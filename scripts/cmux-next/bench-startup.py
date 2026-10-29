#!/usr/bin/env python3
"""Startup phase bench for cmux-next: app launch to the first live terminal frame.

Launches a tagged build with a clean environment (no activation, windows on
the last screen, a scratch cmux.json) and reads every launch mark as an
event: the app writes one `<name> <ms-since-process-start>` line per mark to
the pipe named by CMUX_NEXT_LAUNCH_MARKS_FD (CmuxNextLaunch/LaunchMarkSink.swift).
Nothing here polls: it blocks on the pipe (select with the run deadline),
on waitpid for the app, and on kqueue NOTE_EXIT for the tag's daemon.

  cold  no daemon for the tag runs: the app starts it (`server ensure`);
        its terminal hosts were stopped too (a reboot or logout)
  restart  only the daemon was stopped; its terminal hosts live on and the
        new daemon adopts them (a crash or a version handoff)
  warm  a priming launch leaves the daemon running (keep sessions); only
        the app quits before the measured launch
  daemon  the daemon side alone, with the tag's bundled cmux-tui: `--version`
        (process spawn), `server ensure` after only the owner was stopped
        (state kept, terminal hosts adopted), `server ensure` on an empty
        state root, then one connection's identify and snapshot round trips

  scripts/cmux-next/bench-startup.py --tag nxboot [--tag other] [--runs 5]
      [--mode cold --mode warm] [--profile empty|realistic] [--json out.json]
  scripts/cmux-next/bench-startup.py --app "/path/cmux DEV launch-1.app" ...

--app runs a fleet artifact staged anywhere (its tag comes from the
`cmux DEV <tag>.app` name, as the app's own LaunchIdentity reads it; a
--tag that names the same tag runs it once).
--profile empty deletes the tag's daemon, agent and sidebar state before
each run (a first launch on a new Mac; cold mode only). --profile realistic
seeds one priming launch with REALISTIC_WORKSPACES workspaces of three
terminal tabs and a split, then splits the selected pane and opens an agent
chat in it, so the measured launch restores a full sidebar, a terminal and
an agent pane. Its runs wait for the agent pane's handshake as well as the
first terminal frame.

Several tags run interleaved (A run 1, B run 1, A run 2, ...), so machine
load affects them alike. Prints the load average and, per tag and mode, one
row per mark: p50, p95, p99 and max ms since process start (perf_stats.summary:
linear interpolation, the lab's one percentile definition), and the p50 gap
from the previous row. Kills only processes started from the tag's DerivedData.

--purge empties the file cache with `sudo -n /usr/sbin/purge` before each
--mode cold launch, after every stop and priming launch, so the cold launch has
no page in memory. Chrome's lab does the same on a Mac before a cold story
(catapult telemetry/internal/platform/mac_platform_backend.py
FlushEntireSystemCache runs `purge` elevated and asserts it succeeded). The lab
hosts get the single-command sudoers entry from `host-setup.sh
--grant-privileged` (decision D3). `sudo -n` never prompts: the bench checks the
right (`sudo -n -l`) before any launch and refuses with sudo's reason (exit 2)
when it is missing, because without it "cold" only means "daemon stopped".
--temperature cold is --purge with --mode cold only and the summary counting
the runs whose `launch.temperature` read cold; --temperature warm purges nothing.

--after-reboot is the T2 launch after reboot: one --mode cold run with no
purge, refused (exit 2) unless the Mac booted less than AFTER_REBOOT_MAX_UPTIME_S
ago and no process of the tag runs yet. A realistic profile must be seeded
before the reboot: seeding launches the app and would page it in.

--out DIR writes cmux-perf-result/v1 through bench_launch.BenchApp.record, one
file per series: `launch.<mode>.<mark>` (ms since process start) for
result_marks(profile), `launch.<mode>.<mark>.missing_runs` (count) and, for cold,
`launch.cold.not_cold_runs`: runs the build itself classified other than cold
(task 007's launch.temperature) are left out of the cold samples, so a warm
launch is never reported as cold. A cold result needs --purge, --temperature
cold or --after-reboot, and --out needs a --profile. The empty profile's
measured launch is a first launch, which shows the agent New Tab page, so its
first content is `first_content` (the first live terminal frame or the agent
page's handshake, whichever came first); the realistic profile restores a
terminal and writes `first_terminal_frame`. The story is `launch-<mode>` (empty
profile), `launch-<mode>-realistic` or `launch-after-reboot` (empty profile
only: a realistic --after-reboot result needs --story), or --story, or the
perf-lab runner's PERF_LAB_STORY; the features come from `features.list`, read
in each tag's first measured launch that answers it before it quits (a launch
that never drew too, so its missing_runs still record). Under the perf-lab
runner that launch is also validated again with the tag's pids
(BenchApp.validate_lab_host: host_env.py's network-egress and the other checks). Lab stories:
scripts/perf-lab/stories.d/launch-cold.json, launch-cold-realistic.json,
launch-warm-realistic.json, launch-after-reboot.json, and launch-warm.json.

--corpus MANIFEST launches from a corpus launch story's saved session instead of a
--profile (perf-corpus/launch-restore.json, task p12-perf-process-121; the story's
module, scripts/perf-lab/corpus/launch_restore.py, says how). Seeding imports the
story's layout snapshot in a fresh bench launch once per layout digest and reads its
checkpoint digests (the state at quit); each launch gets the seeding's window (the bench
size on the main display) and config, waits for the first live terminal frame and the
live sidebar rows, then puts the window where seeding left it and reads the restored
digests before it quits. Results are `corpus.<id>.<mode>.<mark>` in session
`corpus:<id>` (story `<id>-<mode>`, or --story), plus
`corpus.<id>.<mode>.checkpoint_mismatch_runs`: a launch that restored another state
than the recorded checkpoint (else the state at quit) fails the bench (exit 1).
--capture records the agreed digests in the manifest.
Lab stories: launch-restore-cold.json and launch-restore-warm.json.

Value marks (tasks 007, 108): `launch.temperature`, `launch.pageins_run_loop_start`,
`launch.pageins_first_frame`, `launch.main_cpu_ms` and `launch.interrupted`
arrive on the same pipe as `<name> <value>` (a number, true/false, or a name).
So do p08-startup-068's `launch.first_frame_threads`, `launch.first_frame_runtime_threads`
and `launch.first_frame_ghostty_threads` (Debug and bench builds: the threads right after the
first frame, the native runtime threads among them, target 0, and libghostty's), and
p08-startup-064's `launch.sidebar_rows_built` and `launch.sidebar_rows_visible`:
the sidebar row views built before startup_complete against the rows its clip showed
(sent right after `startup_complete`, so they need --startup-complete).
`launch.views_built` (p08-startup-065: the pane content views made before
startup_complete, sent just before it; == the visible panes; --startup-complete
waits for it) arrives the same way.
They are not times: no table row, gap or --order term. Task 007 can also send
the temperature as the instant mark `launch.temperature.<name>`; it reads the
same. Each run's line and the summary print them when the build sends them.

--tag finds the tag's newest bundle in DerivedData's Build/Products/Debug or
Build/Products/Release (where `reload.sh --config release|bench|bench-checks`
puts it). --require-optimized refuses (exit 2), before any launch, a build that
is not optimized, by bench_launch.build_config: reload.sh's Info.plist stamp
CMUXBuildConfiguration, checked against the executable. `release` and `bench`
pass; `debug`, `bench-checks` (its blocking detector costs time on every
checked call), a stamp the executable contradicts, and an unstamped bench-hooks
bundle are refused. With --tag it takes the tag's newest optimized bundle.
With --after-reboot it reads only the Info.plist stamp and the bundle's file
names before the launch (scanning the executable would page it in, and the
launch would not be the first since the boot), then checks the stamp against
the executable after the launch, before any result is written.

--order FIRST<SECOND[<THIRD...] checks each pair of a chain in every run. A
term A|B is any one of the marks (the earliest that arrived): a launch marks
launch.agent_page_warmup when the warm-up made its page,
launch.agent_page_warmup_not_needed when an agent page had started WebKit first, and
launch.agent_page_warmup_chromium when agent pages open in Chromium, so it made no
WebKit page (p13-webui-046).
"""
import argparse
import glob
import json
import os
import re
import shutil
import select
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The shared launch helper's socket paths and session check (bench_launch.py). Not its bench env: this bench times
# the launch itself, with the agent pane's real handshake and the account's Chief, as a person's launch runs.
from bench_launch import (  # noqa: E402
    BUILD_CONFIG_KEY, PERF_LAB, BenchApp, LaunchError, RecordError, build_config, bundle_kind, features_snapshot,
    finder_limits, info_plist, limits_line, load_by_path, require_gui_session, rpc_at, socket_candidates)

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
# The product folders a tagged build lands in: reload.sh's default Debug, and Release for --config release, bench
# and bench-checks (BUILD_CONFIGURATION=Release).
PRODUCT_CONFIGS = ("Debug", "Release")
FINAL_MARK = "first_terminal_frame"
AGENT_MARK = "agent_pane.handshake_end"
SIDEBAR_MARK = "sidebar_rows_shown"
# The daemon's own start (identify {startup_marks}), measured in the daemon from its main() and
# recorded by the app after the first snapshot; daemon_steps_summary names the slowest step.
DAEMON_STEPS = [
    ("daemon.main_start", "daemon: main()"),
    ("daemon.config_loaded", "daemon: config loaded"),
    ("daemon.owner_prepared", "daemon: owner prepared"),
    ("daemon.socket_bound", "daemon: session socket bound"),
    ("daemon.mux_restored", "daemon: registry and terminals restored"),
    ("daemon.owner_event_loop", "daemon: owner event loop"),
    ("daemon.websocket_ready", "daemon: WebSocket step done"),
    ("daemon.launch_snapshot_writer_started", "daemon: launch snapshot writer"),
    ("daemon.lifecycle_ready", "daemon: lifecycle ready"),
    ("daemon.first_identify_served", "daemon: first identify answered"),
]

# Rows in launch order; a mark a build does not emit is left out.
MARKS = [
    ("main_start", "process start -> main()"),
    ("main.environment_frozen", "main: environment prepared and frozen"),
    ("main.warmup_started", "main: launch warm-up started"),
    ("main.app_environment", "main: app environment and state paths"),
    ("main.launch_reads", "main: launch reads posted"),
    ("main.prestart", "main: daemon prestart"),
    ("main.delegate", "main: launch order and delegate"),
    ("main.nsapp", "main: NSApp set up"),
    ("main.run", "main: run()"),
    # The launch thread's icon pack and catalog decode; the first tab or sidebar icon reads both.
    ("icons_decoded", "launch thread: icon pack and catalog decoded"),
    ("run_loop_start", "main run loop started"),
    ("did_finish_launching_start", "AppKit ready (applicationDidFinishLaunching)"),
    ("dfl.settings_wait", "dfl: settings launch read in hand (waited on a cold disk)"),
    ("dfl.settings_read", "dfl: settings read"),
    ("dfl.theme", "dfl: Ghostty runtime and theme"),
    ("crash.sentry_start", "crash reporting: SentrySDK.start begins"),
    ("crash.sentry_started", "crash reporting: SentrySDK.start returned (p08-startup-032)"),
    ("services.crash_reporting", "services: crash reporting"),
    ("services.cache", "services: cloud, feed, ssh, tab cache"),
    ("services.windows", "services: window manager"),
    ("services.palette_updater", "services: palette, update sheet"),
    ("dfl.services", "dfl: services"),
    ("dfl.bind", "dfl: actions bound"),
    ("dfl.settings", "dfl: settings and control"),
    ("dfl.menu", "dfl: main menu"),
    ("daemon.binary_resolved", "daemon binary resolved"),
    ("launch_snapshot_applied", "cached layout read (launch snapshot)"),
    ("dfl.daemon_cloud_updater", "dfl: daemon, cloud, updater"),
    ("dfl.first_window_hooks", "dfl: first window hooks"),
    ("dfl.home_history", "dfl: home, bookmarks, history"),
    ("window_display", "first window ordered on screen"),
    # The front window's saved picture as the first frame (savedWindowPicture), or why not.
    ("launch_picture_shown", "first window shown as its saved picture"),
    ("launch_picture_mismatch", "saved picture's meta did not match the window (today's path)"),
    ("launch_picture_removed", "saved picture left the live window"),
    ("launch_snapshot_shown", "cached layout window made"),
    ("dfl.windows", "dfl: windows restored"),
    ("did_finish_launching_end", "applicationDidFinishLaunching end"),
    ("first_window_frame_committed", "first window frame committed"),
    ("first_idle", "main run loop first idle after launch"),
    ("launch.non_paint_services", "non-paint services started (updater, ssh, reach)"),
    ("launch.post_window_warmups", "warm-ups started (Chromium, spares, page hosts)"),
    ("launch.agent_page_warmup", "agent page WebKit warm-up made its page"),
    ("launch.agent_page_warmup_not_needed", "agent page WebKit warm-up not needed (a page started WebKit)"),
    ("launch.agent_page_warmup_chromium", "agent page WebKit warm-up not made (agent pages open in Chromium)"),
    ("control.serving", "app control socket accepting (p08-startup-019)"),
    # The daemon connect milestones (DaemonConnectMarks), once each per launch; connect_started
    # lands in main(), before main.prestart (the table orders rows by time).
    ("daemon.connect_started", "daemon connect started (prestart in main)"),
    ("daemon.connect_start", "first connect attempt"),
    ("daemon.status_start", "server status spawn"),
    ("daemon.status_end", "server status exit"),
    ("daemon.login_env_start", "login env wait (cold)"),
    ("daemon.login_env_end", "login env ready (cold)"),
    ("daemon.ensure_start", "server ensure spawn (cold)"),
    ("daemon.ensure_end", "daemon ready (cold)"),
    ("daemon.spawned", "daemon spawned by the first connect (cold)"),
    *DAEMON_STEPS,
    ("daemon.endpoint_resolved", "endpoint resolved"),
    ("daemon.socket_connected", "control socket connected"),
    ("daemon.identify_end", "identify answered"),
    ("daemon.handshake_end", "handshake done (client info, subscribe)"),
    ("daemon.identified", "daemon identified (first connect)"),
    ("daemon_connected", "connection published"),
    ("daemon.snapshot_start", "snapshot requested"),
    ("daemon.snapshot_end", "snapshot received"),
    ("daemon.snapshot_received", "first snapshot received (prefetched)"),
    ("daemon.first_tree_applied", "first live tree applied"),
    ("daemon_snapshot_loaded", "windows restored from live tree"),
    ("first_terminal_surface_created", "first Ghostty surface"),
    ("terminal.attach_start", "first terminal attach started"),
    ("terminal.attach_end", "first terminal attached (replay)"),
    ("first_terminal_content", "first terminal content decoded"),
    ("first_terminal_content_applied", "first content in a surface"),
    (FINAL_MARK, "first live terminal frame"),
    ("first_page_frame", "first page painted in a visible pane (agent or internal page)"),
    ("first_live_content_frame", "first live content frame (terminal or page, shown)"),
    ("sidebar_rows_shown", "sidebar rows shown"),
    ("reveal.sidebar", "sidebar revealed"),
    ("reveal.tabs", "tab strips revealed"),
    ("reveal.pane", "pane content revealed"),
    ("reveal.home", "Home revealed"),
    ("agent_pane.view_created", "first agent pane view made"),
    ("agent_pane.page_loaded", "agent page loaded (didFinish)"),
    ("agent_pane.handshake_start", "agent page asked for its handshake"),
    (AGENT_MARK, "agent pane handshake answered"),
    # The last quit's pane images, read off the main thread from main() (slice c): a `missed` row means a pane
    # asked before its read ended and showed its placeholder.
    ("agent_pane.launch_images_read", "saved agent pages read and decoded"),
    ("agent_pane.launch_image_missed", "an agent pane asked before its read ended"),
    ("agent_pane.launch_image_shown", "an agent pane's saved page shown"),
    ("terminal.launch_frames_read", "saved terminal frames read and decoded"),
    ("terminal.launch_frame_missed", "a terminal asked before its read ended"),
    ("terminal.launch_frame_shown", "a terminal's saved frame shown"),
    # The front window's saved picture, read and decoded on the files lane from main().
    ("launch_picture_decoded", "front window's saved picture read and decoded"),
    ("launch_picture_missed", "the first window asked before its picture's read ended"),
    ("launch_picture_dropped", "the front window's picture untaken at startup complete"),
    # StartupScheduler's refs are all released (or its 10 s failsafe fired); --startup-complete
    # waits for it after the first content.
    ("startup_complete", "startup complete (StartupScheduler)"),
]
# Chrome's startup milestones (components/startup_metric_utils/browser/startup_metric_utils.h): --milestones
# requires each in every run, and each pair below (the ones every launch orders the same way) when both landed.
# startup_complete is not required: it comes after the first content, as late as StartupScheduler's 10 s failsafe;
# --startup-complete waits for it.
MILESTONES = ["main_start", "run_loop_start", "window_display", "first_window_frame_committed", "first_idle",
              "first_live_content_frame"]
MILESTONE_ORDER = [
    "main_start<run_loop_start",
    "run_loop_start<first_idle",
    "did_finish_launching_end<first_idle",
    "window_display<launch_snapshot_shown",
    "window_display<first_window_frame_committed",
    "first_window_frame_committed<startup_complete",
    "first_live_content_frame<startup_complete",
]
STARTUP_COMPLETE = "startup_complete"
# P1, main() on the main thread (p08-startup 033): from its first mark to NSApplication.run, per run.
MAIN_SPAN = ("main_start", "main.run")
MAIN_BUDGET_MS = 10.0
# The completion's reason, an instant time mark `startup_complete.<reason>` sent with it (LaunchOrder).
COMPLETION_INSTANT = STARTUP_COMPLETE + "."
FAILSAFE = "failsafe"
REALISTIC_WORKSPACES = 24
# Launch work that must start only after the first window frame (perf-launch-memory): checked
# with --order, and always in budget mode (any --budget, as the CI launch gate runs).
LAUNCH_ORDER = [
    "first_window_frame_committed<launch.non_paint_services",
    "first_window_frame_committed<launch.post_window_warmups",
    "first_window_frame_committed<launch.agent_page_warmup|launch.agent_page_warmup_not_needed|launch.agent_page_warmup_chromium",
]

# Marks whose value is not a time (tasks 007, 108; startup-queue.py's VALUE_MARKS): never a row, a gap or an
# --order term.
TEMPERATURE = "launch.temperature"
# Task 007 sends the temperature as an instant time mark, `launch.temperature.<name> <ms>`, at run_loop_start.
TEMPERATURE_INSTANT = TEMPERATURE + "."
# The page-ins the temperature is classified from (run_loop_start), and the separate count at the first frame.
PAGEINS_RUN_LOOP = "launch.pageins_run_loop_start"
PAGEINS = "launch.pageins_first_frame"
MAIN_CPU = "launch.main_cpu_ms"
INTERRUPTED = "launch.interrupted"
# The sidebar row views built before startup_complete, and the rows its clip showed then.
SIDEBAR_ROWS_BUILT = "launch.sidebar_rows_built"
SIDEBAR_ROWS_VISIBLE = "launch.sidebar_rows_visible"
# The off-screen rows a launch may build (SidebarModel.LaunchRows.Report.slack).
SIDEBAR_ROWS_SLACK = 2
# How long a launch that completed waits for the sidebar's row counts, sent right after startup_complete.
SIDEBAR_ROWS_WAIT_S = 0.5
# The pane content views made before startup_complete (`launchVisiblePanesOnly`): == visible panes.
# The app sends it just before startup_complete, so a --startup-complete run has it.
VIEWS_BUILT = "launch.views_built"
# p08-startup-068 (LaunchThreadCensus, Debug and bench builds): the process's threads right after the first frame,
# the threads of a native runtime no first frame needs (iroh's tokio pool; target 0), and libghostty's threads.
FIRST_FRAME_THREADS = "launch.first_frame_threads"
FIRST_FRAME_RUNTIME_THREADS = "launch.first_frame_runtime_threads"
FIRST_FRAME_GHOSTTY_THREADS = "launch.first_frame_ghostty_threads"
THREAD_MARKS = (FIRST_FRAME_THREADS, FIRST_FRAME_RUNTIME_THREADS, FIRST_FRAME_GHOSTTY_THREADS)
# How long a launch that reached its content waits for the thread counts, sent from a cpu lane after the committed
# first frame (never at a missed reveal deadline); a build without them, or a launch that drew no frame, costs this.
THREAD_MARKS_WAIT_S = 1.0
# p08-startup-092 (LaunchValueMarks): the main thread's wait for the warm-up thread's action catalog build at the
# registry's read (target 0 in every run), and its whole time in that read; microseconds.
ACTION_CATALOG_MAIN_WAIT = "launch.action_catalog_main_wait_us"
ACTION_CATALOG_MAIN_READ = "launch.action_catalog_main_read_us"
VALUE_MARKS = (TEMPERATURE, PAGEINS_RUN_LOOP, PAGEINS, MAIN_CPU, INTERRUPTED, SIDEBAR_ROWS_BUILT, SIDEBAR_ROWS_VISIBLE,
               VIEWS_BUILT, *THREAD_MARKS, ACTION_CATALOG_MAIN_WAIT, ACTION_CATALOG_MAIN_READ)
# Percentiles printed after p50 (perf_stats.summary).
PERCENTILES = (95, 99)

# The single command the lab's sudoers entry allows (host-setup.sh --grant-privileged, decision D3).
PURGE = "/usr/sbin/purge"
# --after-reboot refuses a Mac up longer than this: the T2 runner starts the story right after the reboot's login.
AFTER_REBOOT_MAX_UPTIME_S = 600
TARGET_MARK = "first_window_frame_committed"
# The empty profile's first content: a first launch shows the agent New Tab page, not a terminal (one_run), so its
# result is whichever of the two arrived first.
FIRST_CONTENT = "first_content"


class Refused(SystemExit):
    """A run that cannot measure what was asked (purge refused, an unoptimized build): the reason, exit 2."""

    def __init__(self, message):
        print(f"bench-startup: {message}", file=sys.stderr, flush=True)
        super().__init__(2)


def mark_value(text):
    """A mark line's value: ms for a time mark; for a value mark, its number, true/false or name."""
    try:
        return float(text)
    except ValueError:
        return {"true": True, "false": False}.get(text.lower(), text)


def parse_mark_line(line):
    """`(name, value)` of one `<name> <value>` line from the mark pipe, or None for a line without both."""
    name, _, value = line.decode(errors="replace").strip().partition(" ")
    return (name, mark_value(value.strip())) if name and value.strip() else None


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def spread(values):
    """p50 (as --budget reads it), p95, p99 and max, from perf_stats.summary."""
    summary = perf_stats.summary(values)
    return {column: summary[column] for column in ("p50", *(f"p{p}" for p in PERCENTILES), "max")}



def temperature_name(value):
    """A temperature as the build names it (`cold`, `warm`, `lukewarm`: task 007 sends names, never a number); any
    other value is shown as it came."""
    return f"{value:g}" if is_number(value) else str(value).lower()


def run_temperature(marks):
    """The run's temperature name: a `launch.temperature <value>` mark, else task 007's instant mark
    `launch.temperature.<name>`; None when the build sends neither."""
    if TEMPERATURE in marks:
        return temperature_name(marks[TEMPERATURE])
    names = sorted(name[len(TEMPERATURE_INSTANT):] for name in marks if name.startswith(TEMPERATURE_INSTANT))
    return names[0].lower() if names else None


def completion_reason(marks):
    """The run's startup completion reason (`startup_complete.<reason>`), or None when it never completed."""
    names = sorted(name[len(COMPLETION_INSTANT):] for name in marks if name.startswith(COMPLETION_INSTANT))
    return names[0] if names else None


def completion_summary(runs):
    """The completion reasons over the runs, the failsafe ones counted (p08-startup-012: never failsafe)."""
    total = len(runs)
    read = [reason for reason in map(completion_reason, runs) if reason is not None]
    if not read:
        return f"  {STARTUP_COMPLETE}: missing in all {total} runs (no --startup-complete, or the build has no scheduler)"
    counts = sorted(((read.count(reason), reason) for reason in set(read)), key=lambda item: (-item[0], item[1]))
    line = f"  {STARTUP_COMPLETE}: " + ", ".join(f"{reason} {count}" for count, reason in counts) + f" of {total} runs"
    if len(read) < total:
        line += f" ({total - len(read)} without it)"
    return line + f"; {read.count(FAILSAFE)} of {total} by the {FAILSAFE}"


def interrupted(run):
    """startup-queue.py's rule: present and not false or null; a mark at 0 ms counts."""
    value = run.get(INTERRUPTED)
    return value is not None and value is not False


# Apps given with --app, by tag; other tags are DerivedData builds, each resolved once into TAGGED (tagged_app).
APPS = {}
TAGGED = {}


def app_tag(path):
    """The tag of a staged `cmux DEV <tag>.app` (LaunchIdentity.taggedAppName)."""
    name = os.path.basename(os.path.normpath(path))
    match = re.fullmatch(r"cmux DEV (.+)\.app", name)
    if not match:
        raise SystemExit(f"{path}: expected a `cmux DEV <tag>.app` bundle")
    return re.sub(r"[^a-z0-9-]", "-", match.group(1).lower())


def bundle_root(tag):
    """The path every process of the tag starts from, as a pgrep pattern."""
    if tag in APPS:
        # /tmp is /private/tmp: a process may show either spelling.
        path = re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", APPS[tag].removeprefix("/private"))
        return f"(/private)?{path}" if path.startswith("/tmp/") else path
    return f"DerivedData/cmux-{tag}/Build/Products/({'|'.join(PRODUCT_CONFIGS)})/cmux DEV"


def executable(app):
    """The bundle's main executable: a Release product names it differently (cmux, not cmux DEV); the bundle says."""
    name = info_plist(app).get("CFBundleExecutable")
    if not name:
        raise SystemExit(f"{app}: its Info.plist names no CFBundleExecutable")
    return os.path.join(app, "Contents/MacOS", name)


def tagged_apps(tag):
    """The tag's DerivedData bundles in every product folder, the newest stamp first (the Info.plist, which reload.sh
    writes when it stages the tagged app)."""
    apps = [app for config in PRODUCT_CONFIGS
            for app in glob.glob(f"{DERIVED}/cmux-{tag}/Build/Products/{config}/cmux DEV*.app")
            if os.path.isfile(os.path.join(app, "Contents/Info.plist"))]
    return sorted(apps, key=lambda app: os.path.getmtime(os.path.join(app, "Contents/Info.plist")), reverse=True)


def tagged_app(tag, optimized=False, evidence=None):
    """The tag's newest DerivedData bundle. With `optimized`, its newest optimized one by `evidence(app)` (default
    executable_evidence), so a later Debug rebuild of the tag never hides its bench build; the newest when it has
    none, for require_optimized to refuse by name."""
    apps = tagged_apps(tag)
    if not apps:
        raise SystemExit(f"no tagged app for {tag} under {DERIVED}/cmux-{tag}/Build/Products/"
                         f"({' or '.join(PRODUCT_CONFIGS)})")
    if optimized:
        evidence = evidence or executable_evidence
        return next((app for app in apps if evidence(app)[0]), apps[0])
    return apps[0]


def app_path(tag):
    if tag in APPS:
        return APPS[tag]
    if tag not in TAGGED:
        TAGGED[tag] = tagged_app(tag)
    return TAGGED[tag]


def app_binary(tag):
    return executable(app_path(tag))


def pgrep(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) != os.getpid()]


def tag_pids(tag):
    """The tag's app, daemon and terminal hosts (started from its bundle)."""
    return pgrep(bundle_root(tag))


def app_pids(tag):
    return pgrep(f"{bundle_root(tag)}.*/Contents/MacOS/")


def wait_exit(pids, timeout):
    """Blocks until every pid exited (kqueue NOTE_EXIT) or the timeout passes."""
    queue = select.kqueue()
    live = set()
    for pid in pids:
        try:
            queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                         select.KQ_NOTE_EXIT)], 0, 0)
            live.add(pid)
        except (ProcessLookupError, OSError):
            pass  # already gone
    deadline = time.monotonic() + timeout
    while live:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        for event in queue.control(None, len(live), remaining):
            live.discard(event.ident)
    queue.close()
    return not live


def stop(pids, timeout=10):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if not wait_exit(pids, timeout):
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wait_exit(pids, 5)


def launch_environment(scratch, marks_fd, extra_env=None):
    """The environment of one measured launch: an isolated launch on the last screen with the scratch cmux.json,
    its marks on `marks_fd`; `extra_env` wins."""
    return {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
        "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
        "CMUX_NEXT_LAUNCH_MARKS_FD": str(marks_fd),
        **({"CMUX_NEXT_HANG_THRESHOLD_MS": str(HANG_THRESHOLD_MS)} if HANG_THRESHOLD_MS else {}),
        **(extra_env or {}),
    }


class Launch:
    """One app process whose launch marks arrive on a pipe."""

    def __init__(self, tag, scratch, extra_env=None):
        read_fd, write_fd = os.pipe()
        env = launch_environment(scratch, write_fd, extra_env)
        with finder_limits() as changed:  # the limits a Finder launch gets (bench_launch.py, Resource limits)
            self.process = subprocess.Popen([app_binary(tag)], env=env, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(write_fd,))
        print(f"bench-startup: app limits {limits_line(changed)}", file=sys.stderr, flush=True)
        os.close(write_fd)
        self.read_fd = read_fd
        self.buffer = b""
        self.marks = {}

    def wait_for(self, mark, timeout, any_of=False):
        """Reads marks until `mark` (or every mark of a list; with `any_of`,
        one of them) arrived, the app exits (EOF) or the timeout."""
        wanted = [mark] if isinstance(mark, str) else list(mark)
        landed = any if any_of else all
        deadline = time.monotonic() + timeout
        while not landed(name in self.marks for name in wanted):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.read_fd], [], [], remaining)
            if not ready:
                return False
            chunk = os.read(self.read_fd, 65536)
            if not chunk:
                return False
            self.buffer += chunk
            *lines, self.buffer = self.buffer.split(b"\n")
            for parsed in filter(None, map(parse_mark_line, lines)):
                self.marks.setdefault(*parsed)
        return True

    def quit(self):
        """Quits the app only; the daemon keeps running (keep sessions)."""
        os.close(self.read_fd)
        stop([self.process.pid], timeout=20)
        self.process.wait()


RUN_TAGS = []
# --focus: the realistic profile's focused pane at quit ("agent" or "terminal").
SEED_FOCUS = "agent"
# --chat-pane: with --focus terminal, the chat's pane (first or last).
SEED_CHAT_PANE = "last"
# --hangs: main-thread stalls over this many ms are recorded with stacks (debug.hangs).
HANG_THRESHOLD_MS = None
# --corpus: the corpus launch story (launch_restore.Story) whose saved session every launch restores.
CORPUS = None
# --startup-complete: each launch also waits (within --timeout) for `startup_complete` and its reason.
WAIT_STARTUP_COMPLETE = False
# The --order terms (and LAUNCH_ORDER's in budget mode): each launch also waits (within --timeout)
# for one mark of each term, since afterStartup posts mark after the first content.
ORDER_MARKS = []
# --milestones: each run that reached its first frames also waits for every MILESTONES mark, within the same timeout.
WAIT_MILESTONES = False


def state_directories(tag):
    """Where a tagged build keeps its sessions: daemon state and the sidebar
    snapshot, agent sessions (acpmux), Home's memory."""
    home = os.path.expanduser("~")
    return [os.path.join(home, "Library/Application Support/cmux/tags", tag),
            os.path.join(home, ".acpmux/builds", "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", tag.lower()).strip(".")),
            # a copy of an untagged build named "cmux DEV <tag>.app" (its tag comes from the name)
            os.path.join(home, ".acpmux/builds", "com.cmuxterm.app.debug--" + re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")), os.path.join(home, ".cmux/mux/tags", tag)]


def reset_state(tag):
    """A first launch: no daemon, no saved workspaces, sidebar or agent sessions."""
    stop(tag_pids(tag))
    for directory in state_directories(tag):
        shutil.rmtree(directory, ignore_errors=True)


def daemon_socket(tag, timeout=20):
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = glob.glob(os.path.join(tmp, "cmux-tui-*", f"cmux-app-{tag}.sock"))
        if found:
            return found[0]
        time.sleep(0.2)
    raise SystemExit(f"tag {tag}: no daemon socket")


def app_client(tag, timeout=30):
    from bench_cli_storm import Client  # noqa: E402
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for path in socket_candidates(tag):  # the state folder first, then the /tmp link
            try:
                return Client(path, timeout=10)
            except OSError:
                pass
        time.sleep(0.2)
    raise SystemExit(f"tag {tag}: control socket did not answer at {', '.join(socket_candidates(tag))}")


def app_tab_id(app, workspace_name, timeout, wanted=lambda tab: True):
    """The app's id for the first wanted tab of a workspace; the daemon's listing names tabs differently."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        topology = (app.call("snapshot.get").get("result") or {}).get("topology") or {}
        for workspace in topology.get("workspaces", []):
            if workspace.get("name") != workspace_name:
                continue
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if wanted(tab):
                            return str(tab.get("id") or "")
        time.sleep(0.2)
    return ""


def project_panes(app, name="project-01"):
    """The panes of a seeded workspace, in the app's screen order."""
    topology = (app.call("snapshot.get").get("result") or {}).get("topology") or {}
    return [pane for workspace in topology.get("workspaces", []) if workspace.get("name") == name
            for screen in workspace.get("screens", []) for pane in screen.get("panes", [])]


def seed_realistic(tag, scratch, timeout):
    """Fills the tag's state with a day's work (see --profile realistic) and
    leaves the daemon running."""
    from bench_cli_storm import Client  # noqa: E402
    reset_state(tag)
    prime = Launch(tag, scratch)
    try:
        if not prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True):
            raise SystemExit(f"tag {tag}: the seeding launch never drew a terminal")
        daemon = Client(daemon_socket(tag), timeout=10)

        def workspaces():
            return {w["id"]: w for w in daemon.call("list-workspaces", cmd_key="cmd")["data"]["workspaces"]}

        for index in range(REALISTIC_WORKSPACES):
            before = workspaces()
            created = daemon.call("new-workspace", {"name": f"project-{index + 1:02d}"}, cmd_key="cmd")
            if not created.get("ok"):
                raise SystemExit(f"tag {tag}: new-workspace failed: {created.get('error')}")
            workspace = next(w for key, w in workspaces().items() if key not in before)
            pane = workspace["screens"][0]["panes"][0]
            for _ in range(2):
                daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
            daemon.call("split", {"pane": pane["id"], "dir": "right"}, cmd_key="cmd")
        daemon.close()
        # The agent chat goes beside a terminal of the first seeded workspace.
        app = app_client(tag)
        focus_tab = app_tab_id(app, "project-01", timeout)
        if not focus_tab:
            print(f"  {tag}: the app never listed a tab in project-01", file=sys.stderr)
        steps = [("palette.goToTab", {"kind": "tab", "id": focus_tab}), ("splitRight", None)]
        if SEED_FOCUS == "terminal":
            # The chat goes in the last pane, or with "first" in the first
            # one, which a launch that ignores the saved focus would pick.
            index = 0 if SEED_CHAT_PANE == "first" else -1
            steps.append(("palette.goToTab", lambda: {"kind": "tab", "id": project_panes(app)[index]["tabs"][0]["id"]}))
        steps.append(("palette.newAgentChat", None))
        agent = True
        for action, target in steps:
            target = target() if callable(target) else target
            reply = app.call("action.run", {"action": action, **({"target": target} if target else {})})
            if not reply.get("ok"):
                print(f"  {tag}: seeding without an agent chat ({action}: {reply.get('error')})", file=sys.stderr)
                agent = False
                break
        app.close()
        if agent and not prime.wait_for(AGENT_MARK, timeout):
            print(f"  {tag}: the seeded agent chat never loaded", file=sys.stderr)
            agent = False
        if agent:
            # A chat made through the control socket opens unselected; select
            # it so it is the visible tab at quit and a restore shows it.
            app = app_client(tag)
            chat = app_tab_id(app, "project-01", timeout, lambda tab: tab.get("kind") == "conversation" and not str(tab.get("id")).startswith("pending_"))
            reply = app.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": chat}}) if chat else {}
            app.close()
            if not reply.get("ok"):
                print(f"  {tag}: the seeded agent chat could not be selected ({reply.get('error')})", file=sys.stderr)
                agent = False
        if agent and SEED_FOCUS == "terminal":
            # The chat stays visible in its pane; a terminal beside it has focus.
            app = app_client(tag)
            other = next((pane["tabs"][0]["id"] for pane in project_panes(app)
                          if pane.get("tabs") and not any(tab.get("kind") == "conversation" for tab in pane["tabs"])), "")
            reply = app.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": other}}) if other else {}
            app.close()
            if not reply.get("ok"):
                print(f"  {tag}: no terminal beside the chat could be focused ({reply.get('error')})", file=sys.stderr)
                agent = False
    finally:
        prime.quit()
    with open(seeded_marker(tag), "w") as out:
        out.write(f"agent focus={seed_layout()}\n" if agent else f"terminals focus={seed_layout()}\n")


def seeded_agent(tag):
    try:
        with open(seeded_marker(tag)) as marker:
            return marker.read().startswith("agent")
    except OSError:
        return False


def seed_layout():
    return SEED_FOCUS if SEED_FOCUS == "agent" or SEED_CHAT_PANE == "last" else f"{SEED_FOCUS}-chat-{SEED_CHAT_PANE}"


def seeded_focus(tag):
    try:
        with open(seeded_marker(tag)) as marker:
            return marker.read().strip().partition("focus=")[2]
    except OSError:
        return None


def seeded_marker(tag):
    return os.path.join(state_directories(tag)[0], "bench-startup-realistic")


def corpus_module():
    """scripts/perf-lab/corpus/launch_restore.py: the corpus launch story's loader, seeding and checkpoint reads."""
    return load_by_path("corpus_launch_restore", os.path.join(PERF_LAB, "corpus", "launch_restore.py"))


def corpus_marker(tag):
    return os.path.join(state_directories(tag)[0], "bench-startup-corpus.json")


def corpus_seed(tag):
    """What the tag's saved session was seeded from: {layout, focus, surfaces} (the layout digest and the state at
    quit), or None."""
    try:
        with open(corpus_marker(tag)) as marker:
            return json.load(marker)
    except (OSError, ValueError):
        return None


def seed_corpus(tag, story):
    """Empties the tag's state and seeds it with the story's layout (launch_restore.seed: a bench launch imports it
    and quits keeping sessions), then stops the daemon: every mode starts from the saved session on disk, the cold
    one with no daemon and the warm one through its own priming launch."""
    reset_state(tag)
    out = tempfile.mkdtemp(prefix=f"bench-startup-seed-{tag}-")
    module = corpus_module()
    try:
        at_quit = module.seed(story, app_path(tag), out)
    except (module.LaunchRestoreError, LaunchError) as error:
        raise SystemExit(f"tag {tag}: seeding {story.id} failed ({error}); the seeding app's log is in {out}") from error
    finally:
        stop(tag_pids(tag))
    seeded = {"layout": story.layout_sha, "focus": at_quit["focus"], "surfaces": at_quit["surfaces"]}
    with open(corpus_marker(tag), "w") as marker:
        json.dump(seeded, marker)
    return seeded


def corpus_launch():
    """(cmux.json, extra env) of every launch of a corpus story: the seeding's window and config
    (launch_restore.launch_config, launch_env), so each restored pane has its size at quit."""
    module = corpus_module()
    return module.launch_config(), module.launch_env()


def app_read(tag):
    """One control request (a method name and its params) to the tag's app, at the first socket that answers."""
    def read(method, params=None):
        reply = None
        for path in socket_candidates(tag):
            reply = rpc_at(path, method, params, timeout=10)
            if not (isinstance(reply, dict) and reply.get("unreachable")):
                return reply
        return reply
    return read


def restored_checkpoint(tag, story, seeded):
    """The measured launch's settled checkpoint digests and whether they are the story's: its recorded digests, else
    the seeding's state at quit. None when the app did not answer the reads (check_checkpoints fails the run)."""
    want = story.recorded or {"focus": seeded["focus"], "surfaces": seeded["surfaces"]}
    module = corpus_module()
    read = app_read(tag)
    try:
        module.place_window(read)  # the seeding's window frame: the panes' content sizes are part of the digest
        got = module.settled_digests(read, want)
    except module.LaunchRestoreError as error:
        print(f"  {tag}: no restored checkpoint ({error})", file=sys.stderr)
        return None
    return {**got, "matches": got == want}


def sudo_reason(done):
    """What sudo said when it refused (stderr, else stdout), or its exit status."""
    return (done.stderr or done.stdout or "").strip() or f"exit {done.returncode}"


def check_purge_right(run=subprocess.run):
    """Refuses before any launch unless this account may run PURGE with no password (`sudo -n -l` runs nothing)."""
    try:
        done = run(["sudo", "-n", "-l", PURGE], capture_output=True, text=True)
    except OSError as error:
        raise Refused(f"cold run refused: cannot run `sudo -n -l {PURGE}` ({error})") from error
    if done.returncode != 0:
        raise Refused(f"cold run refused: this account may not run {PURGE} without a password ({sudo_reason(done)}); "
                      "a lab host gets the right from `host-setup.sh --grant-privileged` (decision D3), and without "
                      "it only --after-reboot measures a cold launch")


def purge(run=subprocess.run):
    """Empties the file cache for a true cold launch. `sudo -n` never prompts; a refusal stops the bench."""
    try:
        done = run(["sudo", "-n", PURGE], capture_output=True, text=True)
    except OSError as error:
        raise Refused(f"cold run refused: cannot run `sudo -n {PURGE}` ({error})") from error
    if done.returncode != 0:
        raise Refused(f"cold run refused: `sudo -n {PURGE}` failed ({sudo_reason(done)}); without it the launch "
                      "reads the file cache and is not cold")


def check_after_reboot(tags, profile, run=subprocess.run, now=time.time):
    """Refuses unless this launch can be the first since a reboot: the Mac booted at most AFTER_REBOOT_MAX_UPTIME_S
    ago, no process of a tag runs, and a realistic profile was seeded before the reboot."""
    try:
        boot = run(["/usr/sbin/sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
    except OSError:
        boot = ""
    match = re.search(r"\bsec = (\d+)", boot or "")
    if not match:
        raise Refused(f"after-reboot run refused: kern.boottime is unreadable ({(boot or '').strip()!r})")
    uptime = now() - int(match.group(1))
    if uptime > AFTER_REBOOT_MAX_UPTIME_S:
        raise Refused(f"after-reboot run refused: the Mac has been up {uptime:.0f} s, over "
                      f"{AFTER_REBOOT_MAX_UPTIME_S} s, so its file cache may hold the app")
    for tag in tags:
        if tag_pids(tag):
            raise Refused(f"after-reboot run refused: tag {tag} already ran since the boot (its pages are in memory)")
        if profile == "realistic" and seeded_focus(tag) != seed_layout():
            raise Refused(f"after-reboot run refused: tag {tag} has no seeded realistic profile, and seeding it now "
                          "launches the app; seed it with one --profile realistic run before the reboot")


def one_run(tag, mode, timeout, profile=None, purge_cold=False, purge_cache=purge, before_quit=None):
    """One measured launch's marks. `purge_cold` empties the file cache last before a --mode cold launch;
    `before_quit(tag)` runs in the measured app before it quits, whether or not it reached its first content."""
    scratch = tempfile.mkdtemp(prefix=f"bench-startup-{tag}-")
    config, env = corpus_launch() if profile == "corpus" else ({}, None)
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write(json.dumps(config) + "\n")
    if app_pids(tag):
        raise SystemExit(f"tag {tag} has an app running; quit it first (this bench only stops what it starts)")
    # A first launch shows the agent New Tab page, not a terminal: other
    # profiles end at whichever content draws first.
    final = [FINAL_MARK, AGENT_MARK]
    any_of = profile not in ("realistic", "corpus")
    seeded = None
    if profile == "empty":
        reset_state(tag)
    elif profile == "corpus":
        seeded = corpus_seed(tag)
        if (seeded or {}).get("layout") != CORPUS.layout_sha:
            seeded = seed_corpus(tag, CORPUS)
        # A restored session shows a terminal: the launch ends at its first live frame and the live sidebar rows.
        final = [FINAL_MARK, SIDEBAR_MARK]
    elif profile == "realistic" and seeded_focus(tag) != seed_layout():
        seed_realistic(tag, scratch, timeout)
    if profile == "realistic" and not seeded_agent(tag):
        final = [FINAL_MARK]
    if mode == "cold":
        # Builds of one tag (a before and an after copy) share its daemon.
        for other in RUN_TAGS or [tag]:
            stop(tag_pids(other))
        if tag_pids(tag):
            raise SystemExit(f"tag {tag}: daemon processes did not exit")
    elif mode == "restart":
        if not owner_pids(f"cmux-app-{tag}"):
            prime = Launch(tag, scratch, env)
            prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True)
            prime.quit()
        stop(owner_pids(f"cmux-app-{tag}"))
    elif not [p for p in tag_pids(tag) if p not in app_pids(tag)]:
        prime = Launch(tag, scratch, env)
        prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True)
        prime.quit()
    if mode == "cold" and purge_cold:
        # Last, after every stop and priming launch: nothing pages back in before the measured launch.
        purge_cache()
    launch = Launch(tag, scratch, env)
    try:
        started = time.monotonic()
        reached = launch.wait_for(final, timeout, any_of=any_of)
        if WAIT_MILESTONES and reached:
            launch.wait_for(MILESTONES, max(0.0, timeout - (time.monotonic() - started)))
        if reached and WAIT_STARTUP_COMPLETE:
            # Startup completes after the first content; the reason mark comes before it on the pipe.
            launch.wait_for(STARTUP_COMPLETE, max(0.0, timeout - (time.monotonic() - started)))
            # The sidebar's row counts are sent in the same main turn, right after it; a build
            # without them, or a launch with no window, costs SIDEBAR_ROWS_WAIT_S.
            if STARTUP_COMPLETE in launch.marks:
                launch.wait_for([SIDEBAR_ROWS_BUILT, SIDEBAR_ROWS_VISIBLE], SIDEBAR_ROWS_WAIT_S)
        if reached:
            # The census comes after the first frame, so a quit at the content mark can beat it.
            launch.wait_for(list(THREAD_MARKS), THREAD_MARKS_WAIT_S)
        for term in ORDER_MARKS if reached else []:
            launch.wait_for(term_marks(term), max(0.0, timeout - (time.monotonic() - started)), any_of=True)
        if HANG_THRESHOLD_MS:
            launch.stalls = launch_stalls(tag)
        if before_quit:
            before_quit(tag)
        checkpoint = restored_checkpoint(tag, CORPUS, seeded) if seeded and reached else None
        if checkpoint is not None:
            launch.marks["checkpoint"] = checkpoint
    finally:
        launch.quit()
    if not reached:
        missing = [mark for mark in final if mark not in launch.marks]
        print(f"  {tag} {mode}: {', '.join(missing)} not reached within {timeout} s", file=sys.stderr)
    if getattr(launch, "stalls", None) is not None:
        return {**launch.marks, "stalls": launch.stalls}
    return launch.marks


def launch_stalls(tag):
    """The launch's main-thread stalls, longest first, with their top frames."""
    client = app_client(tag)
    try:
        hangs = client.call("debug.hangs").get("result") or {}
    finally:
        client.close()
    stalls = [{"ms": round(record.get("duration_ms", 0), 1), "cpu_ms": round(record.get("cpu_ms", 0), 1),
               "frames": [f for f in record.get("frames", []) if "cmux" in f or "CmuxNext" in f][:8]
               or record.get("frames", [])[:8]}
              for record in hangs.get("records", [])]
    return sorted(stalls, key=lambda stall: -stall["ms"])


def owner_pids(session):
    """The session's daemon (owner) process, not its terminal hosts."""
    return pgrep(f"cmux-tui.*--session {session}( |$)")


def daemon_side(tag, runs):
    """Times the daemon's own start and first answers (no app)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_cli_storm import Client  # noqa: E402
    binary = os.path.join(os.path.dirname(os.path.dirname(app_binary(tag))), "Resources/bin/cmux-tui")
    if app_pids(tag):
        raise SystemExit(f"tag {tag} has an app running; quit it first")
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui")

    def env(state_dir):
        return {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": tmp, "CMUX_TUI_STATE_DIR": state_dir}

    def timed(args, state_dir):
        started = time.monotonic()
        out = subprocess.run([binary, *args], env=env(state_dir), capture_output=True, text=True)
        return (time.monotonic() - started) * 1000, out.stdout

    rows = {}
    for _ in range(runs):
        rows.setdefault("spawn cmux-tui --version", []).append(timed(["--version"], state)[0])
        session = f"cmux-app-{tag}"
        stop(owner_pids(session))
        ms, out = timed(["--session", session, "--json", "server", "ensure"], state)
        rows.setdefault("server ensure, state kept (adopt hosts)", []).append(ms)
        socket = json.loads([line for line in out.splitlines() if line.startswith("{")][-1])["socket"]
        client = Client(socket, timeout=10)
        for cmd in ("identify", "list-workspaces", "list-personal"):
            started = time.monotonic()
            client.call(cmd, cmd_key="cmd")
            rows.setdefault(f"{cmd} round trip (first connection)", []).append((time.monotonic() - started) * 1000)
        client.close()
        ms, _ = timed(["--session", session, "--json", "server", "status"], state)
        rows.setdefault("server status (running owner)", []).append(ms)
        fresh = tempfile.mkdtemp(prefix=f"bench-startup-daemon-{tag}-")
        fresh_session = f"bench-{os.getpid()}"
        ms, _ = timed(["--session", fresh_session, "--json", "server", "ensure"], fresh)
        rows.setdefault("server ensure, empty state root", []).append(ms)
        stop(owner_pids(fresh_session))
        subprocess.run(["rm", "-rf", fresh])
    print(f"\n{tag} daemon side ({runs} runs), ms")
    print(f"  {'phase':<46} {spread_header()}")
    for label, values in rows.items():
        print(f"  {label:<46} {spread_cells(spread(values))}")


def stall_site(stall):
    """The first app frame of a stall, without its module and offset."""
    frames = stall["frames"]
    for frame in [f for f in frames if "CmuxNext" in f] + [f for f in frames if "cmux DEV" in f]:
        if "cmux DEV" in frame:
            return frame.split(" + ")[0].replace("cmux DEV.debug.dylib ", "").replace("cmux DEV ", "")[:100]
    return (stall["frames"] or ["?"])[0].split(" + ")[0][:100]


def print_stalls(runs):
    """Main-thread stall time per run, and the sites that stalled in most runs."""
    totals = [sum(s["ms"] for s in run.get("stalls", [])) for run in runs]
    print(f"  main-thread stalls: median total {perf_stats.pct(totals, 0.5):.0f} ms per launch (max {max(totals):.0f})")
    sites = {}
    for run in runs:
        for stall in run.get("stalls", []):
            sites.setdefault(stall_site(stall), []).append(stall["ms"])
    for site, values in sorted(sites.items(), key=lambda item: -sum(item[1]))[:8]:
        print(f"    {len(values)}/{len(runs)} runs, median {perf_stats.pct(values, 0.5):>4.0f} ms  {site}")


def spread_header():
    return " ".join(f"{column:>8}" for column in ("p50", *(f"p{p}" for p in PERCENTILES), "max"))


def spread_cells(values, digits=0):
    return " ".join(f"{values[column]:>8.{digits}f}" for column in ("p50", *(f"p{p}" for p in PERCENTILES), "max"))


def table(runs):
    """Rows `(label, mark, spread, gap, n)` in the order the marks landed (by p50), each with the p50 gap from
    the row before. Only time marks; a value that is not a number is left out."""
    rows = []
    for mark, label in MARKS:
        values = [run[mark] for run in runs if is_number(run.get(mark))]
        if values:
            rows.append((label, mark, spread(values), len(values)))
    out = []
    previous = 0.0
    for label, mark, values, count in sorted(rows, key=lambda row: row[2]["p50"]):
        out.append((label, mark, values, values["p50"] - previous, count))
        previous = values["p50"]
    return out


def run_values(marks):
    """The value marks a run carries, for its line: `temperature cold, page-ins 4100, interrupted`."""
    shown = []
    temperature = run_temperature(marks)
    if temperature is not None:
        shown.append(f"temperature {temperature}")
    if is_number(marks.get(PAGEINS_RUN_LOOP)):
        shown.append(f"page-ins at run loop {marks[PAGEINS_RUN_LOOP]:.0f}")
    if is_number(marks.get(PAGEINS)):
        shown.append(f"page-ins {marks[PAGEINS]:.0f}")
    if is_number(marks.get(MAIN_CPU)):
        shown.append(f"main cpu {marks[MAIN_CPU]:.0f} ms")
    if is_number(marks.get(SIDEBAR_ROWS_BUILT)) and is_number(marks.get(SIDEBAR_ROWS_VISIBLE)):
        shown.append(f"sidebar rows built {marks[SIDEBAR_ROWS_BUILT]:.0f} for {marks[SIDEBAR_ROWS_VISIBLE]:.0f} visible")
    if is_number(marks.get(VIEWS_BUILT)):
        shown.append(f"views built {marks[VIEWS_BUILT]:.0f}")
    if any(mark in marks for mark in THREAD_MARKS):
        total, runtime, ghostty = (count_or_missing(marks.get(mark)) for mark in THREAD_MARKS)
        shown.append(f"threads at first frame {total} (runtime {runtime}, ghostty {ghostty})")
    if is_number(marks.get(ACTION_CATALOG_MAIN_WAIT)):
        shown.append(f"action catalog wait {marks[ACTION_CATALOG_MAIN_WAIT] / 1000:.2f} ms")
    reason = completion_reason(marks)
    if reason is not None:
        shown.append(f"startup complete {reason}")
    if interrupted(marks):
        shown.append("interrupted")
    return shown


def count_or_missing(value):
    """A count for a run's line, or `missing`: a count that did not arrive is never read as 0."""
    return f"{value:.0f}" if is_number(value) else "missing"


def main_span_summary(runs):
    """The main() span (MAIN_SPAN) of each run as a spread against MAIN_BUDGET_MS: a distribution of per-run
    spans, not the gap between two medians. None when no run has both marks (a build before them)."""
    start, end = MAIN_SPAN
    spans = [run[end] - run[start] for run in runs if is_number(run.get(start)) and is_number(run.get(end))]
    if not spans:
        return None
    values = spread(spans)
    cells = "  ".join(f"{column} {value:.1f}" for column, value in values.items())
    over = sum(span > MAIN_BUDGET_MS for span in spans)
    return f"  main(): {start} -> {end} ms {cells}  n {len(spans)}; {over} over {MAIN_BUDGET_MS:g} ms"


def daemon_steps_summary(runs):
    """p08-startup-093: the slowest step of the daemon's own start, by the p50 of each run's gap from the step the
    daemon reached before it. None when no run carries two daemon steps (a warm run attaches to a running daemon, an
    older daemon reports none)."""
    gaps = {}
    for run in runs:
        reached = [(mark, run[mark]) for mark, _ in DAEMON_STEPS if is_number(run.get(mark))]
        for (_, before), (mark, at) in zip(reached, reached[1:]):
            gaps.setdefault(mark, []).append(at - before)
    if not gaps:
        return None
    labels = dict(DAEMON_STEPS)
    p50 = {mark: perf_stats.pct(values, 0.5) for mark, values in gaps.items()}
    slowest = max(p50, key=p50.get)
    total = [run[DAEMON_STEPS[-1][0]] - run[DAEMON_STEPS[0][0]] for run in runs
             if is_number(run.get(DAEMON_STEPS[0][0])) and is_number(run.get(DAEMON_STEPS[-1][0]))]
    span = f"; main() -> first identify p50 {perf_stats.pct(total, 0.5):.1f} ms" if total else ""
    return (f"  daemon start: slowest step {labels[slowest]} ({slowest}) p50 {p50[slowest]:.1f} ms  "
            f"n {len(gaps[slowest])}{span}")


def value_summary(runs, temperature=None):
    """Summary lines for the value marks: the temperature of each run (against --temperature), page-in and main
    CPU spreads, and the interrupted runs by number. None when no run sent one and no temperature was asked."""
    if not runs or (temperature is None and not any(
            mark in VALUE_MARKS or mark.startswith((TEMPERATURE_INSTANT, COMPLETION_INSTANT)) for run in runs for mark in run)):
        return []
    total = len(runs)
    read = [name for name in map(run_temperature, runs) if name is not None]
    if read:
        counts = sorted(((read.count(name), name) for name in set(read)), key=lambda item: (-item[0], item[1]))
        line = f"  {TEMPERATURE}: " + ", ".join(f"{name} {count}" for count, name in counts) + f" of {total} runs"
        if len(read) < total:
            line += f" ({total - len(read)} without it)"
        if temperature:
            line += f"; {read.count(temperature)} of {total} read {temperature} as asked"
    else:
        line = f"  {TEMPERATURE}: missing in all {total} runs (the build sends no task 007 marks)"
    lines = [line]
    for mark, unit in ((PAGEINS_RUN_LOOP, ""), (PAGEINS, ""), (MAIN_CPU, " ms")):
        values = [run[mark] for run in runs if is_number(run.get(mark))]
        if values:
            cells = "  ".join(f"{column} {value:.0f}{unit}" for column, value in spread(values).items())
            lines.append(f"  {mark}: {cells}  n {len(values)}")
        else:
            lines.append(f"  {mark}: missing in all {total} runs")
    built = [run[VIEWS_BUILT] for run in runs if is_number(run.get(VIEWS_BUILT))]
    if built:  # only a launchVisiblePanesOnly build sends it
        cells = "  ".join(f"{column} {value:.0f}" for column, value in spread(built).items())
        lines.append(f"  {VIEWS_BUILT}: {cells}  n {len(built)} (== the visible panes)")
    lines += sidebar_rows_summary(runs)
    lines += first_frame_threads_summary(runs)
    lines += action_catalog_summary(runs)
    lines.append(completion_summary(runs))
    stopped = [str(index + 1) for index, run in enumerate(runs) if interrupted(run)]
    lines.append(f"  {INTERRUPTED}: " + (f"runs {', '.join(stopped)} ({len(stopped)} of {total})" if stopped
                                         else f"none of {total} runs"))
    return lines


def sidebar_rows_summary(runs):
    """p08-startup-064: the sidebar row views built before startup_complete, as a spread, and the runs that built
    more than the rows the clip showed plus SIDEBAR_ROWS_SLACK. No line when no run sent them (an older build)."""
    pairs = [(run[SIDEBAR_ROWS_BUILT], run[SIDEBAR_ROWS_VISIBLE]) for run in runs
             if is_number(run.get(SIDEBAR_ROWS_BUILT)) and is_number(run.get(SIDEBAR_ROWS_VISIBLE))]
    if not pairs:
        return []
    cells = "  ".join(f"{column} {value:.0f}" for column, value in spread([built for built, _ in pairs]).items())
    over = sum(built > visible + SIDEBAR_ROWS_SLACK for built, visible in pairs)
    visible = perf_stats.pct([visible for _, visible in pairs], 0.5)
    return [f"  {SIDEBAR_ROWS_BUILT}: {cells}  n {len(pairs)}; visible p50 {visible:.0f}; "
            f"{over} of {len(pairs)} over visible + {SIDEBAR_ROWS_SLACK}"]


def first_frame_threads_summary(runs):
    """p08-startup-068: each first-frame thread count as a spread, the runs with a runtime thread at the first
    frame (target none) and the runs that sent no runtime count, which never pass as none. No line when no run sent
    any count (an older build, or a Release build without bench hooks)."""
    if not any(mark in run for run in runs for mark in THREAD_MARKS):
        return []
    lines = []
    for mark in THREAD_MARKS:
        values = [run[mark] for run in runs if is_number(run.get(mark))]
        if values:
            cells = "  ".join(f"{column} {value:.0f}" for column, value in spread(values).items())
            lines.append(f"  {mark}: {cells}  n {len(values)}")
    measured = [(index + 1, run[FIRST_FRAME_RUNTIME_THREADS]) for index, run in enumerate(runs)
                if is_number(run.get(FIRST_FRAME_RUNTIME_THREADS))]
    runtime = [str(number) for number, value in measured if value > 0]
    status = f"runs {', '.join(runtime)}" if runtime else "none"
    lines.append(f"  runtime threads at first frame: {status} of {len(measured)} measured")
    missing = [str(index + 1) for index, run in enumerate(runs) if not is_number(run.get(FIRST_FRAME_RUNTIME_THREADS))]
    if missing:
        lines.append(f"  {FIRST_FRAME_RUNTIME_THREADS}: missing in runs {', '.join(missing)} ({len(missing)} of {len(runs)})")
    return lines


def action_catalog_summary(runs):
    """p08-startup-092: `action_catalog_main_wait_ms` 0 in how many runs, the waits as a spread in ms, and the read's
    time on main. A run that sent no wait is missing, never 0. No line when no run sent one (an older build)."""
    if not any(ACTION_CATALOG_MAIN_WAIT in run for run in runs):
        return []
    waits = [run[ACTION_CATALOG_MAIN_WAIT] / 1000 for run in runs if is_number(run.get(ACTION_CATALOG_MAIN_WAIT))]
    cells = "  ".join(f"{column} {value:.2f}" for column, value in spread(waits).items())
    line = (f"  action_catalog_main_wait_ms: 0 in {sum(wait == 0 for wait in waits)} of {len(runs)} runs; "
            f"{cells}  n {len(waits)}")
    missing = len(runs) - len(waits)
    if missing:
        line += f" ({missing} without it)"
    reads = [run[ACTION_CATALOG_MAIN_READ] / 1000 for run in runs if is_number(run.get(ACTION_CATALOG_MAIN_READ))]
    if not reads:
        return [line]
    cells = "  ".join(f"{column} {value:.2f}" for column, value in spread(reads).items())
    return [line, f"  action_catalog_main_read_ms: {cells}  n {len(reads)}"]


def classified_not_cold(run):
    """The build named this run's temperature, and not cold. Task 007 sends names; a number has no agreed meaning
    (temperature_name), so it never drops a run."""
    if is_number(run.get(TEMPERATURE)):
        return False
    name = run_temperature(run)
    return name is not None and name != "cold"


def result_marks(profile):
    """The marks written as result-v1 (`launch.<mode>.<mark>`): the launch target's frame (targets.json `launch`), the
    first content, and the perf cron's launch rows (launch-warm.json). The first content is the first live terminal
    frame where a terminal is restored (realistic); an empty profile's first launch shows the agent page instead,
    so its first content is FIRST_CONTENT, never a first_terminal_frame series that no run could fill."""
    first = FINAL_MARK if profile in ("realistic", "corpus") else FIRST_CONTENT
    return (TARGET_MARK, first, "did_finish_launching_end", SIDEBAR_MARK)


def result_value(run, mark):
    """A run's ms for a result mark: FIRST_CONTENT is the earlier of the terminal frame and the agent handshake that
    arrived; None when the mark never came."""
    if mark == FIRST_CONTENT:
        arrived = [run[name] for name in (FINAL_MARK, AGENT_MARK) if is_number(run.get(name))]
        return min(arrived) if arrived else None
    return run[mark] if is_number(run.get(mark)) else None


def checkpoint_mismatches(runs):
    """The runs (1-based) of a corpus launch story whose restored checkpoint is not the story's."""
    return [index + 1 for index, run in enumerate(runs)
            if isinstance(run.get("checkpoint"), dict) and not run["checkpoint"].get("matches")]


def result_series(mode, runs, profile, root="launch"):
    """`(metric, unit, samples)` of one tag's runs in one mode, as result-v1 names them (`<root>.<mode>.<mark>`; a
    corpus launch story's root is `corpus.<id>`). A cold run that the build classified otherwise is no cold sample:
    <root>.cold.not_cold_runs counts it. A corpus story also counts the runs that restored another state."""
    series = []
    if mode == "cold":
        kept = [run for run in runs if not classified_not_cold(run)]
        series.append((f"{root}.cold.not_cold_runs", "count", [len(runs) - len(kept)]))
        runs = kept
    for mark in result_marks(profile):
        values = [value for value in (result_value(run, mark) for run in runs) if value is not None]
        if values:
            series.append((f"{root}.{mode}.{mark}", "ms", values))
        series.append((f"{root}.{mode}.{mark}.missing_runs", "count", [len(runs) - len(values)]))
    if profile == "corpus":
        series.append((f"{root}.{mode}.checkpoint_mismatch_runs", "count", [len(checkpoint_mismatches(runs))]))
    return series


def default_story(mode, profile, after_reboot=False):
    """The lab story a run measures (scripts/perf-lab/stories.d/<story>.json)."""
    if after_reboot:
        return "launch-after-reboot"
    if profile == "corpus":
        return f"{CORPUS.id}-{mode}"
    return f"launch-{mode}" + ("-realistic" if profile == "realistic" else "")


def target_of(mode, metric, profile):
    """The targets.json row a series is judged by: the launch frame of an empty profile, cold or warm."""
    if profile == "empty" and mode in ("cold", "warm") and metric == f"launch.{mode}.{TARGET_MARK}":
        return f"launch.{mode}"
    return None


class Recorder:
    """Writes each tag's series as cmux-perf-result/v1 through BenchApp.record: one BenchApp per tag (its build and
    the host; one run for all of them), given the features snapshot that the tag's own measured launch answered."""

    def __init__(self, out, profile, session="light", story=None, build_config=None, after_reboot=False,
                 bench_app=BenchApp, rpc=rpc_at):
        self.out, self.profile, self.session = out, profile, session
        self.story = story or os.environ.get("PERF_LAB_STORY") or None
        self.build_config, self.after_reboot = build_config, after_reboot
        self.bench_app, self.rpc = bench_app, rpc
        self.run = perf_result.Run.start()
        self.apps = {}

    def app(self, tag):
        if tag not in self.apps:
            self.apps[tag] = self.bench_app(app_path(tag), out=self.out, teardown=False, perf_session=self.session,
                                            build_config=self.build_config, run=self.run)
        return self.apps[tag]

    def read_features(self, tag):
        """The tag's features.list snapshot, read once, from the first measured launch that answers it before it
        quits; a launch that never drew counts, so its missing_runs still record."""
        app = self.app(tag)
        if app.features is not None:
            return
        for path in socket_candidates(tag):
            reply = self.rpc(path, "features.list", timeout=10)
            if not (isinstance(reply, dict) and reply.get("unreachable")):
                app.features = features_snapshot(reply)
                return

    def observe(self, tag):
        """While the tag's measured launch runs: its features (read_features) and, under the perf-lab runner, the
        lab's full host check over the tag's pids (BenchApp.validate_lab_host, once per tag; skipped while none
        runs, so a later launch checks it)."""
        self.read_features(tag)
        pids = tag_pids(tag)
        if pids:
            self.app(tag).validate_lab_host(pids)

    def record(self, tag, mode, runs):
        """`{metric: path or "not recorded: <reason>"}` for one tag and mode."""
        story = self.story or default_story(mode, self.profile, self.after_reboot)
        app = self.app(tag)
        written = {}
        root = CORPUS.metric_root if self.profile == "corpus" else "launch"
        for metric, unit, samples in result_series(mode, runs, self.profile, root):
            try:
                written[metric] = str(app.record(story, metric, unit, samples, better="lower", engine="none",
                                                 target_ref=target_of(mode, metric, self.profile)))
            except (RecordError, perf_result.ResultError) as error:
                written[metric] = f"not recorded: {error}"
        return written


# Each `reload.sh --config` name (bench_launch.build_config): whether its launch is the shipped, optimized one.
BUILD_CONFIGS = {
    "release": (True, "a Release build"),
    "bench": (True, "a bench build (Release optimization plus the bench hooks)"),
    "debug": (False, "a Debug build (not optimized)"),
    # Release-optimized, but its blocking detector's bookkeeping costs time on every checked call (reload.sh), so
    # the launch it times is not the one that ships; the perf-lab launch story measures `bench` for the same reason.
    "bench-checks": (False, "a bench-checks build (its blocking detector costs time on every checked call)"),
}


def stamp_evidence(app):
    """`(optimized, why)` from the Info.plist stamp and the bundle's file names alone: no byte of the executable is
    read, so a launch after it can still be the first since the boot. build_evidence checks the stamp against the
    executable once that launch ended."""
    if glob.glob(os.path.join(app, "Contents/MacOS/*.debug.dylib")):
        return False, "a Debug build (Xcode's .debug.dylib beside the executable)"
    stamped = info_plist(app).get(BUILD_CONFIG_KEY)
    if stamped not in BUILD_CONFIGS:
        return False, (f"a bundle without a known Info.plist {BUILD_CONFIG_KEY} ({stamped!r}), and an after-reboot "
                       "run reads nothing else before its launch")
    optimized, what = BUILD_CONFIGS[stamped]
    return optimized, f"{what}; Info.plist {BUILD_CONFIG_KEY}={stamped}, its executable checked after the launch"


def build_evidence(app, binary):
    """`(optimized, why)` for a bundle, from bench_launch.build_config: reload.sh's CMUXBuildConfiguration stamp,
    checked against the executable (Xcode's .debug.dylib, the bench-hooks marker). A stamp the bundle contradicts,
    or a bench-hooks bundle with no stamp (bench or bench-checks), is no evidence of an optimized build."""
    try:
        config = build_config(app, binary)
    except RecordError as error:
        return False, str(error).removeprefix("bench-launch: ")
    optimized, what = BUILD_CONFIGS[config]
    stamped = info_plist(app).get(BUILD_CONFIG_KEY)
    if stamped:
        return optimized, f"{what}; Info.plist {BUILD_CONFIG_KEY}={stamped}"
    return optimized, f"{what}; an unstamped {bundle_kind(app, binary)} bundle"


def executable_evidence(app):
    """build_evidence of a bundle and its main executable."""
    return build_evidence(app, executable(app))


def require_optimized(tags, evidence=executable_evidence):
    """Refuses a tag whose build is not optimized: its numbers would not be launch numbers. `evidence(app)` is
    executable_evidence, or stamp_evidence before an after-reboot launch (main checks the executable after it).
    A DerivedData tag resolves here to its newest optimized bundle (tagged_app), which every run then launches."""
    for tag in tags:
        if tag not in APPS and tag not in TAGGED:
            TAGGED[tag] = tagged_app(tag, optimized=True, evidence=evidence)
        app = app_path(tag)
        optimized, why = evidence(app)
        print(f"build: {tag} is {why} ({app})", flush=True)
        if not optimized:
            raise Refused(f"--require-optimized: tag {tag} is {why}; bench a Release or bench build "
                          f"(`reload.sh --tag {tag} --config bench`, which lands in Build/Products/Release, or "
                          "--app with the fleet's bench artifact)")


def parse_order(order):
    """The terms of a `FIRST<SECOND[<THIRD...]` chain (a term `A|B` is any one of its marks); ValueError
    for an empty term or mark, or a value mark."""
    terms = ["|".join(mark.strip() for mark in term.split("|")) for term in order.split("<")]
    if len(terms) < 2 or not all(all(term_marks(term)) for term in terms):
        raise ValueError(f"--order {order!r}: expected FIRST<SECOND (marks joined by <, alternatives by |)")
    values = [mark for term in terms for mark in term_marks(term) if mark in VALUE_MARKS]
    if values:
        raise ValueError(f"--order {order!r}: {', '.join(values)} is a value, not a time")
    return terms


def term_marks(term):
    """The marks of an --order term: `A|B` is A or B."""
    return term.split("|")


def term_time(run, term):
    """The earliest time of the term's marks in `run`, None when none arrived."""
    times = [run[mark] for mark in term_marks(term) if is_number(run.get(mark))]
    return min(times) if times else None


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--app", action="append", default=[], help="a staged `cmux DEV <tag>.app` (fleet artifact)")
    parser.add_argument("--profile", choices=["empty", "realistic"],
                        help="empty: no saved state before each run; realistic: a seeded day's work "
                             "(default: whatever state the tag has)")
    parser.add_argument("--corpus", metavar="MANIFEST",
                        help="launch from a corpus launch story's saved session (perf-corpus/launch-restore.json) "
                             "instead of a --profile; results in session corpus:<id>")
    parser.add_argument("--capture", action="store_true",
                        help="--corpus: record the restored checkpoint's digests in the manifest when the state at "
                             "quit and every restored launch agree")
    parser.add_argument("--focus", choices=["agent", "terminal"], default="agent",
                        help="realistic: the focused pane at quit, the agent chat or a terminal beside it")
    parser.add_argument("--chat-pane", choices=["first", "last"], default="last",
                        help="realistic with --focus terminal: the chat's pane; first puts the focused terminal after it")
    parser.add_argument("--runs", type=int, help="measured launches per tag and mode (default 5; 1 with --after-reboot)")
    parser.add_argument("--mode", action="append", choices=["cold", "restart", "warm", "daemon"])
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per launch to reach the first frame")
    parser.add_argument("--json", help="write every run's marks here")
    parser.add_argument("--budget", action="append", default=[], metavar="MARK=MS",
                        help="exit 1 when a mark's median (any tag, mode) is over MS or never arrives")
    parser.add_argument("--order", action="append", default=[], metavar="FIRST<SECOND",
                        help="exit 1 when, in any run, mark SECOND is missing or comes before mark FIRST "
                             "(for example first_window_frame_committed<launch.non_paint_services); "
                             "a chain A<B<C checks A<B and B<C")
    parser.add_argument("--milestones", action="store_true",
                        help="wait in each run for Chrome's startup milestones (MILESTONES); exit 1 when a run "
                             "lacks one or has a MILESTONE_ORDER pair out of order")
    parser.add_argument("--startup-complete", action="store_true",
                        help="after the first content, keep each launch until startup_complete (within --timeout) "
                             "and print its reason per run and as counts, the failsafe ones counted, and "
                             "launch.views_built (sent just before it)")
    parser.add_argument("--hangs", type=int, metavar="MS",
                        help="record main-thread stalls over MS during each launch (debug.hangs) and print the worst")
    parser.add_argument("--purge", action="store_true",
                        help=f"`sudo -n {PURGE}` before each --mode cold launch (decision D3); without the right the "
                             "bench refuses before any launch, exit 2")
    parser.add_argument("--temperature", choices=["cold", "warm"],
                        help="cold: --purge with --mode cold only; warm: no purge. The summary counts the runs whose "
                             "launch.temperature read it")
    parser.add_argument("--after-reboot", action="store_true",
                        help="one --mode cold launch, the first since a reboot (T2): exit 2 when the Mac is up over "
                             f"{AFTER_REBOOT_MAX_UPTIME_S} s or the tag already runs")
    parser.add_argument("--out", help="write cmux-perf-result/v1 files here (needs --profile)")
    parser.add_argument("--story", help="result-v1 story (default launch-<mode>, launch-<mode>-realistic or, for an "
                                        "empty profile, launch-after-reboot)")
    parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    parser.add_argument("--require-optimized", action="store_true",
                        help="exit 2 before any launch unless each build is release or bench (Info.plist "
                             "CMUXBuildConfiguration, checked against the executable); a --tag takes its newest "
                             "optimized bundle")
    args = parser.parse_args(argv)
    if not args.tag and not args.app:
        parser.error("give at least one --tag or --app")
    for order in args.order:
        try:
            parse_order(order)
        except ValueError as error:
            parser.error(str(error))
    if args.temperature == "cold" and [mode for mode in args.mode or ["cold", "warm"] if mode != "cold"]:
        parser.error("--temperature cold needs --mode cold only: a true cold launch has no daemon and an empty "
                     "file cache")
    if args.after_reboot:
        if [mode for mode in args.mode or ["cold"] if mode != "cold"]:
            parser.error("--after-reboot is one --mode cold launch: only the first launch since the boot is cold")
        if args.runs not in (None, 1):
            parser.error("--after-reboot measures one run: only the first launch since the boot is cold")
        if args.purge or args.temperature:
            parser.error("--after-reboot needs no --purge or --temperature: the reboot emptied the file cache")
        args.mode = ["cold"]
    if args.corpus:
        if args.profile:
            parser.error("--corpus is the launch's saved session: give it or a --profile, not both")
        if args.after_reboot:
            parser.error("--corpus has no after-reboot run: its seeding launches the app")
        args.profile = "corpus"
    elif args.capture:
        parser.error("--capture records a corpus launch story's checkpoint: it needs --corpus")
    args.runs = args.runs or (1 if args.after_reboot else 5)
    args.purge_cold = args.purge or args.temperature == "cold"
    if args.out:
        if not args.profile:
            parser.error("--out needs --profile empty or realistic, or --corpus: a result names the state it "
                         "launched from")
        if "cold" in (args.mode or ["cold", "warm"]) and not (args.purge_cold or args.after_reboot):
            parser.error("--out with --mode cold needs --purge or --after-reboot: a launch that only stopped the "
                         "daemon reads the file cache, and result-v1 never reports it as cold")
        if args.after_reboot and args.profile != "empty" and not args.story:
            parser.error("--out with --after-reboot and --profile realistic needs --story: launch-after-reboot is the "
                         "empty profile's series")
    return args


def write_results(recorder, results):
    """Writes every tag's and mode's result-v1 series and prints where; refuses (exit 2) when none was written."""
    written = {(tag, metric): outcome for tag, modes in results.items() for mode, runs in modes.items()
               for metric, outcome in recorder.record(tag, mode, runs).items()}
    for (tag, metric), outcome in written.items():
        print(f"result-v1 {tag} {metric}: {outcome}", flush=True)
    if not any(not outcome.startswith("not recorded") for outcome in written.values()):
        raise Refused(f"no result-v1 written to {recorder.out}: every series was refused (above)")


def main():
    args = parse_args(sys.argv[1:])
    require_gui_session("bench-startup")
    global HANG_THRESHOLD_MS, SEED_FOCUS, SEED_CHAT_PANE, WAIT_STARTUP_COMPLETE, WAIT_MILESTONES, CORPUS
    HANG_THRESHOLD_MS = args.hangs
    if args.corpus:
        CORPUS = load_corpus(args.corpus)  # before any launch: a manifest that is no launch story stops here
    orders = args.order + (LAUNCH_ORDER if args.budget else [])
    ORDER_MARKS.extend(dict.fromkeys(term for order in orders for term in parse_order(order)))
    WAIT_STARTUP_COMPLETE = args.startup_complete
    WAIT_MILESTONES = args.milestones
    SEED_FOCUS = args.focus
    SEED_CHAT_PANE = args.chat_pane
    for path in args.app:
        APPS[app_tag(path)] = os.path.abspath(path)
        args.tag.append(app_tag(path))
    # The lab runner passes both --app and its --tag: one tag, measured once per run.
    args.tag = list(dict.fromkeys(args.tag))
    RUN_TAGS.extend(args.tag)
    if args.require_optimized:
        # Before a first-since-boot launch, reading the executable would page it in: the stamp only, until it ended.
        require_optimized(args.tag, stamp_evidence if args.after_reboot else executable_evidence)
    modes = args.mode or ["cold", "warm"]
    # Before any launch: a cold run without the purge right, or an after-reboot run that is not one, stops here.
    if args.purge_cold and "cold" in modes:
        check_purge_right()
    if args.after_reboot:
        check_after_reboot(args.tag, args.profile)
    session = CORPUS.session if CORPUS else args.session
    recorder = Recorder(args.out, args.profile, session, args.story, args.build_config,
                        args.after_reboot) if args.out else None
    if "daemon" in modes:
        modes.remove("daemon")
        for tag in args.tag:
            daemon_side(tag, args.runs)
        if not modes:
            return
    results = {tag: {mode: [] for mode in modes} for tag in args.tag}
    print(f"load average: {' '.join(f'{x:.0f}' for x in os.getloadavg())}")
    try:
        for mode in modes:
            for index in range(args.runs):
                for tag in args.tag:
                    marks = one_run(tag, mode, args.timeout, args.profile, args.purge_cold,
                                    before_quit=recorder.observe if recorder else None)
                    results[tag][mode].append(marks)

                    def shown(mark):
                        return "%.0f ms" % marks[mark] if is_number(marks.get(mark)) else "missing"
                    values = "".join(f", {value}" for value in run_values(marks))
                    print(f"  {tag} {mode} run {index + 1}: first live terminal frame {shown(FINAL_MARK)}, "
                          f"agent pane {shown(AGENT_MARK)}{values}", flush=True)
                    for stall in marks.get("stalls", [])[:3]:
                        print(f"    stall {stall['ms']:.0f} ms (cpu {stall['cpu_ms']:.0f}): "
                              + " < ".join(stall["frames"][:4]), flush=True)
    finally:
        for tag in args.tag:
            stop(tag_pids(tag))
    print(f"load average: {' '.join(f'{x:.0f}' for x in os.getloadavg())}")
    for tag in args.tag:
        for mode in modes:
            runs = results[tag][mode]
            cold = " (purged)" if mode == "cold" and args.purge_cold else (
                " (after reboot)" if args.after_reboot else "")
            print(f"\n{tag} {mode}{cold} {args.profile or 'kept'} profile ({len(runs)} runs), ms since process start")
            print(f"  {'phase':<46} {spread_header()} {'gap':>8}  n")
            for label, mark, values, gap, count in table(runs):
                print(f"  {label:<46} {spread_cells(values)} {gap:>+8.0f}  {count}")
            span = main_span_summary(runs)
            if span:
                print(span)
            daemon_steps = daemon_steps_summary(runs)
            if daemon_steps:
                print(daemon_steps)
            for line in value_summary(runs, args.temperature):
                print(line)
            if args.hangs:
                print_stalls(runs)
    if args.json:
        with open(args.json, "w") as out:
            json.dump(results, out, indent=1)
    if args.require_optimized and args.after_reboot:
        require_optimized(args.tag)  # the launch ended: now the stamp is checked against the executable
    if recorder:
        write_results(recorder, results)
    over = check_budgets(results, args.budget) + check_orders(results, orders)
    if args.milestones:
        over += check_milestones(results)
    if CORPUS:
        over += check_checkpoints(results)
        if args.capture and not over:
            capture_checkpoint(results)
    for line in over:
        print(f"over budget: {line}", file=sys.stderr)
    if over:
        sys.exit(1)


def load_corpus(path):
    """The corpus launch story at `path` (launch_restore.load); refuses (exit 2) a manifest that is not one, or a
    checkout without play.py, whose functions are the checkpoint digests."""
    module = corpus_module()
    try:
        module.player()
        return module.load(path)
    except module.LaunchRestoreError as error:
        raise Refused(f"--corpus refused: {error}") from error


def check_checkpoints(results):
    """A corpus launch story's runs that restored another state than the story's, and runs with no checkpoint read
    (the launch did not draw): one line each."""
    lines = []
    for tag, modes in results.items():
        for mode, runs in modes.items():
            for index, run in enumerate(runs, 1):
                got = run.get("checkpoint")
                if not isinstance(got, dict):
                    lines.append(f"{tag} {mode} run {index}: no restored checkpoint (the launch did not draw)")
                elif not got.get("matches"):
                    lines.append(f"{tag} {mode} run {index}: restored another state than {CORPUS.id}'s checkpoint "
                                 f"(focus {got['focus'][:12]}, surfaces {got['surfaces'][:12]})")
    return lines


def capture_checkpoint(results):
    """--capture: writes the restored digests into the manifest, once every run of every tag and mode agreed."""
    states = {(run["checkpoint"]["focus"], run["checkpoint"]["surfaces"])
              for modes in results.values() for runs in modes.values() for run in runs}
    if len(states) != 1:
        raise Refused(f"--capture refused: the runs restored {len(states)} different states")
    (focus, surfaces), = states
    module = corpus_module()
    try:
        path = module.capture(CORPUS, {"focus": focus, "surfaces": surfaces})
    except module.LaunchRestoreError as error:
        raise Refused(f"--capture refused: {error}") from error
    print(f"captured {CORPUS.id}'s restored checkpoint in {path}: focus {focus[:12]}, surfaces {surfaces[:12]}")


def check_budgets(results, budgets):
    """Every `MARK=MS` whose median is over MS (or missing) in some tag and mode."""
    over = []
    for budget in budgets:
        mark, _, limit = budget.partition("=")
        for tag, modes in results.items():
            for mode, runs in modes.items():
                values = [run[mark] for run in runs if is_number(run.get(mark))]
                if len(values) < len(runs):
                    over.append(f"{tag} {mode}: {mark} missing in {len(runs) - len(values)} of {len(runs)} runs")
                elif values and perf_stats.pct(values, 0.5) > float(limit):
                    over.append(f"{tag} {mode}: {mark} median {perf_stats.pct(values, 0.5):.0f} ms > {limit} ms")
    return over


def check_milestones(results):
    """Every run that lacks a milestone, then every MILESTONE_ORDER pair out of order."""
    out = []
    for tag, modes in results.items():
        for mode, runs in modes.items():
            for index, run in enumerate(runs):
                missing = [mark for mark in MILESTONES if mark not in run]
                if missing:
                    out.append(f"{tag} {mode} run {index + 1}: milestones missing: {', '.join(missing)}")
    return out + [line for line in check_orders(results, MILESTONE_ORDER) if not line.endswith(" missing")]


def check_orders(results, orders):
    """Every `FIRST<SECOND` where some run lacks SECOND or has it before FIRST; a chain `A<B<C` is A<B and B<C."""
    out = []
    pairs = [pair for order in orders for marks in [parse_order(order)] for pair in zip(marks, marks[1:])]
    for first, second in pairs:
        for tag, modes in results.items():
            for mode, runs in modes.items():
                for index, run in enumerate(runs):
                    first_ms, second_ms = term_time(run, first), term_time(run, second)
                    if second_ms is None:
                        out.append(f"{tag} {mode} run {index + 1}: {second} missing")
                    elif first_ms is not None and second_ms < first_ms:
                        out.append(f"{tag} {mode} run {index + 1}: {second} at {second_ms:.0f} ms, before {first} at {first_ms:.0f} ms")
    return out


if __name__ == "__main__":
    main()
