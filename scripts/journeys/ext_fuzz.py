"""Model-based action fuzzing for the journeys (group action-fuzz, journeys/fuzz/*.json; orchestrator: fuzz.py).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead. fuzz.py (on the orchestrating
machine) imports it too, for plan(), ddmin() and the corpus; nothing here runs at import.

cmux-ad 2026-10-31 (Lawrence: "we need to fuzz greater for both correctness and speed"): one harness with the smoke
gate. The fuzz shares the driver's action layer (debug.key, the key router's real path, the same as a person's key;
debug.mouse drags as ext_window plays them; the driver's relaunch) and its oracles (ext_window's grid fit, the
smoke gate's topology reads, ext_focus's focus reading).

A seed gives a plan: random user actions (ACTIONS) with a timing each (`now`: the next action follows at once,
`pair`: within 60 ms, a quick double press; `slow`: 1.5 s later). Actions that follow at once or as a pair form a
burst; the oracles run after every burst ends (checking between the actions of a burst would change the timing
under test), so after every action of a slow plan. A model of the expected state (workspaces, tabs, terminals,
panes of the shown workspace) is kept beside the app: each action predicts its change; the app must reach it.

Oracles (each a short name in the failure, `oracle:detail`):
  create      a create (Cmd-T, Cmd-N, Cmd-D, Cmd-Shift-D, Ctrl-`, Cmd-Shift-L) reached the model's prediction (a new
              workspace, tab, terminal or pane), or the app showed a refusal (debug.toast `refusals` grew); never
              silence. A new terminal takes keys: a probe line typed into the focused terminal after the burst runs
              on exactly one terminal, a new one (its daemon screen), and prints the PTY's size (stty) for R3a.
              Cmd-T: the New Tab field has focus (debug.new_tab field). Cmd-Shift-L: the address bar has the keys.
  r3a         every shown terminal: grid == fitted grid == drawn grid == the daemon's screen size, and the grid
              fits the view's frame at the cell size (ext_window's grid_fits rule); the probe's `stty size` == the
              daemon's size (the PTY)
  r3b         (cmux-ad 08:06Z) New Column (the action's key, Ctrl-Cmd-D) keeps every old column's width; Cmd-D and
              Split Down split inside a column, and no OTHER column changes width. Columns are the topology's
              `column`, matched by their panes, with ext_smoke's width reading; exact within 0.01 pt, read until it
              holds for up to 3 s (a layout in flight is not a failure). New Column always starts its burst.
  focus       debug.focus: the model's target == AppKit's first responder (`consistent`, `mismatches`), read again
              0.5 s later before it counts
  topology    the daemon's terminals == the app topology's terminals (`cmux terminal list`); debug.desync check
  stall       no main-thread stall over 100 ms with a cmux frame (debug.hangs records since the last burst);
              stalls with no cmux frame (or no stack) are kept as notes
  crash       the app process lives and its daemon is connected (debug.crashes after a quit relaunch: clean)
  quit        (set `quit`, ext_quitfuzz.py) after each quit kind and each kill -9 (app, daemon, both): every
              acknowledged workspace, pane and terminal is back, scrollback intact, one daemon and at most one holder
              run, no orphan daemon (End choices: what they end is gone, and the layout stays for End Sessions)
  leak        after close-all: the app's fd count, the bundle's process count and its PTY count are back at the
              baseline (taken at the first close-all, so browser helpers that stay warm are counted once); a later
              close-all above it is a leak

Speed: each create records, from its key, `shown_ms` (the first poll, every 25 ms, where the new terminal's pane is
visible and not blank with a drawn grid, or the new tab or workspace is in the topology) and `typeable_ms` (a
terminal: the shell's first output, its prompt, is in the app's viewport text, what the renderer draws; Cmd-T: the New Tab field has focus;
Cmd-Shift-L: the address bar has the keys). No build has a photon (present) timestamp yet, so these are the app's
own drawn state, read the same way on both builds of an A/B; fuzz.py compares them build against build.

A failure is shrunk at once in the same app (ddmin over the actions; each try starts from the baseline workspaces,
closed through the app's own closeWorkspace), until the step's budget ends; fuzz.py replays the smallest sequence in
a fresh lease and writes it as a regression journey (red first).

Diagnostic (journey option fuzz_mode=diagnostic, the smoke gate's --diagnostic): a capture slot has no key window, so
keys the app holds for a terminal still being made are lost there. Every key after a create then waits out the
creation hold (2.5 s, as the driver's typing does): the quick pairs of creates, typing at once into a new terminal and
the focus oracle (no key window) are weak in this mode, and fuzz.py never writes a clean file from it.

Steps (`do`):
  fuzz_run   {seed?, count?, sequence?, budget_s?, shrink?, weights?}
             plays the plan of SEED (or SEQUENCE: a list of {"a": action, "t": timing, ...}, a corpus entry or a
             shrunk repro), the oracles after each burst; writes fuzz.json beside result.json; fails with the
             first failure's oracle, its seed and the shrunk sequence
Conditions (inside `expect.all`):
  fuzz_clean          {}   app: the last fuzz_run found no failure
  fuzz_daemon_agrees  {}   daemon: the daemon's terminals == the app topology's terminals now
"""
import json
import random
import re
import subprocess
import time

D = None  # the driver module (install)

# action: what a person presses. `key`/`mods` go through debug.key (the key router's real path); `action` goes
# through action.run (a menu item's route, for an action with no default key); `special` is played below.
# `creates` names the model's change; `column` marks an action that makes a column (R3b).
ACTIONS = {
    "new_tab": {"key": "t", "mods": ["cmd"], "creates": "tab_page"},              # Cmd-T: the New Tab page
    "new_workspace": {"key": "n", "mods": ["cmd"], "creates": "workspace"},       # Cmd-N
    # R3b (cmux-ad 08:06Z, final scope): New Column adds a column and every old column keeps its exact width; Cmd-D
    # and Split Down split inside a column, and no OTHER column changes width. `column`: adds a column; `inside`: a
    # split inside the focused pane's column.
    "split_right": {"key": "d", "mods": ["cmd"], "creates": "pane", "inside": True},  # Cmd-D
    "new_column": {"key": "d", "mods": ["control", "cmd"], "creates": "pane", "column": True},  # Ctrl-Cmd-D
    "split_down": {"key": "d", "mods": ["cmd", "shift"], "creates": "pane", "inside": True},  # Cmd-Shift-D
    "new_terminal": {"key": "`", "mods": ["control"], "creates": "terminal"},     # Ctrl-`
    "open_url": {"special": True, "creates": "browser"},                          # Cmd-Shift-L, a URL, Return
    "close_tab": {"key": "w", "mods": ["cmd"], "closes": "tab"},                  # Cmd-W
    "close_pane": {"action": "closePane", "closes": "pane"},                      # no default key: the menu's route
    "close_workspace": {"key": "w", "mods": ["cmd", "shift"], "closes": "workspace"},  # Cmd-Shift-W
    "switch_workspace": {"special": True},                                        # Cmd-1 .. Cmd-4
    # cmux-ad 10:48Z, TOP P0 TIP RED 1193 (STATUS 1202): a split, then a line typed AT ONCE (keys held while the pane is
    # made), then a second split SPLIT_GAP later with its own line. Each line must run in the pane made for it,
    # exactly once, and in no other pane (ext_smoke's smoke_new_terminals, the gate's own check). Normal mode only:
    # --diagnostic waits out the creation hold before each line, so there it is weak.
    "split_type": {"special": True, "creates": "pane", "count": 2, "inside": True, "alone": True},
    "resize_window": {"special": True},                                           # drag the window's corner
    "drag_divider": {"special": True},                                            # drag a split's divider
    "type_line": {"special": True},                                               # a line typed into the terminal
    "paste": {"special": True},                                                   # Cmd-V of a short text
    "relaunch": {"special": True, "alone": True},                                 # Cmd-Q, then open again
    "close_all": {"special": True, "alone": True},                                # every workspace closed; leak check
    # QUIT P0 (ext_quitfuzz.py): each quit kind and kill -9 of the app, of its daemon or of both. Each ENDS its burst,
    # so it can come at once after a create, a resize or typed text (a kill during them); the `quit` oracle judges it.
    "quit_keep": {"special": True, "ends": True},
    "quit_end_sessions": {"special": True, "ends": True},
    "quit_end_everything": {"special": True, "ends": True},
    "kill_app": {"special": True, "ends": True},
    "kill_daemon": {"special": True, "ends": True},
    "kill_both": {"special": True, "ends": True},
}
# How often a plan picks each action: creates more often than closes, so the app keeps something to act on.
WEIGHTS = {"new_column": 2, "split_type": 2, "new_tab": 3, "new_workspace": 2, "split_right": 3, "split_down": 2, "new_terminal": 4, "open_url": 1,
           "close_tab": 2, "close_pane": 1, "close_workspace": 1, "switch_workspace": 2, "resize_window": 2,
           "drag_divider": 2, "type_line": 3, "paste": 1, "relaunch": 0.3, "close_all": 1}
# The action sets (journey option fuzz_set): `layout` (cmux-ad 06:42Z, fuzz-catalog row m, the first mode: the layout
# invariants R3a and R3b under the actions that change the layout) and `full` (every action above).
# `quit` (QUIT P0): creates, typing and resizes, then a quit of each kind or a kill -9, often at once after them.
SETS = {"layout": {"new_column": 3, "split_right": 3, "split_down": 2, "split_type": 3, "new_terminal": 3, "close_pane": 1.5,
                   "drag_divider": 2, "resize_window": 2, "relaunch": 0.3},
        "full": WEIGHTS,
        "quit": {"new_workspace": 2, "new_terminal": 3, "split_right": 2, "split_down": 1, "type_line": 4, "resize_window": 1.5,
                 "close_tab": 0.5, "relaunch": 0.5, "quit_keep": 1, "quit_end_sessions": 0.4, "quit_end_everything": 0.3,
                 "kill_app": 1, "kill_daemon": 0.8, "kill_both": 0.6}}
TIMINGS = {"now": 0.0, "pair": 0.06, "slow": 1.5}
TIMING_WEIGHTS = {"now": 3, "pair": 2, "slow": 4}
# A pair of creates is most often the same key twice (Cmd-D twice, Ctrl-` twice: what Lawrence hit).
SAME_PAIR = 0.6
MAX_BURST = 3
URL = "example.com"
PROBE = "fz{nonce}-{n}"
POLL = 0.025
CREATE_TIMEOUT = 20.0
SETTLE = 3.0
STALL_MS = 100.0
HOLD_SECONDS = 2.5  # driver.CREATION_HOLD_SECONDS; repeated so fuzz.py can import this file without the driver
# split_type: the second split this long after the first line's Return (cmux-ad 10:48Z: about 30 ms).
SPLIT_GAP = 0.03
SPLIT_LINES_TIMEOUT = 15.0
# Actions after which the model cannot predict counts (exact create checks and R3b are off for that burst).
DISTURB = {"close_tab", "close_pane", "close_workspace", "switch_workspace", "relaunch", "close_all", "quit_keep",
           "quit_end_sessions", "quit_end_everything", "kill_app", "kill_daemon", "kill_both"}
# Actions that change pane sizes on purpose (R3b is off for that burst).
RESIZE = {"resize_window", "drag_divider"}
# Oracles that stop the sequence and are shrunk (a wrong layout, a lost create, a crash, a leak). The others (RECORD:
# the app's own desync monitor, main-thread stalls, focus) are recorded once per signature with the seed and the
# actions so far, and the run goes on, so one early finding (a cold CEF start, a page-window desync after Cmd-N) does
# not hide the rest of the run. Both count in the verdict; fuzz.py compares each with the base build.
STOP = {"create", "r3a", "r3b", "crash", "topology", "leak", "keys", "quit"}
RECORD = {"desync", "stall", "focus"}
# Leak tolerances after close-all (see Fuzz.leak).
LEAK_FDS = 48
LEAK_HELPERS = 4
LEAK_SETTLE = 15.0

# Lawrence's reported bugs as fixed sequences (cmux-lead-status-3 items 897-914): played first by fuzz.py --corpus,
# and as journeys of their own (journeys/fuzz/lawrence-*.json, the same sequences).
CORPUS = {
    "lawrence-cmd-d-twice": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                             {"a": "split_right", "t": "pair"}, {"a": "split_right", "t": "slow"},
                             {"a": "type_line", "t": "slow"}],
    "lawrence-ctrl-backtick-twice": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                                     {"a": "new_terminal", "t": "pair"}, {"a": "new_terminal", "t": "slow"},
                                     {"a": "type_line", "t": "slow"}],
    "lawrence-no-new-workspace": [{"a": "new_workspace", "t": "now"}, {"a": "new_workspace", "t": "now"},
                                  {"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                                  {"a": "type_line", "t": "slow"}],
    "lawrence-resize": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                        {"a": "split_right", "t": "slow"}, {"a": "resize_window", "t": "slow", "by": [-320, -160]},
                        {"a": "resize_window", "t": "slow", "by": [300, 140]}, {"a": "drag_divider", "t": "slow", "by": -120},
                        {"a": "type_line", "t": "slow"}],
    "lawrence-column-widths": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                               {"a": "new_column", "t": "slow"}, {"a": "new_column", "t": "slow"},
                               {"a": "split_right", "t": "slow"}, {"a": "split_down", "t": "slow"},
                               {"a": "new_column", "t": "pair"}, {"a": "new_column", "t": "slow"}],
    # TIP RED 1193 (STATUS 1202, pa-d's red journey journeys/p0/tipred-1193-split-type-at-once.json): two fast Cmd-D,
    # each with its line typed at once; both lines ran in the second new pane on feat 5097a275a876 (cmux18, key window).
    "tipred-1193-split-type": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                               {"a": "split_type", "t": "slow", "down": [False, False]},
                               {"a": "split_type", "t": "slow", "down": [False, True]}],
    "lawrence-cmd-t-slow": [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"},
                            {"a": "new_tab", "t": "slow"}, {"a": "new_tab", "t": "pair"}, {"a": "new_tab", "t": "slow"}],
}


# The corpus entries each set plays (fuzz.py --corpus): the layout set's are the layout reports.
CORPUS_SETS = {"layout": ("tipred-1193-split-type", "lawrence-cmd-d-twice", "lawrence-ctrl-backtick-twice", "lawrence-resize", "lawrence-column-widths"),
               "full": tuple(CORPUS)}


def corpus_sequence(names):
    """The named corpus entries as one sequence, a close-all between them (one lease plays them all; ddmin keeps
    only what a failure needs)."""
    out = []
    for name in names:
        if out:
            out.append({"a": "close_all", "t": "slow", "corpus": name})
        out += [dict(i, corpus=name) for i in CORPUS[name]]
    return out


def install(driver):
    global D
    D = driver


# ---- the plan (pure: fuzz.py and the tests use it too) ----------------------------------------

def plan(seed, count, weights=None, actions="full"):
    """COUNT actions from SEED out of the set ACTIONS (SETS): [{"a": name, "t": timing, ...args}]; the same seed and
    set always give the same plan."""
    rng = random.Random(int(seed))
    table = dict(SETS[actions], **(weights or {}))
    names = sorted(n for n in ACTIONS if table.get(n, 0) > 0)
    w = [table[n] for n in names]
    timings = sorted(TIMINGS)
    tw = [TIMING_WEIGHTS[t] for t in timings]
    out = []
    while len(out) < count:
        name = rng.choices(names, w)[0]
        if out and out[-1]["t"] == "pair" and ACTIONS[out[-1]["a"]].get("creates") and rng.random() < SAME_PAIR:
            name = out[-1]["a"]
        item = {"a": name, "t": rng.choices(timings, tw)[0]}
        if ACTIONS[name].get("alone"):
            item["t"] = "slow"
            if out and out[-1]["t"] != "slow":
                out[-1]["t"] = "slow"
        elif ACTIONS[name].get("column") and out and out[-1]["t"] != "slow" and out[-1]["a"] != name:
            # New Column starts its burst (a pair of New Column stays one): R3b then knows which column must keep
            # its width exactly (all of them) and which split may change one (the split's own column).
            out[-1]["t"] = "slow"
        if name == "resize_window":
            item["by"] = [rng.randint(-320, 320), rng.randint(-200, 200)]
        elif name == "drag_divider":
            item["by"] = rng.choice((-1, 1)) * rng.randint(24, 200)
        elif name == "switch_workspace":
            item["n"] = rng.randint(1, 4)
        elif name == "split_type":
            item["down"] = [rng.random() < 0.35, rng.random() < 0.35]  # Cmd-D or Split Down, for each of the two
        out.append(item)
    return out


def bursts(seq):
    """The plan cut into bursts: actions that follow at once or as a pair, at most MAX_BURST, then a slow one; an
    `alone` action (relaunch, close-all, split + type) is always a burst of its own."""
    out, cur = [], []
    for item in seq:
        if cur and ACTIONS.get(item["a"], {}).get("alone"):
            out.append(cur)  # an `alone` action is a burst of its own: it never joins the actions before it
            cur = []
        cur.append(item)
        if item.get("t", "slow") == "slow" or len(cur) >= MAX_BURST or ACTIONS.get(item["a"], {}).get("alone") \
                or ACTIONS.get(item["a"], {}).get("ends"):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def ddmin(seq, fails, budget_left=lambda: True):
    """Zeller's ddmin: the smallest subsequence (1-minimal within the budget) for which FAILS(subseq) is True.
    FAILS returns True (the same failure), False, or None (no verdict: out of budget; the search stops there)."""
    seq, n, tries = list(seq), 2, 0
    while len(seq) >= 2 and budget_left():
        size = -(-len(seq) // n)
        chunks = [seq[i:i + size] for i in range(0, len(seq), size)]
        reduced = False
        for i, chunk in enumerate(chunks):
            for cand in ([chunk] if len(chunks) > 1 else []) + [sum(chunks[:i] + chunks[i + 1:], [])]:
                if not cand or cand == seq:
                    continue
                tries += 1
                verdict = fails(cand)
                if verdict is None:
                    return seq, tries
                if verdict:
                    seq, n, reduced = cand, (2 if len(cand) == len(chunk) else max(n - 1, 2)), True
                    break
            if reduced:
                break
        if not reduced:
            if n >= len(seq):
                break
            n = min(len(seq), n * 2)
    return seq, tries


# ---- reads -------------------------------------------------------------------------------

def _rpc(j, method, params=None, timeout=10):
    try:
        return j.app.rpc(method, params or {}, timeout=timeout)
    except (D.StepError, OSError, ValueError) as error:
        return {"error": str(error)[-300:]}


def state(j):
    """The app's topology now, reduced to what the model predicts."""
    topo = j.topology()
    out = {"workspaces": [], "tabs": [], "terminals": {}, "panes": {}, "browsers": [], "focus": topo.get("focus") or {},
           "daemon_state": topo.get("daemon_state"), "columns": {}}
    for ws in topo.get("workspaces") or []:
        out["workspaces"].append(ws.get("id"))
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                out["panes"].setdefault(ws.get("id"), []).append(pane.get("id"))
                if pane.get("column") is not None:
                    out["columns"][pane.get("id")] = pane.get("column")
                for tab in pane.get("tabs") or []:
                    out["tabs"].append(tab.get("id"))
                    term = tab.get("terminal")
                    term = term.get("id") if isinstance(term, dict) else term
                    if term:
                        out["terminals"][str(tab.get("terminal_key") or term)] = {"term": str(term), "ws": ws.get("id"),
                                                                                  "pane": pane.get("id"), "tab": tab.get("id")}
                    if tab.get("kind") == "browser" or (tab.get("url") and not term):
                        out["browsers"].append(tab.get("id"))
    return out


def shown_ws(st):
    return st["focus"].get("workspace")


def surfaces(j, text=False):
    report = _rpc(j, "debug.surfaces", {"text": text}) or {}
    panes = []
    for w in report.get("windows") or [] if isinstance(report, dict) else []:
        for p in w.get("panes") or []:
            if isinstance(p, dict):
                panes.append(dict(p, window_number=w.get("window")))
    return panes


def _grid(text):
    m = re.fullmatch(r"(\d+)x(\d+)", str(text or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def drawn(p):
    """A terminal pane the window shows, not blank, with a grid Ghostty drew."""
    return bool(p.get("visible")) and not p.get("blank") and bool(_grid((p.get("surface") or {}).get("drawn_grid")))


def refusals(j):
    report = _rpc(j, "debug.toast") or {}
    return list(report.get("refusals") or []) if isinstance(report, dict) else []


def new_refusals(before, after):
    """The refusal messages AFTER has that BEFORE did not (debug.toast keeps only the newest 100: once full, a new
    message shifts the list instead of growing it, so a length compare would miss it)."""
    before, after = list(before or []), list(after or [])
    if len(after) > len(before) and after[:len(before)] == before:
        return after[len(before):]
    for k in range(len(before) + 1):  # the longest tail of BEFORE that AFTER starts with
        tail = before[k:]
        if after[:len(tail)] == tail:
            return after[len(tail):]
    return after


# A refusal that answers a split ("Not enough room to split this column / pane"): only these make a split + type round
# not judged; any other message (an error toast of the bug under test) never hides a red.
SPLIT_REFUSAL = re.compile(r"split", re.I)


def hang_records(j, after):
    report = _rpc(j, "debug.hangs", {"after": after, "limit": 200}) or {}
    rows = [r for r in report.get("records") or [] if isinstance(r, dict)] if isinstance(report, dict) else []
    return [r for r in rows if int(r.get("sequence") or 0) > after]


def cmux_frame(record):
    return any("cmux" in str(f.get("image") or "").lower() or "cmux" in str(f.get("symbol") or "").lower()
               for f in record.get("frame_details") or [] if isinstance(f, dict))


def daemon_terminals(j):
    rows = j.app.cmux("terminal", "list")
    if isinstance(rows, dict):
        rows = next((rows[k] for k in ("terminals", "value", "result") if isinstance(rows.get(k), list)), [])
    return {str(r.get("id")): r for r in rows or [] if isinstance(r, dict) and r.get("id")}


def counts(j):
    """{fds, processes, helpers, ptys}: the app's open file descriptors (numeric FDs), the bundle's processes
    (helpers, daemon, terminal hosts; `helpers`: the Chromium ones, which may stay warm) and the PTY devices those
    hold (each /dev/ttysNNN once; lsof, stock macOS)."""
    procs = j.app.bundle_processes(j.app.pid)
    pids = [j.app.pid] + [p["pid"] for p in procs]
    out = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-p", ",".join(map(str, pids))], capture_output=True,
                         text=True, timeout=90).stdout.splitlines()
    fds = 0
    for line in out[1:]:
        parts = line.split()
        if len(parts) > 3 and parts[1] == str(j.app.pid) and re.fullmatch(r"\d+[rwu]?", parts[3]):
            fds += 1
    ptys = len(set(re.findall(r"/dev/ttys\d+", "\n".join(out))))
    return {"fds": fds, "processes": len(procs), "ptys": ptys,
            "helpers": sum(1 for p in procs if "Helper" in p["command"])}


# ---- the run -------------------------------------------------------------------------------

class Fuzz:
    def __init__(self, j, step):
        self.j = j
        opts = j.spec.get("options") or {}
        self.diagnostic = opts.get("fuzz_mode") == "diagnostic" or opts.get("smoke_mode") == "diagnostic"
        if not self.diagnostic and not getattr(j, "smoke_key_ok", False):
            # Normal mode types at once after each create and reads focus against AppKit's first responder: both need
            # the app's window to be key (smoke_make_key, a whole-host lease with the app active). Without it the run
            # would report the slot's limit as product reds: "not run", never a pass or a red.
            raise D.NotRun("known gap: the window did not become key (debug.window.focus "
                           f"{json.dumps(getattr(j, 'smoke_key_reply', None))[:200]}); run --diagnostic or on a granted "
                           "mini with --whole-host")
        self.seed = int(opts.get("fuzz_seed") or step.get("seed") or random.randrange(1 << 30))
        self.count = int(opts.get("fuzz_count") or step.get("count", 300))
        budget = float(opts.get("fuzz_budget_s") or step.get("budget_s", 200))
        self.end = min(D.now() + budget, j.deadline - 25)
        # Shrinking inside the app keeps the lease while no new journey step runs (cmux-ad 09:05Z: never hold a lease
        # while you shrink): off by default; fuzz.py shrinks with one short lease per ddmin try. On only on request.
        self.shrink = str(opts.get("fuzz_shrink", step.get("shrink", False))).lower() in ("true", "1", "yes")
        seq = step.get("sequence")
        if opts.get("fuzz_sequence"):
            seq = json.loads(opts["fuzz_sequence"])
        self.set = str(opts.get("fuzz_set") or step.get("set", "full"))
        if self.set not in SETS:
            raise D.StepError(f"fuzz_run: set is one of {sorted(SETS)}, not {self.set!r}")
        self.sequence = list(seq) if seq else plan(self.seed, self.count, step.get("weights"), self.set)
        if not seq and self.set == "full":
            # The leak oracle compares each close-all with the first one: a seeded plan starts with one (the baseline,
            # after which warm singletons exist) only once something was made, so it ends with one too.
            self.sequence = self.sequence[:max(0, self.count - 1)] + [{"a": "close_all", "t": "slow"}]
        self.source = "sequence" if seq else "seed"
        # The layout set starts every run and every shrink try from the same state: no workspace (each one closed
        # through the app's own closeWorkspace), then a Ctrl-` that opens a fresh workspace with a terminal. A shrink
        # try then replays from where the run began, not from a workspace an earlier try changed.
        self.fresh = str(opts.get("fuzz_fresh", step.get("fresh", "layout"))) in ("true", "1", "yes") or \
            str(opts.get("fuzz_fresh", step.get("fresh", "layout"))) == "layout" and \
            str(opts.get("fuzz_set") or step.get("set", "full")) == "layout"
        self.baseline = set() if self.fresh else set(getattr(j, "smoke_baseline", None) or state(j)["workspaces"])
        self.n = 0
        self.probes = 0
        self.pty_tags = {}
        self.last_create = None
        self.hang_seq = max([int(r.get("sequence") or 0) for r in hang_records(j, 0)] or [0])
        self.leak_base = None
        self.speed, self.played, self.notes = [], [], []
        self.findings = {}  # signature -> {oracle, signature, detail, count, first_n, sequence}
        # split + type at once: plays, plays whose keys took the hold path, reds, passes on the hold path (judged),
        # passes with no held key (not judged: the hold path was not exercised).
        self.split_stats = {"played": 0, "hold": 0, "red": 0, "pass_hold": 0, "pass_not_judged": 0, "refused": 0,
                            "creation_hold": 0}
        # Size history per terminal (journey option fuzz_trace=1; on in replays): every change of the daemon's size
        # (`cmux terminal list`), of the app's grid / fit_grid / drawn grid (debug.surfaces) and every SIGWINCH the
        # shell saw (a trap prints `FZW rows cols`), each with its ms since the run began: whether a size reached
        # the PTY at any time, or only a report field.
        self.trace_on = str(opts.get("fuzz_trace", step.get("trace", ""))).lower() in ("1", "true", "yes")
        self.trace, self.trace_last, self.t0 = {}, {}, D.now()

    def left(self):
        return D.now() < self.end

    # -- input --

    def wait_hold(self):
        """Diagnostic: every key after a create waits out the creation hold (a slot has no key window)."""
        if self.diagnostic and self.last_create is not None:
            self.j.outwait_creation_hold(self.last_create)

    def press(self, key, mods=()):
        self.wait_hold()
        t = D.now()
        reply = self.j.key(key, list(mods))
        return t, reply

    def type_text(self, text):
        """Types TEXT and Return, one debug.key per key; returns each key's path (debug.key `handled_by`: "app" is the
        router's hold, a key held for a terminal still being made and replayed there; "responder" a key that went
        straight to the focused view), the same per-key record as ext_smoke's smoke_type_now."""
        self.wait_hold()
        replies = [self.j.key(ch, []) for ch in text] + [self.j.key("return", [])]
        return [str(r.get("handled_by")) if isinstance(r, dict) else "?" for r in replies]

    def answer_dialog(self):
        """A close that asks (a running process): its default, as Return does."""
        report = _rpc(self.j, "debug.dialog") or {}
        shown = [d for d in report.get("dialogs") or [] if isinstance(d, dict) and d.get("visible")] if isinstance(report, dict) else []
        if shown:
            _rpc(self.j, "debug.dialog", {"key": "return"})
            return shown[-1].get("title")
        return None

    def play(self, item, before):
        """Plays one action; returns its record. An action whose input path fails (the app died mid-burst, a drag or
        a quit that did not take) is recorded with its error, so the oracles (crash first) judge what is left."""
        try:
            return self.play_one(item, before)
        except (D.StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            if ACTIONS[item["a"]].get("creates"):
                self.last_create = D.now()
            return {"a": item["a"], "t": item.get("t", "slow"), "at": D.now(), "error": str(error)[-300:]}

    def play_one(self, item, before):
        name, j = item["a"], self.j
        spec = ACTIONS[name]
        rec = {"a": name, "t": item.get("t", "slow")}
        if "key" in spec:
            rec["at"], reply = self.press(spec["key"], spec["mods"])
            rec["reply"] = {k: reply.get(k) for k in ("handled_by", "error")} if isinstance(reply, dict) else reply
        elif "action" in spec:
            self.wait_hold()
            rec["at"] = D.now()
            rec["reply"] = _rpc(j, "action.run", {"action": spec["action"], "args": {}, "focus": True})
        elif name == "open_url":
            rec["at"], _ = self.press("l", ["cmd", "shift"])
            rec["typeable_ms"] = self.wait_focus("addressBar", rec["at"])
            for ch in URL:
                j.key(ch, [])
            j.key("return", [])
        elif name == "switch_workspace":
            rec["at"], _ = self.press(str(item.get("n", 1)), ["cmd"])
        elif name == "split_type":
            rec.update(self.split_type(item))
        elif name == "resize_window":
            self.wait_hold()
            rec["at"] = D.now()
            j.ext_window = None
            rec["drag"] = _short(j.step_window_drag({"edge": "bottom-right", "by": item.get("by", [-200, -100]), "events": 20}))
        elif name == "drag_divider":
            self.wait_hold()
            rec["at"] = D.now()
            rec["drag"] = self.drag_divider(item.get("by", 80))
        elif name == "type_line":
            rec["at"] = D.now()
            rec["probe"] = self.probe(before, require_new=False)
        elif name == "paste" and not self.focused_terminal():
            rec["at"], rec["skipped"] = D.now(), "the focused tab is not a terminal (Return would submit a field)"
        elif name == "paste":
            # A comment line: the shell runs nothing, and Return leaves the line empty for the next probe.
            text = f": fzp{j.nonce}{self.n}"
            subprocess.run(["/usr/bin/pbcopy"], input=text.encode(), timeout=10, check=False)
            rec["at"], _ = self.press("v", ["cmd"])
            j.key("return", [])
            rec["pasted"] = text
        elif name == "relaunch":
            self.wait_hold()
            rec["at"] = D.now()
            rec["relaunch"] = _short(j.step_relaunch({"how": "quit"}))
            self.last_create = None
        elif name == "close_all":
            self.wait_hold()
            rec["at"] = D.now()
            rec["closed"] = self.close_all()
        elif spec.get("ends"):
            import ext_quitfuzz  # the quit and kill actions (same folder; loaded by the driver too)
            rec.update(ext_quitfuzz.play(self, name, before))
            if "relaunch" in rec:
                rec["relaunch"] = _short(rec["relaunch"])
            self.last_create = None
        if spec.get("creates"):
            self.last_create = rec.get("at", D.now())
        if spec.get("closes"):
            rec["dialog"] = self.answer_dialog()
        return rec

    def creation_hook(self, action, n=None, stand_in=None):
        """The P0 1193 owner's DEBUG hook (#29301, `debug.creation.hold {n}` / `debug.creation.release {n?}`): its reply,
        or None on a build without it (remembered for the run: the plain timing variant is used there)."""
        if getattr(self, "has_creation_hook", None) is False:
            return None
        try:
            params = {} if n is None else {"n": n}
            if stand_in:
                params["stand_in"] = stand_in
            reply = self.j.app.rpc("debug.creation." + action, params, timeout=10)
        except (D.StepError, OSError, ValueError) as error:
            text = str(error).lower()
            if "method_not_found" in text or "unknown method" in text or "not found" in text:
                self.has_creation_hook = False
                return None
            raise
        self.has_creation_hook = True
        return reply if isinstance(reply, dict) else {}

    def wait_new_view(self, split_pane, timeout=5.0):
        """pa-d's smoke_wait_new_view (1ee7b743983): until AppKit's first responder of the key window is a terminal view
        in another pane than SPLIT_PANE (debug.focus appkit first_responder "TerminalSurfaceView", classified
        "content:<pane>"): the new pane's early view has the keyboard. Reads only; True when reached."""
        if not split_pane:
            return False  # pa-d's rule: without the split pane, the old pane's own terminal would pass at once
        end = D.now() + timeout
        while D.now() < end:
            report = _rpc(self.j, "debug.focus") or {}
            for w in report.get("windows") or [] if isinstance(report, dict) else []:
                if not isinstance(w, dict):
                    continue
                kit = w.get("appkit") or {}
                where = str(kit.get("classified") or "")
                if w.get("is_key") and kit.get("first_responder") == "TerminalSurfaceView" and where.startswith("content:") \
                        and where[len("content:"):] not in ("", split_pane):
                    return True
            time.sleep(0.075)
        return False

    def split_type(self, item):
        """Two splits, each followed at once by its own line (see ACTIONS["split_type"]); returns the record with the
        lines and the snapshot name the oracle reads.

        On a build with the creation hold hook (#29301, STATUS 1428, pa-d's tipred-1193-stand-in journey): hold
        {"n": [1], "stand_in": [2]} (creation 1's reply held, creation 2's stand-in kept out of the store, so its focus
        cannot land: the memory-pressure state on purpose), first split, wait until the new pane's view is AppKit's
        first responder, line 1 at once, second split, line 2 at once, release {}. Proven by the release reply: a second
        creation started, creation 1 in `resumed`, `shown` == [2]; never assumed. On a build without the hook: the plain timing, where
        the hold path is proven only by a key the router held (handled_by "app")."""
        import ext_smoke  # beside this file
        j = self.j
        if not self.focused_terminal():
            # Cmd-D on Home or on a page splits nothing a line can be typed in: nothing to judge (the layout set's
            # ensure_target puts a workspace with a terminal first).
            return {"at": D.now(), "skipped": "the focused tab is not a terminal"}
        self.splits = getattr(self, "splits", 0) + 1
        snap = f"fz-split-{self.splits}"
        ext_smoke.step_smoke_snapshot(j, {"name": snap})
        refused_before = refusals(j)
        # The split pane as pa-d reads it (debug.surfaces' focused pane), else the topology's focus.
        split_pane = next((p.get("pane") for p in surfaces(j) if p.get("focused")), None) or state(j)["focus"].get("pane")
        hold = None if self.diagnostic else self.creation_hook("hold", [1], stand_in=[2])
        lines, at, paths, release, reached = [], None, [], None, None
        try:
            for k, down in enumerate(item.get("down") or [False, False]):
                if k:
                    time.sleep(SPLIT_GAP)
                t, _ = self.press("d", ["cmd", "shift"] if down else ["cmd"])
                at = at or t
                self.last_create = t
                if k == 0 and hold is not None:
                    reached = self.wait_new_view(split_pane)
                line = f"st{j.nonce}-{self.splits}-{k + 1}"
                # At once in normal mode (type_text waits out the creation hold only in --diagnostic).
                paths.append(self.type_text(f"echo {line}"))
                lines.append(line)
        finally:
            if hold is not None:
                release = self.creation_hook("release")  # every held creation, and the hook disarmed, on any path
        rec = {"at": at, "split_lines": lines, "split_snapshot": snap, "at_once": not self.diagnostic,
               "split_paths": [{"line": ln, "held": p.count("app"), "paths": sorted(set(p))} for ln, p in zip(lines, paths)],
               "refused_before": refused_before}
        held = sum(p.count("app") for p in paths)
        if hold is not None:
            # The hook's own report (pa-d's _creation_proof with `resumed`): creation 1 waited for this release, and
            # the second split started while it was held.
            ints = lambda key: [int(x) for x in (release or {}).get(key) or [] if isinstance(x, (int, float))]
            proven = int((release or {}).get("started") or 0) >= 2 and 1 in ints("resumed") and sorted(ints("shown")) == [2]
            rec.update(variant="creation-hold", hold_path=proven, held_keys=held, creation_release=release,
                       new_view_focused=reached)
        else:
            # The hold-path rule of pa-d's TIP RED 1193 journey (ext_smoke smoke_hold_path, 90e79d90d35; cmux-ad
            # 11:05Z): a pass counts only when at least one key typed at once after a split was held by the router.
            rec.update(variant="plain", hold_path=held > 0, held_keys=held)
        return rec

    def split_lines(self, rec):
        """The split_type oracle: ext_smoke.cond_smoke_new_terminals (placement new_panes, the last line on the focused
        terminal), polled until it holds or SPLIT_LINES_TIMEOUT."""
        import ext_smoke
        refused = [m for m in new_refusals(rec.get("refused_before"), refusals(self.j)) if SPLIT_REFUSAL.search(str(m))]
        if refused:
            # A split the app refused with a visible message ("Not enough room to split this column"): its line goes to
            # the pane that has the keys, as it should. Not judged; the create oracle records the refusal.
            rec["refused"] = refused[-2:]
            return []
        want = {"since": rec["split_snapshot"], "lines": rec["split_lines"], "focused": rec["split_lines"][-1],
                "placement": "new_panes"}
        end, detail = D.now() + SPLIT_LINES_TIMEOUT, {}
        while True:
            ok, detail = ext_smoke.cond_smoke_new_terminals(self.j, want, {})
            if ok:
                return []
            if D.now() >= end:
                return [("keys", f"split + type at once{'' if rec.get('at_once') else ' (diagnostic: after the hold)'}: "
                                 f"{'; '.join(detail.get('problems') or [])} (holders {json.dumps(detail.get('holders'))[:300]})")]
            time.sleep(0.25)

    def focused_terminal(self):
        st = state(self.j)
        tab = st["focus"].get("tab")
        return any(t["tab"] == tab for t in st["terminals"].values())

    def wait_focus(self, kind, since, timeout=CREATE_TIMEOUT):
        end = D.now() + timeout
        while D.now() < end:
            focus = _rpc(self.j, "debug.focus") or {}
            if any((w.get("model") or {}).get("resolved") == kind for w in focus.get("windows") or [] if isinstance(w, dict)):
                return round((D.now() - since) * 1000)
            time.sleep(POLL)
        return None

    def drag_divider(self, by):
        """Drags the divider between two side-by-side panes of the shown workspace (ext_window's divider_drag)."""
        j = self.j
        panes = [p for p in surfaces(j) if p.get("visible") and (p.get("grid") or {}).get("frame_width")]
        frames = [((p["grid"]["frame_x"], p["grid"]["frame_y"], p["grid"]["frame_width"], p["grid"]["frame_height"]), p) for p in panes]
        for fa, a in frames:
            for fb, b in frames:
                if a is b or a["grid"].get("window") != b["grid"].get("window"):
                    continue
                if abs(fb[0] - (fa[0] + fa[2])) < 12 or abs(fb[1] - (fa[1] + fa[3])) < 12:
                    j.ext_panes = {"fa": {"pane": a.get("pane"), "window": a["grid"].get("window")},
                                   "fb": {"pane": b.get("pane"), "window": b["grid"].get("window")}}
                    try:
                        return _short(j.step_divider_drag({"between": ["fa", "fb"], "by": by, "events": 20}))
                    except D.StepError as error:
                        return {"error": str(error)[-200:]}
        return {"skipped": "no two panes side by side"}

    def close_all(self):
        j, closed = self.j, []
        for wid in state(j)["workspaces"]:
            if wid not in self.baseline:
                _rpc(j, "action.run", {"action": "closeWorkspace", "target": f"workspace:{wid}", "args": {"confirm": True}})
                closed.append(wid)
        end = D.now() + 15
        while D.now() < end and any(w not in self.baseline for w in state(j)["workspaces"]):
            self.answer_dialog()
            time.sleep(0.2)
        return closed

    # -- oracles --

    def predict(self, burst, before):
        """The model's change for the burst: the least increase of workspaces, tabs, terminals, browsers, and
        panes of the workspace shown at the end, and whether it is `exact`. A close or a switch (DISTURB) makes the
        burst inexact: the model does not know what shows after it, so it asks only that something new appear
        (a tab or workspace id not there before) when a create that always makes something (Cmd-N; Ctrl-`, which
        opens a workspace on Home) follows it. A create on Home that needs a workspace (Cmd-D, Cmd-T, Cmd-Shift-L)
        is not predicted. A close or switch after the last create may undo it: nothing is predicted then."""
        want = {"workspaces": 0, "tabs": 0, "terminals": 0, "browsers": 0, "panes": 0}
        none = ({k: 0 for k in want}, False)
        creates = [k for k, i in enumerate(burst) if ACTIONS[i["a"]].get("creates")]
        if not creates or any(i["a"] in DISTURB for i in burst[creates[-1] + 1:]):
            return none
        on_ws = True if shown_ws(before) else False  # True, False (Home) or None (not known)
        exact, sure = True, False
        for item in burst:
            kind = ACTIONS[item["a"]].get("creates")
            if item["a"] in DISTURB:
                # It may undo what came before it in the burst: only the creates after it count.
                exact, on_ws, sure = False, None, False
                want = {k: 0 for k in want}
            elif kind == "workspace":
                want["workspaces"] += 1
                want["panes"] = 0  # the shown workspace changes: delta counts the new one's panes only
                on_ws, sure = True, True
            elif kind == "terminal":
                want["terminals"] += 1
                want["tabs"] += 1
                if on_ws is False:
                    want["workspaces"] += 1
                    want["panes"] = 0  # Ctrl-` on Home opens a workspace: it is the shown one now
                elif on_ws is None:
                    exact = False
                on_ws, sure = True, True
            elif kind in ("pane", "tab_page", "browser"):
                if on_ws is not True:
                    exact = False
                    continue
                n = int(ACTIONS[item["a"]].get("count", 1))
                want["tabs"] += n
                if kind == "pane":
                    want["panes"] += n
                    want["terminals"] += n
                sure = True
        if not exact and not sure:
            return none
        return want, exact

    def delta(self, before, after):
        """What the burst made: the ids in AFTER that BEFORE did not have (workspaces, tabs, terminals, panes of the
        shown workspace), never a net count. A close that lands late (after this burst's baseline, as on cmux20 at
        11:3xZ: a close_pane, then New Column drew a new terminal while the net counts said 0) cannot hide a create."""
        ws = shown_ws(after)
        old_panes = {p for ps in before["panes"].values() for p in ps}
        return {"workspaces": len(set(after["workspaces"]) - set(before["workspaces"])),
                "tabs": len(set(after["tabs"]) - set(before["tabs"])),
                "terminals": len(set(after["terminals"]) - set(before["terminals"])),
                "browsers": len(set(after["browsers"]) - set(before["browsers"])),
                "panes": len(set(after["panes"].get(ws, [])) - old_panes)}

    def trace_sizes(self, st=None):
        """One sample of every terminal's sizes into self.trace (only changes are kept)."""
        if not self.trace_on:
            return
        ms = round((D.now() - self.t0) * 1000)
        try:
            for term, row in daemon_terminals(self.j).items():
                self._trace(term, "daemon", f"{row.get('cols')}x{row.get('rows')}", ms)
        except D.StepError:
            pass
        st = st or state(self.j)
        # The app's own invariant counters (debug.surfaces; R3a/R3b are counted there on builds with #29056): a change
        # across an action tells a real size fault from a stale report field.
        report = _rpc(self.j, "debug.surfaces") or {}
        if isinstance(report, dict) and "invariant_violations" in report:
            self._trace("app", "invariants", f"violations {report.get('invariant_violations')} checks "
                                             f"{report.get('invariant_checks')}", ms)
        for p in surfaces(self.j, text=True):
            term = (st["terminals"].get(str(p.get("terminal_id") or "")) or {}).get("term")
            if not term:
                continue
            surf = p.get("surface") or {}
            self._trace(term, "app", f"grid {surf.get('grid')} fit {surf.get('fit_grid')} drawn {surf.get('drawn_grid')}", ms)
            winch = re.findall(r"FZW (\d+) (\d+)", p.get("text") or "")
            if winch:
                self._trace(term, "winch", " ".join(f"{c}x{r}" for r, c in winch), ms)

    def _trace(self, term, source, value, ms):
        key = (term, source)
        if self.trace_last.get(key) != value:
            self.trace_last[key] = value
            self.trace.setdefault(term, []).append([ms, source, value])

    def arm_winch(self, term_key):
        """In the new terminal: a SIGWINCH trap that prints the PTY's new size (traced runs only)."""
        if self.trace_on:
            self.type_text("trap 'echo FZW $(stty size)' WINCH")

    def creates(self, burst, before, recs, refused_before):
        """The `create` oracle and the speed marks: polls until the model's prediction holds or CREATE_TIMEOUT."""
        want, exact = self.predict(burst, before)
        if not any(want.values()):
            return [], None, exact
        made = [r for r in recs if ACTIONS[r["a"]].get("creates") and not r.get("skipped")]
        t_end = D.now() + CREATE_TIMEOUT
        after, got = before, {}
        old = set(before["terminals"])
        shown_at, prompt_at = {}, {}
        # Inexact (a close or a switch in the burst): something new must appear (a tab or workspace id not there before).
        old_ids = set(before["tabs"]) | set(before["workspaces"])
        fresh = lambda: bool((set(after["tabs"]) | set(after["workspaces"])) - old_ids)
        held = lambda g: all(g[k] >= v for k, v in want.items() if v > 0) if exact else fresh()
        while D.now() < t_end:
            after = state(self.j)
            self.trace_sizes(after)
            got = self.delta(before, after)
            new = [k for k in after["terminals"] if k not in old]
            for p in surfaces(self.j, text=bool(new)):
                key = str(p.get("terminal_id") or "")
                if key in new and drawn(p):
                    shown_at.setdefault(key, D.now())
                    if (p.get("text") or "").strip():
                        prompt_at.setdefault(key, D.now())
            if held(got) and all(k in prompt_at for k in new[:want["terminals"]]):
                break
            time.sleep(POLL)
        done_at = D.now()
        # Speed: the k-th terminal-making action gets the k-th new terminal (by when it showed), from its own key.
        order = sorted(shown_at, key=shown_at.get)
        terms = [r for r in made if ACTIONS[r["a"]]["creates"] in ("terminal", "pane")]
        for r, key in zip(terms, order):
            r["shown_ms"] = round((shown_at[key] - r["at"]) * 1000)
            if key in prompt_at:
                r["typeable_ms"] = round((prompt_at[key] - r["at"]) * 1000)
        for r in made:
            if ACTIONS[r["a"]]["creates"] in ("workspace", "tab_page") and "shown_ms" not in r and held(got):
                r["shown_ms"] = round((done_at - r["at"]) * 1000)
            if ACTIONS[r["a"]]["creates"] == "tab_page" and r is made[-1]:
                r["typeable_ms"] = self.new_tab_field(r["at"])
        problems = []
        if not held(got):
            refused = new_refusals(refused_before, refusals(self.j))
            if refused:
                self.notes.append({"n": self.n, "refused": refused[-3:], "want": want, "got": got})
            else:
                problems.append(("create", f"{'+'.join(i['a'] for i in burst)}: wanted {want}{'' if exact else ' (any)'}, "
                                           f"got {got}, and no refusal shown within {CREATE_TIMEOUT:g} s"))
        return problems, after, exact

    def new_tab_field(self, since, timeout=10.0):
        end = D.now() + timeout
        while D.now() < end:
            field = _rpc(self.j, "debug.new_tab", {"action": "field"}) or {}
            if isinstance(field, dict) and field.get("focused") is True:
                return round((D.now() - since) * 1000)
            time.sleep(POLL * 2)
        return None

    def probe(self, before, require_new=True):
        """Types a probe line into the focused terminal: it must run on exactly one terminal (a new one when the
        burst made one) and print the PTY's size (R3a)."""
        j = self.j
        st = state(j)
        tab = st["focus"].get("tab")
        if not any(t["tab"] == tab for t in st["terminals"].values()):
            return {"skipped": "the focused tab is not a terminal"}
        self.probes += 1
        line = PROBE.format(nonce=j.nonce, n=self.probes)
        self.type_text(f"echo {line} $(stty size)")
        end = D.now() + 15
        holders = {}
        while D.now() < end:
            holders = {}
            for key, t in state(j)["terminals"].items():
                try:
                    text = j.app.screen(t["term"])
                except D.StepError:
                    continue
                for row in (text.get("text") or "").split("\n"):
                    m = re.fullmatch(re.escape(line) + r" (\d+) (\d+)", row.strip())
                    if m:
                        holders[key] = {"term": t["term"], "rows": int(m.group(1)), "cols": int(m.group(2)),
                                        "daemon": [text.get("cols"), text.get("rows")]}
            if holders:
                break
            time.sleep(0.1)
        new = [k for k in st["terminals"] if k not in before["terminals"]]
        out = {"line": line, "on": sorted(holders)}
        problems = []
        if len(holders) != 1:
            problems.append(("create" if require_new else "keys", f"the probe {line} ran on {len(holders)} terminals, not 1"))
        elif require_new and new and next(iter(holders)) not in new:
            problems.append(("create", f"the probe {line} ran on the old terminal {next(iter(holders))}, not a new one {new}"))
        out["problems"] = problems
        if len(holders) == 1:
            self.pty_tags = {next(iter(holders.values()))["term"]: line}
        return out

    def r3a(self, st, pty_tags=None):
        """R3a for every terminal the window shows, judged by the smoke gate's own condition (ext_smoke.cond_smoke_r3):
        grid == fitted grid == drawn grid == fit(the view's frame at the cell size) == the daemon's screen size ==
        the topology tab's size, and, where a probe printed `stty size` (PTY_TAGS: {daemon terminal: tag}), == the
        PTY's size."""
        import ext_smoke  # beside this file (the driver loads every ext_*.py from here)
        problems = []
        if not hasattr(self.j, "smoke_named"):
            self.j.smoke_named = {}
        for p in surfaces(self.j):
            if not p.get("visible") or p.get("blank") or not _grid((p.get("surface") or {}).get("grid")):
                continue
            term = st["terminals"].get(str(p.get("terminal_id") or ""))
            if not term:
                continue
            name = "fz-r3a"
            self.j.smoke_named[name] = {"pane": p.get("pane"), "term": term["term"], "workspace": term["ws"]}
            want = {"pane": name}
            if pty_tags and pty_tags.get(term["term"]):
                want["pty_tag"] = pty_tags[term["term"]]
            try:
                ok, detail = ext_smoke.cond_smoke_r3(self.j, want, {})
            except D.StepError as error:
                self.notes.append({"n": self.n, "r3a_read": str(error)[-160:]})
                continue
            if not ok:
                problems.append(("r3a", f"pane {p.get('pane')} terminal {term['term']}: {'; '.join(detail.get('problems') or [])} "
                                        f"(sizes {json.dumps(detail.get('sizes'))})"))
        return problems

    def widths(self):
        """The smoke gate's column snapshot (ext_smoke._widths/_columns: the topology's `column` of each pane and
        the union of its panes' view frames) of the shown workspace: the same R3b reading as the gate's step."""
        import ext_smoke  # beside this file (the driver loads every ext_*.py from here)
        ws = shown_ws(state(self.j))
        if not ws:
            return None
        return {"workspace": ws, "widths": ext_smoke._widths(self.j, ws), "columns": ext_smoke._columns(self.j, ws)}

    @staticmethod
    def split_column(burst, before, snap):
        """The column a split inside a column may change (cmux-ad 08:06Z): the focused pane's column before the burst,
        when a Cmd-D or Split Down comes before any New Column in the burst (after a New Column, the focus and every
        later split are in the new column, which the snapshot does not have). None: every old column is exact."""
        for item in burst:
            if ACTIONS[item["a"]].get("column"):
                return None
            if ACTIONS[item["a"]].get("inside"):
                pane = before["focus"].get("pane")
                return next((k for k, m in (snap or {}).get("columns", {}).items() if pane in m), None)
        return None

    def r3b(self, snap, before, after, exempt=None):
        """Every column the snapshot had (matched by its panes, as ext_smoke.cond_smoke_same_widths does) keeps its
        exact width (0.01 pt), except EXEMPT (the column a Cmd-D or Split Down split inside)."""
        if not snap or not after or shown_ws(after) != snap["workspace"]:
            return []
        import ext_smoke
        now_cols = ext_smoke._columns(self.j, snap["workspace"])
        now_w = ext_smoke._widths(self.j, snap["workspace"])
        problems = []
        for index, members in snap["columns"].items():
            match = next((k for k, m in now_cols.items() if set(members) <= set(m)), None)
            old, new = snap["widths"].get(index), now_w.get(match) if match is not None else None
            if match is None or old is None or new is None or index == exempt:
                continue  # closed, scrolled out of view, or the column a split inside a column may change
            if abs(old - new) > 0.01:
                what = "a split inside another column" if exempt is not None else "a new column"
                problems.append(("r3b", f"column {index} (panes {members}): width {old:g} -> {new:g} after {what}"))
        return problems

    def focus(self):
        def read():
            report = _rpc(self.j, "debug.focus") or {}
            out = []
            for w in report.get("windows") or [] if isinstance(report, dict) else []:
                if not isinstance(w, dict):
                    continue
                if w.get("consistent") is False or w.get("mismatches"):
                    out.append(f"window {w.get('id')}: model {(w.get('model') or {}).get('resolved')} vs first responder "
                               f"{(w.get('appkit') or {}).get('classified')}: {json.dumps(w.get('mismatches'))[:200]}")
            return out
        found = read()
        if found:
            time.sleep(0.5)
            again = read()
            found = [f for f in found if f.split(":")[0] in {g.split(":")[0] for g in again}]
        if self.diagnostic and found:
            # A slot has no key window: AppKit's first responder is not the person's; kept, never a red.
            self.notes.append({"n": self.n, "focus_weak": found[:3]})
            return []
        return [("focus", f) for f in found]

    def topology(self, st, closed_all=False):
        problems = []
        try:
            daemon = daemon_terminals(self.j)
        except D.StepError as error:
            return [("topology", f"cmux terminal list failed: {str(error)[-200:]}")]
        app_terms = {t["term"] for t in st["terminals"].values()}
        missing = sorted(app_terms - set(daemon))
        if missing:
            problems.append(("topology", f"the app shows terminals the daemon does not have: {missing[:6]}"))
        live = {k for k, r in daemon.items() if str(r.get("lifecycle") or "live") not in ("exited", "dead", "closed")}
        extra = sorted(live - app_terms)
        if extra:
            # Closed tabs may stay in the daemon for undo (the closed history); the leak oracle counts their PTYs.
            self.notes.append({"n": self.n, "daemon_only_terminals": extra[:6], "after_close_all": closed_all})
        check = (_rpc(self.j, "debug.desync", {"check": True}) or {}).get("check") or {}
        for v in check.get("violations") or [] if isinstance(check, dict) else []:
            problems.append(("desync", f"{v.get('invariant')}: {str(v.get('detail'))[:200]}"))
        return problems

    def crash(self, st, relaunched):
        problems = []
        if not self.j.app.alive(self.j.app.pid):
            return [("crash", f"the app (pid {self.j.app.pid}) is gone")]
        if st and st.get("daemon_state") != "connected":
            problems.append(("crash", f"daemon_state {st.get('daemon_state')}"))
        if relaunched:
            rec = (_rpc(self.j, "debug.crashes") or {}).get("launch") or {}
            if isinstance(rec, dict) and rec.get("recovery") not in (None, "clean"):
                problems.append(("crash", f"after the quit, the launch says recovery {rec.get('recovery')}"))
        return problems

    def stalls(self):
        rows = hang_records(self.j, self.hang_seq)
        if rows:
            self.hang_seq = max(int(r.get("sequence") or 0) for r in rows)
        problems = []
        for r in rows:
            ms = float(r.get("duration_ms") or 0)
            if ms <= STALL_MS:
                continue
            if cmux_frame(r):
                top = next((f.get("symbol") for f in r.get("frame_details") or [] if "cmux" in str(f.get("image") or "").lower()), None)
                problems.append(("stall", f"{r.get('kind')} {ms:.0f} ms on the main thread in {top}"))
            else:
                self.notes.append({"n": self.n, "stall_ms": round(ms), "kind": r.get("kind"), "attributed": False})
        return problems

    def leak_settled(self):
        """leak(), read again for up to LEAK_SETTLE seconds while it finds something (processes end, PTYs close)."""
        end = D.now() + LEAK_SETTLE
        while True:
            found, now = self.leak()
            if not found or D.now() >= end:
                return found, now
            time.sleep(1.0)

    def leak(self):
        """After close-all, against the counts of the first close-all (set then): PTYs and non-helper processes
        exactly, the app's fds within LEAK_FDS, browser helpers within LEAK_HELPERS (Chromium keeps its GPU,
        network and a spare renderer warm). A relaunch starts a new baseline."""
        now = counts(self.j)
        if self.leak_base is None:
            self.leak_base = now
            return [], now
        base, problems = self.leak_base, []
        if now["ptys"] > base["ptys"]:
            problems.append(("leak", f"PTYs {base['ptys']} -> {now['ptys']} after close-all"))
        if now["processes"] - now["helpers"] > base["processes"] - base["helpers"]:
            problems.append(("leak", f"processes other than browser helpers {base['processes'] - base['helpers']} -> "
                                     f"{now['processes'] - now['helpers']} after close-all"))
        if now["helpers"] > base["helpers"] + LEAK_HELPERS:
            problems.append(("leak", f"browser helpers {base['helpers']} -> {now['helpers']} after close-all"))
        if now["fds"] > base["fds"] + LEAK_FDS:
            problems.append(("leak", f"app fds {base['fds']} -> {now['fds']} after close-all"))
        return problems, now

    def settle_check(self, fn):
        """An oracle must hold within SETTLE seconds (a layout in flight is not a failure); its last reading."""
        end = D.now() + SETTLE
        while True:
            self.trace_sizes()
            found = fn()
            if not found or D.now() >= end:
                return found
            time.sleep(0.25)

    # -- one burst --

    def run_burst(self, burst):
        j = self.j
        names = [i["a"] for i in burst]
        # The quit oracle (ext_quitfuzz.merged): a close in this burst may be in flight at its end.
        self.burst_closes = any(ACTIONS[a].get("closes") for a in names)
        before = state(j)
        # R3b: a burst whose only layout changes are its creates (no resize, drag, close or switch in it) and that
        # makes a column or splits inside one.
        column = any(ACTIONS[a].get("column") or ACTIONS[a].get("inside") for a in names) \
            and not any(a in DISTURB or a in RESIZE for a in names)
        before_w = self.widths() if column else None
        refused_before = refusals(j) if any(ACTIONS[a].get("creates") for a in names) else []
        recs = []
        for k, item in enumerate(burst):
            self.n += 1
            recs.append(self.play(item, before))
            if k + 1 < len(burst):
                gap = TIMINGS.get(item.get("t"), 0.0)
                if gap:
                    time.sleep(gap)
        # A create whose action skipped itself (split_type on a page: no key pressed) predicts nothing.
        judged = [i for i, r in zip(burst, recs) if not r.get("skipped")]
        problems, after, exact = self.creates(judged, before, recs, refused_before) if judged else ([], None, True)
        for r in recs:
            if r.get("error") and r["a"] in ("relaunch",):
                problems.append(("crash", f"relaunch failed: {r['error'][:200]}"))
        for r in recs:
            if r["a"] == "type_line":
                problems += (r.get("probe") or {}).get("problems", [])
            if r.get("split_lines") and any(p[0] == "create" for p in problems):
                self.split_stats["played"] += 1  # the splits made no pane: a red on any path
                self.split_stats["hold"] += 1 if r.get("hold_path") else 0
                self.split_stats["red"] += 1
            elif r.get("split_lines"):
                found = self.split_lines(r)
                problems += found
                if r.get("refused"):
                    self.split_stats["refused"] += 1
                    continue
                # n(hold)/n(rounds): a pass counts only on the hold path; a red counts on any path.
                self.split_stats["played"] += 1
                self.split_stats["creation_hold"] += 1 if r.get("variant") == "creation-hold" else 0
                self.split_stats["hold"] += 1 if r.get("hold_path") else 0
                if found:
                    self.split_stats["red"] += 1
                elif r.get("hold_path"):
                    self.split_stats["pass_hold"] += 1
                else:
                    self.split_stats["pass_not_judged"] += 1
        made_terminal = any(ACTIONS[a].get("creates") in ("terminal", "pane") for a in names)
        if made_terminal and not any(p[0] == "create" for p in problems):
            self.arm_winch(None)
            pr = self.probe(before, require_new=exact)
            recs[-1]["new_probe"] = pr
            problems += pr.get("problems", [])
        closed_all = "close_all" in names
        # A new app process (a quit or a kill of the app): new launch stalls and a new resource baseline. Only a quit
        # must launch clean; a SIGKILL'd run restores without the crash notice (CrashNoticeTests), so it is not judged.
        relaunched = "relaunch" in names or any(ACTIONS[a].get("ends") and a != "kill_daemon" for a in names)
        quit_clean = "relaunch" in names or any(a.startswith("quit_") for a in names)
        if relaunched:
            # A new process: its launch stalls are not the burst's (skipped), and its resources are a new baseline.
            self.hang_seq = max([int(r.get("sequence") or 0) for r in hang_records(j, 0)] or [0])
            self.leak_base = None
        after = state(j)
        for r in recs:
            if ACTIONS[r["a"]].get("ends") and r.get("error"):
                problems.append(("quit", f"{r['a']} failed: {r['error'][:200]}"))
            elif ACTIONS[r["a"]].get("ends"):
                import ext_quitfuzz
                problems += ext_quitfuzz.oracle(self, r, after)
        problems += self.crash(after, quit_clean)
        if not any(p[0] == "crash" for p in problems):
            tags, self.pty_tags = self.pty_tags, {}
            problems += self.settle_check(lambda: self.r3a(state(j), tags))
            if before_w is not None:
                exempt = self.split_column(burst, before, before_w)
                problems += self.settle_check(lambda: self.r3b(before_w, before, state(j), exempt))
            problems += self.focus()
            problems += self.settle_check(lambda: self.topology(state(j), closed_all))
            problems += self.stalls()
            if closed_all:
                found, now = self.leak_settled()
                problems += found
                recs[-1]["counts"] = now
        for r in recs:
            if r.get("shown_ms") is not None or r.get("typeable_ms") is not None:
                self.speed.append({"a": r["a"], "t": r["t"], "shown_ms": r.get("shown_ms"), "typeable_ms": r.get("typeable_ms")})
        self.played.append({"burst": [dict(i) for i in burst], "recs": [_short(r) for r in recs],
                            "problems": [f"{o}:{d}" for o, d in problems]})
        return problems

    def play_sequence(self, seq, stop_at_first=True):
        """Plays SEQ (the oracles after each burst); the first failure: {oracle, detail, index, sequence: the actions
        played up to it, setup ones included}, or None; "budget" when the time ran out."""
        self.effective = []
        if self.fresh:
            self.close_all()
            self.last_create = None
        for burst in bursts(seq):
            if not self.left():
                return "budget"
            setup = self.ensure_target(burst)
            if setup:
                self.effective += setup
                problems = self.split(self.run_burst(setup))
                if problems and stop_at_first:
                    return self.failed(problems)
            self.effective += burst
            problems = self.split(self.run_burst(burst))
            if problems and stop_at_first:
                return self.failed(problems)
        return None

    def split(self, problems):
        """Records the RECORD oracles' problems as findings; returns the STOP ones."""
        stop = []
        for oracle, detail in problems:
            if oracle not in RECORD:
                stop.append((oracle, detail))
                continue
            sig = signature(oracle, detail)
            row = self.findings.get(sig)
            if row is None:
                self.findings[sig] = {"oracle": oracle, "signature": sig, "detail": detail, "count": 1, "first_n": self.n,
                                      "sequence": list(getattr(self, "effective", []))[-12:]}
            else:
                row["count"] += 1
        return stop

    def failed(self, problems):
        oracle, detail = problems[0]
        return {"oracle": oracle, "detail": detail, "index": len(self.effective), "sequence": list(self.effective),
                "all": [f"{o}:{d}" for o, d in problems]}

    def ensure_target(self, burst):
        """The layout set acts on a workspace: when none shows (launch, or a close took the last pane), a Ctrl-` first
        (it opens a workspace with a terminal on Home), played and kept in the sequence like any action."""
        if not (self.set == "layout" or self.fresh) or burst[0]["a"] in ("new_terminal", "new_workspace", "relaunch", "close_all"):
            return None
        if shown_ws(state(self.j)):
            return None
        return [{"a": "new_terminal", "t": "slow", "setup": True}]

    def reset(self):
        """Back to the baseline workspaces for a shrink try (the app's own closeWorkspace)."""
        self.close_all()
        self.last_create = None
        self.n += 1


def signature(oracle, detail):
    """A finding's identity across runs: ids, numbers and hex removed (`W1: appkit content:pane_ab12 (PageWebView)
    != model agentPage` and the same with another pane id are one finding)."""
    text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<uuid>", str(detail))
    text = re.sub(r"\b(pane|tab|ws|term|win|window|surface|screen)[_:][0-9a-zA-Z-]+", r"\1_*", text)
    text = re.sub(r"\b[0-9a-fA-F]{12,}\b", "<hex>", text)
    text = re.sub(r"0x[0-9a-fA-F]+|\d+(\.\d+)?", "#", text)
    return f"{oracle}:{text[:160]}"


def _short(value, limit=600):
    text = json.dumps(value, default=str)
    return value if len(text) <= limit else {"truncated": text[:limit]}


def step_fuzz_run(j, step):
    fz = Fuzz(j, step)
    j.fuzz = fz
    started = D.now()
    first = fz.play_sequence(fz.sequence)
    budget_out = first == "budget"
    failure = None if budget_out else first
    played = sum(len(b["burst"]) for b in fz.played)
    shrunk, tries = None, 0
    if failure and fz.shrink:
        prefix = failure["sequence"]

        kept, kept_speed, kept_split = dict(fz.findings), list(fz.speed), dict(fz.split_stats)

        def fails(cand):
            if not fz.left():
                return None
            fz.reset()
            got = fz.play_sequence(cand)
            if got == "budget":
                return None
            return bool(got) and got["oracle"] == failure["oracle"]
        shrunk, tries = ddmin(prefix, fails, fz.left)
        # The shrink's replays repeat what the run saw: no new samples, findings or split + type counts.
        fz.findings, fz.speed, fz.split_stats = kept, kept_speed, kept_split
    report = {"seed": fz.seed, "source": fz.source, "diagnostic": fz.diagnostic, "planned": len(fz.sequence),
              "played": played, "seconds": round(D.now() - started, 1), "failure": failure,
              "shrunk": shrunk, "shrink_tries": tries, "budget_out": budget_out, "speed": fz.speed,
              "findings": sorted(fz.findings.values(), key=lambda f: f["first_n"]), "notes": fz.notes[-200:],
              "split_type": fz.split_stats,
              "size_trace": fz.trace, "leak_baseline": fz.leak_base, "log": fz.played[-400:],
              "sequence": getattr(fz, "effective", []) if failure is None else failure["sequence"]}
    (j.out / "fuzz.json").write_text(json.dumps(report, indent=1, default=str) + "\n")
    j.fuzz_report = report
    if failure:
        raise D.StepError(f"FUZZ {failure['oracle']} after action {failure['index']} (seed {fz.seed}): {failure['detail'][:300]}"
                          f" | shrunk to {len(shrunk or failure['sequence'])} actions: {json.dumps(shrunk or failure['sequence'])[:600]}")
    return {"seed": fz.seed, "played": played, "speed_samples": len(fz.speed), "seconds": report["seconds"]}


def cond_fuzz_clean(j, want, cache):
    report = getattr(j, "fuzz_report", None)
    if report is None:
        return False, {"error": "no fuzz_run before this check"}
    return report["failure"] is None and not report["findings"], {"seed": report["seed"], "played": report["played"],
                                                                   "failure": report["failure"],
                                                                   "findings": [f["signature"] for f in report["findings"]]}


def cond_fuzz_daemon_agrees(j, want, cache):
    fz = getattr(j, "fuzz", None)
    if fz is None:
        return False, {"error": "no fuzz_run before this check"}
    # Only the daemon-vs-app topology: the app's own desync monitor (debug.desync) is the RECORD oracle `desync`,
    # already a finding of the run (fuzz_clean), never judged a second time here as a broken round.
    found = [(o, d) for o, d in fz.topology(state(j)) if o not in RECORD]
    return not found, {"problems": [d for _, d in found]}


def step_fuzz_crash_reports(j, step):
    """Reads the mini's crash reports of the last HOURS (default 12) under ~/Library/Logs/DiagnosticReports (the lease's
    account, which runs every capture app) and writes diag-crashes.json beside result.json: per report its file, app
    name, bundle id, version, the build's tag from the app path, the crash time, the exception, the crashing thread's
    top FRAMES frames, and the fuzz's own leases of that mini. Only reads; nothing is changed or sent anywhere."""
    import glob
    import os
    hours, frames = float(step.get("hours", 12)), int(step.get("frames", 16))
    root = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    cutoff = time.time() - hours * 3600
    out = []
    for path in sorted(glob.glob(os.path.join(root, "**", "*.ips"), recursive=True)):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
            text = open(path, errors="replace").read()
        except OSError:
            continue
        head, _, body = text.partition("\n")
        try:
            meta = json.loads(head)
        except ValueError:
            meta = {}
        try:
            crash = json.loads(body)
        except ValueError:
            crash = {}
        rec = {"file": os.path.basename(path), "app": meta.get("app_name") or meta.get("name"),
               "bundle": meta.get("bundleID"), "version": meta.get("app_version"), "build": meta.get("build_version"),
               "time": meta.get("timestamp"), "bug_type": meta.get("bug_type"),
               "path": (crash.get("procPath") or "")[:300], "pid": crash.get("pid"),
               "exception": crash.get("exception"), "termination": crash.get("termination"),
               "launched": crash.get("procLaunch"), "crashed": crash.get("captureTime")}
        threads = crash.get("threads") or []
        images = crash.get("usedImages") or []
        hit = next((t for t in threads if t.get("triggered")), None)
        if hit is not None:
            rec["thread"] = {"name": hit.get("name"), "queue": hit.get("queue"), "frames": [
                {"image": (images[f.get("imageIndex")] or {}).get("name") if isinstance(f.get("imageIndex"), int)
                 and f.get("imageIndex") < len(images) else None, "symbol": f.get("symbol"),
                 "offset": f.get("imageOffset")} for f in (hit.get("frames") or [])[:frames]]}
        out.append(rec)
    (j.out / "diag-crashes.json").write_text(json.dumps(out, indent=1, default=str) + "\n")
    return {"reports": len(out), "apps": sorted({str(r.get("app")) for r in out})}


STEPS = {"fuzz_run": step_fuzz_run, "fuzz_crash_reports": step_fuzz_crash_reports}
CONDITIONS = {"fuzz_clean": ("app", cond_fuzz_clean), "fuzz_daemon_agrees": ("daemon", cond_fuzz_daemon_agrees)}
