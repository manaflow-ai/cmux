#!/usr/bin/env python3
"""Idle thread and wakeup budget of cmux NEXT (Lawrence's threading list, item 6; plans/cmux-next/idle-wakeups.md).

Idle means no input, no visible change, terminals quiet. At idle every cmux process should sleep: the
app's main thread 0 wakeups a second, the app <= 1/s, the cmux-tui daemon <= 1/s, the holder 0, and
each process's thread count capped. This script launches a tagged app (bench_launch.BenchApp), builds a
session, lets it settle, then measures one window with no input and reports, per process:

  threads, wakeups/s (interrupt wakeups, proc_pid_rusage: what Activity Monitor's Idle Wake Ups and
  Chrome's GetIdleWakeupsPerSecond count; the judged number), package-idle wakeups/s (a subset of them,
  GetPackageIdleWakeupsPerSecond), CPU energy and billed energy (mW: CPU energy plus what other processes
  such as WindowServer spent for this one, less what it spent for them), GPU ms/s (IORegistry), context
  switches/s, CPU %, and the threads that ran in the window (CPU time per thread,
  PROC_PIDTHREADID64INFO: the thread names show which loop woke);
  for the app also main_wakes/s (the main run loop's wakes from sleep, debug.hangs `main_wakes`) and,
  when the build has it, the wakeup ledger's owners (debug.wakeups: DemandTimer, FrameScheduler,
  Backoff by owner and reason).
The app's resource coalition (procs.coalition_of: energy, energy billed to it, GPU time and wakeups of
everything it started, processes gone in the window included) is `coalition` in the report: null when
it cannot be read.
D15 (plans/cmux-next/chrome-parity/p14-energy.md, task 105), per process: disk bytes written (the
ri_diskio_byteswritten delta: disk_bytes, disk_bytes_per_s), network bytes, their lo0 part and the connections open
at the end (`nettop -x -n -d -L`, started before the window, only its samples stamped inside it: network_bytes,
network_loopback_bytes, connections; the remote ends name the owner of an over), unified-log lines and their subsystem:category owners (`log show --style ndjson` of the
pid set after the window, only events stamped inside it: log_lines); and per session WindowServer's wakeups/s in the
window against a reference window with cmux hidden (`windowserver`: reported, never judged; rusage through `sudo -n`,
else top's IDLEW; no rate across a WindowServer restart or a source change; a hide that is not confirmed takes no
reference). A process that exits inside the window keeps its network and log values in its kind, its disk unknown
(`exited`). A reader that fails, or nettop samples that do not cover the window, leave the values null and print
IDLE-BUDGET-READER-FAILED: not measured is never a pass.

The script reads the app's counters only at the window's two ends (proc_pid_rusage of another process
does not wake it; the two socket reads sit outside the process counters' window; nettop asks the kernel, starts
before every bracket and its own counters are taken out of the app's coalition; `log show` asks logd), so the bench
adds no wakeup to what it measures. Each end's state reads (debug.energy, pmset, the animated page) sit outside
every counter bracket: the start reads, a quiet gap, then the counters; the counters, then the end reads.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  minimized     the light session with its window minimized (minimizeWindow)
  light-hidden and minimized are hidden-wake sessions: they fail unless the app is hidden (no main window visible)
  or every main window is miniaturized at both ends of the window and after the wake trace, and they name every
  main-thread wake source above 0.1/s in HIDDEN-WAKE lines (`hidden_wake_sources`): a DTrace trace of the main
  thread right after the window (--wake-trace) that gives each wake to the first item it ran, the main run loop's
  repeating timer fires and the wakeup ledger, one list per basis, with the owners' frames from 3 x --sample
  `/usr/bin/sample` runs after the trace. A run whose shipping mode is not confirmed, or whose callbacks atos did not
  name, prints HIDDEN-WAKE-UNCONFIRMED instead.
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet
  tabs-static   the launch pane with 5 WebKit and 10 Chromium tabs hidden behind 1 shown static Chromium tab,
                every page a probe page (Visibility, below); the settle lasts past `browser.freezeHiddenTabs`; after
                the window one hidden Chromium tab is shown and the roles read again (Reshow, below)
  minimized     the light session with its window minimized (action minimizeWindow)
  occluded      the light session with benchhelper's opaque full-screen window over it (`benchhelper cover`: another
                app that activates and shows its key window in front; debug.window_list must report every main window
                occluded and no window of the app key, so the app resigned active)
  home          the light session with Home selected (action home.show; xbench's idle-wakeups-home, D6)
  signed-in     the light session signed in as the host's staging agent test account (CMUX_UITEST_STACK_* of
                --signed-in-credentials, default the fleet secrets file, which the app reads itself; the bench passes
                the account's email and the agent profile only, so no secret or token reaches a log or the report),
                with Phone Access and the GitHub feed on and both keep-awake settings off; auth.status must report the
                account signed in, and the app signs out (debug.cloud.end_session) before it stops. The app signs a
                test account in only in a Debug build (DogfoodCredentials): the session is refused on another build,
                and on a Debug build its own rows are reported, not judged (not the code users run)
  signed-in-display-sleep  signed-in with `pmset displaysleepnow` after the activation (the display wakes at the
                teardown); judged by its relative row: app <= light-hidden of the same run (D13)
  Every session other than the signed-in ones runs signed out: a sign-in the app restores is ended first, and each
  session's `shape.signed_in` records which it ran as.
  app-quit      the light session quit after the settle with the sessions kept (action quitKeepSessions), then settled
                QUIT_SETTLE_S again: the window measures what keeps running without the app (daemon, holders, terminal
                hosts, acpmux; TagTeardown's process set of the tag)
  external-churn  the light session hidden, its terminal in a git project the bench writes 10 times a second, and a
                Chrome History fixture (Chromium's `urls` table) imported with Keep in Sync (the tag's BrowserImport
                store, seeded before the launch and restored after) that gets a visit appended every
                HISTORY_PERIOD_S; the writes run through the settle and the window, from this script
  energy-saver  tabs-static with `energy.saver: always` (and the default-off `energySaver` feature on: saver_launch,
                which bench-typing's --energy-saver uses too), the shown tab an animated page (/anim, rAF every
                frame, no input) whose rAF count the page server reads at the window's two ends: the page keeps
                one fetch the server holds (no wake while held); the bench answers it and the page POSTs
                its count, page clock and visibilityState (any build, Release + CMUX_BENCH_HOOKS included)
  chrome-static the reference: a Chromium browser (--chrome-app) with tabs-static's 16 static pages as tabs in the
                same order, the last shown, and the uBlock Origin --app bundles (--chrome-ublock), launched as xbench
                launches Chrome (a template profile keyed on the browser build and uBlock Origin, its switches, CDP
                /json/new), every page loaded, settled as long as tabs-static; kinds browser, renderer, extension,
                gpu, utility, crashpad. The bundled uBlock Origin is Manifest V2: branded Google Chrome ignores
                --load-extension from 137 and Chromium runs no MV2 from 139, so --chrome-app must be a Chromium with
                the MV2 patch cmux's CEF carries (ungoogled-chromium of cmux's Chromium major: cmux's
                cmux_extensions_manifestv2.patch comes from it). A browser known not to run it (branded Chrome 137+,
                Chrome for Testing 139+) fails the session before it launches. The report gets a `chrome` block
                and `ratio_to_chrome` rows (the budget's, judged once with the other cross-session rows; a Chrome
                value under the field's noise floor counts as the floor, `:floor` on the field). A row whose two
                sessions did not both run uBlock Origin, or whose Chrome pages are not tabs-static's shape, is
                `unequal`: reported, not judged; --gate refuses a failed or unequal chrome-static run.
  power-visible the launch pane with 1 shown static Chromium tab and nothing else, settled 120 s, its window's power
                attributed (scripts/perf-bench/power_attribution.py, p14-energy-096): per process own + billed -
                serviced energy, split per thread by CPU time, summed into owners `<kind>/<thread>`, `<kind>/billed`
                and `<kind>/serviced` that must sum to within 10% of the app's coalition total; WindowServer's own
                energy (with `sudo -n`); unnamed threads summed per kind (`<kind>/unnamed threads`), and while that
                is >= 2 mW a stack sample of the process with the most of it names its threads; the FrameClients
                that ticked (debug.wakeups `frame` ledger owners and FrameScheduler frames) and the infinite Core
                Animation loops and playing video layers at both ends (debug.layers `frame_sources`). Reported, not
                judged: no budget row.
  chrome-power-visible  the same 1 tab in the chrome-static browser, attributed the same way. With both sessions
                measured, POWER-OVER lines list each owner group >= 2 mW (Chrome's kinds: the app and cef-host are
                `browser`) that spends more than Chrome's same group, or that Chrome does not have: reported, not
                judged.
  agent-idle    two agent chats on the ACP fake agent (cmux-tui/crates/acpmux/tests/fake_agent.py, the default
                harness of the session's own ACPMUX_HOME and ACPMUX_SOCKET) after a finished turn: one in a workspace
                that then hides behind the launch workspace, one in the launch pane; plus one pooled entry
                (_acpmux/prewarm). Settled past p14-energy-117's harness freeze (HARNESS_FREEZE_S). Its hidden chat's
                harness rows are `hidden` (under that chat's agent host, from its `hosts/<session>.json` record).
                The window is refused (IDLE-BUDGET-REFUSED) when no measured harness row is under the hidden chat's
                host or under a pooled host: a harness that exited would pass its rows with nothing measured.
  agent-working-visible  the launch pane's chat in a turn that sends nothing (the fake agent's `gate:` blocks on a
                FIFO until the session ends): the pane's working state is what moves. The chat must show in
                Chromium (`debug.agent_pane engine` == cef): its row sums the cef kinds, and a WebKit chat's work
                would fall outside them
  busy-hidden   the launch terminal prints one line every 100 ms, then a new workspace shows over it
  Every process under an acpmux agent host (`__agent-host`, pooled entries included) is kind agent-harness
  (procs.agent_harness_pids); the host itself is acpmux.

Per window the report also has, per session: `energy_mw` (CPU and billed energy, summed per kind and over the
tree), `assertions` (`pmset -g assertions` held by or created for a pid of the set), `saver` (asked by the
session, observed through debug.energy at both ends) and `thermal` (ProcessInfo.thermalState at both ends).
--gate refuses a session whose observed saver state is not the one it asked for, and energy-saver when its page's
rAF rate could not be read; a session whose thermal state reached serious or critical has `thermal_marked` on its
rows.

Roles (D16 of plans/cmux-next/chrome-parity/p14-energy.md, task 106): at the window's end each task's base priority
(proc_pidinfo pti_priority) and the kernel's darwinbg bit give its observed role (darwinbg, suppressed, default:
observed_role). The app and the Chromium Host (task 128) are napped while no window shows; renderers the debug.webui census marks hidden (or every
renderer while no window shows) and the extension process are best-effort (Chrome's kBestEffort); in tabs-static
(`judge_shown_renderers`) a renderer it marks shown is not backgrounded (kUserBlocking, task 107); the daemon and
terminal hosts are never backgrounded while a terminal shows; pooled acpmux agents are PRIO_DARWIN_BG. A budget
`role` (napped, best-effort, background, not-background; null: not judged) overrides the default. Each mismatch is
one `IDLE-BUDGET-OVER <session> <kind> role owner=role pids=... observed=... expected=...` line; a role that could not
be read and a renderer of unknown visibility are IDLE-BUDGET-NOT-JUDGED.
Reshow (task 107, tabs-static's `reshow`): after the window and its samples, a hidden Chromium tab whose renderer was
read best-effort is selected (action tab.focus, as a click does) and the roles are read again until its renderer is
not backgrounded and the tab shown before is best-effort, or RESHOW_WAIT_S passes (reshow_tab, IDLE-BUDGET-RESHOW).
Each renderer that does not change is one `IDLE-BUDGET-OVER tabs-static cef-renderer role owner=role pids=...
observed=... expected=... phase=reshow` line (reshow_audit); a reshow that could not run is IDLE-BUDGET-NOT-JUDGED.

Visibility (D17 of plans/cmux-next/chrome-parity/p14-energy.md, task 048): every tab session's page is a probe page
(PROBE_PAGE: tab_pages' static page plus a probe). It reports document.visibilityState at load and on each change,
and 11 s after it reports `hidden` (before the freeze grace ends) it counts its rAF callbacks and timer wakes for 4 s.
The report's `visibility` has, per tab, the state at the window's start and end, the last hidden probe and what is
wrong or unknown; `met` holds when every Chromium tab reports what it should (the shown tab `visible` unless the
session hides, minimizes or covers its window, every other `hidden`) and a hidden one ran no rAF and <= 1 timer wake/s.
Reported (IDLE-BUDGET-VISIBILITY), never an over. chrome-static's tabs get the same report as the reference.
--visibility-tab gives light, light-hidden, minimized and occluded one shown Chromium probe tab (off by default: it
changes their shape).

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Shipping measurement mode (always on; plans/cmux-next/chrome-parity/p14-energy.md, task 100): every cmux session
launches with bench_launch.shipping_env (CMUX_NEXT_BENCH_SHIPPING_DRAW=1: occluded windows stop drawing as in a
user's launch; CMUX_NEXT_DEV_SENTRY=1 and CMUX_NEXT_DEV_HANG_REPORTS=1: Sentry and hang reports run;
CMUX_NEXT_ISOLATED_LAUNCH=1 instead of CMUX_NEXT_NO_ACTIVATE: the app may activate, at the bench's fixed window
frame), with `diagnostics.hangReports` on and the tag's hang report consent record written
(bench_launch.seed_hang_report_consent), and activates the app once before the settle. The bundle's build config
(debug, bench-hooks, release) is read first. `--gate` refuses a Debug build (exit 2): its code and its draw are not
what users run. `--shipping-draw off` keeps the automation draw of occluded windows for an on/off comparison; only a
Debug build has that draw, so it is refused (exit 2) on any other build. Each session records build_config,
sentry_started (a SentryCrash thread runs in the app), hang_reports (debug.shipping_mode: available, setting,
decision, enabled; `on` when the app sends), draws_when_occluded (the app's WindowDrawPolicy.drawsWhenOccluded and
PageWebView.rendersWhenCovered from debug.shipping_mode, with the launch env's prediction as a cross-check:
IDLE-BUDGET-DRAW-MISMATCH) and activated. `--gate` refuses a session that was not activated, ran without Sentry or
without hang reports.

Budget: scripts/cmux-next/idle-budget.json, schema v2 (its _doc): per process kind with per-session overrides,
sums (app+daemon, tree), ratios to another session of the run and to chrome-static (judged once every session
is measured, whatever the --sessions order), xbench rows (--xbench), allowed_periodic (wakeup-audit.py; an entry
with `kind` and `metrics` also excuses that kind's D15 metric, only toward its `remote` when it names one) and
assertions_allowed_when. A missing or unknown value is reported, not judged (IDLE-BUDGET-NOT-JUDGED lines); a sum
with one unknown part is unknown; a v1 file (kinds only) still loads. Every session runs with both keep-awake
settings off. Over budget prints IDLE-BUDGET-OVER lines (a disk, network or log over names its pids, remote ends or
log owners); the exit code is 0 unless --gate (no CI gate: the perf cron runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress|all] [--settle 60] [--measure 60] [--json DIR/idle-budget.json] [--gate]
  D6 on an xbench.py result (any host): python3 scripts/cmux-next/idle-budget.py --xbench OUT/results.json [--gate]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions tabs-static,energy-saver
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- \\
        --sessions home,occluded,app-quit,external-churn      (Release + CMUX_BENCH_HOOKS: these four can --gate)
  The signed-in sessions need a Debug build of the same tag (no --gate; their own rows are not judged there):
    python3 scripts/cmux-next/idle-budget.py --app "<...>/Debug/cmux DEV <tag>.app" --out DIR \\
        --sessions light-hidden,signed-in,signed-in-display-sleep

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, IDLE-BUDGET-UNCLASSIFIED <session> pid <pid> other:<exe>: <command> for each process no kind names (also an IDLE-BUDGET-OVER
`kind other != classified`), IDLE-BUDGET-GOAL for a number the plan names a goal (reported, never an over),
IDLE-BUDGET-ENERGY / -STATE / -ASSERTION / -ANIM / -CHROME / -VISIBILITY lines, IDLE-BUDGET-SHAPE {json} for what a session
built (signed in or not, the cover, Home, the sign-in and sign-out, the display sleep, the quit, the churn counts),
IDLE-BUDGET-TEARDOWN for a teardown step that failed (the later steps still run), IDLE-BUDGET-REFUSED for a saver
mismatch, an unread rAF rate or a failed or unequal chrome-static, IDLE-BUDGET-THERMAL for a marked session,
IDLE-BUDGET-FRAME-CLIENTS when the build has debug.wakeups, IDLE-BUDGET-WINDOWSERVER per session,
IDLE-BUDGET-READER-FAILED for a D15 reader that failed, POWER-BREAKDOWN / -OWNER / -UNNAMED / -WINDOWSERVER for the
power sessions and POWER-OVER <owner> <mW>, IDLE-BUDGET-MODE with the shipping fields, for a hidden session
`HIDDEN-WAKE {json}` per source and one `HIDDEN-WAKE-TOTAL {json}` with sha and host, a Markdown table, and --json
with every sample.

Results (cmux-perf-result/v1, p12-perf-process-063): each cmux session that measured writes its perf cron rows
(cron_rows, one value per window, p50 = p95 = p99) into --out through BenchApp.record, and every cmux session writes
`idle_budget.<session>.failed` (1 when it did not measure) once its app answered (a session whose app was never
built or never answered has no build or features to name). Stories (idle_burst_bench_report.idle_budget_story):
idle-budget (the Chromium light sessions), idle-budget-webkit (light-webkit) and idle-budget-stress (STRESS); the
sessions of one story in one invocation share one run. The reference sessions (chrome-static, chrome-power-visible)
measure another browser and write none.
"""
import argparse, contextlib, dataclasses, fcntl, fnmatch, glob, hashlib, json, os, platform, plistlib, re, select, \
    shlex, shutil, socket, sqlite3, subprocess, sys, tempfile, threading, time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)
import tab_pages  # noqa: E402  (the tab-page server and the Chromium process classifier)
import power_attribution  # noqa: E402  (who spends the idle power: owners, breakdown, POWER-OVER)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root): {thread id: (cpu ns, name)} of a pid now, {} when it is gone

threads = power_attribution.thread_cpu


# ---------------------------------------------------------------------------------------------------------
# Process kinds (the budget's keys)

# Chromium utility processes by service (content/browser/utility_process_host.cc names them by
# --utility-sub-type, the mojo interface the process serves).
UTILITY_KINDS = {"network.mojom.NetworkService": "cef-network", "storage.mojom.StorageService": "cef-storage",
                 "audio.mojom.AudioService": "cef-audio"}


# The app's own one-shot tools (GitHubCLIClient's `gh`, AgentPaneGitProcess's and the file pages' `git`, RipgrepSearch's
# `rg`, DiffSidecarLauncher's bundled `cmux-diff-sidecar`) and what they run: `app-tool`.
APP_TOOLS = ("gh", "git", "rg", "cmux-diff-sidecar")
# The Now Playing stream (MediaRemoteAdapterProcess): `/bin/sh -c <parentWatch> /usr/bin/perl .../mediaremote-adapter.pl
# ... stream`, its `{ while read }` subshell (the same argv) and the perl adapter: `now-playing`.
NOW_PLAYING_SCRIPT = "/mediaremote-adapter.pl"


def executable(cmd):
    """The executable path of a `ps` command line: its first word, or through a bundle whose name has a space
    (`/Applications/cmux DEV.app/Contents/Resources/bin/cmux-diff-sidecar rpc ...`) the word after its `.app/`."""
    head = cmd.split(" --", 1)[0].strip()
    first = head.split(" ", 1)[0]
    if ".app/" in head and first.startswith("/") and ".app/" not in first:
        bundle, rest = head.rsplit(".app/", 1)
        if " -" not in bundle and rest.strip():
            return bundle + ".app/" + rest.split(" ", 1)[0]
    return first


def app_tool(cmd):
    return os.path.basename(executable(cmd)) in APP_TOOLS


def kind(cmd, pid=None, window=None, under_agent_host=False):
    """The budget kind of a process of the app's set. With `pid` and `window` (WindowKinds: the window's process
    tree and WebKit census) also what the command line alone cannot tell: a terminal's job (under a terminal host
    or a holder), an agent's harness, what the app's tools and its Now Playing stream run, and whether a WebContent
    process runs cmux's own pages. `other:<executable>` is a process no rule names: an over in every judged session
    (over_budget). `under_agent_host`: the process descends from an acpmux agent host (procs.agent_harness_pids), so it
    is the harness of an agent session or of a pooled entry, or a tool that harness runs: `agent-harness`, whatever
    its command. The host itself is acpmux code: `acpmux`."""
    if under_agent_host:
        return procs.AGENT_HARNESS
    ancestors = [command for _parent, command in window.tree.ancestors(pid)] if window is not None and pid is not None else []
    for command in ancestors:
        if "__terminal-host" in command or procs.is_holder(command):
            return "terminal-job"  # the person's shell and what it runs, not cmux's work
        if procs.is_agent_host(command):
            return procs.AGENT_HARNESS
    if procs.is_agent_host(cmd):
        return "acpmux"
    if procs.is_holder(cmd):
        return "holder"
    if "__terminal-host" in cmd:
        return "terminal-host"
    if re.search(r"/bin/cmux-tui(\s|$)", cmd):
        return "daemon"
    if re.search(r"/bin/acpmux(\s|$)", cmd):
        return "acpmux"
    if "--type=crashpad-handler" in cmd or "chrome_crashpad_handler" in cmd:
        return "crashpad"
    if procs.CRASH_WATCHER.search(cmd):
        return "crash-watcher"
    if NOW_PLAYING_SCRIPT in cmd or any(NOW_PLAYING_SCRIPT in command for command in ancestors):
        return "now-playing"
    if app_tool(cmd) or any(app_tool(command) for command in ancestors):
        return "app-tool"
    chromium = tab_pages.chromium_kind(cmd)
    if chromium == "cef-utility":
        service = re.search(r"--utility-sub-type=(\S+)", cmd)
        return UTILITY_KINDS.get(service.group(1) if service else "", "cef-utility")
    if chromium:
        return chromium
    if "com.apple.WebKit." in cmd:
        service = "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
        if service != "webkit-webcontent" or window is None or window.app_pages is None or pid is None:
            return service
        return "webkit-app-page" if pid in window.app_pages else "webkit-browser-tab"
    exe = cmd.split(" --", 1)[0]
    if procs.CUA_HELPER_APP in exe:
        return "cua-helper"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "app"
    return "other:" + os.path.basename(executable(cmd))[:32]


class WindowKinds:
    """`kind` of one window's processes, with what their command lines cannot tell, from the window's end: the
    process tree of the app's set (`rows`: its [(pid, ppid, command)], the same `ps` read as the set, ProcessSet)
    and the debug.webui census (`census`, {} for a build without one; see webkit_app_pages and hidden_pids).
    `shown_tab` is a tab session's shown browser tab (build_tabs), None in a session without one. `hidden(pid,
    kind)` is whether the process runs only hidden pages; a WebContent of a build with no census stays
    webkit-webcontent and is never hidden. `shown(pid, kind)` is whether the census reports the process running a
    visible page or the shown tab; a process that is neither is of unknown visibility (no census, or a browser tab
    of a session without `shown_tab`). `harness` ({pid: agent host pid}, procs.Instance.harness) names the agent
    harness processes; one is hidden when its host is one of `hidden_hosts` (the agent hosts of hidden panes)."""

    def __init__(self, rows, census=None, shown_tab=None, harness=None, hidden_hosts=()):
        census = census if isinstance(census, dict) else {}
        self.harness = harness or {}
        self.hidden_hosts = set(hidden_hosts)
        self.tree = procs.ProcessTree(rows)
        self.app_pages = webkit_app_pages(census)
        self.visible_pids, hidden = census_visibility(census, shown_tab)
        self.hidden_pids = hidden - self.visible_pids
        # The shown tab is a Chromium one, so every WebKit browser tab is hidden behind it.
        self.webkit_tabs_hidden = bool(shown_tab) and shown_tab.get("engine") == "chromium"

    def __call__(self, cmd, pid=None):
        return kind(cmd, pid, self, under_agent_host=pid in self.harness)

    def hidden(self, pid, name):
        if pid in self.harness:
            return self.harness[pid] in self.hidden_hosts
        if name == "webkit-browser-tab":
            return self.webkit_tabs_hidden
        return pid in self.hidden_pids

    def shown(self, pid, name):
        if name == "webkit-browser-tab":
            return False if self.webkit_tabs_hidden else None
        return pid in self.visible_pids


def census_pid(value):
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value == int(value) else None


def host_pids(row):
    """The content processes of one debug.webui row: its WebContent pid and its Chromium renderer pids."""
    values = [row.get("webkit_pid")] + list(row.get("renderer_pids") if isinstance(row.get("renderer_pids"), list) else [])
    return {pid for pid in map(census_pid, values) if pid is not None}


def census_rows(census, key):
    return [row for row in census.get(key) or [] if isinstance(row, dict)] if isinstance(census.get(key), list) else []


def webkit_app_pages(census):
    """The WebContent pids of cmux's own pages and spares from a debug.webui reply (WebUICensus: `pages` and
    `spares`, each with `webkit_pid`), or None when the build has no census. Any other WebContent of the app is a
    browser tab's: WebKit browser tabs are the only other WKWebViews the app makes."""
    if not isinstance(census.get("pages"), list):
        return None
    pids = (census_pid(row.get("webkit_pid")) for row in census_rows(census, "pages") + census_rows(census, "spares"))
    return {pid for pid in pids if pid is not None}


def hidden_pids(census, shown_tab=None):
    """The content processes (WebContent and Chromium renderer pids) that run only hidden pages, from a debug.webui
    reply: a page whose `state` is hidden, every spare (Chrome counts no spare renderer as visible), and with
    `shown_tab` ({engine, tabs: the shown browser tabs' census names}) every other Chromium browser tab. A process
    that also runs a visible page or the shown tab is not hidden. Browser tabs have no state in the census, so
    without `shown_tab` none is counted either way."""
    visible, hidden = census_visibility(census, shown_tab)
    return hidden - visible


def census_visibility(census, shown_tab=None):
    """(visible, hidden): the content processes running a visible page or the shown tab, and those running a hidden
    page, a spare or another browser tab (hidden_pids). A process can be in both."""
    visible, hidden = set(), set()
    for page in census_rows(census, "pages"):
        (hidden if page.get("state") == "hidden" else visible).update(host_pids(page))
    for spare in census_rows(census, "spares"):
        hidden.update(host_pids(spare))
    shown = (shown_tab or {}).get("tabs")
    if shown:
        for tab in census_rows(census, "browser_tabs"):
            (visible if tab.get("tab") in shown else hidden).update(host_pids(tab))
    return visible, hidden


class ProcessSet(dict):
    """{pid: command} of the app's set, with `rows`: the [(pid, ppid, command)] of its processes from the same `ps`
    read, so the kinds' process tree (WindowKinds) and the set are one instant."""

    def __init__(self, commands, rows):
        super().__init__(commands)
        self.rows = rows


def process_set(instance):
    """The app's processes plus their descendants (the terminals' jobs: `terminal-job`), from one `ps` read."""
    table = procs.process_table()
    found = dict(instance.pids(table))
    children = {}
    commands = {}
    for pid, ppid, cmd in table:
        children.setdefault(ppid, []).append(pid)
        commands[pid] = cmd
    stack = list(found)
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in found and child in commands:
                found[child] = commands[child]
                stack.append(child)
    # The tree of the set alone: a bench started from a cmux terminal must not make the app a terminal's job.
    return ProcessSet(found, [row for row in table if row[0] in found])


# ---------------------------------------------------------------------------------------------------------
# One window


# Seconds between the start's state reads and the first counter read.
QUIET_GAP_S = 1.0


def read_rpc(app, method, params=None):
    reply = app.rpc(method, params or {}, timeout=30)
    return reply if isinstance(reply, dict) and not reply.get("error") else {}


def window_end(app, pids, read_anim=None):
    """What one end of the window records outside the process counters: the app's energy policy (debug.energy:
    the saver state; unknown with `app` None, after the app quit), the Mac's thermal state, the power assertions of
    the pid set and, with `read_anim` (IdlePages.read_anim), the animated page's rAF count."""
    saver, reason = saver_state(read_rpc(app, "debug.energy") if app is not None else {})
    end = {"saver": saver, "saver_reason": reason, "thermal": procs.thermal_state(),
           "assertions": procs.power_assertions(pids)}
    if read_anim is not None:
        end["anim"] = read_anim()
    return end


def saver_state(reply):
    """(isSaver, reason) from a debug.energy reply (`policy`: EnergyPolicy, `inputs.reason`); (None, None) when the
    build has no debug.energy or the reply has no boolean isSaver."""
    policy = reply.get("policy") if isinstance(reply.get("policy"), dict) else {}
    inputs = reply.get("inputs") if isinstance(reply.get("inputs"), dict) else {}
    saver = policy.get("isSaver")
    if not isinstance(saver, bool):
        return None, None
    return saver, policy.get("reason") or inputs.get("reason")


def measure(app, instance, seconds, read_anim=None, attribute=False, shown_tab=None, workdir=None, d15=None,
            ledger_limit=20, hidden_hosts=()):
    """Counters of every process of the app over `seconds` with no input (`ledger_limit` busiest ledger owners,
    None: all). The window's end reads (window_end and
    the debug.webui census the kinds need) sit outside every counter bracket, the app's own counters included, so
    the bench's reads are never counted. Each row's kind and `hidden` come from one WindowKinds (the `last` set's
    own `ps` rows, the census and `shown_tab`, build_tabs's), which also names the power owners; a process that
    exited inside the window is named from the `first` set's rows. With `attribute`, `power` has the window's power
    owners: power_attribution.PowerWindow's subprocesses (ps, sudo) run before `first` and after `last`, outside
    this bracket and its own; only its libproc reads sit inside.
    D15's readers (`d15`, default D15Readers()): WindowServer's reads sit outside the bracket; nettop (its CSV in
    `workdir`) starts before the bracket and before PowerWindow lists the coalition, runs in its own process and only
    its samples stamped inside the window count; `log show` reads logd after it. None of them wakes a measured
    process, and nettop's own counters leave the coalition's (PowerWindow's `outside`, coalition_without).
    Processes that exit inside the window keep their D15 values (`exited`, aggregate).
    The agent harness processes (procs.Instance.harness of the last process_set read, the table that named
    `last_pids`) are kind agent-harness, with `agent_host`; those under one of `hidden_hosts` (the agent host pids of
    hidden panes) are `hidden` rows. With `app` None (app-quit: the app is gone) only the process counters and D15
    are read, no socket at all."""
    d15 = d15 or D15Readers()

    def rpc(method, params=None):
        return read_rpc(app, method, params) if app is not None else {}

    pids = process_set(instance)
    start = window_end(app, pids, read_anim)
    nettop = d15.start_network(seconds + NETTOP_LEAD_S, workdir)
    helper = d15.network_pid(nettop)
    helper = helper if helper is not None and same_coalition(helper, instance.pid) else None
    window = power_attribution.PowerWindow(instance.pid, lambda: process_set(instance), kind) if attribute else None
    if window:
        window.prepare()
    time.sleep(QUIET_GAP_S)  # bench: the start reads' aftermath (the page's POST, the RPC's reply) ends before the counters
    hangs0 = rpc("debug.hangs", {"limit": 0})
    ledger0 = rpc("debug.wakeups", {"run_loop": True})
    sources0 = frame_sources(app) if attribute and app is not None else None
    counters0 = app_counters(app) if app is not None else {}
    server0 = d15.windowserver()
    first = snapshot(pids)
    gpu0 = procs.gpu_ns_by_pid()
    if window:
        window.begin()
    coalition0 = procs.coalition_of(instance.pid)
    helper0 = procs.usage(helper) if helper is not None else None
    began, wall_began = time.monotonic(), time.time()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed, wall_ended = time.monotonic() - began, time.time()
    coalition1 = procs.coalition_of(instance.pid)
    helper1 = procs.usage(helper) if helper is not None else None
    if window:
        window.end()
    gpu1 = procs.gpu_ns_by_pid()
    last_pids = process_set(instance)
    harness = {pid: host for pid, host in instance.harness.items() if pid in last_pids}
    last = snapshot(last_pids)
    server1 = d15.windowserver()
    power = window.finish() if window else None
    hangs1 = rpc("debug.hangs", {"limit": 0})
    ledger1 = rpc("debug.wakeups", {"run_loop": True})
    sources1 = frame_sources(app) if attribute and app is not None else None
    counters1 = app_counters(app) if app is not None else {}
    # debug.webui runs on the app's main actor: read after every counter, with the window's other end reads.
    census = rpc("debug.webui")
    classify = WindowKinds(last_pids.rows, census, shown_tab, harness, hidden_hosts)
    end = window_end(app, last_pids, read_anim)
    # The roles at the window's end, after every counter (proc_pidinfo wakes no process); the pooled agents from the
    # set's own `ps` rows.
    priority = procs.priorities(last_pids)
    pooled = pool_pids(last_pids, last_pids.rows, acpmux_homes(getattr(app, "launched_env", None)))
    network = d15.finish_network(nettop, wall_began, wall_ended)
    logs = d15.read_log(set(pids) | set(last_pids), wall_began, wall_ended)
    network = NOT_MEASURED if network is None else network
    logs = NOT_MEASURED if logs is None else logs
    rows = process_rows(first, last, elapsed, gpu0, gpu1, classify, network=network, logs=logs, harness=harness,
                        hidden_hosts=hidden_hosts)
    for row in rows:
        row["hidden"] = classify.hidden(row["pid"], row["kind"])
        row["shown"] = classify.shown(row["pid"], row["kind"])
    rows = with_roles(rows, priority, pooled)
    coalition = procs.coalition_rates(coalition0, coalition1, elapsed)
    if helper is not None:
        coalition = coalition_without(coalition, helper0, helper1, elapsed)
    result = {"seconds": round(elapsed, 1), "processes": rows, "ends": {"start": start, "end": end},
              "browser_tabs": census_tab_pids(census),
              "exited": exited_rows(first, last, WindowKinds(pids.rows, census, shown_tab), network=network, logs=logs),
              "coalition": coalition,
              "readers": {"network": network is not NOT_MEASURED, "log": logs is not NOT_MEASURED},
              "windowserver": windowserver_report(windowserver_rate(server0, server1), None, server1[2])}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed, limit=ledger_limit)
    if owners is not None:
        result["ledger"] = owners
    if owners is not None or attribute:
        result["frame_clients"] = power_attribution.frame_clients(ledger0, ledger1, elapsed,
                                                                  (sources0, sources1) if attribute else None)
    if power is not None:
        result["power"] = power_attribution.attribute({**power, "classify": classify})
    rates = {key: round((counters1[key] - counters0[key]) / elapsed, 3) for key in counters1
             if key in counters0 and counters1[key] != counters0[key]}
    if rates:
        result["app_counter_rates"] = rates
    if ledger1.get("main_run_loop"):
        result["main_run_loop_timers"] = run_loop_timers(ledger1["main_run_loop"])
        if ledger0.get("main_run_loop"):
            result["main_run_loop_timer_fires"] = timer_fires(ledger0["main_run_loop"], ledger1["main_run_loop"], elapsed)
    return result


# nettop starts before the bracket (PowerWindow's prepare, the quiet gap, the first reads): it samples this lead plus
# the window, so it still samples when the window ends; a longer lead leaves the window uncovered (not measured).
NETTOP_LEAD_S = 15


def same_coalition(pid, main_pid):
    """Whether `pid` is in the resource coalition of `main_pid` (False when either cannot be read)."""
    cid = procs.coalition_id(pid)
    return cid is not None and cid == procs.coalition_id(main_pid)


def coalition_without(coalition, first, last, elapsed):
    """procs.coalition_rates less one member's procs.rates over the same window (the bench's nettop), or None when
    either is unknown: a process the bench added is never counted as the app's."""
    if coalition is None or first is None or last is None:
        return None
    member = procs.rates(first, last, elapsed)
    less = {field: round(coalition[field] - member[field], 3)
            for field in ("energy_mw_cpu", "energy_mw_billed", "cpu_pct", "wakeups_per_s", "pkg_idle_wakeups_per_s")}
    return {**coalition, **less}


def frame_sources(app):
    """The app's frame sources no FrameScheduler sees (debug.layers `frame_sources`: infinite Core Animation loops
    and playing video layers per owner view), or None when the build does not report them."""
    got = read_rpc(app, "debug.layers", {"frame_sources": True}).get("frame_sources")
    return got if isinstance(got, dict) else None


def snapshot(commands):
    """{pid: (command, procs.Usage, task overhead, threads)} of `commands` ({pid: command}) now."""
    return {pid: (cmd, procs.usage(pid), procs.overhead(pid), threads(pid)) for pid, cmd in commands.items()}


class _NotMeasured:
    """A D15 reader (nettop, `log show`) that ran and failed: its row values are None (not measured), never 0."""

    def __repr__(self):
        return "NOT_MEASURED"


NOT_MEASURED = _NotMeasured()


def process_rows(first, last, elapsed, gpu0, gpu1, classify, network=None, logs=None, harness=None, hidden_hosts=()):
    """One row per process alive at the window's end, from two snapshots and two GPU reads `elapsed` seconds
    apart, its kind from `classify`; a process that started inside the window counts from its start (`partial`).
    Every row has its disk bytes written; `network` (procs.parse_nettop) and `logs` (procs.parse_log) are {pid:
    reading}, NOT_MEASURED when their reader failed, or None when the run did not read them (no such fields).
    `harness` ({pid: agent host pid}, procs.Instance.harness) names the agent harness processes: kind agent-harness,
    with `agent_host`, and `hidden` when that host is one of `hidden_hosts`."""
    harness = harness or {}
    rows = []
    for pid, (cmd, c1, o1, t1) in sorted(last.items()):
        if c1 is None or o1 is None:
            continue
        (_, c0, o0, t0) = first.get(pid, (cmd, None, None, {}))
        partial = c0 is None
        o0 = o0 or (0, 0, 0, 0, 0)
        ran = []
        for tid, (cpu, name) in t1.items():
            before = t0.get(tid, (0, name))[0] if not partial else 0
            if cpu > before:
                ran.append({"tid": tid, "name": name or "", "cpu_us": round((cpu - before) / 1000, 1)})
        ran.sort(key=lambda t: -t["cpu_us"])
        row = process_row(pid, cmd, c0, c1, elapsed, gpu=procs.gpu_ms_per_s(gpu0, gpu1, pid, elapsed),
                          threads_now=o1[1], csw=procs._delta32(o1[4], o0[4]), ran=ran, classify=classify,
                          disk=max(0, o1[0] - o0[0]), network=_reading(network, pid), log=_reading(logs, pid),
                          under_agent_host=pid in harness)
        if pid in harness:
            row["agent_host"] = harness[pid]
            if harness[pid] in hidden_hosts:
                row["hidden"] = True
        rows.append(row)
    return rows


def _reading(readings, pid):
    """The pid's entry of a whole-run D15 reading: NOT_MEASURED and None pass through; a pid the reader did not
    list read nothing ({})."""
    if readings is None or readings is NOT_MEASURED:
        return readings
    return readings.get(pid, {})


def process_row(pid, cmd, first, last, elapsed, gpu, threads_now, csw, ran, classify=None, disk=None, network=None,
                log=None, under_agent_host=False):
    """One process's row of the window from two procs.Usage reads (`first` None: it started inside the
    window, `partial`); its kind from `classify(cmd, pid)` (default: the cmux kinds, `kind`). D15: `disk` is the bytes it wrote
    in the window; `network` and `log` its procs.parse_nettop and procs.parse_log entries, NOT_MEASURED when the
    reader failed (the values are None), None when not read (the row has no such fields). A process
    `under_agent_host` is agent-harness."""
    got = procs.rates(first, last, elapsed)
    name = procs.AGENT_HARNESS if under_agent_host else (classify or kind)(cmd, pid)
    row = {
        "pid": pid, "kind": name, "command": cmd[:160], "partial": first is None,
        "threads": threads_now, "threads_ran": len(ran), "ran": ran[:8],
        "cpu_pct": round(got["cpu_pct"], 4),
        "wakeups_per_s": round(got["wakeups_per_s"], 3),
        "pkg_idle_wakeups_per_s": round(got["pkg_idle_wakeups_per_s"], 3),
        "energy_mw_cpu": round(got["energy_mw_cpu"], 3),
        "energy_mw_billed": round(got["energy_mw_billed"], 3),
        "gpu_ms_per_s": None if gpu is None else round(gpu, 3),
        "csw_per_s": round(csw / elapsed, 3),
        "footprint_mb": round(last.footprint / procs.MB, 1),
    }
    if disk is not None:
        row.update({"disk_bytes": disk, "disk_bytes_per_s": round(disk / elapsed, 3)})
    row.update(d15_fields(network, log))
    return row


def d15_fields(network, log):
    """A row's network and log fields from its procs.parse_nettop and procs.parse_log entries: NOT_MEASURED gives
    None values, None (not read) no fields."""
    row = {}
    if network is not None:
        unknown = network is NOT_MEASURED
        net = {} if unknown else network
        row.update({"network_bytes": None if unknown else net.get("bytes", 0),
                    "network_loopback_bytes": None if unknown else net.get("loopback_bytes", 0),
                    "connections": None if unknown else net.get("connections", 0),
                    "remotes": list(net.get("remotes") or []),
                    "remote_bytes": dict(net.get("remote_bytes") or {})})
    if log is not None:
        unknown = log is NOT_MEASURED
        lines = {} if unknown else log
        row.update({"log_lines": None if unknown else lines.get("lines", 0),
                    "log_owners": dict(lines.get("owners") or {})})
    return row


def exited_rows(first, last, classify, network=None, logs=None):
    """A D15-only row per process read at the window's start and gone at its end: its network bytes and log lines
    from the whole-window readings, its disk bytes unknown (None: its rusage left with it). It has no rate fields
    (an exited process never had rates); aggregate adds it to its kind's D15 values."""
    rows = []
    for pid, (cmd, c0, _o0, _t0) in sorted(first.items()):
        if c0 is None or (pid in last and last[pid][1] is not None):
            continue
        row = {"pid": pid, "kind": classify(cmd, pid), "command": cmd[:160], "exited": True, "disk_bytes": None,
               "disk_bytes_per_s": None}
        row.update(d15_fields(_reading(network, pid), _reading(logs, pid)))
        rows.append(row)
    return rows


@dataclasses.dataclass(frozen=True)
class NettopRun:
    """A running start_nettop: its process, its CSV and when its last sample is due (time.monotonic())."""
    process: subprocess.Popen
    path: str
    due: float

    @property
    def pid(self):
        return self.process.pid


def start_nettop(seconds, workdir=None):
    """nettop sampling for the coming `seconds`, its CSV in workdir/nettop.csv (workdir None: a new temporary
    folder), or None when it cannot start."""
    try:
        workdir = workdir or tempfile.mkdtemp(prefix="idle-budget-nettop-")
        path = os.path.join(workdir, "nettop.csv")
        os.makedirs(workdir, exist_ok=True)
        with open(path, "w") as handle:  # the child keeps its own descriptor
            process = subprocess.Popen(procs.nettop_command(seconds), stdout=handle, stderr=subprocess.DEVNULL,
                                       stdin=subprocess.DEVNULL)
    except OSError:
        return None
    return NettopRun(process, path, time.monotonic() + seconds)


def finish_nettop(started, start, end):
    """procs.parse_nettop of a start_nettop run over the window start..end (epoch seconds) once nettop has printed
    its last sample, or None when it failed or its samples do not cover the window."""
    if started is None:
        return None
    try:
        started.process.wait(timeout=max(0.0, started.due - time.monotonic()) + 30)
    except subprocess.TimeoutExpired:
        started.process.kill()
        started.process.wait()
        return None
    if started.process.returncode != 0:
        return None
    with open(started.path, errors="replace") as handle:
        return procs.parse_nettop(handle.read(), start, end)


# ---------------------------------------------------------------------------------------------------------
# WindowServer wakeups (D15: reported, never judged; WindowServer serves every app on the host)


def windowserver_reading(table=None, root_usage=None, top_idlew=None, clock=time.monotonic):
    """(pid, cumulative wakeups, source, time) of WindowServer now: its interrupt wakeups through `sudo -n`
    (power_attribution.root_usage, source `rusage`), else top's IDLEW (`top-idlew`: package idle wakeups only),
    else (pid, None, `unreadable`, time). The seams default to the live readers."""
    pid = power_attribution.window_server_pid(procs.process_table() if table is None else table)
    if pid is None:
        return None, None, "not-found", clock()
    got = (root_usage or power_attribution.root_usage)(pid)
    if got is not None:
        return pid, got.interrupt_wakeups, "rusage", clock()
    value = (top_idlew or procs.top_idlew)(pid)
    return pid, value, ("top-idlew" if value is not None else "unreadable"), clock()


def windowserver_rate(before, after):
    """WindowServer wakeups/s between two windowserver_reading()s, or None: another pid (a restart), another
    source, an unreadable end."""
    pid0, value0, source0, at0 = before
    pid1, value1, source1, at1 = after
    if pid0 != pid1 or source0 != source1 or value0 is None or value1 is None or at1 <= at0:
        return None
    return round((value1 - value0) / (at1 - at0), 3)


def windowserver_report(window_rate, reference_rate, source, reference="hidden"):
    """WindowServer's wakeups/s in the window, in the reference window with cmux hidden (`reference`: `hidden`, or
    `self` when the session is itself hidden), and the delta cmux adds."""
    delta = None
    if window_rate is not None and reference_rate is not None:
        delta = round(window_rate - reference_rate, 3)
    return {"source": source, "wakeups_per_s": window_rate, "hidden_reference_per_s": reference_rate,
            "reference": reference, "delta_per_s": delta}


REFERENCE_SETTLE_S = 5  # the hide lands (the window leaves the screen) before the reference window opens


def windowserver_reference(app, seconds):
    """(WindowServer wakeups/s over `seconds` with cmux hidden, the hide's reply, `hidden` or `hide-failed`): the
    reference the window's delta is taken against. It runs after the session's window and samples, so it changes
    nothing that was measured. A hide the app refused, or after which a main window still shows, takes no reference
    (None, `hide-failed`): with cmux shown it would give a plausible delta near 0."""
    reply = hide_all(app)
    if not isinstance(reply, dict) or reply.get("error"):
        return None, reply, "hide-failed"
    time.sleep(REFERENCE_SETTLE_S)  # bench: the hide lands before the reference window opens
    if not hidden_confirmed(window_state(app)):
        return None, reply, "hide-failed"
    before = windowserver_reading()
    time.sleep(seconds)  # bench: the reference window itself
    return windowserver_rate(before, windowserver_reading()), reply, "hidden"


def hidden_confirmed(state):
    """Whether a window_state() shows no visible main window (an unreadable state confirms nothing)."""
    return "error" not in state and not any(window.get("visible") for window in state.get("main") or [])


@dataclasses.dataclass(frozen=True)
class D15Readers:
    """measure's D15 readers (each resolved at the call, so a test's patch applies); tests pass fakes."""
    windowserver: object = lambda: windowserver_reading()  # noqa: E731
    start_network: object = lambda seconds, workdir: start_nettop(seconds, workdir)  # noqa: E731
    finish_network: object = lambda started, start, end: finish_nettop(started, start, end)  # noqa: E731
    network_pid: object = lambda started: None if started is None else started.pid  # noqa: E731
    read_log: object = lambda pids, start, end: procs.read_log(pids, start, end)  # noqa: E731


def hide_all(app):
    """Show/Hide All Windows hidden=true, from a script (light-hidden's hide and the WindowServer reference's)."""
    return app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True}, "focus": False,
                                  "origin": "script"}, timeout=30)


TIMER_RE = re.compile(r"<CFRunLoopTimer [^>]*>\{valid = (\w+), firing = \w+, interval = ([0-9.e+-]+),[^}]*?"
                      r"next fire date = ([0-9.e+-]+)[^}]*?callout = ([^,}]+)")


def run_loop_timers(description):
    """The main run loop's timers from its CFCopyDescription: callout, interval (0: one-shot) and next fire
    date, one entry per timer (a timer in several common modes appears once). Repeating timers wake the main
    thread outside the wakeup ledger."""
    seen = {}
    for valid, interval, fire, callout in TIMER_RE.findall(description):
        key = (callout.strip(), interval, fire)
        if valid == "Yes":
            seen[key] = {"callout": callout.strip()[:160], "interval_s": float(interval), "next_fire": float(fire)}
    return sorted(seen.values(), key=lambda t: (t["interval_s"] == 0, t["interval_s"]))


def window_state(app):
    """The app's main windows from its control socket (`debug.window_list`, no AX): key, visible, occluded,
    miniaturized; and whether the app is active. A system prompt over the window shows as not key or occluded."""
    reply = app.rpc("debug.window_list", timeout=10)
    windows = reply.get("windows") if isinstance(reply, dict) else None
    if not isinstance(windows, list):
        return {"error": str(reply)[:200]}
    main = [{k: w.get(k) for k in ("key", "visible", "occluded", "miniaturized", "alpha")} for w in windows if w.get("kind") == "main"]
    return {"main": main, "any_key": any(w.get("key") for w in windows)}


def run_sample(pid, seconds, path):
    """`/usr/bin/sample` of `pid` for `seconds` after the window (it suspends the process to sample, so it never runs
    inside the measured window); its text, "" when it failed."""
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path], capture_output=True,
                       timeout=seconds + 60)
        return open(path, errors="replace").read()
    except (OSError, subprocess.TimeoutExpired):
        return ""


BLOCKING_SYMBOLS = ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait", "__select", "__ulock_wait")
WAIT_SYMBOLS = BLOCKING_SYMBOLS + ("start_wqthread", "thread_start", "_pthread_start")
THREAD_HEAD_RE = re.compile(r"\s{4}(\d+) Thread_\d+(.*)")
FRAME_RE = re.compile(r"[\s+!:|]*(\d+) (.+?)\s+\(in ([^)]+)\)")


def call_graph(text):
    """The `Call graph:` part of a `/usr/bin/sample` report."""
    return text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]


def threads_from_sample(text):
    """Per thread of a `/usr/bin/sample` report, the frames with the most samples outside the wait."""
    threads_out = {}
    current = None
    for line in call_graph(text).splitlines():
        head = THREAD_HEAD_RE.match(line)
        if head:
            name = head.group(2).strip(" :") or "thread"
            current = {"samples": int(head.group(1)), "frames": {}}
            threads_out[f"{name} ({head.group(1)})"] = current
            continue
        frame = FRAME_RE.match(line)
        if current is not None and frame:
            count, symbol, image = int(frame.group(1)), frame.group(2), frame.group(3)
            if any(wait in symbol for wait in WAIT_SYMBOLS):
                continue
            key = f"{symbol} ({image})"
            current["frames"][key] = max(current["frames"].get(key, 0), count)
    for entry in threads_out.values():
        entry["frames"] = sorted(entry["frames"].items(), key=lambda kv: -kv[1])[:12]
    return threads_out


# ---------------------------------------------------------------------------------------------------------
# Hidden main wakes (p14-energy-095): who wakes the main thread while no window can be seen

# CFRunLoop's callout trampolines (CoreFoundation CFRunLoop.c), the frame below __CFRunLoopRun that says why the main
# thread is awake. A timer, a source, a main-queue drain or a block wakes the run loop; observers run on every wake
# one of those causes, so they are listed but never counted as a cause. Chromium's MessagePumpCFRunLoopBase
# (base/message_loop/message_pump_apple.mm) has the same split: a work source and a delayed-work timer wake it,
# observers only bracket the loop.
RUN_LOOP_CALLOUTS = {
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__": "timer",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__": "source0",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__": "source1",
    "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__": "main-queue",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__": "block",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__": "observer",
}
# The trace's kind codes (D keeps integers in thread-locals); 0 is a wake that no callout claimed.
TRACE_KIND_CODES = {"no-callout": 0, "timer": 1, "source0": 2, "source1": 3, "main-queue": 4, "block": 5, "observer": 6}
TRACE_KINDS = {code: kind for kind, code in TRACE_KIND_CODES.items()}
# The (function, item) key of each callout, as DTrace expressions on its entry (CFRunLoop.c's callout signatures):
# a timer by its callback and CFRunLoopTimerRef, a source0 by its perform function and info, a source1 by its perform
# function and info (its fifth argument), a block by its invoke pointer (Block_layout.invoke, 16 bytes in), an
# observer by its callback and CFRunLoopObserverRef. The main-queue drain is keyed by each item it runs instead.
CALLOUT_KEYS = {"timer": ("arg0", "arg1"), "source0": ("arg0", "arg1"), "source1": ("arg0", "arg4"),
                "block": ("*(uint64_t *)copyin(arg0 + 16, 8)", "0"), "observer": ("arg0", "arg1")}
# A Swift job's RunJob/ResumeTask (swift/ABI/Task.h Job: HeapObject, SchedulerPrivate[2], Flags, Id, Voucher,
# Reserved, then the function): for a task, the partial function it resumes.
SWIFT_JOB_FUNCTION_OFFSET = 56
ADDRESS_MASK = 0x7FFFFFFFFFFF  # drops the pointer-auth bits
WAKE_CAUSES = ("timer", "source0", "source1", "main-queue", "block")
# Where the OS's images live (the dyld shared cache's images have these paths too); every other image (the app
# binary, its frameworks, Sentry, Chromium Embedded Framework) is an owner.
OS_IMAGE_PREFIXES = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")
# Only for an image the report gives no `Binary Images:` path for: the OS images most often on its paths.
FALLBACK_OS_IMAGES = {"CoreFoundation", "Foundation", "AppKit", "HIToolbox", "SkyLight", "QuartzCore", "CoreGraphics",
                      "CoreText", "CFNetwork", "IOKit", "Security", "Metal", "CoreVideo", "CoreDisplay", "ViewBridge",
                      "SwiftUI", "SwiftUICore", "AttributeGraph", "Combine", "Observation", "CoreServices", "Network",
                      "LaunchServices", "AE", "CarbonCore", "RunningBoardServices", "HIServices", "CoreUI", "dyld"}
# Trampolines: a frame in these images with no owner below it passes its samples down to the frame that does the
# work (a run-loop, dispatch, runtime or Swift job frame does none itself).
TRAMPOLINE_IMAGES = {"CoreFoundation", "Foundation", "libdispatch.dylib", "libobjc.A.dylib", "libswift_Concurrency.dylib"}
SWIFT_THUNKS = ("thunk for ", "reabstraction thunk", "partial apply for ", "@objc ", "merged ")
BINARY_IMAGE_RE = re.compile(r"^\s*(0x[0-9a-fA-F]+)\s+-\s+(\S+)\s+.*?<[0-9A-Fa-f-]+>\s+(/.+?)\s*$")
ATOS_RE = re.compile(r"(.+?) \(in ([^)]+)\)")


def image_ranges(text):
    """[(start, end, path)] of a `/usr/bin/sample` report's `Binary Images:` part: where each image is loaded in that
    process (an end of `???` makes a one-byte range)."""
    out = []
    for line in text.split("Binary Images:", 1)[1].splitlines() if "Binary Images:" in text else []:
        match = BINARY_IMAGE_RE.match(line)
        if match:
            start = int(match.group(1), 16)
            end = int(match.group(2), 16) if match.group(2).startswith("0x") else start
            out.append((start, end, match.group(3)))
    return out


def binary_images(text):
    """{image name: path} from a `/usr/bin/sample` report's `Binary Images:` part (the call graph's `(in NAME)` is
    the image file's name)."""
    images = {}
    for _start, _end, path in image_ranges(text):
        images.setdefault(os.path.basename(path), path)
    return images


def image_at(address, ranges):
    """The path of the image loaded at `address` (image_ranges), or None."""
    return next((path for start, end, path in ranges or () if start <= address <= end), None)


def is_system_image(image, images=None):
    """An OS image (by its path in the report), whose frames do not name an owner."""
    path = (images or {}).get(image)
    if path:
        return path.startswith(OS_IMAGE_PREFIXES)
    return image in FALLBACK_OS_IMAGES or (image.startswith("lib") and image.endswith(".dylib"))


def is_wait(node):
    return any(wait in node["symbol"] for wait in BLOCKING_SYMBOLS)


def names_no_owner(node):
    """True for a frame that can not name an owner: an OS image, or a Swift thunk with a frame below it."""
    return node["system"] or (node["symbol"].startswith(SWIFT_THUNKS) and bool(node["children"]))


def main_thread_tree(text):
    """The main thread's call tree in a `/usr/bin/sample` report, nested {symbol, image, system, count, children}
    (the thread on com.apple.main-thread, else the first thread); None when the report has no thread."""
    images = binary_images(text)
    order = []
    stack = []
    for line in call_graph(text).splitlines():
        head = THREAD_HEAD_RE.match(line)
        if head:
            thread = {"symbol": head.group(2).strip(" :") or "thread", "image": "", "system": True,
                      "count": int(head.group(1)), "children": []}
            order.append(thread)
            stack = [(-1, thread)]
            continue
        frame = FRAME_RE.match(line)
        if not stack or not frame:
            continue
        depth = frame.start(1)
        node = {"symbol": frame.group(2), "image": frame.group(3), "system": is_system_image(frame.group(3), images),
                "count": int(frame.group(1)), "children": []}
        while len(stack) > 1 and stack[-1][0] >= depth:
            stack.pop()
        stack[-1][1]["children"].append(node)
        stack.append((depth, node))
    main = [thread for thread in order if "com.apple.main-thread" in thread["symbol"]]
    return (main or order or [None])[0]


def owner_name(node):
    return f"{node['symbol'][:120]} ({node['image']})"


def busy(node):
    """Samples of `node` that ran: its count less the samples blocked in a wait below it (a nested run loop, a
    condition wait), which are not wake time."""
    def waited(n):
        return n["count"] if is_wait(n) else sum(waited(child) for child in n["children"])
    return node["count"] - waited(node)


def attribute(node, label, add):
    """Gives each sample below a callout to its owner: the first frame in an owner image takes all of its running
    samples; a sample with no owner frame goes to the first non-trampoline frame on its own path (`label`), so two OS
    handlers under one callout stay two owners. Wait frames take nothing."""
    if is_wait(node):
        return
    if not names_no_owner(node):
        add(owner_name(node), busy(node))
        return
    if label is None and node["image"] not in TRAMPOLINE_IMAGES:
        label = owner_name(node)
    own = node["count"] - sum(child["count"] for child in node["children"])
    if own > 0:
        add(label or owner_name(node), own)
    for child in node["children"]:
        attribute(child, label, add)


def callout_owners(tree):
    """{(kind, callback, owner): samples} of the main thread's outermost run-loop callouts. `callback` is the frame
    the callout calls, the key the DTrace count has too (None for the main queue drain, which has no callback)."""
    out = {}

    def adder(kind, callback):
        def add(owner, count):
            if count > 0:
                out[(kind, callback, owner)] = out.get((kind, callback, owner), 0) + count
        return add

    pending = [tree] if tree else []
    while pending:
        node = pending.pop()
        kind = RUN_LOOP_CALLOUTS.get(node["symbol"])
        if not kind:
            pending.extend(node["children"])
            continue
        for child in node["children"]:
            attribute(child, None, adder(kind, None if kind == "main-queue" else owner_name(child)))
        adder(kind, None)(owner_name(node), node["count"] - sum(child["count"] for child in node["children"]))
    return out


def main_callouts_from_samples(texts):
    """[{kind, callback, owner, samples}] of the main thread's run-loop callouts, summed over `/usr/bin/sample`
    reports, most first."""
    total = {}
    for text in texts:
        for key, count in callout_owners(main_thread_tree(text)).items():
            total[key] = total.get(key, 0) + count
    rows = [{"kind": kind, "callback": callback, "owner": owner, "samples": count}
            for (kind, callback, owner), count in total.items()]
    return sorted(rows, key=lambda r: (-r["samples"], r["kind"], r["owner"]))


def wake_trace_script(main_tid, seconds):
    """A DTrace script of the main thread (`main_tid`) for `seconds`, its span measured from BEGIN (after the probes
    are enabled) to END. It counts:

    - WAKES: returns from a run-loop wait that can block (__CFRunLoopServiceMachPort with a timeout other than 0; the
      main-queue port poll has 0);
    - FIRST: each wake once, given to the first non-observer callout after it (for a main-queue drain, its first
      item; a drain with no item is the drain's), or to kind 0 when the next blocking wait comes first;
    - CALL: every callout entry, by (function, item) (CALLOUT_KEYS), and each item of an outermost main-queue drain:
      a dispatch function, a block (_dispatch_call_block_and_release's invoke) or a Swift job's resume function;
    - STACK: 997 Hz stacks while an outermost callout runs, by the same key, to name an item from its own frames.

    Addresses lose their pointer-auth bits."""
    tid, mask = f"tid == {int(main_tid)}", f"0x{ADDRESS_MASK:x}"
    cf = "pid$target:CoreFoundation"
    drain = f"{tid} && self->ik == {TRACE_KIND_CODES['main-queue']} && self->cd == 1"
    items = "pid$target:libdispatch.dylib:_dispatch_client_callout:{0}, pid$target:libswift_Concurrency.dylib:swift_job_run:{0}"
    job = f"*(uint64_t *)copyin(arg0 + {SWIFT_JOB_FUNCTION_OFFSET}, 8) & {mask}"
    lines = ["#pragma D option quiet", "#pragma D option ustackframes=64",
             *(f"self int {name};" for name in ("wake", "blk", "cd", "ik", "qd", "qref")),
             *(f"self uint64_t {name};" for name in ("ia", "ib", "qa")),
             "BEGIN { began = timestamp; }",
             f"{cf}:__CFRunLoopServiceMachPort:entry /{tid} && arg4 != 0 && self->wake/ "
             f"{{ @first[self->wake == 2 ? {TRACE_KIND_CODES['main-queue']} : 0, (uint64_t)0, (uint64_t)0] = count(); "
             "self->wake = 0; }",
             f"{cf}:__CFRunLoopServiceMachPort:entry /{tid}/ {{ self->blk = arg4 != 0; }}",
             f"{cf}:__CFRunLoopServiceMachPort:return /{tid} && self->blk/ {{ @wakes = count(); self->wake = 1; self->blk = 0; }}"]
    for function, kind in RUN_LOOP_CALLOUTS.items():
        code, probe = TRACE_KIND_CODES[kind], f"{cf}:{function}:entry"
        if kind == "main-queue":
            lines += [f"{probe} /{tid} && self->wake == 1 && self->cd == 0/ {{ self->wake = 2; }}",
                      f"{probe} /{tid} && self->wake == 1/ {{ @first[{code}, (uint64_t)0, (uint64_t)0] = count(); "
                      "self->wake = 0; }",
                      f"{probe} /{tid} && self->cd == 0/ {{ self->ik = {code}; self->ia = 0; self->ib = 0; }}"]
        else:
            function_expr, item_expr = CALLOUT_KEYS[kind]
            lines.append(f"{probe} /{tid}/ {{ this->a = (uint64_t)({function_expr}) & {mask}; "
                         f"this->b = (uint64_t)({item_expr}) & {mask}; @calls[{code}, this->a, this->b] = count(); }}")
            if kind != "observer":
                lines.append(f"{probe} /{tid} && self->wake == 1/ {{ @first[{code}, this->a, this->b] = count(); "
                             "self->wake = 0; }")
            lines.append(f"{probe} /{tid} && self->cd == 0/ {{ self->ik = {code}; self->ia = this->a; self->ib = this->b; }}")
        lines.append(f"{probe} /{tid}/ {{ self->cd++; }}")
    returns = ", ".join(f"{cf}:{function}:return" for function in RUN_LOOP_CALLOUTS)
    lines += [f"{returns} /{tid} && self->cd > 0/ {{ self->cd--; }}",
              f"{returns} /{tid} && self->cd == 0/ {{ self->ik = 0; self->ia = 0; self->ib = 0; }}",
              # One item per outermost dispatch callout or Swift job of the drain; a block or a job inside a dispatch
              # function names that item instead.
              f"pid$target:libdispatch.dylib:_dispatch_client_callout:entry /{drain} && self->qd == 0/ "
              f"{{ self->qa = arg1 & {mask}; self->qref = 0; }}",
              f"pid$target:libswift_Concurrency.dylib:swift_job_run:entry /{drain} && (self->qd == 0 || "
              f"(self->qd == 1 && !self->qref))/ {{ self->qa = {job}; self->qref = 1; }}",
              f"pid$target:libdispatch.dylib:_dispatch_call_block_and_release:entry /{drain} && self->qd == 1 && "
              f"!self->qref/ {{ self->qa = *(uint64_t *)copyin(arg0 + 16, 8) & {mask}; self->qref = 1; self->ia = self->qa; }}",
              f"{items.format('entry')} /{drain}/ {{ self->qd++; self->ia = self->qa; }}",
              f"{items.format('return')} /{drain} && self->qd > 0/ {{ self->qd--; }}",
              f"{items.format('return')} /{drain} && self->qd == 0 && self->qa/ "
              f"{{ @calls[{TRACE_KIND_CODES['main-queue']}, self->qa, (uint64_t)0] = count(); }}",
              f"{items.format('return')} /{drain} && self->qd == 0 && self->qa && self->wake == 2/ "
              f"{{ @first[{TRACE_KIND_CODES['main-queue']}, self->qa, (uint64_t)0] = count(); self->wake = 0; }}",
              f"{items.format('return')} /{drain} && self->qd == 0/ {{ self->qa = 0; self->ia = 0; }}",
              f"profile-997 /pid == $target && {tid} && self->ik/ {{ @stacks[self->ik, self->ia, self->ib, ustack()] = count(); }}",
              f"tick-{max(1, int(seconds))}s {{ exit(0); }}",
              'END { printf("SPAN %d\\n", timestamp - began); printa("WAKES %@d\\n", @wakes); '
              'printa("CALL %d %x %x %@d\\n", @calls); printa("FIRST %d %x %x %@d\\n", @first); '
              'printa("STACK %d %x %x %@d\\n%k\\nEND-STACK\\n", @stacks); }']
    return "\n".join(lines) + "\n"


TRACE_ROW_RE = re.compile(r"^(CALL|FIRST|STACK) (\d+) ([0-9a-f]+) ([0-9a-f]+) (\d+)$")


def parse_wake_trace(output):
    """{span_ns, wakes, calls, first, stacks} from the trace's output: calls and first map (kind, function, item) to a
    count, stacks map it to [(frames innermost first, count)]."""
    parsed = {"span_ns": None, "wakes": 0, "calls": {}, "first": {}, "stacks": {}}
    stack = None
    for raw in output.splitlines():
        line = raw.strip()
        if stack is not None:
            if line == "END-STACK":
                parsed["stacks"].setdefault(stack[0], []).append((tuple(stack[1]), stack[2]))
                stack = None
            elif line:
                stack[1].append(line)
            continue
        if line.startswith("SPAN ") and line[5:].isdigit():
            parsed["span_ns"] = int(line[5:])
        elif line.startswith("WAKES ") and line[6:].isdigit():
            parsed["wakes"] += int(line[6:])
        match = TRACE_ROW_RE.match(line)
        if not match or int(match.group(2)) not in TRACE_KINDS:
            continue
        key = (TRACE_KINDS[int(match.group(2))], int(match.group(3), 16), int(match.group(4), 16))
        if match.group(1) == "STACK":
            stack = (key, [], int(match.group(5)))
        else:
            table = parsed["calls" if match.group(1) == "CALL" else "first"]
            table[key] = table.get(key, 0) + int(match.group(5))
    return parsed


def stack_frame(line):
    """(image, symbol) of one DTrace ustack line (`image`symbol+0x1c`; a bare address has no image)."""
    if "`" not in line:
        return None, line
    image, rest = line.split("`", 1)
    return image, rest.rsplit("+0x", 1)[0]


def stack_owner(frames, images=None):
    """The owner of one DTrace stack taken in a callout (frames innermost first): below the outermost run-loop
    callout, the first frame in an owner image (a Swift thunk with a frame below it does not count), else the first
    OS frame outside the trampoline images; None when no frame below the callout names one."""
    path = [stack_frame(line) for line in reversed(frames)]
    start = next((index for index, (_image, symbol) in enumerate(path) if symbol in RUN_LOOP_CALLOUTS), None)
    if start is None:
        return None
    below, handler = path[start + 1:], None
    for index, (image, symbol) in enumerate(below):
        if not image or any(wait in symbol for wait in BLOCKING_SYMBOLS):
            continue
        node = {"symbol": symbol, "image": image, "system": is_system_image(image, images),
                "children": below[index + 1:index + 2]}
        if not names_no_owner(node):
            return owner_name(node)
        if handler is None and node["system"] and image not in TRAMPOLINE_IMAGES:
            handler = owner_name(node)
    return handler


def callback_name(address, symbols, images=None, ranges=None):
    """(callback, named, system) of a callout function address: atos's `symbol (image)` when it resolved, else the
    address with the image it is loaded in. `system` comes from the image's path (image_ranges) when the sample has
    it, so the OS or owner decision never rests on atos; None when neither knows the image."""
    path = image_at(address, ranges)
    match = ATOS_RE.match(symbols.get(address, ""))
    symbol, image = (match.group(1), match.group(2)) if match else (None, None)
    image = image or (os.path.basename(path) if path else None)
    if path:
        system = path.startswith(OS_IMAGE_PREFIXES)
    else:
        system = is_system_image(image, images) if image else None
    if symbol and not symbol.startswith("0x"):
        return f"{symbol[:120]} ({image})", True, system
    return (f"0x{address:x} (in {image})" if image else f"0x{address:x}"), False, system


def trace_callouts(parsed, seconds, symbols, images=None, ranges=None):
    """[{kind, callback, callback_named, callback_system, item, calls, calls_per_s, wakes, per_s, stack_samples,
    stack_owners}] from a parsed trace, one row per (kind, function, item): `per_s` is the wakes it claimed (the
    rows add up to the trace's wakes), `calls_per_s` its callout entries; `stack_owners` names it from its own
    stacks only."""
    rows = []
    for key in sorted(set(parsed["calls"]) | set(parsed["first"]), key=lambda k: (k[0], k[1], k[2])):
        kind, function, item = key
        callback, named, system = callback_name(function, symbols, images, ranges) if function else (None, True, None)
        owners = {}
        for frames, count in parsed["stacks"].get(key, []):
            owner = stack_owner(frames, images)
            if owner:
                owners[owner] = owners.get(owner, 0) + count
        sampled = sum(owners.values())
        calls, wakes = parsed["calls"].get(key, 0), parsed["first"].get(key, 0)
        rows.append({"kind": kind, "callback": callback, "callback_named": named, "callback_system": system,
                     "item": f"0x{item:x}" if item else None, "calls": calls, "wakes": wakes,
                     "calls_per_s": round(calls / seconds, 3), "per_s": round(wakes / seconds, 3),
                     "stack_samples": sampled,
                     "stack_owners": [{"owner": owner, "share": round(count / sampled, 3)}
                                      for owner, count in sorted(owners.items(), key=lambda kv: -kv[1])[:3]]})
    return sorted(rows, key=lambda r: (-r["wakes"], -r["calls"], r["kind"], r["callback"] or ""))


def privileged(tool):
    """`tool` through `sudo -n` unless this is root: DTrace's pid provider needs root, and atos needs the same right
    to read a Release app's task."""
    return [tool] if os.geteuid() == 0 else ["sudo", "-n", tool]


def symbolize(pid, addresses):
    """{address: atos line} for the callback addresses in process `pid` ({} when atos can not run)."""
    addresses = sorted(a for a in addresses if a)
    if not addresses:
        return {}
    try:
        run = subprocess.run([*privileged("/usr/bin/atos"), "-p", str(pid), *(f"0x{a:x}" for a in addresses)],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    return dict(zip(addresses, run.stdout.splitlines())) if run.returncode == 0 else {}


def demangle_stacks(stacks):
    """`stacks` with Swift symbols demangled (`xcrun swift-demangle`); unchanged when it can not run."""
    lines = sorted({line for entries in stacks.values() for frames, _count in entries for line in frames})
    if not lines:
        return stacks
    try:
        run = subprocess.run(["/usr/bin/xcrun", "swift-demangle", "--simplified"], input="\n".join(lines) + "\n",
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return stacks
    out = run.stdout.splitlines()
    if run.returncode != 0 or len(out) != len(lines):
        return stacks
    names = dict(zip(lines, out))
    return {key: [(tuple(names[line] for line in frames), count) for frames, count in entries]
            for key, entries in stacks.items()}


def count_main_callouts(app, seconds, folder):
    """Traces the main thread for `seconds` (DTrace pid provider, wake_trace_script): {ok, error, seconds (the
    trace's own span), main_wakes, main_wakes_per_s (wakes on that span), parsed}. The debug.hangs `main_wakes`
    bracket around the dtrace run is kept apart (`rpc_main_wakes_per_s` over `rpc_seconds`, which include dtrace's
    start and exit) and never set against the trace's counts. ok False with the reason when DTrace can not run (no
    root, SIP, a restricted process). name_trace turns `parsed` into named rows."""
    pid = app.process.pid
    ids = threads(pid)
    if not ids:
        return {"ok": False, "error": "the app has no threads", "seconds": None, "callouts": []}
    script = os.path.join(folder, "wake-trace.d")
    with open(script, "w") as handle:
        handle.write(wake_trace_script(min(ids), seconds))  # the main thread is the first: its id is the lowest
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    began = time.monotonic()
    try:
        run = subprocess.run([*privileged("/usr/sbin/dtrace"), "-p", str(pid), "-s", script], capture_output=True,
                             text=True, timeout=seconds + 120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": f"dtrace: {error}"[:300], "seconds": None, "callouts": []}
    elapsed = time.monotonic() - began
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    if run.returncode != 0:
        return {"ok": False, "error": f"dtrace exit {run.returncode}: {run.stderr.strip()[-300:]}", "seconds": None,
                "callouts": []}
    parsed = parse_wake_trace(run.stdout)
    if not parsed["span_ns"]:
        return {"ok": False, "error": "dtrace printed no SPAN line", "seconds": None, "callouts": []}
    span = parsed["span_ns"] / 1e9
    result = {"ok": True, "error": "", "seconds": round(span, 3), "main_wakes": parsed["wakes"],
              "main_wakes_per_s": round(parsed["wakes"] / span, 3), "parsed": parsed}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1 and elapsed > 0:
        result["rpc_seconds"] = round(elapsed, 1)
        result["rpc_main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    return result


def name_trace(trace, pid, sample_text=None):
    """The trace with `callouts` (trace_callouts) in place of its parsed counts: callback addresses through atos and
    the sample report's `Binary Images:` ranges (the same process, so the same load addresses)."""
    parsed = trace.pop("parsed", None)
    trace.setdefault("callouts", [])
    if not trace.get("ok") or parsed is None:
        return trace
    images = binary_images(sample_text) if sample_text else None
    ranges = image_ranges(sample_text) if sample_text else []
    keys = set(parsed["calls"]) | set(parsed["first"])
    symbols = symbolize(pid, {function for _kind, function, _item in keys})
    parsed = {**parsed, "stacks": demangle_stacks(parsed["stacks"])}
    trace["callouts"] = trace_callouts(parsed, trace["seconds"], symbols, images, ranges)
    return trace


TIMER_ENTRY_RE = re.compile(r"<CFRunLoopTimer (0x[0-9a-fA-F]+)[^>]*>\{valid = (\w+), firing = \w+, interval = "
                            r"([0-9.e+-]+),[^}]*?next fire date = ([0-9.e+-]+)[^}]*?callout = (.*?)"
                            r"(?:, context = ([^}]*))?\}")
# Callouts every timer of a kind shares: they name Foundation, not the timer's owner (NSTimer and Swift's Timer).
GENERIC_TIMER_CALLOUTS = ("__NSFireTimer",)


def repeating_timers(description):
    """{timer address: {interval_s, next_fire, callout, context}} of the valid repeating timers of a main run loop
    description (a timer in several modes appears once)."""
    found = {}
    for address, valid, interval, fire, callout, context in TIMER_ENTRY_RE.findall(description or ""):
        if valid == "Yes" and float(interval) > 0:
            found[address] = {"interval_s": float(interval), "next_fire": float(fire), "callout": callout.strip()[:160],
                              "context": (context or "").strip()[:160]}
    return found


def timer_owner(address, timer):
    """(owner, named): the timer's callout, or for a callout every timer shares (__NSFireTimer) the timer itself,
    marked unnamed (the trace names it from the timer's own stacks)."""
    if timer["callout"].startswith(GENERIC_TIMER_CALLOUTS):
        return f"unnamed NSTimer {address} (context {timer['context'] or '?'})", False
    return timer["callout"], True


def timer_fires(before, after, elapsed):
    """Fires per second of each repeating main run-loop timer between two `CFCopyDescription`s of the main run loop
    (debug.wakeups `run_loop`), by timer address: its next fire date advances one interval per fire. A timer at
    only one end, or whose interval changed, is a row with per_s None and its `unpaired` reason. A fire the run
    loop skipped (App Nap) counts as a fire, so the rate is an upper bound."""
    first, last = repeating_timers(before), repeating_timers(after)
    out = []
    for address in sorted(set(first) | set(last)):
        old, new = first.get(address), last.get(address)
        timer = new or old
        owner, named = timer_owner(address, timer)
        row = {"timer": address, "owner": owner, "named": named, "callout": timer["callout"],
               "context": timer["context"], "interval_s": timer["interval_s"], "per_s": None}
        if old is None or new is None or old["interval_s"] != new["interval_s"]:
            row["unpaired"] = ("created in the window" if old is None else "gone at the end" if new is None
                               else "interval changed")
            out.append(row)
            continue
        fired = max(0, round((new["next_fire"] - old["next_fire"]) / new["interval_s"]))
        if fired and elapsed > 0:
            row["per_s"] = round(fired / elapsed, 3)
            out.append(row)
    return sorted(out, key=lambda t: (-(t["per_s"] or 0), t["owner"]))


HIDDEN_WAKE_FLOOR = 0.1  # per second: every main wake source above it is named


def row_owner(row, timers_by_address):
    """(owner, owner_from) of one traced item: its callback when atos named it in an owner image; for a timer, the
    run-loop timer at the same address when its callout names it; else the owner frame of the item's own stacks;
    else unnamed."""
    if row["callback"] and row["callback_named"] and row["callback_system"] is False:
        return row["callback"], "callback"
    timer = timers_by_address.get(int(row["item"], 16)) if row["kind"] == "timer" and row["item"] else None
    if timer and timer.get("named"):
        return timer["owner"], "timer"
    if row["stack_owners"]:
        return row["stack_owners"][0]["owner"], "item-stack"
    where = row["callback"] or "main queue drain, no item ran"
    return f"unnamed {row['kind']} ({where}{', item ' + row['item'] if row['item'] else ''})", "none"


def counted_sources(trace, timers, floor):
    """The `callout-count` sources: each traced main-thread item (kind, function, item) that claimed more than `floor`
    wakes per second or ran more than `floor` callouts per second, named by row_owner. `per_s` is wakes/s (the
    sources add up to the trace's wakes with the no-callout wakes), `calls_per_s` callout entries/s. An item whose
    own stacks show several owners (a source that runs many kinds of work) is `multiplexed`: its owners carry time
    shares, not rates."""
    by_address = {int(t["timer"], 16): t for t in timers if str(t.get("timer", "")).startswith("0x")}
    out = []
    for row in trace.get("callouts") or []:
        if row["kind"] not in WAKE_CAUSES or max(row["per_s"], row["calls_per_s"]) <= floor:
            continue
        owner, owner_from = row_owner(row, by_address)
        out.append({"basis": "callout-count", "kind": row["kind"], "owner": owner, "owner_from": owner_from,
                    "per_s": row["per_s"], "calls_per_s": row["calls_per_s"], "callback": row["callback"],
                    "callback_named": row["callback_named"], "item": row["item"],
                    "top": row["stack_owners"][0]["owner"] if row["stack_owners"] else row["callback"],
                    "multiplexed": len(row["stack_owners"]) > 1, "stack_samples": row["stack_samples"],
                    "stack_owners": row["stack_owners"]})
    return sorted(out, key=lambda s: (-s["per_s"], -s["calls_per_s"]))


def hidden_wake_sources(result, floor=HIDDEN_WAKE_FLOOR):
    """The main thread's wake sources of a hidden session, one list per basis. A source can be in more than one
    basis, so the bases are never summed and `sources_by_basis` counts each apart:

    - `callout-count`: the DTrace trace of the main thread (`wake_trace`): each wake given once to the first item
      that ran after it, per second of the trace's own span (`counted_sources`).
    - `unattributed`: with a trace, its wakes that no callout claimed before the next wait (the same span); without
      one, the window's main wakes less the run-loop timer fires (both over the window).
    - `run-loop-timer`: each repeating main run-loop timer's fires, by timer; unpaired timers with per_s None.
    - `ledger`: wakeup ledger owners (DemandTimer, FrameScheduler, Backoff) on any thread (`thread: any`).
    - `frames` (sample-time): the `/usr/bin/sample` owners' share of the main thread's callout time. Samples measure
      time, not wakes, so per_s is None and no floor applies: they name frames, they do not rank sources.

    Observers are not causes and come back apart. `naming_problems` lists what makes the names unsure (callbacks atos
    did not name); the caller adds them to the session's problems."""
    main_wakes = result.get("main_wakes_per_s")
    trace = result.get("wake_trace") or {"ok": False, "error": "not run", "callouts": []}
    callouts = result.get("main_callouts") or []
    causes = [c for c in callouts if c["kind"] in WAKE_CAUSES]
    total = sum(c["samples"] for c in causes)
    all_timers = result.get("main_run_loop_timer_fires") or []
    timers = [t for t in all_timers if t.get("unpaired") or (t["per_s"] or 0) > floor]
    if trace.get("ok"):
        unattributed = round(sum(r["per_s"] for r in trace["callouts"] if r["kind"] == "no-callout"), 3)
        of = "trace wakes no callout claimed"
    elif isinstance(main_wakes, (int, float)):
        unattributed = round(max(0.0, main_wakes - sum(t["per_s"] for t in timers if t["per_s"])), 3)
        of = "window main wakes less run-loop timer fires"
    else:
        unattributed, of = None, None
    sources = counted_sources(trace, all_timers, floor)
    unnamed = sum(1 for s in sources if s["callback"] and not s["callback_named"])
    naming_problems = [f"atos failed: {unnamed} callbacks unnamed"] if unnamed else []
    if unattributed is not None and unattributed > floor:
        sources.append({"basis": "unattributed", "kind": "unattributed", "owner": "unattributed", "per_s": unattributed,
                        "top": None, "of": of})
    for timer in timers:
        sources.append({"basis": "run-loop-timer", "kind": "timer", "top": timer["callout"],
                        **{k: v for k, v in timer.items() if k != "next_fire"}})
    ledger = [{"basis": "ledger", "kind": "ledger", "owner": f"{e['owner']}:{e['reason']}", "per_s": e["per_s"],
               "thread": "any", "top": None}
              for e in (result.get("ledger") or {}).get("owners") or [] if e["per_s"] > floor]
    sources += sorted(ledger, key=lambda s: -s["per_s"])
    frames = [{"basis": "sample-time", "kind": c["kind"], "owner": c["owner"], "callback": c["callback"],
               "samples": c["samples"], "share": round(c["samples"] / total, 4), "per_s": None} for c in causes]
    observers = ([{"basis": "callout-count", **r} for r in trace.get("callouts") or [] if r["kind"] == "observer"]
                 + [{"basis": "sample-time", **c} for c in callouts if c["kind"] == "observer"])
    by_basis = {}
    for source in sources:
        by_basis[source["basis"]] = by_basis.get(source["basis"], 0) + 1
    return {"main_wakes_per_s": main_wakes, "trace_main_wakes_per_s": trace.get("main_wakes_per_s"),
            "trace": {k: trace.get(k) for k in ("ok", "error", "seconds", "main_wakes", "rpc_seconds",
                                                "rpc_main_wakes_per_s")},
            "cause_samples": total, "unattributed_per_s": unattributed, "sources": sources, "sources_by_basis": by_basis,
            "unnamed": sum(1 for s in sources if s.get("owner_from") == "none"), "naming_problems": naming_problems,
            "frames": frames, "observers": observers[:20]}


def hidden_wake_lines(session, report, build_sha, host, problems=()):
    """The `HIDDEN-WAKE {json}` lines of one hidden session for the Q9 slots (one per source and basis), the
    `HIDDEN-WAKE-FRAME` sample-time lines and observers, then one `HIDDEN-WAKE-TOTAL {json}` line with the build sha
    and host. When `problems` says the run was not the shipping app in the session's state, the source lines are
    `HIDDEN-WAKE-UNCONFIRMED` instead, so no Q9 task comes from them."""
    prefix = "HIDDEN-WAKE-UNCONFIRMED" if problems else "HIDDEN-WAKE"
    lines = [f"{prefix} " + json.dumps({"session": session, **source}) for source in report["sources"]]
    lines += ["HIDDEN-WAKE-FRAME " + json.dumps({"session": session, **frame}) for frame in report["frames"]]
    lines += ["HIDDEN-WAKE-OBSERVER " + json.dumps({"session": session, **o}) for o in report["observers"]]
    lines.append("HIDDEN-WAKE-TOTAL " + json.dumps({
        "session": session, "sha": build_sha, "host": host, "main_wakes_per_s": report["main_wakes_per_s"],
        "trace_main_wakes_per_s": report["trace_main_wakes_per_s"], "trace": report["trace"],
        "unattributed_per_s": report["unattributed_per_s"], "sources_by_basis": report["sources_by_basis"],
        "unnamed": report.get("unnamed", 0), "samples_taken": report.get("samples_taken", 0), "cause_samples": report["cause_samples"],
        "confirmed": not problems, "problems": list(problems), "floor_per_s": HIDDEN_WAKE_FLOOR}))
    return lines


class HiddenStateError(RuntimeError):
    """A hidden-wake session's app was not hidden or minimized as the session asked: its wakes are not hidden wakes."""


def hidden_state_problem(spec, state):
    """None when `window_state` shows the session's state (light-hidden: no main window visible; minimized: every
    main window miniaturized), else why not."""
    if not isinstance(state, dict) or "error" in state:
        return f"debug.window_list failed: {(state or {}).get('error')}"
    main = state.get("main") or []
    if not main:
        return "debug.window_list shows no main window"
    if spec.get("hide") and any(w.get("visible") for w in main):
        return "a main window is visible: the app is not hidden"
    if spec.get("minimize") and not all(w.get("miniaturized") for w in main):
        return "a main window is not miniaturized"
    return None


def shipping_problems(entry):
    """Why the session's applied mode (p14-energy-100's fields) is not the shipping app's; [] when it is: the
    shipping refusals (activation, Sentry, hang reports) and the app's own occluded-window draw answer."""
    problems = [f"{what}: {why}" for what, why in shipping_refusals(entry)]
    if ((entry.get("draws_when_occluded") or {}).get("windows")) is not False:
        problems.append("draws when occluded (the automation draw, not the shipping one)")
    return problems


def check_action_reply(name, reply):
    """Raises HiddenStateError when an `action.run` reply is an error."""
    if not isinstance(reply, dict) or reply.get("error"):
        raise HiddenStateError(f"action.run {name} failed: {str(reply)[:200]}")


def app_counters(app):
    """The app's own cumulative counters that can wake its main thread outside the ledger (the bench diffs two
    reads): the CEF pump (`debug.cef` pump: work runs, immediate and delayed requests from any thread), the
    Chromium page trackers (geometry posts and skips) and each window's child-window reorders (`debug.layers`)."""
    out = {}
    cef = read_rpc(app, "debug.cef")
    for group in ("pump", "tracker"):
        for key, value in (cef.get(group) or {}).items():
            if isinstance(value, (int, float)) and not key.endswith("_ms"):
                out[f"cef.{group}.{key}"] = value
    layers = read_rpc(app, "debug.layers")
    out["layers.reorders"] = sum(w.get("reorders", 0) for w in layers.get("windows") or [] if isinstance(w, dict))
    return out


def ledger_rates(before, after, elapsed, limit=20):
    """Wakeup ledger owners that fired in the window (debug.wakeups, when the build has it), the `limit` busiest
    (None: all)."""
    if not before.get("ledger") and not after.get("ledger"):
        return None
    counts = {(e["owner"], e["reason"]): e.get("count", 0) for e in before.get("ledger") or []}
    out = []
    for entry in after.get("ledger") or []:
        delta = entry.get("count", 0) - counts.get((entry["owner"], entry["reason"]), 0)
        if delta > 0:
            out.append({"owner": entry["owner"], "reason": entry["reason"], "per_s": round(delta / elapsed, 3)})
    out.sort(key=lambda e: -e["per_s"])
    return {"owners": out[:limit], "active_frame_clients": after.get("active_frame_clients", [])}


# ---------------------------------------------------------------------------------------------------------
# Budget


# Summed per kind (field: digits). A None in any process of the kind (GPU time with no IORegistry read)
# makes the kind's sum None: an unknown is never a 0.
SUMMED = {"wakeups_per_s": 3, "pkg_idle_wakeups_per_s": 3, "energy_mw_cpu": 3, "energy_mw_billed": 3,
          "gpu_ms_per_s": 3, "csw_per_s": 3, "cpu_pct": 4}
# D15's fields (task 105), recorded only by the runs that read them (chrome-static reads disk only): a kind whose
# rows have none has no value, so all_kinds judges nothing that was not read; a kind with a row that has it None (a
# failed reader) or lacks it while another has it is None: unknown, not measured, never a pass.
SUMMED_WHEN_PRESENT = {"disk_bytes": 0, "disk_bytes_per_s": 3, "network_bytes": 0, "network_loopback_bytes": 0,
                       "connections": 0, "log_lines": 0}


def aggregate(result):
    """Per kind: count, threads (sum and max per process), interrupt wakeups/s (sum and max per process, and the
    max over the processes of hidden pages), package-idle wakeups/s, CPU and billed energy (mW), GPU ms/s, context
    switches/s, CPU %, disk, network and log sums when the rows have them, with the processes that exited in the
    window (`exited`: their pids); the roles."""
    kinds = {}
    new_kind = lambda: {"n": 0, "threads": 0, "threads_max": 0, "wakeups_max": 0.0, "threads_ran": 0,  # noqa: E731
                        **{field: 0.0 for field in SUMMED}}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], new_kind())
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        if row.get("hidden"):
            entry["hidden_wakeups_max"] = max(entry.get("hidden_wakeups_max", 0.0), row["wakeups_per_s"])
        for field, digits in SUMMED.items():
            value = row.get(field, 0.0)
            entry[field] = None if entry[field] is None or value is None else round(entry[field] + value, digits)
        entry["threads_ran"] += row["threads_ran"]
        if row.get("role"):
            entry["roles"] = sorted(set(entry.get("roles", [])) | {row["role"]})
    exited = result.get("exited") or []
    for row in exited:  # D15-only rows of processes gone in the window: they count in their kind's D15 values
        kinds.setdefault(row["kind"], new_kind()).setdefault("exited", []).append(row["pid"])
    for name, entry in kinds.items():
        rows = [row for row in [*result["processes"], *exited] if row["kind"] == name]
        for field, digits in SUMMED_WHEN_PRESENT.items():
            if not any(field in row for row in rows):
                continue
            values = [row.get(field) for row in rows]
            # A row with it None (its reader failed) or without it while another has it: unknown, not their sum.
            entry[field] = round(sum(values), digits) if all(isinstance(v, (int, float)) for v in values) else None
        d15_owners(entry, rows)
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def d15_owners(entry, rows):
    """The owners of a kind's D15 values, for the over lines: `disk_writers` (the pids that wrote), `remotes` (the
    remote ends that moved bytes or stayed open), `remote_bytes` ({remote end: bytes moved}, what a remote-scoped
    excuse judges) and `log_owners` ({subsystem:category: lines})."""
    writers = [row["pid"] for row in rows if row.get("disk_bytes")]
    if writers:
        entry["disk_writers"] = writers
    remotes = list(dict.fromkeys(remote for row in rows for remote in row.get("remotes") or []))
    if remotes:
        entry["remotes"] = remotes
    remote_bytes = {}
    for row in rows:
        for remote, moved in (row.get("remote_bytes") or {}).items():
            remote_bytes[remote] = remote_bytes.get(remote, 0) + moved
    if remote_bytes:
        entry["remote_bytes"] = remote_bytes
    owners = {}
    for row in rows:
        for owner, count in (row.get("log_owners") or {}).items():
            owners[owner] = owners.get(owner, 0) + count
    if owners:
        entry["log_owners"] = dict(sorted(owners.items(), key=lambda kv: -kv[1]))


def energy_summary(kinds):
    """{"per_kind": {kind: {cpu, billed}}, "tree": {cpu, billed}} in mW: the CPU energy and the billed energy
    (aggregate's energy_mw_cpu and energy_mw_billed) of each kind and of the whole process set."""
    per_kind = {name: {"cpu": entry["energy_mw_cpu"], "billed": entry["energy_mw_billed"]}
                for name, entry in kinds.items()}
    tree = {field: round(sum(e[field] for e in per_kind.values()), 3) for field in ("cpu", "billed")}
    return {"per_kind": per_kind, "tree": tree}


def saver_mismatch(asked, observed):
    """Why the window's saver state is not the one the session asked for, or None. `observed` is the saver state
    debug.energy reported at each end (None: the build has no debug.energy). A session that asks for the saver
    needs both ends to show it; a session that asks for normal mode fails only on an end that shows the saver."""
    if asked and not all(state is True for state in observed):
        return f"asked energy saver on, debug.energy reported {observed}"
    if not asked and any(state is True for state in observed):
        return f"asked energy saver off, debug.energy reported {observed}"
    return None


def worst_thermal(states):
    """The hottest of `states` (ProcessInfo.thermalState names; None is unknown), or None when none is known."""
    known = [s for s in states if s in procs.THERMAL_STATES]
    return max(known, key=procs.THERMAL_STATES.index) if known else None


def thermal_marked(state):
    """Rows taken at serious or critical are marked: the Mac throttles, so the numbers are not comparable."""
    return state in ("serious", "critical")


def window_assertions(start, end):
    """The power assertions of the window's two reads, one entry per assertion (owning pid and assertion ID; its
    age differs between the reads) in first-seen order, each the latest read of it."""
    by_id = {}
    for item in (start or []) + (end or []):
        by_id[(item["pid"], item["id"])] = item
    return list(by_id.values())


def summarize(session, result, budget):
    """The report entry of one measured window: kinds, overs, energy_mw, assertions, saver, thermal (and the
    animated page's rAF rate when the session has one)."""
    spec = SESSIONS[session]
    ends = result.get("ends") or {}
    start, end = ends.get("start") or {}, ends.get("end") or {}
    kinds = aggregate(result)
    thermal = worst_thermal([start.get("thermal"), end.get("thermal")])
    marked = thermal_marked(thermal)
    if marked:
        for entry in kinds.values():
            entry["thermal_marked"] = True
    observed = [start.get("saver"), end.get("saver")]
    entry = {"result": result, "kinds": kinds, "energy_mw": energy_summary(kinds),
             "assertions": window_assertions(start.get("assertions"), end.get("assertions")),
             "saver": {"asked": spec.get("saver", False), "observed": observed,
                       "reason": end.get("saver_reason") or start.get("saver_reason"),
                       "mismatch": saver_mismatch(spec.get("saver", False), observed)},
             "thermal": {"start": start.get("thermal"), "end": end.get("thermal"), "worst": thermal, "marked": marked},
             "readers_failed": [reader for reader, ok in (result.get("readers") or {}).items() if not ok]}
    if result.get("windowserver"):
        entry["windowserver"] = result["windowserver"]
    if spec.get("anim"):
        entry["anim"] = anim_rate(start.get("anim"), end.get("anim"))
    if spec.get("power"):
        # A power session is reported, never judged: it has no budget row, and the default kinds are not its budget.
        entry["over"], entry["not_judged"] = [], []
        return entry
    roles, role_notes = role_audit(session, result["processes"], budget)
    reshown, reshow_notes = reshow_audit(session, result.get("reshow"))
    roles, role_notes = roles + reshown, role_notes + reshow_notes
    entry["role_mismatches"] = roles
    entry["over"] = [list(o) for o in over_budget(session, kinds, budget, window_facts(entry))]
    entry["over"] += [[m["kind"], "role", m["observed"], m["expected"]] for m in roles]
    entry["not_judged"] = kind_notes(session, kinds, budget) + sum_notes(session, kinds, budget) + role_notes \
        + deferred_notes(session, kinds, budget)
    entry["goals"] = goal_rows(budget, session, kinds)
    return entry


def goal_rows(budget, session, kinds):
    """The session's `goals` rows (an absolute number the plan names a goal, not a check: D4's cef-gpu 1.0/s), each
    with its value and whether it is met (None: the selector did not run or its value is unknown). Reported in
    IDLE-BUDGET-GOAL lines, never an over."""
    rows = []
    for goal in budget.get("goals") or []:
        if goal.get("session") != session:
            continue
        value = selector_value(kinds, goal["of"], goal["field"])
        rows.append({"of": goal["of"], "field": goal["field"], "max": goal["max"], "value": value,
                     "met": None if value is None else value <= goal["max"]})
    return rows


def window_facts(entry):
    """over_budget's `facts` of one summarized window: the animated page's rAF rate, the saver state and reason
    both ends agree on (none when an end did not report one) and the power assertions held by the pid set."""
    facts = {"assertions": entry["assertions"]}
    observed = entry["saver"]["observed"]
    if observed and isinstance(observed[0], bool) and all(state == observed[0] for state in observed):
        facts["saver"] = observed[0]
        if entry["saver"]["reason"] is not None:
            facts["saver_reason"] = entry["saver"]["reason"]
    rate = (entry.get("anim") or {}).get("raf_per_s")
    if isinstance(rate, (int, float)):
        facts["page_raf_per_s"] = rate
    return facts


def refusals(entry):
    """[(what, why)] that refuse a session's window under --gate: it did not run the shipping configuration
    (``shipping_refusals``), its saver state is not the one it asked for, or its animated page's rAF rate (D7's
    number) could not be read."""
    out = shipping_refusals(entry)
    if entry["saver"]["mismatch"]:
        out.append(("saver", entry["saver"]["mismatch"]))
    if "error" in (entry.get("anim") or {}):
        out.append(("anim", f"no page rAF rate: {entry['anim']['error']}"))
    return out + agent_refusals(entry.get("agents"), (entry.get("result") or {}).get("processes") or [])


def agent_refusals(agents, rows):
    """[(what, why)] for an agent session (build_agents's record) whose window did not measure the harnesses it
    built: no agent-harness row under the hidden chat's host, or none under a pooled host. A harness that exited
    has no row, and a limit on a kind with no row passes, so the D14 hidden-harness row would pass unmeasured."""
    if not agents:
        return []
    plan = agents.get("plan") or {}
    hosts = {row.get("agent_host") for row in rows if row.get("kind") == procs.AGENT_HARNESS}
    out = []
    if plan.get("hidden") and not hosts & set(agents.get("hidden_hosts") or ()):
        out.append(("agents", f"no agent-harness row under the hidden chat's host {agents.get('hidden_hosts')}"))
    if plan.get("pool") and not hosts & set(agents.get("pool_hosts") or ()):
        out.append(("agents", f"no agent-harness row under a pooled host {agents.get('pool_hosts')}"))
    return out


def exit_code(gate, overs, refused):
    """1 under --gate when a value is over its budget or a session was refused (`refusals`), else 0."""
    return 1 if gate and (overs or refused) else 0


def session_budget(budget, session):
    return (budget.get("sessions") or {}).get(session) or {}


def busy_kind(own, name):
    """Whether kind `name` takes only the session's own values: every kind of a reference session (Chrome) or of a
    session with `busy: true` (an agent at work), else a kind that matches one of the session's `busy` patterns
    (STRESS's animating pages: `cef-*`)."""
    busy = own.get("busy")
    if own.get("reference") or busy is True:
        return True
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in busy or [])


def limit_for(budget, session, name, field):
    """The limit of `field` for kind `name` in `session`: the session's own value (an explicit null there means
    not judged), else the kind's default (one number or {session: number}), else all_kinds. A busy kind
    (busy_kind) takes only the session's own values."""
    own = session_budget(budget, session)
    kind_limits = (own.get("kinds") or {}).get(name) or {}
    if field in kind_limits:
        return kind_limits[field]
    if busy_kind(own, name):
        return None
    defaults = (budget.get("kinds") or {}).get(name) or {}
    if field in defaults:
        limit = defaults[field]
        return limit.get(session) if isinstance(limit, dict) else limit
    return (budget.get("all_kinds") or {}).get(field)


def limited_fields(budget, session, name):
    own = session_budget(budget, session)
    fields = set((own.get("kinds") or {}).get(name) or {})
    if not busy_kind(own, name):
        fields |= set((budget.get("kinds") or {}).get(name) or {}) | set(budget.get("all_kinds") or {})
    return sorted(f for f in fields if not f.startswith("_"))


def selected(kinds, selector):
    """The kinds of `selector` that ran ('tree': every kind; 'app+daemon': those of app and daemon that ran)."""
    return list(kinds) if selector == "tree" else [n for n in selector.split("+") if n in kinds]


def selector_value(kinds, selector, field):
    """`field` summed over the selected kinds that ran; None when none ran, or when one of them has the field None
    or lacks it: an unknown is never a 0, so a partial sum is not a value."""
    values = [(kinds[n] or {}).get(field) for n in selected(kinds, selector)]
    if not values or not all(isinstance(v, (int, float)) for v in values):
        return None
    return round(sum(values), 4)


def unknown_sum(kinds, selector, field):
    """Whether `selector` ran but its sum of `field` is unknown."""
    return bool(selected(kinds, selector)) and selector_value(kinds, selector, field) is None


def unclassified(name):
    """Whether `name` is the kind of a process no rule of `kind` names (`other:<executable>`): every process of
    the app's tree has a budget kind, so one that has none is an over in any session but a reference browser's."""
    return name.startswith("other:")


def setting_on(value):
    return value not in (None, False, "off", "never", 0, "")


def over_budget(session, kinds, budget, facts=None):
    """[(subject, field, value, limit)] for every value of one session over its budget (or a role or expected state
    that differs). `facts`: the session's measurements outside the kinds (page_raf_per_s, saver, saver_reason,
    `assertions` held by cmux pids, the effective `settings`). cross_overs judges the rows that compare sessions."""
    facts = facts or {}
    own = session_budget(budget, session)
    out = []
    for name in sorted(kinds):
        entry = kinds[name]
        if unclassified(name) and not own.get("reference"):
            out.append((name, "kind", "other", "classified"))
        for field in limited_fields(budget, session, name):
            limit = limit_for(budget, session, name, field)
            if limit is None:
                continue
            if field == "role":
                continue  # judged per process, with D16's defaults: role_audit
            value = entry.get(field)
            if isinstance(value, (int, float)) and value > limit and not periodic_excuse(budget, name, field, entry,
                                                                                          limit):
                out.append((name, field, value, limit))
    for selector, limits in (own.get("sums") or {}).items():
        for field, limit in limits.items():
            value = selector_value(kinds, selector, field)
            if limit is not None and value is not None and value > limit:
                out.append((selector, field, value, limit))
    for field, limit in (own.get("limits") or {}).items():
        value = facts.get(field)
        if limit is not None and isinstance(value, (int, float)) and value > limit:
            out.append(("session", field, value, limit))
    for field, expected in (own.get("expect") or {}).items():
        if field in facts and facts[field] != expected:
            out.append(("session", field, facts[field], expected))
    return out + assertion_overs(own, budget, facts)


# The D15 fields an allowed_periodic entry may excuse (its `metrics`), and the owner field of each.
D15_FIELDS = ("disk_bytes_per_s", "network_bytes", "log_lines")


def periodic_excuse(budget, name, field, entry, limit=0):
    """Whether allowed_periodic entries excuse D15 `field` of kind `name` over `limit`: an entry names the kind
    (`kind`) and the field (`metrics`). Without `remote` it excuses the whole value. With `remote` it applies to
    network_bytes only and excuses the bytes moved to that end (procs.remote_matches: the whole host or host:port,
    never a substring); the bytes left (to other ends, or not on a listed flow) must stay within `limit`. An entry
    without `kind` and `metrics` excuses no D15 value: its owner is a wakeup owner only."""
    if field not in D15_FIELDS:
        return False
    rules = [rule for rule in budget.get("allowed_periodic") or []
             if rule.get("kind") == name and field in (rule.get("metrics") or [])]
    if any(rule.get("remote") is None for rule in rules):
        return True
    allowed = [rule["remote"] for rule in rules]
    if field != "network_bytes" or not allowed or not isinstance(entry.get(field), (int, float)):
        return False
    excused = sum(moved for end, moved in (entry.get("remote_bytes") or {}).items()
                  if any(procs.remote_matches(remote, end) for remote in allowed))
    return entry[field] - excused <= limit


def assertion_overs(own, budget, facts):
    """D11: in an idle session every pmset assertion held by a cmux pid is an over, unless the session itself turns
    on one of `assertions_allowed_when` in its `settings`. Every other session runs with them off (KEEP_AWAKE_OFF;
    their shipping default pluggedIn holds an assertion while an agent works or a phone serves), and an effective
    value in `facts.settings` other than the session's is an over too. Busy sessions (a working agent holds
    keep-awake) and reference sessions are not judged."""
    if own.get("reference") or own.get("busy") is True:
        return []
    keys = budget.get("assertions_allowed_when") or []
    asked, effective = own.get("settings") or {}, facts.get("settings") or {}
    out = [("session", key, effective[key], asked.get(key, "off")) for key in keys
           if key in effective and setting_on(effective[key]) != setting_on(asked.get(key))]
    held = facts.get("assertions") or []
    if held and not any(setting_on(asked.get(key)) for key in keys):
        out.append(("assertions", "held", len(held), 0))
    return out


def cross_overs(budget, measured, unequal=None):
    """The rows that compare sessions of one run, judged once after every session is measured, so the order of
    --sessions does not matter: each session's `relative` rows and the ratio_to_chrome rows (chrome_rows: the
    one judgement of those). `measured`: {session: kinds}; `unequal`: {session: [reason]} why chrome-static is no
    fair reference for that session (chrome_unequal). Returns ([(session, over)], [note]); a note names each row
    not judged and why."""
    overs, notes = [], []

    def judge(session, of, field, vs, to, max_ratio, suffix):
        kinds, reference = measured[session], measured.get(to)
        label = f"{session} {of} {field}{suffix}"
        if reference is None:
            notes.append(f"{label}: not judged: reference session {to} not measured")
            return
        for selector, rows in ((of, kinds), (vs, reference)):
            if unknown_sum(rows, selector, field):
                notes.append(f"{label}: not judged: {selector} {field} unknown")
                return
        overs.extend((session, over) for over in ratio_over(of, field, kinds, vs, reference, max_ratio, suffix))

    for session in measured:
        for rule in session_budget(budget, session).get("relative") or []:
            judge(session, rule["of"], rule["field"], rule["of"], rule["to"], rule["max_ratio"], f"/{rule['to']}")
    for row in chrome_rows(budget, measured, unequal):
        if row["verdict"] == "over":
            overs.append((row["session"], tuple(row["over"])))
        elif row["verdict"] != "ok":
            notes.append(row["note"])
    return overs, notes


def chrome_rows(budget, measured, unequal=None):
    """One row per ratio_to_chrome rule whose session was measured, against chrome-static: cmux and Chrome values,
    the ratio, the noise floor it used, and a verdict: ok, over (`over`: the over tuple), or `not judged` with the
    reason in `note`: chrome-static not measured, a side unknown or not run, Chrome's value 0 with no floor, or
    `unequal` (the reasons, also in `unequal`). cross_overs takes its overs and notes from here, the report its rows."""
    reference = measured.get(CHROME_SESSION)
    rows = []
    for rule in budget.get("ratio_to_chrome") or []:
        session, of, vs, field = rule["session"], rule["of"], rule["vs"], rule["field"]
        if session not in measured or session == CHROME_SESSION:
            continue
        kinds, suffix = measured[session], f"/chrome:{vs}"
        row = {"session": session, "of": of, "vs": vs, "field": field, "max_ratio": rule["max_ratio"],
               "cmux_value": selector_value(kinds, of, field),
               "chrome_value": None if reference is None else selector_value(reference, vs, field),
               "floor": None, "ratio": None, "verdict": "ok"}
        why = None
        if reference is None:
            why = f"reference session {CHROME_SESSION} not measured"
        else:
            for selector, values, side in ((of, kinds, "cmux"), (vs, reference, "Chrome")):
                if unknown_sum(values, selector, field):
                    why = f"{selector} {field} unknown"
                    break
                if not selected(values, selector):
                    why = f"{side} ran no {selector}"
                    break
        if why is None and (unequal or {}).get(session):
            row["unequal"] = list(unequal[session])
            why = "unequal: " + "; ".join(row["unequal"])
        if why is None:
            floor = RATIO_FLOORS.get(field)
            row["ratio"], row["floor"] = ratio_of(row["cmux_value"], row["chrome_value"], floor)
            over = ratio_over(of, field, kinds, vs, reference, rule["max_ratio"], suffix, floor)
            if row["ratio"] is None:
                why = f"Chrome's {vs} {field} is 0 and the field has no noise floor"
            elif over:
                row["verdict"], row["over"] = "over", list(over[0])
        if why is not None:
            row["verdict"], row["note"] = "not judged", f"{session} {of} {field}{suffix}: not judged: {why}"
        rows.append(row)
    return rows


def kind_notes(session, kinds, budget):
    """The session's kind limits not judged because the measured value is unknown (a D15 reader failed, a GPU read
    failed): the kind has the field, and it is None."""
    return [f"{session} {name} {field}: not judged: unknown"
            for name in sorted(kinds) for field in limited_fields(budget, session, name)
            if field in kinds[name] and kinds[name][field] is None and limit_for(budget, session, name, field) is not None]


def sum_notes(session, kinds, budget):
    """The session's sum rows not judged because a selected kind's value is unknown."""
    return [f"{session} {selector} {field}: not judged: unknown"
            for selector, limits in (session_budget(budget, session).get("sums") or {}).items()
            for field, limit in limits.items() if limit is not None and unknown_sum(kinds, selector, field)]


def deferred_notes(session, kinds, budget):
    """The session's kind limits set to null with a `_<field>` reason (a row a later task turns on): reported as
    not judged, with the measured value and that reason, so the gap shows in every run."""
    notes = []
    for name, limits in sorted((session_budget(budget, session).get("kinds") or {}).items()):
        for field, limit in sorted(limits.items()):
            reason = limits.get("_" + field)
            if field.startswith("_") or limit is not None or not reason:
                continue
            value = (kinds.get(name) or {}).get(field, "not measured")
            notes.append(f"{session} {name} {field}: not judged: {value} measured; {reason}")
    return notes


def xbench_overs(budget, result):
    """D6 on an xbench.py result (results.json: rows.<row>.<browser>.median). An `xbench` row with `max_ratio`
    compares the browser's median with `vs` (default chrome); one with `max` is absolute. Returns ([over], [note])."""
    rows = (result or {}).get("rows") or {}
    overs, notes = [], []
    for rule in budget.get("xbench") or []:
        per = rows.get(rule["row"]) or {}
        value = (per.get(rule["browser"]) or {}).get("median")
        label = f"xbench {rule['browser']} {rule['row']}"
        if not isinstance(value, (int, float)):
            notes.append(f"{label}: not judged: not measured")
        elif "max" in rule:
            if value > rule["max"]:
                overs.append((rule["browser"], rule["row"], value, rule["max"]))
        else:
            vs = rule.get("vs", "chrome")
            base = (per.get(vs) or {}).get("median")
            if not isinstance(base, (int, float)) or not base:
                notes.append(f"{label}: not judged: {vs} not measured")
            elif round(value / base, 3) > rule["max_ratio"]:
                overs.append((rule["browser"], f"{rule['row']}/{vs}", round(value / base, 3), rule["max_ratio"]))
    return overs, notes


# The noise floors a Chrome reference value is raised to (the cron rows' floors, CRON_FLOORS and CRON_SUM_FLOORS):
# Chrome's GPU process at 0 wakeups against cmux's at 1 in a minute is idle noise, not an infinite ratio, while
# cmux at 3/s against it is 6 times the floor.
RATIO_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "hidden_wakeups_max": 0.5, "main_wakes_per_s": 0.5,
                "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0, "gpu_ms_per_s": 1.0, "threads": 2, "threads_max": 2}


def ratio_of(value, base, floor=None):
    """(value / reference, the floor used or None). A reference below `floor` counts as the floor; a reference of
    0 with no floor, or a side not measured, gives (None, None): no ratio."""
    if value is None or base is None:
        return None, None
    used = floor if floor and base < floor else None
    base = used or base
    return (round(value / base, 3), used) if base else (None, None)


def ratio_over(of, field, kinds, vs, reference, max_ratio, suffix, floor=None):
    """[(of, field + suffix, ratio, max)] when `of` in `kinds` over `vs` in `reference` is above `max_ratio`; a
    reference of 0 or one that was not measured judges nothing. With `floor`, a reference below it counts as the
    floor and the field says so (`:floor`), so the printed ratio is the one compared."""
    ratio, used = ratio_of(selector_value(kinds, of, field), selector_value(reference, vs, field), floor)
    if ratio is None or ratio <= max_ratio:
        return []
    return [(of, field + suffix + (":floor" if used else ""), ratio, max_ratio)]


# ---------------------------------------------------------------------------------------------------------
# Process roles and App Nap (D16 of plans/cmux-next/chrome-parity/p14-energy.md, task 106)
#
# Chrome's model (base/process/process_mac.cc `Process::SetPriority`; RenderProcessHostImpl::UpdateProcessPriority
# in content/browser/renderer_host/render_process_host_impl.cc): a hidden or spare renderer is kBestEffort
# (TASK_BACKGROUND_APPLICATION + TASK_SUPPRESSION_POLICY: low CPU priority), a shown one kUserBlocking
# (TASK_FOREGROUND_APPLICATION; kUserVisible maps to it while kUserVisibleProcessPriority is off, its default). App Nap suppresses a
# hidden app the same way. The audit reads each task's role at the window's end (procs.priorities: its base priority
# and darwinbg bit, never its busiest thread's priority) and compares it with D16 or the budget's `role`.

# osfmk/kern/sched.h: BASEPRI_DEFAULT. task_policy_update_internal_locked (osfmk/kern/task_policy.c) lowers a task's
# base priority below it only for lowpri_cpu (MAXPRI_THROTTLE 4), suppressed_cpu (MAXPRI_SUPPRESSED 28) or a
# positive nice.
BASEPRI_DEFAULT = 31


def observed_role(priority):
    """The scheduling role of one task from `procs.priorities()`: `darwinbg` (the kernel's darwin-background bit:
    PRIO_DARWIN_BG, a background role), `suppressed` (a base priority below BASEPRI_DEFAULT: App Nap or task
    suppression, Chrome's kBestEffort, or a positive nice), `default` (not lowered; foreground and visible apps
    alike, since their role changes thread QoS, not the task's base priority); None when unread."""
    if not priority:
        return None
    if priority.get("darwinbg"):
        return "darwinbg"
    base = priority.get("base")
    if base is None:
        return None
    return "suppressed" if base < BASEPRI_DEFAULT else "default"


# A budget or D16 role and the observed roles that meet it.
ROLE_EXPECTATIONS = {
    "napped": {"darwinbg", "suppressed"},       # App Nap
    "best-effort": {"darwinbg", "suppressed"},  # Chrome kBestEffort
    "background": {"darwinbg"},                 # PRIO_DARWIN_BG exactly (pooled acpmux agents, task 038)
    "not-background": {"default"},
}


def with_roles(rows, priority, pooled):
    """`rows` with each process's `priority` (procs.priorities), observed `role` and whether it is a `pooled` acpmux
    agent (pool_pids)."""
    for row in rows:
        row["priority"] = priority.get(row["pid"])
        row["role"] = observed_role(row["priority"])
        row["pooled"] = row["pid"] in pooled
    return rows


def role_budget_errors(budget):
    """Every budget `role` (kinds, all_kinds, sessions.<s>.kinds) that is no ROLE_EXPECTATIONS key, so a typo refuses
    the run instead of judging by the default. null is valid: measured, not judged (budget_role)."""
    places = [(f"kinds.{name}", limits) for name, limits in (budget.get("kinds") or {}).items()]
    places.append(("all_kinds", budget.get("all_kinds") or {}))
    for session, own in (budget.get("sessions") or {}).items():
        places += [(f"sessions.{session}.kinds.{name}", limits)
                   for name, limits in ((own or {}).get("kinds") or {}).items()]
    errors = []
    for where, limits in places:
        role = limits.get("role") if isinstance(limits, dict) else None
        if isinstance(role, dict):
            bad = [f"{where}.role.{session}" for session, value in role.items()
                   if value is not None and value not in ROLE_EXPECTATIONS]
        else:
            bad = [f"{where}.role"] if role is not None and role not in ROLE_EXPECTATIONS else []
        errors += [f"{place} is not one of {', '.join(ROLE_EXPECTATIONS)}" for place in bad]
    return errors


NO_BUDGET_ROLE = object()


def budget_role(budget, session, name):
    """The budget's `role` for kind `name` in `session`, read as limit_for reads limits, with an explicit null kept
    apart: None is `"role": null` (measured, not judged) or a busy kind; NO_BUDGET_ROLE is no `role` anywhere, so
    D16's default applies."""
    own = session_budget(budget, session)
    kind_limits = (own.get("kinds") or {}).get(name) or {}
    if "role" in kind_limits:
        return kind_limits["role"]
    if busy_kind(own, name):
        return None
    defaults = (budget.get("kinds") or {}).get(name) or {}
    if "role" in defaults:
        limit = defaults["role"]
        if not isinstance(limit, dict):
            return limit
        if session in limit:
            return limit[session]
    all_kinds = budget.get("all_kinds") or {}
    return all_kinds["role"] if "role" in all_kinds else NO_BUDGET_ROLE


def renderer_visibility(row):
    """`hidden`, `shown` or `unknown` for a renderer row: the census's attribution (WindowKinds.hidden and .shown)."""
    if row.get("hidden") is True:
        return "hidden"
    return "shown" if row.get("shown") is True else "unknown"


def expected_role(session, row, budget=None, sessions=None):
    """The role D16 expects of one process in `session`, or None when it is not judged: the budget's `role` wins (an
    explicit null: not judged); a busy kind or a reference session is not judged; a renderer is best-effort when the
    census marks it hidden or no window shows; in a session with `judge_shown_renderers` (tabs-static) it is not
    backgrounded when a window shows and the census marks it shown (Chrome's kUserBlocking for a visible widget:
    RenderProcessPriority::GetProcessPriority in content/browser/child_process_launcher.cc); otherwise a shown
    renderer, or one of unknown visibility, is not judged."""
    budget = budget or {}
    name = row["kind"]
    limit = budget_role(budget, session, name)
    if limit is not NO_BUDGET_ROLE:
        return limit
    facts = (SESSIONS if sessions is None else sessions).get(session, {})
    if row.get("pooled"):
        return "background"
    if name == "cef-extension":
        return "best-effort"
    if name == "cef-renderer" and (facts.get("shown") is False or renderer_visibility(row) == "hidden"):
        return "best-effort"
    if (name == "cef-renderer" and facts.get("judge_shown_renderers") and facts.get("shown")
            and renderer_visibility(row) == "shown"):
        return "not-background"
    # The Chromium Host holds its App Nap activity only while a page shows (host_page_activity.h, task 128).
    if facts.get("shown") is False and name in ("app", "cef-host"):
        return "napped"
    if facts.get("shown") and name in ("daemon", "terminal-host"):
        return "not-background"
    return None


def role_audit(session, rows, budget=None, sessions=None):
    """([{kind, pids, observed, expected}], [not-judged note]): a mismatch for every process whose observed role does
    not meet expected_role; a note for a process with an expected role whose role could not be read (gone, or the
    read failed) and for the renderers of a shown session whose visibility the census does not tell (a build
    without debug.webui, a browser tab of a session with no shown tab): they may serve a shown page, so they are
    not judged. Per-tab renderer attribution (task 124) narrows the second."""
    budget = budget or {}
    out, unread, unknown = [], {}, []
    facts = (SESSIONS if sessions is None else sessions).get(session, {})
    for row in rows:
        want = expected_role(session, row, budget, sessions)
        if want is None:
            if (row["kind"] == "cef-renderer" and facts.get("shown") and not row.get("pooled")
                    and budget_role(budget, session, "cef-renderer") is NO_BUDGET_ROLE
                    and renderer_visibility(row) == "unknown"):
                unknown.append(row["pid"])
            continue
        if row.get("role") is None:
            unread.setdefault(row["kind"], []).append(row["pid"])
        elif row["role"] not in ROLE_EXPECTATIONS[want]:
            out.append({"kind": row["kind"], "pids": [row["pid"]], "observed": row["role"], "expected": want})
    notes = [f"{session} {name} role: not judged: unread pids={','.join(map(str, sorted(pids)))}"
             for name, pids in sorted(unread.items())]
    if unknown:
        notes.append(f"{session} cef-renderer role: not judged: visibility unknown "
                     f"pids={','.join(map(str, sorted(unknown)))}")
    return out, notes


def role_over_line(session, mismatch):
    """One Q9 work item: `IDLE-BUDGET-OVER <session> <kind> role owner=role pids=... observed=... expected=...`."""
    pids = ",".join(str(pid) for pid in mismatch["pids"])
    phase = f" phase={mismatch['phase']}" if mismatch.get("phase") else ""
    return (f"IDLE-BUDGET-OVER {session} {mismatch['kind']} role owner=role pids={pids} "
            f"observed={mismatch['observed']} expected={mismatch['expected']}{phase}")


# The reshow step (task 107). Chrome changes a renderer's priority on every visibility change of its widgets
# (RenderWidgetHostImpl::WasShown / WasHidden -> RenderProcessHostImpl::UpdateProcessPriority in
# content/browser/renderer_host/render_process_host_impl.cc): a renderer that went to kBestEffort while its tab was
# hidden comes back to kUserBlocking when the tab is shown, and the tab hidden by that switch goes to kBestEffort.
# The window's own role read sees only the steady state, so tabs-static shows a hidden tab after its window and reads
# the roles again.
RESHOW_WAIT_S = 10


def census_tab_pids(census):
    """{census name: sorted renderer pids} of the Chromium browser tabs in a debug.webui reply."""
    return {tab.get("tab"): sorted(host_pids(tab)) for tab in census_rows(census, "browser_tabs")
            if isinstance(tab.get("tab"), str)}


def reshow_candidate(rows, browser_tabs, shown_tab):
    """(tab, its renderer pids, None) of the first Chromium browser tab (census name order) that is not the shown
    one, shares no renderer with it, and whose every renderer the window read hidden and best-effort; (None, None,
    why) when there is none."""
    previous = set((shown_tab or {}).get("tabs") or [])
    if not browser_tabs or not previous:
        return None, None, "no census browser_tabs or no shown tab"
    by_pid = {row["pid"]: row for row in rows}
    previous_pids = {pid for name in previous for pid in browser_tabs.get(name, [])}
    for name in sorted(browser_tabs):
        pids = browser_tabs[name]
        if name in previous or not pids or previous_pids & set(pids):
            continue
        if all(by_pid.get(pid, {}).get("kind") == "cef-renderer" and by_pid[pid].get("hidden") is True
               and by_pid[pid].get("role") in ROLE_EXPECTATIONS["best-effort"] for pid in pids):
            return name, pids, None
    return None, None, "no hidden Chromium tab was read best-effort at the window's end"


def tab_selected(app, tab):
    """Whether browser.page.tabs reports the tab `tab` selected in its pane."""
    reply = read_rpc(app, "browser.page.tabs", {"all": True})
    tabs = reply.get("tabs") if isinstance(reply.get("tabs"), list) else []
    return any(isinstance(t, dict) and t.get("id") == tab and t.get("selected") is True for t in tabs)


def reshow_settled(after, priority):
    """Whether, in one priority read, every renderer of the shown tab is not backgrounded and every renderer of the
    tab shown before is best-effort."""
    want = {"tab": ROLE_EXPECTATIONS["not-background"], "previous": ROLE_EXPECTATIONS["best-effort"]}
    return all(observed_role(priority.get(item["pid"])) in want[item["of"]] for item in after)


def reshow_tab(app, rows, browser_tabs, shown_tab, read_priorities=procs.priorities, clock=time.monotonic,
               sleep=time.sleep, wait_s=RESHOW_WAIT_S):
    """Shows a hidden Chromium tab (reshow_candidate) through the action path a click takes (tab.focus) and reads
    the roles again. Waits up to `wait_s` for browser.page.tabs to report it selected, takes the renderer pids of it
    and of the tab shown before from a fresh census, then reads their priorities until reshow_settled or `wait_s`
    passes. Returns {tab, previous, before: [{pid, of, role}] from the window's read, selected, after: [{pid, of,
    priority}], waited_s} for reshow_audit, or {"skipped": why} (no candidate, or the app refused the switch)."""
    tab, pids, why = reshow_candidate(rows, browser_tabs, shown_tab)
    if tab is None:
        return {"skipped": why}
    previous = sorted((shown_tab or {}).get("tabs") or [])
    roles = {row["pid"]: row.get("role") for row in rows}
    before_previous = sorted({pid for name in previous for pid in browser_tabs.get(name, [])})
    record = {"tab": tab, "previous": previous,
              "before": [{"pid": pid, "of": "tab", "role": roles.get(pid)} for pid in pids]
                        + [{"pid": pid, "of": "previous", "role": roles.get(pid)} for pid in before_previous]}
    try:
        run_action(app, "tab.focus", target=f"tab:{tab}", focus=True)
    except SessionShapeError as error:  # the window is measured; a refused switch skips only the reshow
        return {"skipped": str(error)}
    began = clock()
    while not tab_selected(app, tab) and clock() - began < wait_s:
        sleep(0.2)  # bench: bounded wait for the selection to land
    record["selected"] = tab_selected(app, tab)
    after_tabs = census_tab_pids(read_rpc(app, "debug.webui"))
    shown_pids = after_tabs.get(tab, [])
    hidden_after = sorted({pid for name in previous for pid in after_tabs.get(name, [])} - set(shown_pids))
    after = [{"pid": pid, "of": "tab"} for pid in shown_pids] + [{"pid": pid, "of": "previous"} for pid in hidden_after]
    priority = read_priorities([item["pid"] for item in after])
    while not reshow_settled(after, priority) and clock() - began < wait_s:
        sleep(0.2)  # bench: bounded wait for Chromium's priority change on show and hide (proc_pidinfo wakes no one)
        priority = read_priorities([item["pid"] for item in after])
    record["after"] = [{**item, "priority": priority.get(item["pid"])} for item in after]
    record["waited_s"] = round(clock() - began, 1)
    return record


def reshow_audit(session, reshow):
    """([mismatch with phase "reshow"], [not-judged note]) of a reshow_tab record: after the switch every renderer
    of the shown tab must be not-background and every renderer of the tab shown before best-effort. The before half
    is the window's own role read (role_audit). A skipped reshow, a tab that was not selected, an unread role, a tab
    with no renderer after the switch and a tab that runs a new renderer (no return measured) are notes."""
    if not reshow:
        return [], []
    prefix = f"{session} cef-renderer reshow: not judged:"
    if reshow.get("skipped"):
        return [], [f"{prefix} {reshow['skipped']}"]
    tab = reshow["tab"]
    if not reshow.get("selected"):
        return [], [f"{prefix} tab {tab} was not reported selected in {RESHOW_WAIT_S:g} s"]
    want = {"tab": "not-background", "previous": "best-effort"}
    out, unread, notes = [], [], []
    for item in reshow["after"]:
        role = observed_role(item["priority"])
        if role is None:
            unread.append(item["pid"])
        elif role not in ROLE_EXPECTATIONS[want[item["of"]]]:
            out.append({"kind": "cef-renderer", "pids": [item["pid"]], "observed": role, "expected": want[item["of"]],
                        "phase": "reshow"})
    before = sorted(item["pid"] for item in reshow["before"] if item["of"] == "tab")
    after = sorted(item["pid"] for item in reshow["after"] if item["of"] == "tab")
    if not after:
        notes.append(f"{prefix} tab {tab} has no renderer in the census after the switch")
    elif before != after:
        notes.append(f"{prefix} tab {tab} runs a new renderer after the switch (pids before="
                     f"{','.join(map(str, before))} after={','.join(map(str, after))}): its return is not measured")
    if not any(item["of"] == "previous" for item in reshow["after"]):
        notes.append(f"{prefix} the tab shown before ({','.join(reshow['previous'])}) has no renderer of its own")
    if unread:
        notes.append(f"{prefix} unread pids={','.join(map(str, sorted(unread)))}")
    return out, notes


def acpmux_homes(env=None, user_home=None):
    """Every acpmux home the launched app can run a daemon in, resolved as the app does: the root is
    `CMUX_NEXT_ACPMUX_ROOT` (Debug) or `.acpmux` in the password-database home (AcpmuxEnvironment uses
    `homeDirectoryForCurrentUser`; a fleet step's $HOME is a scratch folder), with each build's `builds/<key>`; an
    explicit `ACPMUX_HOME`; and the Chief's own daemons (ChiefHome.acpmuxHome, `<chief home>/acpmux`): the launch's
    `CMUX_NEXT_CHIEF_HOME` and every Chief home under `CMUX_NEXT_CHIEF_ROOT` or `~/.cmux/chief`."""
    env = env or {}
    if user_home is None:
        from bench_launch import account_home
        user_home = account_home()
    root = env.get("CMUX_NEXT_ACPMUX_ROOT") or os.path.join(user_home, ".acpmux")
    found = [root, *sorted(glob.glob(os.path.join(glob.escape(root), "builds", "*")))]
    if env.get("ACPMUX_HOME"):
        found.append(env["ACPMUX_HOME"])
    chief = env.get("CMUX_NEXT_CHIEF_HOME") or env.get("CMUX_NEXT_MUX_HOME")
    if chief:
        found.append(os.path.join(chief, "acpmux"))
    chief_base = glob.escape(env.get("CMUX_NEXT_CHIEF_ROOT") or os.path.join(user_home, ".cmux", "chief"))
    found += sorted(glob.glob(os.path.join(chief_base, "*", "acpmux"))
                    + glob.glob(os.path.join(chief_base, "isolated", "*", "acpmux")))
    return list(dict.fromkeys(os.path.normpath(home) for home in found))


_START_NONCE = re.compile(r"[0-9a-f]+")


def live_lock_held(path):
    """Whether the host liveness lock at `path` is held now, probed as acpmux agent_host::liveness does: a held flock
    is that host incarnation alive, whatever its pid became. False when missing, free or unreadable."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except OSError:
        return False
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def live_pool_host(record, pool, commands):
    """The `host_pid` of a pool record (acpmux HostRecord) whose host is live now, or None: its
    `<session>.<start_nonce>.live` lock is held and the pid runs `__agent-host`. A stale record (a reboot, a SIGKILL,
    an old tag's daemon that never reaps it) whose pid was reused names nothing."""
    if not isinstance(record, dict):
        return None
    session, nonce, host = record.get("session_id"), record.get("start_nonce"), record.get("host_pid")
    if not isinstance(session, str) or not session or "/" in session or session.startswith("."):
        return None
    if not isinstance(nonce, str) or not _START_NONCE.fullmatch(nonce) or type(host) is not int:
        return None
    if "__agent-host" not in commands.get(host, ""):
        return None
    return host if live_lock_held(os.path.join(pool, f"{session}.{nonce}.live")) else None


def pool_pids(pids, table, homes):
    """The pids of `pids` that are pooled acpmux agents: the live `__agent-host` of each record in
    `<home>/hosts/pool/*.json` (acpmux agent_host POOL_DIR_NAME, live_pool_host) and its descendants (the harness and
    the harness's own children)."""
    wanted = set(pids)
    commands = {pid: cmd for pid, _ppid, cmd in table}
    roots = set()
    for home in homes:
        pool = os.path.join(home, "hosts", "pool")
        try:
            names = os.listdir(pool)
        except OSError:
            continue
        for name in names:
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(pool, name)) as handle:
                    record = json.load(handle)
            except (OSError, ValueError):
                continue
            host = live_pool_host(record, pool, commands)
            if host in wanted:
                roots.add(host)
    children = {}
    for pid, ppid, _cmd in table:
        children.setdefault(ppid, []).append(pid)
    found = set()
    stack = list(roots)
    while stack:
        pid = stack.pop()
        if pid in found:
            continue
        found.add(pid)
        stack += [child for child in children.get(pid, []) if child in wanted]
    return found


def over_line(session, over, kinds=None):
    """One IDLE-BUDGET-OVER line; with the session's `kinds`, a disk, network or log over names its owner."""
    name, field, value, limit = over
    relation = ">" if isinstance(limit, (int, float)) and not isinstance(limit, bool) else "!="
    owner = over_owner(field, (kinds or {}).get(name) or {})
    return f"IDLE-BUDGET-OVER {session} {name} {field} {value} {relation} {limit}" + (f" {owner}" if owner else "")


def over_owner(field, entry):
    """Who a D15 over belongs to: the pids that wrote, the remote ends, the top log owners ('' when unknown)."""
    if field.startswith("disk_") and entry.get("disk_writers"):
        return "pids=" + ",".join(str(pid) for pid in entry["disk_writers"])
    if field in ("network_bytes", "connections") and entry.get("remotes"):
        return "remotes=" + ";".join(entry["remotes"][:6])
    if field == "log_lines" and entry.get("log_owners"):
        top = list(entry["log_owners"].items())[:4]
        return "owners=" + ",".join(f"{owner}={count}" for owner, count in top)
    return ""


def load_budget(path):
    """The budget file; a v1 file (kinds only) is read as v2 with no session overrides."""
    with open(path) as handle:
        budget = json.load(handle)
    budget.setdefault("version", 1)
    for key in ("kinds", "sessions", "all_kinds"):
        budget.setdefault(key, {})
    for key in ("ratio_to_chrome", "goals", "xbench", "allowed_periodic", "assertions_allowed_when"):
        budget.setdefault(key, [])
    return budget


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late). D15's rows
# are 0 at idle: any byte or line is a change.
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2,
               "energy_mw_billed": 1.0, "gpu_ms_per_s": 1.0,
               "disk_bytes_per_s": 0.5, "network_bytes": 0.5, "log_lines": 0.5}
CRON_UNITS = {"threads_max": "threads", "threads": "threads", "energy_mw_billed": "mW", "energy_mw_cpu": "mW",
              "gpu_ms_per_s": "ms/s", "disk_bytes_per_s": "B/s", "network_bytes": "bytes", "log_lines": "lines"}
# The sums every session reports, plus the ones its budget names.
CRON_SUMS = ("app+daemon", "tree")
CRON_SUM_FLOORS = {"wakeups_per_s": 0.5, "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0}


def cron_rows(report, budget=None):
    """{row: {p50, p95, p99, unit, budget, floor}} for the perf cron (scripts/cmux-next/perf-cron.py) from one
    idle-budget report: `idle_budget.<session>.<kind>.<field>` and the sums `idle_budget.<session>.<selector>.<field>`,
    one value per run (p50 = p95 = p99: one window is one sample)."""
    budget = budget if budget is not None else load_budget(BUDGET_FILE)
    out = {}
    for session, entry in ((report or {}).get("sessions") or {}).items():
        kinds = entry.get("kinds") or {}
        for name, values in kinds.items():
            for field, floor in CRON_FLOORS.items():
                value = values.get(field)
                if not isinstance(value, (int, float)):
                    continue
                unit = CRON_UNITS.get(field, "/s")
                out[f"idle_budget.{session}.{name}.{field}"] = {"p50": value, "p95": value, "p99": value, "unit": unit,
                                                                 "budget": limit_for(budget, session, name, field),
                                                                 "floor": floor}
        sums = session_budget(budget, session).get("sums") or {}
        for selector in dict.fromkeys([*CRON_SUMS, *sums]):
            for field, floor in CRON_SUM_FLOORS.items():
                value = selector_value(kinds, selector, field)
                if value is None:
                    continue
                out[f"idle_budget.{session}.{selector}.{field}"] = {
                    "p50": value, "p95": value, "p99": value, "unit": CRON_UNITS.get(field, "/s"),
                    "budget": (sums.get(selector) or {}).get(field), "floor": floor}
    return out


def record_session(app, session, entry, budget, failed=False):
    """The session's cron rows and its `failed` count as cmux-perf-result/v1 in the BenchApp's out folder
    (idle_burst_bench_report.idle_budget_series, BenchApp.record); {`story/metric`: path or `not recorded: <why>`}.
    A session that failed before its app answered has no features snapshot, so record() writes nothing and says why.
    A writer that raises is reported as {"error": ...} and an IDLE-BUDGET-RESULTS-FAILED line: the other sessions
    still measure."""
    import idle_burst_bench_report as results_v1
    try:
        rows = {} if failed else cron_rows({"sessions": {session: entry}}, budget)
        return results_v1.record_all(app, results_v1.idle_budget_series(session, SESSIONS[session], rows,
                                                                        failed=failed))
    except Exception as error:  # noqa: BLE001 - a result file that can not be written loses that file, not the run
        problem = f"{type(error).__name__}: {error}"[:300]
        print(f"IDLE-BUDGET-RESULTS-FAILED {session}: {problem}", flush=True)
        return {"error": problem}


# ---------------------------------------------------------------------------------------------------------
# The Chrome reference (chrome-static): a Chromium with the tabs-static pages and the uBlock Origin cmux bundles

CHROME_SESSION = "chrome-static"
CHROME_APP = "/Applications/Chromium.app"  # where ungoogled-chromium installs (the comment above BRANDED_CHROME_IDS)
UBLOCK_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  # fetch-ublock.sh keeps the Web Store key, so the id is stable
UBLOCK_IN_APP = "Contents/Resources/Extensions/ublock-origin"  # bundle-ublock.sh
# Google Chrome's kinds from tab_pages' --type classifier (the switches cmux's helpers carry too). Chrome's
# helpers are not in a cmux Helper app, so chromium_kind does not apply; any other --type is `other`.
CHROME_KINDS = {"cef-renderer": "renderer", "cef-extension": "extension", "cef-gpu": "gpu", "cef-utility": "utility",
                "cef-helper": "other"}
# Builds that cannot run the bundled uBlock Origin (Manifest V2, loaded with --load-extension): branded Google
# Chrome ignores --load-extension from 137 and has no switch back from 142 (Chromium 04f6233ce5be: the
# GOOGLE_CHROME_BRANDING check in extensions' command-line loader); Chromium runs no MV2 extension from 139, and
# Chrome for Testing carries no patch for it. cmux's CEF runs MV2 through cmux_extensions_manifestv2.patch, from
# ungoogled-chromium (plans/cmux-next/browser.md), so ungoogled-chromium of cmux's Chromium major is the reference.
# A plain Chromium has the same bundle id as ungoogled-chromium, so only the run tells them apart: uBlock Origin
# does not start, the rows are unequal and --gate refuses.
BRANDED_CHROME_IDS = ("com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary")
CHROME_FOR_TESTING_ID = "com.google.chrome.for.testing"
LOAD_EXTENSION_GONE_MAJOR = 137
MANIFEST_V2_GONE_MAJOR = 139


def chrome_kind(cmd, pid=None):
    """The kind of a Chrome process: browser, renderer, extension, gpu, utility, crashpad, other (Chromium's
    process types, content/public/common/content_switches.cc; an extension's renderer carries
    --extension-process, extensions/common/switches.cc; Crashpad's handler runs with no --type). The command
    alone decides; `pid` is the classifier signature process_row calls."""
    typed = tab_pages.process_type_kind(cmd)
    if typed:
        return CHROME_KINDS[typed]
    exe = cmd.split(" --", 1)[0].strip()
    if os.path.basename(exe) == "chrome_crashpad_handler":
        return "crashpad"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "browser"
    return "other:" + os.path.basename(exe)[:32]


def read_manifest(folder):
    """The manifest.json of an unpacked extension folder, or None when it has no readable one."""
    try:
        with open(os.path.join(folder, "manifest.json")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return None
    return manifest if isinstance(manifest, dict) else None


def manifest_version(folder):
    """The `version` of an unpacked extension folder, or None when it has no readable manifest."""
    return (read_manifest(folder) or {}).get("version")


def major_version(version):
    head = str(version or "").split(".", 1)[0]
    return int(head) if head.isdigit() else None


def reference_refusal(bundle_id, version, manifest):
    """Why the browser `bundle_id` at `version` cannot run the extension of `manifest` loaded with
    --load-extension, or None when it may (whether it did is checked when it runs)."""
    major = major_version(version)
    if major is None:
        return None
    if bundle_id in BRANDED_CHROME_IDS and major >= LOAD_EXTENSION_GONE_MAJOR:
        return f"branded Google Chrome {version} ignores --load-extension (Chrome {LOAD_EXTENSION_GONE_MAJOR}+)"
    if manifest.get("manifest_version") == 2 and bundle_id == CHROME_FOR_TESTING_ID and major >= MANIFEST_V2_GONE_MAJOR:
        return (f"Chrome for Testing {version} runs no Manifest V2 extension (Chromium {MANIFEST_V2_GONE_MAJOR}+); "
                f"uBlock Origin {manifest.get('version')} is MV2")
    return None


def ublock_parity(cmux_version, cmux_running, chrome_version, chrome_running):
    """Whether both sides ran the same uBlock Origin: `*_version` the copy each side has (None: none), `*_running`
    whether it ran in the measured session (chrome_unequal's rule). Without it one side does less work, so the
    reference is unequal and its ratio rows are reported, not judged."""
    unequal = []
    if cmux_version is None:
        unequal.append("the cmux app bundles no uBlock Origin")
    elif not cmux_running:
        unequal.append(f"uBlock Origin {cmux_version} did not run in the cmux session (no cef-extension process)")
    if chrome_version is None:
        unequal.append("no uBlock Origin was loaded into Chrome")
    elif not chrome_running:
        unequal.append(f"uBlock Origin {chrome_version} did not run in Chrome (no extension target or process)")
    if cmux_version and chrome_version and cmux_version != chrome_version:
        unequal.append(f"uBlock Origin {chrome_version} in Chrome, {cmux_version} in cmux")
    return {"id": UBLOCK_ID, "cmux_version": cmux_version, "chrome_version": chrome_version,
            "cmux_running": bool(cmux_running), "chrome_running": bool(chrome_running), "equal": not unequal,
            "unequal": unequal}


def kind_ran(kinds, name):
    return bool((kinds.get(name) or {}).get("n"))


def chrome_unequal(kinds, chrome):
    """(parity, reasons) of chrome-static (its block `chrome`, with its `kinds`) as the reference of a cmux session
    measured as `kinds`. The same rule on both sides: uBlock Origin ran when an extension renderer was measured in
    the window (cmux: cef-extension; Chrome: extension, and DevTools listed uBlock Origin's own target, as Chrome
    may run component extensions). The reasons add chrome's own shape reasons (chrome_shape_unequal)."""
    ublock = chrome.get("ublock") or {}
    parity = ublock_parity(ublock.get("cmux_version"), kind_ran(kinds, "cef-extension"), ublock.get("chrome_version"),
                           bool(ublock.get("running")) and kind_ran(chrome.get("kinds") or {}, "extension"))
    return parity, list(chrome.get("unequal") or []) + parity["unequal"]


def chrome_shape_unequal(page_targets, visibility, keys):
    """Why Chrome's pages at the window's end are not tabs-static's shape: one page target per key of `keys` (the
    tab_plan's loaded keys in opening order, the last one shown), the last visible and every other hidden
    (`visibility`: the static pages' last document.visibilityState reports)."""
    reasons = []
    if page_targets != len(keys):
        reasons.append(f"Chrome had {page_targets} page targets, tabs-static has {len(keys)}")
    want = {key: "visible" if index == len(keys) - 1 else "hidden" for index, key in enumerate(keys)}
    wrong = [f"{key}={visibility.get(key)}" for key in want if visibility.get(key) != want[key]]
    if wrong:
        reasons.append(f"Chrome's tab visibility is not 1 shown, {len(keys) - 1} hidden: " + ", ".join(wrong))
    return reasons


def template_key(bundle, version, ublock, ublock_version):
    """The template profile's key: a profile built by another browser build or with another uBlock Origin (or
    none) is another template."""
    text = json.dumps([os.path.realpath(bundle), version, ublock and os.path.realpath(ublock), ublock_version])
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def chrome_refusals(asked, entry, rows):
    """Why --gate cannot pass on the Chrome ratios: chrome-static was asked (`asked`) and failed (`entry`), or a
    ratio row of a measured session is unequal. A reference that can never judge must not pass in silence."""
    if not asked:
        return []
    if not entry or entry.get("exit") or not entry.get("kinds"):
        return [f"{CHROME_SESSION} not measured: {(entry or {}).get('error', 'no result')}"[:400]]
    return list(dict.fromkeys(f"{row['session']}: {reason}" for row in rows for reason in row.get("unequal") or []))


def judge_across(report, budget, chrome_asked=False):
    """After every session ran: the cross-session rows (cross_overs) with each session's chrome-static parity,
    so the --sessions order does not matter. Puts `not_judged`, and with chrome-static measured the `chrome` block
    (with each session's uBlock Origin parity) and the `ratio_to_chrome` rows into `report`, each over into its
    session's `over`. Returns (overs [(session, over)], notes, refused: chrome_refusals)."""
    sessions = report["sessions"]
    measured = {name: done["kinds"] for name, done in sessions.items() if done.get("kinds")}
    chrome = chrome_reference(report)
    unequal = {}
    if chrome:
        chrome["parity"] = {}
        for name, kinds in measured.items():
            if not SESSIONS.get(name, {}).get("chrome"):
                chrome["parity"][name], unequal[name] = chrome_unequal(kinds, chrome)
        report["chrome"] = chrome
    overs, notes = cross_overs(budget, measured, unequal)
    rows = chrome_rows(budget, measured, unequal)
    if chrome:
        report["ratio_to_chrome"] = rows
    for name, over in overs:
        sessions[name].setdefault("over", []).append(list(over))
    report["not_judged"] = notes
    return overs, notes, chrome_refusals(chrome_asked, sessions.get(CHROME_SESSION), rows)


def ratio_table(rows):
    lines = ["\n### ratio to Chrome (chrome-static)\n",
             "| session | cmux | Chrome | field | cmux value | Chrome value | floor | ratio | max | verdict |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        verdict = ("**over**" if row["verdict"] == "over" else
                   row["note"].split(": not judged: ", 1)[-1] if row["verdict"] != "ok" else "ok")
        lines.append(f"| {row['session']} | {row['of']} | {row['vs']} | {row['field']} | {row['cmux_value']} | "
                     f"{row['chrome_value']} | {row['floor'] or '-'} | {row['ratio']} | {row['max_ratio']} | {verdict} |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------
# Sessions


def load_stress():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", STRESS_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The animated page of energy-saver: one box turned on every rAF, the count in window.__rafCount. It reports
# /loaded/anim as the shared static page reports /loaded/<n>, then keeps one GET of ANIM_READ_PATH open: the
# server holds it until the bench reads (IdlePages.read_anim), and the page then POSTs
# ANIM_COUNT_PATH/<count>/<performance.now()>/<visibilityState> and asks again. A held request runs no timer in the
# page, so the read path costs no wake inside the window and needs no DevTools port (Release builds have none).
ANIM_PATH = "/anim"
ANIM_READ_PATH = "/anim-read"
ANIM_COUNT_PATH = "/anim-count"
ANIM_PAGE = ("<!doctype html><meta charset='utf-8'><title>idle anim</title>"
             "<style>body{margin:0;background:#f4f4f6}#b{width:64px;height:64px;margin:40px;border-radius:12px;"
             "background:#20304a}</style><div id='b'></div><script>window.__rafCount=0;"
             "const b=document.getElementById('b');requestAnimationFrame(function f(){window.__rafCount++;"
             "b.style.transform='rotate('+(window.__rafCount*3%360)+'deg)';requestAnimationFrame(f)});"
             f"function ask(){{fetch('{ANIM_READ_PATH}',{{cache:'no-store'}}).then(function(){{"
             f"return fetch('{ANIM_COUNT_PATH}/'+window.__rafCount+'/'+performance.now()+'/'+document.visibilityState,"
             "{method:'POST'})}).then(ask,function(){setTimeout(ask,1000)})}"
             "fetch('/loaded/anim',{method:'POST'}).then(ask)</script>")

# The scroll page of bench-typing's chromium-page-scroll (D8, task 135): SCROLL_ROWS rows, nothing running until a
# wheel event arrives. A wheel event (a passive listener: the compositor still scrolls, as for any page) starts one
# rAF loop if none runs, and the loop runs until SCROLL_QUIET_MS pass with no wheel event. Each loop is one run of
# the record, so a pause in the input longer than the quiet time starts a new run and is never a frame interval. Per
# frame the run keeps the rAF time (the BeginMainFrame time, vsync aligned) and the time after that frame's
# main-thread work (a MessageChannel message posted in the rAF callback, as acpmux perf.ts times a key's `paint`).
# Both are main-frame times, not presentation times: the loop itself asks for a main frame every vsync, and a frame
# that viz or the display compositor drops after its main frame is not seen. The read path is the animated page's: a
# held GET of SCROLL_READ_PATH; once the bench reads (IdlePages.read_scroll) the page POSTs
# SCROLL_FRAMES_PATH/<wheel events>/<scrolled px>/<rAF runs>/<after-frame runs> (ms from the record's first frame,
# comma separated, runs separated by `;`, `-` for none), starts a new record and, with no loop running, scrolls back
# to the top, so every gesture has the page's height to scroll.
SCROLL_PATH = "/scroll"
SCROLL_READ_PATH = "/scroll-read"
SCROLL_FRAMES_PATH = "/scroll-frames"
SCROLL_QUIET_MS = 50
SCROLL_ROWS = 500
SCROLL_PAGE_PX = SCROLL_ROWS * 96  # 88 px rows, their 8 px margins collapsed between rows
SCROLL_PAGE = ("<!doctype html><meta charset='utf-8'><title>scroll</title>"
               "<style>body{margin:0;font:16px -apple-system,sans-serif;background:#f4f4f6}"
               ".r{height:88px;margin:8px 16px;padding:0 12px;border-radius:10px;background:#c9d4e8;line-height:88px}"
               "</style><div id='rows'></div><script>const rows=document.getElementById('rows');"
               f"for(let i=0;i<{SCROLL_ROWS};i++){{const d=document.createElement('div');d.className='r';"
               "d.textContent='row '+i+' lorem ipsum dolor sit amet';rows.appendChild(d)}"
               "let runs=[],posts=[],run=null,post=null,wheels=0,from=null,last=-1e9,looping=false;"
               f"function tick(t){{if(run.length&&performance.now()-last>{SCROLL_QUIET_MS}){{looping=false;return}}"
               "run.push(t);const into=post,channel=new MessageChannel();"
               "channel.port1.onmessage=function(){into.push(performance.now());channel.port1.close()};"
               "channel.port2.postMessage(0);requestAnimationFrame(tick)}"
               "addEventListener('wheel',function(){wheels++;last=performance.now();if(from===null)from=scrollY;"
               "if(!looping){looping=true;run=[];post=[];runs.push(run);posts.push(post);requestAnimationFrame(tick)}},"
               "{passive:true});"
               "function enc(list,t0){return list.length?list.map(function(times){"
               "return times.map(function(t){return (t-t0).toFixed(2)}).join(',')}).join(';'):'-'}"
               f"function ask(){{fetch('{SCROLL_READ_PATH}',{{cache:'no-store'}}).then(function(){{"
               "const t0=runs.length&&runs[0].length?runs[0][0]:0,n=wheels,moved=from===null?0:Math.round(scrollY-from);"
               "const fields=n+'/'+moved+'/'+enc(runs,t0)+'/'+enc(posts,t0);"
               "runs=looping?[run]:[];posts=looping?[post]:[];wheels=0;from=null;if(!looping)scrollTo(0,0);"
               f"return fetch('{SCROLL_FRAMES_PATH}/'+fields,{{method:'POST'}})}})"
               ".then(ask,function(){setTimeout(ask,1000)})}"
               "fetch('/loaded/scroll',{method:'POST'}).then(ask)</script>")


# The tab sessions' pages (D17, p14-energy-048): tab_pages' static page (it POSTs /loaded/<key> and /vis/<key>/<state>
# at load and on every visibilitychange, nothing else) plus a visibility probe. PROBE_DELAY_MS after the page reports
# `hidden` (a timer of the hidden page, so Chromium has throttled it by then and the freeze grace of
# FREEZE_HIDDEN_TABS_S has not ended), it counts for PROBE_MS its rAF callbacks and the fires of a setTimeout(0)
# chain, then POSTs PROBE_REPORT_PATH/<key>/<state at start>/<state at end>/<rAF>/<timer fires>/<first to last fire
# ms>/<probe ms>/<ms hidden at start>/<1: no visibilitychange in it>. A page shown again before its probe starts runs
# none. A page that never reports `hidden` is never probed: its visibilityState is the finding. No held request, no
# DevTools port: Release builds have none, and the page runs nothing in the window.
PROBE_PATH = "/probe"
PROBE_REPORT_PATH = "/probe-report"
PROBE_DELAY_MS = 11000
PROBE_MS = 4000
PROBE_PAGE = ("<title>static {key}</title><body style='font:16px system-ui'><h1>Static page {key}</h1>"
              "<p>Nothing runs here.</p><script>(function(){{const k='{key}';let gen=0,hiddenAt=0;"
              "const post=p=>fetch(p,{{method:'POST'}});post('/loaded/'+k);"
              "function probe(g){{const t0=performance.now(),s0=document.visibilityState;"
              "let raf=0,n=0,first=0,last=0,done=false;"
              "requestAnimationFrame(function f(){{if(done)return;raf++;requestAnimationFrame(f)}});"
              "function tick(){{const now=performance.now();if(!n)first=now;n++;last=now;"
              "if(now-t0<{window}){{setTimeout(tick,0);return}}done=true;"
              "post('{report}/'+[k,s0,document.visibilityState,raf,n,Math.round(last-first),Math.round(now-t0),"
              "Math.round(t0-hiddenAt),g===gen?1:0].join('/'))}}setTimeout(tick,0)}}"
              "function vis(){{const s=document.visibilityState;post('/vis/'+k+'/'+s);const g=++gen;"
              "if(s!=='hidden')return;hiddenAt=performance.now();setTimeout(function(){{if(g===gen)probe(g)}},{delay})}}"
              "vis();document.addEventListener('visibilitychange',vis)}})()</script>")
# A hidden page's limits (D17): no rAF, at most 1 timer wake a second (Chrome aligns a hidden page's timers to one
# wake a second, third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc).
HIDDEN_TIMER_WAKES_MAX = 1.0


def probe_page(key):
    """The probe page of tab `key` (PROBE_PAGE)."""
    return PROBE_PAGE.format(key=key, window=PROBE_MS, delay=PROBE_DELAY_MS, report=PROBE_REPORT_PATH)


def parse_probe(path):
    """(key, probe) from the page's PROBE_REPORT_PATH POST: the states at the probe's two ends, rAF callbacks and
    rAF/s, timer fires and timer wakes/s (the intervals between the first and last fire: a probe that starts between
    two aligned wakes counts no extra one), the probe's and the hidden time in ms, and `intact` (the page stayed as it
    was through it); (None, {"error": ...}) for an unreadable post."""
    parts = path.split("?", 1)[0].removeprefix(PROBE_REPORT_PATH + "/").split("/")
    try:
        key, start, end = parts[0], parts[1], parts[2]
        raf, fires, span_ms, probe_ms, hidden_ms, intact = (int(float(value)) for value in parts[3:9])
    except (IndexError, ValueError):
        return None, {"error": f"unreadable probe post {path[:80]}"}
    seconds = probe_ms / 1000
    wakes = round((fires - 1) / (span_ms / 1000), 2) if fires >= 2 and span_ms > 0 else None
    return key, {"state_start": start, "state_end": end, "raf": raf,
                 "raf_per_s": round(raf / seconds, 2) if seconds > 0 else None, "timer_fires": fires,
                 "timer_wakes_per_s": wakes, "probe_ms": probe_ms, "hidden_ms": hidden_ms, "intact": intact == 1}


def parse_anim_count(path):
    """{count, t_ms, visibility} from the page's ANIM_COUNT_PATH POST, or {"error": ...}."""
    parts = path.split("?", 1)[0].removeprefix(ANIM_COUNT_PATH + "/").split("/")
    try:
        return {"count": int(parts[0]), "t_ms": float(parts[1]), "visibility": parts[2]}
    except (IndexError, ValueError):
        return {"error": f"unreadable rAF count post {path[:80]}"}


def parse_scroll_frames(path):
    """{wheels, scrolled_px, runs_ms, post_runs_ms} from the scroll page's SCROLL_FRAMES_PATH POST, or
    {"error": ...}. `runs_ms` holds one list per rAF loop (SCROLL_PAGE) of its frames' rAF times and `post_runs_ms`
    the same frames' after-frame times, in ms from the record's first frame (no runs when no input came)."""
    parts = path.split("?", 1)[0].removeprefix(SCROLL_FRAMES_PATH + "/").split("/")

    def runs(field):
        return [] if field == "-" else [[float(v) for v in run.split(",")] if run else [] for run in field.split(";")]
    try:
        if len(parts) != 4:
            raise ValueError(f"{len(parts)} fields")
        return {"wheels": int(parts[0]), "scrolled_px": int(parts[1]), "runs_ms": runs(parts[2]),
                "post_runs_ms": runs(parts[3])}
    except ValueError:
        return {"error": f"unreadable scroll frames post {path[:80]}"}


class HeldRead:
    """One page's read path: the page keeps one GET of `read_path` open, the server holds it until the bench asks
    (``read``), and the page then POSTs `post_path/<fields>` (parsed by `parse`) and asks again."""

    def __init__(self, read_path, post_path, parse, what):
        self.read_path, self.post_path, self.parse, self.what = read_path, post_path, parse, what
        self._cond = threading.Condition()
        self._asked = 0  # reads the bench asked for
        self._answered = 0  # reads a held GET answered; a GET is held while this equals asked
        self._posts = []  # the page's parsed posts, in order

    def hold(self, closing):
        """Holds the page's GET until the bench asks for a read or the server closes."""
        with self._cond:
            self._cond.wait_for(lambda: self._asked > self._answered or closing.is_set())
            self._answered = self._asked

    def posted(self, path):
        with self._cond:
            self._posts.append(self.parse(path))
            self._cond.notify_all()

    def read(self, seconds):
        """The page's next post: answers its held read and waits for what it posts (a read asked before the page's
        next GET arrives is answered by that GET); {"error": ...} when nothing comes in `seconds`."""
        with self._cond:
            posted = len(self._posts)
            self._asked += 1
            self._cond.notify_all()
            if not self._cond.wait_for(lambda: len(self._posts) > posted, seconds):
                return {"error": f"the page posted no {self.what} in {seconds:g} s (no held {self.read_path})"}
            return self._posts[posted]

    def wake(self):
        with self._cond:
            self._cond.notify_all()


class IdlePages(tab_pages.TabPages):
    """The shared tab-page server plus the tab sessions' probe pages (PROBE_PATH-<key>, their posts in `probes`:
    {key: [parse_probe's probe, in order]}), energy-saver's animated page at ANIM_PATH, bench-typing's scroll page at
    SCROLL_PATH, and their read paths."""

    def __init__(self, *args, **kwargs):
        self._held = {held.read_path: held for held in (
            HeldRead(ANIM_READ_PATH, ANIM_COUNT_PATH, parse_anim_count, "rAF count"),
            HeldRead(SCROLL_READ_PATH, SCROLL_FRAMES_PATH, parse_scroll_frames, "scroll frames"))}
        self._probes = threading.Lock()  # guards probes and probe_errors
        self.probes = {}
        self.probe_errors = []
        super().__init__(*args, **kwargs)

    def probe_url(self, key):
        return f"{self.origin}{PROBE_PATH}-{key}"

    def body(self, path):
        path = path.split("?", 1)[0]
        if path.startswith(PROBE_PATH + "-"):
            return probe_page(path.removeprefix(PROBE_PATH + "-")).encode()
        if path == ANIM_PATH:
            return ANIM_PAGE.encode()
        if path == SCROLL_PATH:
            return SCROLL_PAGE.encode()
        if path in self._held:
            self._held[path].hold(self.closing)
            return b""
        return super().body(path)

    def report(self, path):
        if path.startswith(PROBE_REPORT_PATH + "/"):
            key, probe = parse_probe(path)
            with self._probes:
                if key is None:
                    self.probe_errors.append(probe["error"])
                else:
                    self.probes.setdefault(key, []).append(probe)
            return
        for held in self._held.values():
            if path.startswith(held.post_path + "/"):
                held.posted(path)
                return
        super().report(path)

    def read_anim(self, seconds=10):
        """The animated page's {count, t_ms, visibility} now (HeldRead.read)."""
        return self._held[ANIM_READ_PATH].read(seconds)

    def read_scroll(self, seconds=10):
        """The scroll page's {wheels, scrolled_px, runs_ms, post_runs_ms} since its last read (HeldRead.read); the
        page then starts a new record."""
        return self._held[SCROLL_READ_PATH].read(seconds)

    def page_states(self):
        """({key: the latest document.visibilityState}, {key: [probes]}) now, one copy each."""
        with self._probes:
            return dict(self.visibility), {key: list(probes) for key, probes in self.probes.items()}

    def close(self):
        """Ends the held reads with the other held loads."""
        super().close()
        for held in self._held.values():
            held.wake()

    def wait_loaded(self, key, seconds):
        """True once the page `key` reported /loaded/<key>, False after `seconds`."""
        deadline = time.monotonic() + seconds
        while key not in self.loaded:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.2)  # bench: bounded wait for the tab's page to load
        return True


class SessionShapeError(RuntimeError):
    """The session could not be built as its table entry says (a tab that never opened, a window not minimized)."""


def run_action(app, action, args=None, focus=False, timeout=30, target=None):
    """action.run from a script; raises SessionShapeError on the app's refusal. A reply that times out is no
    refusal (a cold CefInitialize can outlast the reply while the tab still opens): the caller checks the result.
    `focus` selects what the action opens, as STRESS and browser-idle-cost-live open their tabs; `target` is the
    action's target (`tab:<id>`)."""
    params = {"action": action, "args": args or {}, "focus": focus, "origin": "script"}
    if target is not None:
        params["target"] = target
    reply = app.rpc("action.run", params, timeout=timeout)
    error = reply.get("error") if isinstance(reply, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if error and code != "timeout" and not (isinstance(reply, dict) and reply.get("unreachable")):
        raise SessionShapeError(f"{action} refused: {str(error)[:200]}")
    return reply


def plan_keys(tabs):
    """[(engine, loaded key)] of a session's tabs in opening order: the hidden WebKit tabs, the hidden Chromium tabs,
    then the shown Chromium tab (`tabs["shown"]`: "static", key "shown", or "anim", key "anim")."""
    return ([("webkit", f"w{n}") for n in range(tabs["webkit_hidden"])]
            + [("chromium", f"c{n}") for n in range(tabs["chromium_hidden"])]
            + [("chromium", "anim" if tabs["shown"] == "anim" else "shown")])


def tab_plan(pages, tabs):
    """[(engine, url, loaded key)] of a session's tabs (plan_keys): each a probe page (IdlePages.probe_url), the
    animated one at ANIM_PATH."""
    return [(engine, pages.origin + ANIM_PATH if key == "anim" else pages.probe_url(key), key)
            for engine, key in plan_keys(tabs)]


def build_tabs(app, pages, tabs):
    """Opens the session's tabs (tab_plan) in the launch pane; a new tab is selected, so every earlier one is hidden
    behind the last. Waits for each page to load. Returns ({engine: count} of the opened tabs, the shown tab:
    {engine, tabs: the debug.webui `browser_tabs` names the last open added, empty for a WebKit tab or a build with
    no census}), so the window's kinds tell hidden tabs' processes from the shown one's (WindowKinds)."""
    opened, shown = {}, None
    plan = tab_plan(pages, tabs)
    for index, (engine, url, key) in enumerate(plan):
        before = browser_tab_names(app) if index == len(plan) - 1 else None
        run_action(app, f"openBrowser.{engine}", {"url": url}, focus=True, timeout=90)
        if not pages.wait_loaded(key, 90):
            raise SessionShapeError(f"{engine} tab {url} did not load in 90 s")
        opened[engine] = opened.get(engine, 0) + 1
        if before is not None:
            shown = {"engine": engine, "tabs": sorted(browser_tab_names(app) - before)}
    return opened, shown


def browser_tab_names(app):
    """The census names of the app's Chromium browser tabs now (debug.webui `browser_tabs`)."""
    return {tab.get("tab") for tab in census_rows(read_rpc(app, "debug.webui"), "browser_tabs")}


def anim_rate(start, end):
    """{raf_per_s, visibility} of the animated page between two IdlePages.read_anim results (the page's own clock),
    or the first error."""
    for read in (start, end):
        if not isinstance(read, dict) or "error" in read or not isinstance(read.get("count"), (int, float)):
            return {"error": (read or {}).get("error", "no rAF count") if isinstance(read, dict) else "not read"}
    seconds = (end["t_ms"] - start["t_ms"]) / 1000
    if seconds <= 0:
        return {"error": "the page clock did not advance"}
    return {"raf_per_s": round((end["count"] - start["count"]) / seconds, 2), "seconds": round(seconds, 1),
            "visibility": [start.get("visibility"), end.get("visibility")]}


def expected_visibility(spec, key, shown):
    """What tab `key` of a session (`spec`, its SESSIONS entry) should report: the shown tab `visible`, unless the
    session hides, minimizes or covers its window; every other tab `hidden`."""
    if key != shown:
        return "hidden"
    return "hidden" if spec.get("hide") or spec.get("minimize") or spec.get("cover") else "visible"


def hidden_probe(probes):
    """The last probe of a tab that ran hidden from start to end with no visibilitychange in it, or None."""
    for probe in reversed(probes or []):
        if probe.get("intact") and probe.get("state_start") == "hidden" and probe.get("state_end") == "hidden":
            return probe
    return None


def tab_visibility(engine, expected, start, end, probes):
    """One tab's D17 row: the visibilityState it reported last at the window's start and end, its last hidden probe,
    and (problems, unknowns): a state other than `expected`, rAF or more than HIDDEN_TIMER_WAKES_MAX timer wakes/s
    in a hidden probe; no state reported, or a hidden tab with no hidden probe."""
    probe = hidden_probe(probes)
    problems, unknowns = [], []
    for when, state in (("window start", start), ("window end", end)):
        if state is None:
            unknowns.append(f"no visibilityState by the {when}")
        elif state != expected:
            problems.append(f"visibilityState {state} at the {when}, expected {expected}")
    if expected == "hidden" and start == "hidden":
        if probe is None:
            unknowns.append("no hidden probe")
        else:
            if probe["raf"] > 0:
                problems.append(f"{probe['raf_per_s']} rAF/s while hidden")
            wakes = probe["timer_wakes_per_s"]
            if wakes is None:
                unknowns.append("the hidden probe's timer fired less than twice")
            elif wakes > HIDDEN_TIMER_WAKES_MAX:
                problems.append(f"{wakes} timer wakes/s while hidden > {HIDDEN_TIMER_WAKES_MAX:g}")
    return {"engine": engine, "expected": expected, "window_start": start, "window_end": end, "probe": probe,
            "probes": len(probes or []), "problems": problems, "unknown": unknowns}


def visibility_report(spec, tabs, before, after, probes, judged_engine="chromium"):
    """D17 of one session (plans/cmux-next/chrome-parity/p14-energy.md, task 048), reported and never judged as an
    over: per tab of `tabs` (plan_keys; the animated page has its own visibility in `anim`) its tab_visibility row
    from the page states `before` and `after` the window ({key: state}, IdlePages.page_states) and its `probes`;
    `met` is True when every `judged_engine` tab reports what it should with a clean hidden probe, False when one
    does not, None when one is unknown. `wrong` and `unknown` name the tabs. WebKit tabs are reported, not judged
    (p14-energy-005 hides them)."""
    keys = plan_keys(tabs)
    shown = keys[-1][1]
    rows = {key: tab_visibility(engine, expected_visibility(spec, key, shown), before.get(key), after.get(key),
                                probes.get(key))
            for engine, key in keys if key != "anim"}
    judged = {key: row for key, row in rows.items() if row["engine"] == judged_engine}
    wrong = {key: row["problems"] for key, row in judged.items() if row["problems"]}
    unknown = {key: row["unknown"] for key, row in judged.items() if row["unknown"]}
    met = None if not judged else False if wrong else None if unknown else True
    return {"tabs": rows, "met": met, "wrong": wrong, "unknown": unknown}


def visibility_line(report):
    """The IDLE-BUDGET-VISIBILITY summary: met, then per tab its two states and its hidden probe's rAF/s and timer
    wakes/s."""
    tabs = {key: [row["window_start"], row["window_end"]]
            + ([row["probe"]["raf_per_s"], row["probe"]["timer_wakes_per_s"]] if row["probe"] else [])
            for key, row in report["tabs"].items()}
    return json.dumps({"met": report["met"], "wrong": report["wrong"], "unknown": report["unknown"], "tabs": tabs})


def build_stress(app, static=False):
    """STRESS, then its busy terminals stopped (Ctrl-C), so the terminals are quiet. With `static` its pages
    have no rAF spinner (STRESS's own pages animate, which is not idle)."""
    stress_module = load_stress()
    stress = stress_module.Stress(app.rpc)
    if static:
        stress.pages = tab_pages.TabPages(default_kind="grid")
    summary = stress.build()
    for tab in getattr(stress, "busy", []):
        stress.send(tab, "\x03")
    summary["busy_terminals_stopped"] = len(getattr(stress, "busy", []))
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


# ---------------------------------------------------------------------------------------------------------
# The agent sessions and busy-hidden (p14-energy-103, D14)

# The app runs its own acpmux home whose default harness is the ACP fake agent, as readiness-soak.py runs it: no
# network and no credential, but the same agent hosts and session pool a real harness gets.
FAKE_AGENT = os.path.join(HERE, "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
AGENT_HARNESS_ID = "idle-budget-agent"
# p14-energy-117 freezes the harness of an idle hidden session this long after it hides (freezeAfterSeconds); agent-idle
# settles past it (FREEZE_GRACE_S more), so its rows are the frozen state D14 judges once 117 lands.
HARNESS_FREEZE_S = 300
# The pooled entry outlives the settle and the window (acpmux's default pool.idleMinutes is 10).
POOL_IDLE_MINUTES = 60
# How long acpmux, an agent page, a chat start or a turn may take to answer while the session is built.
AGENT_STEP_S = 60
# busy-hidden: the hidden terminal prints one line this often.
BUSY_PERIOD_S = 0.1


def agent_config(python, agent):
    """config.json of the session's acpmux home: the fake agent is the default harness, and a pooled entry stays
    for POOL_IDLE_MINUTES."""
    return {"harnesses": {AGENT_HARNESS_ID: {"argv": [python, agent]}}, "defaultHarness": AGENT_HARNESS_ID,
            "pool": {"idleMinutes": POOL_IDLE_MINUTES}}


def chat_session(reply):
    """The session id in a debug.agent_pane chat_state reply (its `result` is the page's JSON, as text or an
    object), or None."""
    if not isinstance(reply, dict) or "error" in reply:
        return None
    result = reply.get("result", reply)
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            return None
    return result.get("sessionId") if isinstance(result, dict) else None


def turn_done(entry):
    """Whether an acpmux session entry (`_acpmux/sessions`) finished a turn, runs none and still has its harness:
    `ready` (store.rs SessionStatus::Ready, child alive). `idle` is no child process: a harness that exited, which
    the session would then measure as nothing."""
    return entry.get("status") == "ready" and bool((entry.get("lastTurn") or {}).get("endedAt"))


def answered(reply):
    return isinstance(reply, dict) and "error" not in reply


class AgentHome:
    """The session's acpmux home and socket (ACPMUX_HOME, ACPMUX_SOCKET in the app's env, which its acpmux and agent
    hosts inherit): config.json (agent_config), the chats' folder, the gates of working turns, and JSON-RPC over
    the socket (one request per connection after `initialize`, as readiness-soak.py's Acpmux)."""

    def __init__(self, folder, session):
        self.folder = folder
        self.home = os.path.join(folder, "acpmux")
        self.cwd = os.path.join(folder, "agent-work")
        self.pool_cwd = os.path.join(folder, "agent-pool")
        # One socket per run, short enough for AF_UNIX (104 bytes) whatever --out is.
        self.socket = f"/tmp/idle-budget-acp-{os.getpid()}-{session}.sock"
        self.gates = []

    def env(self):
        return {"ACPMUX_HOME": self.home, "ACPMUX_SOCKET": self.socket}

    def write(self):
        shutil.rmtree(self.home, ignore_errors=True)
        for folder in (self.home, self.cwd, self.pool_cwd):
            os.makedirs(folder, exist_ok=True)
        agent = os.path.join(self.folder, "fake_agent.py")
        shutil.copy(FAKE_AGENT, agent)
        with open(os.path.join(self.home, "config.json"), "w") as handle:
            json.dump(agent_config(sys.executable, agent), handle)

    def call(self, method, params=None, timeout=10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            try:
                conn.connect(self.socket)
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1, "clientInfo": {"name": "idle-budget", "version": "1"}}}
                request = {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}}
                conn.sendall((json.dumps(init) + "\n" + json.dumps(request) + "\n").encode())
                buffer = b""
                while True:
                    chunk = conn.recv(1 << 16)
                    if not chunk:
                        return {"error": "acpmux closed the connection"}
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line or b"{}")
                        if message.get("id") == 2:
                            if "error" in message:
                                return {"error": message["error"]}
                            result = message.get("result")
                            return {} if result is None else result  # a null result is an answer
            except (OSError, ValueError) as error:
                return {"error": str(error)}

    def sessions(self):
        reply = self.call("_acpmux/sessions")
        found = reply.get("sessions") if answered(reply) else None
        return {s.get("sessionId"): s for s in found or [] if isinstance(s, dict)}

    def host_pid(self, session_id):
        """The agent host pid of `session_id` from its discovery record (`hosts/<session id>.json`), or None."""
        try:
            with open(os.path.join(self.home, "hosts", f"{session_id}.json")) as handle:
                pid = json.load(handle).get("host_pid")
        except (OSError, ValueError, AttributeError):
            return None
        return pid if isinstance(pid, int) and pid > 1 else None

    def pool_ready(self, cwd):
        """The ready pooled entries in `cwd` (`_acpmux/status` pool.entries, hub/pool pool_view_json): not an entry
        the agent page hinted for its own folder."""
        reply = self.call("_acpmux/status")
        entries = ((reply.get("pool") or {}).get("entries") if answered(reply) else None) or []
        folder = os.path.realpath(cwd)
        return [e for e in entries if isinstance(e, dict) and e.get("state") == "ready"
                and isinstance(e.get("cwd"), str) and os.path.realpath(e["cwd"]) == folder]

    def pool_host_pids(self):
        """The host pids of the pooled entries' records (`hosts/pool/*.json`, agent_host::POOL_DIR_NAME)."""
        folder = os.path.join(self.home, "hosts", "pool")
        pids = []
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(folder, name)) as handle:
                    pid = json.load(handle).get("host_pid")
            except (OSError, ValueError, AttributeError):
                continue
            if isinstance(pid, int) and pid > 1:
                pids.append(pid)
        return pids

    def trust(self, cwd):
        """acp.trust.set `cwd` trusted; returns the refusal (an error reply), printed as AGENT-SESSION-TRUST-REFUSED,
        or None."""
        reply = self.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
        if answered(reply):
            return None
        refusal = {"cwd": cwd, "error": reply.get("error") if isinstance(reply, dict) else reply}
        print("AGENT-SESSION-TRUST-REFUSED " + json.dumps(refusal), flush=True)
        return refusal

    def gate(self):
        """A FIFO the fake agent's `gate:` turn blocks on until release(): a turn that sends nothing meanwhile."""
        path = os.path.join(self.folder, f"gate-{len(self.gates)}")
        if not os.path.exists(path):
            os.mkfifo(path)
        self.gates.append(path)
        return path

    def release(self):
        """Ends every gated turn (its reader is the fake agent; with none, there is nothing to end)."""
        for path in self.gates:
            try:
                fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                os.write(fd, b"go\n")
            finally:
                os.close(fd)


def open_agent_chat(app, home, stress, wait, pane, prompt):
    """An agent chat in `pane` on the fake harness in home.cwd with `prompt` sent, as a person opens one: the agent
    tab (palette.newAgentChat), then the page's own new-chat and send verbs (debug.agent_pane), each sent once: a
    retry after an error reply (a timeout after the page acted) would open a second chat or send the prompt twice.
    Only read-only state (chat_state, acpmux status) is polled. `stress` and `wait` are perf-stress-session.py's
    builder and bounded poll. Returns {session, engine (`debug.agent_pane engine`: cef or webkit:<reason>), trust
    (acp.trust.set's refusal, or None)}; SessionShapeError when a step does not answer."""
    stress.action("palette.newAgentChat", target=f"pane:{pane}")

    def page(action, **args):
        return app.rpc("debug.agent_pane", {"action": action, "pane": pane, **args}, timeout=AGENT_STEP_S)

    def once(action, **args):
        reply = page(action, **args)
        if not answered(reply):
            raise SessionShapeError(f"pane {pane}: {action} refused: {json.dumps(reply)[:300]}")
        return reply

    def state():
        reply = page("chat_state")
        return reply if answered(reply) else None

    before = wait(state, AGENT_STEP_S, step=1)
    if not before:
        raise SessionShapeError(f"no agent page in pane {pane} (refusals: {stress.refusals[-3:]})")
    if not wait(lambda: answered(home.call("_acpmux/status", timeout=3)), AGENT_STEP_S, step=1):
        raise SessionShapeError(f"acpmux does not answer on {home.socket}")
    trust = home.trust(home.cwd)
    started = once("new_chat", harness=AGENT_HARNESS_ID, cwd=home.cwd)
    if started.get("pending"):
        raise SessionShapeError(f"pane {pane}: new_chat waits on a question (folder trust: {trust or 'set'})")
    sent = once("send_prompt", text=prompt)
    prior = chat_session(before)

    def new_session(candidate):
        return candidate if candidate and candidate != prior else None

    session = new_session(sent.get("sessionId")) or wait(lambda: new_session(chat_session(state())), AGENT_STEP_S, step=1)
    if not session:
        raise SessionShapeError(f"pane {pane}: the chat has no new session after its prompt")
    engine = page("engine")
    return {"session": session, "engine": engine.get("engine") if answered(engine) else None, "trust": trust}


def build_agents(app, home, plan, stress_module=None):
    """The agent panes of `plan` (SESSIONS `agents`): with `hidden`, a chat in a new workspace that then hides
    behind the launch workspace; with `visible`, a chat in the launch pane, its turn gated (sends nothing until
    AgentHome.release) when `working`, else finished, on `engine` when the plan names one; `pool` ready pooled
    entries in home.pool_cwd (_acpmux/prewarm). Returns what it built: `plan`, `hidden_hosts` the agent host pids of
    the hidden chats (measure's hidden rows), `pool_hosts` the pooled hosts' pids (agent_refusals), `trust` the
    refused acp.trust.set calls. `stress_module`: perf-stress-session.py (load_stress) or a test's fake."""
    module = stress_module or load_stress()
    stress, wait = module.Stress(app.rpc), module.wait
    shown = stress.focused_workspace()
    built = {"plan": plan, "shown_workspace": shown, "hidden_hosts": [], "pool_hosts": [], "chats": [], "trust": []}

    def opened(pane, prompt):
        chat = open_agent_chat(app, home, stress, wait, pane, prompt)
        if chat["trust"]:
            built["trust"].append(chat["trust"])
        return chat

    def first_pane(workspace):
        panes = stress.panes(stress.workspace(workspace))
        if not panes:
            raise SessionShapeError(f"workspace {workspace} has no pane")
        return panes[0]["id"]

    def finished(session):
        if not wait(lambda: turn_done(home.sessions().get(session) or {}), AGENT_STEP_S, step=1):
            raise SessionShapeError(f"chat {session}: its turn did not finish ({home.sessions().get(session)})")

    if plan.get("hidden"):
        workspace = stress.new_workspace()
        if not workspace:
            raise SessionShapeError("the hidden chat's workspace did not appear")
        stress.show(workspace)
        chat = opened(first_pane(workspace), "hello")
        session = chat["session"]
        finished(session)
        host = home.host_pid(session)
        if host is None:
            raise SessionShapeError(f"chat {session} has no agent host record in {home.home}/hosts")
        built["hidden_hosts"].append(host)
        built["chats"].append({"session": session, "workspace": workspace, "visible": False, "host_pid": host,
                               "engine": chat["engine"]})
        stress.show(shown)
        if stress.window_showing(workspace):
            raise SessionShapeError(f"workspace {workspace} still shows after the launch workspace was shown")
    if plan.get("visible"):
        working = plan.get("working", False)
        chat = opened(first_pane(shown), f"gate: {home.gate()}" if working else "hello")
        session = chat["session"]
        if plan.get("engine") and chat["engine"] != plan["engine"]:
            # The session's row sums the kinds of `engine` (agent-working-visible: cef); a chat on another engine
            # does its work in kinds the row does not read.
            raise SessionShapeError(f"chat {session} shows on {chat['engine']}, the session measures {plan['engine']}")
        if working:
            if not wait(lambda: (home.sessions().get(session) or {}).get("status") == "running", AGENT_STEP_S, step=1):
                raise SessionShapeError(f"chat {session}: its gated turn does not run ({home.sessions().get(session)})")
        else:
            finished(session)
        built["chats"].append({"session": session, "workspace": shown, "visible": True, "working": working,
                               "host_pid": home.host_pid(session), "engine": chat["engine"]})
    if plan.get("pool"):
        trust = home.trust(home.pool_cwd)
        if trust:
            built["trust"].append(trust)
        reply =home.call("_acpmux/prewarm", {"harness": AGENT_HARNESS_ID, "cwd": home.pool_cwd, "wait": True},
                          timeout=AGENT_STEP_S * 2)
        built["prewarm"] = reply
        if not answered(reply) or reply.get("accepted") is not True:
            raise SessionShapeError(f"_acpmux/prewarm in {home.pool_cwd} refused: {json.dumps(reply)[:300]}"
                                    + (f" (trust: {json.dumps(trust)[:200]})" if trust else ""))
        if not wait(lambda: len(home.pool_ready(home.pool_cwd)) >= plan["pool"], AGENT_STEP_S, step=1):
            raise SessionShapeError(f"{plan['pool']} ready pooled entries in {home.pool_cwd} wanted, "
                                    f"{len(home.pool_ready(home.pool_cwd))} (prewarm: {json.dumps(reply)[:300]})")
        built["pool_entries"] = len(home.pool_ready(home.pool_cwd))
        built["pool_hosts"] = home.pool_host_pids()
        if not built["pool_hosts"]:
            raise SessionShapeError(f"no pooled host record in {home.home}/hosts/pool")
    if stress.refusals:
        built["refusals"] = stress.refusals
    print("AGENT-SESSION " + json.dumps(built), flush=True)
    return built


def build_busy_hidden(app, period_s, stress_module=None):
    """The launch terminal prints one line every `period_s`, then a new workspace shows over it: the printing
    terminal is hidden."""
    stress = (stress_module or load_stress()).Stress(app.rpc)
    printing = stress.focused_workspace()
    tabs = [tab for pane in stress.panes(stress.workspace(printing)) for tab in pane.get("tabs") or []]
    tab = next((t for t in tabs if t.get("selected")), tabs[0] if tabs else None)
    if not tab or not tab.get("id"):
        raise SessionShapeError(f"the launch workspace {printing} has no terminal tab")
    stress.send(tab["id"], f"while :; do echo idle-budget-tick; sleep {period_s:g}; done\n")
    if stress.refusals:
        raise SessionShapeError(f"terminal.sendText refused: {stress.refusals}")
    shown = stress.new_workspace()
    if not shown:
        raise SessionShapeError("the workspace over the printing terminal did not appear")
    stress.show(shown)
    if stress.window_showing(printing):
        raise SessionShapeError(f"the printing workspace {printing} still shows")
    built = {"printing_workspace": printing, "printing_tab": tab["id"], "period_s": period_s, "shown_workspace": shown}
    print("BUSY-HIDDEN-SESSION " + json.dumps(built), flush=True)
    return built


def session_app(app_class, app_path, out, session, env, runs=None):
    """(app, agents) of one cmux session: an agent session's AgentHome (else None), whose ACPMUX_HOME and
    ACPMUX_SOCKET join the session's launch env (session_env), so the app's acpmux and agent hosts run in it.
    The app's result-v1 files go into `out` itself (the lab reads only that folder) as the session's perf session
    (idle_burst_bench_report.idle_budget_story: stress for a STRESS session), in the run its story's sessions
    share (`runs`: story -> perf_result.Run, filled here); its log and the agent home go into out/<session>.
    `app_class`: BenchApp."""
    import idle_burst_bench_report as results_v1
    folder = os.path.join(out, session)
    os.makedirs(folder, exist_ok=True)
    story, _engine, perf_session = results_v1.idle_budget_story(session, SESSIONS[session])
    run = None
    if runs is not None:
        run = runs[story] = runs.get(story) or results_v1.perf_result.Run.start()
    agents = AgentHome(folder, session) if SESSIONS[session].get("agents") else None
    app = app_class(app_path, out=out, env={**session_env(session, env), **(agents.env() if agents else {})},
                    config=session_config(session), log_name=os.path.join(session, "app.log"),
                    perf_session=perf_session, run=run)
    return app, agents


def start_session(app, agents, spec, entry, stress_module=None):
    """Writes the agent home before the launch (acpmux reads its config.json at start), launches, then builds the
    agent panes and the printing hidden terminal of `spec` into `entry`."""
    if agents:
        agents.write()
    app.launch()
    if spec.get("agents"):
        entry["agents"] = build_agents(app, agents, spec["agents"], stress_module)
    if spec.get("busy_terminal"):
        entry["busy_terminal"] = build_busy_hidden(app, spec["busy_terminal"], stress_module)


def stop_session(app, agents):
    """Ends the gated turns before the app stops (a turn blocked on its gate would outlive the teardown), and stops
    the app whatever the release did."""
    try:
        if agents:
            agents.release()
    finally:
        app.stop()


def build_sha_of(app_path):
    """The commit the app was built from (bench_launch.build_sha); raises bench_launch.RecordError when neither the
    bundle nor CMUX_CI_SHA names one (a hidden-wake report without its sha can not be cited)."""
    from bench_launch import build_sha
    return build_sha(app_path)


# Both keep-awake settings off (D11): their shipping default is pluggedIn, and a session that asks for keep-awake
# names them in its budget `settings`.
KEEP_AWAKE_OFF = {"sessions": {"keepAwake": "off"}, "phone": {"keepAwake": "off"}}
# The shipping measurement mode's hang reports (HangReportsSetting.path); with the tag's consent record they send.
HANG_REPORTS_ON = {"diagnostics": {"hangReports": True}}
# BenchApp's default, keep-awake off, hang reports on.
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}, **KEEP_AWAKE_OFF, **HANG_REPORTS_ON}
# Hidden Chromium tabs freeze this long after they hide (BrowserHibernationSetting's default, set explicitly so the
# settle below is known to outlast it); the tab sessions settle at least FREEZE_GRACE_S past it.
FREEZE_HIDDEN_TABS_S = 30
FREEZE_GRACE_S = 15
TABS_CONFIG = {"browser": {"freezeHiddenTabs": FREEZE_HIDDEN_TABS_S}}
TABS_STATIC = {"webkit_hidden": 5, "chromium_hidden": 10, "shown": "static"}
# The `energySaver` feature is default-off (schemas/features/features.d/energySaver.json) and the saver setting does
# nothing while it is off (EnergyPolicyResolver.isEnabled), so a launch that asks for the saver turns the feature on
# through CmuxNextFeatures' FeatureOverrides.enableVariable.
ENERGY_FEATURE_ENV = {"CMUX_ENABLE_FEATURES": "energySaver"}


def saver_launch(on):
    """(cmux-next.json keys, environment) of a launch with the energy saver forced on (`energy.saver: always`) or
    off (`off`). The feature is on in both, so two runs differ only in the setting (D8 compares them)."""
    return {"energy": {"saver": "always" if on else "off"}}, dict(ENERGY_FEATURE_ENV)



# The power sessions (p14-energy-096): one shown static Chromium tab and nothing else, in cmux and in the reference
# browser, every owner of the window's power attributed; settled past Chromium's two minutes of post-load work.
ONE_TAB = {"webkit_hidden": 0, "chromium_hidden": 0, "shown": "static"}
POWER_SESSION, CHROME_POWER_SESSION = "power-visible", "chrome-power-visible"
POWER_SETTLE_S = 120
# signed-in: Phone Access and the GitHub feed on (both off by default), keep-awake still off (D11, D13).
SIGNED_IN_CONFIG = {"phone": {"allowConnections": True}, "feed": {"github": {"enabled": True}}}
# Seconds auth.status has to report the test account signed in after the launch, and signed out after the sign-out.
SIGN_IN_WAIT_S = 90
SIGN_OUT_WAIT_S = 60
# Seconds an unsigned session waits for the app's restore of a stored sign-in to end (auth.status `restoring`).
RESTORE_WAIT_S = 30
# app-quit: seconds after the app's exit before the window (the daemon's own wind-down after its client left).
QUIT_SETTLE_S = 30
# external-churn: writes per second into the watched project, and seconds between two Chrome History visits.
CHURN_WRITES_PER_S = 10
HISTORY_PERIOD_S = 5
# The sessions (the docstring describes each). Keys: config (merged into BASE_CONFIG: session_config), env (adds to
# the launch environment: session_env), hide, minimize,
# stress, static (STRESS without its rAF spinner), tabs (build_tabs's plan), settle_min (seconds), saver (the energy
# saver state the session asks for; --gate refuses a window that shows another), anim (read the animated page's rAF
# count at both ends), power (attribute the window's power: power_attribution), chrome (the reference browser with
# the session's tabs), shown (role_audit: an app window, with a terminal, can be seen; a session without it gets
# only the role rules that hold in every session), hidden_wake (print HIDDEN-WAKE lines: hidden_wake_sources),
# agents (build_agents's plan, in the session's own acpmux home: AgentHome), busy_terminal (the hidden terminal's
# print period: build_busy_hidden), cover (benchhelper's full-screen window over the app), home (Home selected),
# sign_in (the agent test account), display_sleep (`pmset displaysleepnow` after the activation), quit
# (quitKeepSessions after the settle; the window measures what is left), churn (external-churn's writers),
# judge_shown_renderers (role_audit: a renderer the census marks shown must be not-background) and reshow (after the
# window, show a hidden tab and read the roles again: reshow_tab).
SESSIONS = {
    "light": {"shown": True},
    "light-webkit": {"config": {"browser": {"defaultEngine": "webkit"}}, "shown": True},
    "light-hidden": {"hide": True, "shown": False, "hidden_wake": True},
    "minimized": {"minimize": True, "shown": False, "hidden_wake": True},
    "occluded": {"cover": True},
    "home": {"home": True},
    "signed-in": {"config": SIGNED_IN_CONFIG, "sign_in": True, "shown": True},
    "signed-in-display-sleep": {"config": SIGNED_IN_CONFIG, "sign_in": True, "display_sleep": True},
    "app-quit": {"quit": True},
    "external-churn": {"churn": True, "hide": True, "shown": False},
    "stress": {"stress": True, "shown": True},
    "stress-static": {"stress": True, "static": True, "shown": True},
    "tabs-static": {"config": TABS_CONFIG, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S,
                    "shown": True, "judge_shown_renderers": True, "reshow": True},
    "energy-saver": {"config": {**TABS_CONFIG, **saver_launch(True)[0]}, "env": saver_launch(True)[1],
                     "tabs": {**TABS_STATIC, "shown": "anim"}, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S,
                     "saver": True, "anim": True, "shown": True},
    # The references (run_chrome_static): the cmux session's pages in a Chromium, settled as long as it.
    CHROME_SESSION: {"chrome": True, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
    POWER_SESSION: {"tabs": ONE_TAB, "power": True, "settle_min": POWER_SETTLE_S},
    CHROME_POWER_SESSION: {"chrome": True, "tabs": ONE_TAB, "power": True, "settle_min": POWER_SETTLE_S},
    "agent-idle": {"agents": {"visible": True, "hidden": True, "pool": 1},
                   "settle_min": HARNESS_FREEZE_S + FREEZE_GRACE_S, "shown": True},
    "agent-working-visible": {"agents": {"visible": True, "working": True, "engine": "cef"}, "shown": True},
    "busy-hidden": {"busy_terminal": BUSY_PERIOD_S, "shown": True},
}


# --visibility-tab (D17): the light sessions get one shown Chromium probe tab (ONE_TAB), so the visible tab of a hidden,
# minimized or covered window reports its visibility. Off by default: it changes those sessions' shape (D3 compares
# them with light, which then has the tab too). Its settle outlasts the probe.
LIGHT_SESSIONS = ("light", "light-hidden", "minimized", "occluded")
VISIBILITY_SETTLE_S = (PROBE_DELAY_MS + PROBE_MS) / 1000 + 5


def session_tabs(session, visibility_tab=False):
    """The tabs build_tabs opens for `session`: its own, or with `visibility_tab` ONE_TAB in a light session; None
    when it has none."""
    tabs = SESSIONS[session].get("tabs")
    if tabs is None and visibility_tab and session in LIGHT_SESSIONS:
        return ONE_TAB
    return tabs


def session_config(session):
    """The cmux-next.json of `session`: BASE_CONFIG with the session's own keys merged on top (a session's
    `phone.allowConnections` keeps BASE_CONFIG's `phone.keepAwake`)."""
    return merged(BASE_CONFIG, SESSIONS[session].get("config") or {})


def merged(base, top):
    """`base` with `top` merged in, key by key through nested objects; `top` wins on a leaf. Neither is changed."""
    out = dict(base)
    for key, value in top.items():
        out[key] = merged(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
    return out


def session_env(session, env):
    """The launch environment of `session`: `env` with the session's own variables on top."""
    return {**env, **(SESSIONS[session].get("env") or {})}


def parse_sessions(text):
    """The --sessions list (`all`: every session); SystemExit naming the first unknown one, before any launch."""
    names = list(SESSIONS) if text == "all" else [s for s in text.split(",") if s]
    for name in names:
        if name not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {name} (one of {', '.join(SESSIONS)})")
    return names


def settle_seconds(session, asked, tabs=None):
    """The settle of `session`: the asked one, at least the session's settle_min (past the hidden-tab freeze), and
    with tabs at least VISIBILITY_SETTLE_S (each hidden tab's probe ends before the window)."""
    return max(asked, SESSIONS[session].get("settle_min", 0), VISIBILITY_SETTLE_S if tabs else 0)


def wait_for(check, seconds, what):
    """Waits until `check()` is true; RuntimeError naming `what` after `seconds`."""
    deadline = time.monotonic() + seconds
    while not check():
        if time.monotonic() > deadline:
            raise RuntimeError(f"{CHROME_SESSION}: {what} after {seconds:g} s")
        time.sleep(0.2)  # bench: bounded wait for the reference browser


def build_template(browser, template, settle):
    """The template profile at `template`: built in a sibling folder and renamed into place only after the
    browser ran `settle` seconds (uBlock Origin compiles its filter lists into it), so an interrupted build
    leaves no half-built template behind."""
    if os.path.isdir(template):
        return False
    building = f"{template}.building-{os.getpid()}"
    shutil.rmtree(building, ignore_errors=True)
    os.makedirs(building)
    try:
        browser.launch(building, None)
        try:
            browser.ready()
            time.sleep(settle)  # bench: uBlock Origin compiles its lists into the template profile
        finally:
            browser.quit()
        os.replace(building, template)
    finally:
        shutil.rmtree(building, ignore_errors=True)
    return True


def run_chrome_static(opts, out, session=CHROME_SESSION):
    """A reference session (chrome-static, chrome-power-visible): the --chrome-app browser through xbench's launcher
    (an APFS clone of a template profile keyed on the browser build and uBlock Origin, --user-data-dir, xbench's
    switches, tabs over CDP /json/new) with the session's tab_plan pages (tabs-static's for chrome-static) from the
    shared page server in its order, every page loaded, the last shown, and the uBlock Origin the cmux app bundles;
    settled and measured as the cmux sessions are, its processes classified by chrome_kind; a `power` session's
    window attributed as a cmux one is (`power`). Raises before launch when the browser cannot run that uBlock
    Origin."""
    import xbench  # scripts/perf-bench (on sys.path): the Chrome launcher the cross-browser bench uses
    spec = SESSIONS[session]
    bundle = os.path.abspath(opts.chrome_app)
    if not os.path.isdir(bundle):
        raise RuntimeError(f"{session}: no {bundle}")
    if procs.main_pid(bundle):
        raise RuntimeError(f"{session}: {bundle} is already running; its processes would be measured too")
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, version = info.get("CFBundleIdentifier"), xbench.bundle_version(bundle)
    cmux_ublock = os.path.join(os.path.realpath(opts.app), UBLOCK_IN_APP)
    ublock = None if opts.chrome_ublock == "none" else opts.chrome_ublock or cmux_ublock
    manifest = read_manifest(ublock) if ublock else None
    if manifest:
        refusal = reference_refusal(bundle_id, version, manifest)
        if refusal:
            raise RuntimeError(f"{session}: {refusal}; pass --chrome-app a Chromium that runs MV2 "
                               "(ungoogled-chromium of cmux's Chromium major)")
    chrome_version = (manifest or {}).get("version")
    work = os.path.join(out, CHROME_SESSION)  # the keyed template profile, shared by every reference session
    helper = xbench.Helper(opts.chrome_helper_cache)
    pages = IdlePages()
    browser = xbench.ChromiumBrowser("chrome", bundle, helper, None, extensions=[ublock] if manifest else [])
    profile = os.path.join(out, session, "run")
    try:
        template = os.path.join(work, "template-" + template_key(bundle, version, ublock if manifest else None,
                                                                 chrome_version))
        built = build_template(browser, template, opts.chrome_template_settle)
        xbench.clone(template, profile)
        browser.launch(profile, None)
        browser.ready()
        # DevTools answers before the startup browser opens its first tab (the handler starts in
        # PreMainMessageLoopRun, StartupBrowserCreator opens the window after it): wait for that tab, then every
        # page that is not one of the session's closes, as xbench's adopt_first does.
        wait_for(lambda: browser.pages(), 30, "no startup page target")
        # The session's own plan and pages, in its order; each new tab is selected, so the last one is shown.
        plan = tab_plan(pages, spec["tabs"])
        urls = [url for _engine, url, _key in plan]
        for _engine, url, key in plan:
            browser.new_tab(url, key)
            if not pages.wait_loaded(key, 90):
                raise SessionShapeError(f"{session}: tab {url} did not load in 90 s")
        for target in browser.pages():
            if target.get("url") not in urls:
                browser.close(target["id"])
        browser.activate(browser.tabs[-1])
        settle = settle_seconds(session, opts.settle, spec["tabs"])
        time.sleep(settle)  # bench: the pages settle and hidden tabs pass Chrome's background throttling
        states_before = pages.page_states()[0]
        # As measure: PowerWindow's subprocesses before `first` and after `last`, its libproc reads around the sleep.
        window = (power_attribution.PowerWindow(browser.instance.pid, browser.instance.pids, chrome_kind)
                  if spec.get("power") else None)
        if window:
            window.prepare()
        first = snapshot(browser.instance.pids())
        gpu0 = procs.gpu_ns_by_pid()
        if window:
            window.begin()
        began = time.monotonic()
        time.sleep(opts.measure)  # bench: the idle window itself (nothing is sent to Chrome in it)
        elapsed = time.monotonic() - began
        if window:
            window.end()
        gpu1 = procs.gpu_ns_by_pid()
        last = snapshot(browser.instance.pids())
        power = window.finish() if window else None
        targets = browser.extension_targets()
        page_targets = len(browser.pages())
        result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, gpu0, gpu1, chrome_kind)}
        if power is not None:
            # Named while the browser still runs: a stack sample of each process with an unnamed owner over the floor.
            result["power"] = name_power_owners(power_attribution.attribute(power), opts.sample, os.path.join(out, session))
        visibility = dict(pages.visibility)
        states_after, probes = pages.page_states()
        running = any(t.get("url", "").startswith(f"chrome-extension://{UBLOCK_ID}/") for t in targets)
        chrome = {"app": bundle, "bundle_id": bundle_id, "version": version, "build": info.get("CFBundleVersion"),
                  "switches": browser.switches(), "settle_s": settle, "template_built": built,
                  "pages": {"tabs": len(urls), "page_targets": page_targets, "shown": 1,
                            "set": "tabs-static" if session == CHROME_SESSION else session,
                            "loaded": len(pages.loaded), "visibility": visibility},
                  "ublock": {"cmux_version": manifest_version(cmux_ublock), "chrome_version": chrome_version,
                             "running": running},
                  "unequal": chrome_shape_unequal(page_targets, visibility, [key for _engine, _url, key in plan]),
                  "extension_targets": [target.get("url", "")[:120] for target in targets],
                  # D17's reference: Chrome's own tabs (every one a Chromium tab), reported.
                  "visibility": visibility_report(spec, spec["tabs"], states_before, states_after, probes)}
        return {"chrome": chrome, "result": result}
    finally:
        browser.quit()
        pages.close()
        shutil.rmtree(profile, ignore_errors=True)  # the keyed template stays for a rerun into `out`


def chrome_static_entry(opts, out, session, markdown):
    """Runs a reference session (run_chrome_static) and prints its rows; a failure is recorded as a cmux session's
    failure is."""
    try:
        entry = run_chrome_static(opts, out, session)
        entry["kinds"] = aggregate(entry["result"])
        entry["over"] = []
        entry["exit"] = 0
        for name, values in entry["kinds"].items():
            print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
        print("IDLE-BUDGET-CHROME " + json.dumps({k: v for k, v in entry["chrome"].items() if k not in ("switches", "visibility")}),
              flush=True)
        print(f"IDLE-BUDGET-VISIBILITY {session} " + visibility_line(entry["chrome"]["visibility"]), flush=True)
        if entry["result"].get("power"):
            entry["power"] = entry["result"]["power"]
            for line in power_attribution.report_lines(session, entry["power"]):
                print(line, flush=True)
        markdown.append(table(session, entry["kinds"], []) + power_table(entry.get("power")))
    except Exception as error:  # noqa: BLE001 - as a cmux session's failure: recorded, the others still run
        entry = {"exit": 1, "error": f"{type(error).__name__}: {error}"[:500]}
        print(f"IDLE-BUDGET-SESSION-FAILED {session} exit=1 {entry['error'][:300]}", flush=True)
        markdown.append(f"\n### {session}\n\nnot measured: {entry['error'][:300]}")
    return entry


def name_power_owners(power, sample_seconds, folder, samples=None, sampler=None):
    """Names the unnamed thread owners at or above the floor from one stack sample of each process that has one
    (`samples`: {pid: text} already taken, as the app's after its window; `sampler` defaults to /usr/bin/sample);
    returns `power`. No new sample with `sample_seconds` 0. The process with the most unnamed thread mW goes
    first, and sampling stops once no `unnamed threads` owner at or above the floor is left."""
    sampler = sampler or power_attribution.sample_text
    tried = set()
    while True:
        weight = {}
        for entry in power_attribution.unnamed(power["owners"]):
            for thread in entry.get("threads") or []:
                if thread["pid"] not in tried:
                    weight[thread["pid"]] = weight.get(thread["pid"], 0.0) + thread["mw"]
        if not weight:
            return power
        pid = max(sorted(weight), key=weight.get)
        tried.add(pid)
        text = (samples or {}).get(pid)
        if text is None and sample_seconds:
            os.makedirs(folder, exist_ok=True)
            text = sampler(pid, sample_seconds, os.path.join(folder, f"sample-power-{pid}.txt"))
        if text:
            power_attribution.name_threads(power["owners"], pid, power_attribution.sample_labels(text))


def power_table(power, floor=power_attribution.FLOOR_MW):
    """The session's power owners under its process table (empty without `power`)."""
    if not power:
        return ""
    got = power["breakdown"]
    lines = [f"\n\npower owners: sum {got['sum_mw']} mW of {got['total_mw']} mW measured (ratio {got['ratio']}, "
             f"within {power_attribution.TOLERANCE:.0%}: {got['within']}); WindowServer {power['window_server']}\n",
             "| owner | mW | named |", "|---|---|---|"]
    lines += [f"| {e['owner']} | {e['mw']} | {'yes' if e['named'] else '**no**'} |" for e in power["owners"]
              if abs(e["mw"]) >= floor]
    return "\n".join(lines)


def power_overs(report):
    """POWER-OVER rows (power_attribution.power_over) of power-visible against chrome-power-visible, when both have
    an attributed window; None when either is missing (nothing to compare)."""
    sessions = report["sessions"]
    mine = (sessions.get(POWER_SESSION) or {}).get("power")
    reference = (sessions.get(CHROME_POWER_SESSION) or {}).get("power")
    if not mine or not reference:
        return None
    return power_attribution.power_over(mine["owners"], reference["owners"])


def chrome_reference(report):
    """The chrome-static block with its kinds, or None when it was not measured."""
    entry = report["sessions"].get(CHROME_SESSION) or {}
    return {**entry["chrome"], "kinds": entry["kinds"]} if entry.get("kinds") and entry.get("chrome") else None


def minimize(app):
    """Minimizes the launch window (action minimizeWindow) and waits until debug.window_list reports it so."""
    run_action(app, "minimizeWindow")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        main = window_state(app).get("main") or []
        if main and all(w.get("miniaturized") for w in main):
            return {"miniaturized": len(main)}
        time.sleep(0.2)  # bench: bounded wait for the window to reach the Dock
    raise SessionShapeError(f"the window is not minimized after 10 s: {window_state(app)}")


def wait_occluded(app, seconds=10, inactive=False, what="the cover"):
    """Waits until debug.window_list reports every main window occluded and, with `inactive`, no window of the app
    key (the app resigned active, as under another app's window); returns the window state, or raises
    SessionShapeError with the last one."""
    deadline = time.monotonic() + seconds
    while True:
        state = window_state(app)
        main = state.get("main") or []
        if main and all(w.get("occluded") for w in main) and not (inactive and state.get("any_key") is not False):
            return state
        if time.monotonic() >= deadline:
            wanted = "occluded and inactive" if inactive else "occluded"
            raise SessionShapeError(f"the app's windows are not {wanted} {seconds:g} s after {what}: {state}")
        time.sleep(0.2)  # bench: bounded wait for the window server's occlusion change to reach the app


def start_cover(helper_path, seconds=10):
    """Starts `benchhelper cover` and returns its process once it says its window is shown; raises SessionShapeError
    (the process ended) when it does not within `seconds`."""
    cover = subprocess.Popen([helper_path, "cover"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([cover.stdout], [], [], seconds)
    line = cover.stdout.readline().strip() if ready else ""
    if not line.startswith("covering "):
        errors = stop_process(cover)
        raise SessionShapeError(f"benchhelper cover showed no window in {seconds:g} s: {(line or errors)[:200]}")
    return cover


def stop_process(process, seconds=10):
    """Ends a process this script started (TERM, then KILL) and closes its pipes; returns what it wrote to stderr,
    or why it could not be ended. Never raises."""
    try:
        if process.poll() is None:
            process.terminate()
        try:
            _out, errors = process.communicate(timeout=seconds)
        except subprocess.TimeoutExpired:
            process.kill()
            _out, errors = process.communicate(timeout=seconds)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return f"pid {process.pid} not ended: {type(error).__name__}: {error}"[:200]
    return (errors or "").strip()


def command_error(run, argv):
    """Runs `argv` through `run` (subprocess.run's signature); returns "" or the error. Never raises."""
    try:
        done = run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        return f"{argv[0]}: {error}"[:200]
    return "" if done.returncode == 0 else f"{argv[0]} exit {done.returncode}: {(done.stderr or '').strip()[:200]}"


def sleep_display(run=subprocess.run):
    """`pmset displaysleepnow` (no root needed); returns "" or the error."""
    return command_error(run, ["pmset", "displaysleepnow"])


def wake_display(run=subprocess.run):
    """Wakes the display as user activity does (`caffeinate -u`: a 2 s user-active assertion); returns "" or the
    error."""
    return command_error(run, ["caffeinate", "-u", "-t", "2"])


def sign_in_refusal(build_config):
    """Why the signed-in sessions cannot run on this build, or None: the app signs a test account in from the fleet
    secrets only in a Debug build (CloudAuth: a release build never reads them)."""
    if build_config != "debug":
        return (f"a {build_config} build signs no test account in (CloudAuth's dev sign-in runs in a Debug build "
                "only); measure the signed-in sessions on a Debug build")
    return None


def unjudged_on_debug(session, entry, build_config):
    """A signed-in session's own rows on a Debug build (the only build that signs a test account in) are reported,
    not judged: a Debug build is not the code users run. Its overs move into `not_judged`; returns the new notes.
    Its `relative` rows compare two sessions of the same build and are still judged (cross_overs)."""
    if not SESSIONS[session].get("sign_in") or build_config != "debug":
        return []
    overs, entry["over"] = entry.get("over") or [], []
    notes = [f"{session}: own rows not judged on a Debug build (not the code users run)"]
    notes += [f"{session} {over[0]} {over[1]}: {over[2]} over {over[3]} on a Debug build" for over in overs]
    entry.setdefault("not_judged", []).extend(notes)
    return notes


def signed_in_state(reply, account=None):
    """auth.status reduced to what the report keeps: signed in, still restoring, the backend and, with `account`,
    whether the account is the test account. The email itself is never kept."""
    reply = reply if isinstance(reply, dict) else {}
    state = {"signed_in": reply.get("signed_in") is True, "restoring": reply.get("restoring") is True,
             "backend": reply.get("backend")}
    if account is not None:
        email = reply.get("email") if isinstance(reply.get("email"), str) else ""
        state["account_matches"] = bool(email) and email.lower() == account.lower()
    return state


def wait_signed_in(app, account, seconds=SIGN_IN_WAIT_S):
    """Waits until auth.status reports `account` signed in (not restoring); returns signed_in_state, or raises
    SessionShapeError."""
    deadline = time.monotonic() + seconds
    while True:
        state = signed_in_state(read_rpc(app, "auth.status"), account)
        if state["signed_in"] and not state["restoring"]:
            if not state["account_matches"]:
                raise SessionShapeError(f"another account than the test account is signed in: {state}")
            return state
        if time.monotonic() >= deadline:
            raise SessionShapeError(f"the test account is not signed in {seconds:g} s after the launch: {state}")
        time.sleep(0.5)  # bench: bounded wait for the app's own sign-in


def wait_auth_settled(app, seconds=RESTORE_WAIT_S):
    """auth.status (signed_in_state, no account) once the app's restore of a stored sign-in ended, or the last
    state after `seconds`."""
    deadline = time.monotonic() + seconds
    while True:
        state = signed_in_state(read_rpc(app, "auth.status"))
        if not state["restoring"] or time.monotonic() >= deadline:
            return state
        time.sleep(0.5)  # bench: bounded wait for the app's own restore


def sign_out(app, seconds=SIGN_OUT_WAIT_S):
    """Ends the app's Cloud session (debug.cloud.end_session: CloudAuth.signOut, which clears the stored tokens and
    `cmux.auth.hasTokens`; the tokens live in the data protection Keychain, which only the app reaches) and waits
    until auth.status reports it signed out. Returns {"signed_out": bool, "error": str}."""
    reply = read_rpc(app, "debug.cloud.end_session")
    deadline = time.monotonic() + seconds
    while True:
        state = signed_in_state(read_rpc(app, "auth.status"))
        if not state["signed_in"] and not state["restoring"]:
            return {"signed_out": True, "error": ""}
        if time.monotonic() >= deadline:
            return {"signed_out": False,
                    "error": f"still signed in {seconds:g} s after debug.cloud.end_session: {json.dumps(reply)[:200]}"}
        time.sleep(0.5)  # bench: bounded wait for the app's own sign-out


class QuitTree:
    """app-quit's process set once the app is gone: the tag's processes (TagTeardown: daemon, holders, terminal
    hosts, acpmux and their children, by bundle path), as procs.Instance.pids gives them for a running app. `pid`
    stays the app's (its coalition reads as unknown)."""

    def __init__(self, teardown, pid):
        self.teardown = teardown
        self.pid = pid

        self.harness = {}  # the last pids() read's agent harness processes: {pid: host pid}, as procs.Instance's

    def pids(self, table=None):
        """{pid: command} of the tag's processes (TagTeardown reads its own table) and the agent harnesses under one
        of them (from `table`, procs.process_table rows, read now when None), as procs.Instance.pids."""
        found = dict(self.teardown.processes())
        table = procs.process_table() if table is None else table
        commands = {pid: cmd for pid, _ppid, cmd in table}
        self.harness = {pid: host for pid, host in procs.agent_harness_pids(table).items()
                        if host in found and pid in commands}
        found.update({pid: commands[pid] for pid in self.harness})
        return found


# external-churn's fixtures: a Chrome profile's History database and its import record with Keep in Sync on.
CHURN_PROFILE_ID = "6d3c6a4e-0b55-4e7b-9a0c-1d2e3f405162"  # a browser profile id (lowercase UUID) for the import
CHROME_EPOCH_OFFSET_S = 11644473600  # Chromium's base::Time counts microseconds from 1601-01-01
# components/history/core/browser/url_database.cc CreateURLTable: the columns ChromiumHistoryReader reads.
CHROME_URLS_TABLE = ("CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, "
                     "visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, "
                     "last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)")


def chrome_time(unix_s):
    """Chromium's stored time (microseconds since 1601-01-01) of a Unix time."""
    return int((unix_s + CHROME_EPOCH_OFFSET_S) * 1_000_000)


def make_chrome_history(path, visits=20, now=None):
    """A Chrome `History` database at `path` with `visits` pages, as a profile that has browsed."""
    now = time.time() if now is None else now
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.execute(CHROME_URLS_TABLE)
        db.executemany("INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES (?, ?, 1, ?)",
                       [(f"https://example.com/page/{n}", f"Page {n}", chrome_time(now - 60 * (visits - n)))
                        for n in range(visits)])
    return path


def append_chrome_visit(path, n, now=None):
    """One visit appended to the History database as Chrome writes it: a committed row, with SQLite's rollback
    journal (`History-journal`) made and removed by the commit, which is what Keep in Sync's folder watch sees."""
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.execute("INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES (?, ?, 1, ?)",
                   (f"https://example.com/churn/{n}", f"Churn {n}", chrome_time(time.time() if now is None else now)))


def keep_in_sync_store(history, now=None):
    """{relative path: JSON} of an import store (ImportedDataStore) holding one Chrome profile imported with Keep in
    Sync on: `sources.json` (the ImportSourceRecord list, `syncedHistoryFile` the History file URL) and the source's
    batch (`<profile>/<source key>.json`, history kind, no pages yet: the first read fills them)."""
    record = {"browser": "chrome", "profileDirectory": "Default", "displayName": "Google Chrome",
              "proposedProfileID": CHURN_PROFILE_ID, "targetProfileID": CHURN_PROFILE_ID, "profileName": "Person 1",
              "syncedHistoryFile": Path(history).resolve().as_uri()}
    batch = {"source": record, "bookmarks": [], "history": [], "openTabs": [], "extensions": [], "kinds": ["history"],
             "importedAt": round(time.time() if now is None else now, 3)}
    return {"sources.json": [record], f"{CHURN_PROFILE_ID}/chrome_Default.json": batch}


def import_store_dir(app):
    """The tag's browser import store (OnboardingService: Application Support/<bundle id>/BrowserImport), or None when
    the bundle is not a tagged DEV bundle (its store is a person's own)."""
    import bench_launch
    ident = bench_launch.bundle_id(app)
    if not ident or not ident.startswith("com.cmuxterm.app.debug."):
        return None
    return os.path.join(os.path.expanduser("~"), "Library/Application Support", ident, "BrowserImport")


class SeededStore:
    """Writes keep_in_sync_store into the tag's import store for one session and restores the store after: an
    earlier store moves aside (`<dir>.bench-prev`) and comes back at `restore`."""

    def __init__(self, directory, files):
        self.directory = directory
        self.files = files
        self.aside = directory + ".bench-prev"
        self.moved = False

    def write(self):
        if os.path.lexists(self.directory):
            if os.path.lexists(self.aside):
                raise SessionShapeError(f"{self.aside} is left from an earlier run: restore or remove it first")
            os.rename(self.directory, self.aside)
            self.moved = True
        for relative, value in self.files.items():
            path = os.path.join(self.directory, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                json.dump(value, handle, sort_keys=True)
        return self

    def restore(self):
        """Removes the seeded store and moves the earlier one back; returns "" or why it could not (the earlier
        store then stays at `aside`, and the next write refuses to run over it). Never raises."""
        shutil.rmtree(self.directory, ignore_errors=True)
        if not self.moved:
            return ""
        try:
            os.rename(self.aside, self.directory)
        except OSError as error:
            return f"the earlier store stays at {self.aside}: {error.strerror or error}"
        self.moved = False
        return ""


def make_project(folder):
    """A git project with one file at `folder` (the external-churn writes go to its `churn.log`)."""
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "README.md"), "w") as handle:
        handle.write("idle-budget external-churn project\n")
    subprocess.run(["git", "init", "-q", folder], check=True, capture_output=True, timeout=30)
    return folder


class ExternalChurn:
    """Other apps' writes while cmux sits hidden: `writes_per_s` appends a second to the watched project's
    `churn.log`, and every `history_period_s` one visit appended to the Chrome History fixture. Each step has its own
    deadline from the start (no drift); a thread runs them through the settle and the window."""

    def __init__(self, project, history, writes_per_s=CHURN_WRITES_PER_S, history_period_s=HISTORY_PERIOD_S):
        self.file = os.path.join(project, "churn.log")
        self.history = history
        self.writes_per_s = writes_per_s
        self.history_every = max(1, round(writes_per_s * history_period_s))
        self.writes = self.visits = 0
        self.error = None
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.run, name="external-churn", daemon=True)

    def step(self, n):
        """Write number `n`: one line into the project; every `history_every`th also one History visit."""
        with open(self.file, "a") as handle:
            handle.write(f"{n} {time.time():.3f}\n")
        self.writes += 1
        if n % self.history_every == 0:
            append_chrome_visit(self.history, n)
            self.visits += 1

    def run(self):
        began = time.monotonic()
        n = 0
        # bench: each write waits for its own deadline; stop() ends the wait at once
        while not self.stopped.wait(max(0.0, began + n / self.writes_per_s - time.monotonic())):
            try:
                self.step(n)
            except (OSError, sqlite3.Error) as error:  # the counts show where the churn stopped
                self.error = f"{type(error).__name__}: {error}"[:200]
                return
            n += 1

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        """Stops the writes; returns their counts."""
        self.stopped.set()
        self.thread.join(10)
        return {"writes": self.writes, "history_visits": self.visits, "error": self.error}


class SessionRig:
    """What a session builds around the app and takes down after it: the launch env of the signed-in account,
    the fixtures made before the launch (external-churn's project, Chrome History and import store; the cover's
    helper, compiled before the app runs), the shape made after the launch and after the activation (the sign-in,
    or the check that the app runs signed out; the terminal in the project, Home, the cover, the display sleep, the
    churn), and their teardown (`teardown`). `shape` is what it built, for the report; it never holds a secret.
    `run` runs pmset and caffeinate (subprocess.run's signature)."""

    def __init__(self, session, build_config, credentials=None, helper_cache=None, run=subprocess.run):
        self.spec = SESSIONS[session]
        self.build_config = build_config
        self.credentials = credentials
        self.helper_cache = helper_cache
        self.run = run
        self.account = self.helper = self.cover = self.churn = self.store = self.scratch = None
        self.project = self.history = None
        self.display_slept = False
        self.shape = {}

    def env(self, base):
        """The launch env: `base`, plus the agent account's sign-in for a signed-in session (SessionShapeError on a
        build that signs no test account in, or a credentials file the app would not read or that signs another
        account in)."""
        if not self.spec.get("sign_in"):
            return base
        refusal = sign_in_refusal(self.build_config)
        if refusal:
            raise SessionShapeError(refusal)
        import bench_launch
        try:
            extra = bench_launch.agent_sign_in_env(self.credentials or bench_launch.AGENT_CREDENTIALS)
        except bench_launch.CredentialsError as error:
            raise SessionShapeError(f"signed-in: {error}") from None
        self.account = extra["CMUX_DEV_AUTH_ACCOUNT"]
        return {**base, **extra}

    def before_launch(self, app_path):
        if self.spec.get("cover"):
            import xbench  # scripts/perf-bench (on sys.path): benchhelper, compiled once per source hash
            self.helper = xbench.Helper(self.helper_cache).path
        if not self.spec.get("churn"):
            return
        store = import_store_dir(app_path)
        if store is None:
            raise SessionShapeError("external-churn seeds only a tagged DEV bundle's import store")
        import tempfile
        self.scratch = tempfile.mkdtemp(prefix="idle-budget-churn-")
        self.project = make_project(os.path.join(self.scratch, "project"))
        profile = os.path.join(self.scratch, "Chrome", "Default")
        os.makedirs(profile)
        self.history = make_chrome_history(os.path.join(profile, "History"))
        self.store = SeededStore(store, keep_in_sync_store(self.history)).write()
        self.shape["keep_in_sync"] = {"store": store, "history": self.history}

    def after_launch(self, app):
        """The sign-in of a signed-in session. Any other session runs signed out: a sign-in the app restored (one an
        earlier run did not end) is ended in the app (`left_signed_in`), or the session is refused. `signed_in`
        records which it ran as."""
        if self.account:
            self.shape["sign_in"] = wait_signed_in(app, self.account)
            self.shape["signed_in"] = True
        else:
            state = wait_auth_settled(app)
            if state["signed_in"]:
                ended = self.shape["left_signed_in"] = sign_out(app)
                if not ended["signed_out"]:
                    raise SessionShapeError(f"the app restored a stored sign-in and did not sign out: {ended['error']}")
            self.shape["signed_in"] = False
        if self.project:
            run_action(app, "terminal.sendText", {"text": f"cd {shlex.quote(self.project)} && clear\n"})
            self.shape["project"] = self.project

    def after_activate(self, app):
        """After the activation and any hide or minimize: Home; the cover, until the app is occluded and no longer
        active (another app's window in front); the display sleep, until the app is occluded; then the churn (it
        runs through the settle and the window)."""
        if self.spec.get("home"):
            run_action(app, "home.show")
            self.shape["home"] = True
        if self.helper:
            self.cover = start_cover(self.helper)
            self.shape["cover"] = wait_occluded(app, inactive=True)
        if self.spec.get("display_sleep"):
            error = sleep_display(self.run)
            if error:
                raise SessionShapeError(f"the display did not sleep: {error}")
            self.display_slept = True
            self.shape["display_sleep"] = wait_occluded(app, 15, what="pmset displaysleepnow")
        if self.project:
            self.churn = ExternalChurn(self.project, self.history).start()

    def after_window(self):
        """Stops the churn at the window's end; its counts go into `shape`."""
        if self.churn is not None and "churn" not in self.shape:
            self.shape["churn"] = self.churn.stop()
        return self.shape

    def teardown(self, app, stop=None):
        """Takes the session down in this order: the churn's writes stop; a signed-in app signs out while it still
        runs (`shape.sign_out`); the app stops (`stop`, default `app.stop`); then the cover ends, the display wakes, the import store
        comes back and the scratch folder goes. Every step runs whatever an earlier one raised; returns the steps'
        errors."""
        errors = []

        def step(name, work):
            try:
                problem = work()
            except Exception as error:  # noqa: BLE001 - recorded; the later steps still run
                problem = f"{type(error).__name__}: {error}"
            if problem:
                errors.append(f"{name}: {problem}"[:300])

        step("churn", lambda: self.after_window() and None)  # its counts (and a write error) go into `shape`
        if app is not None:
            process = getattr(app, "process", None)
            if self.account and process is not None and process.poll() is None:
                step("sign-out", lambda: self.sign_out(app))
            step("app", stop or app.stop)
        if self.cover is not None:
            step("cover", self.stop_cover)
        if self.display_slept:
            step("display", lambda: wake_display(self.run))
        if self.store is not None:
            step("store", self.store.restore)
        if self.scratch:
            step("scratch", lambda: shutil.rmtree(self.scratch, ignore_errors=True))
        return errors

    def stop_cover(self):
        stop_process(self.cover)
        return f"benchhelper cover pid {self.cover.pid} still runs" if self.cover.poll() is None else None

    def sign_out(self, app):
        self.shape["sign_out"] = sign_out(app, SIGN_OUT_WAIT_S)
        return self.shape["sign_out"]["error"]


def bundle_build_config(app):
    """The bundle's build config as bench_launch reads it: `debug`, `bench-hooks` or `release`."""
    import bench_launch
    app = os.path.realpath(app).rstrip("/")
    return bench_launch.bundle_kind(app, bench_launch.main_binary(app))


def gate_refusal(build_config, gate, shipping_draw="on"):
    """Why this run is refused before any launch, or None: under `--gate` a Debug build is not the code or the draw
    users run; `--shipping-draw off` on another build would measure the same draw twice (only a Debug automation
    launch draws occluded windows, WindowDrawPolicy.drawsOccludedWindows)."""
    if gate and build_config == "debug":
        return ("--gate refuses a Debug build: measure a Release build with CMUX_BENCH_HOOKS "
                "(its code, occlusion draw and Sentry are what users run)")
    if shipping_draw == "off" and build_config != "debug":
        return (f"--shipping-draw off has no effect on a {build_config} build: only a Debug build draws occluded "
                "windows in an automation launch, so the on/off comparison is a Debug-only diagnostic")
    return None


def launch_env(shipping_draw=True):
    """BenchApp's `env` of every cmux session: the shipping measurement mode (bench_launch.shipping_env)."""
    import bench_launch
    return bench_launch.shipping_env(draw=shipping_draw)


def predicted_draws_when_occluded(build_config, env):
    """What WindowDrawPolicy.drawsOccludedWindows should say for this build and launch env: only a Debug build
    draws occluded windows, in an automation launch without CMUX_NEXT_BENCH_SHIPPING_DRAW=1. Only a cross-check of
    the app's own answer (debug.shipping_mode), never the recorded value."""
    if build_config != "debug" or env.get("CMUX_NEXT_BENCH_SHIPPING_DRAW") == "1":
        return False
    return env.get("CMUX_NEXT_NO_ACTIVATE") == "1" or env.get("CMUX_NEXT_SOCKET_MODE") == "automation"


SENTRY_THREAD_PREFIX = "SentryCrash"  # Sentry's Mach exception handler threads (crash-ends-app-gate.py PRIMARY)
SHIPPING_FIELDS = ("build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated")


def shipping_fields(build_config, env, thread_names, mode, activation):
    """The five shipping-mode fields of a session, read from the app: `mode` is its debug.shipping_mode reply ({}
    when it did not answer: every value unknown). draws_when_occluded is the app's answer (null when unknown) with
    the launch env's prediction beside it."""
    mode = mode or {}
    hang = mode.get("hang_reports") if isinstance(mode.get("hang_reports"), dict) else {}
    draws = mode.get("draws_when_occluded")
    pages = mode.get("pages_render_when_covered")
    return {
        "build_config": build_config,
        "sentry_started": any(name.startswith(SENTRY_THREAD_PREFIX) for name in thread_names),
        "hang_reports": {"available": hang.get("available"), "setting": hang.get("setting"),
                         "decision": hang.get("decision"), "enabled": hang.get("enabled"),
                         "on": hang.get("available") is True and hang.get("enabled") is True},
        "draws_when_occluded": {"windows": draws if isinstance(draws, bool) else None,
                                "pages": pages if isinstance(pages, bool) else None,
                                "predicted": predicted_draws_when_occluded(build_config, env)},
        "activated": dict(activation),
    }


def draw_mismatch(fields):
    """A line when the app's draw answer differs from the launch env's prediction (the Swift rule changed, or a
    key the prediction does not know), else None. An unknown answer is no mismatch; the record shows it as null."""
    draw = fields["draws_when_occluded"]
    wrong = {name: draw[name] for name in ("windows", "pages")
             if draw[name] is not None and draw[name] != draw["predicted"]}
    if not wrong:
        return None
    return (f"the app says {', '.join(f'{name} draw occluded={value}' for name, value in wrong.items())}, "
            f"the launch env predicts {draw['predicted']}")


def shipping_refusals(entry):
    """[(what, why)] for a session that did not run the shipping configuration it is judged as: not activated,
    Sentry not started, hang reports not on (not available, setting off, no consent, or not enabled)."""
    out = []
    activated = entry.get("activated") or {}
    if activated.get("activated") is not True:
        out.append(("activated", f"the app was not activated: {activated.get('error') or 'not recorded'}"))
    if entry.get("sentry_started") is not True:
        out.append(("sentry", "no SentryCrash thread runs in the app (CMUX_NEXT_DEV_SENTRY=1 not honored, or "
                              "telemetry off)"))
    hang = entry.get("hang_reports") or {}
    if hang.get("on") is not True:
        out.append(("hang_reports", "hang reports do not run: " + json.dumps(
            {key: hang.get(key) for key in ("available", "setting", "decision", "enabled")})))
    return out


def fresh_session(app):
    """Starts the session from empty: ends the tag's leftover daemons (TagTeardown: exact PIDs of this app
    bundle) and removes the tag's saved terminal session, as bench_pane_scale.py does. A bench host's tag
    (split-spring) is shared, and its saved session restored 509 terminals into a "light" run (cmux20,
    2026-10-24). Returns what it removed."""
    if app.teardown:
        app.teardown.end()
        app.teardown.done = False
    state = os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", app.tag, "tui")
    existed = os.path.isdir(state)
    shutil.rmtree(state, ignore_errors=True)
    return {"tui_state_removed": existed}


def host_facts():
    display = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return {"host": platform.node(), "macos": platform.mac_ver()[0], "chip": subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
        "load": os.getloadavg(), "display": [l.strip() for l in display.splitlines() if "Refresh" in l or "Resolution" in l][:4]}


def table(session, kinds, overs, entry=None):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n"]
    if entry:
        saver, thermal, energy = entry["saver"], entry["thermal"], entry["energy_mw"]["tree"]
        lines.append(f"energy {energy['cpu']} mW CPU, {energy['billed']} mW billed (tree); saver asked {saver['asked']}, "
                     f"observed {saver['observed']}{' REFUSED' if saver['mismatch'] else ''}; thermal {thermal['worst']}"
                     f"{' (marked)' if thermal['marked'] else ''}; {len(entry['assertions'])} power assertion(s)"
                     + (f"; page rAF {entry['anim']}" if "anim" in entry else "")
                     + (f"; D17 visibility met={entry['visibility']['met']} wrong={sorted(entry['visibility']['wrong'])}"
                        if "visibility" in entry else "") + "\n")
    lines += ["| process | n | threads (max) | wakeups/s (max) | pkg-idle wakeups/s | main wakes/s | "
              "CPU mW | billed mW | GPU ms/s | csw/s | CPU % | threads that ran | disk B/s | net bytes (conns) | "
              "log lines | roles |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        d15 = lambda f: "-" if e.get(f) is None else mark(f, e[f])  # noqa: E731  (absent or unknown)
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{e['pkg_idle_wakeups_per_s']} | {mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | "
                     f"{mark('energy_mw_cpu', e['energy_mw_cpu'])} | {mark('energy_mw_billed', e['energy_mw_billed'])} | "
                     f"{mark('gpu_ms_per_s', '-' if e['gpu_ms_per_s'] is None else e['gpu_ms_per_s'])} | "
                     f"{e['csw_per_s']} | {e['cpu_pct']} | {e['threads_ran']} | {d15('disk_bytes_per_s')} | "
                     f"{d15('network_bytes')} ({d15('connections')}) | {d15('log_lines')} | "
                     f"{mark('role', ', '.join(e.get('roles') or []) or '-')} |")
    server = (entry or {}).get("windowserver")
    if server:
        lines.append(f"\nWindowServer ({server['source']}, reported): {server['wakeups_per_s']}/s, "
                     f"{server['hidden_reference_per_s']}/s with cmux hidden ({server['reference']}), "
                     f"delta {server['delta_per_s']}/s")
    return "\n".join(lines)


def windowserver_with_reference(app, server, spec, seconds, entry):
    """The window's WindowServer report with its reference: a hidden session is its own (`self`); another session
    hides cmux for `seconds` after its window and samples (the hide's reply in entry["windowserver_hide"]; a hide that
    is not confirmed is reference `hide-failed`, no delta); 0 seconds: no reference."""
    rate, source = server["wakeups_per_s"], server["source"]
    if spec.get("hide"):
        return windowserver_report(rate, rate, source, reference="self")
    if seconds <= 0:
        return windowserver_report(rate, None, source, reference="none")
    reference_rate, entry["windowserver_hide"], reference = windowserver_reference(app, seconds)
    return windowserver_report(rate, reference_rate, source, reference=reference)


def coalition_line(coalition):
    """The app's resource coalition under the session's table (None: it could not be read)."""
    if coalition is None:
        return "app coalition: not readable"
    return (f"app coalition: {coalition['wakeups_per_s']} wakeups/s ({coalition['pkg_idle_wakeups_per_s']} pkg-idle), "
            f"{coalition['energy_mw_cpu']} mW CPU, {coalition['energy_mw_billed']} mW billed, "
            f"{coalition['gpu_ms_per_s']} GPU ms/s, {coalition['cpu_pct']} % CPU")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help='a tagged "cmux DEV <tag>.app" (not running)')
    parser.add_argument("--xbench", metavar="RESULTS_JSON",
                        help="judge an xbench.py results.json against the budget's xbench rows (D6) and exit; no --app")
    parser.add_argument("--tag", help="ignored (split-spring passes it); the tag comes from the app")
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--budget", default=BUDGET_FILE)
    parser.add_argument("--gate", action="store_true",
                        help="exit 1 when a value is over its budget, a session's saver state is not the one it asked "
                        "for, or chrome-static failed or is no equal reference; exit 2 at once on a Debug build")
    parser.add_argument("--shipping-draw", choices=("on", "off"), default="on",
                        help="off: keep the automation draw of occluded windows, to compare with the shipping draw "
                        "(a Debug build only: refused on another build, which has no such draw)")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    parser.add_argument("--windowserver-reference", type=float, default=None,
                        help="seconds of the WindowServer reference window with cmux hidden, after the window and its "
                        "samples (default: --measure; 0: none; a hidden session is its own reference)")
    parser.add_argument("--visibility-tab", action="store_true",
                        help="D17: open one shown Chromium probe tab in light, light-hidden, minimized and occluded, so "
                        "the visible tab of a hidden, minimized or covered window reports its visibility (changes "
                        "those sessions' shape)")
    parser.add_argument("--samples", type=int, default=None,
                        help="how many --sample runs to take and add (default: 3 in a hidden-wake session, else 1)")
    parser.add_argument("--wake-trace", type=float, default=30,
                        help="seconds of DTrace wake trace of the main thread right after the window and before the "
                             "samples, in a hidden-wake session (0: none)")
    parser.add_argument("--chrome-app", default=CHROME_APP,
                        help="the chrome-static browser: a Chromium that runs Manifest V2 (ungoogled-chromium of "
                        "cmux's Chromium major); branded Chrome 137+ and Chrome for Testing 139+ are refused")
    parser.add_argument("--chrome-ublock", default=None,
                        help="the unpacked uBlock Origin chrome-static loads (default: the copy in --app; "
                        "`none`: without it, which marks the Chrome ratios unequal)")
    parser.add_argument("--chrome-template-settle", type=float, default=45,
                        help="seconds the reference browser's template profile runs before its first clone")
    parser.add_argument("--chrome-helper-cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"),
                        help="xbench's benchhelper cache (the chrome-static reference and occluded's cover window)")
    parser.add_argument("--signed-in-credentials", default=None,
                        help="signed-in's 0600 file with the agent test account (CMUX_UITEST_STACK_*; default the fleet "
                        "secrets file ~/.secrets/cmuxterm-dev.env, which the app finds itself; another file is passed "
                        "by path and must hold no CMUX_DOGFOOD_STACK_* pair); the bench passes no secret")
    opts, _unknown = parser.parse_known_args(argv)
    budget = load_budget(opts.budget)
    role_errors = role_budget_errors(budget)
    if role_errors:
        raise SystemExit(f"idle-budget: {opts.budget}: " + "; ".join(role_errors))
    reference_s = opts.measure if opts.windowserver_reference is None else opts.windowserver_reference
    if opts.xbench:
        with open(opts.xbench) as handle:
            overs, notes = xbench_overs(budget, json.load(handle))
        for note in notes:
            print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
        for over in overs:
            print(over_line("xbench", over), flush=True)
        print(f"IDLE-BUDGET over={len(overs)} xbench={opts.xbench}", flush=True)
        sys.exit(1 if opts.gate and overs else 0)
    if not opts.app:
        parser.error("--app is required (or --xbench RESULTS_JSON)")
    sessions = parse_sessions(opts.sessions)
    build_config = bundle_build_config(opts.app)
    refusal = gate_refusal(build_config, opts.gate, opts.shipping_draw)
    if refusal:
        print(f"IDLE-BUDGET-REFUSED build_config={build_config}: {refusal}", flush=True)
        sys.exit(2)
    import bench_launch
    from bench_launch import BenchApp
    env = launch_env(shipping_draw=opts.shipping_draw == "on")
    runs = {}  # story -> the result-v1 run its sessions of this invocation share
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "build_config": build_config, "shipping_draw": opts.shipping_draw,
              "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    refused = []
    markdown = []
    for session in sessions:
        spec = SESSIONS[session]
        if spec.get("chrome"):
            report["sessions"][session] = chrome_static_entry(opts, out, session, markdown)
            continue
        rig = SessionRig(session, build_config, opts.signed_in_credentials, opts.chrome_helper_cache)
        folder = os.path.join(out, session)
        app = agents = None
        tabs = session_tabs(session, opts.visibility_tab)
        pages = IdlePages() if tabs else None
        try:
            sha = build_sha_of(opts.app) if spec.get("hidden_wake") else None  # before the launch: no report without it
            app, agents = session_app(BenchApp, opts.app, out, session, rig.env(env), runs)
            entry = {"fresh_session": fresh_session(app), "shape": rig.shape}  # a failed session keeps its shape too
            report["sessions"][session] = entry
            consent = bench_launch.seed_hang_report_consent(app.app)
            if consent:
                print(f"IDLE-BUDGET-NO-HANG-CONSENT {session}: {consent}", flush=True)
            rig.before_launch(app.app)
            start_session(app, agents, spec, entry)
            rig.after_launch(app)
            if spec.get("stress"):
                entry["stress"] = build_stress(app, static=spec.get("static", False))
            shown_tab = None
            if tabs:
                entry["tabs"], shown_tab = build_tabs(app, pages, tabs)
                entry["shown_tab"] = shown_tab
            activation = app.activate()  # once, before the settle (and before a hide or minimize): users run an active app
            if not activation["activated"]:
                print(f"IDLE-BUDGET-NOT-ACTIVATED {session}: {activation['error']}", flush=True)
            if spec.get("hide"):
                entry["hide"] = hide_all(app)
                check_action_reply("showHideAllWindows", entry["hide"])
            if spec.get("minimize"):
                entry["minimize"] = minimize(app)
            rig.after_activate(app)
            settle = settle_seconds(session, opts.settle, tabs)
            entry["settle_s"] = settle
            time.sleep(settle)  # bench: the session settles (page loads, Chromium's post-load work, the hidden-tab freeze)
            instance = procs.Instance(app.app, app.process.pid)
            names = [name for _cpu, name in threads(app.process.pid).values()]
            entry.update(shipping_fields(build_config, app.launched_env or {}, names,
                                         read_rpc(app, "debug.shipping_mode"), activation))
            print(f"IDLE-BUDGET-MODE {session} " + json.dumps({k: entry[k] for k in SHIPPING_FIELDS}), flush=True)
            mismatch = draw_mismatch(entry)
            if mismatch:
                print(f"IDLE-BUDGET-DRAW-MISMATCH {session}: {mismatch}", flush=True)
            measured_app = app
            if spec.get("quit"):
                quit_state = app.quit_keep_sessions()
                rig.shape["quit"] = quit_state
                if not quit_state["quit"]:
                    raise SessionShapeError(quit_state["error"])
                time.sleep(QUIT_SETTLE_S)  # bench: the daemon's wind-down after its client left, before the window
                instance, measured_app = QuitTree(app.teardown, app.process.pid), None
            window_before = window_state(app) if measured_app else None
            problem = hidden_state_problem(spec, window_before) if spec.get("hidden_wake") else None
            if problem:
                print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps({"start": window_before}), flush=True)
                raise HiddenStateError(f"before the window: {problem}")
            states_before = pages.page_states()[0] if pages else None
            result = measure(measured_app, instance, opts.measure, pages.read_anim if spec.get("anim") else None,
                             attribute=spec.get("power", False) and measured_app is not None, shown_tab=shown_tab,
                             workdir=folder, ledger_limit=None if spec.get("hidden_wake") else 20,
                             hidden_hosts=tuple((entry.get("agents") or {}).get("hidden_hosts") or ()))
            visibility = None
            if pages:
                states_after, probes = pages.page_states()
                visibility = visibility_report(spec, tabs, states_before, states_after, probes)
            if measured_app:
                result["window_state"] = {"start": window_before, "end": window_state(app)}
                print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            entry["shape"] = rig.after_window()
            print(f"IDLE-BUDGET-SHAPE {session} " + json.dumps(entry["shape"]), flush=True)
            problem = hidden_state_problem(spec, result["window_state"]["end"]) if spec.get("hidden_wake") else None
            if problem:
                raise HiddenStateError(f"at the end of the window: {problem}")
            trace = None
            if spec.get("hidden_wake") and opts.wake_trace:
                # Before /usr/bin/sample, which suspends the app again and again: no catch-up work in the trace.
                os.makedirs(folder, exist_ok=True)
                time.sleep(QUIET_GAP_S)  # bench: the end read's reply settles before the trace
                trace = count_main_callouts(app, opts.wake_trace, folder)
                result["window_state"]["after_trace"] = window_state(app)
                problem = hidden_state_problem(spec, result["window_state"]["after_trace"])
                if problem:
                    raise HiddenStateError(f"after the wake trace: {problem}")
            texts = []
            if opts.sample and measured_app:
                os.makedirs(folder, exist_ok=True)
                for index in range(opts.samples or (3 if spec.get("hidden_wake") else 1)):
                    text = run_sample(app.process.pid, opts.sample, os.path.join(folder, f"sample-app-{index + 1}.txt"))
                    if text:
                        texts.append(text)
                result["sample"] = threads_from_sample(texts[0]) if texts else {}
                result["main_callouts"] = main_callouts_from_samples(texts)
            if trace is not None:
                result["wake_trace"] = name_trace(trace, app.process.pid, texts[0] if texts else None)
            if spec.get("reshow") and measured_app:
                # After the window and its samples (input would be counted), before the WindowServer reference hides
                # the app.
                result["reshow"] = reshow_tab(app, result["processes"], result.get("browser_tabs") or {}, shown_tab)
                print(f"IDLE-BUDGET-RESHOW {session} " + json.dumps(result["reshow"]), flush=True)
            if result.get("power"):
                # Named while the app runs: the app's first sample above, and one sample of each other process with an
                # unnamed owner over the floor.
                taken = {app.process.pid: texts[0]} if texts else {}
                name_power_owners(result["power"], opts.sample, folder, samples=taken)
            # After app-quit no app is left to hide for the reference: the window's own rate, no reference.
            result["windowserver"] = windowserver_with_reference(app, result["windowserver"], spec,
                                                                 reference_s if measured_app else 0, entry)
            print(f"IDLE-BUDGET-WINDOWSERVER {session} " + json.dumps(result["windowserver"]), flush=True)
            entry.update(summarize(session, result, budget))
            unjudged_on_debug(session, entry, build_config)
            if visibility is not None:
                entry["visibility"] = visibility
                print(f"IDLE-BUDGET-VISIBILITY {session} " + visibility_line(visibility), flush=True)
            for reader in entry["readers_failed"]:
                print(f"IDLE-BUDGET-READER-FAILED {session} {reader}: not measured", flush=True)
            if result.get("power"):
                entry["power"] = result["power"]
                for line in power_attribution.report_lines(session, entry["power"]):
                    print(line, flush=True)
            if result.get("frame_clients"):
                print(f"IDLE-BUDGET-FRAME-CLIENTS {session} " + json.dumps(result["frame_clients"]), flush=True)
            kinds, overs, notes = entry["kinds"], [tuple(o) for o in entry["over"]], entry["not_judged"]
            for name, values in kinds.items():
                print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
            print(f"IDLE-BUDGET-ENERGY {session} " + json.dumps(entry["energy_mw"]), flush=True)
            for goal in entry.get("goals") or []:
                print(f"IDLE-BUDGET-GOAL {session} " + json.dumps(goal), flush=True)
            print(f"IDLE-BUDGET-STATE {session} " + json.dumps({"saver": entry["saver"], "thermal": entry["thermal"]}), flush=True)
            for item in entry["assertions"]:
                print(f"IDLE-BUDGET-ASSERTION {session} {item['line']}", flush=True)
            if "anim" in entry:
                print(f"IDLE-BUDGET-ANIM {session} " + json.dumps(entry["anim"]), flush=True)
            for row in result["processes"]:
                if unclassified(row["kind"]):
                    print(f"IDLE-BUDGET-UNCLASSIFIED {session} pid {row['pid']} {row['kind']}: {row['command']}", flush=True)
                if row["kind"] in ("app", "daemon", "holder", "acpmux", "agent-harness") and row["ran"]:
                    names = ", ".join(f"{t['name'] or t['tid']}={t['cpu_us']}us" for t in row["ran"])
                    print(f"IDLE-BUDGET-THREADS {session} {row['kind']} pid {row['pid']}: {names}", flush=True)
            if result.get("ledger"):
                print(f"IDLE-BUDGET-LEDGER {session} " + json.dumps(result["ledger"]), flush=True)
            if result.get("app_counter_rates"):
                print(f"IDLE-BUDGET-APP-COUNTERS {session} per s " + json.dumps(result["app_counter_rates"]), flush=True)
            for timer in result.get("main_run_loop_timers") or []:
                if timer["interval_s"] > 0:
                    print(f"IDLE-BUDGET-MAIN-TIMER {session} every {timer['interval_s']:g} s: {timer['callout']}", flush=True)
            for name, sampled in (result.get("sample") or {}).items():
                top = "; ".join(f"{frame} x{count}" for frame, count in sampled["frames"][:6])
                if top:
                    print(f"IDLE-BUDGET-SAMPLE {session} {name}: {top}", flush=True)
            if spec.get("hidden_wake"):
                hidden = hidden_wake_sources(result)
                hidden.update({"sha": sha, "host": machine["host"], "samples_taken": len(texts),
                               "problems": shipping_problems(entry) + hidden["naming_problems"]})
                entry["hidden_wake"] = hidden
                for line in hidden_wake_lines(session, hidden, sha, machine["host"], hidden["problems"]):
                    print(line, flush=True)
            for note in notes:
                print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
            for over in overs:
                if over[1] != "role":
                    print(over_line(session, over, kinds), flush=True)
            for mismatch in entry.get("role_mismatches") or []:
                print(role_over_line(session, mismatch), flush=True)
            reasons = refusals(entry)
            if reasons:
                refused.append(session)
            for what, why in reasons:
                print(f"IDLE-BUDGET-REFUSED {session} {what}: {why}", flush=True)
            if entry["thermal"]["marked"]:
                print(f"IDLE-BUDGET-THERMAL {session} rows taken at {entry['thermal']['worst']}: not comparable", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs, entry) + "\n\n" + coalition_line(result.get("coalition"))
                            + power_table(entry.get("power")))
            print(f"IDLE-BUDGET-COALITION {session} " + json.dumps(result.get("coalition")), flush=True)
            entry["results_v1"] = record_session(app, session, entry, budget)
            entry["exit"] = 0
        except BaseException as error:  # noqa: BLE001 - one session's failure (a STRESS shape refusal, a launch
            # failure) is recorded with its exit code; the other sessions still measure and report.
            code = error.code if isinstance(error, SystemExit) and isinstance(error.code, int) else 1
            report["sessions"].setdefault(session, {}).update({"exit": code or 1, "error": f"{type(error).__name__}: {error}"[:500]})
            print(f"IDLE-BUDGET-SESSION-FAILED {session} exit={code or 1} {type(error).__name__}: {str(error)[:300]}", flush=True)
            markdown.append(f"\n### {session}\n\nnot measured: {type(error).__name__}: {str(error)[:300]}")
            if isinstance(error, KeyboardInterrupt):
                raise
            if app is not None:  # no app was built: nothing names the build or its features
                report["sessions"][session]["results_v1"] = record_session(app, session, {}, budget, failed=True)
        finally:
            try:
                # The app stops (stop_session: the gated agent turns end first) before the rig's fixtures go.
                teardown_errors = rig.teardown(app, stop=lambda: stop_session(app, agents))
                if teardown_errors:
                    report["sessions"].setdefault(session, {})["teardown_errors"] = teardown_errors
                for problem in teardown_errors:
                    print(f"IDLE-BUDGET-TEARDOWN {session} {problem}", flush=True)
            finally:
                if pages is not None:
                    pages.close()
    cross, cross_notes, chrome_refused = judge_across(report, budget, CHROME_SESSION in sessions)
    for note in cross_notes:
        print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
    for session, over in cross:
        print(over_line(session, over), flush=True)
    for why in chrome_refused:
        print(f"IDLE-BUDGET-REFUSED {CHROME_SESSION} reference: {why}", flush=True)
    if chrome_refused:
        refused.append(CHROME_SESSION)
        report["chrome_refused"] = chrome_refused
    all_overs += [(session, *over) for session, over in cross]
    if cross or cross_notes:
        markdown.append("\n### across sessions\n\n" + "\n".join(
            [f"- {over_line(session, over)}" for session, over in cross] + [f"- {note}" for note in cross_notes]))
    if report.get("ratio_to_chrome"):
        markdown.append(ratio_table(report["ratio_to_chrome"]))
    over_power = power_overs(report)
    if over_power is not None:
        # Q9's work list for visible power (p14-energy.md): reported, never a budget over (D6 judges the total).
        report["power_over"] = over_power
        lines = power_attribution.over_lines(over_power)
        for line in lines:
            print(line, flush=True)
        markdown.append(f"\n### {POWER_SESSION} over {CHROME_POWER_SESSION}\n\n" + ("\n".join(f"- {l}" for l in lines) or "none"))
    report["over"] = [list(o) for o in all_overs]
    report["refused"] = refused
    report["session_exits"] = {name: entry.get("exit") for name, entry in report["sessions"].items()}
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} refused={json.dumps(refused)} sessions={json.dumps(report['session_exits'])} "
          f"json={path}", flush=True)
    sys.exit(exit_code(opts.gate, all_overs, refused))


if __name__ == "__main__":
    main()
