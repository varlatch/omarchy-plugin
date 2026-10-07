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
  // Opening also re-reads the CLI version, so a CLI updated outside the
  // plugin shows at once, and (checkUpdates on) checks for a release when
  // the last check is over an hour old, instead of up to 12 hours.
  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      if (hostWidget) hostWidget.refreshVersion(3600)
    } else {
      connecting = false
      connectError = ""
    }
  }

  function shortHost(url) { return hostWidget ? hostWidget.shortHost(url) : String(url) }

  // "Code expires in 9m" for a device sign-in's code.
  function codeLeft(expiresAt) {
    var ms = Date.parse(expiresAt) - nowMs
    if (!isFinite(ms)) return ""
    if (ms <= 0) return "Code expired"
    var m = Math.floor(ms / 60000)
    return m >= 1 ? "Code expires in " + m + "m" : "Code expires in under a minute"
  }

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

  readonly property bool cliMissing: hostWidget ? hostWidget.cliMissing : false
  readonly property bool cliUsable: sessionState !== "unavailable" && sessionState !== "unsupported"
  readonly property string knownServer: hostWidget ? hostWidget.knownServer : ""

  // ---- Server address form: the first sign-in (no server known yet) or
  // another server. Submitting starts the usual browser sign-in.
  property bool connecting: false
  property string connectError: ""
  readonly property bool connectShown: cliUsable && pendingLogin === null
    && (connecting || (servers.length === 0 && knownServer === ""))
  // Something to go back to, so the form gets a cancel.
  readonly property bool connectCancellable: servers.length > 0 || knownServer !== ""

  function startConnect() {
    connecting = true
    connectError = ""
    if (!opened) open()
    Qt.callLater(function () { if (connectField) connectField.forceActiveFocus() })
  }

  // For the widget's debugState.
  readonly property bool connectFocused: connectField.activeFocus

  function stopConnect() {
    connecting = false
    connectError = ""
    connectField.text = ""
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // "https://varlatch.example.com" from what was typed; empty when it
  // cannot be a server address.
  function normalizedServer(text) {
    var s = String(text || "").replace(/\s+/g, "").replace(/\/+$/, "")
    if (s === "") return ""
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = "https://" + s
    return /^https?:\/\/[^\/?#]+(\/[^?#]*)?$/i.test(s) ? s : ""
  }

  function submitConnect() {
    var url = normalizedServer(connectField.text)
    if (!url) {
      connectError = "Give the server's address, such as varlatch.example.com"
      return
    }
    act(["login", url])
    stopConnect()
  }

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
    // With the address form showing (no server known yet, or "add
    // server"), typing goes straight into it.
    focusTarget: root.connectShown ? connectField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(Math.min(mainColumn.implicitHeight + Style.space(24), Style.space(560)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Keys go to the address field while it has focus.
      blocked: connectField.activeFocus
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

        // ---- Sign-in in flight. In the browser: the passkey prompt is
        // there, and the link is here in case it opened in the wrong browser
        // (or not at all). From another device: the address, the code to
        // type there, and a QR code of the address for a phone's camera.
        Column {
          id: pendingBlock
          readonly property var p: root.pendingLogin
          readonly property bool device: !!p && p.mode === "device"
          visible: p !== null
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: pendingBlock.p ? "Signing in to " + root.shortHost(pendingBlock.p.server) : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: pendingBlock.device
              ? "From another device: open this address, sign in with your passkey, and enter the code."
              : "Finish in your browser."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            visible: pendingBlock.device
            width: parent.width
            spacing: Style.space(12)

            // White quiet zone around the code, whatever the theme.
            Rectangle {
              id: qrFrame
              visible: pendingBlock.device && !!pendingBlock.p.qr
              width: Style.space(112)
              height: width
              color: "white"
              radius: Style.space(4)
              Image {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                source: qrFrame.visible ? "file://" + pendingBlock.p.qr : ""
                fillMode: Image.PreserveAspectFit
                smooth: false
                cache: false
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - (qrFrame.visible ? qrFrame.width + parent.spacing : 0)
              spacing: Style.space(4)

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: pendingBlock.device ? String(pendingBlock.p.url).replace(/^https:\/\//, "") : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                text: pendingBlock.device ? pendingBlock.p.code : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.body * 1.6)
                font.bold: true
                font.letterSpacing: 2
              }
              Text {
                text: pendingBlock.device ? root.codeLeft(pendingBlock.p.expiresAt) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item {
            width: parent.width
            height: pendingChips.implicitHeight

            Row {
              id: pendingChips
              anchors.right: parent.right
              spacing: Style.space(6)
              Chip {
                label: "copy code"
                visible: pendingBlock.device
                onClicked: Quickshell.execDetached(["wl-copy", pendingBlock.p.code])
              }
              Chip {
                label: "open link"
                visible: !!pendingBlock.p && !!pendingBlock.p.url
                onClicked: { Quickshell.execDetached(["xdg-open", pendingBlock.p.url]); root.close() }
              }
              // The browser here has no passkey, or the wrong one: approve
              // from a phone or another computer instead.
              Chip {
                label: "other device"
                visible: !pendingBlock.device && !!root.hostWidget && root.hostWidget.deviceSignIn
                onClicked: root.act(["login-device", pendingBlock.p.server])
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

        // ---- Another server, below the sessions.
        Item {
          visible: root.servers.length > 0 && !root.connectShown && root.pendingLogin === null
          width: parent.width
          height: addServer.implicitHeight
          Chip {
            id: addServer
            anchors.right: parent.right
            label: "add server"
            onClicked: root.startConnect()
          }
        }

        // ---- No sessions: install or update the CLI, or log in again.
        Column {
          visible: root.servers.length === 0 && root.pendingLogin === null && !root.connectShown
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.cliMissing ? "The varlatch CLI is not installed"
              : root.sessionState === "unsupported" ? "This varlatch CLI is too old"
              : root.sessionState === "unavailable" ? "varlatch CLI unavailable"
              : root.knownServer ? "Not logged in to " + root.shortHost(root.knownServer)
              : "Not logged in"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: text !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.cliMissing
              ? "Install the release CLI, checked against its checksums, to ~/.local/bin."
              : !root.cliUsable && root.hostWidget ? root.hostWidget.errorDetail : ""
            color: root.cliMissing ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            Chip {
              label: "install CLI"
              visible: root.cliMissing
              onClicked: { root.hostWidget.installCli(); root.close() }
            }
            Chip {
              label: "update CLI"
              visible: root.sessionState === "unsupported" && !!root.hostWidget && root.hostWidget.cliInstall === "release"
              onClicked: { root.hostWidget.upgradeCli(); root.close() }
            }
            Chip {
              label: "log in"
              visible: root.sessionState === "none" && root.knownServer !== "" && !root.connecting
              onClicked: root.act(["login", root.knownServer])
            }
            Chip {
              label: "other server"
              visible: root.sessionState === "none" && root.knownServer !== "" && !root.connecting
              onClicked: root.startConnect()
            }
          }
        }

        // ---- Server address form.
        Column {
          visible: root.connectShown
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: root.servers.length > 0 ? "Connect another server" : "Connect to your Varlatch server"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Item {
            width: parent.width
            height: Math.max(connectField.implicitHeight, connectChips.implicitHeight)

            TextField {
              id: connectField
              anchors.left: parent.left
              anchors.right: connectChips.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "varlatch.example.com"
              foreground: root.fg
              font.family: root.fontFamily
              inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
              onTextChanged: root.connectError = ""
              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.submitConnect()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (root.connectCancellable) root.stopConnect()
                  else root.close()
                  event.accepted = true
                }
              }
            }

            Row {
              id: connectChips
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Chip {
                label: "connect"
                onClicked: root.submitConnect()
              }
              Chip {
                label: "cancel"
                visible: root.connectCancellable
                onClicked: root.stopConnect()
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.connectError !== "" ? root.connectError
              : "Your browser opens for the passkey sign-in."
            color: root.connectError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Footer: CLI version, and a newer release when checkUpdates
        // finds one. "update" only for the release build the plugin can
        // replace; a source checkout or custom command gets the notes.
        PanelSeparator {
          visible: footer.visible
          width: parent.width
        }

        Item {
          id: footer
          readonly property var host: root.hostWidget
          visible: !!host && host.cliVersion !== ""
          width: parent.width
          height: Math.max(footerText.implicitHeight, footerChips.implicitHeight)

          Text {
            id: footerText
            anchors.left: parent.left
            anchors.right: footerChips.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.StyledText
            text: {
              var h = footer.host
              if (!h) return ""
              var t = "CLI " + h.cliVersion
              if (h.cliInstall === "checkout") t += " · source checkout"
              if (h.updateAvailable) t += " · <font color=\"#e0993e\">" + h.latestVersion + " available</font>"
              return t
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: footerChips
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Chip {
              label: "notes"
              visible: !!footer.host && footer.host.updateAvailable
              onClicked: { Quickshell.execDetached(["xdg-open", footer.host.releaseUrl]); root.close() }
            }
            Chip {
              label: "update"
              visible: !!footer.host && footer.host.canUpgrade
              onClicked: { footer.host.upgradeCli(); root.close() }
            }
          }
        }
      }
    }
  }
}
