import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui

// Anchored popout under the bar widget: sessions with live countdowns and
// the actions that make sense for the current state. All reads come from
// the host widget's `status --json` poll; buttons are the only network
// paths (login/renew, logout, verify). Sign-in runs without a terminal:
// while it waits on the browser, the panel shows it with open link/cancel.
Panel {
  id: root
  moduleName: "varlatch"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var servers: hostWidget ? hostWidget.servers : []
  readonly property string sessionState: hostWidget ? hostWidget.sessionState : "unavailable"
  readonly property string menuHelper: hostWidget ? hostWidget.menuHelper : ""
  // Browser sign-in waiting on its callback ({server, url, pid}) or null.
  readonly property var pendingLogin: hostWidget ? hostWidget.pendingLogin : null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Live countdowns while open.
  property double nowMs: Date.now()
  Timer { interval: 10000; running: root.opened; repeat: true; onTriggered: root.nowMs = Date.now() }
  onOpenedChanged: if (opened) nowMs = Date.now()

  function shortHost(url) { return hostWidget ? hostWidget.shortHost(url) : String(url) }

  function remaining(s) {
    if (s.expired === true) return "EXPIRED"
    if (!s.expiresAt) return "no expiry recorded"
    var ms = Date.parse(s.expiresAt) - nowMs
    if (!isFinite(ms)) return "no expiry recorded"
    if (ms <= 0) return "EXPIRED"
    var h = Math.floor(ms / 3600000)
    var m = Math.floor((ms % 3600000) / 60000)
    return (h > 0 ? h + "h " + m + "m" : m + "m") + " left"
  }

  function act(args) {
    Quickshell.execDetached([root.menuHelper].concat(args))
  }

  readonly property var expiredServers: servers.filter(function (s) { return s.expired === true })
  readonly property bool loginUseful: servers.length === 0 || expiredServers.length > 0

  component Chip: Rectangle {
    property string label: ""
    property bool danger: false
    signal clicked()
    radius: Style.space(6)
    color: chipMouse.containsMouse ? Qt.alpha(danger ? root.urgent : root.fg, 0.18) : Qt.alpha(root.fg, 0.08)
    implicitWidth: chipText.implicitWidth + Style.space(16)
    implicitHeight: chipText.implicitHeight + Style.space(10)
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.label
      color: parent.danger ? root.urgent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(Math.min(mainColumn.implicitHeight + Style.space(24), Style.space(560)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: mainColumn
        width: parent.width
        spacing: Style.space(10)

        // ---- Header: brand mark + title, verify on the right.
        Item {
          width: parent.width
          height: Style.space(30)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Item {
              width: Style.space(18)
              height: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              Image {
                id: headerMark
                anchors.fill: parent
                source: Qt.resolvedUrl("assets/varlatch-mark-symbolic.png")
                sourceSize: Qt.size(64, 64)
                fillMode: Image.PreserveAspectFit
                smooth: true
                visible: false
              }
              MultiEffect {
                anchors.fill: headerMark
                source: headerMark
                colorization: 1.0
                colorizationColor: root.fg
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "VARLATCH"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
              color: root.dim
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Chip {
              label: root.hostWidget && root.hostWidget.verifying ? "verifying…" : "verify"
              visible: root.servers.length > 0
              onClicked: { if (root.hostWidget && !root.hostWidget.verifying) root.hostWidget.verify() }
            }
            Chip {
              label: "dashboard"
              visible: root.servers.length > 0
              onClicked: { root.act(["web"]); root.close() }
            }
          }
        }

        PanelSeparator { width: parent.width }

        Text {
          visible: root.hostWidget ? root.hostWidget.verifyError !== "" : false
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.hostWidget ? root.hostWidget.verifyError : ""
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- Sign-in in flight: the browser has the passkey prompt; the
        // link is here in case it opened in the wrong browser (or not at all).
        Column {
          visible: root.pendingLogin !== null
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: "Signing in to " + (root.pendingLogin ? root.shortHost(root.pendingLogin.server) : "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Item {
            width: parent.width
            height: pendingChips.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.right: pendingChips.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: "Finish in your browser"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              id: pendingChips
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Chip {
                label: "open link"
                visible: root.pendingLogin !== null && !!root.pendingLogin.url
                onClicked: { Quickshell.execDetached(["xdg-open", root.pendingLogin.url]); root.close() }
              }
              Chip {
                label: "cancel"
                danger: true
                onClicked: root.act(["login-cancel"])
              }
            }
          }
        }

        // ---- Sessions
        Repeater {
          model: root.servers
          delegate: Item {
            id: sessionRow
            required property var modelData
            width: mainColumn.width
            height: Style.space(44)

            readonly property bool bad: modelData.expired === true || modelData.state === "warning"

            Rectangle {
              width: Style.space(8)
              height: width
              radius: width / 2
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: modelData.expired === true ? root.urgent
                : modelData.state === "warning" ? Qt.alpha(root.urgent, 0.75)
                : "#7bc96f"
            }

            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: root.shortHost(modelData.server)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: {
                  var base = modelData.expired === true
                    ? "Session expired — log in again"
                    : "Logged in — " + root.remaining(modelData)
                  var p = modelData.probe
                  if (p) base += p.state === "valid" ? " · ✓ verified"
                    : p.state === "invalid" ? " · ✕ " + (p.detail || "invalid")
                    : " · server unreachable"
                  return base
                }
                color: sessionRow.bad || (modelData.probe && modelData.probe.state !== "valid")
                  ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              // Renew = log in again to the same server; the CLI revokes the
              // old credential only once the new one is saved, so a cancelled
              // sign-in loses nothing.
              Chip {
                label: "renew"
                visible: modelData.expired !== true && root.pendingLogin === null
                onClicked: root.act(["login", modelData.server])
              }
              Chip {
                label: modelData.expired === true ? "log in" : "log out"
                danger: modelData.expired !== true
                visible: modelData.expired !== true || root.pendingLogin === null
                onClicked: {
                  if (modelData.expired === true) root.act(["login", modelData.server])
                  else { root.act(["logout", modelData.server]); root.close() }
                }
              }
            }
          }
        }

        // ---- Empty state
        Column {
          visible: root.servers.length === 0
          width: parent.width
          spacing: Style.space(8)
          Text {
            visible: root.pendingLogin === null
            text: root.sessionState === "unavailable" || root.sessionState === "unsupported"
              ? "varlatch CLI unavailable"
              : "Not logged in"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Chip {
            label: "log in"
            visible: root.sessionState === "none" && root.pendingLogin === null
            onClicked: root.act(["login"])
          }
        }
      }
    }
  }
}
