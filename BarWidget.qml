import QtQuick
import qs.Commons
import qs.Ui

// Bar entry: the reason this plugin is findable at all.
//
// Omathought is driven by keybindings the user chooses, and an Omarchy plugin
// cannot ship a binding of its own. Without an icon, a fresh install has no
// surface anywhere — nothing to click, no key to press, no error — and reads as
// broken. The icon is the way in: it opens a panel that explains the two keys
// and records them.
BarWidget {
  id: root
  moduleName: "com.github.marvreichmann.omathought"

  // The bar injects `bar`, `moduleName` and `settings` — nothing else. A nested
  // panel gets none of them unless we hand them over, and `anchorItem` is what
  // positions the popup against this button.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for the bar's summon/hide/toggle routing: the bar tracks the
  // widget mounted in its slot, not the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function toggle() { root.togglePanel() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  // Whether the panel has found working keybindings. Drives the setup dot.
  readonly property bool needsSetup: panelLoader.item ? panelLoader.item.needsSetup === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.needsSetup ? "Omathought — needs keybindings" : "Thoughts"

    OpticalGlyph {
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      // U+F036F nf-md-message_text — a spoken note.
      text: "󰍯"
      fontFamily: button.fontFamily
      fontSize: Style.bar.iconFont
      color: button.foreground
    }

    // An unconfigured plugin says so on the bar rather than waiting to be
    // clicked, because the thing it is missing is the only way to reach it.
    Rectangle {
      visible: root.needsSetup
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(3)
    }

    onPressed: function(b) {
      if (!root.bar) return
      root.togglePanel()
    }
  }
}
