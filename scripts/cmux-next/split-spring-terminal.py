#!/usr/bin/env python3
"""Rapid Cmd-D and Cmd-Shift-D on terminals, in a real window (Lawrence 2026-10-20: "when I do Command-D
multiple times, the animation is not perfectly fluid and smooth ... buttery, perfectly smooth").

Launches a tagged cmux-next app (scratch config, empty Ghostty config). Each round opens a fresh workspace
with one terminal filled with --scrollback lines (optionally streaming, --stream), then presses the split
--presses times, --interval ms apart, through the splitRight (or splitDown) action, and measures the whole
gesture until the panes rest:

  missed         display frames the main thread missed (`debug.frames`), and max / p99 frame interval
  layout_max_ms  the layout's longest main-thread work in one frame (`debug.motion` clock)
  grid_reports   terminal grid reports the views made (`debug.window_transition`); resizes_sent: grids
                 sent to the daemon, each a PTY resize, a shell redraw and a reflow at the owner
  hangs          main-thread hangs (`debug.hangs`)

Budget rows (printed; they fail the run with --gate): no missed frame beyond --missed-budget, and at most
one grid per terminal of the row (presses + 1) for the whole gesture.

With --suite=pane-perf it runs scripts/cmux-next/pane-perf-terminal.py instead (split, close, New Column, zoom
and a divider drag in 2, 8 and 30 pane layouts; the controller allowlists this entry, not pane-perf.sh yet).
With --suite=app-perf it runs scripts/cmux-next/app-perf.py the same way (app gestures at 10 and 50 workspaces).
With --suite=anim-perf it runs scripts/cmux-next/anim-perf-terminal.py (tab, workspace, sidebar, group, Home
and palette animations at a 120 Hz frame budget).
With --suite=split-scale it runs scripts/cmux-next/split-scale-bench.py (split, close, bottom pane, divider drag and
side pane across 1/4/9 splits, four pane contents and 1/10/30 workspaces).
With --suite=split-move it runs that bench's move family (--moves: a tab or a pane from one split to another).

Usage: split-spring-terminal.py --tag <tag> --app PATH [--rounds 3] [--presses 5] [--interval 100]
       [--directions right,down] [--scrollback 20000] [--stream] [--json PATH] [--out DIR] [--gate]
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, require_gui_session  # noqa: E402
from state_wait import StateWaitTimeout, wait_stable, wait_until  # noqa: E402

# `--suite=launch-check`: only launch the app, wait for its socket and a window, quit (bench_launch.py check): is
# this worker able to run GUI benches at all. Dispatched before the session gate: `check` names no-gui-session itself.
if "--suite=launch-check" in sys.argv:
    def _flag(name, default=None):
        for i, a in enumerate(sys.argv):
            if a.startswith(name + "="):
                return a.split("=", 1)[1]
            if a == name and i + 1 < len(sys.argv):
                return sys.argv[i + 1]
        return default
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_launch.py")
    rest = ["check", "--app", _flag("--app"), "--out", _flag("--out", "/tmp")]
    if _flag("--json"):
        rest += ["--json", _flag("--json")]
    os.execv(sys.executable, [sys.executable, suite] + rest)
# `--suite=scale-fixture`: 1,100 workspaces, 5 Chiefs and a 160 KB cmux.json; fails on a main-thread block over
# 250 ms in the sidebar flush, scroll and switch flows (scripts/cmux-next/scale-fixture-bench.py). Before the GUI
# check: with no GUI session it passes with a warning itself (fail open), as its PR check needs.
if "--suite=scale-fixture" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scale-fixture-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=scale-fixture"])
# Every other suite but pane-bench (package tests, no window) needs this account's GUI login session on the console:
# without it the app never opens its socket (bench_launch.py). Say so at once instead of after a launch timeout (the
# build in split-spring.sh has run by then). launch-check above reports it itself, in `check`'s own --json shape.
if "--suite=pane-bench" not in sys.argv and "--suite=action-budget-bench" not in sys.argv:
    require_gui_session("split-spring")
# `--suite=power-user`: fast seeded window resizes, workspace and tab switches, judged per frame (frame times,
# blank and flashing panes, layout shift the input did not cause; scripts/perf-bench/power_user_native.py).
if "--suite=power-user" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench", "power_user_native.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=power-user"])
# `--suite=memory-agents`: the app's idle memory, empty and with idle agent chats open, as perf-cron rows
# (scripts/cmux-next/memory-agents-cron.py, bench_memory.py on the acpmux test agent).
if "--suite=memory-agents" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-agents-cron.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=memory-agents"])
# `--suite=cef-resize`: late frames and commit time while panes and the window resize beside a Chromium page, as
# perf-cron rows (scripts/cmux-next/cef-resize-cron.py, cef-resize-sync-bench.py's light bench).
if "--suite=cef-resize" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cef-resize-cron.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=cef-resize"])
# `--suite=motion-frames`: blank or late frames around Cmd-Shift-Enter, Cmd-P and Cmd-W at the default motion and
# under Reduce Motion (scripts/ci/frame-pacing/motion_frames_fleet.py, golden.py's motion_frames on this display).
if "--suite=motion-frames" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci", "frame-pacing", "motion_frames_fleet.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=motion-frames"])
# `--suite=relaunch`: quit and reopen with the session restored, to the window, the chats live again and the terminals
# live; `--suite=wake`: the app after every process of it was frozen and resumed, a wake proxy. Both as perf-cron rows
# (scripts/cmux-next/relaunch-wake-cron.py, which keeps the --suite argument).
for _suite in ("relaunch", "wake"):
    if f"--suite={_suite}" in sys.argv:
        suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relaunch-wake-cron.py")
        os.execv(sys.executable, [sys.executable, suite] + sys.argv[1:])
# `--suite=chat-size`: one chat at 1 MB to 4 GB, five axes, each over the 1 MB chat's (scripts/cmux-next/chat-size-ratio.py;
# the perf cron's chat-size part).
if "--suite=chat-size" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chat-size-ratio.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=chat-size"])
# `--suite=chat-snappy`: Enter to the sent row's frame, the reserved turn in that frame, layout shifts per send, first
# token and chat switch, plain and under duress (scripts/measure/snappy-bench.py; the perf cron's chat-snappy part).
if "--suite=chat-snappy" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "measure", "snappy-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=chat-snappy"])
# `--suite=graceful-swap`: a webview .tsx save to the first changed frame of the focused pane, the unfocused pane and a
# hidden tab, drafts kept (scripts/measure/graceful-swap-cron.py; the perf cron's hot-swap part, goal hot-swap-fast).
if "--suite=graceful-swap" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "measure", "graceful-swap-cron.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=graceful-swap"])
# `--suite=renderer-rest`: each Chromium renderer's footprint, pages and V8 heap every 5 s while the empty app rests,
# then after a GC and a memory-pressure purge (scripts/cmux-next/renderer-rest.py, CMUX-571 ram-baseline).
if "--suite=renderer-rest" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "renderer-rest.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=renderer-rest"])
# `--suite=bench-smoke`: one short run of each bench that launches through bench_launch.py (bench-launch-smoke.py).
if "--suite=bench-smoke" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-launch-smoke.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=bench-smoke"])
# `--suite=terminal-throughput`: one large output burst through a NEXT terminal and through standalone Ghostty, MB/s
# each and their ratio (scripts/cmux-next/terminal-throughput-bench.py; the perf cron's throughput part).
if "--suite=terminal-throughput" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "terminal-throughput-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=terminal-throughput"])
# `--suite=power`: the app's power in mW, idle and scrolling, against standalone Ghostty at idle
# (scripts/cmux-next/power-cron.py, bench_power.py; the perf cron's power part).
if "--suite=power" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "power-cron.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=power"])
# `--suite=premain`: where the time from the process start to main() goes (scripts/cmux-next/premain-launch.py): the
# staged copy, a new ditto copy and a new APFS clone, 3 launches each, with the signature checkers' log per launch.
if "--suite=premain" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "premain-launch.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=premain"])
# `--suite=command-pan`: Command + scroll pans the columns strip, light and STRESS (scripts/cmux-next/bench-command-pan.py).
if "--suite=command-pan" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-command-pan.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=command-pan"])
# `--suite=open-panel`: click to file picker, light and STRESS (scripts/cmux-next/open-panel-bench.py).
if "--suite=open-panel" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "open-panel-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=open-panel"])
# `--suite=overlay-open`: icon picker and group editor opens, warm, cold and after a sign of intent, and their memory
# (scripts/cmux-next/overlay-open-bench.py).
if "--suite=overlay-open" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "overlay-open-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=overlay-open"])
# `--suite=first-click`: one click on native controls acts while a Chromium page holds the key (first-click-live.py).
if "--suite=first-click" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "first-click-live.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=first-click"])
# `--suite=split-resize`: a Chromium page beside a dragged split divider (scripts/cmux-next/split-resize-bench.py).
if "--suite=split-resize" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "split-resize-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=split-resize"])
# `--suite=cef-tab`: new Chromium and WebKit tabs, key to visible and to page pixels, light and STRESS
# (scripts/cmux-next/cef-tab-bench.py, PL-cef-tab).
if "--suite=cef-tab" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cef-tab-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=cef-tab"])
# `--suite=split-scale`: split and pane transitions across splits x pane content x workspaces, first frame, settled,
# frame times, blank frames and retargets per cell (scripts/cmux-next/split-scale-bench.py; the instant-splits goal).
# Launched directly: a fleet step has no LaunchServices session (bench_memory.launch).
if "--suite=split-scale" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "split-scale-bench.py")
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=split-scale"])
# `--suite=right-split-open`: Cmd-D's first frame with the snapshot-first right split off and on, from the app's own
# frame-timing log (scripts/cmux-next/right-split-open-bench.py; the instant-splits goal).
if "--suite=right-split-open" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "right-split-open-bench.py")
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=right-split-open"])
# `--suite=split-move`: the same bench's move family (a tab or a pane from one split to another, forth and back, in a
# half, a third and a quarter, per pane content), judged frame by frame by split_move_metrics.py.
if "--suite=split-move" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "split-scale-bench.py")
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    rest = [a for a in sys.argv[1:] if a != "--suite=split-move"]
    os.execv(sys.executable, [sys.executable, suite] + rest + ([] if any(a.startswith("--moves") for a in rest) else ["--moves=all"]))
# `--suite=sidebar-stress`: sidebar scroll, switch, theme switch during a scroll and custom sidebar sections at 20 and
# 500 workspaces (scripts/cmux-next/sidebar-stress-profiles.py, which runs sidebar-stress-bench.py per profile).
if "--suite=sidebar-stress" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sidebar-stress-profiles.py")
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=sidebar-stress"])
# `--suite=hover-instant`: a sidebar row's hover card, pointer arrival to card, at 10 and 200 workspaces
# (scripts/cmux-next/hover-instant-bench.py; the sidebar-hover-instant goal).
if "--suite=hover-instant" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hover-instant-bench.py")
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=hover-instant"])
# `--suite=pane-perf` (through the allowlisted fleet entry scripts/measure/split-spring.sh): the whole pane
# motion suite instead, scripts/cmux-next/pane-perf-terminal.py, with the same --tag/--app/--out/--json.
# `--suite=budgets`: every perf budget row, scripts/cmux-next/perf-budgets.py (one table, one gate).
if "--suite=budgets" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-budgets.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=budgets"])
# `--suite=stress`: the app under extreme stress from several angles (CPU and thread starvation, many streaming
# agent chats, many workspaces with output floods, a CLI/socket flood, memory pressure), a baseline and a stress
# window each (scripts/cmux-next/stress-bench.py; the `stress` cmux-bench).
if "--suite=stress" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stress-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=stress"])
# `--suite=workspace-scaling`: the warning-only 1/100/1000 workspace trend budget.
if "--suite=workspace-scaling" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workspace-scaling-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=workspace-scaling"])
# `--suite=config-parity`: is the bench build (split-spring.sh --config=bench builds --app) as fast as Release?
# Builds a Release app of this checkout (tag cfgparity-rel), then scripts/cmux-next/bench-config-parity.py
# runs the same actions on both, interleaved (--runs, --rounds, --idle pass through).
if "--suite=config-parity" in sys.argv:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    rest = [a for a in sys.argv[1:] if a != "--suite=config-parity"]
    bench_app = rest[rest.index("--app") + 1]
    out = rest[rest.index("--out") + 1] if "--out" in rest else "/tmp/config-parity"
    passthrough = [a for a in rest if a.startswith(("--runs=", "--rounds=", "--idle=", "--settle="))]
    log = os.path.join(out, "reload-release.log")
    os.makedirs(out, exist_ok=True)
    with open(log, "w") as handle:
        built = subprocess.run(["./scripts/reload.sh", "--tag", "cfgparity-rel", "--config", "release"], cwd=root,
                               env={**os.environ, "CMUX_DEV_BACKEND_MODE": "local"}, stdout=handle, stderr=subprocess.STDOUT)
    lines = open(log).read().splitlines()
    paths = [lines[i + 1].strip() for i, line in enumerate(lines[:-1]) if line.startswith("App path:")]
    if built.returncode != 0 or not paths:
        print("\n".join(lines[-60:]))
        raise SystemExit("config-parity: the Release build failed")
    suite = os.path.join(here, "bench-config-parity.py")
    os.execv(sys.executable, [sys.executable, suite, "--release", paths[-1], "--bench", bench_app, "--out", out] + passthrough)
if "--suite=pane-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pane-perf-terminal.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=pane-perf"])
# `--suite=app-perf`, the same way: scripts/cmux-next/app-perf.py (Cmd-D, Cmd-Shift-D, the side pane, the sidebar, a new
# workspace at the top and workspace switches, at 10 and 50 workspaces; app-efficiency 2026-10-21).
if "--suite=app-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app-perf.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=app-perf"])
# `--suite=anim-perf`: every other app animation (tabs, workspace switch, sidebars, groups, Home, palette),
# scripts/cmux-next/anim-perf-terminal.py, budgets in scripts/perf-bench/budgets.json (animations).
# `--suite=one-motion`: does every pane move as one? Per-pane frame timing of Cmd-B, Cmd-D, the two together and the
# right sidebar beside an agent chat (scripts/cmux-next/one-motion-trace.py; Leo 2026-11-05, "everything moves as one").
if "--suite=one-motion" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "one-motion-trace.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=one-motion"])
# `--suite=chromium-tab-count`: 150 Chromium tabs under launchd's 256 open files, the app still answering
# (scripts/cmux-next/chromium-tab-count-live.py; release blocker 2026-10-23, OpenFileLimit).
if "--suite=chromium-tab-count" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chromium-tab-count-live.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=chromium-tab-count"])
# `--suite=cli-storm`: the CLI storm (bench_cli_storm.py) in a launched app, light or STRESS (--session=stress), with
# debug.main_budget and the display links made around it, scripts/cmux-next/cli-storm-session.py.
# `--sessions=light,stress` (cli-storm and sidebar-churn): one fleet step runs the suite once per session, each in its
# own launch, --out and --json; report.json then holds {"sessions": {session: that run's report}}.
def _run_per_session(script, name):
    args = [a for a in sys.argv[1:] if a != f"--suite={name}"]
    sessions = next(a.split("=", 1)[1] for a in args if a.startswith("--sessions="))
    args = [a for a in args if not a.startswith("--sessions=")]

    def value(flag):
        for i, a in enumerate(args):
            if a.startswith(flag + "="):
                return a.split("=", 1)[1]
            if a == flag and i + 1 < len(args):
                return args[i + 1]
        return None

    def without(flags):
        out, skip = [], False
        for a in args:
            if skip:
                skip = False
                continue
            if a in flags:
                skip = True
                continue
            if not any(a.startswith(f + "=") for f in flags):
                out.append(a)
        return out

    out, report = value("--out") or tempfile.mkdtemp(prefix=f"{name}-"), value("--json")
    rest, combined, code = without({"--out", "--json"}), {"suite": name, "sessions": {}}, 0
    for session in sessions.split(","):
        folder = os.path.join(out, session)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "report.json")
        status = subprocess.call([sys.executable, script, *rest, f"--session={session}", "--out", folder, "--json", path])
        code = code or status
        try:
            with open(path) as f:
                combined["sessions"][session] = json.load(f)
        except (OSError, ValueError) as error:
            combined["sessions"][session] = {"error": f"exit {status}: {error}"}
        combined["sessions"][session]["exit"] = status
    with open(report or os.path.join(out, "report.json"), "w") as f:
        json.dump(combined, f, indent=1, default=str)
    sys.exit(code)


# `--suite=keep-frames-disk`: what the app writes while the 12-pane HEAVY session runs and after it goes idle, with the
# launch frame folder's writes per terminal (REOPEN-F6), scripts/cmux-next/keep-frames-disk-bench.py.
if "--suite=keep-frames-disk" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "keep-frames-disk-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=keep-frames-disk"])
# `--suite=sidebar-churn`: terminal typing idle and while the sidebar rearranges, scripts/cmux-next/sidebar-churn-typing.py.
if "--suite=sidebar-churn" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sidebar-churn-typing.py")
    if any(a.startswith("--sessions=") for a in sys.argv):
        _run_per_session(suite, "sidebar-churn")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=sidebar-churn"])
if "--suite=cli-storm" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cli-storm-session.py")
    if any(a.startswith("--sessions=") for a in sys.argv):
        _run_per_session(suite, "cli-storm")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=cli-storm"])
# `--suite=automation-typing`: terminal typing idle and while agents automate the app (terminal writes, a Chromium page
# driven through the control socket, optional AX walks), scripts/cmux-next/automation-typing-bench.py.
# `--suite=cef-idle`: Chromium's pages, their visibility and what wakes the pump at idle, scripts/cmux-next/cef-idle-probe.py.
if "--suite=cef-idle" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cef-idle-probe.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=cef-idle"])
if "--suite=automation-typing" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "automation-typing-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=automation-typing"])
# `--suite=idle-budget`: threads and wakeups per process at idle, light and STRESS, scripts/cmux-next/idle-budget.py.
if "--suite=idle-budget" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idle-budget.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=idle-budget"])
# `--suite=script-storm`: terminal typing and Cmd-D / Cmd-W while a script storms background workspaces (sidebar
# reorders, tab moves, New Column/Row, renames, app-side renameTab), light and STRESS, scripts/cmux-next/script-storm-bench.py.
if "--suite=script-storm" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "script-storm-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=script-storm"])

def pane_bench_report(proc, config):
    """Passes the lane's output through and writes --json (the step's report.json artifact): one row per PANE-BENCH
    line (action, panes, frames, p50/p95/max ms, frames over 8 ms) and each suite's lane result. Before, the pane bench
    wrote no report, so `--artifact artifacts/split-spring/report.json` failed a step whose suites passed."""
    rows, suites = [], {}
    for line in proc.stdout:
        sys.stdout.write(line)
        if line.startswith("PANE-BENCH "):
            row = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
            rows.append({k: (v if k == "action" else float(v) if "." in v else int(v)) for k, v in row.items()})
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("PaneMotionWorkTests", "PaneMotionBench") and parts[1] in ("passed", "failed", "skipped", "no"):
            suites[parts[0]] = " ".join(parts[1:-1]) if parts[-1].endswith("s") else " ".join(parts[1:])
    status = proc.wait()
    path = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--json=")), None)
    if path is None and "--json" in sys.argv[:-1]:
        path = sys.argv[sys.argv.index("--json") + 1]
    if path:
        with open(path, "w") as f:
            json.dump({"suite": "pane-bench", "config": config, "exit": status, "suites": suites, "rows": rows}, f, indent=1)
    return status

# `--suite=pane-bench`: the layout's own pane motion benches, no app window (PaneMotionBench: frame time of
# split/close/New Column/zoom at 2, 8 and 30 panes; PaneMotionWorkTests: panes touched per frame). Run
# yourself (perf lead, not a CI gate); --config=release|debug picks the build (default release).
if "--suite=pane-bench" in sys.argv:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
    config = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--config=")), "release")
    env = dict(os.environ, CMUX_PANE_BENCH="1", CMUX_SWIFT_SUITE_CONFIGURATION=config)
    sys.exit(pane_bench_report(subprocess.Popen(
        [os.path.join(root, "scripts/ci/package-test-lane.sh"), "suite", "Packages/macOS/CmuxNext",
         "PaneMotionWorkTests,PaneMotionBench"], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace"), config))
# `--suite=action-budget-bench`: the per-action budget monitor's always-on cost in ns per run and per batch
# (ActionBudgetMonitorBench, CmuxNextActionsTests), no app window; --config=release|debug (default release). Run
# it on each macOS major (perf lead, not a CI gate) and quote its `action-budget bench:` lines.
if "--suite=action-budget-bench" in sys.argv:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
    config = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--config=")), "release")
    env = dict(os.environ, CMUX_ACTION_BUDGET_BENCH="1", CMUX_SWIFT_SUITE_CONFIGURATION=config)
    sys.exit(subprocess.run([os.path.join(root, "scripts/ci/package-test-lane.sh"), "suite", "Packages/macOS/CmuxNext",
                             "ActionBudgetMonitorBench"], cwd=root, env=env).returncode)
# `--suite=gui-tests --tests=SuiteA,SuiteB`: CmuxNext package suites that need a screen (a window zoom, a real
# display link), run through the same lane script on a measure host, which has the console session and a
# display the suite runners lack (there such tests are skipped: `.enabled(if: NSScreen.main != nil)`).
if "--suite=gui-tests" in sys.argv:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
    tests = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tests=")), "")
    if not tests:
        sys.exit("split-spring --suite=gui-tests needs --tests=SuiteA,SuiteB")
    sys.exit(subprocess.run([os.path.join(root, "scripts/ci/package-test-lane.sh"), "suite", "Packages/macOS/CmuxNext", tests],
                            cwd=root).returncode)
# `--suite=every-action`: every catalog action through its real entrypoint plus the non-catalog interactions,
# light and STRESS, scripts/cmux-next/every-action-sweep.py (also artifacts/split-spring/every-action.md).
if "--suite=every-action" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "every-action-sweep.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=every-action"])
# `--suite=activation`: Cmd-Tab back in a heavy session (scripts/cmux-next/activation-perf.py: become notices'
# main-thread time, the drain after them, indicator resyncs, hangs; perf-lead row 8). Its activation-perf.json is
# also --json (the step's report.json); the rest of the arguments after the suite's own go to activation-perf.py.
if "--suite=activation" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "activation-perf.py")
    wrapper = argparse.ArgumentParser(add_help=False)
    wrapper.add_argument("--json")
    wrapper.add_argument("--out")
    # activation-perf.py's own options; the measure step's others (--tag, --suite, --vdisplay ...) are not its.
    for flag in ("--app", "--hang-ms", "--workspaces", "--browser", "--hibernate", "--chats", "--cycles", "--max-resyncs"):
        wrapper.add_argument(flag)
    wrapper.add_argument("--sample", action="store_true")
    wrapper.add_argument("--gate", action="store_true")
    known, _ = wrapper.parse_known_args()
    passed = [part for key, value in vars(known).items() if key != "json" and value not in (None, False)
              for part in (["--" + key.replace("_", "-")] + ([] if value is True else [str(value)]))]
    status = subprocess.run([sys.executable, suite] + passed).returncode
    produced = os.path.join(known.out, "activation-perf.json") if known.out else None
    if known.json and produced and os.path.exists(produced):
        with open(produced) as source, open(known.json, "w") as target:
            target.write(source.read())
    sys.exit(status)
# `--suite=typing-frame`: key to frame in a terminal, the Home composer and the omnibar, idle and under load
# (optionally in the STRESS session), scripts/cmux-next/typing-frame-bench.py.
if "--suite=typing-frame" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "typing-frame-bench.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=typing-frame"])
# `--suite=terminal-resize`: Ghostty live resize, idle cursor and STRESS drag (PL-ghostty),
# scripts/cmux-next/bench-terminal-resize.py; --json is its terminal-resize.json too.
if "--suite=terminal-resize" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-terminal-resize.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=terminal-resize"])
if "--suite=anim-perf" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "anim-perf-terminal.py")
    os.execv(sys.executable, [sys.executable, suite] + [a for a in sys.argv[1:] if a != "--suite=anim-perf"])
# `--suite=perf-gate`: the perf counter gate, scripts/cmux-next/perf-gate.py, which the perf cron
# (scripts/cmux-next/perf-cron.py) runs on a fleet GUI host since it left the push and pull request CI
# (2026-10-23). perf-gate.py takes no --tag or --json: it reads the tag from the app and writes <out>/perf-gate.json.
# The step passes whenever that report was written (a broken counter budget is in the report, and a fleet step
# returns its artifact only when it passes); it fails only when the gate wrote no report.
if "--suite=perf-gate" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-gate.py")
    rest, skip, out = [], False, None
    for i, a in enumerate(sys.argv[1:], 1):
        if skip:
            skip = False
        elif a in ("--tag", "--json"):
            skip = True
        elif a != "--suite=perf-gate" and not a.startswith(("--tag=", "--json=")):
            rest.append(a)
            if a == "--out" and i + 1 < len(sys.argv):
                out = sys.argv[i + 1]
    code = subprocess.call([sys.executable, suite] + rest)
    report_path = os.path.join(out or "/tmp/cmux-next-perf-gate", "perf-gate.json")
    print(f"split-spring --suite=perf-gate: perf-gate.py exited {code}; report {report_path}"
          f"{'' if os.path.exists(report_path) else ' (missing)'}", flush=True)
    sys.exit(0 if os.path.exists(report_path) else (code or 1))
# `--suite=cef-resize-sync`: Chromium layer hosting and its resize wait (plans/cmux-next/cef-layer-hosting-DESIGN.md) on
# the step's app: cef-layer-verify.py --mode on and --mode off (debug input; hosted.fork, show.again, pixels, input),
# then cef-resize-sync-bench.py (off, on, on0; light and STRESS). `--label=NAME` names the bench run (api26, api27),
# `--no-bench` runs only the verify. Every part runs; <out>/cef-resize-sync.json records each part's exit, and the
# step fails when a part failed.
if "--suite=cef-resize-sync" in sys.argv:
    here = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    value = lambda name: next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name), None)
    app, tag, out = value("--app"), value("--tag"), value("--out") or "/tmp/cmux-next-cef-resize-sync"
    label = next((a.split("=", 1)[1] for a in argv if a.startswith("--label=")), "")
    parts = [("verify-on", ["cef-layer-verify.py", "--mode", "on"]), ("verify-off", ["cef-layer-verify.py", "--mode", "off"])]
    if "--no-bench" not in argv:
        parts.append(("bench", ["cef-resize-sync-bench.py", "--label", label]))
    results = {}
    for name, (script, *extra) in parts:
        part_out = os.path.join(out, name)
        os.makedirs(part_out, exist_ok=True)
        verify_input = ["--input", "debug"] if script == "cef-layer-verify.py" else []
        print(f"== cef-resize-sync {name}", flush=True)
        results[name] = subprocess.call([sys.executable, os.path.join(here, script), "--app", app, "--tag", tag,
                                         "--out", part_out] + verify_input + extra)
        print(f"== cef-resize-sync {name} exit {results[name]}", flush=True)
    with open(os.path.join(out, "cef-resize-sync.json"), "w") as f:
        json.dump(results, f, indent=1)
    sys.exit(0 if all(code == 0 for code in results.values()) else 1)
# `--suite=launch`: launch time, scripts/cmux-next/bench-startup.py (the launch-time budget that left the pull request
# CI, 2026-10-23). bench-startup.py takes the app's tag from --app, so --tag and --out are dropped; --json stays.
# The step passes whenever the JSON was written (an over-budget launch is in it).
if "--suite=launch" in sys.argv:
    suite = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-startup.py")
    rest, skip, report_path = [], False, None
    for i, a in enumerate(sys.argv[1:], 1):
        if skip:
            skip = False
        elif a in ("--tag", "--out"):
            skip = True
        elif a != "--suite=launch" and not a.startswith(("--tag=", "--out=")):
            rest.append(a)
            if a == "--json" and i + 1 < len(sys.argv):
                report_path = sys.argv[i + 1]
    code = subprocess.call([sys.executable, suite] + rest)
    ok = bool(report_path) and os.path.exists(report_path)
    print(f"split-spring --suite=launch: bench-startup.py exited {code}; report {report_path}{'' if ok else ' (missing)'}", flush=True)
    sys.exit(0 if ok else (code or 1))

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--presses", type=int, default=5)
parser.add_argument("--interval", type=int, default=100, help="ms between presses")
parser.add_argument("--directions", default="right,down")
parser.add_argument("--scrollback", type=int, default=20000)
parser.add_argument("--stream", action="store_true", help="keep output streaming in the first terminal")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the budget rows")
parser.add_argument("--missed-budget", type=int, default=0)
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"split-spring-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ROWS, LAUNCHED = [], []
app = None


def rpc(method, params=None, timeout=30):
    import socket
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def surface_panes(text=False):
    surfaces = rpc("debug.surfaces", {"text": True} if text else None) or {}
    return [p for w in (surfaces.get("windows") or []) if isinstance(w, dict) for p in (w.get("panes") or [])]


def layout_signature():
    """The shown panes: id, kind, tab, focus and frame (an action or a spring changes them)."""
    return json.dumps([(p.get("pane"), p.get("kind"), p.get("selected_tab"), p.get("focused"), p.get("frame"))
                       for p in surface_panes()], sort_keys=True)


MOTION = {"rests": True}


def layout_at_rest(what, timeout=10.0):
    """Every spring at rest (`debug.motion` read: no display link) and the pane layout holding still. A build or
    run whose display links never stop is told once; from then on only the layout is waited on."""
    if MOTION["rests"]:
        rest = lambda: not (rpc("debug.motion", {"action": "read"}) or {}).get("display_links")  # noqa: E731
        if not wait_until(rest, f"{what}: the springs at rest", timeout=timeout, raise_on_timeout=False):
            MOTION["rests"] = False
            print(f"note: display links still ran {timeout:g} s after {what}; from here only the layout is waited on",
                  flush=True)
    try:
        wait_stable(layout_signature, f"the layout after {what}", timeout=timeout, interval=0.05, reads=4)
    except StateWaitTimeout as error:
        print(f"note: {error}", flush=True)


def action(name, args=None, settle=0.0, timeout=60):
    """settle (the old fixed wait, s): wait for the action to change the layout, then for it to come to rest."""
    before = layout_signature() if settle else None
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
    if settle:
        if not wait_until(lambda: layout_signature() != before, f"{name} to change the layout",
                          timeout=max(5.0, settle * 4), raise_on_timeout=False):
            print(f"note: {name} did not change the pane layout", flush=True)
        layout_at_rest(name, timeout=max(10.0, settle * 6))
    return reply


def focused_text():
    for pane in surface_panes(text=True):
        if pane.get("focused") and pane.get("kind") == "terminal":
            return pane.get("text") or (pane.get("surface") or {}).get("text") or ""
    return ""


def wait(check, seconds, step=0.1):
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


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def fresh():
    """A fresh workspace with one fed terminal, focused."""
    action("workspace.newAtBottom", settle=1.5)
    text = f"seq 1 {opts.scrollback}\r" if opts.scrollback else ""
    if opts.stream:
        text += "while :; do echo \"$RANDOM $RANDOM $RANDOM streaming output line\"; sleep 0.004; done\r"
    # The fresh terminal's shell prompt, so the text goes to a running shell.
    wait_until(lambda: focused_text().strip(), "the new terminal's shell prompt", timeout=20, raise_on_timeout=False)
    if text:
        action("terminal.sendText", {"text": text})
    # seq ran to its last line (or the stream, which starts after it, printed).
    marks = ([f"\n{opts.scrollback}\n", f"\n{opts.scrollback}\r"] if opts.scrollback else []) + \
        (["streaming output line"] if opts.stream else [])
    if marks:
        text_now = lambda: "\n" + focused_text() + "\n"  # noqa: E731
        if not wait_until(lambda: any(m in text_now() for m in marks), "seq to fill the scrollback / the stream to start",
                          timeout=30, raise_on_timeout=False):
            print("note: the terminal never showed seq's last line or the stream", flush=True)


def measure(label, verb):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.window_transition", {"action": "start"})
    errors = []
    start = time.time()
    for press in range(opts.presses):
        # A person's rhythm: each press at its slot, however long the one before took to answer.
        delay = start + press * opts.interval / 1000 - time.time()
        if delay > 0:
            time.sleep(delay)  # test harness: presses opts.interval ms apart
        reply = rpc("action.run", {"action": verb, "args": {}, "focus": True, "origin": "script"}, timeout=30)
        if isinstance(reply, dict) and reply.get("error"):
            errors.append(str(reply.get("error")))
    # The split spring lands (rest is under 0.5 s) and the panes' frames hold still.
    layout_at_rest(f"{label}'s presses")
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    moving = sum(1 for s in (motion.get("samples") or []) if s.get("name") == "layout.travel" and (s.get("v") or 0) > 0) \
        if isinstance(motion, dict) else 0
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "errors": errors,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "moving_frames": moving, "refresh_ms": frames.get("refresh_ms"),
        "layout_max_ms": work.get("max_ms"), "layout_p95_ms": work.get("p95_ms"), "layout_p50_ms": work.get("p50_ms"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
    }
    print(f"  {label:<14} moved {moving} frames  frame p50 {result['frames_p50_ms']} p99 {result['frames_p99_ms']} "
          f"max {result['frames_max_ms']} ms missed {result['missed']} (refresh {result['refresh_ms']} ms)  "
          f"layout p95 {result['layout_p95_ms']} max {result['layout_max_ms']} ms  grids {result['grid_reports']}/"
          f"{result['resizes_sent']}  hangs {result['hangs']}  errors {errors}", flush=True)
    return result


def cleanup():
    if os.environ.get("SPLIT_SPRING_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    # CMUX_NEXT_NO_ACTIVATE stays unset, as before bench_launch.py: the app activates and its window is key, so these
    # split-spring rows stay comparable with the earlier ones (an inactive app's terminals are unfocused).
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=(80, 80, 1600, 1000), screen=None, teardown=False,
                     env={"CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
                          "CMUX_NEXT_NO_ACTIVATE": None})
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    print(f"launched pid {app.pid} macOS {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}",
          flush=True)
    # Launch work settles: a terminal pane is shown and the layout comes to rest.
    wait_until(lambda: any(p.get("kind") == "terminal" for p in surface_panes()), "the first terminal pane", timeout=30,
               raise_on_timeout=False)
    layout_at_rest("launch", timeout=30)
    report = {"tag": TAG, "stream": opts.stream, "scrollback": opts.scrollback, "presses": opts.presses,
              "interval_ms": opts.interval, "runs": []}
    for direction in opts.directions.split(","):
        verb = {"right": "splitRight", "down": "splitDown"}[direction]
        for index in range(opts.rounds):
            fresh()
            run = measure(f"{direction} #{index}", verb)
            run.update(direction=direction)
            report["runs"].append(run)
            if index == 0:
                rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{direction}-after.png")})
            row(f"{direction} #{index}: the splits animated (layout springs moved)", "> 0 frames",
                str(run["moving_frames"]), run["moving_frames"] > 0)
            row(f"{direction} #{index}: every press split", "no refusal", str(run["errors"]), not run["errors"])
            sent, budget = run["resizes_sent"], opts.presses + 1
            row(f"{direction} #{index}: grids sent to the PTY owner" + ("" if opts.gate else " (info)"),
                f"<= {budget}", str(sent), sent is not None and sent <= budget or not opts.gate)
            missed = run["missed"]
            row(f"{direction} #{index}: missed frames" + ("" if opts.gate else " (info)"),
                f"<= {opts.missed_budget}", str(missed), missed is not None and missed <= opts.missed_budget or not opts.gate)
            if opts.json:
                json.dump(report, open(opts.json, "w"), indent=1)
            time.sleep(0.5)  # test harness: idle between runs
    print("\n== summary (median over rounds)")
    for direction in opts.directions.split(","):
        runs = [r for r in report["runs"] if r["direction"] == direction]

        def med(key):
            values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
            return values[len(values) // 2] if values else None
        print(f"  {direction:<5} x{opts.presses} moved {med('moving_frames')} frame p50 {med('frames_p50_ms')} p99 "
              f"{med('frames_p99_ms')} max {med('frames_max_ms')} ms missed {med('missed')}  layout p95 {med('layout_p95_ms')} "
              f"max {med('layout_max_ms')} ms  grids {med('grid_reports')}/{med('resizes_sent')}  hangs {med('hangs')}", flush=True)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


try:
    main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
