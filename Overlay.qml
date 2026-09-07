import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omathought's only entry point. One `keepLoaded` overlay hosting two layer
// surfaces — the capture card at the bottom and the note browser down the left
// — because a plugin gets a single entry point per kind, and both surfaces need
// the same live state and the same IPC handler.
//
// keepLoaded matters for more than speed: the push-to-talk keybinding calls
// `captureStop` on key release, which can only reach a plugin the shell has
// already mounted.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "com.github.marvreichmann.omathought"

  // Resolved on call rather than held as a binding. `manifest` is injected by
  // the loader after construction, and a derived binding read from inside
  // `onManifestChanged` can still observe the pre-change value — which yielded
  // a bare "/bin/omathought", a silent exit 127, and a plugin that reported its
  // own keybindings missing while they were sitting there working.
  function helperPath() {
    var dir = (manifest && manifest.__sourceDir) || ""
    return dir + "/bin/omathought"
  }

  // ------------------------------------------------------------- capture

  property bool captureOpen: false
  // idle → recording → transcribing → ready ( → saving ) ; or error
  property string phase: "idle"
  property string draft: ""
  property string savedId: ""

  // ------------------------------------------------------------- browsing

  property bool browseOpen: false
  property var notes: []
  property string query: ""
  property string selectedId: ""
  property bool editing: false
  property string editDraft: ""
  property string pendingDelete: ""

  readonly property var visibleNotes: Model.filterNotes(root.notes, root.query)
  // `now` is only re-read when the list is rebuilt; a memo's group heading does
  // not need to change under the cursor at midnight.
  readonly property var rows: Model.buildRows(root.visibleNotes, new Date())
  readonly property var selectedNote: Model.findNote(root.notes, root.selectedId)

  // ---------------------------------------------------------------- theme

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", root.borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding

  // ------------------------------------------------------------- monitors

  // Which output each surface is on. A PanelWindow with no `screen` lands on
  // the first one Quickshell enumerates, so on a multi-monitor desk a summoned
  // panel opens on some other screen than the one being used — it is not
  // missing, it is two monitors away.
  //
  // Resolved once when a surface opens, not bound live: a card must not hop
  // monitors because focus moved while it was up.
  property var captureScreen: null
  property var browseScreen: null

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    if (!name) return null

    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    // Hyprland named an output Quickshell does not know yet. Null falls back to
    // the default screen, which is better than refusing to show anything.
    return null
  }

  // ============================================================== plugin API

  // The shell calls these; `summon` routes its payload to open().
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.mode === "browse") root.openBrowser()
    else root.startCapture()
  }

  function close() {
    root.captureOpen = false
    root.browseOpen = false
  }

  function toggle() {
    if (root.browseOpen) root.closeBrowser()
    else root.openBrowser()
  }

  // Tell the host to drop this plugin's open state, but only once *both*
  // surfaces are down: the shell tracks one open flag per plugin id, so
  // releasing it while the other surface is still up would desync the host.
  function releaseIfIdle() {
    if (root.captureOpen || root.browseOpen) return
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // ============================================================== capture

  function startCapture() {
    // Key repeat fires `captureStart` again while the key is held down. Without
    // this guard the second call restarts the recording and the first half of
    // the sentence is lost.
    if (root.captureOpen && (root.phase === "recording" || root.phase === "transcribing")) return

    root.captureScreen = root.focusedScreen()
    root.captureOpen = true
    root.phase = "recording"
    root.draft = ""
    root.savedId = ""
    recordStart.running = true

    // The surface has to map before anything inside it can take active focus,
    // and the focus has to land before Voxtype types: the transcript arrives as
    // ordinary key events aimed at whatever holds the keyboard.
    Qt.callLater(function () { captureInput.forceActiveFocus() })
  }

  function stopCapture() {
    if (root.phase !== "recording") return
    root.phase = "transcribing"
    recordStop.running = true
    transcribeTimeout.restart()
  }

  // Voxtype signals nothing when it finishes typing, so the end of a transcript
  // is inferred: text arrived, then stopped changing. Short, because the wait is
  // in front of the user.
  function noteTranscriptActivity() {
    if (root.phase !== "transcribing") return
    settleTimer.restart()
  }

  function settleTranscript() {
    if (root.phase !== "transcribing") return
    transcribeTimeout.stop()
    root.phase = "ready"
  }

  function saveCapture() {
    var text = Model.cleanTranscript(root.draft)
    if (!Model.isSaveable(text)) { root.dismissCapture(); return }

    root.phase = "saving"
    saveProcess.command = ["bash", root.helperPath(), "save", text]
    saveProcess.running = true
  }

  function dismissCapture() {
    // A card closed mid-recording must not leave the daemon listening, and the
    // audio is discarded rather than transcribed into nothing.
    if (root.phase === "recording" || root.phase === "transcribing") recordCancel.running = true
    transcribeTimeout.stop()
    settleTimer.stop()
    root.captureOpen = false
    root.phase = "idle"
    root.draft = ""
    root.releaseIfIdle()
  }

  // ============================================================== browsing

  function openBrowser() {
    root.browseScreen = root.focusedScreen()
    root.browseOpen = true
    root.editing = false
    root.pendingDelete = ""
    root.refresh()
    Qt.callLater(function () { browseKeys.forceActiveFocus() })
  }

  function closeBrowser() {
    root.browseOpen = false
    root.editing = false
    root.pendingDelete = ""
    root.query = ""
    root.releaseIfIdle()
  }

  function refresh() {
    listProcess.running = true
  }

  function consumeList(raw) {
    root.notes = Model.parseList(raw)
    if (!Model.findNote(root.notes, root.selectedId))
      root.selectedId = root.notes.length > 0 ? root.notes[0].id : ""
  }

  function moveSelection(delta) {
    if (root.editing) return
    root.selectedId = Model.moveSelection(root.rows, root.selectedId, delta)
    root.pendingDelete = ""
  }

  function beginEdit() {
    var note = root.selectedNote
    if (!note) return
    root.editDraft = note.body
    root.editing = true
    root.pendingDelete = ""
    Qt.callLater(function () { editInput.forceActiveFocus() })
  }

  function commitEdit() {
    var note = root.selectedNote
    if (!note) { root.editing = false; return }
    var text = Model.cleanTranscript(root.editDraft)

    // An emptied note is a delete the user did not ask for, so it is refused
    // here rather than silently dropped by the helper.
    if (!Model.isSaveable(text)) { root.cancelEdit(); return }

    updateProcess.command = ["bash", root.helperPath(), "update", note.id, text]
    updateProcess.running = true
    root.editing = false
    Qt.callLater(function () { browseKeys.forceActiveFocus() })
  }

  function cancelEdit() {
    root.editing = false
    root.editDraft = ""
    Qt.callLater(function () { browseKeys.forceActiveFocus() })
  }

  // Delete is two keystrokes, not a modal: the first arms the row, the second
  // commits, and any other key disarms it.
  function requestDelete() {
    if (root.editing || !root.selectedId) return
    if (root.pendingDelete === root.selectedId) root.confirmDelete()
    else root.pendingDelete = root.selectedId
  }

  function confirmDelete() {
    var id = root.pendingDelete
    if (!id) return
    root.pendingDelete = ""
    // Move the cursor before the list reloads, so it lands where the deleted
    // row was rather than snapping back to the top.
    root.selectedId = Model.selectionAfterDelete(root.visibleNotes, id)
    deleteProcess.command = ["bash", root.helperPath(), "delete", id]
    deleteProcess.running = true
  }

  function setQuery(next) {
    root.query = next
    root.pendingDelete = ""
    if (!Model.findNote(root.visibleNotes, root.selectedId))
      root.selectedId = root.visibleNotes.length > 0 ? root.visibleNotes[0].id : ""
  }

  // ============================================================ ipc + procs

  // Bound to the push-to-talk keybinding, which needs a target that exists
  // before the first keypress — hence the plugin's keepLoaded manifest flag.
  IpcHandler {
    target: "omathought"

    function captureStart(): void { root.startCapture() }
    function captureStop(): void { root.stopCapture() }
    function captureCancel(): void { root.dismissCapture() }
    function browse(): void { root.openBrowser() }
    function toggleBrowse(): void { root.toggle() }
  }

  Process { id: recordStart;  command: ["voxtype", "record", "start"] }
  Process { id: recordStop;   command: ["voxtype", "record", "stop"] }
  Process { id: recordCancel; command: ["voxtype", "record", "cancel"] }

  Process {
    id: listProcess
    command: ["bash", root.helperPath(), "list"]
    stdout: StdioCollector { onStreamFinished: root.consumeList(this.text) }
  }

  Process {
    id: saveProcess
    stdout: StdioCollector { onStreamFinished: root.savedId = this.text.trim() }
    onExited: function (code) {
      if (code !== 0) { root.phase = "ready"; return }
      root.captureOpen = false
      root.phase = "idle"
      root.draft = ""
      root.releaseIfIdle()
      // Keep an open browser honest about a memo saved behind it.
      if (root.browseOpen) root.refresh()
    }
  }

  Process {
    id: updateProcess
    onExited: root.refresh()
  }

  Process {
    id: deleteProcess
    onExited: root.refresh()
  }

  // Transcription has landed when the text stops growing.
  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.settleTranscript()
  }

  // A daemon that never answers must not strand the card in "Transcribing…".
  // The recording is gone either way; what is left is a card the user can close.
  Timer {
    id: transcribeTimeout
    interval: 20000
    onTriggered: {
      if (root.phase !== "transcribing") return
      settleTimer.stop()
      root.phase = root.draft.length > 0 ? "ready" : "error"
    }
  }

  // ============================================================ capture card

  PanelWindow {
    id: capturePanel
    visible: root.captureOpen
    screen: root.captureScreen
    // Anchored on three sides: the card sits at the bottom, but the surface
    // spans the screen so the scrim covers it and a click anywhere dismisses.
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omathought-capture"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismissCapture() }

    BorderSurface {
      id: captureCard
      width: Math.min(Style.space(720), capturePanel.width - Style.gapsOut * 4)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(80)
      height: captureColumn.implicitHeight + root.contentMargin * 2
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: captureColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: captureCard.contentTopInset
        anchors.leftMargin: captureCard.contentLeftInset
        anchors.rightMargin: captureCard.contentRightInset
        spacing: Style.spacing.md

        Row {
          spacing: Style.spacing.sm

          // A filled dot while the mic is live, hollow once it is not.
          Rectangle {
            width: Style.space(9)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.phase === "recording" ? Color.urgent : "transparent"
            border.width: root.phase === "recording" ? 0 : Math.max(1, Style.space(1))
            border.color: Util.alpha(root.foreground, 0.5)

            SequentialAnimation on opacity {
              running: root.phase === "recording"
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.35; duration: 620; easing.type: Easing.InOutQuad }
              NumberAnimation { from: 0.35; to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
            onVisibleChanged: if (!visible) opacity = 1.0
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: Model.captureStatus(root.phase, root.draft.trim().length > 0)
            color: root.phase === "error" ? Color.urgent : Util.alpha(root.foreground, 0.65)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // The transcript target. Voxtype types into whatever holds the
        // keyboard, so this field receives the memo keystroke by keystroke —
        // which is also what makes the text editable before it is saved.
        TextEdit {
          id: captureInput
          anchors.left: parent.left
          anchors.right: parent.right
          text: root.draft
          onTextChanged: {
            if (root.draft !== text) root.draft = text
            root.noteTranscriptActivity()
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          selectionColor: root.selectedBackground
          selectedTextColor: root.selectedText
          // Grows with the memo, then scrolls rather than pushing the card off
          // the top of the screen.
          height: Math.min(implicitHeight, Style.space(220))
          clip: true

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              root.dismissCapture()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                       && (event.modifiers & Qt.ControlModifier)) {
              root.saveCapture()
              event.accepted = true
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.fill: parent
            visible: captureInput.text.length === 0
            text: root.phase === "recording" ? "Speak…" : "No text captured"
            color: Util.alpha(root.foreground, 0.35)
            font: captureInput.font
          }
        }
      }
    }
  }

  // ============================================================ note browser

  PanelWindow {
    id: browsePanel
    visible: root.browseOpen
    screen: root.browseScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omathought-browser"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.closeBrowser() }

    BorderSurface {
      id: browseCard
      width: Math.min(Style.space(420), browsePanel.width - Style.gapsOut * 2)
      anchors.left: parent.left
      anchors.leftMargin: Style.gapsOut
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.gapsOut
      anchors.bottomMargin: Style.gapsOut
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Key handling for the list lives on one item so the ListView delegates
      // stay presentational; the editor takes focus away while it is open.
      Item {
        id: browseKeys
        anchors.fill: parent
        focus: !root.editing

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (root.editing) return

          if (event.key === Qt.Key_Escape) {
            if (root.pendingDelete) root.pendingDelete = ""
            else if (root.query) root.setQuery("")
            else root.closeBrowser()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.beginEdit()
            event.accepted = true
          } else if (event.key === Qt.Key_Delete
                     || (event.key === Qt.Key_D && (event.modifiers & Qt.ControlModifier))) {
            root.requestDelete()
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            root.setQuery(root.query.slice(0, -1))
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            // j/k navigate only while the filter is empty; once the user is
            // typing a query, every letter is a letter.
            if (!root.query && (event.key === Qt.Key_J || event.key === Qt.Key_K)) return
            root.setQuery(root.query + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: browseCard.contentTopInset
        anchors.leftMargin: browseCard.contentLeftInset
        anchors.rightMargin: browseCard.contentRightInset
        anchors.bottomMargin: browseCard.contentBottomInset
        spacing: Style.spacing.md

        // ------------------------------------------------------- header
        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          height: header.implicitHeight

          Column {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: "Thoughts"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              elide: Text.ElideRight
              text: root.query
                ? "Filter: " + root.query + " · " + root.visibleNotes.length + " of " + root.notes.length
                : root.notes.length + (root.notes.length === 1 ? " note" : " notes")
              color: Util.alpha(root.foreground, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // -------------------------------------------------------- list
        ListView {
          id: noteList
          anchors.left: parent.left
          anchors.right: parent.right
          height: parent.height - parent.spacing * 2 - header.implicitHeight - footer.implicitHeight
          clip: true
          spacing: Style.spacing.xxs
          model: root.rows
          currentIndex: -1
          visible: !root.editing

          // Follow the keyboard cursor, which lives in `selectedId` rather than
          // in the view — the model interleaves headings, so an index is not a
          // stable handle on a note.
          function scrollTo(id) {
            for (var i = 0; i < model.length; i++) {
              if (model[i].kind === "note" && model[i].id === id) { positionViewAtIndex(i, ListView.Contain); return }
            }
          }
          Connections {
            target: root
            function onSelectedIdChanged() { noteList.scrollTo(root.selectedId) }
          }

          delegate: Item {
            id: rowItem
            required property var modelData
            width: noteList.width
            height: rowItem.modelData.kind === "heading"
              ? headingText.implicitHeight + Style.spacing.md
              : noteRow.implicitHeight + Style.spacing.sm * 2

            // ------ group heading
            Text {
              id: headingText
              visible: rowItem.modelData.kind === "heading"
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              text: rowItem.modelData.label || ""
              color: Util.alpha(root.foreground, 0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.capitalization: Font.AllUppercase
              font.letterSpacing: 0.6
            }

            // ------ note row
            Rectangle {
              visible: rowItem.modelData.kind === "note"
              anchors.fill: parent
              radius: root.cornerRadius
              color: root.pendingDelete === rowItem.modelData.id
                ? Util.alpha(Color.urgent, 0.18)
                : (root.selectedId === rowItem.modelData.id ? root.selectedBackground : "transparent")

              MouseArea {
                anchors.fill: parent
                onClicked: { root.selectedId = rowItem.modelData.id; root.pendingDelete = "" }
                onDoubleClicked: { root.selectedId = rowItem.modelData.id; root.beginEdit() }
              }

              Column {
                id: noteRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                spacing: Style.spacing.xxs

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  spacing: Style.spacing.sm

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width - timeText.implicitWidth - parent.spacing
                    elide: Text.ElideRight
                    text: rowItem.modelData.title || ""
                    color: root.selectedId === rowItem.modelData.id ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: timeText
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.modelData.time || ""
                    color: Util.alpha(root.foreground, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  elide: Text.ElideRight
                  visible: text.length > 0
                  text: root.pendingDelete === rowItem.modelData.id
                    ? "Press again to delete · Esc to keep"
                    : (rowItem.modelData.preview || "")
                  color: root.pendingDelete === rowItem.modelData.id
                    ? Color.urgent
                    : Util.alpha(root.foreground, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ------ empty state
          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            width: parent.width - Style.spacing.lg * 2
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: noteList.count === 0
            text: root.notes.length === 0
              ? "No thoughts yet.\nHold the capture key and speak."
              : "Nothing matches that filter."
            color: Util.alpha(root.foreground, 0.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ------------------------------------------------------ editor
        TextEdit {
          id: editInput
          anchors.left: parent.left
          anchors.right: parent.right
          height: noteList.height
          visible: root.editing
          text: root.editDraft
          onTextChanged: if (root.editDraft !== text) root.editDraft = text
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          selectionColor: root.selectedBackground
          selectedTextColor: root.selectedText
          clip: true

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              root.cancelEdit()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                       && (event.modifiers & Qt.ControlModifier)) {
              root.commitEdit()
              event.accepted = true
            }
          }
        }

        // ------------------------------------------------------ footer
        Text {
          id: footer
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          elide: Text.ElideRight
          text: root.editing
            ? "Ctrl+Enter save · Esc cancel"
            : "↑↓ move · Enter edit · Del delete · type to filter"
          color: Util.alpha(root.foreground, 0.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
