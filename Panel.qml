import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Kart Chaos panel. Polling, the daily-challenge rotation and "you got beaten"
// notifications live in the daemon behind Service.qml; this widget renders
// its state.
Panel {
  id: root
  moduleName: "grivera.kartchaos"
  ipcTarget: "grivera.kartchaos"

  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor("grivera.kartchaos") : null
  readonly property var st: svc ? svc.state : ({})
  readonly property var config: svc ? svc.config : ({})
  readonly property var daily: svc ? svc.daily : null
  readonly property var tracks: svc ? svc.tracks : []
  readonly property var rooms: svc ? svc.rooms : []
  readonly property var account: svc ? svc.account : null

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property color gold: "#e3b341"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property string flag: String.fromCodePoint(0xF023C)
  readonly property string kart: String.fromCodePoint(0xF0D79)
  readonly property string trophy: String.fromCodePoint(0xF0538)
  readonly property string playGlyph: String.fromCodePoint(0xF040A)
  readonly property string group: String.fromCodePoint(0xF0849)
  readonly property string timer: String.fromCodePoint(0xF051B)
  readonly property string ghost: String.fromCodePoint(0xF02A0)

  property string tab: "daily"
  property int trackPick: -1            // -1 = follow today's daily track
  property string board: "laps"
  property bool editing: false          // the player-code field has focus

  readonly property int trackIdx: trackPick >= 0 ? trackPick : (daily ? daily.track : 0)
  readonly property var track: tracks.length ? tracks[Math.min(trackIdx, tracks.length - 1)] : null
  readonly property var me: daily && daily.me ? daily.me : null
  readonly property bool linked: !!account
  // Linked and today's challenge isn't raced yet: the bar gets a dot.
  readonly property bool dailyTodo: linked && !!daily && daily.loaded && !me

  property double nowMs: Date.now()
  Timer {
    interval: root.opened ? 1000 : 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  implicitWidth: rankButton.visible ? rankButton.implicitWidth : button.implicitWidth
  implicitHeight: rankButton.visible ? rankButton.implicitHeight : button.implicitHeight

  // ---- helpers ----

  function fmtTime(t) {
    if (t === null || t === undefined || !isFinite(t)) return "--:--.---"
    t = Math.max(0, t)
    var m = Math.floor(t / 60), s = Math.floor(t % 60), ms = Math.round(t * 1000) % 1000
    return m + ":" + ("0" + s).slice(-2) + "." + ("00" + ms).slice(-3)
  }

  function countdown(ms) {
    var s = Math.max(0, Math.floor((ms - nowMs) / 1000))
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
    if (h > 0) return h + "h " + ("0" + m).slice(-2) + "m"
    if (m > 0) return m + "m"
    return s + "s"
  }

  function shortDate(ms) { return ms ? Qt.formatDate(new Date(ms), "MMM d") : "" }

  function racerLine(d) {
    if (!d) return ""
    return (d.custom ? "Your Custom racer" : d.charName) + " · " + d.kartName + " kart · " + d.cc + "cc · " + d.laps + " laps"
  }

  function summary() {
    if (!svc) return "SERVICE NOT LOADED"
    if (svc.lastError) return svc.lastError.toUpperCase()
    if (!svc.running) return "BACKEND STOPPED"
    if (st.status === "starting") return "LOADING THE BOARDS…"
    if (st.status === "offline") return "OFFLINE · CAN'T REACH KARTCHAOS.COM"
    var bits = []
    if (daily) bits.push("DAILY · " + daily.trackName.toUpperCase())
    if (me) bits.push("YOU'RE #" + me.rank)
    if (daily) bits.push("NEW IN " + countdown(daily.resetsAt).toUpperCase())
    if (st.status === "stale") bits.push("STALE")
    return bits.join("  ·  ")
  }

  function tooltip() {
    if (!daily) return "Kart Chaos"
    var lines = ["Daily: " + daily.trackName + " · " + daily.cc + "cc"]
    if (me) lines.push("You're #" + me.rank + " of " + daily.count + " · " + fmtTime(me.time))
    else if (daily.top && daily.top.length) lines.push("🏆 " + daily.top[0].name + " " + fmtTime(daily.top[0].time))
    else if (dailyTodo) lines.push("Not raced yet today")
    if (rooms.length) lines.push(rooms.length + (rooms.length === 1 ? " open room" : " open rooms"))
    lines.push("New challenge in " + countdown(daily.resetsAt))
    return lines.join("\n")
  }

  function stepTrack(dx) {
    if (!tracks.length) return
    trackPick = (trackIdx + dx + tracks.length) % tracks.length
  }

  readonly property var tabs: [
    { value: "daily", label: "Daily" },
    { value: "records", label: "Records" },
    { value: "rooms", label: rooms.length ? "Rooms · " + rooms.length : "Rooms" },
    { value: "player", label: "Player" }
  ]

  // ---- bar ----

  BarIconButton {
    id: button
    anchors.fill: parent
    visible: !rankButton.visible
    bar: root.bar
    text: root.kart
    opacity: root.st.status === "offline" ? 0.5 : 1
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton && root.svc) root.svc.play()
      else if (b === Qt.MiddleButton && root.svc) root.svc.refresh()
      else root.toggle()
    }
  }

  WidgetButton {
    id: rankButton
    anchors.fill: parent
    visible: !!root.me && root.config.barRank !== false && !(root.bar && root.bar.vertical)
    bar: root.bar
    text: root.kart + "  #" + (root.me ? root.me.rank : "")
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton && root.svc) root.svc.play()
      else if (b === Qt.MiddleButton && root.svc) root.svc.refresh()
      else root.toggle()
    }
  }

  // Today's challenge not raced yet.
  Rectangle {
    visible: root.dailyTodo
    z: 2
    width: Math.max(5, Math.round(Style.bar.iconFont * 0.42))
    height: width
    radius: width / 2
    color: Color.accent
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Math.max(0, (button.width - Style.bar.iconCanvas) / 2 - width / 3)
    anchors.topMargin: Math.max(1, (button.height - Style.bar.iconCanvas) / 2)
  }

  // ---- panel ----

  KeyboardPanel {
    id: panel
    anchorItem: rankButton.visible ? rankButton : button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    onOpenChanged: {
      if (!open) return
      root.trackPick = -1
      if (root.svc) root.svc.refresh()
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx && root.tab === "records") root.stepTrack(dx)
        if (dy) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(80)))
      }
      onTextKey: function(t) {
        if (/^[1-4]$/.test(t)) { root.tab = root.tabs[Number(t) - 1].value; flick.contentY = 0 }
        else if (t === "p" && root.svc) root.svc.play()
        else if (t === "r" && root.svc) root.svc.refresh()
        else if (t === "b" && root.tab === "records") root.board = root.board === "laps" ? "runs" : "laps"
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff; width: Style.space(4) }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Kart Chaos"
            meta: root.summary()
            detail: root.account ? "Racing as " + root.account.name : ""
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.flag
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                text: "Play"
                iconText: root.playGlyph
                tooltipText: "Open Kart Chaos (p)"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: if (root.svc) root.svc.play()
              }
            }
          }

          ButtonGroup {
            options: root.tabs
            value: root.tab
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.tab = v; flick.contentY = 0 }
          }

          Loader {
            width: parent.width
            sourceComponent: root.tab === "daily" ? dailyTab
              : root.tab === "records" ? recordsTab
              : root.tab === "rooms" ? roomsTab : playerTab
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // ================================================================ tabs

  Component {
    id: dailyTab
    Column {
      id: dailyCol
      width: parent ? parent.width : 0
      spacing: Style.space(10)
      readonly property var d: root.daily
      readonly property var rows: d && d.top ? d.top : []

      // Today's challenge
      Rectangle {
        visible: !!dailyCol.d
        width: parent.width
        height: card.implicitHeight + Style.space(28)
        radius: Style.cornerRadius
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
        border.width: 1
        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)

        Column {
          id: card
          readonly property var d: root.daily || ({})
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(14)
          spacing: Style.space(4)

          Text {
            text: "TODAY'S CHALLENGE · " + (card.d.id ? Qt.formatDate(new Date(card.d.id + "T12:00:00Z"), "ddd MMM d").toUpperCase() : "")
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          Text {
            width: parent.width
            text: card.d.trackName || ""
            elide: Text.ElideRight
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.racerLine(card.d)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            text: root.timer + "  New challenge in " + root.countdown(card.d.resetsAt || 0)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Item { width: 1; height: Style.space(6) }
          Row {
            spacing: Style.space(12)
            Button {
              text: root.me ? "Race it again" : "Race it"
              iconText: root.playGlyph
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: if (root.svc) root.svc.play()
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: !!root.me
              text: root.me ? "You're #" + root.me.rank + " · " + root.fmtTime(root.me.time) : ""
              color: root.me && root.me.rank === 1 ? root.gold : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }
      }

      PanelSectionHeader {
        text: dailyCol.d && dailyCol.d.count ? "TODAY'S BOARD · " + dailyCol.d.count + (dailyCol.d.count === 1 ? " RACER" : " RACERS") : "TODAY'S BOARD"
        foreground: root.fg
        fontFamily: root.fontFamily
      }

      Text {
        visible: !dailyCol.d || !dailyCol.d.loaded || !dailyCol.rows.length
        width: parent.width
        topPadding: Style.space(6)
        bottomPadding: Style.space(6)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: !dailyCol.d || !dailyCol.d.loaded ? (root.st.status === "offline" ? "Can't reach the server right now." : "Loading the board…")
          : "Nobody has raced today's challenge yet. Be the first!"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        Repeater {
          model: dailyCol.rows
          BoardRow {
            required property var modelData
            width: parent.width
            entry: modelData
            sub: ""
            gap: modelData.rank > 1 ? "+" + (modelData.time - dailyCol.rows[0].time).toFixed(3) : ""
          }
        }
        Text {
          visible: !!root.me && root.me.rank > dailyCol.rows.length
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "⋯"
          color: root.dim
          font.pixelSize: Style.font.body
        }
        BoardRow {
          visible: !!root.me && root.me.rank > dailyCol.rows.length
          width: parent.width
          entry: root.me ? { rank: root.me.rank, name: root.account ? root.account.name : "You", time: root.me.time, mine: true } : ({})
          sub: ""
          gap: root.me && dailyCol.rows.length ? "+" + (root.me.time - dailyCol.rows[0].time).toFixed(3) : ""
        }
      }

      Text {
        readonly property var prev: dailyCol.d && dailyCol.d.prev ? dailyCol.d.prev : []
        visible: prev.length > 0
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Yesterday's podium:  " + prev.map(function(e, i) { return ["🥇", "🥈", "🥉"][i] + " " + e.name + " " + root.fmtTime(e.time) }).join("   ")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: !root.linked
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Link your player code in the Player tab to see your rank and hear when someone passes you."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = "player" }
      }
    }
  }

  Component {
    id: recordsTab
    Column {
      id: recordsCol
      width: parent ? parent.width : 0
      spacing: Style.space(10)
      readonly property var list: root.track ? (root.board === "laps" ? root.track.laps : root.track.runs) : []

      Item {
        width: parent.width
        height: prevBtn.implicitHeight

        Button {
          id: prevBtn
          anchors.left: parent.left
          text: "‹"
          tooltipText: "Previous track (h)"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.stepTrack(-1)
        }
        Column {
          anchors.centerIn: parent
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.track ? root.track.name : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !!root.daily && root.trackIdx === root.daily.track
            text: "TODAY'S DAILY TRACK"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }
        }
        Button {
          anchors.right: parent.right
          text: "›"
          tooltipText: "Next track (l)"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.stepTrack(1)
        }
      }

      ButtonGroup {
        options: [{ value: "laps", label: "Fastest lap" }, { value: "runs", label: "Full race" }]
        value: root.board
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(v) { root.board = v }
      }

      Text {
        visible: root.linked && !!root.track
        width: parent.width
        wrapMode: Text.WordWrap
        text: {
          var t = root.track
          if (!t) return ""
          var bits = []
          if (t.myLap) bits.push("lap #" + t.myLap.rank + " " + root.fmtTime(t.myLap.time))
          if (t.myRun) bits.push("race #" + t.myRun.rank + " " + root.fmtTime(t.myRun.time))
          return bits.length ? "You: " + bits.join(" · ") : "You're not on this track's boards yet."
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: recordsCol.list.length === 0
        width: parent.width
        topPadding: Style.space(10)
        bottomPadding: Style.space(10)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.st.status === "starting" ? "Loading the boards…"
          : "No " + (root.board === "laps" ? "laps" : "races") + " yet on this track. Be the first!"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        Repeater {
          model: recordsCol.list
          BoardRow {
            required property var modelData
            width: parent.width
            entry: modelData
            sub: [modelData.charName, modelData.kartName, root.shortDate(modelData.at)].filter(function(x) { return !!x }).join(" · ")
          }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: (root.board === "laps" ? "Each racer's best lap in Time Trial." : "Each racer's best 3-lap Time Trial.") + "  " + root.ghost + " = the record ghost you can race."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: roomsTab
    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(8)

      Column {
        visible: root.rooms.length === 0
        width: parent.width
        topPadding: Style.space(14)
        bottomPadding: Style.space(14)
        spacing: Style.space(10)
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.group
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "No open rooms right now. Start one from Online in the game and invite friends."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Repeater {
        model: root.rooms
        Item {
          id: roomRow
          required property var modelData
          readonly property bool full: modelData.players >= 8
          width: parent.width
          height: Math.max(joinBtn.implicitHeight, roomCol.implicitHeight) + Style.space(12)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
            border.width: 1
            border.color: root.faint
          }
          Text {
            id: codeText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: roomRow.modelData.code
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            font.letterSpacing: 2
          }
          Column {
            id: roomCol
            anchors.left: codeText.right
            anchors.leftMargin: Style.space(14)
            anchors.right: joinBtn.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              text: roomRow.modelData.host + "'s room"
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              text: roomRow.modelData.players + "/8 · " + (roomRow.modelData.racing ? "racing" : "in lobby")
              color: roomRow.modelData.racing ? root.dim : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Button {
            id: joinBtn
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: roomRow.full ? "Full" : "Join"
            bordered: true
            opacity: roomRow.full ? 0.5 : 1
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (!roomRow.full && root.svc) root.svc.play(roomRow.modelData.code)
          }
        }
      }
    }
  }

  Component {
    id: playerTab
    Column {
      id: playerCol
      width: parent ? parent.width : 0
      spacing: Style.space(10)
      readonly property var pending: root.svc ? root.svc.pending : null

      // Linked
      Rectangle {
        visible: root.linked
        width: parent.width
        height: Style.space(64)
        radius: Style.cornerRadius
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
        border.width: 1
        border.color: root.faint
        Column {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          Text {
            text: root.account ? root.account.name : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            text: root.account && root.account.charName ? "Racer: " + root.account.charName : "Linked"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Button {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: "Unlink"
          tooltipText: "Forget this player on this computer. Your times stay in the game."
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: if (root.svc) root.svc.unlink()
        }
      }

      Text {
        visible: root.linked && root.account.loaded && !root.account.onBoards
        width: parent.width
        wrapMode: Text.WordWrap
        text: "None of " + (root.account ? root.account.name : "this player") + "'s times are on the boards. If you race on another phone or browser, that device may be a different player: copy the code from Settings there, then Unlink and paste it here."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Not linked: paste a code
      Text {
        visible: !root.linked
        width: parent.width
        wrapMode: Text.WordWrap
        text: "In Kart Chaos, open ⚙️ Settings and copy your player code (or its link), then paste it here. The plugin uses it to mark your times and tell you when someone beats them. It only reads the boards: it never races, posts times or shows you online."
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Row {
        visible: !root.linked && !playerCol.pending
        width: parent.width
        spacing: Style.space(8)
        TextField {
          id: codeField
          width: parent.width - linkBtn.width - parent.spacing
          placeholderText: "XXXX-XXXX-XXXX"
          foreground: root.fg
          font.family: root.fontFamily
          onActiveFocusChanged: root.editing = activeFocus
          onAccepted: if (root.svc && text) root.svc.checkCode(text)
          Keys.onEscapePressed: { focus = false; keyCatcher.forceActiveFocus() }
          Component.onDestruction: root.editing = false
        }
        Button {
          id: linkBtn
          text: root.svc && root.svc.linkBusy ? "Checking…" : "Link"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: if (root.svc && codeField.text) root.svc.checkCode(codeField.text)
        }
      }

      Column {
        visible: !root.linked && !!playerCol.pending
        width: parent.width
        spacing: Style.space(8)
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: playerCol.pending ? "Play as " + playerCol.pending.name + (playerCol.pending.charName ? " (" + playerCol.pending.charName + ")" : "") + " here?" : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Row {
          spacing: Style.space(8)
          Button {
            text: playerCol.pending ? "Yes, I'm " + playerCol.pending.name : "Yes"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.svc) root.svc.confirmLink()
          }
          Button {
            text: "Cancel"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: if (root.svc) root.svc.cancelLink()
          }
        }
      }

      Text {
        visible: !!root.svc && root.svc.linkError !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.svc ? root.svc.linkError : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { foreground: root.fg }
      PanelSectionHeader { text: "SETTINGS"; foreground: root.fg; fontFamily: root.fontFamily }

      SettingToggle { key: "notifyRecords"; label: "Record alerts"; description: "When someone passes one of your Time Trial times." }
      SettingToggle { key: "notifyDaily"; label: "Daily Challenge alerts"; description: "When someone passes you on today's board." }
      SettingToggle { key: "barRank"; label: "Daily rank in the bar"; description: "Shows your place on today's board next to the flag." }

      Row {
        spacing: Style.space(8)
        Button {
          text: "Test notification"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: if (root.svc) root.svc.send("test")
        }
        Button {
          text: "Refresh"
          tooltipText: "Fetch the boards now (r)"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          bordered: true
          onClicked: if (root.svc) root.svc.refresh()
        }
      }
    }
  }

  // ================================================================ pieces

  component SettingToggle: Toggle {
    property string key: ""
    width: parent ? parent.width : 0
    foreground: root.fg
    fontFamily: root.fontFamily
    checked: root.config[key] !== false
    onClicked: if (root.svc) root.svc.setConfig(key, !checked)
  }

  component BoardRow: Item {
    id: brow
    property var entry: ({})
    property string sub: ""
    property string gap: ""
    readonly property bool mine: !!entry.mine
    implicitHeight: Math.max(Style.space(30), nameCol.implicitHeight + Style.space(8))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: brow.mine ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : "transparent"
    }
    Rectangle {
      visible: brow.mine
      width: Style.space(3)
      height: parent.height - Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      radius: width / 2
      color: Color.accent
    }

    Text {
      id: rankText
      width: Style.space(34)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: brow.entry.rank === 1 ? root.trophy : "#" + brow.entry.rank
      color: brow.entry.rank === 1 ? root.gold : root.dim
      font.family: root.fontFamily
      font.pixelSize: brow.entry.rank === 1 ? Style.font.body * 1.15 : Style.font.caption
      font.bold: true
    }
    Column {
      id: nameCol
      anchors.left: rankText.right
      anchors.right: timeCol.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: brow.entry.name + (brow.entry.ghost ? "  " + root.ghost : "")
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: brow.mine
      }
      Text {
        visible: brow.sub !== ""
        width: parent.width
        text: brow.sub
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Column {
      id: timeCol
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      Text {
        anchors.right: parent.right
        text: root.fmtTime(brow.entry.time)
        color: brow.mine ? Color.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        anchors.right: parent.right
        visible: brow.gap !== ""
        text: brow.gap
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
