#!/usr/bin/env python3
"""claude-account ui — the full-screen view.

It never edits a file itself. Everything it shows comes from `claude-account _ui-state`
and `_ui-usage`, and every change it makes runs the same `claude-account <verb>` you could
type, so the CLI's own guards (the map lock, the backups, the refusals) apply here too and
there is one writer. Python 3.9 compatible on purpose: it is what macOS ships.
"""
import curses
import datetime
import json
import locale
import os
import re
import subprocess
import sys
import threading
import time

CA = os.environ.get("CA_SELF", "")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
HOME = os.path.expanduser("~")
SORTS = ["your order", "most weekly left", "most 5h left", "sign-in ends first", "name"]
GLOBAL = "(global)"
# curses draws ▶ ─ █ only in a UTF-8 locale; anywhere else they become garbage, so the
# view falls back to plain ASCII instead (main() decides).
ASCII = False
ASCII_MAP = {ord("▶"): ">", ord("●"): "*", ord("─"): "-", ord("└"): "`", ord("█"): "#", ord("░"): ".",
             ord("⚠"): "!", ord("＋"): "+", ord("↑"): "^", ord("↓"): "v", ord("⏎"): "enter", ord("→"): "->",
             ord("←"): "<-", ord("…"): "...", ord("—"): "-", ord("·"): "-", ord("⇧"): "shift+"}


def tilde(p):
    return "~" + p[len(HOME):] if p == HOME or p.startswith(HOME + "/") else p


def ca(args, timeout=120):
    """Run the CLI with no terminal and capture what it says. NO_COLOR keeps it plain;
    stdin is /dev/null so nothing it runs can sit waiting for an answer."""
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    try:
        p = subprocess.run(["bash", CA] + list(args), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                           timeout=timeout)
        return p.returncode, ANSI.sub("", p.stdout.decode("utf-8", "replace")).rstrip("\n")
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ds: claude-account %s" % (timeout, " ".join(args))


def target(acct):
    """The word the CLI takes for an account: the profile name, or `global`."""
    return "global" if acct == GLOBAL else acct


class Model(object):
    def __init__(self):
        self.state = {}
        self.usage = {}           # account -> parsed _ui-usage answer
        self.loading = set()
        self.lock = threading.Lock()
        self.error = ""

    def reload(self):
        rc, out = ca(["_ui-state"])
        if rc != 0:
            self.error = out or ("claude-account _ui-state failed (exit %d)" % rc)
            return False
        try:
            self.state = json.loads(out)
            self.error = ""
            return True
        except ValueError:
            self.error = "could not read claude-account's state: " + out[:200]
            return False

    def reload_groups(self):
        """After a `group` or `order`, which change nothing about an account: read back only
        the groups, order and layout. A full reload reads every login and took 1.1-1.6 s for
        8 accounts, so [ and ] lagged. False means the caller must reload everything."""
        if not self.state:
            return False
        rc, out = ca(["_ui-groups"])
        if rc != 0:
            return False
        try:
            g = json.loads(out)
        except ValueError:
            return False
        known = set(self.accounts())
        if any(m not in known for sec in g.get("layout", []) for m in sec.get("members", [])):
            return False                # an account made elsewhere since: show it too
        for k in ("groups", "order", "layout"):
            self.state[k] = g.get(k, [])
        return True

    def accounts(self):
        return {a["name"]: a for a in self.state.get("accounts", [])}

    def fetch_usage(self, names):
        def one(n):
            rc, out = ca(["_ui-usage", target(n)], timeout=60)
            try:
                u = json.loads(out)
            except ValueError:
                u = {"problem": (out.splitlines() or ["no answer from the usage check"])[-1]}
            with self.lock:
                self.usage[n] = u
                self.loading.discard(n)

        def worker(queue):
            while True:
                with self.lock:
                    if not queue:
                        return
                    n = queue.pop(0)
                one(n)

        with self.lock:
            queue = [n for n in dict.fromkeys(names) if n not in self.loading]
            self.loading.update(queue)
        # Two at a time: one call per account back to back is what provoked the 429s
        # overview had to learn to retry, and the CLI's fetch still retries once.
        for _ in range(min(2, len(queue))):
            threading.Thread(target=worker, args=(queue,), daemon=True).start()


# ── drawing helpers ──────────────────────────────────────────────────────────────────

class Paint(object):
    def __init__(self):
        self.ok = curses.has_colors() and not os.environ.get("NO_COLOR")
        self.pairs = {}
        if self.ok:
            curses.start_color()
            try:
                curses.use_default_colors()
                bg = -1
            except curses.error:
                bg = curses.COLOR_BLACK
            orange = 208 if curses.COLORS >= 256 else curses.COLOR_YELLOW
            for i, (name, fg) in enumerate([("green", curses.COLOR_GREEN), ("yellow", curses.COLOR_YELLOW),
                                            ("orange", orange), ("red", curses.COLOR_RED),
                                            ("cyan", curses.COLOR_CYAN), ("blue", curses.COLOR_BLUE)], start=1):
                try:
                    curses.init_pair(i, fg, bg)
                    self.pairs[name] = curses.color_pair(i)
                except curses.error:
                    pass

    def __call__(self, name):
        return self.pairs.get(name, 0) if self.ok else 0

    def band(self, p):
        if p is None:
            return 0
        if p >= 100:
            return self("red") | curses.A_BOLD
        if p >= 90:
            return self("red")
        if p >= 75:
            return self("orange")
        if p >= 50:
            return self("yellow")
        return self("green")


def put(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return x
    room = w - x - (1 if y == h - 1 else 0)   # the bottom-right cell cannot be written
    if room <= 0:
        return x
    if ASCII:
        text = text.translate(ASCII_MAP).encode("ascii", "replace").decode("ascii")
    text = text[:room]
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass
    return x + len(text)


# Terminals disagree about how they send Home, End and even the arrows (Terminal.app, iTerm2
# and tmux each have their own habits), and curses only knows the encodings its terminfo entry
# lists — anything else arrives as a bare ESC plus loose bytes. So the view decodes the common
# ones itself, and swallows any other sequence whole.
ESC_KEYS = {"[A": curses.KEY_UP, "OA": curses.KEY_UP, "[B": curses.KEY_DOWN, "OB": curses.KEY_DOWN,
            "[C": curses.KEY_RIGHT, "OC": curses.KEY_RIGHT, "[D": curses.KEY_LEFT, "OD": curses.KEY_LEFT,
            "[H": curses.KEY_HOME, "OH": curses.KEY_HOME, "[1~": curses.KEY_HOME, "[7~": curses.KEY_HOME,
            "[F": curses.KEY_END, "OF": curses.KEY_END, "[4~": curses.KEY_END, "[8~": curses.KEY_END,
            "[5~": curses.KEY_PPAGE, "[6~": curses.KEY_NPAGE,
            "[1;2A": curses.KEY_SR, "[1;2B": curses.KEY_SF, "[a": curses.KEY_SR, "[b": curses.KEY_SF}


def read_escape(win):
    """Called after getch() gave ESC. Returns the key the sequence stands for, 27 for a lone
    Esc, or None for a sequence the view does not know (already swallowed)."""
    win.nodelay(True)
    seq = ""
    try:
        while len(seq) < 12:
            c = win.getch()
            if c == -1:
                break
            seq += chr(c) if 0 <= c < 256 else "?"
    finally:
        win.nodelay(False)
    if not seq:
        return 27
    return ESC_KEYS.get(seq)


def drain(win):
    """Swallow the rest of an escape sequence curses did not recognise, so its bytes do not
    arrive as keys of their own — "[" of "\\x1b[1~" would otherwise move an account."""
    win.nodelay(True)
    try:
        while win.getch() != -1:
            pass
    finally:
        win.nodelay(False)


def pct(p):
    return " –" if p is None else ("%3.0f%%" % p)


def left(ts):
    """How long until a window resets, in its largest unit (2h, 45m, 3d), worked out at draw
    time so it stays right between fetches. Three characters for any real window: the 5-hour
    one is under 5h, the weekly ones under 7d. "" when there is no time to show."""
    if not ts:
        return ""
    try:
        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        s = (t - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    except (ValueError, TypeError):
        return ""
    if s < 60:
        return "now"
    if s >= 86400:
        return "%dd" % (s // 86400)
    if s >= 3600:
        return "%dh" % (s // 3600)
    return "%dm" % (s // 60)


# ── the app ──────────────────────────────────────────────────────────────────────────

class App(object):
    def __init__(self, scr):
        self.scr = scr
        self.m = Model()
        self.paint = Paint()
        self.sort = 0
        self.expanded = set()
        self.seen = set()           # accounts already shown: only NEW ones are opened for you
        self.cursor = 0            # index into self.items, always a selectable item
        self.top = 0
        self.items = []
        self.msg = ("", 0)
        self.want = None           # (kind, account, path) to put the cursor back on

    # ── data ──
    def load(self, usage_for=None):
        self.m.reload()
        # Every account that has a path opens expanded (Alexy, 2026-10-18) — at start, and when
        # one appears later (added, renamed). One you closed stays closed; one with no path
        # stays closed too, as `e` leaves it: opening it only adds a "no paths" line.
        for a in self.m.state.get("accounts", []):
            if a["name"] not in self.seen:
                self.seen.add(a["name"])
                if a.get("paths"):
                    self.expanded.add(a["name"])
        accts = [a["name"] for a in self.m.state.get("accounts", [])]
        if usage_for is None:
            usage_for = [n for n in accts if n not in self.m.usage and n not in self.m.loading]
        if usage_for:
            self.m.fetch_usage([n for n in usage_for if n in accts])

    def refresh_usage(self, names=None):
        """Fetch usage again: one account from its own menu, every account from m or r.
        Only the usage is read for a single account; all of them reloads the state too."""
        if names is None:
            with self.m.lock:
                self.m.usage.clear()
            self.load()
            self.msg = ("refreshing usage…", 0)
        else:
            with self.m.lock:
                for n in names:
                    self.m.usage.pop(n, None)
            self.m.fetch_usage(names)
            self.msg = ("refreshing %s's usage…" % ", ".join(names), 0)
        self.remember()
        self.build()

    def machine(self):
        """Where a paused path goes: the account selected with `use`, else (global)."""
        return self.m.state.get("fallback") or GLOBAL

    def with_paths(self):
        return {a["name"] for a in self.m.state.get("accounts", []) if a.get("paths")}

    def all_expanded(self):
        wp = self.with_paths()
        return bool(wp) and wp <= self.expanded

    def toggle_all(self):
        """e: every account's paths at once, or none (asked for by Alexy, 2026-10-18). An
        account with no path is left closed: opening it only adds a "no paths" line."""
        if not self.with_paths():
            self.msg = ("no account has a path to show", 0)
            return
        if self.all_expanded():
            self.expanded.clear()
            self.msg = ("paths hidden — e shows them all again", 0)
        else:
            self.expanded |= self.with_paths()
            self.msg = ("every account's paths — e hides them all", 0)
        self.remember()                 # on a path that is now hidden: lands on its account
        self.build()

    def usage_of(self, name):
        with self.m.lock:
            return self.m.usage.get(name), name in self.m.loading

    @staticmethod
    def short_rows(u):
        """5h, week, the first model-scoped weekly, and extra usage, as numbers."""
        out = {"5h": None, "week": None, "scoped": None, "extra": None, "at": {}}
        if not u:
            return out
        for r in u.get("rows", []):
            k = r.get("kind", "")
            if k == "session" and out["5h"] is None:
                out["5h"] = r.get("pct"); out["at"]["5h"] = r.get("resets_at")
            elif k == "weekly_all" and out["week"] is None:
                out["week"] = r.get("pct"); out["at"]["week"] = r.get("resets_at")
            elif k == "weekly_scoped" and out["scoped"] is None:
                out["scoped"] = (r.get("label") or "model", r.get("pct")); out["at"]["scoped"] = r.get("resets_at")
        if u.get("extra"):
            out["extra"] = u["extra"].get("pct")
        return out

    def sorted_members(self, members):
        mode = SORTS[self.sort]
        if mode == "your order":
            return list(members)
        accts = self.m.accounts()

        def key(n):
            u, _ = self.usage_of(n)
            s = self.short_rows(u)
            if mode == "most weekly left":
                v = s["week"]
                return (v is None, v if v is not None else 0, n)
            if mode == "most 5h left":
                v = s["5h"]
                return (v is None, v if v is not None else 0, n)
            if mode == "sign-in ends first":
                v = (accts.get(n) or {}).get("signin_secs")
                return (v is None, v if v is not None else 0, n)
            return (False, 0, n.lower())
        return sorted(members, key=key)

    def build(self):
        """The visible lines: section headers, account rows, and paths under an expanded
        account. Only accounts and paths can take the cursor."""
        items = []
        accts = self.m.accounts()
        layout = self.m.state.get("layout", [])
        show_heads = any(sec.get("section") for sec in layout)
        for sec in layout:
            members = [n for n in sec.get("members", []) if n in accts]
            if show_heads:
                items.append({"kind": "section", "name": sec.get("section") or "Ungrouped",
                              "group": sec.get("section"), "count": len(members)})
            for n in self.sorted_members(members):
                items.append({"kind": "account", "name": n, "group": sec.get("section")})
                if n in self.expanded:
                    paths = accts[n].get("paths", [])
                    for p in paths:
                        items.append({"kind": "path", "name": n, "path": p["path"],
                                      "state": p["state"], "dest": p.get("dest", ""),
                                      "bound": p.get("bound") or n, "group": sec.get("section")})
                    if not paths:
                        items.append({"kind": "nopath", "name": n, "group": sec.get("section")})
        self.items = items
        sel = [i for i, it in enumerate(items) if it["kind"] in ("account", "path")]
        if not sel:
            self.cursor = 0
            return
        if self.want:
            kind, name, path, group = self.want
            self.want = None
            for i in sel:
                it = items[i]
                if it["kind"] == kind and it["name"] == name and it.get("path") == path \
                        and (group is None or it.get("group") == group):
                    self.cursor = i
                    return
            for i in sel:
                if items[i]["name"] == name:
                    self.cursor = i
                    return
        if self.cursor not in sel:
            later = [i for i in sel if i >= self.cursor]
            self.cursor = later[0] if later else sel[-1]

    def remember(self):
        it = self.cur()
        if it:
            self.want = (it["kind"], it["name"], it.get("path"), it.get("group"))

    def cur(self):
        if 0 <= self.cursor < len(self.items) and self.items[self.cursor]["kind"] in ("account", "path"):
            return self.items[self.cursor]
        return None

    def move(self, d):
        sel = [i for i, it in enumerate(self.items) if it["kind"] in ("account", "path")]
        if not sel:
            return
        if self.cursor not in sel:
            self.cursor = sel[0]
            return
        k = sel.index(self.cursor) + d
        self.cursor = sel[max(0, min(len(sel) - 1, k))]

    # ── drawing ──
    def note_for(self, a, u):
        st = a.get("state")
        if st == "error":
            return ("KEYCHAIN ERROR — could not read the credential", self.paint("red"))
        if st == "absent":
            return ("not signed in", self.paint("red"))
        s = a.get("signin_secs")
        if s is not None and s <= 0:
            return ("sign-in ended %s" % a.get("signin_date", ""), self.paint("red"))
        if s is not None and s < a.get("signin_warn_secs", 432000):
            return ("⚠ sign in again by %s" % a.get("signin_date", ""), self.paint("orange"))
        if u and u.get("problem"):
            return ("usage: %s" % u["problem"], self.paint("yellow"))
        return (a.get("summary", ""), curses.A_DIM)

    def draw_account(self, y, it, selected, w):
        P = self.paint
        a = self.m.accounts()[it["name"]]
        u, loading = self.usage_of(it["name"])
        s = self.short_rows(u)
        attr_sel = curses.A_REVERSE if selected else 0
        x = put(self.scr, y, 0, " ▶ " if selected else "   ", P("green") | curses.A_BOLD)
        machine = a.get("machine")
        name = it["name"]
        x = put(self.scr, y, x, ("● " if machine else "  "), P("cyan"))
        x = put(self.scr, y, x, "%-12s" % name[:12], (P("cyan") if a.get("global") else curses.A_BOLD) | attr_sel)
        x = put(self.scr, y, x, " %-5s" % (a.get("plan") or "")[:5])
        if loading and not u:
            x = put(self.scr, y, x, "  loading usage…", curses.A_DIM)
        elif u and u.get("rows") is not None and not u.get("problem"):
            # each windowed percentage carries a dim countdown to its reset (Alexy's pick,
            # 2026-10-18): compact enough to keep the columns, the exact time is in the panel
            x = put(self.scr, y, x, "  5h ", curses.A_DIM)
            x = put(self.scr, y, x, pct(s["5h"]), P.band(s["5h"]))
            x = put(self.scr, y, x, " %-3s" % left(s["at"].get("5h")), curses.A_DIM)
            x = put(self.scr, y, x, "  week ", curses.A_DIM)
            x = put(self.scr, y, x, pct(s["week"]), P.band(s["week"]))
            x = put(self.scr, y, x, " %-3s" % left(s["at"].get("week")), curses.A_DIM)
            if s["scoped"]:
                lbl, v = s["scoped"]
                x = put(self.scr, y, x, "  %s " % lbl[:8], curses.A_DIM)
                x = put(self.scr, y, x, pct(v), P.band(v))
                x = put(self.scr, y, x, " %-3s" % left(s["at"].get("scoped")), curses.A_DIM)
            if s["extra"] is not None:
                x = put(self.scr, y, x, "  extra ", curses.A_DIM)
                x = put(self.scr, y, x, pct(s["extra"]), P.band(s["extra"]))
        note, nattr = self.note_for(a, u)
        x = max(x + 3, 62) if w > 100 else x + 3
        put(self.scr, y, x, note, nattr)

    def draw_path(self, y, it, selected):
        P = self.paint
        put(self.scr, y, 0, " ▶ " if selected else "   ", P("green") | curses.A_BOLD)
        x = put(self.scr, y, 3, "     └ ", curses.A_DIM)
        x = put(self.scr, y, x, "%-46s" % tilde(it["path"]), curses.A_REVERSE if selected else 0)
        st = it["state"]
        if st == "active":
            put(self.scr, y, x + 2, "in use", P("green"))
        elif st == "pinned":
            put(self.scr, y, x + 2, "in use · pinned with switch <path> global", P("green"))
        elif st == "switched":
            put(self.scr, y, x + 2, "not in use → %s · switched" % (it.get("dest") or GLOBAL), P("orange"))
        else:
            put(self.scr, y, x + 2, "not in use → %s · paused" % (it.get("dest") or GLOBAL), P("orange"))

    def detail_lines(self):
        it = self.cur()
        if not it:
            return []
        a = self.m.accounts().get(it["name"])
        if not a:
            return []
        u, loading = self.usage_of(it["name"])
        lines = []
        head = "── %s " % it["name"]
        lines.append((head + "─" * max(0, 60 - len(head)), curses.A_DIM))
        ident = a.get("identity", "")
        if a.get("label") and a.get("state") == "signed-in":
            ident = "%s  ·  %s" % (a["label"], ident)
        lines.append(("  " + ident, 0))
        s = a.get("signin_secs")
        if s is not None and s < a.get("signin_warn_secs", 432000):
            when = "ended" if s <= 0 else "ends"
            lines.append(("  sign-in %s %s — sign in again: claude-account login %s"
                          % (when, a.get("signin_date", ""), target(it["name"])),
                          self.paint("red" if s <= 0 else "orange")))
        groups = [g["name"] for g in self.m.state.get("groups", []) if it["name"] in g.get("members", [])]
        if groups:
            lines.append(("  groups: " + ", ".join(groups), curses.A_DIM))
        if loading and not u:
            lines.append(("  loading usage…", curses.A_DIM))
        elif u:
            if u.get("problem"):
                lines.append(("  " + u["problem"], self.paint("yellow")))
            for r in u.get("rows", []):
                lines.append(("bar", r))
            if u.get("extra"):
                e = u["extra"]
                lines.append(("bar", {"name": "extra usage", "pct": e.get("pct"),
                                      "resets": "used %s/%s" % (e.get("used"), e.get("limit"))}))
            if u.get("note"):
                lines.append(("  " + u["note"], curses.A_DIM))
        return lines

    def draw(self):
        scr, P = self.scr, self.paint
        scr.erase()
        h, w = scr.getmaxyx()
        st = self.m.state
        mach = st.get("machine") or GLOBAL
        acct = self.m.accounts().get(mach, {})
        x = put(scr, 0, 0, " claude-account", P("green") | curses.A_BOLD)
        x = put(scr, 0, x, " · this machine: ", curses.A_DIM)
        x = put(scr, 0, x, mach, P("cyan") if mach == GLOBAL else curses.A_BOLD)
        if acct.get("label"):
            x = put(scr, 0, x, "  " + acct["label"])
        if mach != GLOBAL:
            x = put(scr, 0, x, "  (selected with use)", curses.A_DIM)
        right = "sort: %s   v%s   ? keys" % (SORTS[self.sort], st.get("version", ""))
        if w - len(right) - 1 > x + 2:
            put(scr, 0, w - len(right) - 1, right, curses.A_DIM)

        # The key line: each key bold, what it does dim (Alexy, 2026-10-18), so the keys stand out
        foot = [("↑↓", "move"), ("⏎", "actions"), ("→", "paths"),
                ("e", "%s all" % ("collapse" if self.all_expanded() else "expand")), ("[ ]", "reorder"),
                ("g", "groups"), ("m", "menu"), ("s", "sort"), ("r", "refresh"), ("q", "quit")]
        detail = self.detail_lines() if h >= 22 else []
        dh = min(len(detail), max(0, h - 14)) if detail else 0
        list_top, list_bot = 2, h - 3 - (dh + 1 if dh else 0)
        rows = max(1, list_bot - list_top)
        if self.m.error:
            put(scr, 2, 1, self.m.error, P("red"))
            list_top += 2
            rows = max(1, rows - 2)
        if not self.items:
            put(scr, list_top, 3, "no accounts yet — m for the menu: create a profile, or add a path", curses.A_DIM)
        if self.cursor < self.top:
            self.top = self.cursor
        if self.cursor >= self.top + rows:
            self.top = self.cursor - rows + 1
        if self.top > 0 and self.items and self.items[self.top - 1]["kind"] == "section" and self.cursor - self.top + 1 < rows:
            self.top -= 1   # keep a section's header in view with its first row
        for i in range(self.top, min(len(self.items), self.top + rows)):
            it, y = self.items[i], list_top + i - self.top
            if it["kind"] == "section":
                t = "── %s (%d) " % (it["name"], it["count"])
                x = put(scr, y, 1, "── ", curses.A_DIM)
                x = put(scr, y, x, it["name"], curses.A_BOLD | (curses.A_DIM if not it["group"] else 0))
                put(scr, y, x, " (%d) %s" % (it["count"], "─" * max(0, min(w, 90) - len(t) - 2)), curses.A_DIM)
            elif it["kind"] == "account":
                self.draw_account(y, it, i == self.cursor, w)
            elif it["kind"] == "path":
                self.draw_path(y, it, i == self.cursor)
            else:
                put(scr, y, 10, "└ no paths — ⏎ then 'Add a path…'", curses.A_DIM)
        if len(self.items) > self.top + rows:
            put(scr, list_bot - 1 if list_bot - 1 > list_top else list_top, w - 4, " ↓ ", curses.A_DIM)
        if dh:
            y = list_bot + 1
            for line, attr in detail[:dh]:
                if line == "bar":
                    r = attr
                    v = r.get("pct")
                    x = put(scr, y, 2, "%-22s " % (r.get("name") or "")[:22])
                    x = put(scr, y, x, "%5.1f%%" % v if v is not None else "    –", P.band(v))
                    filled = int(round((v or 0) / 5))
                    x = put(scr, y, x, "  [")
                    x = put(scr, y, x, "█" * filled, P.band(v))
                    x = put(scr, y, x, "░" * (20 - filled) + "]", curses.A_DIM)
                    put(scr, y, x + 2, r.get("resets") or "")
                else:
                    put(scr, y, 1, line, attr)
                y += 1
        text, kind = self.msg
        if text:
            put(scr, h - 2, 1, text.splitlines()[0] if text else "",
                P("red") if kind < 0 else (P("green") if kind > 0 else curses.A_DIM))
        x = 1
        for key, what in foot:
            x = put(scr, h - 1, x, key, curses.A_BOLD)
            x = put(scr, h - 1, x, " %s  " % what, curses.A_DIM)
        scr.noutrefresh()
        curses.doupdate()

    # ── overlays ──
    def box(self, lines_needed, width):
        h, w = self.scr.getmaxyx()
        bw = min(w - 2, max(width + 4, 30))
        bh = min(h - 2, lines_needed + 2)
        win = curses.newwin(bh, bw, max(0, (h - bh) // 2), max(0, (w - bw) // 2))
        win.keypad(True)
        win.erase()
        try:
            win.border()
        except curses.error:
            pass
        return win

    def menu(self, title, options, start=0, hint="↑↓ choose · ⏎ select · esc cancel"):
        """DoctorBox-style: ▶ marks the choice, Enter takes it. Returns an index or None."""
        if not options:
            return None
        sel = max(0, min(start, len(options) - 1))
        width = max([len(title), len(hint)] + [len(o) + 4 for o in options])
        while True:
            self.draw()
            win = self.box(len(options) + 4, width)
            bh, bw = win.getmaxyx()
            put(win, 1, 2, title, curses.A_BOLD)
            vis = bh - 5
            off = max(0, sel - vis + 1)
            for k, o in enumerate(options[off:off + vis]):
                j = k + off
                if j == sel:
                    put(win, 2 + k + 1, 2, "▶ " + o, self.paint("green") | curses.A_BOLD)
                else:
                    put(win, 2 + k + 1, 2, "  " + o)
            put(win, bh - 2, 2, hint, curses.A_DIM)
            win.refresh()
            c = win.getch()
            if c == 27:
                c = read_escape(win)
                if c == 27:
                    return None          # a lone Esc cancels the menu
                if c is None:
                    continue             # an unknown sequence does nothing
            if c in (curses.KEY_UP, ord("k")):
                sel = (sel - 1) % len(options)
            elif c in (curses.KEY_DOWN, ord("j")):
                sel = (sel + 1) % len(options)
            elif c in (curses.KEY_ENTER, 10, 13):
                return sel
            elif c == ord("q"):
                return None
            elif c == curses.KEY_RESIZE:
                continue

    def confirm(self, question):
        """Yes/No with No highlighted, so a stray Enter changes nothing."""
        return self.menu(question, ["Yes", "No"], start=1) == 0

    def ask(self, prompt, initial=""):
        """One line of text. Enter takes it, Esc cancels (returns None)."""
        buf = list(initial)
        curses.curs_set(1)
        try:
            while True:
                self.draw()
                width = max(len(prompt), 50)
                win = self.box(5, width)
                bh, bw = win.getmaxyx()
                put(win, 1, 2, prompt, curses.A_BOLD)
                field = "".join(buf)
                shown = field[-(bw - 6):]
                put(win, 2, 2, "> " + shown)
                put(win, 3, 2, "⏎ ok · esc cancel", curses.A_DIM)
                win.move(2, min(bw - 2, 4 + len(shown)))
                win.refresh()
                c = win.get_wch()
                if c in ("\n", "\r", curses.KEY_ENTER):
                    return "".join(buf)
                if c == "\x1b":
                    k = read_escape(win)
                    if k == 27:
                        return None      # a lone Esc cancels
                    continue             # arrows and the rest do nothing in a one-line field
                if c in (curses.KEY_BACKSPACE, "\x7f", "\b", 127, 8):
                    if buf:
                        buf.pop()
                elif c == "\x15":           # ctrl-u clears the line
                    buf = []
                elif isinstance(c, str) and c.isprintable():
                    buf.append(c)
        finally:
            curses.curs_set(0)

    def typed_confirm(self, what, word):
        got = self.ask("%s — type %s to go ahead" % (what, word))
        if got is None:
            return False
        if got.strip() != word:
            self.msg = ("nothing changed: you typed %r, not %r" % (got.strip(), word), -1)
            return False
        return True

    def show_text(self, title, text, ok=True):
        lines = text.splitlines() or ["(no output)"]
        off = 0
        while True:
            self.draw()
            h, w = self.scr.getmaxyx()
            width = min(w - 6, max([len(title)] + [len(l) for l in lines]))
            win = self.box(min(len(lines), h - 8) + 4, width)
            bh, bw = win.getmaxyx()
            put(win, 1, 2, title, (self.paint("green") if ok else self.paint("red")) | curses.A_BOLD)
            vis = bh - 4
            for k, l in enumerate(lines[off:off + vis]):
                put(win, 2 + k, 2, l)
            more = " ↑↓ scroll ·" if len(lines) > vis else ""
            put(win, bh - 1, 2, "%s ⏎ close " % more, curses.A_DIM)
            win.refresh()
            c = win.getch()
            if c == 27:
                c = read_escape(win)
                if c is None:
                    continue
            if c in (curses.KEY_DOWN, ord("j")) and off + vis < len(lines):
                off += 1
            elif c in (curses.KEY_UP, ord("k")) and off > 0:
                off -= 1
            elif c in (curses.KEY_ENTER, 10, 13, 27, ord("q"), ord(" ")):
                return

    # ── running commands ──
    def run(self, args, title=None, refetch=None, quiet_ok=False):
        self.remember()
        self.msg = ("running: claude-account %s …" % " ".join(args), 0)
        self.draw()
        rc, out = ca(args)
        cmd = "claude-account " + " ".join(args)
        if not (args[0] in ("group", "order") and self.m.reload_groups()):
            self.load(usage_for=refetch)        # None: only accounts with no usage yet
        self.build()
        if rc == 0:
            self.msg = ("done: " + cmd, 1)
            if out and not quiet_ok:
                self.show_text(title or cmd, out, ok=True)
        else:
            self.msg = ("failed (exit %d): %s" % (rc, cmd), -1)
            self.show_text("failed (exit %d): %s" % (rc, cmd), out or "(no output)", ok=False)
        return rc

    def run_in_terminal(self, args, refetch=None):
        """For what needs the real terminal — a browser sign-in, a y/N of the CLI's own,
        a long report: leave the screen, run it, wait for Enter, come back."""
        self.remember()
        curses.def_prog_mode()
        curses.endwin()
        cmd = ["bash", CA] + list(args)
        print("\n$ claude-account %s\n" % " ".join(args), flush=True)
        try:
            rc = subprocess.call(cmd)
        except KeyboardInterrupt:
            rc = 130
        print("\n(exit %d) — press Enter to go back to the view" % rc, flush=True)
        try:
            sys.stdin.readline()
        except KeyboardInterrupt:
            pass
        curses.reset_prog_mode()
        self.scr.refresh()
        self.load(usage_for=refetch)            # None: only accounts with no usage yet
        self.build()
        self.msg = (("done: " if rc == 0 else "exit %d: " % rc) + "claude-account " + " ".join(args),
                    1 if rc == 0 else -1)
        return rc

    # ── pickers ──
    def pick_account(self, title, exclude=None):
        names = [a["name"] for a in self.m.state.get("accounts", []) if a["name"] != exclude]
        i = self.menu(title, names)
        return None if i is None else names[i]

    # Both group menus do ONE thing and go back to the main screen, where the change shows:
    # most accounts sit in one group (Alexy, 2026-10-18), so coming back to the menu after
    # each pick was one more Esc almost every time. g again for a second group.
    def groups_for(self, name):
        groups = self.m.state.get("groups", [])
        opts = ["[%s] %s" % ("x" if name in g.get("members", []) else " ", g["name"]) for g in groups]
        opts.append("＋ New group…")
        i = self.menu("Groups for %s" % name, opts, hint="↑↓ choose · ⏎ put it in, or take it out · esc back")
        if i is None:
            return
        if i == len(groups):
            g = (self.ask("Name of the new group") or "").strip()
            if g and self.run(["group", g, target(name)], quiet_ok=True) == 0:
                self.msg = ("%s is in %s — g again to put it in another group too" % (name, g), 1)
            return
        g = groups[i]["name"]
        if name in groups[i].get("members", []):
            if self.run(["group", g, "--remove", target(name)], quiet_ok=True) == 0:
                self.msg = ("%s is out of %s" % (name, g), 1)
        elif self.run(["group", g, target(name)], quiet_ok=True) == 0:
            self.msg = ("%s is in %s — g again to put it in another group too" % (name, g), 1)

    def groups_manager(self):
        groups = self.m.state.get("groups", [])
        opts = ["%s  (%d)" % (g["name"], len(g.get("members", []))) for g in groups] + ["＋ New group…",
                                                                                     "Reset your order to the default"]
        i = self.menu("Groups — ⏎ on one to rename, delete or move it", opts)
        if i is None:
            return
        if i == len(groups) + 1:
            if self.confirm("Forget your own order? Groups and their members stay."):
                self.run(["order", "--reset"], quiet_ok=True)
            return
        if i == len(groups):
            g = self.ask("Name of the new group")
            if g:
                self.run(["group", "--new", g.strip()], quiet_ok=True)
            return
        g = groups[i]["name"]
        names = [x["name"] for x in groups]
        acts = ["Rename…", "Move up", "Move down", "Delete the group (its accounts stay)", "Back"]
        k = self.menu("Group %s" % g, acts)
        if k == 0:
            new = self.ask("New name for %s" % g, g)
            if new and new.strip() != g:
                self.run(["group", "--rename", g, new.strip()], quiet_ok=True)
        elif k in (1, 2):
            j = i - 1 if k == 1 else i + 1
            if 0 <= j < len(names):
                names[i], names[j] = names[j], names[i]
                self.run(["order", "--groups"] + names, quiet_ok=True)
        elif k == 3:
            if self.confirm("Delete the group %s? Its accounts are not touched." % g):
                self.run(["group", "--delete", g], quiet_ok=True)

    # ── reordering ──
    def reorder(self, d):
        it = self.cur()
        if not it or it["kind"] != "account":
            self.msg = ("put the cursor on an account to move it", 0)
            return
        if SORTS[self.sort] != "your order":
            self.msg = ("showing a temporary sort — press s until it says 'your order' to arrange", 0)
            return
        group = it["group"]
        sec = None
        for s in self.m.state.get("layout", []):
            if s.get("section") == group:
                sec = list(s.get("members", []))
        if not sec or it["name"] not in sec:
            return
        i = sec.index(it["name"])
        j = i + d
        if j < 0 or j >= len(sec):
            return
        if group:
            sec[i], sec[j] = sec[j], sec[i]
            self.run(["order", "--in", group] + [target(n) for n in sec], quiet_ok=True)
        else:
            order = list(self.m.state.get("order", []))
            a, b = order.index(sec[i]), order.index(sec[j])
            order[a], order[b] = order[b], order[a]
            self.run(["order"] + [target(n) for n in order], quiet_ok=True)
        self.want = ("account", it["name"], None, group)
        self.build()

    # ── menus for the thing under the cursor ──
    def account_menu(self, name):
        a = self.m.accounts()[name]
        paths = a.get("paths", [])
        active = [p for p in paths if p["state"] == "active"]
        paused = [p for p in paths if p["state"] == "paused"]
        glob = a.get("global")
        # First, so ⏎ ⏎ is always harmless: it only reads. It is also the retry for a usage
        # check that failed (rate limited, say), which otherwise shows until the next r.
        acts = [("Refresh its usage", "usage")]
        signed = a.get("state") == "signed-in"
        if not a.get("machine"):
            acts.append(("Use it for every path with no rule" + ("" if signed or glob else " (it is not signed in)"), "use"))
        elif not glob:
            acts.append(("Stop using it for paths with no rule (back to (global))", "use-global"))
        if active and not glob:
            acts.append(("Pause its %d path(s) — they use %s meanwhile" % (len(active), self.machine()), "pause"))
        if paused:
            acts.append(("Resume its %d paused path(s)" % len(paused), "resume"))
        if active and not glob:
            acts.append(("Switch its paths to another account…", "switch"))
        if not glob:
            acts.append(("Add a path…", "add"))
        if paths and not glob:
            acts.append(("Unbind all its paths (the login stays)", "unbind-all"))
        acts.append(("Groups…", "groups"))
        acts.append(("Sign in again…", "login"))
        acts.append(("Renew its access token", "refresh"))
        acts.append(("Label it with its email…", "label"))
        if not glob:
            acts.append(("Rename…", "rename"))
        acts.append(("Open its limit-reset page on claude.ai", "reset"))
        acts.append(("Sign out… (deletes the stored login)", "logout"))
        if not glob:
            acts.append(("Forget the profile… (login, label and rules)", "forget"))
        i = self.menu(name, [t for t, _ in acts])
        if i is None:
            return
        act, t = acts[i][1], target(name)
        if act == "usage":
            self.refresh_usage([name])
        elif act == "use":
            if signed or glob:
                if self.confirm("Use %s for every path with no rule?" % name):
                    self.run(["use", t])
            elif self.confirm("%s is not signed in, so every launch in a folder with no rule would warn. Use it anyway?" % name):
                self.run(["use", t, "--force"])
        elif act == "use-global":
            if self.confirm("Send every path with no rule back to (global)?"):
                self.run(["use", "global"])
        elif act == "pause":
            if self.confirm("Pause %s's %d path(s)? Open chats keep their account until reopened." % (name, len(active))):
                self.run(["pause", t])
        elif act == "resume":
            if self.confirm("Resume %s's %d path(s)?" % (name, len(paused))):
                self.run(["resume", t])
        elif act == "switch":
            dest = self.pick_account("Switch %s's paths to…" % name, exclude=name)
            if dest and self.confirm("Move every path on %s to %s?" % (name, dest)):
                self.run(["switch", t, target(dest)])
        elif act == "add":
            p = self.ask("Folder to bind to %s (an absolute path, ~ is fine)" % name)
            if p:
                p = os.path.expanduser(p.strip())
                if self.confirm("Bind %s to %s?" % (tilde(p), name)):
                    self.run(["add", p, t])
                    self.expanded.add(name)
                    self.build()
        elif act == "unbind-all":
            if self.confirm("Unbind all %d path(s) from %s? Its login stays, so add brings them back." % (len(paths), name)):
                self.run(["unbind", t, "--all"])
        elif act == "groups":
            self.groups_for(name)
        elif act == "login":
            extra = self.signin_options()
            if extra is not None:
                self.run_in_terminal(["login", t] + extra, refetch=[name])
        elif act == "refresh":
            self.run(["refresh", t], refetch=[name])
        elif act == "label":
            k = self.menu("Label %s" % name, ["Type the email…", "Read it from the most recent sign-in (--auto)", "Clear the label"])
            if k == 0:
                cur = a.get("label") or ""
                lbl = self.ask("Email to record for %s" % name, cur)
                if lbl and lbl.strip() != cur:
                    self.run(["label", t, lbl.strip()], quiet_ok=True)
            elif k == 1:
                self.run(["label", t, "--auto"])
            elif k == 2 and self.confirm("Clear the recorded email of %s?" % name):
                self.run(["label", t], quiet_ok=True)
        elif act == "rename":
            new = self.ask("New name for the profile %s" % name, name)
            if new and new.strip() != name and self.confirm("Rename %s to %s? Its login moves with it." % (name, new.strip())):
                self.run(["rename", t, new.strip()])
        elif act == "reset":
            self.run_in_terminal(["reset-page", t])
        elif act == "logout":
            if self.typed_confirm("Sign out of %s — its stored login is deleted" % name, t):
                keep = []
                if paths and not glob:
                    k = self.menu("Its paths after signing out", ["Pause them, so they use (global) quietly (usual)",
                                                                  "Keep them routed — only if you sign straight back in"])
                    if k is None:
                        self.msg = ("nothing changed", 0)
                        return
                    keep = ["--keep-active"] if k == 1 else []
                self.run(["logout", t] + keep, refetch=[name])
        elif act == "forget":
            n = len(paths)
            what = "Forget %s — its login and label are deleted%s%s" % (
                name, (", and its %d rule(s) are removed" % n) if n else "",
                ", and paths with no rule go back to (global)" if a.get("selected") else "")
            if self.typed_confirm(what, t):
                self.run(["forget", t] + (["--force"] if (n or a.get("selected")) else []))

    def path_menu(self, it):
        p, name, st = it["path"], it["name"], it["state"]
        # A row pinned with `switch <path> global` is listed under (global), but its rule is
        # still bound to its own profile, and that is where resume and unbind act.
        bound = it.get("bound") or name
        acts = []
        if st == "active":
            acts.append(("Pause this path — it uses %s meanwhile" % self.machine(), "pause"))
        elif st == "pinned":
            acts.append(("Send this path back to %s (resume)" % bound, "resume"))
        else:
            acts.append(("Resume this path on %s" % bound, "resume"))
        acts.append(("Switch this path to another account…", "switch"))
        acts.append(("Unbind this path (the login stays)", "unbind"))
        i = self.menu(tilde(p), [t for t, _ in acts])
        if i is None:
            return
        act = acts[i][1]
        if act == "pause" and self.confirm("Pause %s?" % tilde(p)):
            self.run(["pause", p])
        elif act == "resume" and self.confirm("Resume %s on %s?" % (tilde(p), bound)):
            self.run(["resume", p])
        elif act == "switch":
            dest = self.pick_account("Switch %s to…" % tilde(p), exclude=None)
            if dest and self.confirm("Move %s to %s?" % (tilde(p), dest)):
                self.run(["switch", p, target(dest)])
        elif act == "unbind" and self.confirm("Unbind %s from %s? Its login stays." % (tilde(p), bound)):
            self.run(["unbind", p])

    def signin_options(self):
        """The browser sign-in, or one of its variants. Returns the extra flags, or None."""
        k = self.menu("How to sign in", ["In the browser, the usual way", "With a specific email…",
                                         "With SSO", "With an Anthropic Console account"])
        if k is None:
            return None
        if k == 1:
            e = self.ask("Email to sign in with")
            return ["--email", e.strip()] if e and e.strip() else None
        return [[], [], ["--sso"], ["--console"]][k]

    def whoami(self):
        p = self.ask("Which folder? (an absolute path, ~ is fine)", HOME)
        if not p:
            return
        p = os.path.expanduser(p.strip())
        who = os.path.join(os.path.dirname(CA), "claude-whoami")
        cmd = ["bash", who, p] if os.path.isfile(who) else ["claude-whoami", p]
        env = dict(os.environ); env["NO_COLOR"] = "1"
        try:
            out = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, env=env, timeout=60).stdout.decode("utf-8", "replace")
        except (OSError, subprocess.TimeoutExpired) as e:
            out = "could not run claude-whoami: %s" % e
        self.show_text("Which account %s uses" % tilde(p), ANSI.sub("", out).rstrip("\n"))

    def printed(self):
        views = [("overview", ["overview", "--no-refresh"]), ("list — one row per path rule", ["list", "--no-refresh"]),
                 ("profiles — one row per login", ["profiles", "--no-refresh"]),
                 ("verify — the plan each path uses", ["verify", "--no-refresh"]),
                 ("your groups and order", ["group"]), ("every command (--help)", ["--help"])]
        k = self.menu("Show the printed view", [t for t, _ in views])
        if k is not None:
            self.msg = ("running: claude-account %s …" % " ".join(views[k][1]), 0)
            self.draw()
            rc, out = ca(views[k][1])
            self.show_text("claude-account " + " ".join(views[k][1]), out, ok=(rc == 0))

    def transfer(self):
        k = self.menu("Move to another Mac", ["Export the rules, labels and groups to a file…",
                                             "Import them from a file…"])
        if k == 0:
            f = self.ask("Write the export to", os.path.join(HOME, "claude-accounts.tsv"))
            if f:
                f = os.path.expanduser(f.strip())
                if os.path.exists(f) and not self.confirm("%s exists. Replace it?" % tilde(f)):
                    return
                rc, out = ca(["export"])
                if rc == 0:
                    try:
                        with open(f, "w", encoding="utf-8") as fh:
                            fh.write(out + "\n")
                        self.msg = ("exported to %s — logins are never in it" % tilde(f), 1)
                    except OSError as e:
                        self.show_text("could not write %s" % tilde(f), str(e), ok=False)
                else:
                    self.show_text("export failed", out, ok=False)
        elif k == 1:
            f = self.ask("Import from", os.path.join(HOME, "claude-accounts.tsv"))
            if f and self.confirm("Import %s? Paths that already have a rule are skipped." % tilde(f.strip())):
                self.run(["import", os.path.expanduser(f.strip())])

    def plumbing(self):
        k = self.menu("Set up", ["Wire up PATH and the editors (setup)", "Status bar item in VS Code / Cursor: install",
                                 "Status bar item: remove", "Status bar item: status"])
        if k == 0:
            self.run_in_terminal(["setup"])
        elif k == 1:
            self.run(["vscode-status", "install"])
        elif k == 2 and self.confirm("Remove the status bar item from every editor?"):
            self.run(["vscode-status", "remove"])
        elif k == 3:
            self.run(["vscode-status", "status"])

    def main_menu(self):
        fb = self.m.state.get("fallback")
        acts = [("Refresh every account's usage", "usage"),
                ("Add a path…", "add"), ("Create a profile… (signs in through the browser)", "create"),
                ("Groups…", "groups"), ("Which account does a folder use?", "whoami")]
        if fb:
            acts.append(("Send paths with no rule back to (global)", "use-global"))
        acts += [("Renew every expired access token", "refresh"), ("Undo the last change to the path rules…", "undo"),
                 ("Health check (doctor)", "doctor"), ("Show a printed view or the full help…", "printed"),
                 ("Move to another Mac (export / import)…", "transfer"), ("Set up PATH, editors and the status bar…", "plumbing"),
                 ("Keys", "help"), ("Quit", "quit")]
        i = self.menu("claude-account", [t for t, _ in acts])
        if i is None:
            return True
        act = acts[i][1]
        if act == "usage":
            self.refresh_usage()
        elif act == "add":
            names = [a["name"] for a in self.m.state.get("accounts", []) if not a.get("global")]
            NEW = "＋ a new profile, named after the folder"
            i = self.menu("Bind a folder to which account?", names + [NEW])
            if i is None:
                return True
            p = self.ask("Folder to bind (an absolute path, ~ is fine)")
            if not p:
                return True
            p = os.path.expanduser(p.strip())
            if i == len(names):
                if self.confirm("Bind %s to a new profile named after the folder? Sign it in afterwards." % tilde(p)):
                    self.run(["add", p])
            elif self.confirm("Bind %s to %s?" % (tilde(p), names[i])):
                self.cursor_to(names[i])
                self.run(["add", p, names[i]])
        elif act == "create":
            n = self.ask("Name for the new profile (lowercase, e.g. work)")
            if n:
                extra = self.signin_options()
                if extra is not None:
                    self.run_in_terminal(["create", n.strip()] + extra, refetch=[n.strip()])
        elif act == "whoami":
            self.whoami()
        elif act == "printed":
            self.printed()
        elif act == "transfer":
            self.transfer()
        elif act == "plumbing":
            self.plumbing()
        elif act == "groups":
            self.groups_manager()
        elif act == "use-global":
            if self.confirm("Send every path with no rule back to (global)?"):
                self.run(["use", "global"])
        elif act == "refresh":
            self.run(["refresh"], refetch=[a["name"] for a in self.m.state.get("accounts", [])])
        elif act == "undo":
            self.run_in_terminal(["undo"])
        elif act == "doctor":
            self.run_in_terminal(["doctor"])
        elif act == "help":
            self.help()
        elif act == "quit":
            return False
        return True

    def cursor_to(self, name):
        self.want = ("account", name, None, None)
        self.build()

    def help(self):
        self.show_text("Keys", "\n".join([
            "↑ ↓  or  k j      move",
            "→  or  l          show the account's paths      ←  or  h  hide them",
            "e                 every account's paths at once, or hide them all again",
            "⏎                 what you can do with the account or path under the cursor,",
            "                  first of all refresh its usage",
            "[  ]              move the account up / down in its group (shift+↑↓ too)",
            "g                 the account's groups          G  manage groups",
            "m                 menu: add a path, create a profile, undo, health check",
            "s                 sort for a moment by usage left, sign-in end or name",
            "                  (your saved order comes back when you press s round to it)",
            "r                 refresh every account's usage (m has it too)     q  quit",
            "",
            "Every change runs the same claude-account command you could type,",
            "and shows what it printed. Things that cannot be undone ask you to",
            "type the profile name first.",
        ]))

    def loop(self):
        curses.curs_set(0)
        self.scr.keypad(True)
        self.scr.timeout(250)
        self.load()
        self.build()
        while True:
            self.draw()
            try:
                c = self.scr.getch()
            except KeyboardInterrupt:
                return
            if c == -1:
                continue
            it = self.cur()
            if c == 27:
                # Never "quit": decode the sequence, or swallow it. Only q quits the view.
                c = read_escape(self.scr)
                self.scr.timeout(250)
                if c in (None, 27):
                    continue
            if c == ord("q"):
                return
            elif c in (curses.KEY_UP, ord("k")):
                self.move(-1)
            elif c in (curses.KEY_DOWN, ord("j")):
                self.move(1)
            elif c == curses.KEY_HOME:
                self.move(-10 ** 6)
            elif c == curses.KEY_END:
                self.move(10 ** 6)
            elif c in (curses.KEY_NPAGE,):
                self.move(10)
            elif c in (curses.KEY_PPAGE,):
                self.move(-10)
            elif c in (curses.KEY_RIGHT, ord("l"), ord(" ")) and it and it["kind"] == "account":
                if c == ord(" ") and it["name"] in self.expanded:
                    self.expanded.discard(it["name"])
                else:
                    self.expanded.add(it["name"])
                self.remember()
                self.build()
            elif c in (curses.KEY_LEFT, ord("h")) and it:
                self.expanded.discard(it["name"])
                self.want = ("account", it["name"], None, it.get("group"))
                self.build()
            elif c == ord("e"):
                self.toggle_all()
            elif c in (curses.KEY_ENTER, 10, 13) and it:
                if it["kind"] == "account":
                    self.account_menu(it["name"])
                else:
                    self.path_menu(it)
                self.build()
            elif c in (ord("["), curses.KEY_SR):
                self.reorder(-1)
            elif c in (ord("]"), curses.KEY_SF):
                self.reorder(1)
            elif c == ord("g") and it:
                self.groups_for(it["name"])
                self.build()
            elif c == ord("G"):
                self.groups_manager()
                self.build()
            elif c == ord("m"):
                if not self.main_menu():
                    return
                self.build()
            elif c == ord("s"):
                self.sort = (self.sort + 1) % len(SORTS)
                self.remember()
                self.build()
                self.msg = ("sort: %s%s" % (SORTS[self.sort], "" if self.sort == 0 else " — for this view only, nothing saved"), 0)
            elif c == ord("r"):
                self.refresh_usage()
            elif c == ord("?"):
                self.help()
            elif c == curses.KEY_RESIZE:
                self.build()


def main():
    if not CA or not os.path.isfile(CA):
        sys.stderr.write("claude-account ui: run it as `claude-account ui`\n")
        return 2
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        sys.stderr.write("claude-account ui needs a terminal — use `claude-account overview` in scripts\n")
        return 2
    global ASCII
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        pass
    # What ncurses itself will use: the C library's codeset. Not getpreferredencoding(), which
    # Python's UTF-8 mode reports as utf-8 even in the C locale, where ncurses sees ASCII.
    try:
        enc = locale.nl_langinfo(locale.CODESET)
    except (AttributeError, ValueError):
        enc = locale.getpreferredencoding(False)
    ASCII = "utf" not in (enc or "").lower().replace("-", "")
    os.environ.setdefault("ESCDELAY", "25")   # Esc closes a menu at once, not after a second
    curses.wrapper(lambda scr: App(scr).loop())
    return 0


if __name__ == "__main__":
    sys.exit(main())
