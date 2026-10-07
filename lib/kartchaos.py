#!/usr/bin/env python3
"""Kart Chaos companion for the grivera.kartchaos Omarchy plugin: today's Daily
Challenge, the Time Trial boards, open online rooms, and a notification when
someone passes one of your times.

Everything comes from the game's own server (wss://kartchaos.com/ws), the same
one-off requests the game makes for its boards. Linking your player code lets
the plugin mark your entries; it never races, posts times or shows you online.

Standard library only.

  kartchaos status [--json]   today's challenge and your ranks
  kartchaos daily             one line: today's challenge and your rank
  kartchaos daemon            JSON state lines on stdout, commands on stdin
"""

import base64
import datetime
import json
import os
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.request

HOST = "kartchaos.com"
GAME_URL = "https://kartchaos.com/"
WS_PATH = "/ws"
UA = "grivera-kartchaos/1.0"

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "grivera-kartchaos")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "grivera-kartchaos")
ACCOUNT_FILE = os.path.join(STATE_DIR, "account.json")
CONFIG_FILE = os.path.join(STATE_DIR, "config.json")
RANKS_FILE = os.path.join(STATE_DIR, "ranks.json")
GAME_FILE = os.path.join(CACHE_DIR, "game.json")
LIB = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(LIB), "assets")

DEFAULT_CONFIG = {
    "notifyRecords": True,   # someone passed you on a Time Trial board
    "notifyDaily": True,     # someone passed you on today's Daily Challenge
    "barRank": True,         # your daily rank next to the bar icon
}

POLL = 180          # seconds between polls
RETRY = 60          # after a failed poll
SYNC_EVERY = 3600   # refresh the linked player's name
DAY_MS = 86400000

# The game's tables as of its 2026-09-28 release. refresh_game() re-reads them
# from the live site once a day, so new tracks and daily eras show up without
# a plugin update; these are the fallback.
BUILTIN_GAME = {
    "tracks": ["Chamo Circuit", "Cactus Canyon", "Snowy Peak", "Sunshine Beach", "Neon Nights",
               "Mars Aliens", "Miami Vice", "Zoo City"],
    "chars": ["Chamo", "Momo", "Bao", "Lucas", "Bumblebee", "Chicky", "Dorito", "Custom"],
    "karts": ["Classic", "Bullet", "Buggy"],
    "charCount": 8,
    "kartCount": 3,
    "ccChoices": [100, 150, 150, 200],
    "dailyLaps": 3,
    "eras": [[None, 5, 101], ["2026-09-27", 6, 202], ["2026-09-28", 8, 303]],
}


# ---------------------------------------------------------------- helpers

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data, private=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600 if private else 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def fmt_time(t):
    if t is None:
        return "--:--.---"
    t = max(0.0, float(t))
    return "%d:%02d.%03d" % (t // 60, int(t % 60), int(round(t * 1000)) % 1000)


def http_get(url, timeout=12):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def open_game(fragment=""):
    url = GAME_URL + (("#" + fragment) if fragment else "")
    for cmd in (["omarchy-launch-webapp", url], ["xdg-open", url]):
        if shutil.which(cmd[0]):
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return True
    return False


# ---------------------------------------------------------------- websocket

class WebSocket:
    """Just enough of RFC 6455 for the game's JSON text frames."""

    def __init__(self, timeout=10):
        raw = socket.create_connection((HOST, 443), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=HOST)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: https://%s\r\n"
            "User-Agent: %s\r\n\r\n" % (WS_PATH, HOST, key, HOST, UA)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed during handshake")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0] + b" ":
            raise ConnectionError("handshake refused: %s" % head.split(b"\r\n", 1)[0].decode(errors="replace"))

    def _frame(self, opcode, data):
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            head = struct.pack(">BB", 0x80 | opcode, 0x80 | n)
        elif n < 65536:
            head = struct.pack(">BBH", 0x80 | opcode, 0x80 | 126, n)
        else:
            head = struct.pack(">BBQ", 0x80 | opcode, 0x80 | 127, n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))

    def send(self, obj):
        self._frame(1, json.dumps(obj, separators=(",", ":")).encode())

    def _read(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.time()
            if left <= 0:
                raise TimeoutError
            self.sock.settimeout(left)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self, deadline):
        """The next JSON message, or None at the deadline."""
        parts = []
        try:
            while True:
                b0, b1 = self._read(2, deadline)
                n = b1 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", self._read(2, deadline))[0]
                elif n == 127:
                    n = struct.unpack(">Q", self._read(8, deadline))[0]
                mask = self._read(4, deadline) if b1 & 0x80 else None
                data = self._read(n, deadline)
                if mask:
                    data = bytes(b ^ mask[i & 3] for i, b in enumerate(data))
                op = b0 & 0x0F
                if op == 8:
                    raise ConnectionError("closed")
                if op == 9:
                    self._frame(10, data)
                    continue
                if op in (0, 1):
                    parts.append(data)
                    if b0 & 0x80:
                        try:
                            return json.loads(b"".join(parts))
                        except ValueError:
                            parts = []
        except (TimeoutError, socket.timeout):
            return None

    def close(self):
        try:
            self._frame(8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def exchange(requests, want, timeout=10):
    """Send each request once the server says welcome; return {type: reply}
    for the reply types in `want` (plus any `rooms` broadcast)."""
    ws = WebSocket(timeout)
    got = {}
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            m = ws.recv(deadline)
            if m is None:
                break
            t = m.get("t")
            if t == "welcome":
                for r in requests:
                    ws.send(r)
            elif t in want or t == "rooms":
                got[t] = m
                if all(w in got for w in want) and "rooms" in got:
                    break
    finally:
        ws.close()
    missing = [w for w in want if w not in got]
    if missing:
        raise TimeoutError("no %s reply" % "/".join(missing))
    return got


# ---------------------------------------------------------------- game tables

def parse_game(data_js, daily_js):
    def names(block):
        return re.findall(r'^\s*(?:\{\s*)?name:\s*"([^"]+)"', block, re.M)

    def between(src, start, end):
        i = src.index(start)
        j = src.index(end, i)
        return src[i:j]

    tracks = names(between(data_js, "export const TRACKS", "export const BETA_BASE"))
    chars = names(between(data_js, "export const CHARACTERS", "export const KARTS"))
    karts = names(between(data_js, "export const KARTS", "export const CC"))
    num = lambda pat: int(re.search(pat, daily_js).group(1))
    eras = []
    for frm, day, count, seed in re.findall(
            r'\{\s*from:\s*(-Infinity|dayNumber\("(\d{4}-\d{2}-\d{2})"\)),\s*count:\s*(\d+),\s*seed:\s*(\d+)\s*\}', daily_js):
        eras.append([day or None, int(count), int(seed)])
    game = {
        "tracks": tracks, "chars": chars, "karts": karts,
        "charCount": num(r"CHAR_COUNT\s*=\s*(\d+)"),
        "kartCount": num(r"KART_COUNT\s*=\s*(\d+)"),
        "ccChoices": [int(x) for x in re.search(r"CC_CHOICES\s*=\s*\[([\d,\s]+)\]", daily_js).group(1).split(",")],
        "dailyLaps": num(r"DAILY_LAPS\s*=\s*(\d+)"),
        "eras": eras,
    }
    if not eras or eras[0][0] is not None or len(chars) < game["charCount"] or len(karts) < game["kartCount"]:
        raise ValueError("unexpected game tables")
    if max(e[1] for e in eras) > len(tracks):
        raise ValueError("daily rotation has more tracks than the track list")
    return game


def refresh_game():
    main = http_get(GAME_URL + "js/main.js")

    def ver(mod):   # main.js imports e.g. "./data.js?v=20"; ask for the same build
        m = re.search(r'\./%s\.js(\?v=\d+)?"' % mod, main)
        return (m and m.group(1)) or ""
    game = parse_game(http_get(GAME_URL + "js/data.js" + ver("data")), http_get(GAME_URL + "js/daily.js" + ver("daily")))
    game["at"] = time.time()
    save_json(GAME_FILE, game)
    return game


def load_game():
    game = load_json(GAME_FILE, None)
    return game if isinstance(game, dict) and game.get("eras") else dict(BUILTIN_GAME, at=0)


# ---------------------------------------------------------------- daily challenge
# A straight port of the game's js/daily.js (mulberry32 + era rotation), so the
# plugin knows the track, racer, kart and class without racing.

U32 = 0xFFFFFFFF


def imul(a, b):
    return ((a & U32) * (b & U32)) & U32


def rng(seed):
    a = [seed & U32]

    def nxt():
        a[0] = (a[0] + 0x6D2B79F5) & U32
        t = a[0]
        t = imul(t ^ (t >> 15), t | 1)
        t = (t ^ ((t + imul(t ^ (t >> 7), t | 61)) & U32)) & U32
        return ((t ^ (t >> 14)) & U32) / 4294967296
    return nxt


def day_number(day_id):
    return (datetime.date(*(int(x) for x in day_id.split("-"))) - datetime.date(1970, 1, 1)).days


def daily_id(ms=None):
    ms = time.time() * 1000 if ms is None else ms
    return time.strftime("%Y-%m-%d", time.gmtime(ms / 1000))


def track_order(block, count, seed):
    r = rng(block * 7919 + seed)
    order = list(range(count))
    for i in range(count - 1, 0, -1):
        j = int(r() * (i + 1))
        order[i], order[j] = order[j], order[i]
    return order


def track_for(day, eras):
    era = len(eras) - 1
    while era > 0 and day < eras[era][0]:
        era -= 1
    frm, count, seed = eras[era]
    d = day if era == 0 else day - frm
    block = d // count
    order = track_order(block, count, seed)
    prev = track_for(frm - 1, eras) if era > 0 and block == 0 else track_order(block - 1, count, seed)[count - 1]
    if order[0] == prev:
        order[0], order[1] = order[1], order[0]
    return order[d - block * count]


def daily_challenge(game, day_id_=None):
    day_id_ = day_id_ or daily_id()
    day = day_number(day_id_)
    eras = [[None if e[0] is None else day_number(e[0]), e[1], e[2]] for e in game["eras"]]
    r = rng(imul(day, 2654435761) ^ 0x5EED)
    cc = game["ccChoices"]
    return {
        "id": day_id_,
        "track": track_for(day, eras),
        "char": int(r() * game["charCount"]),
        "kart": int(r() * game["kartCount"]),
        "cc": cc[int(r() * len(cc))],
        "laps": game["dailyLaps"],
    }


# ---------------------------------------------------------------- engine

def board_at(records, kind, i):
    boards = records.get(kind) or []
    return (boards[i] if i < len(boards) else None) or []


def name_of(table, i, fallback="?"):
    return table[i] if isinstance(i, int) and 0 <= i < len(table) else fallback


class Notifier:
    def send(self, key, summary, body, fragment=""):
        if not shutil.which("notify-send"):
            return
        icon = os.path.join(ASSETS, "kartchaos.svg")
        args = ["notify-send", "-a", "Kart Chaos", "-i", icon, "-h", "string:x-grivera-kartchaos:" + key,
                "-w", "-A", "default=Race", summary, body]

        def run():
            try:
                out = subprocess.run(args, capture_output=True, text=True, timeout=3600).stdout.strip()
                if out == "default":
                    open_game(fragment)
            except (OSError, subprocess.SubprocessError):
                pass

        threading.Thread(target=run, daemon=True).start()


class Engine:
    def __init__(self, emit=None):
        self.emit = emit
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.config = dict(DEFAULT_CONFIG, **load_json(CONFIG_FILE, {}))
        self.account = load_json(ACCOUNT_FILE, {}) or {}
        self.ranks = load_json(RANKS_FILE, {})
        self.game = load_game()
        self.notifier = Notifier()
        self.daily = None      # server reply for today
        self.records = None
        self.rooms = []
        self.status = "starting"
        self.error = ""
        self.updated = 0
        self.synced = 0
        self.pending = None    # {code, name, char} while confirming a link

    # ---- account

    def device(self):
        """An anonymous id for reading the boards while no player is linked."""
        if not self.account.get("device"):
            self.account["device"] = os.urandom(12).hex()
            save_json(ACCOUNT_FILE, self.account, private=True)
        return self.account["device"]

    def pid(self):
        return self.account.get("pid") or self.device()

    def linked(self):
        return bool(self.account.get("pid"))

    @staticmethod
    def clean_code(code):
        code = re.sub(r"[^0-9A-Z]", "", str(code or "").upper())
        # Accept a pasted player link too: .../#player=XXXX-XXXX-XXXX
        return code[-12:] if len(code) >= 12 else code

    def link_check(self, code):
        code = self.clean_code(code)
        if len(code) != 12:
            return False, "A player code has 12 letters and numbers."
        # Linking merges the asking id into the code's player, and the server keeps an alias
        # from it afterwards. A brand-new id per attempt means a link can never merge another
        # player (say, one this plugin linked to before) into the one being linked.
        fresh = os.urandom(12).hex()
        m = exchange([{"t": "acct-check", "pid": fresh, "code": code}], ["account"])["account"]
        if not m.get("ok"):
            return False, ("Too many tries. Wait a few minutes." if m.get("error") == "slow"
                           else "That code doesn't exist.")
        self.pending = {"code": code, "device": fresh, "name": m.get("name") or "?", "char": m.get("char")}
        return True, None

    def link(self):
        p = self.pending
        if not p:
            return False, "Check a code first."
        m = exchange([{"t": "acct-link", "pid": p["device"], "code": p["code"]}], ["account"])["account"]
        if not m.get("ok") or not m.get("pid"):
            return False, "Couldn't link right now. Try again in a bit."
        prof = m.get("profile") or {}
        self.account.update({"pid": m["pid"], "name": prof.get("name") or p["name"],
                             "char": prof.get("char", p["char"]), "linkedAt": int(time.time())})
        save_json(ACCOUNT_FILE, self.account, private=True)
        self.pending = None
        self.ranks = {}          # new baseline: no notifications for old changes
        save_json(RANKS_FILE, self.ranks)
        self.synced = time.time()
        return True, None

    def unlink(self):
        self.account = {}
        save_json(ACCOUNT_FILE, self.account, private=True)
        self.ranks = {}
        save_json(RANKS_FILE, self.ranks)
        self.pending = None

    def sync_account(self):
        """Pick up a new name or a merged id from the player's other devices."""
        m = exchange([{"t": "acct-sync", "pid": self.account["pid"]}], ["account"])["account"]
        self.synced = time.time()
        if not m.get("ok"):
            return
        changed = False
        if m.get("pid") and m["pid"] != self.account["pid"]:
            self.account["pid"] = m["pid"]
            changed = True
        prof = m.get("profile") or {}
        for k in ("name", "char"):
            if prof.get(k) is not None and prof[k] != self.account.get(k):
                self.account[k] = prof[k]
                changed = True
        if changed:
            save_json(ACCOUNT_FILE, self.account, private=True)

    # ---- polling

    def poll(self):
        if time.time() - (self.game.get("at") or 0) > 86400:
            try:
                self.game = refresh_game()
            except Exception as exc:          # keep the last good tables
                self.game["at"] = time.time() - 86400 + 3600
                if self.emit:
                    self.emit({"type": "log", "error": "game tables: %r" % exc})
        if self.linked() and time.time() - self.synced > SYNC_EVERY:
            try:
                self.sync_account()
            except Exception:
                pass
        pid = self.pid()
        got = exchange([{"t": "daily", "pid": pid}, {"t": "records", "pid": pid}], ["daily", "records"])
        with self.lock:
            self.daily = got["daily"]
            self.records = got["records"]
            self.rooms = (got.get("rooms") or {}).get("list") or []
            self.updated = time.time()
            self.status, self.error = "ok", ""
        if self.linked():
            self.check_ranks()

    # ---- rank changes

    def boards(self):
        """{key: (label, entries, fragment)} for every board you can be on."""
        out = {}
        rec = self.records or {}
        for kind in ("laps", "runs"):
            for i, board in enumerate(rec.get(kind) or []):
                out["%s:%d" % (kind, i)] = (kind, i, board or [])
        return out

    def check_ranks(self):
        new = {}
        events = []
        tracks = self.game["tracks"]
        for key, (kind, i, board) in self.boards().items():
            mine = next((n for n, e in enumerate(board) if e.get("mine")), None)
            entry = {"rank": None if mine is None else mine + 1,
                     "time": None if mine is None else board[mine].get("time"),
                     "top": [[e.get("name"), e.get("time")] for e in board]}
            new[key] = entry
            old = self.ranks.get(key)
            if not old or old.get("rank") is None:
                continue
            if entry["rank"] is not None and entry["rank"] <= old["rank"]:
                continue
            seen = {tuple(x) for x in old.get("top") or []}
            limit = entry["rank"] - 1 if entry["rank"] else len(board)
            by = [e for e in board[:limit] if (e.get("name"), e.get("time")) not in seen]
            if not by:
                continue
            what = "lap" if kind == "laps" else "3-lap"
            where = name_of(tracks, i, "a track")
            who = by[0].get("name") or "Someone"
            if len(by) > 1:
                who += " and %d more" % (len(by) - 1)
            head = ("%s took your %s record on %s" % (who, what, where) if old["rank"] == 1
                    else "%s passed your %s time on %s" % (who, what, where))
            body = "#%d → %s · 🏆 %s %s · You %s" % (
                old["rank"], "#%d" % entry["rank"] if entry["rank"] else "off the board",
                fmt_time(board[0].get("time")), board[0].get("name"), fmt_time(old.get("time")))
            events.append(("records", key, head, body))

        d = self.daily or {}
        if d.get("day"):
            key = "daily:" + d["day"]
            me = d.get("me") or {}
            top = d.get("top") or []
            entry = {"rank": me.get("rank"), "time": me.get("time"),
                     "top": [[e.get("name"), e.get("time")] for e in top]}
            new[key] = entry
            old = self.ranks.get(key)
            if old and old.get("rank") and entry["rank"] and entry["rank"] > old["rank"]:
                seen = {tuple(x) for x in old.get("top") or []}
                by = [e for e in top[:entry["rank"] - 1] if (e.get("name"), e.get("time")) not in seen]
                who = by[0].get("name") if by else "Someone"
                if len(by) > 1:
                    who += " and %d more" % (len(by) - 1)
                ch = daily_challenge(self.game, d["day"])
                head = ("%s took the lead in today's Daily Challenge" % who if old["rank"] == 1
                        else "%s passed you in today's Daily Challenge" % who)
                body = "%s · #%d → #%d · You %s" % (name_of(self.game["tracks"], ch["track"]), old["rank"],
                                                    entry["rank"], fmt_time(entry["time"]))
                events.append(("daily", key, head, body))

        # Keep yesterday's daily entry out of the file
        self.ranks = new
        save_json(RANKS_FILE, self.ranks)
        for kind, key, head, body in events:
            if self.config["notifyRecords" if kind == "records" else "notifyDaily"]:
                self.notifier.send(key, head, body)

    # ---- state

    def entry(self, e, rank):
        return {"rank": rank, "name": e.get("name") or "?", "time": e.get("time"),
                "char": e.get("char"), "charName": name_of(self.game["chars"], e.get("char"), ""),
                "kartName": name_of(self.game["karts"], e.get("kart"), ""),
                "at": e.get("at"), "mine": bool(e.get("mine")), "ghost": bool(e.get("ghost"))}

    def snapshot(self):
        with self.lock:
            game = self.game
            now_ms = time.time() * 1000
            ch = daily_challenge(game)
            d = self.daily if (self.daily or {}).get("day") == ch["id"] else None
            daily = dict(ch, trackName=name_of(game["tracks"], ch["track"]),
                         charName=name_of(game["chars"], ch["char"]), kartName=name_of(game["karts"], ch["kart"]),
                         custom=ch["char"] == len(game["chars"]) - 1 and game["chars"][-1] == "Custom",
                         resetsAt=int(now_ms + DAY_MS - now_ms % DAY_MS),
                         loaded=d is not None, count=(d or {}).get("count", 0),
                         top=[self.entry(dict(e, char=ch["char"], kart=ch["kart"]), n + 1)
                              for n, e in enumerate((d or {}).get("top") or [])],
                         me=(d or {}).get("me"),
                         prev=[{"name": e.get("name"), "time": e.get("time")}
                               for e in (((d or {}).get("prev") or {}).get("top") or [])])
            tracks = []
            rec = self.records or {}
            for i, tname in enumerate(game["tracks"]):
                laps = [self.entry(e, n + 1) for n, e in enumerate(board_at(rec, "laps", i))]
                runs = [self.entry(e, n + 1) for n, e in enumerate(board_at(rec, "runs", i))]
                tracks.append({"index": i, "name": tname, "laps": laps, "runs": runs,
                               "myLap": next((e for e in laps if e["mine"]), None),
                               "myRun": next((e for e in runs if e["mine"]), None)})
            acct = None
            if self.linked():
                acct = {"name": self.account.get("name") or "?", "char": self.account.get("char"),
                        "charName": name_of(game["chars"], self.account.get("char"), ""),
                        "onBoards": bool((d or {}).get("me")) or any(t["myLap"] or t["myRun"] for t in tracks),
                        "loaded": self.records is not None}
            pending = None
            if self.pending:
                pending = {"name": self.pending["name"], "charName": name_of(game["chars"], self.pending["char"], "")}
            status = self.status
            if status == "offline" and self.updated:
                status = "stale"
            return {
                "status": status, "error": self.error, "updatedAt": int(self.updated * 1000),
                "account": acct, "pending": pending, "config": self.config,
                "daily": daily, "tracks": tracks,
                "rooms": [{"code": r.get("code"), "host": r.get("host"), "players": r.get("players", 0),
                           "racing": r.get("state") == "racing"} for r in self.rooms if r.get("code")],
                "gameUrl": GAME_URL,
            }

    def set_config(self, msg):
        for key, default in DEFAULT_CONFIG.items():
            if key in msg:
                self.config[key] = bool(msg[key]) if isinstance(default, bool) else msg[key]
        save_json(CONFIG_FILE, self.config)


# ---------------------------------------------------------------- daemon

def daemon():
    out_lock = threading.Lock()

    def emit(obj):
        with out_lock:
            try:
                sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                os._exit(0)

    engine = Engine(emit)
    last = [None]

    def publish():
        blob = json.dumps(engine.snapshot(), sort_keys=True)
        if blob != last[0]:
            last[0] = blob
            emit({"type": "state", "state": json.loads(blob)})

    def loop():
        publish()
        while True:
            wait = POLL
            try:
                engine.poll()
            except Exception as exc:     # network or a protocol change: keep the bar alive
                with engine.lock:
                    engine.status, engine.error = "offline", str(exc) or exc.__class__.__name__
                wait = RETRY
            publish()
            engine.wake.wait(wait)
            engine.wake.clear()

    threading.Thread(target=loop, daemon=True).start()

    # A day rollover changes the challenge with no poll needed; tick the snapshot.
    def ticker():
        while True:
            time.sleep(30)
            try:
                publish()
            except Exception:
                pass
    threading.Thread(target=ticker, daemon=True).start()

    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        cmd, ok, err = msg.get("cmd"), True, None
        try:
            if cmd == "refresh":
                engine.wake.set()
            elif cmd == "play":
                room = str(msg.get("room") or "")
                frag = ("room=" + room) if re.fullmatch(r"[A-Za-z]{4}", room) else ""
                ok = open_game(frag)
                err = None if ok else "no browser launcher found"
            elif cmd == "link-check":
                ok, err = engine.link_check(msg.get("code"))
            elif cmd == "link-cancel":
                engine.pending = None
            elif cmd == "link":
                ok, err = engine.link()
                engine.wake.set()
            elif cmd == "unlink":
                engine.unlink()
                engine.wake.set()
            elif cmd == "config":
                engine.set_config(msg)
            elif cmd == "test":
                engine.notifier.send("test", "Zoe passed your lap time on Zoo City",
                                     "#2 → #3 · 🏆 0:24.910 Zoe · You 0:25.383")
            else:
                ok, err = False, "unknown command"
        except Exception as exc:
            ok, err = False, "Can't reach the server right now. Try again in a bit." if isinstance(
                exc, (OSError, TimeoutError)) else str(exc)
        publish()
        emit({"type": "result", "id": msg.get("id"), "cmd": cmd, "ok": ok, "error": err})


# ---------------------------------------------------------------- CLI

def cli_state():
    engine = Engine()
    engine.poll()
    return engine.snapshot()


def daily_line(state):
    d = state["daily"]
    racer = "your Custom racer" if d["custom"] else d["charName"]
    line = "Daily: %s · %s · %s · %dcc" % (d["trackName"], racer, d["kartName"], d["cc"])
    if d.get("me"):
        line += " · you're #%d (%s)" % (d["me"]["rank"], fmt_time(d["me"]["time"]))
    elif d["top"]:
        line += " · 🏆 %s %s" % (fmt_time(d["top"][0]["time"]), d["top"][0]["name"])
    return line


def print_status(state):
    print(daily_line(state))
    left = (state["daily"]["resetsAt"] - time.time() * 1000) / 60000
    print("New challenge in %dh %02dm · %d racing today" % (left // 60, left % 60, state["daily"]["count"]))
    if state["account"]:
        print("\nYour Time Trial ranks (%s)" % state["account"]["name"])
        for t in state["tracks"]:
            bits = []
            if t["myLap"]:
                bits.append("lap #%d %s" % (t["myLap"]["rank"], fmt_time(t["myLap"]["time"])))
            if t["myRun"]:
                bits.append("race #%d %s" % (t["myRun"]["rank"], fmt_time(t["myRun"]["time"])))
            if bits:
                print("  %-16s %s" % (t["name"], " · ".join(bits)))
    else:
        print("\nNot linked: paste your player code in the bar panel to see your ranks.")
    if state["rooms"]:
        print("\nOpen rooms")
        for r in state["rooms"]:
            print("  %s  %s's room · %d/8 · %s" % (r["code"], r["host"], r["players"], "racing" if r["racing"] else "in lobby"))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "daemon":
        daemon()
    elif cmd == "status":
        state = cli_state()
        if "--json" in argv:
            print(json.dumps(state, indent=2))
        else:
            print_status(state)
    elif cmd == "daily":
        print(daily_line(cli_state()))
    else:
        print(__doc__.strip())
        return 0 if cmd in ("-h", "--help", "help") else 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
