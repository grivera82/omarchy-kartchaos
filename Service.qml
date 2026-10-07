import QtQuick
import Quickshell
import Quickshell.Io

// Owns the single `kartchaos daemon` process. The daemon polls the game's
// server for the Daily Challenge and Time Trial boards, works out today's
// challenge, and notifies when someone passes one of your times; bar widgets
// on every monitor share this state.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string cli: String(Qt.resolvedUrl("bin/kartchaos")).replace(/^file:\/\//, "")

  property var state: ({ status: "starting" })
  property string lastError: ""
  property string linkError: ""
  property bool linkBusy: false
  property int serial: 0

  readonly property bool running: daemon.running
  readonly property string status: state.status || "starting"
  readonly property var config: state.config || ({})
  readonly property var account: state.account || null
  readonly property var pending: state.pending || null
  readonly property var daily: state.daily || null
  readonly property var tracks: state.tracks || []
  readonly property var rooms: state.rooms || []

  function send(cmd, args) {
    if (!daemon.running) return false
    daemon.write(JSON.stringify(Object.assign({ cmd: cmd, id: ++serial }, args || {})) + "\n")
    return true
  }

  function refresh() { return send("refresh") }
  function play(room) { return send("play", room ? { room: room } : {}) }
  function setConfig(key, value) { var a = {}; a[key] = value; return send("config", a) }

  // The code goes to the daemon over stdin, never on a command line.
  function checkCode(code) {
    root.linkError = ""
    root.linkBusy = send("link-check", { code: code })
  }
  function confirmLink() { root.linkError = ""; root.linkBusy = send("link") }
  function cancelLink() { root.linkError = ""; send("link-cancel") }
  function unlink() { send("unlink") }

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type === "state") {
      root.state = msg.state || {}
    } else if (msg.type === "result") {
      if (msg.cmd === "link-check" || msg.cmd === "link") {
        root.linkBusy = false
        root.linkError = msg.ok ? "" : (msg.error || "Couldn't check that code.")
      } else if (!msg.ok) {
        root.lastError = msg.error || "command failed"
        clearError.restart()
      }
    } else if (msg.type === "log" && msg.error) {
      console.warn("grivera.kartchaos:", msg.error)
    }
  }

  Process {
    id: daemon
    command: [root.cli, "daemon"]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onRunningChanged: {
      if (running) return
      root.linkBusy = false
      root.state = Object.assign({}, root.state, { status: "offline" })
      restart.restart()
    }
  }

  Timer {
    id: restart
    interval: 5000
    onTriggered: daemon.running = true
  }

  Timer {
    id: clearError
    interval: 6000
    onTriggered: root.lastError = ""
  }
}
