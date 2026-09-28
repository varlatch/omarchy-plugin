import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Varlatch session disclosure. Everything shown here
// comes from `varlatch status --json`, which reads local files only — the
// widget never makes ambient authenticated calls with a stored credential.
// The one ambient network read is the opt-in release check (checkUpdates),
// which is anonymous and cached by the helper.
// Actions (login/renew, logout, verify with --probe) live in the panel,
// the omarchy menu, and the expiry notifications.
BarWidget {
  id: root
  moduleName: "varlatch"

  // "ok" | "warning" | "expired" | "none" | "unsupported" | "unavailable"
  property string sessionState: "unavailable"
  property var servers: []
  property string errorDetail: ""
  // server url -> last state notified for it, so each transition into
  // warning/expired notifies exactly once.
  property var _notified: ({})

  readonly property string command: String(setting("varlatchCommand", "varlatch"))
  readonly property int refreshSec: Math.max(15, parseInt(String(setting("refreshIntervalSec", 30)), 10) || 30)
  readonly property bool notifyExpiry: setting("notifyExpiry", "on") !== "off"
  readonly property bool showWhenLoggedOut: setting("showWhenLoggedOut", "on") !== "off"
  // A localhost dev server should not count as "logged in" (or color the
  // bar) unless explicitly asked for.
  readonly property bool showLocalhost: setting("showLocalhost", "off") === "on"

  function isLocalhost(url) {
    return /^[a-z]+:\/\/(localhost|127\.)/.test(String(url || ""))
  }

  // A refresh requested mid-run (settings arriving after the first timer
  // tick) re-runs once the current process exits, so the widget never sits
  // on output from a stale command.
  property bool _refreshQueued: false
  function refresh() {
    loginFile.reload()
    if (statusProc.running) { _refreshQueued = true; return }
    statusProc.running = true
  }

  onSettingsChanged: { refresh(); refreshVersion(); injectPanel() }

  // ---- CLI version and updates, from `varlatch-menu version-info`: the
  // installed version, how it is installed ("release" builds can be
  // replaced by the plugin; "checkout" and "custom" cannot), and with
  // checkUpdates on, the latest release (the helper caches the check).
  property string cliVersion: ""
  property string cliInstall: ""
  property string latestVersion: ""
  property bool updateAvailable: false
  property string releaseUrl: ""
  readonly property bool canUpgrade: updateAvailable && cliInstall === "release"

  property bool _versionQueued: false
  function refreshVersion() {
    if (versionProc.running) { _versionQueued = true; return }
    versionProc.running = true
  }

  function upgradeCli() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      root.menuHelper + " upgrade-cli " + root.latestVersion])
  }

  Process {
    id: versionProc
    running: false
    command: ["bash", "-lc", "'" + root.menuHelper + "' version-info"]
    stdout: StdioCollector { id: versionStdout; waitForEnd: true }
    onExited: function (exitCode) {
      var doc = null
      if (exitCode === 0) { try { doc = JSON.parse(String(versionStdout.text || "")) } catch (e) {} }
      root.cliVersion = doc ? doc.current || "" : ""
      root.cliInstall = doc ? doc.install || "" : ""
      root.latestVersion = doc ? doc.latest || "" : ""
      root.updateAvailable = doc ? doc.updateAvailable === true : false
      root.releaseUrl = doc ? doc.releaseUrl || "" : ""
      if (root._versionQueued) { root._versionQueued = false; Qt.callLater(root.refreshVersion) }
    }
  }

  // Hourly; the helper only goes to the network once its cache is stale.
  Timer {
    interval: 3600 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshVersion()
  }

  // The CLI decides "expiring" (under 20% of the credential's lifetime
  // left); older CLIs lack the field, so fall back to the same rule here.
  function classify(server, now) {
    if (server.expired === true) return "expired"
    if ("expiring" in server) return server.expiring === true ? "warning" : "ok"
    if (server.issuedAt && server.expiresAt) {
      var issued = Date.parse(server.issuedAt)
      var expires = Date.parse(server.expiresAt)
      if (isFinite(issued) && isFinite(expires) && expires > issued
          && (expires - now) < (expires - issued) * 0.2) return "warning"
    }
    return "ok"
  }

  function shortHost(url) {
    return String(url || "").replace(/^[a-z]+:\/\//, "").replace(/[/].*$/, "")
  }

  function remainingText(expiresAt, now) {
    var ms = Date.parse(expiresAt) - now
    if (!isFinite(ms)) return ""
    if (ms <= 0) return "expired"
    var h = Math.floor(ms / 3600000)
    var m = Math.floor((ms % 3600000) / 60000)
    return h > 0 ? h + "h" + (m > 0 ? " " + m + "m" : "") + " left" : m + "m left"
  }

  function parse(stdout) {
    var doc
    try { doc = JSON.parse(stdout) } catch (e) {
      root.sessionState = "unavailable"
      root.errorDetail = "unparseable status output"
      return
    }
    var now = Date.now()
    var list = (doc.servers || []).filter(function (s) {
      return root.showLocalhost || !root.isLocalhost(s.server)
    })
    var worst = list.length === 0 ? "none" : "ok"
    var notified = {}
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      s.state = classify(s, now)
      if (s.state === "expired") worst = "expired"
      else if (s.state === "warning" && worst !== "expired") worst = "warning"
      if (s.state === "warning" || s.state === "expired") {
        notified[s.server] = s.state
        if (root.notifyExpiry && root._notified[s.server] !== s.state) {
          // Routed through the helper so the notification's action button
          // ("Renew now" / "Log in") can start the login.
          Quickshell.execDetached([root.menuHelper, "notify-session", s.server, s.state,
            s.state === "expired"
              ? "Credential for " + shortHost(s.server) + " has expired — log in again."
              : "Credential for " + shortHost(s.server) + " expires soon (" + remainingText(s.expiresAt, now) + ")."])
        }
      }
    }
    root._notified = notified
    root.servers = list
    root.sessionState = worst
    root.errorDetail = ""
    // Keep the omarchy-menu submenu in step with session state (it no-ops
    // and skips the menu refresh when nothing changed).
    Quickshell.execDetached([root.menuHelper, "sync-menu"])
  }

  readonly property string menuHelper:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/varlatch/bin/varlatch-menu"

  // In-panel verification: same `status --probe --json` the menu route uses,
  // but the results land on the session rows instead of a notification.
  property bool verifying: false
  property string verifyError: ""
  function verify() {
    if (verifyProc.running) return
    verifying = true
    verifyError = ""
    verifyProc.running = true
  }

  Process {
    id: verifyProc
    running: false
    command: ["bash", "-lc", root.command + " status --probe --json"]
    stdout: StdioCollector { id: verifyStdout; waitForEnd: true }
    stderr: StdioCollector { id: verifyStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root.verifying = false
      if (exitCode === 0) {
        // The probe payload is a full status document whose servers carry
        // `probe` results (and freshly backfilled expiry metadata).
        root.parse(String(verifyStdout.text || ""))
      } else {
        root.verifyError = String(verifyStderr.text || "").trim() || "verify failed"
      }
    }
  }

  // Browser sign-in in flight ({server, url, pid}) or null. The helper runs
  // the login without a terminal and records it here, so the panel can
  // offer "open link" / "cancel" instead of a window showing the URL.
  property var pendingLogin: null
  FileView {
    id: loginFile
    path: Quickshell.env("HOME") + "/.local/state/varlatch-omarchy/login.json"
    watchChanges: true
    printErrors: false
    // `text()` is stale inside the change signal; reload and parse on load.
    onFileChanged: reload()
    onLoaded: {
      var doc = null
      try { doc = JSON.parse(text()) } catch (e) {}
      root.pendingLogin = doc && doc.state === "pending" ? doc : null
    }
    onLoadFailed: root.pendingLogin = null
  }

  Process {
    id: statusProc
    running: false
    // Login shell so the user's PATH (~/.local/bin) resolves the CLI.
    command: ["bash", "-lc", root.command + " status --json"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function (exitCode) {
      var out = String(statusStdout.text || "")
      var err = String(statusStderr.text || "")
      if (exitCode === 0) {
        root.parse(out)
        if (root._refreshQueued) { root._refreshQueued = false; Qt.callLater(root.refresh) }
        return
      }
      root.servers = []
      if ((out + err).indexOf("Usage:") >= 0) {
        // The CLI resolved but predates the `status` command.
        root.sessionState = "unsupported"
        root.errorDetail = "varlatch CLI has no `status` — update it"
      } else {
        root.sessionState = "unavailable"
        root.errorDetail = err.trim() || "varlatch not found"
      }
      if (root._refreshQueued) { root._refreshQueued = false; Qt.callLater(root.refresh) }
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Panel wiring (shape contract for shell popout routing).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property real openPanelIndicatorWidth: content.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()

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

  IpcHandler {
    target: "varlatch"
    function refresh(): void { root.broadcast("refresh") }
    function refreshVersion(): void { root.broadcast("refreshVersion") }
    function verify(): void { root.verify() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function debugState(): string {
      return JSON.stringify({ sessionState: root.sessionState, servers: root.servers, pendingLogin: root.pendingLogin, cliVersion: root.cliVersion, cliInstall: root.cliInstall, latestVersion: root.latestVersion, updateAvailable: root.updateAvailable, errorDetail: root.errorDetail, opened: root.opened, hasPanel: !!panelLoader.item })
    }
  }

  readonly property string tooltipText: {
    if (sessionState === "unavailable") return "Varlatch: CLI unavailable (" + errorDetail + ")"
    if (sessionState === "unsupported") return "Varlatch: " + errorDetail
    if (sessionState === "none") return "Varlatch: no stored credentials — click to log in"
    var now = Date.now()
    var lines = []
    for (var i = 0; i < servers.length; i++) {
      var s = servers[i]
      lines.push(shortHost(s.server) + ": " + (s.state === "expired" ? "EXPIRED"
        : s.expiresAt ? remainingText(s.expiresAt, now) : "no expiry recorded"))
    }
    if (updateAvailable) lines.push("CLI " + latestVersion + " available")
    return "Varlatch\n" + lines.join("\n")
  }

  visible: sessionState !== "none" || showWhenLoggedOut
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The visual is our own Row (brand mark + label); suppress the built-in
    // label but keep the button's chrome, tooltip and click handling.
    text: ""
    hasVisualContent: true
    labelVisible: false
    fixedWidth: content.implicitWidth + button.scaledHorizontalMargin * 2
    active: root.sessionState === "warning" || root.sessionState === "expired"
    tooltipText: root.tooltipText
    onPressed: function (b) {
      // Left click: anchored panel. Middle click: the searchable menu route.
      if (b === Qt.MiddleButton) {
        if (root.bar) root.bar.run("omarchy menu summon varlatch")
        return
      }
      root.togglePanel()
    }

    // Icon-only, state told by color: theme foreground when the session is
    // healthy, amber when close to expiry, theme urgent (red) when logged
    // out, expired, or the CLI is unusable. Detail lives in the tooltip.
    readonly property color contentColor: root.sessionState === "ok" ? button.foreground
      : root.sessionState === "warning" ? "#e0993e"
      : button.activeColor
    readonly property real markSize: Math.max(12, Math.round(button.barSize * 0.5))

    Item {
      id: content
      implicitWidth: button.markSize
      implicitHeight: button.markSize
      anchors.centerIn: parent
      // Brand mark, colorized like the tray's symbolic icons (the source is
      // white-on-transparent: MultiEffect colorization preserves luminance).
      Image {
        id: markImage
        anchors.fill: parent
        source: Qt.resolvedUrl("assets/varlatch-mark-symbolic.png")
        sourceSize: Qt.size(64, 64)
        fillMode: Image.PreserveAspectFit
        smooth: true
        visible: false
      }
      MultiEffect {
        anchors.fill: markImage
        source: markImage
        colorization: 1.0
        colorizationColor: button.contentColor
        opacity: root.sessionState === "unavailable" || root.sessionState === "unsupported" ? 0.6 : 1
      }
    }
  }
}
