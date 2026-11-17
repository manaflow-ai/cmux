#!/usr/bin/env python3
"""Key to frame for the three typing surfaces of cmux NEXT (perf-lead.md issue 5; target p95 < 8 ms).

Launches the tagged DEBUG app itself on a GUI host (no activation, scratch cmux.json and Ghostty config, an
isolated Chief home, the mock agent host, the typing probe on, the hang watchdog at 8 ms) and types one key at a
time (`debug.key` with the client's send time as the event timestamp, so the wait for the main thread counts, as a
real key waits in the event queue) into:

  terminal   a zsh prompt (`zsh -f`): send to the frame whose layer contents show the echo (`contents_ms`)
  home       the native Home composer (the Home fixture: the same MessagesLab view and field over the mock
             owner): send to the end of the run-loop turn that committed the edit (`commit_ms`)
  dock       the docked Home the app opens at launch (the real Home owner), when it shows a conversation
  omnibar    the omnibar of a Chromium tab: send to the commit of the edit (`commit_ms`)
  chat       the agent chat's composer, the webview a prompt is typed into: key to the frame that paints
             the character, from the page's own per-key samples (`page_paint_ms`, debug.agent_pane
             typing_stats), because the probe's `contents_ms` is the terminal's layer-contents mark and
             nothing marks it for a Chromium page. Beside it `submitted_ms`, the mark chat and terminal share:
             key to the frame handed on for display (the terminal's `contents_ms`; the chat's element timing
             `presentationTime`, 4 ms steps, `submitted_floor_ms` its earliest; see SUBMITTED_PAGE).
             Measured in one app on one host beside the terminal, so
             the pair is readable (Leo, 2026-11-17: "man the difference typing on terminal vs gui is def
             noticeable rn ... slow and sad comparatively on the latter")

each in two phases:

  idle       nothing else runs
  load       --busy terminals print without pause (three of them visible next to the typed surface, the rest in
             other workspaces), --chats mock agent chats stream (debug.agent_pane stream), and for home the
             fixture's Chief streams a reply into the transcript at 30 tokens/s

Per surface and phase: key-to-frame p50/p95/p99/max, the probe's hop split (send to dispatch, dispatch, dispatch to
frame), main-thread hangs over 8 ms (`debug.hangs`), and with --sample a `/usr/bin/sample` of the app during the
load phase's keys (the main thread's heaviest frames). The display's refresh rate is in the report (judge drops in
frames). Exit 1 with --gate-p95-ms when any measured surface's p95 is over it.

  typing-frame-bench.py --app APP --tag TAG --out DIR [--json FILE] [--surfaces terminal,home,dock,omnibar]
      [--phases idle,load] [--samples 80] [--busy 20] [--chats 2] [--sample] [--gate-p95-ms 8]
  typing-frame-bench.py --app APP --tag TAG --out DIR --surfaces terminal,chat   # the terminal/GUI pair

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=typing-frame [--arg=--stress] [--arg=--sample] \\
    [--arg=--gate-p95-ms=8]
"""
import argparse, csv, glob, json, os, re, socket, statistics, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--surfaces", default="dock,terminal,home,omnibar,chat")
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--samples", type=int, default=80)
parser.add_argument("--interval", type=float, default=0.1, help="seconds between keys (one key in flight)")
parser.add_argument("--busy", type=int, default=20, help="busy terminals in the load phase")
parser.add_argument("--chats", type=int, default=2, help="streaming mock agent chats in the load phase")
parser.add_argument("--stress", action="store_true",
                    help="build the STRESS session first (perf-lead brief: 60 workspaces, the typed workspace a 4x3 grid with "
                         "6 tabs per pane, 10 workspaces with Chromium pages, 10 printing terminals); every phase runs in it. "
                         "Uses scripts/cmux-next/perf-stress-session.py when present, else the builder here")
parser.add_argument("--sessions", help="comma list of light,stress: one app launch each (default: light, or stress with --stress)")
parser.add_argument("--rounds", type=int, default=3, help="every phase this many times per launch (the noise shows)")
# The chat arm's keys were queued, not delivered: `interceptKeyDown` claimed every one of them while the
# router's own dry_run verdict was `deliver`, and the composer's text never changed. For a bare printable
# key the only claimants are routesBareKey, typesAhead and typesIntoPrimaryInput, and type-ahead queues a
# key for a page whose `PageInputReadiness` is not ready (`isReady = documentReady && awaitedTarget == nil`,
# PageInputReadiness.update). `CMUX_DEBUG_FOCUS_WAIT=off` makes it wait for no command focus, so this says
# whether the awaited focus is what holds the keys. A diagnostic, not the measured state: a number taken
# under it is not the app a person types in, and the run says so.
parser.add_argument("--focus-wait", default="", choices=["", "off", "epoch", "field"],
                    help="CMUX_DEBUG_FOCUS_WAIT for the launch (default: the app's own 'field')")
parser.add_argument("--sample", action="store_true", help="/usr/bin/sample the app over each load phase")
parser.add_argument("--gate-p95-ms", type=float)
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"typing-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
PROBE = os.path.join(OUT, "typing.csv")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1400, 900)
BUSY = "while :; do printf '%s busy line %s %s\\n' $RANDOM $RANDOM $RANDOM; done"
results = {"tag": TAG, "host": os.uname().nodename, "opts": vars(opts), "log": [], "runs": []}
app = None
SESSION = "light"
ROUND = 0


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def rpc(method, params=None, timeout=30):
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
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def action(name, args=None, settle=0.0, focus=True, timeout=60, target=None):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def cli(*args, timeout=60):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    try:
        return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


def probe_rows():
    try:
        with open(PROBE) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def refresh_hz():
    out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True, timeout=60).stdout
    rates = re.findall(r"@ ?([\d.]+) ?Hz", out) or re.findall(r"Refresh Rate: ?([\d.]+)", out)
    lines = [l.strip() for l in out.splitlines() if "Hz" in l or "Resolution" in l]
    return {"hz": [float(r) for r in rates] or None, "lines": lines[:6]}


# ---------------------------------------------------------------- load
class Streamer(threading.Thread):
    """Calls `step()` every `period` seconds until stopped (the Home fixture's reply, the agent chats' streams)."""

    def __init__(self, step, period):
        super().__init__(daemon=True)
        self.step, self.period, self.flag, self.calls = step, period, threading.Event(), 0

    def run(self):
        while not self.flag.is_set():
            t0 = time.perf_counter()
            self.step(self.calls)
            self.calls += 1
            rest = self.period - (time.perf_counter() - t0)
            if rest > 0:
                self.flag.wait(rest)  # the stream's pace

    def stop(self):
        self.flag.set()
        self.join(timeout=30)


LOAD = {"made": False, "workspaces": [], "chat_panes": []}
# Every `debug.agent_pane stream` call of the current measure: (kind, pane, start, end, ok, reply). `measure` resets it
# and reports `stream_ok` from it, and how many keys were typed while a stream was in flight.
STREAM_CALLS = []
STREAM_LOCK = threading.Lock()


def ws_panes(ws, docks=True):
    """The panes of workspace `ws` (snapshot.get), docked columns too unless `docks` is False."""
    w = next((w for w in workspaces() if w.get("id") == ws), None)
    return [p for sc in (w or {}).get("screens") or [] for p in sc.get("panes") or [] if docks or not p.get("dock")]


def shown_workspace():
    snap = rpc("snapshot.get") or {}
    return ((snap.get("topology") or snap).get("focus") or {}).get("workspace")


def add_load_chat(ws, anchor):
    """One real agent chat in a pane of its own, split below `anchor` in the shown workspace `ws`, selected there.

    Not a bare `palette.newAgentChat`: that is a person's New Agent Chat, which opens every chat in the chat dock
    (NewChatPlacement), so the --chats load chats were new tabs in the typed chat's own pane, each replacing the tab
    it showed (`"created": []`, and the router's `agentPage(... tab:)` changed between the idle and load rounds): the
    "load chats" were the typed chat. Aimed at a pane with no focus it opens as a tab in that pane (openTargetedChat,
    #23016, as perf-stress-session.py's chats do), unselected while a window shows the pane, so `tab.focus` shows it.
    Returns the pane's key, or None (noted) when no chat page answers in it."""
    before = {p.get("id") for p in ws_panes(ws)}
    action("splitDown", target=f"pane:{anchor}", settle=0.6)
    made = wait(lambda: [p.get("id") for p in ws_panes(ws) if p.get("id") not in before] or None, 10)
    if not made:
        note(f"load: splitDown of {anchor} made no pane in {ws}")
        return None
    pane = made[0]
    tabs = lambda: next((p.get("tabs") or [] for p in ws_panes(ws) if p.get("id") == pane), [])
    old = {t.get("id") for t in tabs()}
    reply = action("palette.newAgentChat", target=f"pane:{pane}", focus=False)
    tab = wait(lambda: next((t for t in tabs() if t.get("id") not in old and t.get("kind") == "conversation"
                             and not str(t.get("id") or "").startswith("pending_tab_")), None), 30)
    if not tab:
        note(f"load: no agent chat tab appeared in {pane} ({json.dumps(reply)[:160]}; tabs {json.dumps(tabs())[:200]})")
        return None
    action("tab.focus", target=f"tab:{tab['id']}", settle=0.5)
    ready = wait(lambda: (lambda r: r if r.get("document_ready") else None)(
        rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, timeout=5) or {}), 30, step=0.5)
    engine = rpc("debug.agent_pane", {"action": "engine", "pane": pane}) or {}
    note(f"load: agent chat {pane} tab {tab['id']} ({engine.get('engine') or engine.get('error')}) ready={bool(ready)}")
    return pane if engine.get("engine") else None


def make_load(surface_ws):
    """Busy terminals (three split beside the typed surface, the rest in other workspaces) and --chats agent chats
    beside it. Returns the key `chat_streams` takes.

    The visible part is made per workspace, in the typed surface's own workspace, shown first. Before, it was made once,
    in whatever workspace showed when the first load phase began (the chat's: `surface_terminal` ran it before
    `focus_terminal`), so the terminal's visible load sat in another workspace, and every stream the terminal's load
    phase asked for answered "pane ... shows no agent tab": `debug.agent_pane` finds a pane only in the workspace a
    window shows (DebugAgentPane.agentPane reads `controller.content`, not the parked workspaces)."""
    if SESSION == "stress":
        if not LOAD["made"]:
            LOAD["made"] = True
            # STRESS has its printing terminals and agent chats already: stream up to --chats of its chats.
            listed = rpc("debug.agent_pane", {"action": "engine", "pane": "none"}) or {}
            LOAD["chat_panes"] = (listed.get("agent_panes") or [])[: opts.chats]
            note(f"load (stress): streaming chats {LOAD['chat_panes']}")
        return "stress"
    ws = surface_ws or shown_workspace()
    if not LOAD["made"]:
        LOAD["made"] = True
        rest = opts.busy - min(3, opts.busy)
        per = 4
        for index in range((rest + per - 1) // per):
            count = min(per, rest - index * per)
            ref = cli("workspace", "create", "--name", f"busy {index}", "--shell", BUSY).stdout.strip()
            LOAD["workspaces"].append(ref)
            for _ in range(count - 1):
                cli("workspace", ref, "focus")
                action("splitDown", settle=0.4)
                action("terminal.sendText", {"text": BUSY + "\r"})
    if ws:
        action("goToWorkspace", {"workspace": ws}, settle=0.5)
    shown = LOAD.setdefault("visible", {})
    if ws in shown:
        return ws
    panes = ws_panes(ws, docks=False) or ws_panes(ws)
    anchor = panes[0].get("id") if panes else None
    visible = min(3, opts.busy)
    for index in range(visible):
        action("splitRight", target=f"pane:{anchor}" if index == 0 and anchor else None, settle=0.6)
        action("terminal.sendText", {"text": BUSY + "\r"})
    chats = [add_load_chat(ws, anchor) for _ in range(opts.chats)] if anchor else []
    shown[ws] = [c for c in chats if c]
    note(f"load in {ws}: {opts.busy} busy terminals ({visible} visible), {len(shown[ws])}/{opts.chats} agent chats {shown[ws]}")
    return ws


def stream_step(kind, panes):
    """One `Streamer` step: a scripted reply streamed into each of `panes` in turn, every call recorded."""
    def step(_):
        for pane in panes:
            t0 = time.perf_counter()
            reply = rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": 40, "seconds": 3, "chunk_ms": 30},
                        timeout=10)
            ok = isinstance(reply, dict) and not reply.get("error")
            with STREAM_LOCK:
                STREAM_CALLS.append((kind, pane, t0, time.perf_counter(), ok, json.dumps(reply)[:200]))
    return step


def chat_stream(pane):
    """A reply streaming into one named pane (the typed chat's own), as `chat_streams` does for the load panes."""
    return Streamer(stream_step("own", [pane]), 3.0) if pane else None


def chat_streams(key):
    """The load chats `make_load` returned `key` for, each streaming a reply."""
    panes = [p for p in (LOAD["chat_panes"] if key == "stress" else LOAD.get("visible", {}).get(key) or []) if p]
    return Streamer(stream_step("load", panes), 3.0) if panes else None


def focus_chat_composer(pane):
    """Re-assert the composer's focus right before the keys, and read both halves of what focus means.

    `surface_chat` already calls `focus_composer` and refuses to measure unless it reports `focused: true`,
    and the first two fleet runs passed that check and still saw the page count 0 keys. So page focus alone
    does not decide the path. `composer_focused` reports two different things and only one of them was read:
    `focused` is the page's caret (`document.activeElement` is the composer's field) and `native` is
    `debugHoldsKeyboard`, whether that pane's view holds the keyboard natively. The key router's type-ahead
    claims a printable key when the screen's primary input claims it and no text input "has the keyboard"
    (`KeyRouter+TypeAhead.typesIntoPrimaryInput`), which is a native question, not a DOM one: a page caret
    with no native keyboard still routes to `beginTyping`, which is what `handled_by: "app"` with an empty
    trace and 0 page keys describes.

    Reads both, right before the keys, and returns them so a round says which focus it measured under.
    """
    focused = rpc("debug.agent_pane", {"action": "focus_composer", "pane": pane}, timeout=20) or {}
    state = rpc("debug.agent_pane", {"action": "composer_focused", "pane": pane}, timeout=20) or {}
    note(f"chat: focus_composer {json.dumps(focused)[:160]}; composer_focused {json.dumps(state)[:160]}")
    return {"focused": state.get("focused") is True, "native": state.get("native") is True,
            "focus_reply": focused, "state": state}


def composer_drawn_text(pane):
    """The chat composer's text as the page draws it (`composerTyped.ts` reads the same node).

    The chat arm's gate was the page's keydown counter, and on this path it is structurally 0: the key
    router consumes the key before AppKit's dispatch (`handled_by: "app"`, empty trace), so no keydown
    listener in the page ever runs. Whether the character still arrives is a different question, and this
    answers it from what is on screen instead of from an event count.
    """
    reply = rpc("debug.agent_pane", {"action": "query", "selector": ".acpmux-md-root", "pane": pane}, timeout=20) or {}
    elements = reply.get("elements") or []
    return "".join(str(el.get("text") or "") for el in elements if isinstance(el, dict))


def router_decision(key="x"):
    """What the key router would do with `key` in the focused pane: its own verdict, no dispatch.

    `debug.key {"dry_run": true}` on the shell window returns the router's decision and the focus it read
    (DebugKey.swift). This names the route a real printable key takes in the chat -- primary input,
    type-ahead, an action or the page -- instead of inferring it from an empty trace.
    """
    return rpc("debug.key", {"key": key, "dry_run": True}, timeout=10)


def activate_app():
    """Bring the app to the front with an Apple Event to itself, as agent-engine-bench's `--activate` does.

    Dropping CMUX_NEXT_NO_ACTIVATE only *permits* activation; nothing asks for it, and BenchApp spawns the
    binary directly rather than through `open`, so the app stayed inactive: the claimant read at
    37373e0cd80 reported `app_active: false` and `key_window: null`, which is why no window took the keys
    and the page's listener never ran. `tell application id ... to activate` is the one call that fixes
    that and needs no Accessibility grant (the System Events route did, and timed out on the fleet host).
    Returns `debug.focus`'s own answer, so a round says whether the app really came forward.
    """
    ident = bundle_id(APP)
    if not ident:
        note("chat: the app has no bundle id in its Info.plist; not activating")
        return None
    done = subprocess.run(["osascript", "-e", f'tell application id "{ident}" to activate'],
                          capture_output=True, text=True, timeout=30)
    time.sleep(1)  # the activation settles before the focus read
    report = rpc("debug.focus") or {}
    state = {"rc": done.returncode, "stderr": (done.stderr or "").strip()[:120],
             "app_active": report.get("app_active"), "key_window": report.get("key_window")}
    note(f"chat: activate {json.dumps(state)}")
    return state


def claimant_state():
    """The `debug.focus` fields that name a key's holder: the creation and New Tab holds, and the window
    the keys go to (`app_active`, `key_window`). Read before the probe key, so a held key says who held it."""
    report = rpc("debug.focus") or {}
    windows = [w for w in report.get("windows") or [] if isinstance(w, dict)]
    return {"app_active": report.get("app_active"), "key_window": report.get("key_window"),
            "new_tab_key_log": (report.get("new_tab_key_log") or [])[-4:],
            "new_tab_key_holds": report.get("new_tab_key_holds"),
            "creation_hold_tab_keys": report.get("creation_hold_tab_keys"),
            "context": report.get("context"),
            "holds": [{"is_key": w.get("is_key"), "creation_hold": w.get("creation_hold"),
                       "creation_hold_end": w.get("creation_hold_end"),
                       "resolved": (w.get("model") or {}).get("resolved")} for w in windows][:3]}


def chat_key_route(pane):
    """The `debug.key` route whose key the chat's composer actually gets, proven before the measure.

    A printable key addressed to the pane's own Chromium page window (`target: "page"`) is meant to travel
    the path a real key takes and be counted by the page's keydown listener. #45273's first two fleet runs
    saw 0 keys on that route and on the shell window, with `handled_by: "app"` and an empty trace, so the key
    router took it first. `focus_chat_composer` logs both halves of focus just before, so the next run says
    whether the pane held the keyboard natively when that happened. Tries the page window first, keeps
    whichever route the page saw, and returns None when neither did, so the surface measures nothing rather
    than report a wrong number.
    """
    activate_app()
    focus_chat_composer(pane)
    note(f"chat: router dry_run {json.dumps(router_decision())[:300]}")
    # Which claimant inside `interceptKeyDown` holds the key. `handled_by: "app"` with an empty trace and
    # a nil `lastInterception` (no action in the reply) rules out every route that runs an action, so what
    # is left is the capture coordinators and type-ahead -- and `debug.focus` reports all of them:
    # `creation_hold` and `creation_hold_end` (CreationInputCoordinator holds a new tab's keys and replays
    # them), `new_tab_key_holds` and `new_tab_key_log`, plus `app_active` and `key_window`, which say
    # whether the keys even go to the window the probe addresses. Named in the log, before the key.
    note(f"chat: claimants {json.dumps(claimant_state())[:600]}")
    # A real click into the composer, not only `field.focus()`: a creation hold ends on the person's own
    # click, and a page that never reported its field gets one this way.
    clicked = rpc("debug.agent_pane", {"action": "click", "selector": ".acpmux-md-root", "pane": pane}, timeout=20)
    note(f"chat: composer click {json.dumps(clicked)[:200]}")
    for params in ({"target": "page", "pane": pane}, {}):
        rpc("debug.agent_pane", {"action": "reset_typing", "pane": pane}, timeout=20)
        before = composer_drawn_text(pane)
        reply = rpc("debug.key", dict(params, key="x"), timeout=10)
        time.sleep(0.3)  # the page's keydown listener and its frame
        stats = rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=20) or {}
        after = composer_drawn_text(pane)
        note(f"chat: route {json.dumps(params)}: the page saw {stats.get('keys')} key(s); "
             f"composer text {json.dumps(before)[:60]} -> {json.dumps(after)[:60]}; "
             f"debug.key {json.dumps(reply)[:220]}")
        rpc("debug.key", dict(params, key="delete"))
        if stats.get("keys"):
            return params
    note(f"chat: journal tail {json.dumps(rpc('debug.journal', {'limit': 12}) or {})[:700]}")
    note("chat: no debug.key route reached the composer; nothing measured")
    return None


def home_stream(tab=None):
    words = ("the chief streams a reply into the transcript while you type in the composer, token by token, " * 40).split()

    def step(index):
        text = " ".join(words[: 1 + index % len(words)])
        params = {"action": "stream", "text": text, "done": index % len(words) == len(words) - 1}
        rpc("debug.home.drive", params, timeout=10)
    return Streamer(step, 1 / 30)


# ---------------------------------------------------------------- STRESS
def build_stress():
    """STRESS through the shared builder (scripts/cmux-next/perf-stress-session.py). The typed terminal is the
    selected terminal of the measured workspace's last pane (the first 10 panes' terminals print), at `zsh -f`.
    Returns the measured workspace's id."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                                       "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(rpc, log=note)
    summary = stress.build()
    note("STRESS-SESSION " + json.dumps(summary))
    results["stress"] = summary
    ws = summary.get("measured")
    panes = stress.panes(stress.workspace(ws))
    if panes:
        last = panes[-1]
        stress.focus_pane(last["id"])
        tab = next((t for t in reversed(last.get("tabs") or []) if t.get("kind") == "terminal"), None)
        if tab:
            stress.action("tab.focus", target=f"tab:{tab['id']}")
            action("terminal.sendText", {"text": "exec /bin/zsh -f\r"})
            time.sleep(1)  # the prompt draws
        LOAD["stress_pane"] = last["id"]
    return ws


def workspaces():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    return topo.get("workspaces") or []


# ---------------------------------------------------------------- typing
def type_keys(count, params, column):
    keys = "abcdefghijklmnopqrstuvwxyz"
    rows_before = len(probe_rows())
    trips = []
    KEY_TIMES.clear()
    # What the app did with each key (`debug.key` reports it): "responder" or "page" went on to AppKit's
    # dispatch, which is where the typing probe opens its sample; "app" means the key router consumed the
    # key before that, so no probe row and no key in the surface (the chat's nulls, `surface_chat`).
    verdicts = {}
    for index in range(count):
        t0 = time.perf_counter()
        reply = rpc("debug.key", dict(params, key=keys[index % len(keys)], timestamp=time.clock_gettime(time.CLOCK_UPTIME_RAW)),
                    timeout=10)
        trips.append((time.perf_counter() - t0) * 1000)
        KEY_TIMES.append(t0)
        if isinstance(reply, dict):
            verdict = f"{reply.get('handled_by')}/{reply.get('action')}@{reply.get('window_kind')}"
            if reply.get("error"):
                verdict = f"error:{json.dumps(reply.get('error'))[:80]}"
                note(f"key {index}: {reply.get('error')}")
        else:
            verdict = f"no reply ({type(reply).__name__})"
        verdicts[verdict] = verdicts.get(verdict, 0) + 1
        rest = opts.interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    time.sleep(0.5)  # the last frame lands
    rows = [r for r in probe_rows()[rows_before:] if r.get("complete") == "1" and r.get(column)]
    return rows, trips, verdicts


GENERIC = ("start", "main", "NSApplicationMain", "_DPSNextEvent", "_DPSBlockUntilNextEventMatchingListInMode", "ReceiveNextEventCommon",
           "_BlockUntilNextEventMatchingListInMode", "RunCurrentEventLoopInMode", "__CFRunLoopRun", "_CFRunLoopRunSpecificWithOptions",
           "CFRunLoopRunSpecific", "__CFRunLoopDoObservers", "__CFRunLoopDoSources0", "__CFRunLoopDoSource1", "__CFRUNLOOP_IS_CALLING_OUT",
           "_dispatch_main_queue_drain", "_dispatch_main_queue_callback_4CF", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__",
           "_dispatch_client_callout", "-[NSApplication run]", "withExtendedLifetime", "__debug_main_executable_dylib_entry_point",
           "CmuxNextApp.main()", "partial apply for closure #1 in CmuxNextApp.main()", "closure #1 in CmuxNextApp.main()",
           "-[NSApplication(NSEventRouting) nextEventMatchingMask", "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask")


def digest_sample(text):
    """The main thread of a `sample` report: busy share, and the heaviest frames inclusive (each counted once per
    path), all and ours (the cmux dylib), and leaves. Percent of all main-thread samples (idle included)."""
    graph = text.split("Call graph:", 1)[-1].splitlines()
    lines, started = [], False
    for line in graph:
        if "com.apple.main-thread" in line:
            started = True
            continue
        if started and re.match(r"^\s{4}\d+ Thread_", line):
            break
        if started:
            lines.append(line)
    inclusive, ours, leaf, stack = {}, {}, {}, []
    total = idle = 0
    for i, line in enumerate(lines):
        m = re.match(r"^([\s+!:|]*)(\d+)\s+(.+?)\s+\(in ([^)]+)\)", line)
        if not m:
            continue
        depth, count, name, image = len(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        total = max(total, count)
        if name not in {n for _, n in stack}:
            inclusive[name] = inclusive.get(name, 0) + count
            if "cmux DEV" in image and not name.startswith(("closure", "thunk", "partial apply", "reabstraction")):
                ours[name] = ours.get(name, 0) + count
        stack.append((depth, name))
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        nm = re.match(r"^([\s+!:|]*)\d+\s", nxt)
        if not nm or len(nm.group(1)) <= depth:
            leaf[name] = leaf.get(name, 0) + count
            if name in ("mach_msg2_trap", "__workq_kernreturn"):
                idle += count
    pct_of = lambda c: round(100.0 * c / total, 1) if total else 0
    top = lambda d, n: [{"frame": k[:200], "pct": pct_of(v)} for k, v in sorted(d.items(), key=lambda kv: -kv[1])
                        if not k.startswith(GENERIC)][:n]
    return {"samples": total, "busy_pct": pct_of(total - idle), "top": top(inclusive, 60), "ours": top(ours, 40), "leaves": top(leaf, 25)}


# Not a probe column: a webview surface's key-to-frame comes from the page's own per-key samples
# (`debug.agent_pane typing_stats`, webviews perf.ts `AcpmuxPerf`), because the probe's `contents_ms` is
# the terminal's layer-contents mark and nothing marks it for a Chromium page (TypingLatencyProbe).
PAGE_PAINT = "page_paint_ms"
# The mark chat and terminal compare on (`submitted_ms` in each run): the frame that shows the key handed on
# for display. The terminal's is `contents_ms` (Ghostty's present callback: its echo frame became the layer's
# contents, after its own Core Animation commit). A Chromium page's frames never pass through the app (its GPU
# process commits them to its own CA context, which the app hosts), so the chat's is the page's element timing
# `presentationTime` of the frame that draws the key (webviews keyPresentation.ts: Chromium's presentation
# feedback of that frame), from the same key event time as `page_paint_ms`. On macOS Chromium's feedback is the
# display time of the refresh its GPU process commits the frame for (its display link), so the chat's mark can sit
# up to one refresh after its commit, where the terminal's is taken. Chromium rounds it up to a 4 ms step
# on a page that is not cross-origin isolated (the agent page): `submitted_floor_ms` is the earliest it can be.
SUBMITTED_PAGE = "page_submitted_ms"


def page_key_to_frame(page, field="to_paint", mark=PAGE_PAINT, keys_field="keys"):
    """`pct`-shaped key-to-frame from the page's typing samples: each key's own event time to after the
    frame that paints it (perf.ts `TypingSample.paint`), or another of its marks (`field`). The page
    summarizes, so there is no p99 or mean."""
    paint = (page or {}).get(field) or {}
    if not (page or {}).get(keys_field) or paint.get("p95_ms") is None:
        return None
    return {"n": page[keys_field], "p50": paint.get("p50_ms"), "p95": paint.get("p95_ms"), "p99": None,
            "max": paint.get("max_ms"), "mean": None, "from": mark}


KEY_TIMES = []  # each key's send time (perf_counter) in the current measure, for `stream_report`
STREAM_FAILURES = []


def stream_report(surface, phase, streams):
    """What the measure's streams did: `stream_ok` and `stream_errors` per kind (`own`: the typed chat's own reply,
    `load`: the --chats load chats), the keys typed while a stream that answered without error was in flight, and
    `stream_check`. A load phase with --chats whose streams answered errors, or whose chat surface typed no key while
    its own reply streamed, FAILS loudly (noted, in the report's `stream_failures`, and --gate-p95-ms exits 1): the
    first fleet runs of the chat arm reported a "chat while its own reply streams" number while every stream answered
    "pane ... shows no agent tab" and the report showed only the first four replies."""
    with STREAM_LOCK:
        calls = list(STREAM_CALLS)
    by_kind = {}
    for kind, _pane, _t0, _t1, ok, _reply in calls:
        k = by_kind.setdefault(kind, {"calls": 0, "ok": 0, "errors": 0})
        k["calls"] += 1
        k["ok" if ok else "errors"] += 1
    during = lambda kinds: sum(any(c[2] <= t <= c[3] for c in calls if c[4] and c[0] in kinds) for t in KEY_TIMES)
    out = {
        "stream_ok": sum(c[4] for c in calls), "stream_errors": sum(not c[4] for c in calls), "stream_by_kind": by_kind,
        "keys_while_streaming": during(("own", "load")), "keys_while_own_stream": during(("own",)),
        "stream_replies": [c[5] for c in calls if not c[4]][:4] + [c[5] for c in calls if c[4]][:2],
    }
    problems = []
    if phase == "load" and opts.chats > 0:
        if not calls:
            problems.append("no stream ran (no load chat was made)")
        if out["stream_errors"]:
            problems.append(f"{out['stream_errors']}/{len(calls)} stream replies were errors: {out['stream_replies'][:1]}")
        if surface == "chat" and not (by_kind.get("own") or {}).get("ok"):
            problems.append("the typed chat's own reply never streamed")
        if surface == "chat" and out["keys_while_own_stream"] < len(KEY_TIMES) // 2:
            problems.append(f"only {out['keys_while_own_stream']}/{len(KEY_TIMES)} keys were typed while its own reply streamed")
    out["stream_check"] = "FAIL: " + "; ".join(problems) if problems else "ok"
    if problems:
        STREAM_FAILURES.append(f"{SESSION} {surface}.{phase} round {ROUND}: {'; '.join(problems)}")
        note(f"FAIL {SESSION} {surface}.{phase}: the load phase's streams failed: {'; '.join(problems)}")
    elif calls:
        note(f"{SESSION} {surface}.{phase}: streams ok {out['stream_ok']} ({json.dumps(by_kind)}), "
             f"{out['keys_while_streaming']}/{len(KEY_TIMES)} keys while streaming, {out['keys_while_own_stream']} during its own reply")
    return out


def main_thread_tree(text, cap=400_000):
    """The main thread's part of a `sample` report's call graph, as written (indented tree), at most `cap` characters."""
    graph = text.split("Call graph:", 1)[-1].splitlines()
    lines, started = [], False
    for line in graph:
        if "com.apple.main-thread" in line:
            started = True
        elif started and re.match(r"^\s{4}\d+ Thread_", line):
            break
        if started:
            lines.append(line)
    tree = "\n".join(lines)
    return tree if len(tree) <= cap else tree[:cap] + "\n... (cut at %d of %d characters)" % (cap, len(tree))


def measure(surface, phase, params, column, pid, streams=(), page_stats=None, probe_column=None):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.timings", {"clear": True})
    rows_before = len(probe_rows())
    rpc("debug.frames", {"action": "start"})
    with STREAM_LOCK:
        STREAM_CALLS.clear()
    KEY_TIMES.clear()
    for s in streams:
        s.start()
    sampler = None
    if opts.sample and phase == "load":
        path = os.path.join(OUT, f"sample-{SESSION}-{surface}-{phase}.txt")
        seconds = max(3, int(opts.samples * opts.interval))
        sampler = (subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-file", path],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), path)
    if streams:
        time.sleep(1.0)  # the streams run before the first key
    # debug.view_churn (which views ask for display or layout while the keys are typed) exists only in a probe
    # build (scratch branch pl-typing-view-churn, never landed: a DEBUG swizzle of NSView); elsewhere this records the error.
    rpc("debug.view_churn", {"action": "start"})
    # `column` is what key-to-frame reads; `probe_column` is the probe row's own last mark, which a
    # page surface closes at its commit (`probe: "commit"`) because no terminal echo follows its key.
    rows, trips, verdicts = type_keys(opts.samples, params, probe_column or column)
    churn = rpc("debug.view_churn", {"action": "stop", "limit": 15}, timeout=20)
    for s in streams:
        s.stop()
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    timings = rpc("debug.timings", timeout=20) or {}
    publishes = [p.get("ms") for p in (timings.get("control_publishes") or []) if isinstance(p, dict)]
    page = page_stats() if page_stats else None
    every = probe_rows()[rows_before:]
    marks = ["dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms", "output_decoded_ms",
             "output_received_ms", "output_parsed_ms", "contents_ms", "commit_ms"]
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20)
    f = lambda key: [float(r[key]) for r in rows if r.get(key)]
    entry = {
        "session": SESSION, "surface": surface, "phase": phase, "keys": len(trips), "measured": len(rows),
        "key_to_frame_ms": page_key_to_frame(page) if column == PAGE_PAINT else pct(f(column)), "column": column,
        "key_verdicts": verdicts, "page_typing": page,
        "send_to_dispatch_ms": pct(f("dispatch_start_ms")),
        "dispatch_ms": pct([float(r["dispatch_end_ms"]) - float(r["dispatch_start_ms"]) for r in rows
                            if r.get("dispatch_end_ms") and r.get("dispatch_start_ms")]),
        "dispatch_to_frame_ms": pct([float(r[probe_column or column]) - float(r["dispatch_end_ms"]) for r in rows
                                     if r.get("dispatch_end_ms")]),
        "key_rpc_ms": pct(trips),
        "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms")}
        if isinstance(hangs, dict) else hangs,
        "hang_records": (hangs or {}).get("records") if isinstance(hangs, dict) else None,
        "frames": frames, "streams": [s.calls for s in streams], "round": ROUND, "focus": LOAD.get("focus"),
        "view_churn": churn, "control_publishes": {"count": len(publishes), "ms": pct(publishes),
                                                   "total_ms": round(sum(publishes), 1)},
        "probe_rows": {"all": len(every), "complete": sum(r.get("complete") == "1" for r in every),
                       "marks": {m: sum(bool(r.get(m)) for r in every) for m in marks}},
    }
    if column == PAGE_PAINT:
        # Null on an app without the page's presentation mark (perf.ts before keyPresentation.ts).
        entry["submitted_ms"] = page_key_to_frame(page, "to_submitted", SUBMITTED_PAGE, "submitted_keys")
        entry["submitted_floor_ms"] = page_key_to_frame(page, "to_submitted_floor", SUBMITTED_PAGE + "_floor",
                                                        "submitted_keys")
    elif column == "contents_ms":
        k = entry["key_to_frame_ms"]
        entry["submitted_ms"] = dict(k, **{"from": column}) if k else None
    entry.update(stream_report(surface, phase, streams))
    if sampler:
        try:
            sampler[0].wait(timeout=opts.samples * opts.interval + 60)
        except subprocess.TimeoutExpired:
            sampler[0].terminate()
        entry["sample"] = os.path.basename(sampler[1])
        try:
            # The report is the fleet step's one artifact: keep the main thread's digest in it.
            text = open(sampler[1], errors="replace").read()
            entry["main_profile"] = digest_sample(text)
            if surface == "chat":
                # The main thread's whole call graph as `sample` wrote it, so a stack above a leaf (a condvar wait
                # under keyDown) can be read from the report, the step's one artifact.
                entry["main_profile"]["raw_tree"] = main_thread_tree(text)
        except OSError:
            pass
    k = entry["key_to_frame_ms"] or {}
    note(f"{SESSION} {surface}.{phase}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
         f"(n={k.get('n')}/{len(trips)}); hangs {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}")
    if column == PAGE_PAINT:
        s, fl = entry.get("submitted_ms") or {}, entry.get("submitted_floor_ms") or {}
        note(f"{SESSION} {surface}.{phase}: key-to-submitted p50 {s.get('p50')} p95 {s.get('p95')} max {s.get('max')} ms "
             f"(floor p50 {fl.get('p50')} p95 {fl.get('p95')}; n={s.get('n')})")
    results["runs"].append(entry)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    return entry


def named_workspace(name):
    """The id of the workspace named `name`, and its panes (snapshot.get)."""
    for w in workspaces():
        if (w.get("name") or w.get("title")) == name:
            panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
            return w.get("id"), panes
    return None, []


def focus_terminal():
    """Shows the typed terminal's workspace and gives its pane the keyboard; returns what has it (debug.focus)."""
    ws, pane = LOAD["terminal_ws"], LOAD.get("stress_pane") or LOAD.get("terminal_pane")
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
    if pane:
        rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane}", "focus": True, "origin": "script"})
    time.sleep(0.5)  # focus settles
    return focus_report()


def focus_report():
    report = rpc("debug.focus") or {}
    windows = [w for w in report.get("windows") or [] if isinstance(w, dict)]
    return {"resolved": report.get("resolved") or report.get("focus"),
            "first_responders": [(w.get("appkit") or {}).get("first_responder") for w in windows][:3]}


def surface_terminal(phase, pid):
    if not LOAD.get("terminal_ws"):
        cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec /bin/zsh -f")
        ws, panes = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("typing")), 20) or (None, [])
        LOAD["terminal_ws"], LOAD["terminal_pane"] = ws, (panes[0].get("id") if panes else None)
        time.sleep(2)  # the prompt draws
    streams = []
    if phase == "load":
        key = make_load(LOAD["terminal_ws"])
        s = chat_streams(key)
        streams = [s] if s else []
    LOAD["focus"] = focus_terminal()
    entry = measure("terminal", phase, {}, "contents_ms", pid, streams)
    action("terminal.sendText", {"text": "\x15"})  # clears the typed line (Ctrl-U)
    return entry


def surface_home(phase, pid):
    # The Home fixture in a workspace of its own (a whole content area, in the light session and in STRESS).
    if not LOAD.get("home_ws"):
        cli("workspace", "create", "--name", "home typing", "--focus")
        ws, _ = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("home typing")), 20) or (None, [])
        LOAD["home_ws"] = ws
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
        time.sleep(1)  # the workspace shows
        opened = rpc("debug.home_native_fixture.open", {"new": True})
        note(f"home fixture in {ws}: {json.dumps(opened)[:160]}")
        time.sleep(2)  # the transcript lays out
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": LOAD["home_ws"]}, "focus": True, "origin": "script"})
    time.sleep(0.5)  # the workspace shows
    key = make_load(LOAD["home_ws"]) if phase == "load" else None
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"home: no composer to focus ({json.dumps(focused)[:160]})")
        return None
    streams = [home_stream()] if phase == "load" else []
    if phase == "load":
        s = chat_streams(key)
        if s:
            streams.append(s)
    LOAD["focus"] = focus_report()
    entry = measure("home", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.home.drive", {"action": "stream", "text": "done", "done": True})
    return entry


def surface_dock(phase, pid):
    # The docked Home the app opened at launch: the home workspace's page.
    homes = rpc("debug.home") or {}
    action("home.show", settle=1.5)
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"dock: no Home composer to focus ({json.dumps(focused)[:160]}; debug.home {json.dumps(homes)[:200]})")
        return None
    return measure("dock", phase, {"probe": "commit"}, "commit_ms", pid, [])


def surface_omnibar(phase, pid):
    key = make_load(None) if phase == "load" else None
    if not LOAD.get("omnibar_open"):
        reply = action("openBrowser.chromium", {"url": "about:blank"}, settle=4.0, timeout=120)
        note(f"omnibar: chromium tab {json.dumps(reply)[:120]}")
        LOAD["omnibar_open"] = True
    action("focusBrowserAddressBar", settle=0.5)
    bar = rpc("debug.omnibar") or {}
    if not bar.get("field_editor_active"):
        note(f"omnibar: the field editor is not active ({json.dumps(bar)[:200]})")
    streams = []
    if phase == "load":
        s = chat_streams(key)
        streams = [s] if s else []
    LOAD["focus"] = focus_report()
    entry = measure("omnibar", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.key", {"key": "escape"})
    return entry


def surface_chat(phase, pid):
    # The agent chat's composer: the webview surface a prompt is typed into, measured on `contents_ms` like the
    # terminal so the pair answers "terminal vs gui" directly. Its own reply streams in the load phase, which is
    # the case the complaint is about: typing while a reply arrives.
    if not LOAD.get("chat_ws"):
        cli("workspace", "create", "--name", "chat typing", "--focus")
        ws, _ = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("chat typing")), 20) or (None, [])
        LOAD["chat_ws"] = ws
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
        time.sleep(1)  # the workspace shows
        reply = action("palette.newAgentChat", settle=1.0)
        # The action answers while the chat still opens: wait for its page, as make_load does.
        ready = wait(lambda: (lambda r: r if r.get("document_ready") else None)(
            rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}), 30, step=0.5)
        engine = rpc("debug.agent_pane", {"action": "engine"}) or {}
        LOAD["chat_pane"] = engine.get("pane")
        note(f"chat: pane {engine.get('pane')} ({engine.get('engine')}) ready={bool(ready)} {json.dumps(reply)[:120]}")
        time.sleep(2)  # the transcript lays out
    else:
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": LOAD["chat_ws"]}, "focus": True,
                           "origin": "script"})
        time.sleep(0.5)  # the workspace shows
    key = make_load(LOAD["chat_ws"]) if phase == "load" else None
    pane = LOAD.get("chat_pane")
    focused = rpc("debug.agent_pane", {"action": "focus_composer", **({"pane": pane} if pane else {})}, timeout=20)
    if not (isinstance(focused, dict) and focused.get("focused")):
        state = rpc("debug.agent_pane", {"action": "composer_focused", **({"pane": pane} if pane else {})})
        note(f"chat: no composer to focus ({json.dumps(focused)[:160]}; composer_focused {json.dumps(state)[:120]})")
        return None
    if not pane:
        note("chat: debug.agent_pane engine named no pane, so the keys have no page window to go to")
        return None
    route = chat_key_route(pane)
    if route is None:
        return None
    streams = []
    if phase == "load":
        own = chat_stream(pane)
        if own:
            streams.append(own)
        other = chat_streams(key)
        if other:
            streams.append(other)
    LOAD["focus"] = focus_report()
    # The page's own per-key marks, so the chat's key-to-frame is its `to_paint` (each key's event time to
    # after the frame that paints it) and the hops split into webview delivery (`to_listener`), the page's
    # edit and render (`to_work`) and the frame after it (`to_frame`): debug.agent_pane typing_stats
    # (webviews perf.ts AcpmuxPerf). `probe: "commit"` closes the native row at the commit after dispatch,
    # since no terminal echo follows a page's key, which keeps the probe's send-to-dispatch hops readable.
    def page_stats():
        return rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=20)

    rpc("debug.agent_pane", {"action": "reset_typing", "pane": pane}, timeout=20)
    entry = measure("chat", phase, dict(route, probe="commit"), PAGE_PAINT, pid, streams,
                    page_stats=page_stats, probe_column="commit_ms")
    # Leave the composer empty for the next round: select all, then delete.
    rpc("debug.key", dict(route, key="a", modifiers=["command"]))
    rpc("debug.key", dict(route, key="delete"))
    return entry


SURFACES = {"terminal": surface_terminal, "home": surface_home, "dock": surface_dock, "omnibar": surface_omnibar,
            "chat": surface_chat}


def run_session(session):
    """One launch of the app (scripts/cmux-next/bench_launch.py): the light session, or STRESS (built first); every
    surface and phase in it, --rounds times."""
    global app, SESSION, SOCKET, CONFIG
    SESSION = session
    LOAD.clear()
    LOAD.update({"made": False, "workspaces": [], "chat_panes": []})
    env = {"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
    if opts.focus_wait:
        # Diagnostic (--focus-wait): what holds the chat's keys. Named in the report so no number taken
        # under it is read as the app's own behaviour.
        env["CMUX_DEBUG_FOCUS_WAIT"] = opts.focus_wait
        note(f"launch: CMUX_DEBUG_FOCUS_WAIT={opts.focus_wait} (diagnostic, not the shipped focus wait)")
    # The chat surface needs the app in front. A bench launches with `CMUX_NEXT_NO_ACTIVATE=1`, under which
    # `CmuxApplication.refusesActivation` refuses every activation, and then no view of the pane holds the
    # keyboard: the measured `composer_focused {"focused": true, "native": false}` of three runs. The key
    # router's type-ahead claims a printable key in exactly that state and types it natively, so the page
    # never sees it and the surface measures nothing. A person types with cmux in front, so a run that
    # measures the chat drops that variable and lets the app activate; BenchApp refuses such a launch on a
    # person's Mac itself (`bench_launch.person_mac_problem`), which is why this needs no guard of its own.
    # The whole launch activates, not the chat part, so a terminal/chat pair is measured under one state and
    # stays comparable. Terminal numbers from an activated run are not comparable with ones from a
    # non-activated run; the pair in one run is.
    if "chat" in opts.surfaces.split(","):
        env["CMUX_NEXT_NO_ACTIVATE"] = None
    bench = BenchApp(APP, out=OUT, config={"browser": {"defaultEngine": "chromium"}}, window=WINDOW,
                     log_name=f"app-{session}.log", env=env)
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            note(f"{session}: the app did not come up: {error.reason}")
            results.setdefault("launch_failures", []).append({"session": session, "reason": error.reason,
                                                              "detail": error.report.get("detail")})
            return
        app, SOCKET, CONFIG = bench.process, bench.socket, os.path.join(bench.scratch, "cmux.json")
        if session == "stress":
            LOAD["terminal_ws"] = build_stress()
            time.sleep(5)  # the grid settles
        surfaces = opts.surfaces.split(",")
        global ROUND
        for ROUND in range(opts.rounds):
            for phase in opts.phases.split(","):
                for surface in surfaces:
                    if surface == "dock" and phase != "idle":
                        continue
                    try:
                        SURFACES[surface](phase, app.pid)
                    except Exception as error:  # one surface failing must not hide the others
                        note(f"{session} {surface}.{phase}: failed: {error!r}")
    finally:
        bench.stop()


def main():
    results["refresh_hz"] = refresh_hz()
    results["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    sessions = opts.sessions.split(",") if opts.sessions else (["stress"] if opts.stress else ["light"])
    try:
        for session in sessions:
            run_session(session)
    finally:
        summary = {}
        for r in results["runs"]:
            summary.setdefault(f"{r['session']}.{r['surface']}.{r['phase']}", []).append((r["key_to_frame_ms"] or {}).get("p95"))
        results["summary_p95_ms"] = summary
        submitted = {}
        for r in results["runs"]:
            if "submitted_ms" in r:
                submitted.setdefault(f"{r['session']}.{r['surface']}.{r['phase']}", []).append(
                    (r["submitted_ms"] or {}).get("p95"))
        results["summary_submitted_p95_ms"] = submitted
        results["stream_failures"] = STREAM_FAILURES
        if STREAM_FAILURES:
            note(f"FAIL: {len(STREAM_FAILURES)} load phase(s) measured with no reply streaming: {STREAM_FAILURES}")
        note(f"summary p95 ms: {json.dumps(summary)} refresh {results.get('refresh_hz')}")
        if opts.json:
            json.dump(results, open(opts.json, "w"), indent=1)
    if opts.gate_p95_ms is not None:
        over = {k: v for k, v in results["summary_p95_ms"].items() if any(x is not None and x > opts.gate_p95_ms for x in v)}
        if STREAM_FAILURES:
            print(f"FAIL load phases measured with no reply streaming: {STREAM_FAILURES}", flush=True)
            sys.exit(1)
        if over or not results["summary_p95_ms"]:
            print(f"FAIL key-to-frame p95 over {opts.gate_p95_ms} ms: {over or 'nothing measured'}", flush=True)
            sys.exit(1)
        print(f"PASS key-to-frame p95 within {opts.gate_p95_ms} ms", flush=True)


if __name__ == "__main__":
    main()
