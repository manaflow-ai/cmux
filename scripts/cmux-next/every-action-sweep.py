#!/usr/bin/env python3
"""Every action, timed (Performance Lead, Lawrence 2026-10-23: "new workspace, Cmd-D, Cmd-Shift-D, literally
everything must be as fast as the speed of light"). Not a CI gate: a measurement an agent runs on the fleet.

Launches a tagged Debug cmux-next app (no activation, scratch cmux.json, empty Ghostty config, isolated Chief
home, agent launch denied, the typing probe on, the hang watchdog at 8 ms) and, per session (`light`, then
`stress`: scripts/cmux-next/perf-stress-session.py), runs every action of the live catalog (`action.list`,
the same ids as plans/cmux-next/action-surfaces.json) that can run unattended, through its real entrypoint:

  key      the action's effective shortcut (`shortcut_config`) as a key-down through the app's own key path
           (`debug.key`: key router, window and menu key equivalents, responder chain)
  action   `action.run` with focus (the CLI and palette path) when it has no single-stroke shortcut, or the
           key did not run it in this focus (`key_routed: false` in the row)

Before each action the focused pane shows the tab kind the action needs (terminal, Chromium page, address bar,
agent chat); after it, Escape twice, then the layout goes back: new windows, workspaces, panes and tabs close,
removed tabs come back, toggles run again, changed settings are written back, focus returns.

Per action (one row of the JSON table):
  turn_ms          the handler's main-thread time: the always-on action.perform signpost (CmuxNextSignposts,
                   ActionRegistry.performNow, the path every key, menu, palette and CLI action takes; the same
                   interval a Release build records), read live from `log stream --signpost` (OUT/signposts.ndjson)
  wait_ms          input sent to action.perform's begin (the main thread's queue; both on CLOCK_UPTIME_RAW: machTimestamp)
  commit_ms        input sent to the end of action.commit: the end of the Core Animation commit after the handler
                   (CommitBoundary), so input to committed frame
  result_ms        input to the first commit after the expected object appeared in the topology (creates and
                   closes that finish after a daemon reply), when that differs
  rpc_ms           the socket round trip of the input (debug.key or action.run)
  frames           display frames during the settle window (`debug.frames`): refresh, missed vsyncs (an interval
                   over 1.5 refresh periods), longest interval, longest main-thread frame
  hangs            main-thread stalls over 8 ms (`debug.hangs`)
  error            a refusal or error reply, a key that ran nothing, a missing handler run
  check            a cheap correctness check: a split made a pane, a new tab made a tab, a close removed one,
                   a focus move moved focus (`ok`, `wrong`, `n/a`)
Each action runs --repeat times (default 3); the row keeps p50/p95/max over the repeats.

Non-catalog interactions (rows with kind `interaction`): typing in a terminal (the typing probe's key to
frame), the agent composer and the omnibar; scrolling the terminal, a page, the sidebar; clicks on a pane, a tab
and a sidebar row; a divider drag; a window resize; full screen in and out; a hover card; Cmd-Tab back
(`debug.app_activation`); a tab dragged to another pane.

Skipped, never run (each row says why): actions that end or restart the app, sign in or out, buy, install
or update from the network, open another app or a web site, change system defaults, delete data, wait for a
person (file panels, confirmations), or use the Cloud, a phone, a remote machine or computer use; destructive
actions; debug-only actions; actions whose context the sweep cannot set up (markdown, diff viewer, simulator,
palette-internal, ...); in STRESS also actions that destroy the session (close all or other workspaces,
windows). Window-closing actions run in the light session last, then the app relaunches.

Measurement validity: the report states the display refresh, the idle missed-frame rate of each session, and
whether every Chromium tab is a real Chromium page (`debug.cef` shows no unavailable or fallback state).

Outputs: OUT/every-action.json (all rows, both sessions, environment), OUT/every-action.md (ranked misses:
over 10 ms p95 to commit, any dropped frame, over 4 ms on the key's turn, any error or wrong result).

Fleet (an owned mini's console; the allowlisted entry builds the tagged app at the ref):
  cmux-ci run --class exclusive --measurement --label measure [--label macos-26] \\
    --script scripts/measure/split-spring.sh --ref SHA --key KEY --timeout 10800 \\
    --artifact artifacts/split-spring/report.json --arg=--suite=every-action [--arg=--sessions=light,stress]
  (also artifacts/split-spring/every-action.md in a second step with that --artifact)
  The controller returns --artifact files only when the step passes. A run with a failed session exits
  FAILED_SESSION_EXIT and prints its whole report into the step log (every-action.md, then the JSON as
  EVERY-ACTION-REPORT lines); get it back with
  cmux-ci log STEP_ID > step.log && every-action-sweep.py --merge OUT/every-action.json step.log

On the fleet pass --vdisplay=120 to split-spring.sh: a 1920x1080 120 Hz virtual display, so frames are judged at
full ProMotion refresh and the STRESS grid (4 columns) fits; a 1024x768 console refuses the splits. The window
opens on screen 0, the main display: the virtual one when split-spring.sh made it main, else the console.
Pass --vdisplay-hold=SECONDS longer than the run (the helper ends itself after 1200 s by default).

Usage: every-action-sweep.py --app APP --tag TAG --out DIR [--json PATH] [--sessions light,stress] [--repeat 3]
       [--only id,id] [--limit N] [--shard K/N] [--settle 0.5] [--no-interactions] [--keep]
A sharded run (--shard K/N) times the interactions in shard 1 only; merge the shards' JSON with
--merge OUT/every-action.json SHARD.json... (writes the merged JSON and the ranked markdown). A SHARD may also be the
step log of a failed step (the EVERY-ACTION-REPORT lines it printed).
Exit status FAILED_SESSION_EXIT (3) when a session failed (its error is in failed_sessions and every-action.md; a
session that failed partway keeps its rows, marked `failed`); a --merge that holds a shard's failure exits the same.
A STRESS session of another shape (perf-stress-session's StressShapeError at the build, SessionShapeError at a
mid-session rebuild or tab restore) is such a failure: another layout is never measured as `stress`. So is an app that
does not come back after a crash (bench_launch's LaunchError at a relaunch): the session is recorded with its rows and
the next session runs on a fresh launch.
"""
import argparse, base64, csv, signal, threading, glob, gzip, importlib.util, json, os, platform, re, socket, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402
from bench_launch import LaunchError, launch_app  # noqa: E402

if len(sys.argv) > 2 and sys.argv[1] == "--merge":
    MERGE = (sys.argv[2], sys.argv[3:])
    sys.argv = [sys.argv[0], "--app", "-", "--tag", "-", "--out", os.path.dirname(os.path.abspath(sys.argv[2]))]
else:
    MERGE = None

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--repeat", type=int, default=3)
parser.add_argument("--only", default="", help="comma-separated action ids (default: every action)")
parser.add_argument("--limit", type=int, default=0, help="at most N actions per session (a smoke run)")
parser.add_argument("--shard", default="", help="K/N or K1,K2/N: only every N-th action from the K-th (1-based), for N hosts in parallel")
parser.add_argument("--settle", type=float, default=0.5, help="seconds of frames kept after each commit (animations)")
parser.add_argument("--no-interactions", action="store_true")
parser.add_argument("--keep", action="store_true", help="leave the app running")
opts = parser.parse_args()

OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
# A tagged build's socket lives in ~/.local/state/cmux with a /tmp link, or at /tmp when the path is too long.
SOCKETS = [SOCKET, os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{opts.tag}.sock")]
SCRATCH = tempfile.mkdtemp(prefix=f"every-action-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
PROBE = os.path.join(OUT, "typing.csv")
WINDOW = (40, 40, 1600, 1000)

TARGET_COMMIT_MS = 10.0
TARGET_TURN_MS = 4.0
# The exit status of a run (or a --merge) in which a session failed: the report still lands, with every failure in
# failed_sessions and in every-action.md, but the run is not a pass (bench-launch-smoke, split-spring.sh's step).
FAILED_SESSION_EXIT = 3
# How long a closed-history entry may take to reach the app after the topology shows its close (the daemon's
# closed history and the topology are two event streams). restore() waits this long for the input's own entries,
# and mark_closed() for the sweep's own cleanup entries.
CLOSED_LAND_S = 3.0
# A failed run prints its report into the step log as `EVERY-ACTION-REPORT k/N <gzip+base64 chunk>` lines.
REPORT_LINE = "EVERY-ACTION-REPORT"
REPORT_LINE_CHARS = 4000  # base64 characters per line: short enough for any line-based log store


def uptime():
    """CLOCK_UPTIME_RAW seconds: CACurrentMediaTime's and NSEvent timestamps' clock."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def note(text):
    print(text, flush=True)


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error), "unreachable": True}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def error_of(reply):
    if isinstance(reply, dict) and reply.get("error"):
        error = reply["error"]
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:240]
        return str(error)[:240]
    return None


DESTRUCTIVE = set()  # ids action.list marks destructive: a socket caller passes confirm (ControlRouter+ActionRun)


def hang_summary(hangs):
    """debug.hangs: stall count, the longest stall, and the longest stall's main-thread stack (the cause)."""
    records = [r for r in (hangs.get("records") or []) if r.get("kind", "stall") == "stall"] if isinstance(hangs, dict) else []
    longest = max(records, key=lambda r: r.get("duration_ms") or 0, default=None)
    out = {"count": hangs.get("count") if isinstance(hangs, dict) else None,
           "max_ms": round((hangs.get("max_ms") if isinstance(hangs, dict) else 0) or 0, 2)}
    if longest:
        out["stack"] = {"ms": round(longest.get("duration_ms") or 0, 2), "cpu_ms": round(longest.get("cpu_ms") or 0, 2),
                        "top": (longest.get("frames") or [])[:6],
                        "app": [f for f in longest.get("frames") or [] if "cmux" in f.lower()][:14]}
    return out


def act(ident, target=None, args=None, timeout=30, **params):
    """action.run of `ident`; a destructive action gets the script caller's confirm."""
    args = dict(args or {})
    if ident in DESTRUCTIVE:
        args["confirm"] = True
    call = {"action": ident, **params}
    if args:
        call["args"] = args
    if target:
        call["target"] = target
    return rpc("action.run", call, timeout=timeout)


def wait(predicate, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded poll of the app's socket state in a test script
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test script: the poll interval
    return None


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


def stat(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return None
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": round(max(values), 2)}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ----------------------------------------------------------------------------------------------------------
# The app.

class App:
    def __init__(self):
        self.process = None
        self.pids = []

    def launch(self):
        with open(CONFIG, "w") as f:
            json.dump({"appearance": {"backgroundOpacity": 1}}, f)
        open(GHOSTTY, "w").close()
        for path in SOCKETS:
            if os.path.lexists(path):
                os.unlink(path)
        # The environment typing-frame-bench.py launches with on the fleet (a step's HOME, no login shell).
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh", "CMUX_DEV_BACKEND_MODE": "local",
               "CMUX_NEXT_AGENT_PANE_MOCK": "1", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "0", "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, WINDOW)),
               "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
               "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TYPING_PROBE": PROBE,
               "CMUX_NEXT_HANG_THRESHOLD_MS": "8", "ACPMUX_AGENT_LAUNCH": "deny"}
        def started(process):
            self.process = process
            self.pids.append(process.pid)
            SIGNPOSTS.pids.add(process.pid)
            note(f"every-action: launched pid {process.pid}")
        # One launch path (bench_launch.py): the state-folder socket, the session check, and the reason (crash
        # report, main-thread sample, log tail) when the app does not come up; raises LaunchError (a SystemExit).
        global SOCKET
        _, SOCKET = launch_app(opts.app, env, os.path.join(OUT, "app.log"), timeout=180, on_start=started)
        time.sleep(3)  # test script: launch work (restore, first pages) ends before the first measure

    def stop(self):
        try:
            self.quit()
        finally:
            # The tag's headless cmux-tui session and acpmux outlive a quit (keep-on-quit): end them, so the next
            # session starts empty (a relaunch otherwise restores every workspace the last session left).
            TagTeardown(opts.app, log=note).end()

    def quit(self):
        if not self.process or self.process.poll() is not None:
            return
        rpc("action.run", {"action": "quitEndSessions"}, timeout=10)  # ends the tag's terminal sessions too
        try:
            self.process.wait(timeout=25)
            return
        except subprocess.TimeoutExpired:
            pass
        self.process.terminate()  # our own child only
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)

    def relaunch(self):
        self.stop()
        self.launch()


# ----------------------------------------------------------------------------------------------------------
# Topology helpers.

def topology():
    reply = rpc("snapshot.get")
    return (reply.get("topology") or {}) if isinstance(reply, dict) else {}


def panes_of(workspace):
    return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]


def shape(topo):
    """Comparable shape: windows, workspaces, and per workspace its panes and their tabs."""
    workspaces = {w["id"]: {p["id"]: [t["id"] for t in p.get("tabs") or []] for p in panes_of(w)}
                  for w in topo.get("workspaces") or [] if w.get("id")}
    windows = [w.get("id") for w in topo.get("windows") or []]
    return {"windows": windows, "workspaces": workspaces, "focus": topo.get("focus") or {}}


def counts(s):
    panes = sum(len(p) for p in s["workspaces"].values())
    tabs = sum(len(t) for w in s["workspaces"].values() for t in w.values())
    return {"windows": len(s["windows"]), "workspaces": len(s["workspaces"]), "panes": panes, "tabs": tabs}


def tab_kinds(topo):
    return {t["id"]: t.get("kind") for w in topo.get("workspaces") or [] for p in panes_of(w) for t in p.get("tabs") or []}


def layout(topo):
    """What a restore must bring back exactly when ids change (a reopened pane or tab has new ids): the windows, and
    per workspace each screen's panes in order, each as its column and the multiset of its tab kinds."""
    return {"windows": sorted(w.get("id") or "" for w in topo.get("windows") or []),
            "workspaces": {w["id"]: [[[p.get("column"), sorted(t.get("kind") or "?" for t in p.get("tabs") or [])]
                                      for p in s.get("panes") or [] if not p.get("dock")] for s in w.get("screens") or []]
                           for w in topo.get("workspaces") or [] if w.get("id")}}


def pane_position(topo, workspace, pane):
    """[screen index, pane index] of `pane` in `workspace`, or None."""
    ws = next((w for w in topo.get("workspaces") or [] if w.get("id") == workspace), {})
    for screen_index, screen in enumerate(ws.get("screens") or []):
        for pane_index, info in enumerate(p for p in screen.get("panes") or [] if not p.get("dock")):
            if info.get("id") == pane:
                return [screen_index, pane_index]
    return None


def pane_at(topo, workspace, position):
    """The id of the pane at `position` ([screen index, pane index]) in `workspace`, or None."""
    ws = next((w for w in topo.get("workspaces") or [] if w.get("id") == workspace), {})
    screens = ws.get("screens") or []
    if not position or position[0] >= len(screens):
        return None
    panes = [p for p in screens[position[0]].get("panes") or [] if not p.get("dock")]
    return panes[position[1]].get("id") if position[1] < len(panes) else None


def terminals(topo):
    """tab id -> terminal id of every terminal tab (a reopen inside the reap grace attaches the same terminal)."""
    return {t["id"]: t.get("terminal") for w in topo.get("workspaces") or [] for p in panes_of(w)
            for t in p.get("tabs") or [] if t.get("kind") == "terminal" and t.get("terminal")}


def closed_ids():
    """The closed-history ids (`history.list`, newest first): each one a group `history.reopen` brings back by id.
    [] only for a history the app read as empty; None when the read failed (an error or unreachable reply, a
    timeout, a reply without an `entries` list): then nobody knows which entries a measured input made."""
    reply = rpc("history.list", {"kind": "closed", "range": "all", "limit": 5000})
    entries = reply.get("entries") if isinstance(reply, dict) and not error_of(reply) else None
    if not isinstance(entries, list):
        note(f"every-action: history.list did not answer: {error_of(reply) or type(reply).__name__}")
        return None
    return [e["closed_id"] for e in entries if isinstance(e, dict) and e.get("closed_id")]


# ----------------------------------------------------------------------------------------------------------
# Classification: what runs, through which entrypoint, and what it is checked against.

SKIPS = [
    (r"(?i)(^|[.])(quit|relaunch|restart(App)?|terminate|crash|hang|freeze|forceQuit)", "ends or restarts the app"),
    (r"(?i)(sign(In|Out)|log(In|Out)|account|auth|passkey|keychain|password)", "sign-in, accounts or credentials"),
    (r"(?i)(purchase|buy|subscri|billing|checkout|upgrade|redeem|pricing)", "purchase"),
    (r"(?i)(install|update|checkForUpdates|download|appStore|store\.|extension\.(add|load))", "installs or updates from the network"),
    (r"(?i)(openIn(?!Split|NewTab|Pane|Background|Foreground)|reveal|finder|external|openWith|defaultBrowser|makeDefault|"
     r"setDefault|share|mail|feedback|reportIssue|github|discord|website|docs|help\.|openURL|vscode|xcode|editor\.open)",
     "opens another app, a web site or changes system defaults"),
    (r"(?i)(cloud|machine|remote|ssh|tunnel|vm\b|phone|simulator|cua|computerUse|tailscale|devices?\.add|mobile|pair)",
     "uses the Cloud, a remote machine, a phone or computer use"),
    (r"(?i)(delete|clear(History|BrowsingData|SiteData|Cookies|Data|Cache)|removeImported|wipe|erase|forget|resetSite|"
     r"reset(All|Settings|Data))", "deletes data"),
    (r"(?i)(import|export|saveAs|savePage|openFile|openFolder|choose|pick|upload|attach|print|screenshot|record)",
     "opens a file panel or writes files outside the app"),
]
MASS_DESTROY = r"(?i)(closeAll|closeOther|close.*Others|closeTabsTo|merge|ungroupAll|stashAll|stash.*Others|resetLayout)"
WINDOW_CLOSERS = r"(?i)^(closeWindow|closeAllWindows|closeOtherWindows|window\.close.*)$"
CONTEXT_SETUP = {"terminalFocused": "terminal", "browserFocused": "chromium", "webViewFocused": "chromium",
                 "omnibarFocused": "omnibar", "textBoxFocused": "omnibar", "agentPaneFocused": "chat", "signedOut": None}

EXPECT = [
    (r"(?i)^(split|newColumn|newRow|newPane|pane\.new)", "pane+"),
    (r"(?i)^(newSurface|newTab\.|openBrowser|newBrowserTab|palette\.newAgentChat|duplicateTab|tab\.duplicate|newTerminalTab)", "tab+"),
    (r"(?i)^(newTab$|workspace\.new|newWorkspace|duplicateWorkspace)", "workspace+"),
    (r"(?i)^(newWindow|newIncognitoWindow)", "window+"),
    (r"(?i)^(closeTab|closeSurface)$", "tab-"),
    (r"(?i)^closePane$", "pane-"),
    (r"(?i)^closeWorkspace$", "workspace-"),
    (r"(?i)^(focus(Left|Right|Up|Down|Next|Previous)(Pane)?|nextTab|previousTab|selectNextTab|selectPreviousTab|"
     r"nextWorkspace|previousWorkspace|selectTab\d|goToTab\d)", "focus"),
]
TOGGLES = r"(?i)(toggle|Toggle|zoom(?!In|Out|Reset)|^show|^hide|Sidebar$|fullScreen|pin|mute)"
KEY_NAMES = {"left", "right", "up", "down", "home", "end", "pageup", "pagedown", "tab", "return", "escape", "delete", "space"}


def skip_reason(action, session):
    ident = action["id"]
    if action.get("debug_only"):
        return "debug-only tool"
    if action.get("waits_for_person"):
        return "waits for a person"
    for pattern, reason in SKIPS:
        if re.search(pattern, ident):
            return reason
    if action.get("destructive") and not re.match(r"(?i)^close(Tab|Pane|Workspace|Window)$", ident):
        return "destructive (deletes or closes things a person confirms)"
    if session == "stress" and (re.search(MASS_DESTROY, ident) or re.match(WINDOW_CLOSERS, ident)):
        return "destroys the STRESS session (measured in light)"
    surfaces = action.get("surfaces") or {}
    if surfaces.get("palette") == "paletteInternal" and not action.get("shortcut_config"):
        return "palette-internal (runs inside the open palette)"
    return None


def key_of(action):
    """(key, modifiers) for debug.key from the effective single-stroke shortcut, or None."""
    config = action.get("shortcut_config")
    if not config or " " in config:
        return None
    parts = config.split("+")
    if config.endswith("++"):
        parts = parts[:-2] + ["+"]
    key, mods = parts[-1], parts[:-1]
    names = {"cmd": "cmd", "shift": "shift", "opt": "option", "ctrl": "control"}
    if any(m not in names for m in mods):
        return None
    if key == "plus":
        key = "+"
    if len(key) > 1 and key not in KEY_NAMES:
        return None  # function keys and named keys debug.key does not synthesize
    return key, [names[m] for m in mods]


def expectation(ident):
    for pattern, kind in EXPECT:
        if re.search(pattern, ident):
            return kind
    return None


def argument_values(action, base):
    """Values for required arguments, or (None, reason)."""
    values = {}
    for argument in action.get("arguments") or []:
        if not argument.get("required"):
            continue
        kind, name = argument.get("kind"), argument.get("name")
        if kind == "string":
            values[name] = "sweep"
        elif kind == "int":
            values[name] = argument.get("min", 1)
        elif kind == "bool":
            values[name] = True
        elif kind == "enum":
            choices = argument.get("choices") or []
            if not choices:
                return None, f"argument {name} has no choices"
            values[name] = choices[0]["value"]
        elif kind == "target":
            target = (argument.get("target_kind") or "").split("-")[0]
            pick = {"workspace": base.get("other_workspace"), "tab": base.get("tab"), "pane": base.get("pane"),
                    "window": base.get("window")}.get(target)
            if not pick:
                return None, f"needs a {argument.get('target_kind') or 'target'} argument"
            values[name] = f"{argument.get('target_kind') or target}:{pick}"
        else:
            return None, f"argument {name} of kind {kind}"
    return values, None


# ----------------------------------------------------------------------------------------------------------
# One session's sweep.

class SessionShapeError(RuntimeError):
    """The STRESS session has another shape after a restore (Stress.check refused it): the session fails, another
    layout is never measured as `stress`. Only the sweep's shape check raises it. perf-stress-session raises its own
    StressShapeError for a builder step that timed out too (focus never reached a pane, a workspace never showed);
    in a restore that is a harness row of the action (or the interaction's restore_error), then relaunch_session():
    a relaunch and build(), whose own check fails the session on a real deviation."""


def tab_key(tab):
    """What still names a tab after a reopen gives it a new id: its url (each STRESS page has its own), else its
    terminal (a reopen inside the reap grace attaches the same one); None when neither is known."""
    if tab.get("url"):
        return "url:" + tab["url"]
    if tab.get("terminal"):
        return "terminal:" + tab["terminal"]
    return None


def tabs_at(topo, workspace, pane):
    """The tabs of `pane` in `workspace` (topology dicts, in order); [] when the pane is not there."""
    ws = next((w for w in topo.get("workspaces") or [] if w.get("id") == workspace), {})
    return next((p.get("tabs") or [] for p in panes_of(ws) if p.get("id") == pane), [])


class Sweep:
    def __init__(self, app, session, stress_module):
        self.app, self.session, self.stress_module = app, session, stress_module
        self.rows, self.interactions = [], []
        self.base = {}
        self.builder = None
        # The closed-history ids just before the measured input (mark_closed); restore() reopens only newer ones.
        self.closed_mark = None
        self.mark_problem = None  # why the mark is None (mark_closed), for the restore's drift
        # The sweep's own closes since the last mark (cleanup_close), and the history ids read before the first.
        self.cleanup_owed, self.cleanup_since = 0, None

    # Session building.

    def build(self):
        self.builder = self.stress_module.Stress(rpc, log=note, settle=3.0)
        # A session starts from one workspace: anything a restore brought back is closed first.
        leftover = [w["id"] for w in topology().get("workspaces") or [] if w.get("id")][1:]
        for workspace in leftover:
            self.cleanup_close("closeWorkspace", f"workspace:{workspace}")
        if leftover:
            note(f"every-action: {self.session}: closed {len(leftover)} restored workspaces; "
                 f"{len(topology().get('workspaces') or [])} left")
        if self.session == "stress":
            # STRESS or nothing (P12): the builder's own shape check raises StressShapeError on any other layout, which
            # fails this session (failed_sessions, exit FAILED_SESSION_EXIT); another layout is never measured as it.
            summary = self.builder.build()
            note("STRESS-SESSION " + json.dumps(summary))
            self.summary = summary
            workspace = summary.get("measured")
        else:
            # Shown, and split by pane id (the builder's light session): focus may not follow a new workspace.
            workspace, panes = self.builder.build_light()
            self.builder.new_workspace()
            self.builder.action("goToWorkspace", {"workspace": workspace})
            wait(lambda: self.builder.focused_workspace() == workspace, 20)
            self.builder.focus_pane(panes[0])
            time.sleep(3)  # test script: the pages' first loads end
            topo = topology()
            self.summary = {"workspaces": len(topo.get("workspaces") or []), "measured": workspace, "measured_panes": len(panes),
                            "measured_tabs": len(self.builder.tabs(workspace, panes[0])), "refusals": self.builder.refusals[:10]}
            note("LIGHT-SESSION " + json.dumps(self.summary))
        self.snapshot_base(workspace)

    def snapshot_base(self, workspace):
        topo = topology()
        focus = topo.get("focus") or {}
        pane = focus.get("pane")
        ws = next((w for w in topo.get("workspaces") or [] if w.get("id") == workspace), {})
        pane_info = next((p for p in panes_of(ws) if p.get("id") == pane), (panes_of(ws) or [{}])[0])
        tabs = pane_info.get("tabs") or []
        # The kind the builder asked for each tab it made (perf-stress-session's `made`: webkit and chromium apart,
        # chat even when the New Tab page stood in); the topology says only `browser` for both engines.
        asked = {tab: kind for entries in (getattr(self.builder, "made", None) or {}).values()
                 for kind, tab, *_ in entries if tab}
        places = {p["id"]: [w["id"], pane_position(topo, w["id"], p["id"])]
                  for w in topo.get("workspaces") or [] if w.get("id") for p in panes_of(w) if p.get("id")}
        keys = {t["id"]: tab_key(t) for w in topo.get("workspaces") or [] for p in panes_of(w) for t in p.get("tabs") or []
                if t.get("id") and tab_key(t)}
        kinds = {"terminal": [t["id"] for t in tabs if t.get("kind") == "terminal"],
                 "browser": [t["id"] for t in tabs if t.get("kind") == "browser"],
                 "chat": [t["id"] for t in tabs if t.get("kind") == "conversation"]}
        if not kinds["chat"]:
            every = [t for s in ws.get("screens") or [] for p in s.get("panes") or [] for t in p.get("tabs") or []]
            kinds["chat"] = [t["id"] for t in every if t.get("kind") == "conversation"] or \
                [t["id"] for t in tabs if t.get("kind") == "page"]
        selected = next((t["id"] for t in tabs if t.get("selected")), pane_info.get("selected_tab"))
        other = next((w["id"] for w in topo.get("workspaces") or [] if w.get("id") != workspace), None)
        # The busy terminals (STRESS: 10 printing a line every 20 ms) by terminal id: a reopened pane must bring back
        # the same running terminals, not new idle shells.
        by_tab = terminals(topo)
        busy = sorted(by_tab[t] for t in getattr(self.builder, "busy", None) or [] if t in by_tab)
        self.base = {"workspace": workspace, "pane": pane_info.get("id"), "tab": selected, "kinds": kinds, "asked": asked,
                     "window": focus.get("window"), "other_workspace": other, "shape": shape(topo), "tab_kinds": tab_kinds(topo),
                     "layout": layout(topo), "pane_at": pane_position(topo, workspace, pane_info.get("id")), "busy": busy,
                     "places": places, "tab_keys": keys, "settings": self.settings()}
        note(f"every-action: {self.session} base {json.dumps({k: v for k, v in self.base.items() if k not in ('shape', 'settings', 'tab_kinds', 'layout', 'asked', 'places', 'tab_keys')})}")

    def settings(self):
        reply = rpc("settings.get", {"path": []})
        return reply.get("value") if isinstance(reply, dict) and "value" in reply else reply

    # Context.

    def show(self, kind):
        """The base pane shows a tab of `kind` (terminal, chromium, chat) or the omnibar has focus. False when it cannot."""
        if kind is None:
            return True
        tabs = self.base["kinds"]
        pick = {"terminal": tabs["terminal"][:1], "chromium": tabs["browser"][:1], "omnibar": tabs["browser"][:1],
                "chat": tabs["chat"][:1]}.get(kind) or []
        if not pick:
            return False
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{pick[0]}", "focus": True})
        if kind == "omnibar":
            rpc("action.run", {"action": "focusLocation", "focus": True})
        time.sleep(0.15)  # test script: the selection's first frame before the measured input
        return True

    def home(self):
        """Focus back on the base workspace, pane and tab."""
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": self.base["workspace"]}, "focus": True})
        if self.base.get("pane"):
            rpc("action.run", {"action": "pane.focus", "target": f"pane:{self.base['pane']}", "focus": True})
        if self.base.get("tab"):
            rpc("action.run", {"action": "tab.focus", "target": f"tab:{self.base['tab']}", "focus": True})

    # Restore.

    def cleanup_close(self, action, target):
        """A close the sweep sends itself: a restore's cleanup, a damaged measured workspace, a workspace left over
        from an earlier session. Its closed-history group reaches the app on the daemon's event stream, so it can land
        after the topology shows the close, and even after the next input's mark. This counts it, and mark_closed()
        waits until every counted group is in the history before it takes the mark. Then a cleanup group is never
        read as a group of the next input."""
        if not self.cleanup_owed:
            ids = closed_ids()
            self.cleanup_since = None if ids is None else set(ids)
        self.cleanup_owed += 1
        return act(action, target, origin="script")

    def mark_closed(self):
        """Records the closed history just before a measured input: restore() reopens only the entries that input made.
        The mark first waits until the groups of the sweep's own closes since the last mark (``cleanup_close``) are in
        the history: one new entry per close, counted against the history read before the first of them. When the
        history cannot be read, or those groups do not all land within CLOSED_LAND_S, the mark stays None. restore()
        then reopens nothing (any entry could be a cleanup group or an older one) and takes the tab or rebuild path.
        A limit: an input group that lands later than restore()'s own wait is counted as a cleanup group here."""
        owed, since = self.cleanup_owed, self.cleanup_since
        self.cleanup_owed, self.cleanup_since = 0, None
        self.mark_problem = None
        if not owed:
            ids = closed_ids()
            if ids is None:
                self.mark_problem = "closed history unread before the input"
        else:
            def landed():
                now = closed_ids()
                return now if now is not None and len(set(now) - since) >= owed else None
            ids = wait(landed, CLOSED_LAND_S) if since is not None else None
            if ids is None:
                self.mark_problem = ("closed history unread before the input" if since is None else
                                     f"the closed groups of the sweep's own {owed} close(s) never landed before the input")
                note(f"every-action: {self.session}: {self.mark_problem}")
        self.closed_mark = None if ids is None else set(ids)

    def restore(self, action_id, toggled):
        if self.app.process and self.app.process.poll() is not None:
            # The app is gone (it quit or crashed): rebuilding through a dead socket would only time out.
            raise RuntimeError(f"the app exited (code {self.app.process.returncode})")
        for _ in range(2):
            rpc("debug.key", {"key": "escape"}, timeout=5)
        rpc("debug.key", {"key": "escape", "target": "palette"}, timeout=5)
        if toggled:
            reply = rpc("action.run", {"action": action_id, "focus": True})
            if error_of(reply):
                key = None
        mark, self.closed_mark = self.closed_mark, None
        problem, self.mark_problem = self.mark_problem, None
        closed = []
        drift = []
        if self.lost(self.base["shape"], shape(topology())):
            if mark is None:
                # No entry can be told apart as the input's own (mark_closed says why).
                drift.append(f"{problem or 'closed history unread before the input'}: no reopen")
            else:
                # The groups the input closed, read before this restore's own closes add theirs. The daemon's closed
                # history reaches the app on its own event stream, so an entry can land after the topology shows
                # the close: wait for it. A move (a pane into another workspace) closes nothing, and the bound runs
                # out. A failed read here is no ids, never "everything".
                closed = wait(lambda: [i for i in closed_ids() or [] if i not in mark], CLOSED_LAND_S) or []
        drift += self.close_new(self.base["shape"])
        lost = self.lost(self.base["shape"], shape(topology()))
        if lost:
            drift.append(f"lost {lost}")
            self.rebuild(lost, closed)
        changed = self.restore_settings()
        if changed:
            drift.append(f"settings {','.join(changed)[:80]}")
        self.home()
        return drift

    def close_new(self, before):
        """Closes every window, workspace, pane and tab that `before` (a shape) does not have; returns what it closed."""
        after = shape(topology())
        drift = []
        for window in after["windows"]:
            if window not in before["windows"]:
                self.cleanup_close("closeWindow", f"window:{window}")
                drift.append("window+")
        for workspace in list(after["workspaces"]):
            if workspace not in before["workspaces"]:
                self.cleanup_close("closeWorkspace", f"workspace:{workspace}")
                drift.append("workspace+")
        for workspace, panes in after["workspaces"].items():
            old = before["workspaces"].get(workspace)
            if old is None:
                continue
            for pane, tabs in panes.items():
                if pane not in old:
                    self.cleanup_close("closePane", f"pane:{pane}")
                    drift.append("pane+")
                    continue
                for tab in tabs:
                    if tab not in old[pane]:
                        self.cleanup_close("closeTab", f"tab:{tab}")
                        drift.append("tab+")
        return drift

    def lost(self, before, after):
        missing = {"workspaces": 0, "panes": 0, "tabs": 0, "windows": 0}
        missing["windows"] = sum(1 for w in before["windows"] if w not in after["windows"])
        for workspace, panes in before["workspaces"].items():
            now = after["workspaces"].get(workspace)
            if now is None:
                missing["workspaces"] += 1
                continue
            for pane, tabs in panes.items():
                if pane not in now:
                    missing["panes"] += 1
                    continue
                missing["tabs"] += sum(1 for t in tabs if t not in now[pane])
        return {k: v for k, v in missing.items() if v}

    def restored(self):
        """True when the topology is the base again: the same layout (``layout``) and every busy terminal running."""
        topo = topology()
        return layout(topo) == self.base["layout"] and set(self.base["busy"]) <= set(terminals(topo).values())

    def reopen(self, closed):
        """Reopens exactly `closed` (closed-history ids the measured input made, newest first: the undo order) by id
        (`history.reopen`, the Recently Closed list's path), never the newest entry of the history (Cmd-Shift-T),
        which this sweep's own cleanup closes fill. True once the topology is the base again (``restored``); then
        the base pane is the pane at the base pane's place. Otherwise whatever came back is closed and False."""
        if not closed:
            return False
        for item in closed:
            reply = act("history.reopen", args={"id": item}, origin="script")
            if error_of(reply):
                note(f"every-action: {self.session}: history.reopen {item}: {error_of(reply)}")
                break
        else:
            # action.run answers when the reopen's work settled; the store lays the reopened tabs over later.
            if wait(self.restored, 10.0):
                topo = topology()
                base_ws = self.base["workspace"]
                pane = pane_at(topo, base_ws, self.base.get("pane_at")) or self.base["pane"]
                busy = set(self.base["busy"])
                if busy:
                    self.builder.busy = [tab for tab, terminal in terminals(topo).items() if terminal in busy]
                self.carry_made(topo)
                self.builder.focus_pane(pane)
                self.snapshot_base(base_ws)
                return True
        note(f"every-action: {self.session}: reopening {closed} did not give the base back; closing what came back")
        self.close_new(self.base["shape"])
        return False

    def carry_made(self, topo):
        """After a reopen gave the base back with new ids: the builder's record of the kind it asked for each tab
        (`made`) moves to the reopened panes (by place) and tabs (by url or terminal, ``tab_key``), so the shape
        check and a later tab restore still read the engine each tab was made with. A terminal or chat entry with
        neither falls back to an unclaimed tab of its topology kind (the check tells only terminal from not); a
        page entry never does (WebKit and Chromium are both `browser`): it is left unknown, and the check names it."""
        made = self.builder.made
        keys = self.base.get("tab_keys") or {}
        for old_pane, (workspace, place) in list((self.base.get("places") or {}).items()):
            entries = made.get(old_pane)
            if not entries:
                continue
            new_pane = old_pane if pane_position(topo, workspace, old_pane) else pane_at(topo, workspace, place)
            tabs = tabs_at(topo, workspace, new_pane)
            present = {t.get("id") for t in tabs}
            by_key = {tab_key(t): t["id"] for t in tabs if tab_key(t)}
            # An entry is (kind, id, *rest): perf-stress-session adds fields after the id (whether a chat fell back).
            moved = [(kind, tab if tab is None or tab in present else by_key.get(keys.get(tab)), *rest)
                     for kind, tab, *rest in entries]
            claimed = {entry[1] for entry in moved if entry[1]}
            for index, (kind, tab, *rest) in enumerate(moved):
                if tab is None and entries[index][1] is not None and kind in ("terminal", "chat"):
                    want = ("terminal",) if kind == "terminal" else ("conversation", "page")
                    tab = next((t["id"] for t in tabs if t.get("kind") in want and t["id"] not in claimed), None)
                    if tab:
                        claimed.add(tab)
                        moved[index] = (kind, tab, *rest)
            if new_pane != old_pane:
                made.pop(old_pane, None)
            if new_pane:
                made[new_pane] = moved

    def check_stress_shape(self):
        """In STRESS, the session is STRESS again after a restore rebuilt part of it, or SessionShapeError fails the
        session (run() and interaction() pass it up; main() records it in failed_sessions, exit FAILED_SESSION_EXIT)."""
        if self.session != "stress":
            return
        summary = self.builder.summary()
        try:
            self.stress_module.Stress.check(summary)
        except self.stress_module.StressShapeError as error:
            raise SessionShapeError(str(error)) from error

    def rebuild(self, lost, closed=()):
        """Removed objects come back: the closed groups the input made, reopened by id; else tabs of the base
        workspace, each of the kind the builder asked for it; otherwise the session's measured workspace is
        rebuilt. A rebuilt STRESS session passes the shape check, or the session fails."""
        if not lost.get("workspaces") and not lost.get("windows") and self.reopen(list(closed)):
            note(f"every-action: {self.session}: reopened {len(closed)} closed group(s) by id; the base is back ({lost})")
            return
        before, after = self.base["shape"], shape(topology())
        lost = self.lost(before, after) or lost
        base_ws = self.base["workspace"]
        missing = self.lost_tabs(before, after) if set(lost) == {"tabs"} and base_ws in after["workspaces"] else None
        if missing:
            for pane, tab, kind in missing:
                self.replace_tab(base_ws, pane, tab, kind)
            self.builder.focus_pane(self.base["pane"])
            self.check_stress_shape()
            self.snapshot_base(base_ws)
            return
        note(f"every-action: {self.session}: rebuilding after {lost}")
        if self.session == "stress":
            workspace = self.builder.build_measured()
        else:
            workspace, _ = self.builder.build_light()
        # The damaged measured workspace goes: in STRESS it would stay a second grid of pages and busy terminals.
        if base_ws in shape(topology())["workspaces"]:
            self.cleanup_close("closeWorkspace", f"workspace:{base_ws}")
            # The store applies the close after the reply, and the shape check counts workspaces (exactly 60):
            # wait for it to go. If it never goes, the check fails the session with 61.
            wait(lambda: base_ws not in shape(topology())["workspaces"], 10.0)
        self.check_stress_shape()
        time.sleep(2)  # test script: rebuilt pages load
        self.snapshot_base(workspace)

    def replace_tab(self, workspace, pane, tab, kind):
        """A new tab of `kind` in `pane` in place of the lost `tab`, in the builder's books too:
          * `made`: the new tab takes the lost tab's entry (same index). A lost tab with no entry is the pane's first
            terminal, which perf-stress-session's summary() counts by itself; its replacement gets no entry either, so
            the pane still counts 2 terminals, not 3.
          * `busy`: when the lost tab was a busy terminal, the new one runs perf-stress-session's BUSY_COMMAND and takes
            its place. When the new tab's id is unknown, the dead id leaves `busy`: the shape check then counts 9 busy
            terminals and fails the session. A dead id never stays and gets counted as busy."""
        made = self.builder.made.setdefault(pane, [])
        index = next((i for i, entry in enumerate(made) if entry[1] == tab), None)
        self.builder.focus_pane(pane)
        self.builder.add_tab(workspace, pane, kind)
        entry = made.pop()  # add_tab appended the new tab's entry: (kind, id, ...), the id None when unknown
        if index is not None:
            made[index] = entry
        busy = getattr(self.builder, "busy", None)
        if busy and tab in busy:
            at = busy.index(tab)
            if entry[1]:
                self.builder.send(entry[1], self.stress_module.BUSY_COMMAND)
                busy[at] = entry[1]
            else:
                busy.pop(at)

    def lost_tabs(self, before, after):
        """[(pane, tab, kind)] for each base-workspace tab gone from a pane that is still there, with the kind the
        builder asked for it (``made``: webkit, chromium, chat), or terminal for an unrecorded terminal (a pane's
        first tab); None when a pane is gone or a lost tab's kind is unknown: then only a rebuild is exact."""
        base_ws = self.base["workspace"]
        asked = self.base.get("asked") or {}
        missing = []
        for pane, tabs in before["workspaces"][base_ws].items():
            now = after["workspaces"][base_ws].get(pane)
            if now is None:
                return None
            for tab in tabs:
                if tab in now:
                    continue
                kind = asked.get(tab) or ("terminal" if self.base["tab_kinds"].get(tab) == "terminal" else None)
                if kind is None:
                    note(f"every-action: {self.session}: lost tab {tab} ({self.base['tab_kinds'].get(tab)}) has no recorded kind")
                    return None
                missing.append((pane, tab, kind))
        return missing

    def restore_settings(self):
        now = self.settings()
        old = self.base.get("settings")
        if not isinstance(now, dict) or not isinstance(old, dict) or now == old:
            return []
        changed = []

        def walk(path, a, b):
            if isinstance(a, dict) and isinstance(b, dict):
                for key in set(a) | set(b):
                    walk(path + [key], a.get(key, KeyError), b.get(key, KeyError))
            elif a != b:
                if a is KeyError:
                    rpc("settings.unset", {"path": path})
                else:
                    rpc("settings.set", {"path": path, "value": a})
                changed.append(".".join(path))
        walk([], old, now)
        return changed

    # Measuring one input.

    def measure(self, send, action_id, settle=None):
        """Runs `send(t_send)`; returns timings from the action signposts, debug.frames and debug.hangs."""
        settle = opts.settle if settle is None else settle
        rpc("debug.hangs", {"clear": True})
        rpc("debug.frames", {"action": "start"})
        t_send = uptime()
        reply = send(t_send)
        t_reply = uptime()
        # The handler's action.commit ends after the Core Animation commit that carries its changes.
        SIGNPOSTS.wait_commit(action_id, t_send, 3.0)
        time.sleep(settle)  # test script: the animation the action started runs out inside the frame window
        t_end = uptime()
        frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
        hangs = rpc("debug.hangs", {"limit": 8}) or {}
        runs = SIGNPOSTS.runs(t_send, t_end)
        mine = next((r for r in runs if r["id"] == action_id), None)
        first = mine or (runs[0] if runs else None)
        row = {"rpc_ms": round((t_reply - t_send) * 1000, 2), "reply": reply, "runs": [r["id"] for r in runs][:6],
               "ran": bool(mine), "t_send": t_send, "window": [t_send, t_end]}
        if first:
            row["turn_ms"] = round(first["perform_ms"], 3) if first.get("perform_ms") is not None else None
            row["wait_ms"] = round((first["begin"] - t_send) * 1000, 2)
            if first.get("commit_end") is not None:
                row["commit_ms"] = round((first["commit_end"] - t_send) * 1000, 2)
        refresh = frames.get("refresh_ms") or 0
        intervals = frames.get("intervals_ms") or []
        busy = frames.get("main_ms") or []
        row["frames"] = {"refresh_ms": round(refresh, 2), "count": frames.get("frames"), "missed": frames.get("missed"),
                         "max_ms": round(frames.get("max_ms") or 0, 2), "main_max_ms": round(frames.get("main_max_ms") or 0, 2),
                         "main_over_8_3": frames.get("main_over_8_3_ms"),
                         "first_main_ms": round(busy[0], 2) if busy else None,
                         "first_interval_ms": round(intervals[0], 2) if intervals else None}
        row["hangs"] = hang_summary(hangs)
        return row

    # One action.

    def plan(self, action):
        reason = skip_reason(action, self.session)
        if reason:
            return None, reason
        missing = [k for k in action.get("requires") or [] if k not in CONTEXT_SETUP]
        if missing:
            return None, f"needs context the sweep does not set up: {', '.join(missing)}"
        kinds = [CONTEXT_SETUP[k] for k in action.get("requires") or [] if CONTEXT_SETUP.get(k)]
        context = "omnibar" if "omnibar" in kinds else (kinds[0] if kinds else None)
        args, why = argument_values(action, self.base)
        if args is None:
            return None, why
        return {"context": context, "args": args, "key": key_of(action) if not args else None}, None

    def run_action(self, action):
        ident = action["id"]
        plan, reason = self.plan(action)
        row = {"session": self.session, "kind": "action", "id": ident, "title": action.get("title"),
               "category": action.get("category"), "shortcut": action.get("shortcut_config")}
        if not plan:
            row["skipped"] = reason
            return row
        row["entry"] = "key" if plan["key"] else "action"
        row["context"] = plan["context"]
        samples, errors, checks, drifts = [], [], [], []
        expect = expectation(ident)
        toggled = bool(re.search(TOGGLES, ident)) and not expect
        for attempt in range(opts.repeat):
            self.mark_closed()
            if not self.show(plan["context"]):
                row["skipped"] = f"no {plan['context']} tab in the base pane"
                return row
            described = rpc("action.describe", {"action": ident})
            info = (described or {}).get("action") if isinstance(described, dict) else None
            if info and info.get("available") is False and not plan["args"]:
                row["skipped"] = f"unavailable here: {info.get('context_reason') or info.get('unavailable_reason') or 'context'}"
                return row
            before = shape(topology())
            entry = row["entry"]
            if plan["key"]:
                key, mods = plan["key"]
                sample = self.measure(lambda t: rpc("debug.key", {"key": key, "modifiers": mods, "timestamp": t}, timeout=20), ident)
                if not sample["ran"]:
                    # The key did not run this action here (another handler took it, or none): the CLI path instead.
                    sample["key_reply"] = {k: sample["reply"].get(k) for k in ("handled_by", "action", "refused_action")} \
                        if isinstance(sample["reply"], dict) else sample["reply"]
                    key_runs = sample["runs"]
                    drift = self.restore(ident, False) if key_runs else []
                    self.mark_closed()
                    if not self.show(plan["context"]):
                        break
                    before = shape(topology())
                    retry = self.measure(lambda t: act(ident, focus=True), ident)
                    retry["key_routed"] = False
                    retry["key_reply"] = sample["key_reply"]
                    retry["key_ran"] = key_runs
                    sample = retry
                    entry = "action"
            else:
                sample = self.measure(lambda t: act(ident, args=plan["args"], focus=True), ident)
            sample["entry"] = entry
            err = error_of(sample["reply"])
            if isinstance(sample["reply"], dict) and sample["reply"].get("refused_action"):
                err = f"refused: {sample['reply']['refused_action']}"
            if not err and SIGNPOSTS.live and not sample["ran"]:
                err = "no handler run recorded"
            if err:
                errors.append(err)
            after_topo = topology()
            check, result_ms = self.check(expect, before, shape(after_topo), sample)
            sample["check"] = check
            if result_ms is not None:
                sample["result_ms"] = result_ms
            checks.append(check)
            samples.append(sample)
            drifts.extend(self.restore(ident, toggled))
            if err and attempt == 0 and ("unavailable" in err or "not_found" in err or "refused" in err or "invalid" in err):
                break
        row["samples"] = len(samples)
        # Wall-clock windows of the measured inputs: the always-on action signposts are joined to them after the run.
        row["windows"] = [[round(s["window"][0], 6), round(s["window"][1], 6), s.get("wait_ms")] for s in samples]
        for key in ("turn_ms", "wait_ms", "commit_ms", "result_ms", "rpc_ms"):
            row[key] = stat([s.get(key) for s in samples])
        row["frames"] = {"refresh_ms": max([s["frames"]["refresh_ms"] for s in samples] or [0]),
                         "missed": max([s["frames"]["missed"] or 0 for s in samples] or [0]),
                         "missed_total": sum(s["frames"]["missed"] or 0 for s in samples),
                         "max_ms": max([s["frames"]["max_ms"] for s in samples] or [0]),
                         "main_max_ms": max([s["frames"]["main_max_ms"] for s in samples] or [0])}
        row["hangs"] = {"count": sum((s["hangs"]["count"] or 0) for s in samples),
                        "max_ms": max([s["hangs"]["max_ms"] or 0 for s in samples] or [0])}
        stacks = [s["hangs"]["stack"] for s in samples if s["hangs"].get("stack")]
        if stacks:
            row["hangs"]["stack"] = max(stacks, key=lambda x: x["ms"])
        row["entries"] = sorted({s["entry"] for s in samples})
        row["key_routed"] = all(s.get("key_routed", True) for s in samples) if plan["key"] else None
        row["key_reply"] = next((s.get("key_reply") for s in samples if s.get("key_reply")), None)
        row["runs"] = samples[0]["runs"] if samples else []
        row["errors"] = sorted(set(errors))
        row["check"] = "wrong" if "wrong" in checks else ("ok" if "ok" in checks else "n/a")
        row["drift"] = sorted(set(drifts))[:6]
        return row

    def check(self, expect, before, after, sample):
        """`ok`, `wrong` or `n/a`, and when a create or close finished after the first commit, input to the
        first commit after the topology showed it (an upper bound: the snapshot publishes after the model)."""
        if not expect:
            return "n/a", None
        c0, c1 = counts(before), counts(after)
        if expect == "focus":
            return ("ok" if before["focus"] != after["focus"] else "wrong"), None
        what, sign = expect[:-1], expect[-1]
        key = {"pane": "panes", "tab": "tabs", "workspace": "workspaces", "window": "windows"}[what]
        grew = c1[key] - c0[key]
        ok = grew > 0 if sign == "+" else grew < 0
        if not ok:
            # The object may land after the daemon's reply: wait for it, then for the next commit.
            def landed():
                c = counts(shape(topology()))
                return (c[key] - c0[key] > 0) if sign == "+" else (c[key] - c0[key] < 0)
            if wait(landed, 3.0, step=0.02):
                return "ok", round((uptime() - sample["t_send"]) * 1000, 2)
            return "wrong", None
        return "ok", None

    # Non-catalog interactions.

    def interaction(self, name, run, **extra):
        self.mark_closed()
        try:
            result = run()
        except Exception as error:  # a harness failure is a row, not a crash of the sweep
            result = {"error": f"harness: {error}"}
        row = {"session": self.session, "kind": "interaction", "id": name, **extra, **(result or {})}
        self.interactions.append(row)
        note(f"every-action: {self.session} interaction {name}: {json.dumps({k: v for k, v in row.items() if k in ('commit_ms', 'key_to_frame_ms', 'frames', 'error', 'turn_ms')})[:300]}")
        try:
            self.restore("", False)
        except SessionShapeError:
            raise  # the rebuilt session is not STRESS: the session fails
        except Exception as error:  # the row keeps it; the next row runs on a fresh build, as after an action's
            row["restore_error"] = f"{error!r}"[:240]
            self.relaunch_session(f"the restore after interaction {name} failed")

    def frames_during(self, body, settle=0.4):
        rpc("debug.hangs", {"clear": True})
        rpc("debug.frames", {"action": "start"})
        t0 = uptime()
        extra = body() or {}
        wall = (uptime() - t0) * 1000
        time.sleep(settle)  # test script: trailing frames of the gesture
        frames = rpc("debug.frames", {"action": "stop"}) or {}
        hangs = rpc("debug.hangs", {"limit": 8}) or {}
        return {"wall_ms": round(wall, 1), "frames": {"refresh_ms": round(frames.get("refresh_ms") or 0, 2), "count": frames.get("frames"),
                                                       "missed": frames.get("missed"), "p95_ms": round(frames.get("p95_ms") or 0, 2),
                                                       "max_ms": round(frames.get("max_ms") or 0, 2),
                                                       "main_p95_ms": round(frames.get("main_p95_ms") or 0, 2),
                                                       "main_max_ms": round(frames.get("main_max_ms") or 0, 2)},
                "hangs": hang_summary(hangs), **extra}

    def pane_chrome(self):
        reply = rpc("debug.pane_chrome") or {}
        window = (reply.get("windows") or [{}])[0] if isinstance(reply, dict) else {}
        return window

    def run_interactions(self):
        # Each interaction reads self.base when it runs: a restore or relaunch_session() gives the session new ids.
        # Typing in a terminal: the typing probe's key to frame (send time is the event's timestamp).
        def typing():
            self.show("terminal")
            start = len(probe_rows())
            rpcs = []
            def body():
                for index in range(30):
                    t = uptime()
                    rpc("debug.key", {"key": "abcdefghij"[index % 10], "timestamp": t}, timeout=10)
                    rpcs.append((uptime() - t) * 1000)
                    time.sleep(0.1)  # test harness: one key in flight at a time
                rpc("debug.key", {"key": "u", "modifiers": ["control"]})
            out = self.frames_during(body)
            rows = [r for r in probe_rows()[start:] if r.get("contents_ms")]
            out["key_to_frame_ms"] = stat([float(r["contents_ms"]) for r in rows])
            out["dispatch_ms"] = stat([float(r["dispatch_end_ms"]) - float(r["dispatch_start_ms"]) for r in rows
                                       if r.get("dispatch_end_ms") and r.get("dispatch_start_ms")])
            out["rpc_ms"] = stat(rpcs)
            if not rows:
                out["error"] = "the typing probe wrote no rows"
            return out
        self.interaction("type.terminal", typing)

        def typing_in(context, name):
            def run():
                if not self.show(context):
                    return {"skipped": f"no {context} tab"}
                rpcs = []
                def body():
                    for index in range(30):
                        t = uptime()
                        rpc("debug.key", {"key": "abcdefghij"[index % 10], "timestamp": t}, timeout=10)
                        rpcs.append((uptime() - t) * 1000)
                        time.sleep(0.05)  # test harness: typing pace
                    for _ in range(30):
                        rpc("debug.key", {"key": "delete"})
                out = self.frames_during(body)
                out["rpc_ms"] = stat(rpcs)
                out["note"] = "no app-side key-to-frame probe on this path: rpc_ms is the key's turn plus one socket hop"
                return out
            self.interaction(name, run)
        typing_in("chat", "type.agent_composer")
        typing_in("omnibar", "type.omnibar")

        def omnibar_bench():
            if not self.show("chromium"):
                return {"skipped": "no Chromium tab"}
            reply = rpc("debug.omnibar_bench", {}, timeout=20)
            return {"omnibar_click": reply if not error_of(reply) else None, "error": error_of(reply)}
        self.interaction("click.omnibar", omnibar_bench)

        def scroll(context, name, sidebar=False):
            def run():
                if context and not self.show(context):
                    return {"skipped": f"no {context} tab"}
                def body():
                    for index in range(40):
                        if sidebar:
                            rpc("debug.sidebar_wheel", {"dy": -40 if index < 20 else 40})
                        else:
                            rpc("debug.mouse", {"action": "scroll", "pane": self.base["pane"], "dy": -40 if index < 20 else 40,
                                                "phase": "began" if index in (0, 20) else ("ended" if index in (19, 39) else "changed"),
                                                "hover": index in (0, 20)})
                        time.sleep(1 / 120)  # test harness: one wheel event per 120 Hz frame
                return self.frames_during(body)
            self.interaction(name, run)
        scroll("terminal", "scroll.terminal")
        scroll("chromium", "scroll.chromium_page")
        scroll("chat", "scroll.agent_chat")
        scroll(None, "scroll.sidebar", sidebar=True)

        def click_pane():
            topo = topology()
            ws = next((w for w in topo.get("workspaces") or [] if w.get("id") == self.base["workspace"]), {})
            other = next((p["id"] for p in panes_of(ws) if p["id"] != self.base["pane"]), None)
            if not other:
                return {"skipped": "one pane only"}
            rpc("debug.pane_focus", {"action": "start"})
            out = self.frames_during(lambda: rpc("debug.mouse", {"action": "click", "pane": other}) and None)
            timer = rpc("debug.pane_focus", {"action": "stop"}) or {}
            moves = timer.get("moves") or timer.get("samples") or []
            out["commit_ms"] = stat([m.get("commit_ms") for m in moves])
            out["input_ms"] = stat([m.get("input_ms") for m in moves])
            out["check"] = "ok" if (topology().get("focus") or {}).get("pane") == other else "wrong"
            return out
        self.interaction("click.pane", click_pane)

        def click_tab():
            window = self.pane_chrome()
            pane = next((p for p in window.get("panes") or [] if p.get("pane") == self.base["pane"]), None)
            if not pane or not pane.get("strip") or not pane.get("tab_slots"):
                return {"skipped": "no tab strip geometry (debug.pane_chrome)"}
            sx, sy, sw, sh = pane["strip"]
            slots = pane["tab_slots"]
            target = slots[1] if len(slots) > 1 else slots[0]
            x = sx + target[0] + target[1] / 2
            y = sy + sh / 2
            rpc("debug.tab_switch", {"action": "start"})
            out = self.frames_during(lambda: rpc("debug.mouse", {"action": "click", "x": x, "y": y}) and None)
            timer = rpc("debug.tab_switch", {"action": "stop"}) or {}
            switches = timer.get("switches") or timer.get("samples") or []
            out["commit_ms"] = stat([s.get("commit_ms") for s in switches])
            out["input_ms"] = stat([s.get("input_ms") for s in switches])
            out["check"] = "ok" if switches else "wrong"
            return out
        self.interaction("click.tab", click_tab)

        def click_sidebar_row():
            reply = rpc("debug.sidebar_rows") or {}
            rows = ((reply.get("windows") or [{}])[0].get("rows") or []) if isinstance(reply, dict) else []
            key = next((w.get("key") for w in topology().get("workspaces") or [] if w.get("id") == self.base["other_workspace"]), None)
            row = next((r for r in rows if str(r.get("key", "")) == f"workspace({key})" and r.get("window_frame")), None) \
                or next((r for r in rows if str(r.get("key", "")).startswith("workspace(") and r.get("window_frame")
                         and str(r.get("key")) != f"workspace({next((w.get('key') for w in topology().get('workspaces') or [] if w.get('id') == self.base['workspace']), '')})"), None)
            if not row:
                return {"skipped": "no sidebar row geometry (debug.sidebar_rows)"}
            f = row["window_frame"]  # window points, top-left origin, as debug.mouse
            x, y, w, h = f["x"], f["y"], f["width"], f["height"]
            rpc("debug.workspace_switch", {"action": "start"})
            out = self.frames_during(lambda: rpc("debug.mouse", {"action": "click", "x": x + w / 2, "y": y + h / 2}) and None, settle=0.6)
            timer = rpc("debug.workspace_switch", {"action": "stop"}) or {}
            switches = timer.get("switches") or timer.get("samples") or []
            out["commit_ms"] = stat([s.get("commit_ms") for s in switches])
            out["input_ms"] = stat([s.get("input_ms") for s in switches])
            out["check"] = "ok" if (topology().get("focus") or {}).get("workspace") != self.base["workspace"] else "wrong"
            return out
        self.interaction("click.sidebar_row", click_sidebar_row)

        def divider():
            layers = rpc("debug.layers") or {}
            window = (layers.get("windows") or [{}])[0] if isinstance(layers, dict) else {}
            height = (window.get("frame") or [0, 0, 0, WINDOW[3]])[3]
            areas = sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w)
            if not areas:
                return {"skipped": "no vertical divider"}
            x0, y0 = areas[0]
            def body():
                rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
                x = x0
                for delta in [3.0] * 30 + [-3.0] * 30:
                    rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                                        "press": False, "release": False})
                    x += delta
                    time.sleep(1 / 120)  # test harness: one pointer event per 120 Hz frame
                rpc("debug.mouse", {"action": "up", "x": x, "y": y0})
            return self.frames_during(body)
        self.interaction("drag.divider", divider)

        def resize():
            def body():
                rpc("debug.mouse", {"action": "down", "x": WINDOW[2] - 1, "y": WINDOW[3] - 1})
                for step in range(1, 41):
                    d = 4 * (step if step <= 20 else 40 - step)
                    rpc("debug.mouse", {"action": "drag", "x": WINDOW[2] - 1 - d, "y": WINDOW[3] - 1 - d / 2,
                                        "to_x": WINDOW[2] - 1 - d, "to_y": WINDOW[3] - 1 - d / 2, "steps": 1, "press": False, "release": False})
                    time.sleep(1 / 120)  # test harness: one pointer event per 120 Hz frame
                rpc("debug.mouse", {"action": "up", "x": WINDOW[2] - 1, "y": WINDOW[3] - 1})
            return self.frames_during(body, settle=0.6)
        self.interaction("resize.window", resize)

        def fullscreen():
            rpc("debug.window_transition", {"action": "start"})
            def body():
                rpc("debug.key", {"key": "f", "modifiers": ["cmd", "control"]})
                time.sleep(1.5)  # test harness: the full-screen animation (system, ~0.7 s) runs out
                rpc("debug.key", {"key": "f", "modifiers": ["cmd", "control"]})
                time.sleep(1.5)  # test harness: the exit animation runs out
            out = self.frames_during(body)
            out["transition"] = rpc("debug.window_transition", {"action": "stop"})
            return out
        self.interaction("fullscreen.in_out", fullscreen)

        def hover():
            window = self.pane_chrome()
            pane = next((p for p in window.get("panes") or [] if p.get("pane") == self.base["pane"]), None)
            if not pane or not pane.get("strip") or not pane.get("tab_slots"):
                return {"skipped": "no tab strip geometry"}
            sx, sy, sw, sh = pane["strip"]
            slot = pane["tab_slots"][-1]
            def body():
                rpc("debug.mouse", {"action": "move", "x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2})
                time.sleep(1.2)  # test harness: the hover card's delay
            out = self.frames_during(body)
            cards = rpc("debug.hover_cards") or {}
            out["card"] = {k: cards.get(k) for k in ("phase", "kind", "visible") if isinstance(cards, dict)}
            rpc("debug.mouse", {"action": "leave"})
            return out
        self.interaction("hover.tab_card", hover)

        def cmd_tab():
            rows = []
            for _ in range(10):
                rpc("debug.app_activation", {"active": False, "window_notices": True})
                time.sleep(0.3)  # test harness: the app sits in the background between Cmd-Tabs
                t0 = uptime()
                reply = rpc("debug.app_activation", {"active": True, "window_notices": True}) or {}
                t1 = uptime()
                rpc("debug.layout_counters")
                rows.append({"observers_ms": reply.get("observers_ms"), "round_trip_ms": (t1 - t0) * 1000,
                             "drain_ms": (uptime() - t1) * 1000})
                time.sleep(0.3)  # test harness: trailing work ends
            return {"observers_ms": stat([r["observers_ms"] for r in rows]), "round_trip_ms": stat([r["round_trip_ms"] for r in rows]),
                    "drain_ms": stat([r["drain_ms"] for r in rows])}
        self.interaction("activate.cmd_tab", cmd_tab)

        def tab_drag():
            window = self.pane_chrome()
            panes = window.get("panes") or []
            src = next((p for p in panes if p.get("pane") == self.base["pane"]), None)
            dst = next((p for p in panes if p.get("pane") != self.base["pane"] and p.get("cell")), None)
            if not src or not dst or not src.get("tab_slots"):
                return {"skipped": "no two panes with geometry"}
            sx, sy, sw, sh = src["strip"]
            slot = src["tab_slots"][0]
            cx, cy, cw, ch = dst["cell"]
            before = counts(shape(topology()))
            def body():
                rpc("debug.mouse", {"action": "drag", "x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2,
                                    "to_x": cx + cw / 2, "to_y": cy + ch / 2, "steps": 30})
            out = self.frames_during(body, settle=0.8)
            moved = [p for p in panes_of(next((w for w in topology().get("workspaces") or [] if w.get("id") == self.base["workspace"]), {}))
                     if p.get("id") == self.base["pane"]]
            out["check"] = "ok" if moved and len(moved[0].get("tabs") or []) < len(self.base["shape"]["workspaces"][self.base["workspace"]][self.base["pane"]]) else "wrong"
            out["counts_before"] = before
            return out
        self.interaction("drag.tab_to_pane", tab_drag)

    # The whole session.

    def run(self, actions):
        self.build()
        self.validity = self.check_validity()
        self.idle = self.frames_during(lambda: time.sleep(3.0) and None, settle=0)
        note(f"every-action: {self.session} idle frames {json.dumps(self.idle['frames'])}")
        later = []
        for index, action in enumerate(actions):
            if re.match(WINDOW_CLOSERS, action["id"]) and self.session == "light":
                later.append(action)
                continue
            try:
                row = self.run_action(action)
            except SessionShapeError:
                raise  # a restore rebuilt another layout: the session fails, it is never measured as STRESS
            except Exception as error:  # a harness failure (a builder step's timeout too) is this action's row; the session goes on
                row = {"session": self.session, "kind": "action", "id": action["id"], "errors": [f"harness: {error!r}"[:240]],
                       "frames": {"missed": None}, "check": "n/a"}
            self.rows.append(row)
            note(f"every-action: {self.session} {index + 1}/{len(actions)} {action['id']}: "
                 + (f"skipped ({row['skipped']})" if row.get("skipped") else
                    f"commit {(row.get('commit_ms') or {}).get('p95')} turn {(row.get('turn_ms') or {}).get('p95')} "
                    f"missed {row['frames']['missed']} errors {row['errors'][:2]} check {row['check']}"))
            if any(e.startswith("harness:") for e in row.get("errors") or []):
                self.relaunch_session(f"a harness failure in {action['id']} (its restore or a builder step)")
            elif (rpc("system.ping", timeout=10) or {}).get("pong") is not True:
                self.rows[-1]["errors"] = sorted(set(self.rows[-1].get("errors") or []) | {"the app stopped answering"})
                self.relaunch_session(f"the app stopped answering after {action['id']}")
        if not opts.no_interactions and (not opts.shard or "1" in opts.shard.split("/")[0].split(",")):
            self.run_interactions()
        for action in later:
            row = self.run_action(action)
            row["note"] = "ran last; the app relaunched after it"
            self.rows.append(row)
            self.relaunch_session(f"{action['id']} closed the windows")
        return self

    def relaunch_session(self, why):
        """The one way back to a known session, after an action's or an interaction's restore failed (a builder step
        timed out, the app stopped answering) and after a window-closing action: relaunch the app, then build(). In
        STRESS, build() runs perf-stress-session's shape check, so a session that does not come back as STRESS fails
        there. The next row is never measured on a half-restored layout."""
        note(f"every-action: {self.session}: {why}; relaunching and building the session again")
        self.app.relaunch()
        self.build()

    def check_validity(self):
        """Chromium really runs (PL-engine): no unavailable reason, no WebKit fallback, Chromium the default engine,
        no dev-server web-dev.json, and the shown Chromium tabs are CEF tabs (debug.cef devtools: one per shown CEF tab)."""
        cef = rpc("debug.cef") or {}
        bad = []
        if not isinstance(cef, dict) or error_of(cef):
            bad.append(f"debug.cef: {error_of(cef)}")
            cef = {}
        if cef.get("unavailable"):
            bad.append(f"unavailable {cef['unavailable']}")
        if cef.get("fallback"):
            bad.append(f"fallback {cef['fallback']}")
        if cef.get("default_engine") != "chromium":
            bad.append(f"default engine {cef.get('default_engine')}")
        if cef.get("ready_after_launch_s") is None:
            bad.append(f"Chromium not ready (state {cef.get('state')})")
        web_dev = os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json"))
        if web_dev:
            bad.append("~/.config/cmux/web-dev.json")
        shown = None
        if self.show("chromium"):
            shown = len((rpc("debug.cef") or {}).get("devtools") or [])
            if not shown:
                bad.append("the base pane's Chromium tab is not a CEF tab")
        validity = {"chromium_ok": not bad, "cef_flags": bad, "web_dev_json": web_dev, "shown_cef_tabs": shown,
                    "cef": {k: cef.get(k) for k in ("state", "default_engine", "unavailable", "fallback", "ready_after_launch_s",
                                                    "initialize_ms", "footprint_mb")}}
        note(f"every-action: {self.session} validity {json.dumps(validity)[:400]}")
        self.home()
        return validity


def probe_rows():
    try:
        with open(PROBE) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


# ----------------------------------------------------------------------------------------------------------
# The always-on action signposts (CmuxNextSignposts, 7550ef0ed36): action.perform (the handler's main-thread
# time) and action.commit (to the end of the Core Animation commit after it) of every action run.

def mach_timebase():
    """Seconds per mach_absolute_time tick (mach_timebase_info), or None."""
    try:
        import ctypes

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
        info = Timebase()
        if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(info)) != 0 or not info.denom:
            return None
        return info.numer / info.denom / 1e9
    except (OSError, AttributeError):
        return None


class SignpostStream:
    """`log stream --signpost` of the app's action category, read live on a thread: the sweep waits for each
    action's commit and reads its intervals. Rows also keep wall-clock windows; OUT/signposts.ndjson keeps the stream."""
    PREDICATE = 'subsystem == "com.cmuxterm.app.next" AND category == "action"'

    def __init__(self, path):
        self.path, self.process, self.error, self.live = path, None, None, False
        self.pids, self.opened, self.done, self.lost, self.missed = set(), {}, [], 0, 0
        self.timebase = mach_timebase()
        self.wall_to_uptime = uptime() - time.time()
        self.lock = threading.Lock()  # test harness: the reader thread appends, the sweep reads

    def start(self, module):
        self.module = module
        try:
            self.handle = open(self.path, "w")
            self.process = subprocess.Popen(["/usr/bin/log", "stream", "--signpost", "--style", "ndjson",
                                             "--predicate", self.PREDICATE], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except OSError as error:
            self.error = str(error)
            return
        self.process.stdout.readline()  # the filter line: attached
        self.live = True
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        for line in self.process.stdout:
            self.handle.write(line)
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("eventType") == "lossEvent":
                self.lost += 1
                continue
            if event.get("eventType") != "signpostEvent" or (self.pids and event.get("processID") not in self.pids):
                continue
            key = (event.get("processID"), event.get("signpostName"), event.get("signpostID"))
            mach = event.get("machTimestamp")
            # mach_absolute_time is CLOCK_UPTIME_RAW: the sweep's own clock. The wall clock only for a line without it.
            at = mach * self.timebase if isinstance(mach, int) and self.timebase else \
                self.module.parse_time(event["timestamp"]) + self.wall_to_uptime
            with self.lock:
                if event.get("signpostType") == "begin":
                    self.opened[key] = (at, self.module.fields(event.get("eventMessage", "")))
                elif event.get("signpostType") == "end" and key in self.opened:
                    begin, info = self.opened.pop(key)
                    if self.module.fields(event.get("eventMessage", "")).get("commit") == "missed":
                        self.missed += 1
                        continue  # the commit boundary missed this run's commit (PL-arch review 1): no commit time
                    self.done.append({"name": key[1], "id": info.get("id"), "origin": info.get("origin"),
                                      "input_age_ms": info.get("input_age_ms"), "begin": begin, "end": at, "ms": (at - begin) * 1000})

    def stop(self):
        if not self.process:
            return
        self.process.send_signal(signal.SIGINT)  # our own log stream child: it flushes and exits
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.thread.join(timeout=10)
        self.handle.close()

    def intervals(self):
        with self.lock:
            return list(self.done)

    def wait_commit(self, action_id, since, seconds):
        if not self.live:
            return None
        return wait(lambda: any(i["name"] == "action.commit" and i["id"] == action_id and i["begin"] >= since - 0.002
                                for i in self.intervals()), seconds, step=0.01)

    def runs(self, start, end):
        """Action runs that began in [start, end]: id, begin, perform_ms, commit_end (action.commit opens just
        before action.perform of the same run)."""
        inside = [i for i in self.intervals() if start - 0.002 <= i["begin"] <= end]
        commits = [i for i in inside if i["name"] == "action.commit"]
        found = []
        for perform in sorted((i for i in inside if i["name"] == "action.perform"), key=lambda i: i["begin"]):
            commit = next((c for c in commits if c["id"] == perform["id"] and 0 <= perform["begin"] - c["begin"] < 0.005), None)
            if commit:
                commits.remove(commit)
            found.append({"id": perform["id"], "begin": perform["begin"], "perform_ms": perform["ms"],
                          "commit_end": commit["end"] if commit else None, "commit_ms": commit["ms"] if commit else None})
        return found


SIGNPOSTS = SignpostStream(os.path.join(OUT, "signposts.ndjson"))


# ----------------------------------------------------------------------------------------------------------
# Report.

def misses(row):
    """Why a row misses a target (empty: it meets them)."""
    if row.get("skipped"):
        return []
    why = []
    commit = (row.get("commit_ms") or {}).get("p95")
    result = (row.get("result_ms") or {}).get("p95") if isinstance(row.get("result_ms"), dict) else None
    if isinstance(commit, (int, float)) and commit > TARGET_COMMIT_MS:
        why.append(f"commit p95 {commit} ms")
    if isinstance(result, (int, float)) and result > TARGET_COMMIT_MS:
        why.append(f"result p95 {result} ms")
    turn = (row.get("turn_ms") or {}).get("p95")
    if isinstance(turn, (int, float)) and turn > TARGET_TURN_MS:
        why.append(f"turn p95 {turn} ms")
    frames = row.get("frames") or {}
    if frames.get("missed"):
        main = frames.get("main_max_ms") or 0
        cause = f"main thread {main} ms" if main > (frames.get("refresh_ms") or 16.67) else "main thread under a frame"
        why.append(f"{frames['missed']} missed frames at {frames.get('refresh_ms')} ms ({cause})")
    for key in ("key_to_frame_ms",):
        p95 = (row.get(key) or {}).get("p95")
        if isinstance(p95, (int, float)) and p95 > TARGET_COMMIT_MS:
            why.append(f"key to frame p95 {p95} ms")
    errors = [e for e in row.get("errors") or [] if not refusal(e)]
    if errors:
        why.append("error: " + "; ".join(errors)[:160])
    if row.get("error"):
        why.append("error: " + str(row["error"])[:160])
    if row.get("check") == "wrong":
        why.append("wrong result")
    return why


def refusal(error):
    """A refusal the sweep's own context or missing arguments caused (the action says what it needs), not an app error."""
    head = error.split(":")[0]
    return head in ("unavailable", "disabled", "not_found", "invalid_argument", "invalid_params") or "unavailable" in head


def score(row):
    values = [(row.get(k) or {}).get("p95") for k in ("commit_ms", "result_ms", "key_to_frame_ms")
              if isinstance(row.get(k), dict)]
    values = [v for v in values if isinstance(v, (int, float))]
    return (max(values) if values else 0) + 50 * ((row.get("frames") or {}).get("missed") or 0) + (500 if [e for e in row.get("errors") or [] if not refusal(e)] or row.get("error") else 0)


def failure_line(failure):
    shard = f" (shard {failure['shard']})" if failure.get("shard") else ""
    return f"- {failure['name']}{shard}, after {failure.get('rows', 0)} rows: {failure.get('error', '')[:600]}"


def markdown(report):
    lines = [f"# every-action sweep: {report['env']['host']} macOS {report['env']['macos']} build {report['env']['sha'][:12]}", ""]
    lines.append(f"Targets: commit p95 <= {TARGET_COMMIT_MS} ms, turn p95 <= {TARGET_TURN_MS} ms, 0 missed frames, no errors, right result.")
    failed = report.get("failed_sessions") or []
    if failed:
        lines += ["", f"## FAILED: {len(failed)} session(s) did not finish", ""] + [failure_line(f) for f in failed]
    if not report["sessions"]:
        lines += ["", "No session finished."]
    for session in report["sessions"]:
        rows = session["rows"] + session["interactions"]
        ran = [r for r in session["rows"] if not r.get("skipped")]
        missed = [r for r in rows if misses(r)]
        lines += ["", f"## {session['name']}", ""]
        if session.get("failed"):
            lines += ["FAILED partway: the rows below cover only the actions before the failure.", ""] + \
                [failure_line(f) for f in session["failed"]] + [""]
        lines += [f"Session: {json.dumps(session['summary'])[:400]}", "",
                  f"Validity: Chromium ok {session['validity'].get('chromium_ok')} (flags {session['validity'].get('cef_flags')}), "
                  f"refresh {session['idle']['frames'].get('refresh_ms')} ms, idle 3 s missed {session['idle']['frames'].get('missed')} frames.", "",
                  f"Actions: {len(session['rows'])} listed, {len(ran)} ran, {len(session['rows']) - len(ran)} skipped; "
                  f"{len(missed)} rows miss a target.", "",
                  "| # | id | entry | commit p95 | turn p95 | wait p95 | missed | errors / check | why |", "|---|---|---|---|---|---|---|---|---|"]
        for index, row in enumerate(sorted(missed, key=score, reverse=True)):
            lines.append(f"| {index + 1} | {row['id']} | {','.join(row.get('entries') or [row.get('kind')])} | "
                         f"{(row.get('commit_ms') or {}).get('p95')} | {(row.get('turn_ms') or {}).get('p95')} | "
                         f"{(row.get('wait_ms') or {}).get('p95')} | {(row.get('frames') or {}).get('missed')} | "
                         f"{'; '.join(row.get('errors') or [])[:80]} {row.get('check', '')} | {'; '.join(misses(row))[:160]} |")
        refused = [r for r in session["rows"] if r.get("errors") and all(refusal(e) for e in r["errors"])]
        if refused:
            lines += ["", f"Refused in the sweep's context ({len(refused)}; timed, not counted as errors):", ""]
            for row in refused:
                lines.append(f"- {row['id']}: {row['errors'][0][:160]}")
        skipped = {}
        for row in session["rows"]:
            if row.get("skipped"):
                skipped.setdefault(row["skipped"], []).append(row["id"])
        lines += ["", "Skipped:", ""]
        for reason, ids in sorted(skipped.items(), key=lambda kv: -len(kv[1])):
            lines.append(f"- {reason} ({len(ids)}): {', '.join(ids[:12])}{' ...' if len(ids) > 12 else ''}")
    return "\n".join(lines) + "\n"


def main():
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    SIGNPOSTS.start(load("perf_signposts", "perf-signposts.py"))
    if not SIGNPOSTS.live:
        raise SystemExit(f"every-action: no signpost stream ({SIGNPOSTS.error})")
    app = App()
    app.launch()
    identify = rpc("system.identify") or {}
    methods = set(identify.get("methods") or [])
    sha = os.environ.get("CMUX_CI_SHA") or subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    env = {"host": os.uname().nodename, "macos": platform.mac_ver()[0], "machine": platform.machine(), "sha": sha,
           "app": opts.app, "tag": opts.tag, "signposts": SIGNPOSTS.live, "load": os.getloadavg()}
    note(f"every-action: env {json.dumps(env)}")
    listed = rpc("action.list") or {}
    actions = sorted(listed.get("actions") or [], key=lambda a: a["id"])
    DESTRUCTIVE.update(a["id"] for a in actions if a.get("destructive"))
    only = {a for a in opts.only.split(",") if a}
    if only:
        actions = [a for a in actions if a["id"] in only]
    if opts.shard:
        ks, n = opts.shard.split("/")
        picks = {int(k) - 1 for k in ks.split(",")}
        actions = [a for index, a in enumerate(actions) if index % int(n) in picks]
        env["shard"] = opts.shard
    if opts.limit:
        actions = actions[:opts.limit]
    surfaces = os.path.join(ROOT, "plans/cmux-next/action-surfaces.json")
    try:
        exported = {a["id"] for a in json.load(open(surfaces))["actions"]}
    except (OSError, ValueError, KeyError):
        exported = set()
    env["catalog"] = {"live": len(listed.get("actions") or []), "exported": len(exported),
                      "live_not_exported": sorted({a["id"] for a in listed.get("actions") or []} - exported)[:40],
                      "exported_not_live": sorted(exported - {a["id"] for a in listed.get("actions") or []})[:40]}
    report = {"env": env, "sessions": []}
    report_path = opts.json or os.path.join(OUT, "every-action.json")
    try:
        for index, name in enumerate([s for s in opts.sessions.split(",") if s]):
            sweep = Sweep(app, name, stress_module)
            failure = None
            try:
                if index:
                    app.relaunch()  # each session starts from a fresh app: STRESS is exactly perf-stress-session's shape
                sweep.run(actions)
            # The session failed: the other sessions still run, each from its own fresh launch, and the run exits
            # FAILED_SESSION_EXIT. LaunchError is a SystemExit (an app that crashed and did not come back at a
            # relaunch): it is this session's failure too, not an exit that skips its rows and the report.
            except (Exception, LaunchError) as error:
                note(f"every-action: the {name} session failed: {error!r}")
                failure = {"name": name, "error": repr(error)[:2000], "rows": len(sweep.rows)}
                if opts.shard:
                    failure["shard"] = opts.shard
                report.setdefault("failed_sessions", []).append(failure)
                if not getattr(sweep, "validity", None):
                    continue  # failed before it measured anything: failed_sessions is its whole record
            entry = {"name": name, "summary": getattr(sweep, "summary", {}), "validity": sweep.validity,
                     "idle": getattr(sweep, "idle", {"frames": {}}), "rows": sweep.rows, "interactions": sweep.interactions}
            if failure:
                entry["failed"] = [failure]  # its rows cover only the actions before the failure
            report["sessions"].append(entry)
            with open(report_path, "w") as f:
                json.dump(report, f, indent=1, default=str)
    finally:
        with open(report_path, "w") as f:
            json.dump(report, f, indent=1, default=str)
        if report_path != os.path.join(OUT, "every-action.json"):
            with open(os.path.join(OUT, "every-action.json"), "w") as f:
                json.dump(report, f, indent=1, default=str)
        with open(os.path.join(OUT, "every-action.md"), "w") as f:
            f.write(markdown(report))
        SIGNPOSTS.stop()
        try:
            intervals = SIGNPOSTS.intervals()
            report["env"]["signposts"] = {"intervals": len(intervals), "error": SIGNPOSTS.error, "lost": SIGNPOSTS.lost,
                                          "commit_missed": SIGNPOSTS.missed, "mach_clock": bool(SIGNPOSTS.timebase),
                                          "negative_waits": sum(1 for se in report["sessions"] for r in se["rows"]
                                                                if ((r.get("wait_ms") or {}).get("p50") or 0) < 0)}
        except Exception as error:  # the report still lands without the signpost join
            report["env"]["signposts"] = {"error": f"join: {error}"}
        with open(report_path, "w") as f:
            json.dump(report, f, indent=1, default=str)
        with open(os.path.join(OUT, "every-action.md"), "w") as f:
            f.write(markdown(report))
        if not opts.keep:
            app.stop()
    note(f"every-action: wrote {report_path} and {os.path.join(OUT, 'every-action.md')}")
    if report.get("failed_sessions"):
        report_to_log(report)
    fail_on_failed_sessions(report)


def report_to_log(report):
    """Prints `report` into the step log, for a run that exits FAILED_SESSION_EXIT. The controller returns --artifact
    files only when the step passes (`cmux-ci run --help`), so without this a failed STRESS session would also lose
    the finished light session's rows. Prints every-action.md as it is, then the JSON (gzip, base64) in
    REPORT_LINE_CHARS pieces, `EVERY-ACTION-REPORT k/N <piece>`. report_from() reads them back (--merge OUT STEP.log)."""
    note("every-action: the step fails, so its artifacts do not come back; the report follows in the step log")
    print(markdown(report), flush=True)
    data = base64.b64encode(gzip.compress(json.dumps(report, default=str).encode())).decode()
    pieces = [data[i:i + REPORT_LINE_CHARS] for i in range(0, len(data), REPORT_LINE_CHARS)]
    for index, piece in enumerate(pieces):
        print(f"{REPORT_LINE} {index + 1}/{len(pieces)} {piece}")
    sys.stdout.flush()


def report_from(path):
    """The report in `path`: an every-action JSON file, or a step log holding report_to_log()'s lines (any prefix the
    log store adds before them is ignored). A log without all N pieces of one report is an error, never a partial
    report."""
    with open(path) as f:
        text = f.read()
    try:
        return json.loads(text)
    except ValueError:
        pass
    pieces, totals = {}, set()
    for match in re.finditer(rf"{REPORT_LINE} (\d+)/(\d+) ([A-Za-z0-9+/=]+)", text):
        pieces[int(match.group(1))] = match.group(3)
        totals.add(int(match.group(2)))
    if len(totals) != 1 or sorted(pieces) != list(range(1, max(totals) + 1)):
        raise SystemExit(f"every-action: {path} is not a report, and not a step log with one whole report "
                         f"(pieces {sorted(pieces)[:8]} of {sorted(totals)})")
    return json.loads(gzip.decompress(base64.b64decode("".join(pieces[k] for k in sorted(pieces)))))


def fail_on_failed_sessions(report):
    """Exits FAILED_SESSION_EXIT when a session of `report` failed (after the report is written)."""
    failed = report.get("failed_sessions") or []
    if failed:
        note(f"every-action: FAILED: {len(failed)} session(s) failed: {', '.join(f['name'] for f in failed)}")
        raise SystemExit(FAILED_SESSION_EXIT)


def merge(out, paths):
    """One report from shard reports (same host and build): sessions joined by name, rows by action id."""
    reports = [report_from(p) for p in paths]
    merged = {"env": dict(reports[0]["env"], shards=[r["env"].get("shard") for r in reports]), "sessions": []}
    for report in reports:
        shard = report["env"].get("shard")
        # A shard's failure stays a failure of the merged run (its missing rows are not covered actions).
        for failure in report.get("failed_sessions") or []:
            merged.setdefault("failed_sessions", []).append(dict(failure, shard=failure.get("shard") or shard))
        for session in report["sessions"]:
            failures = [dict(f, shard=f.get("shard") or shard) for f in session.get("failed") or []]
            into = next((s for s in merged["sessions"] if s["name"] == session["name"]), None)
            if into is None:
                first = json.loads(json.dumps(session))
                if failures:
                    first["failed"] = failures
                merged["sessions"].append(first)
                continue
            into["rows"] += session["rows"]
            into["interactions"] += session["interactions"]
            if failures:
                into.setdefault("failed", []).extend(failures)
    for session in merged["sessions"]:
        session["rows"].sort(key=lambda r: r["id"])
    with open(out, "w") as f:
        json.dump(merged, f, indent=1, default=str)
    with open(os.path.splitext(out)[0] + ".md", "w") as f:
        f.write(markdown(merged))
    print(f"every-action: merged {len(paths)} shards into {out}")
    fail_on_failed_sessions(merged)


if __name__ == "__main__":
    if MERGE:
        merge(*MERGE)
    else:
        main()
