#!/usr/bin/env python3
"""The agent chat in WebKit against Chromium (the `agent.chromium` Debug toggle spike).

Launches a tagged DEBUG app once per mode, with the mock agent host, and measures the chat on the
shared page host (the pane's own WebKit host is gone):
  webkit    the page host in WebKit (`agent.chromium` off)
  chromium  the page host in Chromium (`agent.chromium`, `browser.defaultEngine: chromium`)

Per mode: the engine that showed the chat (`debug.agent_pane engine`); time from the open action to
the first text and to a visible composer, for the first chat and for each of `--chats` more; memory
(physical footprint of the app, its Chromium helpers and the WebKit processes it is responsible
for, bench_memory.py) at launch, with one chat and with `--chats`; flings over 5000 seeded rows; and
typing latency in the composer (keydown to the next frame and to its paint, the page's own
typingStats) for `--keys` keys sent with `debug.key`. With `--activate` the app runs active and the
report adds which window holds the keys once the chat is focused (a Chromium page is its own child
window). Each mode launches through bench_launch.BenchApp (the bench env, a fresh saved session, the tag's
teardown at the end). Runs on a fleet mini, never a laptop:
  agent-engine-bench.py --app BUNDLE [--tag TAG] [--modes webkit,chromium] [--chats 10] [--json FILE]

With --story (one mode only; agent-engine is chromium, agent-engine-webkit is webkit) the run also writes
cmux-perf-result/v1 into --out through BenchApp.record (agent_bench_report.py): each chat's content and
interactive ms, the session's composer, each composer key's time to the next frame and to its paint (the page's
`typing_stats raw`), every fling frame and each fling's dropped frames, the footprint at each stage, and the chats
that showed in another engine (their samples never enter the story's series).
"""
import argparse, json, os, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_bench_report as bench_report  # noqa: E402
import bench_memory  # noqa: E402
from bench_launch import BenchApp, LaunchError, bundle_id, rpc_at, tag_of  # noqa: E402
from bench_story import story_problem  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="the bundle's tag (default: read from --app)")
parser.add_argument("--app", required=True)
parser.add_argument("--modes", default="webkit,chromium")
parser.add_argument("--chats", type=int, default=10)
parser.add_argument("--keys", type=int, default=40)
parser.add_argument("--flings", type=int, default=3)
parser.add_argument("--settle", type=float, default=10)
parser.add_argument("--activate", action="store_true", help="run the app active, to see which window takes the keys")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
parser.add_argument("--story", help="write result-v1 under this stories.d story (one mode, of the story's engine)")
parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
parser.add_argument("--build-config", choices=["bench", "bench-checks"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it")
parser.add_argument("--shots", help="a folder: light and dark screen captures of the open session in each mode, with the window glass on")
opts = parser.parse_args()
APP = os.path.realpath(opts.app.rstrip("/"))
TAG = opts.tag or tag_of(APP)
MODES = opts.modes.split(",")
if opts.story:
    if len(MODES) != 1:
        parser.error("--story records one engine: pass one mode with --modes")
    problem = story_problem(opts.story, MODES[0])
    if problem:
        parser.error(problem)
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"  # the launched app's socket once BenchApp has started it
TUNABLES = {"webkit": {"agent.chromium": False}, "chromium": {"agent.chromium": True}}
bench = None  # the BenchApp of the running mode


def rpc(method, params=None, timeout=30):
    """The result, or {"error": ...} (bench_launch.rpc_at)."""
    return rpc_at(SOCKET, method, params, timeout)


def pane(action, timeout=30, **params):
    return rpc("debug.agent_pane", dict(params, action=action), timeout=timeout) or {}


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def open_chat():
    """Opens a chat; ms from the action to the first text and to a visible composer, and its engine."""
    start = time.monotonic()
    reply = rpc("action.run", {"action": "palette.newAgentChat"})
    error = reply.get("error") if isinstance(reply, dict) else None
    # The socket answers after about 2 s; an action still running then goes on, so wait for the page.
    if error and not (isinstance(error, dict) and (error.get("data") or {}).get("state") == "in_progress"):
        return {"error": error}
    content = interactive = None
    deadline = start + 30
    while time.monotonic() < deadline and interactive is None:
        ready = pane("readiness", timeout=5)
        now = round((time.monotonic() - start) * 1000, 1)
        if content is None and (ready.get("body_text_length") or 0) > 0:
            content = now
        if ready.get("composer_visible") and ready.get("document_ready"):
            interactive = now
        time.sleep(0.02)  # test harness: poll the page about once a frame
    return {"content_ms": content, "interactive_ms": interactive, "engine": pane("engine").get("engine")}


def memory(label, chats):
    got = bench_memory.sample(bench.process.pid, APP, label, chats)
    return {"total_footprint_mb": got["total_footprint_mb"], "total_footprint_bytes": got["total_footprint_bytes"],
            "kinds": got["kinds"]}


def open_session():
    """A fresh chat shows the start screen, not the composer: ms from opening a mock session to its composer."""
    start = time.monotonic()
    pane("select_session", session="mock-session")
    ready = wait(lambda: (lambda r: r if r.get("composer_visible") else None)(pane("readiness", timeout=5)), 30, step=0.02)
    return {"composer_ms": round((time.monotonic() - start) * 1000, 1) if ready else None,
            "transcript_rows": (ready or {}).get("transcript_rows")}


def typing():
    pane("reset_typing")
    focused = pane("focus_composer").get("focused")
    # The chat's pane, not the focused one: keys for a Chromium page go to that pane's page window.
    target = {"target": "page", "pane": pane("engine").get("pane")} if pane("engine").get("engine") == "cef" else {}
    letters = "abcdefghijklmnopqrstuvwxyz"
    replies = []
    for index in range(opts.keys):
        replies.append(rpc("debug.key", dict(target, key=letters[index % len(letters)])))
        time.sleep(0.08)  # test harness: about a fast typist's pace
    time.sleep(0.5)  # test harness: the last key's frame lands
    errors = [r.get("error") for r in replies if isinstance(r, dict) and r.get("error")]
    stats = pane("typing_stats", raw=True)
    # Every key's times go to result-v1 as two flat lists; the report keeps the page's summary keys.
    samples = {f"{key}_samples_ms": bench_report.frame_samples(stats, f"{key}_ms") for key in ("to_frame", "to_paint")}
    stats.pop("samples", None)
    return {"composer_focused": focused, "first_key_reply": replies[0] if replies else None, "key_errors": len(errors),
            "composer_text_length": pane("readiness").get("composer_text_length"), **stats, **samples}


def fling():
    """One 3 s fling over the seeded transcript (the page's flingStats), with each of its frame intervals
    (`frames_ms`, from the page's per-frame samples, which the fling reset at its start; none when the fling
    failed or the read is not this fling's: bench_report.run_frames)."""
    stats = pane("fling", seconds=3, wait=True, timeout=60)
    frames = pane("perf_stats", raw=True, timeout=30) if "error" not in stats else {}
    stats["frames_ms"] = bench_report.frame_samples(bench_report.run_frames(stats, frames))
    return stats


def screen_shots(mode):
    """The screen with the chat's session open, light then dark: the screen, not the app's own snapshot,
    since only the window server composites a Chromium page window over the glass under it."""
    if not opts.shots:
        return None
    os.makedirs(opts.shots, exist_ok=True)
    taken = {}
    for look in ("light", "dark"):
        rpc("debug.appearance", {"mode": look})
        time.sleep(3)  # test harness: the theme reload and the page's repaint land
        # screencapture takes one file per display; a single-display mini writes only d1.
        names = [os.path.join(opts.shots, f"{mode}-{look}-d{n}.png") for n in (1, 2)]
        done = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", *names], capture_output=True, text=True, timeout=30)
        taken[look] = {"files": [n for n in names if os.path.exists(n)], "error": done.stderr.strip() or None}
    rpc("debug.appearance", {"mode": "system"})
    taken["windows"] = rpc("debug.window_list")
    return taken


def focus_probe():
    if not opts.activate:
        return None
    subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to activate'], capture_output=True, timeout=30)
    time.sleep(1)  # test harness: activation settles
    focused = pane("focus_composer").get("focused")
    time.sleep(0.5)  # test harness: focus settles
    report = rpc("debug.focus") or {}
    windows = [w for w in report.get("windows", []) if isinstance(w, dict)]
    return {"composer_focused": focused, "app_active": report.get("app_active"), "key_window": report.get("key_window"),
            "shell_window_is_key": any(w.get("is_key") for w in windows),
            "first_responders": [(w.get("appkit") or {}).get("first_responder") for w in windows]}


def launch(mode, scratch):
    """Launches the app for `mode` through BenchApp: the Chromium default engine, the mode's `agent.chromium` debug
    tunable, the window at 40,40 1200x900 on the last screen. True once its socket answered with a window."""
    global bench, SOCKET
    tunables = os.path.join(scratch, "debug-tunables.json")
    with open(tunables, "w") as handle:
        json.dump({"version": 1, "values": TUNABLES[mode]}, handle)
    env = {"CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables}
    if opts.shots:
        # The window glass (Liquid Glass under a 0.7 theme tint), so the captures show what a page does over it;
        # BenchApp's own (empty) Ghostty config is an opaque window.
        ghostty = os.path.join(scratch, "ghostty")
        with open(ghostty, "w") as handle:
            handle.write("background-opacity = 0.7\nbackground-blur = macos-glass-regular\n")
        env["CMUX_NEXT_GHOSTTY_CONFIG"] = ghostty
    if opts.activate:
        env["CMUX_NEXT_NO_ACTIVATE"] = None  # BenchApp: drop its default no-activate launch
    bench = BenchApp(APP, out=opts.out, env=env, config={"browser": {"defaultEngine": "chromium"}},
                     window=(40, 40, 1200, 900), screen="last", log_name=f"app-{TAG}-{mode}.log",
                     build_config=opts.build_config)
    try:
        bench.launch(timeout=120)  # prints the reason (no GUI session, crash, silent socket) when it fails
    except LaunchError:
        return False
    SOCKET = bench.socket
    return True


def quit_app():
    """Quits the mode's app and its daemons (BenchApp.stop), then any process of the bundle still running."""
    global bench
    if bench is None:
        return
    try:
        bench.stop()
    finally:
        bench_memory.end_bundle(APP)
        bench = None


def record(mode, result):
    """The mode's series as result-v1 under --story (BenchApp.record); {} without --story."""
    if not opts.story:
        return {}
    entries = bench_report.agent_engine_series(mode, result, opts.chats, story=opts.story)
    written = bench_report.record_all(bench, entries, engine=mode, session=opts.session)
    if not bench_report.any_written(written):
        print(f"RESULT-V1 FAIL {mode}: no series written", flush=True)
    return written


def run_mode(mode):
    if not launch(mode, tempfile.mkdtemp(prefix=f"agent-engine-{mode}-")):
        return {"error": "the tagged app did not come up"}
    time.sleep(opts.settle)  # test harness: launch settles before the baseline
    result = {"baseline": memory("baseline", 0)}
    first = open_chat()
    result["first_chat"] = first
    print(mode, "first chat", json.dumps(first), flush=True)
    time.sleep(opts.settle)  # test harness: the chat settles before it is measured
    result["one_chat"] = memory("one chat", 1)
    result["session"] = open_session()
    result["focus"] = focus_probe()
    result["shots"] = screen_shots(mode)
    result["typing"] = typing()
    pane("seed_rows", count=5000, timeout=60)
    time.sleep(3)  # test harness: the seeded transcript lays out
    pane("fling", seconds=3, wait=True, timeout=60)  # warms the transcript's layout, not reported
    result["flings"] = [fling() for _ in range(opts.flings)]
    more = [open_chat() for _ in range(opts.chats - 1)]
    result["more_chats"] = more
    time.sleep(opts.settle)  # test harness: the chats settle before they are measured
    result[f"chats_{opts.chats}"] = memory(f"{opts.chats} chats", opts.chats)
    base, one, many = (result[k]["total_footprint_mb"] for k in ("baseline", "one_chat", f"chats_{opts.chats}"))
    result["summary"] = {
        "engine": first.get("engine"), "engines_seen": sorted({c.get("engine") for c in [first] + more if c.get("engine")}),
        **bench_report.agent_engine_summary_stats(first, more),
        "first_chat_mb": round(one - base, 1), f"chats_{opts.chats}_mb": round(many - base, 1),
        "per_more_chat_mb": round((many - one) / max(1, opts.chats - 1), 1),
        "typing_to_frame": result["typing"].get("to_frame"), "typing_to_paint": result["typing"].get("to_paint"),
        "session_composer_ms": result["session"].get("composer_ms"),
        "typing_keys": result["typing"].get("keys"), "focus": result["focus"],
        "fling_dropped_frames": [f.get("dropped_frames") for f in result["flings"]],
        "fling_p95_ms": [f.get("p95_ms") for f in result["flings"]],
        "fling_p99_ms": [f.get("p99_ms") for f in result["flings"]],
    }
    result["result_v1"] = record(mode, result)
    return result


def recorded(result):
    """Without --story, True; with it, whether the mode wrote at least one series."""
    return not opts.story or bench_report.any_written(result.get("result_v1"))


def main():
    results = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "modes": {}}
    for mode in MODES:
        try:
            results["modes"][mode] = run_mode(mode)
        finally:
            quit_app()
        time.sleep(3)  # test harness: the last mode's processes leave
    print("\nSUMMARY", json.dumps({m: r.get("summary", r) for m, r in results["modes"].items()}, indent=1), flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        json.dump(results, open(opts.json, "w"), indent=1)
    return all("summary" in r and recorded(r) for r in results["modes"].values())


ok = False
try:
    ok = main()
finally:
    quit_app()
sys.exit(0 if ok else 1)
