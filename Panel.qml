import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The setup and control surface, and the reason the bar icon exists: choosing
// the two keys is the one part of this plugin the user has to do themselves,
// and this is where it happens.
//
// The inner surface is a KeyboardPanel rather than a PopupCard because
// recording a chord needs real key events, and a PopupCard is an xdg-popup that
// only receives keys once a click has routed focus through its parent surface.
Panel {
  id: root
  moduleName: "com.github.marvreichmann.omathought"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The plugin directory is not injected into bar-hosted components, so the
  // helper is resolved relative to this file.
  readonly property string helper: Qt.resolvedUrl("bin/omathought").toString().replace("file://", "")

  // ------------------------------------------------------------------ state

  property string captureChord: ""
  property string browseChord: ""
  property bool loaded: false
  property bool busy: false

  // Which row is listening for a chord: "", "capture" or "browse".
  property string recording: ""

  readonly property bool needsSetup: root.loaded && (root.captureChord === "" || root.browseChord === "")

  onOpenedChanged: if (opened) root.refresh()
  Component.onCompleted: root.refresh()

  function refresh() {
    if (queryProcess.running) return
    queryProcess.running = true
  }

  function beginRecording(slot) {
    if (root.busy) return
    root.recording = slot
  }

  function cancelRecording() {
    root.recording = ""
  }

  // Hyprland names keys by keysym. Letters, digits and the function keys cover
  // what a person actually binds; anything else is refused rather than guessed
  // at, because a wrong name yields a binding that silently never fires.
  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    return ""
  }

  function handleRecordingKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.cancelRecording()
      event.accepted = true
      return
    }

    // Bare modifier presses arrive as their own key events. Waiting for the key
    // that completes the chord is what lets someone hold Super and think.
    if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
        || event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr
        || event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L
        || event.key === Qt.Key_Super_R || event.key === Qt.Key_CapsLock) {
      event.accepted = true
      return
    }

    event.accepted = true

    var key = root.keyName(event.key)
    if (key === "") {
      root.warn("That key cannot be bound", "Use a letter, a digit, or F1-F12.")
      return
    }

    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

    // A bare key is allowed for capture and refused for browse. Push-to-talk is
    // held for as long as the sentence lasts, which a three-key chord makes
    // unpleasant - a bare F-key next to Voxtype's own F9 is the point. Browse
    // is a single press, so it has no excuse to occupy a bare key.
    if (mods.length === 0) {
      var bare = (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12)
      if (root.recording !== "capture" || !bare) {
        root.warn("Add a modifier",
          root.recording === "capture"
            ? "Hold Super, Ctrl, Alt or Shift - or use a bare F-key, which is easier to hold while speaking."
            : "Hold Super, Ctrl, Alt or Shift as well.")
        return
      }
    }

    root.applyChord(root.recording, mods.concat([key]).join(" + "))
  }

  function applyChord(slot, chord) {
    root.busy = true
    root.recording = ""
    writeProcess.command = ["bash", root.helper, "keys", "--set", slot, chord]
    writeProcess.running = true
  }

  function clearChord(slot) {
    if (root.busy) return
    root.busy = true
    root.recording = ""
    writeProcess.command = ["bash", root.helper, "keys", "--clear", slot]
    writeProcess.running = true
  }

  function warn(headline, detail) {
    Quickshell.execDetached(["omarchy-notification-send", "-u", "normal", "Omathought", headline + " - " + detail])
  }

  function label(chord) {
    return chord === "" ? "Not set" : chord
  }

  function run(method) {
    root.close()
    launchProcess.command = ["omarchy-shell", "-q", "omathought", method]
    launchProcess.running = true
  }

  // --------------------------------------------------------------- processes

  Process {
    id: queryProcess
    command: ["bash", root.helper, "keys", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var data = ({})
        try { data = JSON.parse(this.text || "{}") } catch (e) { data = ({}) }
        root.captureChord = data.capture || ""
        root.browseChord = data.browse || ""
        root.loaded = true
      }
    }
  }

  Process {
    id: writeProcess
    stderr: StdioCollector {
      onStreamFinished: if (this.text.trim()) root.warn("Could not write the binding", this.text.trim())
    }
    onExited: {
      root.busy = false
      root.refresh()
    }
  }

  Process { id: launchProcess }

  // ----------------------------------------------------------------- surface

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a row is listening, every key belongs to the chord being
      // recorded - including the arrows and Escape this catcher would
      // otherwise act on itself.
      blocked: root.recording !== ""
      onCloseRequested: root.close()

      Keys.onPressed: function (event) {
        if (root.recording !== "") root.handleRecordingKey(event)
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.md

        PanelHero {
          width: parent.width
          title: "Omathought"
          meta: root.needsSetup ? "Needs keybindings"
                                : (root.loaded ? "Ready" : "Checking...")
          foreground: root.needsSetup ? root.urgent : root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            OpticalGlyph {
              // The same mark as the bar widget - the panel should look like
              // what was clicked. Written literally: the surrogate-pair form is
              // one digit away from a different glyph entirely.
              text: "󰍯"
              width: Style.font.display
              height: Style.font.display
              fontSize: Style.font.display
              color: root.needsSetup ? root.urgent : root.foreground
            }
          }
        }

        // Shown until both keys exist. It is the first thing a new install
        // sees, and it says what the plugin is waiting for rather than that
        // something went wrong.
        Text {
          width: parent.width
          visible: root.needsSetup
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "Omathought runs from two keys you choose. Click a row and press "
              + "the combination you want."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        KeyRow {
          width: parent.width
          slot: "capture"
          heading: "Hold to capture"
          detail: "Hold to record, release to transcribe."
        }

        KeyRow {
          width: parent.width
          slot: "browse"
          heading: "Browse notes"
          detail: "Opens everything you have captured."
        }

        PanelSeparator { width: parent.width }

        // Two equal halves rather than two content-width buttons and a ragged
        // gap: the panel reads as a column, so the actions line up with the
        // rows above them instead of ending wherever their labels do.
        Row {
          width: parent.width
          spacing: Style.spacing.sm

          Button {
            width: (parent.width - Style.spacing.sm) / 2
            text: "Open notes"
            bordered: true
            enabled: !root.busy
            onClicked: root.run("browse")
          }

          Button {
            width: (parent.width - Style.spacing.sm) / 2
            text: "Capture now"
            bordered: true
            enabled: !root.busy
            onClicked: root.run("captureStart")
          }
        }

        // Destructive and secondary, so it is unbordered and tinted rather than
        // a third button competing with the pair above. Hidden outright when
        // there is nothing bound to remove.
        Item {
          width: parent.width
          height: removeButton.implicitHeight
          visible: root.captureChord !== "" || root.browseChord !== ""

          Button {
            id: removeButton
            anchors.right: parent.right
            text: "Remove key bindings"
            enabled: !root.busy
            foreground: root.urgent
            accent: root.urgent
            fontSize: Style.font.caption
            tooltipText: "Unbind both. The bar icon still opens this panel."
            onClicked: root.clearChord("all")
          }
        }
      }
    }
  }

  // One settable key. Every line is single-height and elided, so nothing in
  // here reflows when the text changes under the cursor - a wrapping detail
  // line was pushing the whole panel around on hover.
  component KeyRow: Item {
    id: row
    required property string slot
    required property string heading
    required property string detail

    readonly property string chord: row.slot === "capture" ? root.captureChord : root.browseChord
    readonly property bool listening: root.recording === row.slot
    // A row is a button, and the only clue it was one used to be that it
    // happens to sit under the cursor.
    readonly property bool hot: hover.hovered || row.listening

    implicitHeight: rowColumn.implicitHeight + Style.spacing.md * 2
    height: implicitHeight

    BorderSurface {
      anchors.fill: parent
      radius: Style.cornerRadius
      // The resting-to-hover step is the point: the system's normal and hover
      // fills are 4% and 8%, which on a dark panel is no change at all, so
      // hover takes the selected weight and the accent border together - the
      // shell's own focused-control pairing. Listening then separates itself
      // by tinting the fill accent as well.
      color: row.listening
        ? Util.alpha(Color.accent, 0.22)
        : (row.hot ? Style.selectedFillFor(root.foreground, Color.accent)
                   : (row.chord === "" ? Util.alpha(root.urgent, 0.08)
                                       : Style.normalFillFor(root.foreground, Color.accent)))
      // "selected" carries a zero border width in this theme, so a hovered or
      // listening row keeps the hover-cursor width and changes only its colour.
      // controlSpec resolves that colour from the argument passed as
      // foreground, which is how hover gets an accent outline, not a grey one.
      borderSpec: Border.controlSpec(row.hot ? "hover-cursor" : "normal",
                                     row.hot ? Color.accent
                                             : (row.chord === "" ? root.urgent : root.foreground),
                                     Color.accent)

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    HoverHandler { id: hover }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function (mouse) {
        if (mouse.button === Qt.RightButton) { root.clearChord(row.slot); return }
        if (row.listening) root.cancelRecording()
        else root.beginRecording(row.slot)
      }
    }

    Column {
      id: rowColumn
      x: Style.spacing.md
      y: Style.spacing.md
      width: parent.width - Style.spacing.md * 2
      spacing: Style.spacing.xxs

      // Heading left, chord hard right, both single-line. The chord holds its
      // position in every state and only changes colour, so the eye can rest
      // on it while moving between rows.
      Item {
        width: parent.width
        height: Math.max(headingText.implicitHeight, chordText.implicitHeight)

        Text {
          id: headingText
          anchors.left: parent.left
          anchors.right: chordText.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.heading
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          id: chordText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: row.listening ? "Press a key..." : root.label(row.chord)
          color: row.listening || row.hot
            ? Color.accent
            : (row.chord === "" ? root.urgent : root.foreground)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          Behavior on color {
            ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
          }
        }
      }

      // One line, never wrapped, always present. The text swaps under the
      // cursor to name what a click does; the height cannot change with it.
      Text {
        width: parent.width
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: row.listening
          ? "Esc cancels."
          : (row.hot
              ? (row.chord === "" ? "Click to set a key."
                                  : "Click to change, right-click to clear.")
              : row.detail)
        color: row.hot ? Qt.darker(root.foreground, 1.2) : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption

        Behavior on color {
          ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
      }
    }
  }
}
