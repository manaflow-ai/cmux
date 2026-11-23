#!/usr/bin/env python3
"""Key to frame for the native typing surfaces of cmux NEXT (perf-lead.md issue 5; target p95 < 8 ms).

Launches the tagged DEBUG app itself on a GUI host (no activation, scratch cmux.json and Ghostty config, an
isolated Chief home, the mock agent host, the typing probe on, the hang watchdog at 8 ms) and types one key at a
time (`debug.key` with the client's send time as the event timestamp, so the wait for the main thread counts, as a
real key waits in the event queue) into:

  terminal   a zsh prompt (`zsh -f`): send to the frame whose layer contents show the echo (`contents_ms`)
  home       the native Home composer (the Home fixture: the same MessagesLab view and field over the mock
             owner): send to the end of the run-loop turn that committed the edit (`commit_ms`)
  dock       the docked Home the app opens at launch (the real Home owner), when it shows a conversation
  omnibar    the omnibar of a Chromium tab: send to the commit of the edit (`commit_ms`)
  agentpane  the native agent chat composer: send through the page target, validate exact key order/text, and
             join `typing_stats.paint_epoch_ms` to the native dispatch clock (a paint proxy, not presentation).
             `--chat-agent real` attaches an ACP fake agent and streams through AgentPaneTransport/AcpmuxPaneSocket;
             the default mock stream remains a separate in-page diagnostic path.

each in two phases:

  idle       nothing else runs
  load       --busy terminals print without pause (three of them visible next to the typed surface, the rest in
             other workspaces), --chats mock agent chats stream (debug.agent_pane stream), and for home the
             fixture's Chief streams a reply into the transcript at 30 tokens/s

or, with --modes, in the load modes every under-load harness shares (webviews/bench/load-modes.json, cmuxterm-hq
docs/design/chat-instant-under-load.md "The bench"; Leo, 2026-11-16: "but typing under load is not good enough"), so
a native typing number and a web typing number were taken under the same load:

  L0 idle                       L3 the focused chat is the 100k-row fixture, streaming
  L1 the focused chat streams    L4 every core saturated by other processes (--cpu-burners spinning processes)
  L2 10 other chats streaming    L5 L1 to L4 together, in the STRESS session (60 workspaces, 20 printing terminals)

Each mode is one launch of the app, and its knobs come from the registry, not from --busy/--chats. The agentpane
surface seeds the mode's `native.rows` (L3 and L5: 100,000) into the chat it types in (debug.agent_pane seed_rows)
before the chat streams. A knob these surfaces cannot express is in the mode's `nativeMissing`, and a seed that came
up short is added to the run's `mode_missing`; either goes in the report beside the row, so a number is never read
as the full mode. The web side
(L0-L3, its own load model in webviews/bench/composer-load.ts) is `scripts/bench/cmux-bench typing`; this harness's
cmux-bench adapter is `typing-native`.

Per surface and phase: key-to-frame p50/p95/p99/max, the probe's hop split (send to dispatch, dispatch, dispatch to
frame), main-thread hangs over 8 ms (`debug.hangs`), and with --sample a `/usr/bin/sample` of the app during the
load phase's keys (the main thread's heaviest frames). The display's refresh rate is in the report (judge drops in
frames). Exit 1 with --gate-p95-ms when any measured surface's p95 is over it.

  typing-frame-bench.py --app APP --tag TAG --out DIR [--json FILE] [--surfaces terminal,home,dock,omnibar,agentpane]
      [--phases idle,load | --modes L0,L1,L2,L4,L5|all] [--samples 80] [--busy 20] [--chats 2] [--cpu-burners N]
      [--sample] [--chat-agent mock|real] [--gate-p95-ms 8] [--backdrops opaque,opacity85,picture]
      [--ab browserPage.drawKeysAtOnce]
Comparing a key's wait for its frame (`listener -> frame`) across phases needs --chat-agent real: each row
carries `frame_timing.valid`, false for a mock-streamed load phase, because whether the mock keeps the
renderer producing frames like the real transport is not established (hq#15723). Every other number in the
row stands either way.

The perf cron's `typing` part runs the terminal surface only, idle (scripts/cmux-next/perf-cron.py PARTS): its row
terminal.key_to_echo.idle pools every round's keys (`key_to_frame_values`), p50 and p95, budget p95 8 ms.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=typing-frame [--arg=--stress] [--arg=--sample] \\
    [--arg=--gate-p95-ms=8]
"""
import argparse, csv, glob, json, math, os, re, shlex, socket, statistics, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import load_modes  # noqa: E402
from bench_launch import BenchApp, LaunchError, tag_of as bench_tag_of, tag_state_root  # noqa: E402
from state_wait import wait_until, wait_stable  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_AGENT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "cmux-tui/crates/acpmux/tests/fake_agent.py")


def run_agent():
    """ACP harness used by --chat-agent real; stream turns exercise the app transport."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("fake_agent", FAKE_AGENT)
    fake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake)
    inner = fake.handle_prompt
    words = ("the chief streams a reply into the transcript while you type in the composer token by token and a "
             "tool runs beside it printing its test lines").split()

    def handle_prompt(rid, params):
        text = fake.prompt_text(params)
        if "stream:" not in text:
            return inner(rid, params)
        sid = params["sessionId"]
        seconds, chunk_ms, chars = (text[text.index("stream:") + 7:].split() + ["6", "10", "24"])[:3]
        end, i, block = time.monotonic() + float(seconds), 0, 0
        next_tool = time.monotonic()
        while time.monotonic() < end:
            piece = ""
            while len(piece) < int(chars):
                piece += words[i % len(words)] + " "
                i += 1
            fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}})
            if time.monotonic() >= next_tool:
                out = "".join(f"test hub::case_{block}_{n} ... ok\n" for n in range(8))
                fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"t{block}", "title": f"cargo test {block}",
                                  "kind": "execute", "status": "completed", "rawInput": {"command": "cargo test"},
                                  "content": [{"type": "content", "content": {"type": "text", "text": out}}]})
                block += 1
                next_tool += 0.5
            time.sleep(float(chunk_ms) / 1000)
        fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "\n\n"}})
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})

    fake.handle_prompt = handle_prompt
    fake.main()


if __name__ == "__main__" and "--agent" in sys.argv[1:]:
    sys.argv = [a for a in sys.argv if a != "--agent"]
    run_agent()
    sys.exit(0)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--surfaces", default="dock,terminal,home,omnibar,agentpane")
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--modes", help="the shared load modes instead of --phases: a comma list of ids (L0,L1,...) or "
                                    "`all`; one app launch each, knobs from webviews/bench/load-modes.json")
parser.add_argument("--cpu-burners", type=int, default=0,
                    help="spinning processes a mode that saturates every core starts (default: this host's cores)")
parser.add_argument("--launch", choices=("direct", "launchservices"), default="direct",
                    help="how the app starts: `direct` (a child of this script, with its scheduling: on a fleet worker "
                         "the worker's utility clamp) or `launchservices` (`open -n`, as a person's Finder or Dock launch)")
parser.add_argument("--samples", type=int, default=80)
parser.add_argument("--interval", type=float, default=0.1, help="seconds between keys (one key in flight)")
parser.add_argument("--busy", type=int, default=20, help="busy terminals in the load phase")
parser.add_argument("--chats", type=int, default=2, help="streaming mock agent chats in the load phase")
parser.add_argument("--title-churn", action="store_true",
                    help="the busy terminals rename their tab ten times a second (an agent's spinner title) instead of printing")
parser.add_argument("--dock-load", action="store_true", help="measure the docked Home in the load phase too")
parser.add_argument("--words", action="store_true", help="type words with spaces (a sentence), not the alphabet as one word")
parser.add_argument("--fresh-draft", action="store_true",
                    help="empty the Home draft (Cmd-A, Delete) before each measure, so every round types the same draft")
parser.add_argument("--prefill", type=int, default=0,
                    help="with --fresh-draft: the Home draft holds this many characters of words before the measured keys")
parser.add_argument("--stress", action="store_true",
                    help="build the STRESS session first (perf-lead brief: 60 workspaces, the typed workspace a 4x3 grid with "
                         "6 tabs per pane, 10 workspaces with Chromium pages, 10 printing terminals); every phase runs in it. "
                         "Uses scripts/cmux-next/perf-stress-session.py when present, else the builder here")
parser.add_argument("--sessions", help="comma list of light,stress: one app launch each (default: light, or stress with --stress)")
parser.add_argument("--rounds", type=int, default=3, help="every phase this many times per launch (the noise shows)")
parser.add_argument("--sample", action="store_true", help="/usr/bin/sample the app over each load phase")
parser.add_argument("--sample-idle", action="store_true", help="with --sample: the idle phases too")
parser.add_argument("--gate-p95-ms", type=float)
parser.add_argument("--chat-agent", choices=("mock", "real"), default="mock",
                    help="mock: in-page debug stream; real: ACP fake agent through AgentPaneTransport")
parser.add_argument("--stream", default="6 10 24", help="real agent stream: SECONDS CHUNK_MS CHARS")
parser.add_argument("--ab", help="a tunable key (debug.tunables) to measure off against on: every round runs its surfaces twice, once with the key false and once true, the order alternating per round so drift does not land on one arm. Each run row carries `ab`, and an agent chat row carries the frames the engine drew for its keys (`draw_on_input`), so an arm that reads on but changes nothing is visible as an inert toggle instead of a win")
parser.add_argument("--backdrops", default="default",
                    help="comma list of window backdrops, one launch each: default (the bench's config), opaque "
                         "(Opacity 1), opacity85 (Opacity 0.85, no picture), picture (van-gogh-starry-night at Opacity "
                         "0.85). Each run's session is SESSION/BACKDROP; every measure records the app's and "
                         "WindowServer's CPU over its keys, which is where a see-through terminal's compositing costs")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"typing-{TAG}-")
WORK = os.path.realpath(tempfile.mkdtemp(prefix=f"typing-work-{TAG}-"))
CONFIG = os.path.join(SCRATCH, "cmux.json")
PROBE = os.path.join(OUT, "typing.csv")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1400, 900)
BUSY = "while :; do printf '%s busy line %s %s\\n' $RANDOM $RANDOM $RANDOM; done"
# An agent's spinner title: the tab renames ten times a second, as a working agent's terminal does (one process, no
# fork per frame: a shell loop around `sleep` would spawn ten processes a second per terminal).
TITLE_CHURN = r'''perl -e '$|=1; for(;;){ for $s (qw(a b c d e f g h i j)){ print "\e]0;$s Working on the task\a"; select(undef,undef,undef,0.1) } }' '''.strip()
results = {"tag": TAG, "host": os.uname().nodename, "opts": vars(opts), "log": [], "runs": []}
app = None
SESSION = "light"
ROUND = 0
# The --ab arm being measured (None without --ab): False (the key off) or True (on). ARM is the live-set arm;
# LAUNCH_ARM is the arm this whole launch was started with, for a key read once at startup.
ARM = None
LAUNCH_ARM = None
# This launch's (ok, detail) switch proof for a launch-time --ab key, read once per launch (`launch_switch_once`).
LAUNCH_SWITCH = None
# The mode being measured, when --modes is given: its id, its `native` knobs and what it cannot express here.
MODE = None


# What make_load builds: --busy/--chats by default, a mode's `native` knobs with --modes.
LOADSPEC = {"busy": opts.busy, "chats": opts.chats, "cpu": False}
BURNERS = []


# Keys Chromium (or the app) reads once at startup: a live `debug.tunables set` cannot change them, because the
# process it would change already parsed its command line. Both arms of such a key need their own launch, with the
# value written into the build's own debug-tunables.json before the app starts (`--tunables build` in
# cef-layer-verify.py is the same route). A live set here would leave both arms on the build's default and report
# them as off and on, which is how an inert change measures as a win (cmux#45709).
LAUNCH_TIME_TUNABLES = {"browserPage.noFrameRateLimit"}


def launch_arm_key():
    """--ab's key if it needs a launch per arm, else None."""
    return opts.ab if opts.ab in LAUNCH_TIME_TUNABLES else None


def launch_tunables_path():
    """The override file the bench's own build reads at launch.

    The tag comes off the bundle (`bench_launch.tag_of`), never off `--tag`: `BenchApp` names its state root that
    way too, so a `--tag` that does not match the bundle would write the file one build reads and launch another
    (review F2 on cmux#48152). `--tag` only labels the report."""
    return os.path.join(tag_state_root(bench_tag_of(APP)), "debug-tunables.json")


def write_launch_tunable(key, value):
    """Sets a launch-time key in the build's own override file, read at the next launch. The app must be down: its
    coalesced writer would race this.

    `value=None` removes the key instead of storing a null: the store reads a stored null as a value that is set,
    so writing one leaves the key overridden after the arms are done rather than back on the build's default."""
    path = launch_tunables_path()
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        data = {"version": 1, "values": {}}
    values = data.setdefault("values", {})
    if value is None:
        values.pop(key, None)
    else:
        values[key] = value
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(data, open(path, "w"), indent=2, sort_keys=True)
    return path


def set_arm(arm):
    """Sets --ab's key for one arm. Returns why it could not, else None.

    Only for a key read per use (`browserPage.drawKeysAtOnce` is read per key, so this reaches the open chats). A
    launch-time key never comes here: `run_session` gives each of its arms a launch instead."""
    if opts.ab in LAUNCH_TIME_TUNABLES:
        return (f"{opts.ab} is read once at launch, so a live set cannot change this process; "
                "a launch-time key takes one launch per arm (LAUNCH_TIME_TUNABLES)")
    rpc("debug.tunables", {"action": "activate"})  # a bench build's tunable store is off until asked (debug-settings.md)
    row = rpc("debug.tunables", {"action": "set", "key": opts.ab, "value": arm}) or {}
    if row.get("value") is not arm:
        return f"debug.tunables set {opts.ab}={arm} answered {json.dumps(row)[:200]}"
    # sleep-ok: a rest gap; the key is read per key (nothing to propagate), the gap keeps the set's own work out of
    # the first measured key's frame.
    time.sleep(0.5)
    return None


def reset_arm():
    """--ab's key back to the build's default, so a later launch or surface measures the build as it is.

    A launch-time key is not reset here: this process already parsed its command line, so a live set changes
    nothing in it, and the override file is what the next launch reads (`write_launch_tunable(key, None)` at the
    end of the arms removes it). Sending the set anyway recorded a reset that never happened (review F3 on
    cmux#48152)."""
    if opts.ab and not launch_arm_key():
        rpc("debug.tunables", {"action": "set", "key": opts.ab, "value": None}, timeout=10)


def cpu_share(start, end):
    """App and WindowServer CPU over an interval, in percent of one core (`cpu_seconds` deltas over the wall time).
    None for either when the process could not be read."""
    wall = end[0] - start[0]
    share = lambda i: (round(100.0 * (end[i] - start[i]) / wall, 1)
                       if wall > 0 and end[i] is not None and start[i] is not None else None)
    return {"app": share(1), "window_server": share(2), "seconds": round(wall, 2)}


def frame_timing_validity(phase, streams):
    """Whether this row's frame-start timings (`listener -> frame`) may be compared across phases.

    A key's wait for its frame depends on whether the renderer was already producing frames, so a load phase only
    answers that question if its chat really streams. `--chat-agent real` streams through AgentPaneTransport and the
    daemon; the default `mock` drives the page through an in-page debug RPC, and whether that keeps the renderer
    ticking the same way is **not established** — on one host (cmux20, 120 Hz) the same L1 mode read `listener ->
    frame` p50 1.3 ms under the real transport and 5.2 ms under the mock, which is the whole size of the effect being
    measured (hq#15723). An idle phase needs no stream, so it is always comparable.

    This marks the row rather than refusing to measure: every other number here (paint, presentation, hangs) is
    unaffected, and a reader of the frame-start column needs to know which rows belong in it."""
    if phase == "idle" or not streams:
        return {"valid": True, "load_source": "none", "why": "an idle phase needs no stream to be comparable"}
    if opts.chat_agent == "real":
        return {"valid": True, "load_source": "real_acp_agent_transport",
                "why": "the chat streams through AgentPaneTransport and the daemon"}
    return {"valid": False, "load_source": "mock_stream",
            "why": "mock_stream is not proven to keep the renderer producing frames like the real transport; "
                   "use --chat-agent real for frame-start comparisons (hq#15723)"}


def draw_on_input_frames():
    """Frames the engine drew for keys, per browser, from `debug.cef`'s `tracker` counters.

    The engine reports them flat inside `tracker` (`CEFTrackerStats.reportFields`): `draw_on_input_counter` is 1 when
    the shim answers the per-key count at all, and `draw_on_input.<browser>` is one page's frames. Returns None when
    `draw_on_input_counter` is absent or 0, which is not the same as zero frames: an engine below fork API 35 takes no
    draw-on-input call at all, so an arm that reads on measures the off path (cmux#45709 shipped against a pin at
    API 33)."""
    report = rpc("debug.cef", timeout=20)
    tracker = report.get("tracker") if isinstance(report, dict) else None
    if not isinstance(tracker, dict) or not tracker.get("draw_on_input_counter"):
        return None
    return {k[len("draw_on_input."):]: v for k, v in tracker.items() if k.startswith("draw_on_input.")}


# What a launch-time key's arm must find in `debug.cef`'s `launch_switches` to have measured its own path.
LAUNCH_SWITCH_PROOF = {"browserPage.noFrameRateLimit": ["disable-frame-rate-limit", "disable-gpu-vsync"]}


def launch_switch_proof(key, arm):
    """Whether this launch passed Chromium the switches `key`=`arm` means, read off `debug.cef`.

    `launch_switches` is what `CEFRuntime` recorded where it built the command line, so it answers what the process
    launched with and not what the store holds now. An arm cannot tell its own path from the other one without it:
    writing the override file and reading back a row proves only that the value was stored, and a launch that raced
    the store's load, or a build whose code ignores the key, still reports the value as set. That gap is what
    cmux#45709 shipped. Returns (ok, detail); ok is None when the build is too old to report the field at all."""
    expected = LAUNCH_SWITCH_PROOF.get(key)
    if expected is None:
        return None, {"key": key, "why": "no switch proof known for this key"}
    report = rpc("debug.cef", timeout=20)
    if not isinstance(report, dict) or "launch_switches" not in report:
        return None, {"key": key, "why": "this build's debug.cef reports no launch_switches"}
    got = sorted(report.get("launch_switches") or [])
    want = sorted(expected) if arm else []
    return got == want, {"key": key, "arm": bool(arm), "expected": want, "launched_with": got}


def launch_switch_once():
    """This launch's switch proof, read once and shared by every row of the launch (`LAUNCH_SWITCH`).

    What Chromium was launched with cannot change inside a launch, so one `debug.cef` read answers every row. It
    used to be read per row, which put a 20 s-timeout RPC between a surface's setup and its keys on every row of
    every mode (review F1 on cmux#48152)."""
    global LAUNCH_SWITCH
    if LAUNCH_SWITCH is None:
        LAUNCH_SWITCH = launch_switch_proof(launch_arm_key(), LAUNCH_ARM) if launch_arm_key() else (None, None)
    return LAUNCH_SWITCH


def start_burners():
    """Mode L4's load: one spinning shell per core, each a process of ours, so the app waits its turn for a core as
    it does on a loaded Mac. Only these children are ever signalled."""
    count = opts.cpu_burners or os.cpu_count() or 8
    for _ in range(count):
        BURNERS.append(subprocess.Popen(["/bin/sh", "-c", "while :; do :; done"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    note(f"load: {len(BURNERS)} cpu burners (this host has {os.cpu_count()} cores)")
    return len(BURNERS)


def stop_burners():
    while BURNERS:
        child = BURNERS.pop()
        try:
            child.terminate()
            child.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass


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


def layout_signature():
    """What an action changes: the shown panes (kind, tab, focus, frame) and the windows' first responders."""
    surfaces = rpc("debug.surfaces") or {}
    panes = [(p.get("pane"), p.get("kind"), p.get("selected_tab"), p.get("focused"), json.dumps(p.get("frame")))
             for w in (surfaces.get("windows") or []) if isinstance(w, dict) for p in (w.get("panes") or [])]
    return json.dumps([panes, focus_report()["first_responders"]])


def action(name, args=None, settle=0.0, focus=True, timeout=60):
    """settle (s, the old fixed wait): wait for the action's change to show and the layout to stop changing."""
    before = layout_signature() if settle else None
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": focus, "origin": "script"}, timeout=timeout)
    if settle:
        wait_until(lambda: layout_signature() != before, f"{name} to change the layout", timeout=max(5.0, settle * 4),
                   raise_on_timeout=False)
        wait_stable(layout_signature, f"the layout after {name}", timeout=max(10.0, settle * 6), interval=0.1, reads=4,
                    raise_on_timeout=False)
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


def frame_metrics(frames):
    """Summarize the display and main-thread counters without assuming one DEBUG reply shape."""
    if not isinstance(frames, dict):
        return {"raw": frames, "frames_over_16ms": None, "frame_bursts": None, "main_thread_cost": None}
    intervals = [x for x in (frames.get("intervals_ms") or []) if isinstance(x, (int, float)) and x >= 0]
    main = [x for x in (frames.get("main_ms") or []) if isinstance(x, (int, float)) and x >= 0]
    refresh = frames.get("refresh_ms")
    burst_limit = refresh * 0.5 if isinstance(refresh, (int, float)) and refresh > 0 else 8.33
    burst_runs, current = [], 0
    for interval in intervals:
        if interval <= burst_limit:
            current += 1
        elif current:
            burst_runs.append(current)
            current = 0
    if current:
        burst_runs.append(current)
    return {
        "refresh_ms": refresh,
        "frames": frames.get("frames", len(intervals)),
        "intervals_ms": intervals,
        "frames_over_16ms": sum(interval > 16 for interval in intervals),
        "frame_bursts": {"threshold_ms": burst_limit, "count": len(burst_runs),
                         "max_length": max(burst_runs, default=0), "total_frames": sum(burst_runs)},
        "main_thread_cost": {"samples": len(main), "total_ms": round(sum(main), 2), "distribution": pct(main)},
    }


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


def busy_command():
    """What each busy terminal runs: printed lines, or with --title-churn a spinner title."""
    return TITLE_CHURN if opts.title_churn else BUSY


def make_load(surface_ws):
    """Busy terminals (three split beside the typed surface, the rest in other workspaces) and mock agent chats."""
    if LOAD["made"]:
        return
    LOAD["made"] = True
    if LOADSPEC["cpu"]:
        LOAD["cpu_burners"] = start_burners()
    if SESSION.split("/")[0] == "stress":  # SESSION is SESSION/BACKDROP with --backdrops
        # STRESS has its printing terminals and agent chats already: stream up to this many of its chats.
        listed = rpc("debug.agent_pane", {"action": "engine", "pane": "none"}) or {}
        LOAD["chat_panes"] = (listed.get("agent_panes") or [])[: LOADSPEC["chats"]]
        note(f"load (stress): streaming chats {LOAD['chat_panes']}")
        return
    visible = min(3, LOADSPEC["busy"])
    for _ in range(visible):
        action("splitRight", settle=0.6)
        action("terminal.sendText", {"text": busy_command() + "\r"})
    rest = LOADSPEC["busy"] - visible
    per = 4
    for index in range((rest + per - 1) // per):
        count = min(per, rest - index * per)
        ref = cli("workspace", "create", "--name", f"busy {index}", "--shell", busy_command()).stdout.strip()
        LOAD["workspaces"].append(ref)
        for _ in range(count - 1):
            cli("workspace", ref, "focus")
            action("splitDown", settle=0.4)
            action("terminal.sendText", {"text": busy_command() + "\r"})
    for _ in range(LOADSPEC["chats"]):
        pane, engine = open_agent_chat()
        if pane:
            LOAD["chat_panes"].append(pane)
        note(f"load: agent chat {pane} ({engine})")
    if surface_ws:
        cli("workspace", surface_ws, "focus")
    note(f"load: {LOADSPEC['busy']} busy terminals ({visible} visible), {len(LOAD['chat_panes'])} agent chats")


def chat_streams(panes=None):
    panes = [p for p in (panes if panes is not None else LOAD["chat_panes"]) if p]
    if not panes:
        return None

    replies = LOAD.setdefault("stream_replies", [])

    def step(_):
        for pane in panes:
            if opts.chat_agent == "real":
                reply = rpc("debug.agent_pane", {"action": "send_prompt", "pane": pane,
                                                  "text": f"stream: {opts.stream}"}, timeout=20)
            else:
                reply = rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": 40,
                                                  "seconds": 3, "chunk_ms": 30}, timeout=10)
            if len(replies) < 4 or (isinstance(reply, dict) and reply.get("error")):
                replies.append(json.dumps(reply)[:200])
    period = float(opts.stream.split()[0]) + 0.5 if opts.chat_agent == "real" else 3.0
    return Streamer(step, period)


def agent_expected_text(count):
    """Stable ordinary keys: the report can prove order and exact composer text."""
    letters = "abcdefghijklmnopqrstuvwxyz"
    return "".join(letters[index % len(letters)] for index in range(count))


def agent_typing_verdict(stats, expected, dispatch):
    """Validate page telemetry and join its paint epoch to the native dispatch clock."""
    stats = stats if isinstance(stats, dict) else {}
    samples = stats.get("samples") if isinstance(stats.get("samples"), list) else []
    keys = [sample.get("key") for sample in samples if isinstance(sample, dict)]
    ordered = (len(keys) == len(samples) == len(expected) and all(isinstance(key, str) for key in keys)
               and "".join(keys) == expected)
    exact = stats.get("composer_text") == expected
    finite = bool(samples) and len(samples) == len(expected)

    def good(value):
        return isinstance(value, (int, float)) and math.isfinite(value) and value >= 0
    # frame and paint are the measurement; listener and work only split it into stages. The page's work mark waits
    # for the key's `input` event until the key's frame, so a key whose edit lands after that frame (under load:
    # 1 of 200 in L2 on cmux20-bench, 2026-11-20) has no work stage. Such keys are counted, and a run stays complete.
    stage_missing = {"listener": 0, "work": 0}
    for sample in samples:
        if not isinstance(sample, dict) or not (good(sample.get("frame")) and good(sample.get("paint"))):
            finite = False
            break
        for field in stage_missing:
            stage_missing[field] += not good(sample.get(field))
    paints = [sample["paint"] for sample in samples if isinstance(sample, dict)
              and isinstance(sample.get("paint"), (int, float))]
    paint_distribution = pct(paints)
    after_frame = []
    if len(dispatch) == len(samples):
        for sample, sent in zip(samples, dispatch):
            painted = sample.get("paint_epoch_ms") if isinstance(sample, dict) else None
            if not isinstance(painted, (int, float)) or not isinstance(sent.get("epoch_ms"), (int, float)):
                after_frame = []
                break
            after_frame.append(painted - sent["epoch_ms"])
    joined = len(after_frame) == len(expected) and all(0 <= value < 60000 for value in after_frame)
    after_distribution = pct(after_frame)
    return {
        "complete": finite and ordered and exact and joined,
        "key_order_ok": ordered,
        "text_exact": exact,
        "stage_missing": stage_missing,
        "expected_keys": len(expected),
        "observed_keys": len(samples),
        "key_to_frame_ms": paint_distribution,
        "paint_p50_ms": (paint_distribution or {}).get("p50"),
        "paint_p95_ms": (paint_distribution or {}).get("p95"),
        "paint_p99_ms": (paint_distribution or {}).get("p99"),
        "paint_max_ms": (paint_distribution or {}).get("max"),
        "dispatch_to_after_frame_ms": after_frame,
        "dispatch_to_after_frame": after_distribution,
        "dispatch_to_after_frame_p50_ms": (after_distribution or {}).get("p50"),
        "dispatch_to_after_frame_p95_ms": (after_distribution or {}).get("p95"),
        "dispatch_to_after_frame_p99_ms": (after_distribution or {}).get("p99"),
        "dispatch_to_after_frame_max_ms": (after_distribution or {}).get("max"),
        "renderer_budget_met": bool(finite and ordered and exact and (paint_distribution or {}).get("p95", float("inf")) <= 16
                                     and (paint_distribution or {}).get("p99", float("inf")) <= 33),
    }


def foreground_activation():
    """Bring the already-running tagged app front through LaunchServices and prove NSApp is active."""
    opened = subprocess.run(["open", APP], capture_output=True, text=True, timeout=30)
    focus = wait(lambda: (lambda report: report if report.get("app_active") is True else None)(rpc("debug.focus") or {}),
                 15, step=0.25)
    report = focus or rpc("debug.focus") or {}
    front = str(report.get("front_app") or report.get("frontmost_app") or report.get("application") or "").lower()
    locked = report.get("screen_locked") is True or front == "loginwindow"
    return {"method": "launchservices_open", "returncode": opened.returncode,
            "stderr": opened.stderr.strip()[:200], "app_active": bool(focus), "screen_locked": locked,
            "focus": report}


def open_agent_chat():
    """Open one chat and attach either the in-page fixture or a real ACP harness."""
    reply = action("palette.newAgentChat", settle=1.0, timeout=120)
    wait(lambda: (lambda r: r if r.get("document_ready") else None)(
        rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}), 30, step=0.5)
    engine = rpc("debug.agent_pane", {"action": "engine"}, timeout=10) or {}
    pane = engine.get("pane")
    if pane and opts.chat_agent == "real":
        made = rpc("debug.agent_pane", {"action": "new_chat", "pane": pane, "harness": "fake", "cwd": WORK}, timeout=90)
        # WORK is a new folder: the start waits on the pane's trust ask until someone answers it (every chat of
        # 8372af35's L0-L5 run stayed pending). Answer it as a person does, with a click on Trust; once trusted, the
        # folder asks no later chat.
        trust = None
        if (made or {}).get("pending"):
            trust = wait(lambda: (lambda r: r if r.get("clicked") else None)(
                rpc("debug.agent_pane", {"action": "click", "pane": pane, "selector": ".acpmux-trust-ask-action"},
                    timeout=10) or {}), 10, step=0.5)
        attached = wait(lambda: (lambda state: state if state.get("connection") == "attached" and state.get("sessionId") else None)(
            rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=10) or {}), 40, step=0.5)
        # The chat's state when it never attached (connection, error, pending ask): the report says why its stream
        # could not run, and stream_load_missing names it beside the number.
        last = None if attached else rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=10) or {}
        LOAD.setdefault("attach", {})[pane] = {"attached": bool(attached), "new_chat": made, "trust_clicked": bool(trust),
                                               "state": None if attached else json.dumps(last)[:400]}
        note(f"chat {pane}: new_chat {json.dumps(made)[:160]} attached={bool(attached)}"
             + ("" if attached else f" state {json.dumps(last)[:240]}"))
    elif pane:
        rpc("debug.agent_pane", {"action": "select_session", "pane": pane, "session": "mock-session"}, timeout=30)
    if pane:
        wait(lambda: (lambda r: r if r.get("composer_visible") else None)(
            rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, timeout=5) or {}), 30, step=0.25)
    note(f"chat {pane} ({engine.get('engine')}) {json.dumps(reply)[:120]}")
    return pane, engine.get("engine")


def ensure_agentpane():
    if LOAD.get("agentpane_pane"):
        return LOAD["agentpane_pane"]
    pane, engine_name = open_agent_chat()
    if not pane:
        raise RuntimeError("agent pane did not open")
    LOAD["agentpane_pane"] = pane
    LOAD["agentpane_engine"] = engine_name
    return pane


def measure_agentpane(phase, pid, pane, streams=()):
    """Native agent composer path: exact key samples, page paint epoch, foreground proof and load provenance."""
    global WINDOW_SERVER
    # `--surfaces=agentpane` never runs `measure`, which is where this is otherwise found.
    WINDOW_SERVER = WINDOW_SERVER or window_server_pid()
    activation = foreground_activation()
    if activation.get("screen_locked"):
        entry = {
            "session": SESSION, "surface": "agentpane", "phase": phase, "mode": (MODE or {}).get("id"),
            "mode_missing": (MODE or {}).get("nativeMissing") or [], "pane": pane,
            "engine": LOAD.get("agentpane_engine"), "foreground": activation,
            "error": "screen is locked (front app loginwindow); no typing or ACP measurement attempted",
            "complete": False, "keys": 0, "measured": 0,
        }
        results["runs"].append(entry)
        return entry
    focus_reply = rpc("debug.agent_pane", {"action": "focus_composer", "pane": pane}, timeout=30) or {}
    focus = wait(lambda: (lambda report: report if report.get("app_active") is True else None)(rpc("debug.focus") or {}),
                 10, step=0.25) or (rpc("debug.focus") or {})
    entry = {
        "session": SESSION, "surface": "agentpane", "phase": phase, "mode": (MODE or {}).get("id"),
        "mode_missing": (MODE or {}).get("nativeMissing") or [], "pane": pane,
        "engine": LOAD.get("agentpane_engine"), "foreground": activation, "launch": opts.launch,
        "focus": {"composer": focus_reply, "report": focus, "app_active": focus.get("app_active") is True},
        "capabilities": {
            "typing": "debug.key -> agent page",
            "telemetry": "debug.agent_pane typing_stats (paint_epoch_ms proxy)",
            "foreground_activation": "LaunchServices open + debug.focus.app_active",
            "load_source": ("real_acp_agent_transport" if opts.chat_agent == "real" and streams
                             else "mock_stream" if streams else "none"),
            "daemon_wake": "exercised" if opts.chat_agent == "real" and streams else "not_exercised",
            "three_chat_acceptance": {
                "requested": 3 if MODE is None and phase == "load" else 0,
                "observed": len(LOAD.get("chat_panes") or []) + 1,
                "complete": None if MODE is not None or phase != "load"
                             else len(LOAD.get("chat_panes") or []) + 1 >= 3,
                "status": "legacy acceptance" if MODE is None and phase == "load" else "covered by L0-L5 mode registry",
            },
            "background_wake": {"supported": opts.chat_agent == "real",
                                "status": "exercised" if opts.chat_agent == "real" and streams else "not_exercised",
                                "reason": ("ACP fake agent prompts stream through AgentPaneTransport/AcpmuxPaneSocket"
                                           if opts.chat_agent == "real" else
                                           "canonical L0-L5 path uses mock_stream; use --chat-agent real for daemon traffic")},
        },
    }
    if focus.get("app_active") is not True:
        entry.update({"error": "LaunchServices activation did not produce debug.focus.app_active=true",
                      "complete": False, "keys": 0, "measured": 0})
        results["runs"].append(entry)
        return entry
    for stream in streams:
        stream.start()
    if streams:
        # The streams run before the first key: each has made its first step.
        wait_until(lambda: all(stream.calls >= 1 for stream in streams), "the streams' first step", timeout=30,
                   raise_on_timeout=False)
    target = {"pane": pane}
    if LOAD.get("agentpane_engine") == "cef":
        target["target"] = "page"
    frames_before = draw_on_input_frames()
    # For a launch-time --ab key, what this launch actually passed Chromium: the row carries it so no cell is read
    # as an arm's number before its switch is proven to have landed (`launch_switch_once`, one read per launch).
    switch_ok, switch_detail = launch_switch_once()
    cpu_start = (time.monotonic(), cpu_seconds(pid), cpu_seconds(WINDOW_SERVER))
    stats_before = rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=10) or {}
    before_keys = stats_before.get("keys", 0) if isinstance(stats_before, dict) else 0
    clear_select = rpc("debug.key", dict(target, key="a", modifiers=["command"]), timeout=10)
    clear_delete = rpc("debug.key", dict(target, key="delete"), timeout=10)
    cleared = wait(lambda: (lambda report: report if report.get("composer_text") == "" and
                             report.get("keys", 0) >= before_keys + 2 else None)(
        rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=5) or {}), 5, step=0.2)
    reset = rpc("debug.agent_pane", {"action": "reset_typing", "pane": pane}, timeout=10)
    rpc("debug.hangs", {"clear": True})
    rpc("debug.timings", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    sampler = None
    if opts.sample and phase == "load":
        sample_path = os.path.join(OUT, f"sample-{SESSION}-agentpane-{phase}.txt")
        seconds = max(3, int(opts.samples * opts.interval))
        sampler = (subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-file", sample_path],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), sample_path)
    expected = agent_expected_text(opts.samples)
    dispatch, trips = [], []
    probe = SchedProbe(pid, opts.samples * opts.interval)
    probe.start()
    send_start = time.monotonic()
    for index, key in enumerate(expected):
        deadline = send_start + index * opts.interval
        time.sleep(max(0, deadline - time.monotonic()))
        started = time.monotonic()
        epoch_ms = time.time() * 1000
        reply = rpc("debug.key", dict(target, key=key), timeout=10)
        dispatch.append({"index": index, "key": key, "epoch_ms": epoch_ms,
                         "late_ms": (started - deadline) * 1000,
                         "rpc_ms": (time.monotonic() - started) * 1000, "reply": reply})
        trips.append(dispatch[-1]["rpc_ms"])
    probe.halt.set()
    probe.join(timeout=10)
    typing = wait(lambda: (lambda report: report if report.get("keys", 0) >= len(expected) else None)(
        rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=5) or {}), 15, step=0.25)
    typing = typing or (rpc("debug.agent_pane", {"action": "typing_stats", "pane": pane}, timeout=10) or {})
    if streams:
        for stream in streams:
            stream.stop()
    frames = rpc("debug.frames", {"action": "stop", "raw": True}, timeout=20)
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20)
    main_profile = None
    if sampler:
        try:
            sampler[0].wait(timeout=opts.samples * opts.interval + 60)
        except subprocess.TimeoutExpired:
            sampler[0].terminate()
        try:
            main_profile = digest_sample(open(sampler[1], errors="replace").read())
        except OSError:
            main_profile = {"error": "sample output unavailable", "file": os.path.basename(sampler[1])}
    cpu_end = (time.monotonic(), cpu_seconds(pid), cpu_seconds(WINDOW_SERVER))
    frames_after = draw_on_input_frames()
    verdict = agent_typing_verdict(typing, expected, dispatch)
    frame_report = frame_metrics(frames)
    entry.update({"keys": len(expected), "measured": verdict["observed_keys"], "expected_text": expected,
                  "clear": {"select": clear_select, "delete": clear_delete, "delete_key": "delete",
                            "verified": bool(cleared), "reset": reset},
                  "typing": typing, "dispatch": dispatch, "key_rpc_ms": pct(trips), **verdict,
                  # The app's and WindowServer's CPU over the keys: a frame-pacing arm buys latency with
                  # frames nobody sees, so its cost belongs in the same row as its win (`--ab`).
                  "cpu_percent": cpu_share(cpu_start, cpu_end),
                  "frame_timing": frame_timing_validity(phase, streams),
                  # `counter: false`: this engine has no draw-on-input counter, so the mode cannot be live here
                  # whatever a setting reads, and `drew: 0` with a counter means the mode was off or opted this page out.
                  # `ok: false` means this arm launched without the switches its label claims, so its numbers are
                  # the other arm's; `ok: null` means the build cannot say (too old to report `launch_switches`).
                  "launch_switch": None if switch_detail is None else {"ok": switch_ok, **switch_detail},
                  "draw_on_input": {"counter": frames_after is not None,
                                    "before": frames_before, "after": frames_after,
                                    "drew": None if frames_after is None else
                                            sum(max(0, v - (frames_before or {}).get(k, 0)) for k, v in frames_after.items())},
                  "driver_p95_late_ms": pct([item["late_ms"] for item in dispatch]).get("p95"),
                  "driver_p99_rpc_ms": pct(trips).get("p99"),
                  "frames": frames, "frame_metrics": frame_report, "frames_over_16ms": frame_report.get("frames_over_16ms"),
                  "frame_bursts": frame_report.get("frame_bursts"), "main_thread_cost": frame_report.get("main_thread_cost"),
                  "hangs": hangs,
                  "streams": [stream.calls for stream in streams], "main_profile": main_profile,
                  "sched_probe": probe.snapshots,
                  "complete": bool(verdict["complete"] and cleared)})
    results["runs"].append(entry)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    note(f"{SESSION} agentpane.{phase}: key-to-frame {entry.get('key_to_frame_ms')} dispatch-to-after-frame "
         f"p95={entry.get('dispatch_to_after_frame_p95_ms')} exact={verdict['text_exact']} active={focus.get('app_active')}")
    return entry


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
            wait_until(lambda: zsh_prompt(tab["id"]), "zsh -f's prompt in the stress pane", timeout=15,
                       raise_on_timeout=False)
        LOAD["stress_pane"] = last["id"]
    return ws


def workspaces():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    return topo.get("workspaces") or []


# ---------------------------------------------------------------- typing
SENTENCE = "the chief reads your note and starts on the work in a new workspace "


def type_keys(count, params, column):
    keys = SENTENCE if opts.words else "abcdefghijklmnopqrstuvwxyz"
    rows_before = len(probe_rows())
    trips = []
    for index in range(count):
        t0 = time.perf_counter()
        key = keys[index % len(keys)]
        reply = rpc("debug.key", dict(params, key="space" if key == " " else key, timestamp=time.clock_gettime(time.CLOCK_UPTIME_RAW)),
                    timeout=10)
        trips.append((time.perf_counter() - t0) * 1000)
        if isinstance(reply, dict) and reply.get("error"):
            note(f"key {index}: {reply.get('error')}")
        rest = opts.interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    # The last frame lands: a complete probe row for every key typed.
    wait_until(lambda: sum(1 for r in probe_rows()[rows_before:] if r.get("complete") == "1" and r.get(column)) >= count,
               "a probe row for the last key", timeout=5, raise_on_timeout=False)
    rows = [r for r in probe_rows()[rows_before:] if r.get("complete") == "1" and r.get(column)]
    return rows, trips


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


BACKDROPS = {"default": {}, "opaque": {"backgroundOpacity": 1}, "opacity85": {"backgroundOpacity": 0.85},
             "picture": {"background": "van-gogh-starry-night", "backgroundOpacity": 0.85}}
WINDOW_SERVER = None


def cpu_seconds(pid):
    """A process's user+system CPU time in seconds (`ps -o cputime`, any user's process), or None."""
    if not pid:
        return None
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = [float(x) for x in out.replace("-", ":").split(":")]
    total = 0.0
    for x in parts:
        total = total * 60 + x
    return total


class SchedProbe(threading.Thread):
    """Scheduler state while keys are typed: `ps -M` (one row per thread with its scheduler priority PRI and CPU
    times) of the app, each Chromium helper it started (renderer, GPU, utility) and one CPU burner, at `points`
    evenly spaced through the typing window. Read-only; signals nothing."""

    def __init__(self, pid, seconds, points=4):
        super().__init__(daemon=True)
        self.pid, self.seconds, self.points = pid, seconds, points
        self.snapshots = []
        self.halt = threading.Event()

    def helpers(self):
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3 or not parts[0].isdigit() or parts[1] != str(self.pid):
                continue
            command = parts[2]
            kind = re.search(r"--type=([\w-]+)", command)
            found.append({"pid": int(parts[0]), "kind": kind.group(1) if kind else "other",
                          "helper": " Helper" in command, "command": command[:400]})
        return found

    def snapshot(self, index):
        children = self.helpers()
        pids = [self.pid] + [child["pid"] for child in children if child["helper"]]
        if BURNERS:
            pids.append(BURNERS[0].pid)
        # Where a scheduling clamp would come from: this harness and its parent (the fleet worker's step tree), and
        # two apps LaunchServices started on this host, for reference.
        reference = {"harness": os.getpid(), "harness_parent": os.getppid()}
        for name in ("Finder", "Dock"):
            found = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
            if found:
                reference[name] = int(found[0])
        pids += [pid for pid in reference.values() if pid not in pids]
        threads = subprocess.run(["ps", "-M", "-p", ",".join(str(p) for p in pids)],
                                 capture_output=True, text=True).stdout
        load = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
        front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
        front_info = subprocess.run(["lsappinfo", "info", "-only", "pid", front], capture_output=True,
                                    text=True).stdout.strip() if front else ""
        self.snapshots.append({"index": index, "t": time.time(), "app_pid": self.pid, "launch": opts.launch,
                               "burner_pid": BURNERS[0].pid if BURNERS else None, "loadavg": load,
                               "reference_pids": reference, "front_app": front, "front_app_pid": front_info,
                               "children": children, "ps_M": threads})

    def run(self):
        step = self.seconds / (self.points + 1)
        for index in range(self.points):
            if self.halt.wait(step):
                return
            try:
                self.snapshot(index)
            except Exception as error:  # the probe must never end a run
                self.snapshots.append({"index": index, "error": repr(error)})


def window_server_pid():
    out = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def measure(surface, phase, params, column, pid, streams=()):
    global WINDOW_SERVER
    WINDOW_SERVER = WINDOW_SERVER or window_server_pid()
    rpc("debug.hangs", {"clear": True})
    rpc("debug.timings", {"clear": True})
    rows_before = len(probe_rows())
    rpc("debug.frames", {"action": "start"})
    for s in streams:
        s.start()
    sampler = None
    if opts.sample and (phase == "load" or opts.sample_idle):
        path = os.path.join(OUT, f"sample-{SESSION}-{surface}-{phase}.txt")
        seconds = max(3, int(opts.samples * opts.interval))
        sampler = (subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "1", "-file", path],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), path)
    if streams:
        # The streams run before the first key: each has made its first step.
        wait_until(lambda: all(stream.calls >= 1 for stream in streams), "the streams' first step", timeout=30,
                   raise_on_timeout=False)
    # debug.view_churn (which views ask for display or layout while the keys are typed) exists only in a probe
    # build (scratch branch pl-typing-view-churn, never landed: a DEBUG swizzle of NSView); elsewhere this records the error.
    rpc("debug.view_churn", {"action": "start"})
    cpu_start = (time.monotonic(), cpu_seconds(pid), cpu_seconds(WINDOW_SERVER))
    rows, trips = type_keys(opts.samples, params, column)
    cpu_end = (time.monotonic(), cpu_seconds(pid), cpu_seconds(WINDOW_SERVER))
    wall = cpu_end[0] - cpu_start[0]
    share = lambda i: (round(100.0 * (cpu_end[i] - cpu_start[i]) / wall, 1)
                       if wall > 0 and cpu_end[i] is not None and cpu_start[i] is not None else None)
    churn = rpc("debug.view_churn", {"action": "stop", "limit": 15}, timeout=20)
    for s in streams:
        s.stop()
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    timings = rpc("debug.timings", timeout=20) or {}
    publishes = [p.get("ms") for p in (timings.get("control_publishes") or []) if isinstance(p, dict)]
    every = probe_rows()[rows_before:]
    marks = ["dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms", "output_decoded_ms",
             "output_received_ms", "output_parsed_ms", "contents_ms", "commit_ms"]
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20)
    display_metrics = frame_metrics(frames)
    f = lambda key: [float(r[key]) for r in rows if r.get(key)]
    entry = {
        "session": SESSION, "surface": surface, "phase": phase, "keys": len(trips), "measured": len(rows),
        # Only with --modes, so a report from the --phases path stays the rows bench_ab already compares.
        "mode": (MODE or {}).get("id"),
        "mode_missing": (MODE or {}).get("nativeMissing") or [],
        "cpu_burners": LOAD.get("cpu_burners", 0),
        "key_to_frame_ms": pct(f(column)), "column": column,
        # Every measured key's value, so a reader pools the rounds (the perf cron's terminal.key_to_echo rows).
        "key_to_frame_values": [round(v, 3) for v in f(column)],
        "send_to_dispatch_ms": pct(f("dispatch_start_ms")),
        "dispatch_ms": pct([float(r["dispatch_end_ms"]) - float(r["dispatch_start_ms"]) for r in rows
                            if r.get("dispatch_end_ms") and r.get("dispatch_start_ms")]),
        "dispatch_to_frame_ms": pct([float(r[column]) - float(r["dispatch_end_ms"]) for r in rows if r.get("dispatch_end_ms")]),
        "key_rpc_ms": pct(trips),
        "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms")}
        if isinstance(hangs, dict) else hangs,
        "hang_records": (hangs or {}).get("records") if isinstance(hangs, dict) else None,
        "frames": frames, "frame_metrics": display_metrics, "frames_over_16ms": display_metrics.get("frames_over_16ms"),
        "frame_bursts": display_metrics.get("frame_bursts"), "main_thread_cost": display_metrics.get("main_thread_cost"),
        "streams": [s.calls for s in streams],
        "round": ROUND, "focus": LOAD.get("focus"),
        "view_churn": churn, "control_publishes": {"count": len(publishes), "ms": pct(publishes),
                                                   "total_ms": round(sum(publishes), 1)},
        "probe_rows": {"all": len(every), "complete": sum(r.get("complete") == "1" for r in every),
                       "marks": {m: sum(bool(r.get(m)) for r in every) for m in marks}},
        "stream_replies": LOAD.get("stream_replies", [])[:4],
        "cpu_pct": {"app": share(1), "window_server": share(2), "seconds": round(wall, 2)},
    }
    if sampler:
        try:
            sampler[0].wait(timeout=opts.samples * opts.interval + 60)
        except subprocess.TimeoutExpired:
            sampler[0].terminate()
        entry["sample"] = os.path.basename(sampler[1])
        try:
            # The report is the fleet step's one artifact: keep the main thread's digest in it.
            entry["main_profile"] = digest_sample(open(sampler[1], errors="replace").read())
        except OSError:
            pass
    k = entry["key_to_frame_ms"] or {}
    note(f"{SESSION} {surface}.{phase}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
         f"(n={k.get('n')}/{len(trips)}); hangs {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}; "
         f"cpu app {entry['cpu_pct']['app']}% WindowServer {entry['cpu_pct']['window_server']}%; "
         f"frames {json.dumps({x: (frames or {}).get(x) for x in ('missed', 'max_ms', 'p99_ms')} if isinstance(frames, dict) else frames)}")
    results["runs"].append(entry)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    return entry


def surface_panes():
    surfaces = rpc("debug.surfaces", {"text": True}) or {}
    return [p for w in (surfaces.get("windows") or []) if isinstance(w, dict) for p in (w.get("panes") or [])]


def zsh_prompt(tab):
    """The pane showing `tab` ends in a `zsh -f` prompt (`host% `)."""
    for pane in surface_panes():
        if pane.get("selected_tab") == tab:
            lines = [line for line in (pane.get("text") or (pane.get("surface") or {}).get("text") or "").splitlines() if line.strip()]
            return bool(lines) and lines[-1].rstrip().endswith(("%", "#"))
    return False


def workspace_shown(ws):
    """A pane on screen shows one of workspace `ws`'s tabs (snapshot.get vs debug.surfaces)."""
    tabs = {t.get("id") for w in workspaces() if w.get("id") == ws for sc in w.get("screens") or []
            for p in sc.get("panes") or [] for t in p.get("tabs") or []}
    return bool(tabs & {p.get("selected_tab") for p in surface_panes()})


def named_workspace(name):
    """The id of the workspace named `name`, and its panes (snapshot.get)."""
    for w in workspaces():
        if (w.get("name") or w.get("title")) == name:
            panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
            return w.get("id"), panes
    return None, []


def focus_terminal(tries=5):
    """Shows the typed terminal's workspace and gives its pane the keyboard; returns what has it (debug.focus).

    Tries again while no terminal is the first responder (an agent chat the load just opened can keep the window's
    keyboard): a measure with the keys going nowhere records no probe rows, which read as a missing number, not a slow
    one. The report keeps `tries` and `terminal_focused`."""
    ws, pane = LOAD["terminal_ws"], LOAD.get("stress_pane") or LOAD.get("terminal_pane")
    report = {}
    for attempt in range(1, tries + 1):
        went = rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": ws}, "focus": True, "origin": "script"})
        focus = rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane}", "focus": True, "origin": "script"}) if pane else None
        time.sleep(0.5)  # focus settles
        report = focus_report()
        focused = any("TerminalSurfaceView" in str(r) for r in report["first_responders"])
        if focused:
            break
        note(f"{SESSION}: focus try {attempt}: no terminal has the keyboard ({report['first_responders']})")
        if attempt == 1:
            # What the app says it did and has: the whole debug.focus report, the two replies, the shown workspace.
            results.setdefault("focus_failures", []).append({
                "session": SESSION, "round": ROUND, "workspace": ws, "pane": pane,
                "goToWorkspace": went, "pane_focus": focus, "debug_focus": rpc("debug.focus")})
    return dict(report, tries=attempt, terminal_focused=focused)


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
        tab = next((t.get("id") for p in panes for t in p.get("tabs") or [] if t.get("kind") == "terminal"), None)
        if tab:
            wait_until(lambda: zsh_prompt(tab), "zsh -f's prompt in the typing workspace", timeout=20,
                       raise_on_timeout=False)
    streams = []
    if phase == "load":
        make_load(LOAD["terminal_ws"])
        s = chat_streams()
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
        wait_until(lambda: workspace_shown(ws), "the home typing workspace shows", timeout=10, raise_on_timeout=False)
        opened = rpc("debug.home_native_fixture.open", {"new": True})
        note(f"home fixture in {ws}: {json.dumps(opened)[:160]}")
        # The transcript lays out: the composer reports its geometry, then it and the rows stop changing.
        wait_until(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), "the Home fixture's composer",
                   timeout=20, raise_on_timeout=False)
        wait_stable(lambda: (rpc("debug.home.drive", {"action": "geometry"}), rpc("debug.home.drive", {"action": "rows"})),
                    "the Home fixture's transcript layout", timeout=20, interval=0.1, reads=5, raise_on_timeout=False)
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": LOAD["home_ws"]}, "focus": True, "origin": "script"})
    wait_until(lambda: workspace_shown(LOAD["home_ws"]), "the home typing workspace shows", timeout=10, raise_on_timeout=False)
    if phase == "load":
        make_load(None)
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"home: no composer to focus ({json.dumps(focused)[:160]})")
        return None
    empty_draft()
    streams = [home_stream()] if phase == "load" else []
    if phase == "load":
        s = chat_streams()
        if s:
            streams.append(s)
    LOAD["focus"] = focus_report()
    entry = measure("home", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.home.drive", {"action": "stream", "text": "done", "done": True})
    return entry


def empty_draft():
    """With --fresh-draft: the focused Home composer's draft is emptied through its own keys (Cmd-A, Delete)."""
    if opts.fresh_draft:
        rpc("debug.key", {"key": "a", "modifiers": ["cmd"]})
        rpc("debug.key", {"key": "delete"})
        if opts.prefill:
            text = (SENTENCE * (opts.prefill // len(SENTENCE) + 1))[: opts.prefill]
            rpc("debug.home.drive", {"action": "type", "text": text})
        # The emptied (or filled) field lays out before the first measured key: its geometry stops changing.
        wait_stable(lambda: rpc("debug.home.drive", {"action": "geometry"}), "the Home composer's layout", timeout=10,
                    interval=0.05, reads=4, raise_on_timeout=False)


def surface_dock(phase, pid):
    # The docked Home the app opened at launch: the home workspace's page.
    homes = rpc("debug.home") or {}
    if phase == "load":
        make_load(None)
    action("home.show", settle=1.5)
    focused = rpc("debug.home.drive", {"action": "focus"})
    if not (isinstance(focused, dict) and focused.get("ok")):
        note(f"dock: no Home composer to focus ({json.dumps(focused)[:160]}; debug.home {json.dumps(homes)[:200]})")
        return None
    empty_draft()
    return measure("dock", phase, {"probe": "commit"}, "commit_ms", pid, [])


def surface_omnibar(phase, pid):
    if phase == "load":
        make_load(None)
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
        s = chat_streams()
        streams = [s] if s else []
    LOAD["focus"] = focus_report()
    entry = measure("omnibar", phase, {"probe": "commit"}, "commit_ms", pid, streams)
    rpc("debug.key", {"key": "escape"})
    return entry


def seed_transcript(pane, rows):
    """The mode's god chat: ROWS synthetic rows put into the focused chat's transcript (debug.agent_pane seed_rows,
    the page's replaceRows), once per launch, before its stream starts; the real agent's stream then lands after
    them. The rows are the page's (the daemon's log keeps the real turns): the page is where a long transcript
    costs a key. What it did, or None when the mode wants no rows."""
    if not rows:
        return None
    if LOAD.get("seed", {}).get("pane") == pane:
        return LOAD["seed"]
    started = time.time()
    reply = rpc("debug.agent_pane", {"action": "seed_rows", "pane": pane, "count": rows}, timeout=120) or {}
    seeded = reply.get("rows") if isinstance(reply.get("rows"), int) else 0
    LOAD["seed"] = {"pane": pane, "requested": rows, "rows": seeded, "commit_ms": reply.get("commit_ms"),
                    "seconds": round(time.time() - started, 1), "error": reply.get("error")}
    note(f"seed {pane}: {json.dumps(LOAD['seed'])[:200]}")
    return LOAD["seed"]


# The page's synthetic transcript is whole turns of a prompt, a reply and a turn summary (webviews
# src/agent-session/acpmux/synthetic.ts), so a 100,000-row ask seeds 99,999.
SEED_TURN_ROWS = 3


def seed_short(seed):
    """Whether SEED put fewer rows into the chat than the mode asks for, past the last partial turn."""
    return seed["rows"] <= seed["requested"] - SEED_TURN_ROWS


def stream_load_missing(panes, attach=None):
    """With the real agent, a chat that never attached has no session to prompt, so its stream never ran: the load
    is not the mode's. A line naming how many of the streaming chats that is, or None when every one attached (or
    the mock agent streams, which needs no session)."""
    if opts.chat_agent != "real" or not panes:
        return None
    attach = LOAD.get("attach", {}) if attach is None else attach
    dead = [p for p in panes if not (attach.get(p) or {}).get("attached")]
    if not dead:
        return None
    return f"{len(dead)} of {len(panes)} streaming chats never attached to the agent, so their streams never ran"


def surface_agentpane(phase, pid):
    pane = ensure_agentpane()
    seed = seed_transcript(pane, ((MODE or {}).get("native") or {}).get("rows") or 0)
    streams, source = [], []
    if phase == "load":
        make_load(None)
        mode_id = (MODE or {}).get("id")
        # L1/L3 type into the focused chat while it streams; L2 adds the ten background chats;
        # L5 combines both. The legacy --phases path preserves its existing mock-chat load.
        source.clear()
        if mode_id in ("L1", "L3", "L5"):
            source.append(pane)
        if mode_id in ("L2", "L5"):
            source.extend(LOAD.get("chat_panes") or [])
        if not mode_id:
            source.extend(LOAD.get("chat_panes") or [])
        stream = chat_streams(source)
        if stream:
            streams.append(stream)
    entry = measure_agentpane(phase, pid, pane, streams)
    missing = stream_load_missing(source)
    if missing:
        entry["mode_missing"] = [*(entry.get("mode_missing") or []), missing]
        entry["attach"] = {p: LOAD.get("attach", {}).get(p) for p in source}
    if seed is not None:
        entry["transcript_seed"] = seed
        if seed_short(seed):
            # Fewer rows than the mode asks for is not that mode: say so beside the number.
            entry["mode_missing"] = [*(entry.get("mode_missing") or []),
                                     f"the {seed['requested']}-row chat transcript (seeded {seed['rows']})"]
    return entry


SURFACES = {"terminal": surface_terminal, "home": surface_home, "dock": surface_dock,
            "omnibar": surface_omnibar, "agentpane": surface_agentpane}


def run_session(session, phases=None, backdrop="default"):
    """One launch of the app (scripts/cmux-next/bench_launch.py): the light session, or STRESS (built first); every
    surface and phase in it (`phases`, default --phases), --rounds times, with the window's `backdrop` (BACKDROPS)."""
    global app, SESSION, SOCKET, CONFIG, LAUNCH_SWITCH
    SESSION = session if backdrop == "default" else f"{session}/{backdrop}"
    LAUNCH_SWITCH = None  # one switch proof per launch, read by the first row of this one
    LOAD.clear()
    LOAD.update({"made": False, "workspaces": [], "chat_panes": []})
    env = {"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
    if opts.chat_agent == "real":
        env.update(CMUX_NEXT_AGENT_PANE_MOCK=None, ACPMUX_AGENT_LAUNCH=None)
    config = {"browser": {"defaultEngine": "chromium"}}
    if BACKDROPS[backdrop]:
        config["appearance"] = BACKDROPS[backdrop]
    bench = BenchApp(APP, out=OUT, config=config, window=WINDOW,
                     log_name=f"app-{SESSION.replace('/', '-')}.log",
                     env=env, launch=opts.launch)
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            note(f"{session}: the app did not come up: {error.reason}")
            results.setdefault("launch_failures", []).append({"session": session, "reason": error.reason,
                                                              "detail": error.report.get("detail")})
            return
        app, SOCKET, CONFIG = bench.process, bench.socket, os.path.join(bench.scratch, "cmux.json")
        initial_focus = rpc("debug.focus") or {}
        front = str(initial_focus.get("front_app") or initial_focus.get("frontmost_app") or initial_focus.get("application") or "").lower()
        if initial_focus.get("screen_locked") is True or front == "loginwindow":
            note(f"{session}: screen is locked (front app {front or 'unknown'}); aborting GUI measurements")
            results.setdefault("launch_failures", []).append({"session": session, "reason": "screen_locked",
                                                               "detail": initial_focus})
            return
        if opts.chat_agent == "real":
            added = action("agent.harness.add", {"id": "fake", "name": "Fake", "command": sys.executable,
                                                 "args": f"{shlex.quote(os.path.abspath(__file__))} --agent",
                                                 "protocol": "acp", "replace": "true"}, timeout=30)
            results["harness_add"] = added
            note(f"harness add: {json.dumps(added)[:300]}")
        if session == "stress":
            LOAD["terminal_ws"] = build_stress()
            # The grid settles: the topology and the shown layout stop changing.
            wait_stable(lambda: (json.dumps(workspaces(), sort_keys=True), layout_signature()), "the STRESS grid",
                        timeout=60, interval=0.5, reads=4, raise_on_timeout=False)
        surfaces = opts.surfaces.split(",")
        global ROUND, ARM
        # Every idle round before the first load round: the load (busy terminals, chats) runs until the app quits,
        # so an idle round after a load round would measure under load.
        for phase in (phases or opts.phases.split(",")):
            for ROUND in range(opts.rounds):
                # With --ab, both arms in the same round, the order alternating: a drift over the launch (thermals, a
                # warming cache) then falls on both arms, not on whichever one ran second.
                arms = ([None] if not opts.ab or launch_arm_key()
                        else [False, True] if ROUND % 2 == 0 else [True, False])
                for ARM in arms:
                    if ARM is not None:
                        problem = set_arm(ARM)
                        if problem:
                            note(f"{session} round {ROUND} arm {opts.ab}={ARM}: {problem}")
                            results.setdefault("ab_problems", []).append(
                                {"session": session, "phase": phase, "round": ROUND, "arm": ARM, "problem": problem})
                            continue
                    for surface in surfaces:
                        if surface == "dock" and phase != "idle" and not opts.dock_load:
                            continue
                        first = len(results["runs"])
                        try:
                            SURFACES[surface](phase, app.pid)
                        except Exception as error:  # one surface failing must not hide the others
                            note(f"{session} {surface}.{phase}: failed: {error!r}")
                        if opts.ab:
                            arm = LAUNCH_ARM if launch_arm_key() else ARM
                            for row in results["runs"][first:]:
                                row["ab"] = {"key": opts.ab, "arm": arm, "round": ROUND,
                                             "route": "launch" if launch_arm_key() else "live"}
                ARM = None
        reset_arm()
    finally:
        bench.stop()
        stop_burners()


def main():
    results["refresh_hz"] = refresh_hz()
    results["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    global MODE, LAUNCH_ARM
    sessions = opts.sessions.split(",") if opts.sessions else (["stress"] if opts.stress else ["light"])
    try:
        if opts.modes:
            # One launch per mode, its knobs from the registry. L0 is the idle phase; every other mode is the load
            # phase with the mode's own load.
            try:
                wanted = load_modes.load(opts.modes)
            except KeyError as error:
                sys.exit(str(error))
            for index, mode in enumerate(wanted):
                MODE = mode
                native = mode["native"]
                LOADSPEC.update({"busy": native["busyTerminals"], "chats": native["chats"],
                                 "cpu": bool(native["cpuSaturation"])})
                missing = mode.get("nativeMissing") or []
                note(f"mode {mode['id']} ({mode['label']}): {mode['what']}; session {native['session']}, "
                     f"{native['chats']} chats, {native['busyTerminals']} busy terminals, "
                     f"cpu saturation {bool(native['cpuSaturation'])}"
                     + (f"; not expressed here: {'; '.join(missing)}" if missing else ""))
                phase = "idle" if mode["id"] == "L0" else "load"
                for backdrop in opts.backdrops.split(","):
                    # A launch-time --ab key cannot be set in a running app, so each arm gets its own launch, the
                    # order alternating per mode so a drift over the run does not land on one arm.
                    if launch_arm_key():
                        order = [False, True] if index % 2 == 0 else [True, False]
                        for arm in order:
                            LAUNCH_ARM = arm
                            path = write_launch_tunable(opts.ab, arm)
                            note(f"mode {mode['id']} arm {opts.ab}={arm}: wrote {path} for the next launch")
                            run_session(native["session"], [phase], backdrop)
                        LAUNCH_ARM = None
                        write_launch_tunable(opts.ab, None)
                    else:
                        run_session(native["session"], [phase], backdrop)
            MODE = None
        else:
            for index, session in enumerate(sessions):
                for backdrop in opts.backdrops.split(","):
                    # As in the --modes path: a launch-time --ab key cannot be set in a running app, so each arm
                    # gets its own launch, the order alternating per session. Without this the sessions path ran one
                    # launch at the build's default and labelled its rows off and on, which is the inert-toggle trap
                    # this harness exists to catch (cmux#45709; review F3 on cmux#48152).
                    if launch_arm_key():
                        order = [False, True] if index % 2 == 0 else [True, False]
                        for arm in order:
                            LAUNCH_ARM = arm
                            path = write_launch_tunable(opts.ab, arm)
                            note(f"session {session} arm {opts.ab}={arm}: wrote {path} for the next launch")
                            run_session(session, backdrop=backdrop)
                        LAUNCH_ARM = None
                        write_launch_tunable(opts.ab, None)
                    else:
                        run_session(session, backdrop=backdrop)
    finally:
        summary = {}
        for r in results["runs"]:
            key = (f"{r['mode']}.{r['surface']}" if r.get("mode")
                   else f"{r['session']}.{r['surface']}.{r['phase']}")
            if r.get("ab"):
                key = f"{key}.{opts.ab}={r['ab'].get('arm')}"
            summary.setdefault(key, []).append((r.get("key_to_frame_ms") or {}).get("p95"))
        results["summary_p95_ms"] = summary
        note(f"summary p95 ms: {json.dumps(summary)} refresh {results.get('refresh_hz')}")
        # Keep a terminal report even when a surface fails before it has latency rows. This is the
        # evidence artifact for screen-lock, focus and transport failures; it must not disappear.
        if opts.json:
            json.dump(results, open(opts.json, "w"), indent=1)
    if opts.gate_p95_ms is not None:
        over = {k: v for k, v in results["summary_p95_ms"].items() if any(x is not None and x > opts.gate_p95_ms for x in v)}
        if over or not results["summary_p95_ms"]:
            print(f"FAIL key-to-frame p95 over {opts.gate_p95_ms} ms: {over or 'nothing measured'}", flush=True)
            sys.exit(1)
        print(f"PASS key-to-frame p95 within {opts.gate_p95_ms} ms", flush=True)


if __name__ == "__main__":
    main()
