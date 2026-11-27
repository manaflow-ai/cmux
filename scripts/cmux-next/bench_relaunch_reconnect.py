#!/usr/bin/env python3
"""Relaunch to the first live chat event: how long a cmux NEXT app takes, after it relaunches, to
show a running agent's reply streaming again in the chat it shows.

Leo, 2026-11-04: "i feel like the restarted after nightly update does too many layout
shifts/flicker renderings and takes too long to reconnect acpmux or whatever". This is the
reconnect half (manaflow-ai/cmuxterm-hq#6338).

The load: `--chats` local chats on the app's own acpmux daemon (the test agent, idle_cost_agent.py),
each in its own workspace and shown once; the first one streams a reply (`stream:`, `--rate` words
a second) through the whole run, and its workspace is the one shown when the app quits. Then, for
each mode in `--modes`, `--rounds` times: quit the app (Quit and Keep Sessions; update and new-version through the updater's relaunch path, quit_app; SIGTERM if it is still up
after 20 s), do what the mode says, relaunch it into the same HOME and state, and wait until the
shown chat gets a live event (one that arrives within LIVE_EVENT_LAG_MS of when acpmux recorded it,
webviews perf.ts). Modes:

  warm     the daemon keeps running (its streaming turn keeps it), same build: a plain relaunch.
  update   the bundle is replaced in place while the app is gone, as Sparkle's installer does (a copy
           staged beside it, swapped in atomically, the old one deleted), so the running daemon's
           executable is gone: the relaunched app hands it off (AcpmuxVersionHandoff) and starts
           the bundled one, which adopts the streaming agent.
  cold     the daemon is stopped (SIGTERM) after the quit: the relaunched app starts one.
  new-version  `update`, with the bundle a new version as a real update ships one (Leo, 2026-11-14,
           after a nightly update: "terminal is instantly shown, then browser, and then the agent chat
           after a bit and after a jolt of rendering"): every script of the agent pane's page has new
           bytes, and pane.css new bytes under a new `?h=` name in index.html, so nothing the old
           build's renderer kept or compiled is of this build; the version and commit in Info.plist
           are new, and the copy is signed ad hoc, as capture-host signs every clone
           (new_version_bundle).

Each round's phases, in ms since the relaunched app's process started (debug.timings' launch marks,
and the shown page's own wall-clock marks lined up with them through `process_start_epoch_ms`):

  app main (main_start) -> did_finish_launching_end -> acpmux.lookup_start -> acpmux.adopted ->
  acpmux.status_answered -> acpmux.handed_off (update) -> acpmux.spawn_start -> acpmux.spawn_ready ->
  acpmux.lookup_end -> agent_pane.view_created -> agent_pane.page_loaded -> page handshakeStart ->
  agent_pane.handshake_end / page handshakeReady -> page connectStart -> agent_pane.transport_open ->
  page connected -> agent_pane.painted -> page firstEvent -> page liveEvent

and what the person sees, each in ms from the window's first committed frame (first_window_frame_committed):
  (a) terminal  the terminal got its content (first_terminal_content);
  (b) browser   the browser pane's first contentful paint (browser.first_paint; --browser);
  (c) chat      the chat pane first shows its transcript: the pane showed the page's rows (its saved copy
                or its own; agent_pane.painted) or the pane's saved picture (agent_pane.launch_image_shown),
                whichever came first;
  (d) settled   the chat is final: the page drew acpmux's settled view of it (page settledDrawn) and no
                layout shift came after (page lastShift: the Layout Instability API's last entry, counted
                up to SETTLE_WATCH_MS after the settled frame). Read with --shown idle: a streaming reply
                moves rows by design.

plus the daemon's own log lines (stopping, ready) when its log has them. Prints one
PERF-RELAUNCH line per round, a per-mode median table between PERF-RELAUNCH-TABLE-BEGIN and -END,
and writes the JSON to --out.

  bench_relaunch_reconnect.py --app BUNDLE [--modes warm,update,new-version,cold] [--rounds 3] [--chats 6]
      [--shown streaming|idle] [--turns 40] [--browser] [--out FILE.json] [--md FILE.md]
One command on the fleet (bench_power.py's `relaunch-reconnect` scenario; --arg=chats=N sets the chats):
  cmux-ci run --class exclusive --measurement --display --label measure \\
    --script scripts/measure/perf-idle-power.sh --ref SHA --arg=scenarios=relaunch-reconnect \\
    --arg=config=bench --artifact artifacts/perf-idle-power.json
macOS only, on a fleet Mac (it launches the app with a scratch HOME).
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import plistlib
import glob
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, FakeChats, end_bundle, process_table)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)
import idle_cost_load as load  # noqa: E402  (new_session, stream, open_workspace)

AGENT = os.path.join(HERE, "idle_cost_agent.py")
# Every phase, in the order the relaunch reaches them: (column, source, mark).
PHASES = [
    ("app main", "app", "main_start"),
    ("did finish launching", "app", "did_finish_launching_end"),
    ("first window frame", "app", "first_window_frame_committed"),
    ("Chromium start", "app", "cef.initialize_start"),
    ("Chromium ready", "app", "cef.ready"),
    ("lookup start", "app", "acpmux.lookup_start"),
    ("build homes adopted", "app", "acpmux.adopted"),
    ("daemon status answered", "app", "acpmux.status_answered"),
    ("bundled build read", "app", "acpmux.bundled_build_read"),
    ("old daemon handed off", "app", "acpmux.handed_off"),
    ("daemon spawn start", "app", "acpmux.spawn_start"),
    ("daemon ready (log)", "daemon", "ready"),
    ("daemon spawn ready", "app", "acpmux.spawn_ready"),
    ("lookup end", "app", "acpmux.lookup_end"),
    ("pane view created", "app", "agent_pane.view_created"),
    ("page loaded", "app", "agent_pane.page_loaded"),
    ("page handshake start", "page", "handshakeStart"),
    ("handshake: endpoint", "app", "agent_pane.handshake_endpoint"),
    ("handshake: machine name", "app", "agent_pane.handshake_machine"),
    ("handshake: start folders", "app", "agent_pane.handshake_folders"),
    ("handshake: GitHub repository", "app", "agent_pane.handshake_github"),
    ("handshake: relaunch wake", "app", "agent_pane.handshake_wake"),
    ("handshake answered", "page", "handshakeReady"),
    ("page connect start", "page", "connectStart"),
    ("transport open asked", "app", "agent_pane.transport_open_asked"),
    ("transport open start", "app", "agent_pane.transport_open_start"),
    ("transport open", "app", "agent_pane.transport_open"),
    ("page connected", "page", "connected"),
    ("pane painted", "app", "agent_pane.painted"),
    ("first event", "page", "firstEvent"),
    ("first live event", "page", "liveEvent"),
    ("window first frame", "app", "first_window_frame_committed"),
    ("terminal content", "app", "first_terminal_content"),
    ("browser first paint", "app", "browser.first_paint"),
    ("launch image shown", "app", "agent_pane.launch_image_shown"),
    ("launch image cleared", "app", "agent_pane.launch_image_cleared"),
    ("page copy painted", "page", "copyPainted"),
    ("page rows drawn", "page", "rowsDrawn"),
    ("page copy swapped", "page", "copySwapped"),
    ("pane painted settled", "app", "agent_pane.painted_settled"),
    ("page settled drawn", "page", "settledDrawn"),
    ("page last layout shift", "page", "lastShift"),
]
# What the person sees, in ms from the window's first frame (the module doc): (a) to (d).
SEEN = ["(a) terminal", "(b) browser", "(c) chat rows", "(d) chat settled"]
# How long after the settled frame a layout shift still counts against (d), and how long a round waits for it.
SETTLE_WATCH_MS = 3000


ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Daemon log lines a round keeps (after the quit): what stopped, started, adopted or replayed.
LOG_KEEP = re.compile(r"ready|stopping|shutting down|stopped|owner|adopt|replay|host|handoff|lock|resum|warn|error", re.I)


def daemon_log(home: str, since: float) -> tuple[dict, list[str]]:
    """The daemon log since `since` (ms since 1970): the first `acpmux ready` and `shutting down`
    times, and the lines LOG_KEEP matches (at most 300)."""
    found: dict[str, float] = {}
    kept: list[str] = []
    for path in sorted(glob.glob(os.path.join(home, "**", "*.log"), recursive=True)):
        try:
            with open(path, errors="replace") as handle:
                lines = handle.readlines()[-20000:]
        except OSError:
            continue
        for raw in lines:
            line = ANSI.sub("", raw).rstrip()
            stamp = re.match(r"\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)(Z|[+-]\d\d:?\d\d)?", line)
            if not stamp:
                continue
            text = stamp.group(1)[:26] + (stamp.group(2) or "Z").replace("Z", "+00:00")
            try:
                at = datetime.fromisoformat(text).timestamp() * 1000
            except ValueError:
                continue
            if at < since:
                continue
            for name, needle in (("ready", "acpmux ready pid="), ("shutting_down", "shutting down")):
                if needle in line and (name not in found or at < found[name]):
                    found[name] = at
            if LOG_KEEP.search(line) and len(kept) < 300:
                kept.append(f"{os.path.basename(path)}: {line[:400]}")
    return found, kept


RENAME_SWAP = 0x2  # <stdio.h>: renamex_np swaps the two paths


def quit_app(sock: str, bundle: str, updater: bool = False):
    """The Quit action, as a person's Cmd-Q, or with `updater` what Restart to Update runs (`debug.updater relaunch`:
    the updater's relaunch hook, which saves the windows, then terminate); SIGTERM
    (also a normal quit) when the app is still up after 20 s.

    The update modes quit through the updater: with Cmd-Q they measured a quit no update runs. Leo, 2026-11-24, on
    Restart to Update: "it def percievably changed a lot bc the agent pane blanked": the updater's quit pictured the
    chats after their windows had left the screen, found none and dropped every saved picture; these rows, quitting
    with Cmd-Q, still showed the picture at once."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    apps = {pid for pid, _, cmd in bm.process_table() if cmd.startswith(binary_dir + "/") and not bm.is_clone_cleanup(cmd)}
    if updater:
        bp.rpc(sock, "debug.updater", {"action": "relaunch"}, timeout=10)
    else:
        bm.App(bundle, sock).action("quitKeepSessions", wait=False)
    left = bm.still_running(apps, 20)
    if left:
        print(f"   quit: the app was still up after 20 s; SIGTERM {sorted(left)}", file=sys.stderr)
        bm.end_processes(left)


def daemon_pids(bundle: str) -> set[int]:
    return {pid for pid, _, cmd in bm.process_table()
            if bm.in_bundle(cmd, bundle) is not None and "/bin/acpmux daemon run" in cmd}


def replace_bundle(bundle: str, generation: int | None = None):
    """An update's swap, as Sparkle's installer does it (SUPlainInstaller): the new copy (an APFS
    clone) staged in a temporary folder on the bundle's volume, swapped with the installed bundle
    in one `renamex_np(RENAME_SWAP)`, so the bundle's path never goes missing, then the old bundle
    deleted. Sparkle deletes it right after it asks for the relaunch, seconds before the new app
    looks at its daemon; deleting it before the relaunch keeps that order every round, so the
    running daemon's executable is gone and the relaunched app hands it off
    (AcpmuxVersionHandoff.replaced) as it does after a real update."""
    bundle = bundle.rstrip("/")
    staged = tempfile.mkdtemp(prefix=".bench-update-", dir=os.path.dirname(bundle))
    try:
        new = os.path.join(staged, os.path.basename(bundle))
        subprocess.run(["cp", "-cR", bundle, new], check=True, timeout=600)
        if generation is not None:
            new_version_bundle(new, generation)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renamex_np(new.encode(), bundle.encode(), RENAME_SWAP) != 0:
            raise OSError(ctypes.get_errno(), "renamex_np(RENAME_SWAP) failed", bundle)
    finally:
        shutil.rmtree(staged, ignore_errors=True)


def new_version_bundle(bundle: str, generation: int):
    """The bundle as the next version of itself (the `new-version` mode), on the staged copy before it is
    swapped in: each script of the agent page gets new bytes (a trailing comment), pane.css new bytes and the
    new `?h=` name index.html links it by (build-agent-pane-web.sh), Info.plist a new version and commit, and
    the bundle is signed ad hoc again (its resources changed)."""
    tag = f"bench-new-version {generation}"
    pages = 0
    for root, _dirs, files in os.walk(os.path.join(bundle, "Contents")):
        if not {"index.html", "pane.css", "chat-snapshot.js"} <= set(files):
            continue
        pages += 1
        # Every script the page ships, at any depth (chunks/, locales/ and the rest), as an update replaces them all.
        scripts = [os.path.join(where, f) for where, _sub, names in os.walk(root) for f in names if f.endswith(".js")]
        for path in scripts + [os.path.join(root, "pane.css")]:
            with open(path, "a") as handle:
                handle.write(f"\n/* {tag} */\n")
        with open(os.path.join(root, "pane.css"), "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()[:16]
        index = os.path.join(root, "index.html")
        with open(index) as handle:
            text = handle.read()
        with open(index, "w") as handle:
            handle.write(re.sub(r"pane\.css\?h=[0-9a-f]+", f"pane.css?h={digest}", text))
    if not pages:
        raise RuntimeError(f"new-version: no agent page (index.html, pane.css, chat-snapshot.js) in {bundle}")
    plist = os.path.join(bundle, "Contents", "Info.plist")
    with open(plist, "rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleVersion"] = f"{info.get('CFBundleVersion') or '0'}.{generation}"
    info["CFBundleShortVersionString"] = f"{info.get('CFBundleShortVersionString') or '0'}.{generation}"
    for key in ("CMUXCommit", "CMUXGitSHA"):
        if key in info:
            info[key] = hashlib.sha1(f"{info[key]} {tag}".encode()).hexdigest()
    with open(plist, "wb") as handle:
        plistlib.dump(info, handle)
    signed = subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", bundle], capture_output=True, text=True)
    if signed.returncode != 0:
        raise RuntimeError(f"codesign of {bundle} failed: {(signed.stderr or signed.stdout).strip()[:300]}")


def seen(phases: dict) -> dict:
    """(a) to (d), in ms from the window's first frame (None when either end is missing)."""
    zero = phases.get("window first frame")

    def since(value):
        return None if value is None or zero is None else round(value - zero, 1)

    rows = [v for v in (phases.get("pane painted"), phases.get("launch image shown")) if v is not None]
    settled = phases.get("page settled drawn")
    shift = phases.get("page last layout shift")
    final = settled
    if settled is not None and shift is not None and settled < shift <= settled + SETTLE_WATCH_MS:
        final = shift
    return {"(a) terminal": since(phases.get("terminal content")), "(b) browser": since(phases.get("browser first paint")),
            "(c) chat rows": since(min(rows) if rows else None), "(d) chat settled": since(final)}


def wait_settled(sock: str, seconds: float) -> dict:
    """The shown pane's launch marks once it drew its settled frame and SETTLE_WATCH_MS passed after it, so a
    layout shift after that frame is in them (or `seconds` pass)."""
    deadline, last, settled_at = time.monotonic() + seconds, {}, None
    while time.monotonic() < deadline:
        stats = bp.rpc(sock, "debug.agent_pane", {"action": "perf_stats"}, timeout=15)
        launch = stats.get("launch") if isinstance(stats, dict) else None
        if isinstance(launch, dict):
            last = launch
            if settled_at is None and "settledDrawn_epoch_ms" in launch:
                settled_at = time.monotonic()
            if settled_at is not None and time.monotonic() - settled_at >= SETTLE_WATCH_MS / 1000:
                return launch
        time.sleep(0.25)  # test script: the page records its own times; this only waits for them
    return last


def long_transcript(cli: str, env: dict, session: str, turns: int):
    """`turns` more answered turns in chat `session`, each a multi-line prompt the test agent echoes: more rows
    than the pane shows, as a chat a person comes back to."""
    body = "\n".join(f"relaunch line {k}: the quick brown fox jumps over the lazy dog, again and again" for k in range(8))
    for turn in range(turns):
        sent = subprocess.run([cli, "acp", "send", session, f"relaunch turn {turn}\n{body}"],
                              capture_output=True, text=True, timeout=120, env=env)
        if sent.returncode != 0:
            print(f"   long transcript: turn {turn}: {(sent.stdout + sent.stderr).strip()[:400]}", file=sys.stderr)
            return


def beside_chat(app, folder: str):
    """A terminal right of the chat and a browser pane under it, on a local page, in the shown workspace."""
    page = os.path.join(folder, "page.html")
    with open(page, "w") as handle:
        handle.write("<!doctype html><title>relaunch page</title><h1>relaunch page</h1>" + "<p>text</p>" * 40)
    for action, extra in (("splitRight", {}), ("splitDown", {}), ("openBrowser.chromium", {"url": "file://" + page})):
        response = app.run(action, **extra)
        if response.get("error") or response.get("code"):
            print(f"   beside chat: {action}: {response.get('message') or response.get('error')}", file=sys.stderr)
        time.sleep(1)  # test script: each pane settles before the next split


def wait_live(sock: str, seconds: float) -> dict:
    """The shown pane's launch marks once it has a live event (or `seconds` pass)."""
    deadline, last = time.monotonic() + seconds, {}
    while time.monotonic() < deadline:
        stats = bp.rpc(sock, "debug.agent_pane", {"action": "perf_stats"}, timeout=15)
        launch = stats.get("launch") if isinstance(stats, dict) else None
        if isinstance(launch, dict):
            last = launch
            if "liveEvent_epoch_ms" in launch:
                return launch
        time.sleep(0.25)  # test script: the page records its own times; this only waits for them
    return last


def round_phases(timings: dict, page: dict, daemon: dict) -> dict:
    """Each phase in ms since the app process started (None when it never happened)."""
    zero = timings.get("process_start_epoch_ms")
    marks = timings.get("launch_ms_since_process_start") or {}
    out = {}
    for column, source, mark in PHASES:
        value = None
        if source == "app":
            value = marks.get(mark)
        elif zero is not None and source == "page" and page.get(f"{mark}_epoch_ms") is not None:
            value = page[f"{mark}_epoch_ms"] - zero
        elif zero is not None and source == "daemon" and daemon.get(mark) is not None:
            value = daemon[mark] - zero
        out[column] = None if value is None else round(float(value), 1)
    out["handshake attempts"] = page.get("handshake_attempts")
    return out


def uptime_to_epoch_ms() -> float | None:
    """ms to add to a CLOCK_UPTIME_RAW reading (ns / 1e6) to get ms since 1970, read now: the app
    stamps `debug.cef` `start_steps` on that clock (CEFStartSteps). None off macOS."""
    clock = getattr(time, "CLOCK_UPTIME_RAW", None)
    if clock is None:
        return None
    before = time.time_ns()
    uptime = time.clock_gettime_ns(clock)
    after = time.time_ns()
    return ((before + after) / 2 - uptime) / 1e6


def cef_step_marks(cef: dict, offset_ms: float | None, zero: float | None) -> dict:
    """Chromium's start steps (`debug.cef` `start_steps`: `initialize`, `make_tab`, `create_window`,
    pump runs, `first_window`, page points) as marks in ms since process start: `cef.NAME` when a
    step began and `cef.NAME.end` when a timed one ended (a repeated name gets `#2`, `#3`)."""
    steps = cef.get("start_steps") if isinstance(cef, dict) else None
    if offset_ms is None or zero is None or not isinstance(steps, list):
        return {}
    out, seen = {}, {}
    for step in steps:
        if not isinstance(step, dict) or not isinstance(step.get("start_uptime_ns"), (int, float)):
            continue
        name = str(step.get("name"))
        seen[name] = seen.get(name, 0) + 1
        key = f"cef.{name}" + (f"#{seen[name]}" if seen[name] > 1 else "")
        start = step["start_uptime_ns"] / 1e6 + offset_ms - zero
        out[key] = start
        if isinstance(step.get("ms"), (int, float)) and step["ms"] > 0:
            out[f"{key}.end"] = start + step["ms"]
    return out


def all_marks(timings: dict, page: dict, cef: dict | None = None, offset_ms: float | None = None) -> dict:
    """Every app launch mark, Chromium start step and page mark, in ms after
    did_finish_launching_end, in time order: a mark added inside a phase (a new
    `DebugTimings.markLaunch`, a `CEFStartSteps` point or a page `*_epoch_ms` mark) shows up here
    with no harness change, as the fleet runs this script only from feat-cmux-next."""
    zero = timings.get("process_start_epoch_ms")
    marks = dict(timings.get("launch_ms_since_process_start") or {})
    marks.update(cef_step_marks(cef or {}, offset_ms, zero))
    if zero is not None:
        for key, at in page.items():
            if key.endswith("_epoch_ms") and isinstance(at, (int, float)):
                marks["page." + key[:-len("_epoch_ms")]] = at - zero
    base = marks.get("did_finish_launching_end")
    if not isinstance(base, (int, float)):
        return {}
    out = {name: round(float(at) - base, 1) for name, at in marks.items() if isinstance(at, (int, float))}
    return dict(sorted(out.items(), key=lambda item: item[1]))


def median_table(rounds: list[dict], modes: list[str]) -> str:
    def cell(values):
        values = [v for v in values if v is not None]
        return "-" if not values else f"{statistics.median(values):.0f}"
    lines = ["| phase (ms since process start, median) | " + " | ".join(modes) + " |",
             "| --- |" + " --- |" * len(modes)]
    for column, _, _ in PHASES + [("handshake attempts", "", "")]:
        lines.append(f"| {column} | " + " | ".join(
            cell([r["phases"].get(column) for r in rounds if r["mode"] == mode]) for mode in modes) + " |")
    for column in SEEN:
        lines.append(f"| **{column}**, ms after the window's first frame | " + " | ".join(
            cell([r["seen"].get(column) for r in rounds if r["mode"] == mode]) for mode in modes) + " |")
    lines.append("| rounds live (settled with --shown idle) | " + " | ".join(
        f"{sum(1 for r in rounds if r['mode'] == mode and (r['phases'].get('first live event') or r['phases'].get('page settled drawn')) is not None)}"
        f"/{sum(1 for r in rounds if r['mode'] == mode)}" for mode in modes) + " |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--modes", default="warm,update,cold")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--chats", type=int, default=6, help="local chats, each in its own workspace")
    parser.add_argument("--rate", type=float, default=10, help="streamed words a second")
    parser.add_argument("--settle", type=float, default=10, help="seconds after the shown chat is live before each quit")
    parser.add_argument("--live-timeout", type=float, default=120)
    parser.add_argument("--shown", choices=["streaming", "idle"], default="streaming",
                        help="the chat shown at each quit: streaming a reply, or idle with --turns answered turns (for (d))")
    parser.add_argument("--turns", type=int, default=40, help="--shown idle: the shown chat's answered turns")
    parser.add_argument("--browser", action="store_true",
                        help="the shown workspace also has a terminal and a browser pane beside the chat ((a) and (b))")
    parser.add_argument("--retheme", default="",
                        help="two themes of one appearance, A,B: the app starts on A and each new-version relaunch "
                             "switches to the other, as an update that adds or tunes a theme token changes the "
                             "theme's key (the saved chat copy was refused on that key, chatSnapshot/shared.ts)")
    parser.add_argument("--config", default="{}")
    parser.add_argument("--out")
    parser.add_argument("--md")
    args = parser.parse_args(argv)
    modes = [mode for mode in args.modes.split(",") if mode]
    for mode in modes:
        if mode not in ("warm", "update", "new-version", "cold"):
            raise SystemExit(f"bench-relaunch: unknown mode {mode}")
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(args.app)
    root = tempfile.mkdtemp(prefix="relaunch-reconnect-")
    acpmux_home = os.path.join(root, "acpmux")
    env = {"ACPMUX_HOME": acpmux_home}
    config = json.loads(args.config)
    themes = [name.strip() for name in args.retheme.split(",") if name.strip()]
    if themes and len(themes) != 2:
        raise SystemExit("bench-relaunch: --retheme takes two themes, A,B")
    if themes:
        config.setdefault("appearance", {})["theme"] = themes[0]
    rounds, scratch, load_info, generation = [], None, {}, 0
    total = len(modes) * args.rounds
    stream_s = 600 + total * 120  # the reply streams through every round
    try:
        pid, sock, scratch = bm.launch(args.app, config, env)
        app = bm.App(args.app, sock)
        chats = bm.FakeChats(app, args.app, AGENT)
        shown, streaming = None, None
        idle = args.shown == "idle"
        for i in range(args.chats):
            session = load.new_session(app.cli_path, chats.env, f"relaunch chat {i}")
            if session and streaming is None and idle:
                long_transcript(app.cli_path, chats.env, session, args.turns)
            workspace = load.open_workspace(app, session) if session else None
            if workspace and streaming is None and (idle or load.stream([app.cli_path, "acp"], chats.env, session, stream_s, args.rate)):
                shown, streaming = workspace, session
        if not shown:
            raise SystemExit("bench-relaunch: no shown chat opened")
        app.action("goToWorkspace", workspace=shown)
        if args.browser:
            beside_chat(app, root)
        waiting = wait_settled if idle else wait_live
        first = waiting(sock, args.live_timeout)
        load_info = {"chats": args.chats, "shown": args.shown, "turns": args.turns if idle else None, "browser": args.browser,
                     "shown_session": streaming,
                     "first_launch_live": ("settledDrawn_epoch_ms" if idle else "liveEvent_epoch_ms") in first}
        print(f"PERF-RELAUNCH-LOAD {json.dumps(load_info)}", flush=True)
        for mode in modes:
            for index in range(args.rounds):
                time.sleep(args.settle)  # test script: the chat streams a while before the quit
                quit_at = time.time() * 1000
                quit_app(sock, args.app, updater=mode in ("update", "new-version"))
                if mode == "cold":
                    bm.end_processes(daemon_pids(args.app))
                elif mode == "update":
                    replace_bundle(args.app)
                elif mode == "new-version":
                    generation += 1
                    replace_bundle(args.app, generation)
                    if themes:
                        config.setdefault("appearance", {})["theme"] = themes[generation % 2]
                running = sorted(daemon_pids(args.app))
                started = time.time() * 1000
                pid, sock, scratch = bm.launch(args.app, config, env, scratch=scratch)
                page = waiting(sock, args.live_timeout)
                timings = bp.rpc(sock, "debug.timings") or {}
                cef = bp.rpc(sock, "debug.cef") or {}
                daemon, log_lines = daemon_log(acpmux_home, quit_at)
                daemon = {name: at for name, at in daemon.items() if at >= started}
                phases = round_phases(timings, page, daemon)
                seen_ms = seen(phases)
                zero = timings.get("process_start_epoch_ms")
                entry = {"mode": mode, "round": index + 1, "daemon_before": running,
                         "launch_to_process_ms": None if zero is None else round(zero - started, 1),
                         "phases": phases, "seen": seen_ms, "page": page, "daemon_log": daemon, "daemon_log_lines": log_lines,
                         "daemon_after": sorted(daemon_pids(args.app)),
                         "app_marks": timings.get("launch_ms_since_process_start"),
                         "cef_start_steps": cef.get("start_steps") if isinstance(cef, dict) else None}
                rounds.append(entry)
                print(f"PERF-RELAUNCH mode={mode} round={index + 1} live_ms={phases.get('first live event')} "
                      f"seen={json.dumps(seen_ms)} {json.dumps(phases)}", flush=True)
                print(f"PERF-RELAUNCH-MARKS mode={mode} round={index + 1} "
                      f"{json.dumps(all_marks(timings, page, cef, uptime_to_epoch_ms()))}", flush=True)
    finally:
        bm.end_bundle(args.app)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    sha = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True).stdout.strip()
    model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
    harness = (f"bench_relaunch_reconnect.py @{sha or '?'} {model}, {args.chats} chats, {args.rounds} rounds, shown {args.shown}"
               + (f" ({args.turns} turns)" if args.shown == "idle" else "") + (", browser" if args.browser else "")
               + (f", retheme {args.retheme}" if themes else ""))
    table = median_table(rounds, modes)
    print("PERF-RELAUNCH-TABLE-BEGIN")
    print(f"harness: {harness}")
    print(table, end="")
    print("PERF-RELAUNCH-TABLE-END", flush=True)
    if args.md:
        with open(args.md, "w") as handle:
            handle.write(f"harness: {harness}\n\n{table}")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": args.app, "harness": harness, "load": load_info, "rounds": rounds,
                       "markdown": table}, handle, indent=1)


if __name__ == "__main__":
    main()
