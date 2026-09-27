import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// NextDNS bar widget: a shield in the bar, and a popup that says which resolver
// the system is actually on, lets you switch NextDNS off to a chosen public or
// DHCP resolver, and hands control to an automatic policy for networks that
// block NextDNS outright.
//
// All privileged work goes through /usr/local/bin/nextdns-toggle under a scoped
// NOPASSWD rule; the shell itself runs unprivileged and never touches
// resolved.conf, NetworkManager or the nextdns service.
Panel {
  id: root
  moduleName: "blacksheep.nextdns"
  ipcTarget: "blacksheep.nextdns"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  property var stats: ({})
  property bool busy: false

  readonly property bool installed: stats.installed === true
  // "Active" is read from what omarchy-dns has the stack pointed at, not from
  // our own override -- the automatic policy can move it without a click, and
  // the switch has to show where DNS actually goes.
  readonly property bool active: stats.active === true
  readonly property bool serviceUp: stats.service === true
  // The daemon can stay alive and bound to 127.0.0.1:53 while answering
  // nothing, so a running service is not by itself good news.
  readonly property bool answering: stats.answering === true
  readonly property string mode: stats.mode || "auto"
  readonly property string provider: stats.provider || "Cloudflare"

  // Wanted but not filtering: NextDNS isn't forced off, yet DNS isn't going
  // through a working NextDNS. That includes the automatic fallback on a
  // network that blocks it, which is exactly when you'd want to know. Shown
  // the way the stock widgets show trouble, by lighting the whole icon in the
  // bar's active colour, rather than with a badge that's easy to miss.
  readonly property bool alarming: installed && mode !== "off" && !(active && answering)

  readonly property string statusText: {
    if (!installed) return "Not installed"
    if (active && answering) return "Filtering"
    if (active) return "Not answering"
    return "Off — using " + (stats.resolver || "another resolver")
  }

  readonly property string modeText: {
    if (mode === "on") return "On"
    if (mode === "off") return "Forced off"
    return "Automatic — falls back when a network blocks it"
  }

  readonly property string daemonText: {
    if (!serviceUp) return "Stopped"
    return answering ? "Running" : "Running, not answering"
  }
  function refresh() {
    if (statsProc.running) return
    statsProc.running = true
  }

  // Turning "Fall back automatically" off must not change which resolver is in
  // use -- it only stops the policy from owning the choice. Pinning the
  // override to whatever is already active does exactly that, and reuses the
  // on/off verbs the sudoers rule already grants rather than needing a new one.
  function pinManual() {
    runToggle(active ? "on" : "off")
  }

  function runToggle(action) {
    if (busy || !installed) return
    busy = true
    toggleProc.command = ["sudo", "-n", "/usr/local/bin/nextdns-toggle", action]
    toggleProc.running = true
  }

  function setProvider(name) {
    if (busy || !installed) return
    busy = true
    toggleProc.command = ["sudo", "-n", "/usr/local/bin/nextdns-toggle", "provider", name]
    toggleProc.running = true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: refresh()

  Process {
    id: statsProc
    // Run from the plugin itself, as a fixed argv: `omarchy plugin update` then
    // updates the helper along with the panel, and no shell parses the path.
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/blacksheep.nextdns/scripts/nextdns-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.stats = JSON.parse(String(text || "{}").trim() || "{}")
        } catch (e) {
          root.stats = {}
        }
      }
    }
  }

  Process {
    id: toggleProc
    // Switching provider reloads NetworkManager and restarts systemd-resolved,
    // and nextdns-apply waits on a DNS probe before it commits. Give the stack
    // a moment to settle before believing the next sample.
    onExited: {
      root.busy = false
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  // The bar icon has to stay honest even while the popup is shut, but polling
  // hard when nobody is looking wakes the machine for nothing.
  Timer {
    interval: root.opened ? 2000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.active
      ? "NextDNS — " + (root.answering ? "on" : "not answering")
      : "NextDNS — off, using " + (root.stats.resolver || "another resolver")
        + (root.alarming ? "" : " (forced off)")

    iconComponent: Component {
      Item {
        NextDnsIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.alarming
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : (root.bar ? root.bar.barForeground : Color.foreground)
          crossed: !root.active
        }
      }
    }

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "a" || t === "A") root.runToggle("auto")
        else if (t === "n" || t === "N") root.runToggle("toggle")
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "NextDNS"
          meta: root.statusText
          iconOpacity: root.active ? 1.0 : 0.5
          iconComponent: Component {
            NextDnsIcon {
              iconSize: Style.font.display
              color: root.alarming
                ? (root.bar ? root.bar.urgent : Color.urgent)
                : (root.bar ? root.bar.foreground : Color.foreground)
              crossed: !root.active
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.active
              busy: root.busy
              interactive: root.installed
              opacity: interactive ? 1.0 : 0.4
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onToggled: root.runToggle("toggle")
            }
          }
        }

        PanelSeparator { width: parent.width }

        GridLayout {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(14)
          rowSpacing: Style.space(6)

          // Mode first: who decides is the one thing here you might change.
          InfoLabel { text: "Mode" }
          InfoValue { text: root.modeText; Layout.fillWidth: true }

          InfoLabel { text: "Resolver" }
          InfoValue { text: root.stats.resolver || "—"; Layout.fillWidth: true }

          InfoLabel { text: "Profile" }
          InfoValue { text: root.stats.profile || "—" }

          InfoLabel { text: "Daemon" }
          InfoValue { text: root.daemonText }

          InfoLabel { text: "Network" }
          InfoValue { text: root.stats.ssid || "—"; Layout.fillWidth: true }

        }

        PanelSeparator { width: parent.width }

        // Two switches, because the state really is three-valued: automatic,
        // forced on, forced off. The hero switch says which resolver is in use;
        // this one says who decides. Flipping the hero switch while this is on
        // is itself an override, so this drops to off on its own.
        Item {
          width: parent.width
          implicitHeight: Math.max(autoLabels.implicitHeight, autoSwitch.implicitHeight)

          Column {
            id: autoLabels
            anchors.left: parent.left
            anchors.right: autoSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Fall back automatically"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              text: "On captive portals and networks that block NextDNS"
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              opacity: 0.6
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: autoSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.mode === "auto"
            busy: root.busy
            interactive: root.installed
            opacity: interactive ? 1.0 : 0.4
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onToggled: root.mode === "auto" ? root.pinManual() : root.runToggle("auto")
          }
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          text: "When off"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // Picking a provider here is a preference while NextDNS is on and an
        // immediate switch while it is off; nextdns-toggle decides which,
        // because only it knows whether the change is visible right now.
        ButtonGroup {
          width: parent.width
          enabled: root.installed
          opacity: root.installed ? 1.0 : 0.4
          // The panel drives its own keyboard cursor; a ButtonGroup that also
          // took Tab focus would swallow the panel's h/l and Enter.
          focusable: false
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          fontSize: Style.font.bodySmall
          value: root.provider
          options: [
            { value: "Cloudflare", label: "Cloudflare", tooltip: "1.1.1.1 over TLS — private, unfiltered" },
            { value: "Google", label: "Google", tooltip: "8.8.8.8 over TLS" },
            { value: "DHCP", label: "DHCP", tooltip: "Whatever the network hands out — the one that works behind a captive portal" }
          ]
          onChanged: function(v) { root.setProvider(v) }
        }

        Text {
          width: parent.width
          visible: !root.installed
          text: "nextdns-toggle is not installed. Run install.sh in the plugin folder (see the README), then this panel becomes live."
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.6
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.installed && !!root.stats.last
          text: String(root.stats.last || "")
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.alarming
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : (root.bar ? root.bar.foreground : Color.foreground)
          opacity: root.alarming ? 1.0 : 0.6
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Color.foreground
    opacity: 0.6
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.bar ? root.bar.foreground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
