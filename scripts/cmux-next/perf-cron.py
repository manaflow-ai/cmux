#!/usr/bin/env python3
"""cmux-next perf cron: opportunistic, lowest-priority perf measurement of the feat-cmux-next tip.

Lawrence 2026-10-23: no perf gate may block or slow a push, a pull request merge or a nightly build; perf
runs on a cron instead, only on idle fleet capacity, behind every nightly and dev build. The workflow
(.github/workflows/cmux-next-perf-budgets.yml, started by main's cmux-next-perf-cron-dispatch.yml every
20 minutes) runs one tick:

  plan (Linux)      reads the state (the newest `perf-cron-state` artifact), picks the work: the next part of
                    the measurement in flight, else the newest feat-cmux-next commit whose cmux-tui tree is
                    published (a fleet build needs it) when it is newer than the last measured one (commits
                    in between are skipped; when none has a tree, the newest commit, whose Linux parts run at
                    once and whose Mac parts wait for its tree), else one bisect step of an open regression. While a nightly
                    or dev build waits for a Mac on GitHub, a Mac part runs only on cmux20-bench (it runs no
                    CI job); a measurement pinned to another host waits, and gives that host up after 2 h.
                    A Mac part with no reading yet goes first; a tip that predates one ends its Mac parts so the
                    newest commit with a tree measures it (supersede_for_unread).
  measure (gateway) runs only on its own runner label (vars.CI_PERF_CRON_GATEWAY), skips unless the part's host
                    (the measurement's, else cmux20-bench) is idle and no dev build waits in the controller queue,
                    then runs ONE part (its run_seconds: 15 minutes, the build 20, STRESS and sidebar 25, workspace
                    scaling 60 because it seeds and measures a 1000-row topology) as a
                    background (lowest priority) measurement step on that host, and cancels it when a foreground
                    job queues that the host could run (its labels, its name, or a target worker).
  request (controller) with no gateway label and vars.CMUX_NEXT_PERF_CRON_CONTROLLER=1: a job named for the part;
                    the build controller queues it on an idle measure worker and dispatches a result run.
                    Neither route set: every Mac part is recorded as not run.
  report (Linux)    stores the part; after the last part compares every row with the last good run, and opens,
                    updates or closes the one issue "cmux-next perf regression". No check fails on a
                    regression; a missing measurement for 24 h is noted in the issue.

A row is a candidate when its p95 is more than 10 % and its noise floor (perf-budgets.json) over its reference (the
median of its last 5 good values, or the median of its last good values from 7 days ago, at least 3 of them, when
lower: a creep of a little under 10 % per run does not ratchet the baseline up), or when it newly misses its target
(latency rows 10 ms p95; frame rows one display refresh; dropped frames and perf-gate failed checks 0; CPU rows their
perf-budgets.json budget). A candidate regresses only when consecutive tip measurements show a shift
(confirm_regressions).

Subcommands: fetch-state, plan, fleet-check, run-part, part-cleanup, run-linux-part, report, dispatch-next,
replay-results (see each --help). Tests: scripts/cmux-next/tests/test_perf_cron.py (decisions) and test_perf_cron_io.py (GitHub, git, the
fleet client and multi-tick runs, faked) (run them yourself; no CI job runs them).
"""
import argparse, collections, copy, datetime, hashlib, importlib.util, io, json, os, random, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCHEMA = 1
STATE_ARTIFACT = "perf-cron-state"
# The only runs whose state artifact the cron trusts: this workflow, on this branch, in this repository (a fork
# pull request or a run on any other branch can upload an artifact of the same name).
STATE_WORKFLOW = ".github/workflows/cmux-next-perf-budgets.yml"
STATE_BRANCH = "feat-cmux-next"
STATE_EVENTS = ("workflow_dispatch", "schedule", "push")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ISSUE_TITLE = "cmux-next perf regression"
ISSUE_MARK = "<!-- cmux-next-perf-cron -->"
BENCH_WORKER = "cmux20-bench"
# A row's name carries the host that measured it ("panes.1x2.split.frame@cmux20-bench"): the controller runs a part on
# any idle measure worker (lead decision 2026-10-24), every part of one measurement on the host that built its app, and
# a row is only ever compared with values of the same host. A diff row carries the GitHub runner class instead.
HOST_SEP = "@"
# A worker name the cron puts into a request job's name (the controller's perfCronJobName takes the same).
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# The Linux part's rows carry the GitHub runner class that measured them (diff.stream.p95@blacksmith-32vcpu-ubuntu-2404):
# the classes differ in CPU, so a row is compared only within its class. Before host keys every Linux row came from
# this class (the linux job's runs-on: vars.LINUX_RUNNER is blacksmith-4vcpu-ubuntu-2404 on 2026-10-24, so the job
# took blacksmith-32vcpu-ubuntu-2404); rename_legacy_rows names those rows with it.
LEGACY_LINUX_CLASS = "blacksmith-32vcpu-ubuntu-2404"
# A host the fleet check reported offline (not a controller worker, not healthy, not seen: OFFLINE_REASONS) is not
# asked again for this long: the tip goes to any idle measure host meanwhile, and that host's culprit ranges wait. A
# host that is only busy is never marked so (HOST_WAIT_HOURS covers it).
HOST_RETRY_HOURS = 24
OFFLINE_REASONS = ("is not a controller worker", "is not healthy", "has not been seen for over")
# A measurement pinned to a host (the host that built its app, a regressed row's host, or a bisect step's rows'
# host) gives the host up when it took none of the measurement's parts for this long since the first request to it:
# four 20-minute dispatcher ticks past the longest part (25 min) and the controller's 5-minute queue limit, so a host
# that is only between two of the cron's own parts is never given up. A tip measurement goes on on any idle measure
# host (its rows are host-keyed; split-spring.sh --app-cache builds on a cache miss); a bisect step ends without
# blaming its commit (its rows are judged only on that host). The host is not pinned again for as long.
HOST_WAIT_HOURS = 2
# The controller route runs a measurement's Mac parts back to back (cmuxterm-hq perf_cron_batch.go): the request job
# prints them as one BATCH_PREFIX line, the requested part first, at most BATCH_MAX, and every result comes back in one
# result run when the last part ends. Leo, 2026-11-22, on the perf cron's 2 h bench window: "does it need to take it for
# 2h tho? cant it be faster?" One part per round trip took a tip measurement 3 to 14 h (each part waited for a plan,
# a request and a result run on the shared Linux queue); its Mac parts back to back take about 1.5 h. No result comes
# while the batch runs, so the host's silence is bounded by the batch's own deadline on top of HOST_WAIT_HOURS: every
# listed part's run_seconds plus BATCH_SLACK_HOURS (the controller's perfCronBatchSlack).
BATCH_PREFIX = "perf-cron-batch: "
BATCH_MAX = 32
BATCH_SLACK_HOURS = 1
# A Mac host that ran no part for this long while Mac parts ran on other hosts is gone (it left the fleet, or it is
# never idle): its open regressions close as not judged, since it can neither confirm nor clear them (12 tip
# measurements at TIP_EVERY_HOURS went to other hosts meanwhile).
HOST_GONE_HOURS = 72
LATENCY_TARGET_MS = 10.0
STALE_HOURS = 24
# A part whose newest stored rows are older than this runs ahead of the PARTS order (part_order), so each row the
# cron feeds gets a pass within STALE_HOURS: the goals in cmuxterm-hq's NOW (terminal-throughput reads
# terminal.throughput.ratio) need one every 24 h. Four hours under that leave room for one queue wait and the part.
PART_STALE_HOURS = 20
SUPERSEDE_AFTER_HOURS = 24  # a tip measurement younger than this keeps its Mac parts for an unread part (supersede_for_unread)
SUPERSEDED_LINUX_HOURS = 2  # a superseded tip's Linux parts get this long to finish (supersede_for_unread)
ABANDON_HOURS = 12          # of active time: the hours a measurement spent yielding to the fleet do not count
ABANDON_WALL_HOURS = 48     # the hard cap, yielding included
# A tip measurement closed at its bound (close_at_bound) has this long to finish before it is abandoned after all.
CLOSE_GRACE_HOURS = 6
MAX_YIELDS = 3
PART_RUN_SECONDS = 900      # one part, its app build included (Lawrence: under 15 minutes each)
PART_QUEUE_SECONDS = 300    # a part that does not start at once gives its place back
CANDIDATE_DEPTH = 80
# What one plan's tree lookups (tree_published) may take together, inside the plan step's `timeout 600`.
TREE_LOOKUP_SECONDS = 300
# feat-cmux-next gets ~400 first-parent commits a day and a tip measurement takes 3 h or more, so a newer tip
# always exists: while a regression range can be bisected, a tip measurement starts at most once per TIP_EVERY_HOURS
# and the ticks in between go to the bisect.
TIP_EVERY_HOURS = 6
# When no commit since the last tip has a published cmux-tui tree, the tip is the newest commit anyway: its Linux
# parts run at once, and its Mac parts (a fleet build needs the tree) wait this long for its tree, then are recorded
# as not run ('no_tree'). 2026-11-17 07:13Z: none of the 10 commits since the last tip had a tree, so no tip started,
# and the web-ui rows of new Linux benches (cmux#44534) waited on a prerequisite only the Mac parts have.
TREE_WAIT_HOURS = 2
# Judging whether the bisect can measure a commit (its parts, its split-spring.sh version, its cmux-tui tree) costs
# about 30 git reads, some fetching a blob, and a tree lookup. A plan tick judges at most this many commits across
# every range, and a range keeps its place (looked) so the next tick goes on from there: on 2026-11-19 sixteen culprit
# ranges of 300 to 1,900 commits had no measurable commit near their middle, the bisect judged every one of them each
# tick, and the plan job hit its 75 min timeout every tick, so no part ran for two days.
BISECT_JUDGED_PER_TICK = 40
# The plan's checkout is shallow (fetch-depth 300): a culprit range older than that is deepened this many commits at
# a time, at most DEEPEN_ROUNDS times, before its commits are listed.
DEEPEN_STEP = 500
DEEPEN_ROUNDS = 8
# The comparison reference of a row: the median of its last REF_RUNS good values (a single noisy run does not move
# it, and a slow creep does not ratchet it up one run at a time), and the median of its good values from at least
# CREEP_DAYS ago (a creep of a few % per run is caught within that window). Each row keeps HISTORY_DAYS of values.
REF_RUNS = 5
# A row raises a regression only when its baseline has at least CONFIRM_SAMPLES good values (on its own host: Mac rows
# are row@host, the diff rows all run on the same GitHub Linux runner class) and its candidates (values worse than the
# reference) show a shift, not noise the baseline already holds (confirm_regressions): 2 consecutive values outside
# the baseline's spread (spread_top, by more than the 10 % rule and the row's floor) and above its max, or
# CONFIRM_SAMPLES consecutive ones above its max, or REF_RUNS consecutive candidates (as many runs as the reference has
# values). Anything less is "unconfirmed" in the issue, not a regression (lead 2026-10-24: one good value on a shared
# runner opened diff.stream.p95 for noise). The first CONFIRM_SAMPLES values of a row (a new host, or after a rebase)
# cannot be judged by that rule, so they all are baseline values. An open regression keeps the reference it was
# confirmed against (its 'ref'), and closes only after RECOVER_RUNS consecutive judged runs within its threshold, so
# one lucky run neither closes it nor moves its range start past the culprit.
CONFIRM_SAMPLES = 3
RECOVER_RUNS = 2
# A row worse than its reference (state['pending']) is confirmed only by the next tip measurements on its own host
# that judge it, however far apart they are (a measurement may take ABANDON_WALL_HOURS, and bisect steps run between
# tips): the next tip measurement on its host that ran the row's part and printed no value for it, or the row's host
# leaving the fleet (host_gone), drops the entry (review 2 of the host-keyed rows: a noisy value on host X, days of
# measurements on Y, then a second noisy value on X confirmed a regression; review 2 of 8af6ea46de5, finding 3: a
# wall-clock limit reset every streak of a busy host, so a real step there was never confirmed).
CREEP_DAYS = 7
HISTORY_DAYS = 14
HISTORY_MAX = 120
# The issue is the cron's own only when the bot opened it and its body carries ISSUE_MARK.
ISSUE_AUTHOR = "github-actions[bot]"
# A measure job's step: fleet-check (`cmux-ci status`, up to 300 s), the queue (PART_QUEUE_SECONDS), the part (its
# run_seconds), the artifact download (600 s) and the watch loop's last round and slack.
FLEET_CHECK_SECONDS = 300
ARTIFACT_SECONDS = 600
STEP_SLACK_SECONDS = 180
NIGHTLY_WORKFLOWS = ("nightly.yml", "nightly-next-train.yml")
DEV_DAILY_TITLE = "cmux NEXT DEV daily"

# One fleet part = one step through the allowlisted scripts/measure/split-spring.sh on a measure host. The first
# part builds the app once per measurement (--build-only) and leaves it in the host's app cache; every other fleet
# part reuses it (--app-cache) and asks for a 120 Hz virtual display as the main display (--vdisplay=120; the
# report's `display` says whether it came up; after a VDISPLAY-FALLBACK it carries the real main display's measured
# rate, so a fallback run's frame rows are compared with rows of the same refresh only, and dropped frames on any
# display). No cron run has confirmed the 120 Hz display on cmux20-bench yet (2026-10-23). The `linux` part runs on a
# GitHub Linux runner, not on a Mac. `needs`: a capability the measured commit must have.
VDISPLAY_HZ = 120
MEASURE = ["--app-cache", f"--vdisplay={VDISPLAY_HZ}"]
PARTS = [
    # A cold tagged build: 323 s on cmux20-bench, 620 s on cmux7s (2026-10-23).
    {"name": "build", "args": ["--build-only"], "artifact": "artifacts/split-spring/report.json", "kind": "build",
     "run_seconds": 1200},
    # STRESS: 1 round. With 2 rounds the session build and the rounds took ~900 s (cmux7s, 9e875493c37e); 1 round
    # plus the app-cache copy and the virtual display is not timed yet, so it keeps 0b05a9b73bd's 25-minute cap
    # until a cron tick records its `seconds` (each part's time is in the state's parts entries).
    {"name": "stress", "args": [*MEASURE, "--suite=pane-perf", "--layouts=stress", "--rounds=1", "--actions=split,close,column,zoom"],
     "artifact": "artifacts/split-spring/report.json", "kind": "panes", "needs": "stress", "run_seconds": 1500},
    {"name": "motion", "args": [*MEASURE, "--suite=budgets", "--only=panes,new_surfaces"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "switch", "args": [*MEASURE, "--suite=budgets", "--only=tab_switch,palette"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "perf-gate", "args": [*MEASURE, "--suite=perf-gate", "--frames=auto"],
     "artifact": "artifacts/split-spring/perf-gate.json", "kind": "perf_gate", "needs": "perf-gate"},
    {"name": "launch", "args": [*MEASURE, "--suite=launch", "--profile", "empty", "--mode", "warm", "--runs", "5", "--timeout", "20"],
     "artifact": "artifacts/split-spring/report.json", "kind": "launch", "needs": "launch"},
    # The same launch as a Dock click opens it (CMUX-629, CMUX-631): through LaunchServices, activated, the app's own
    # restore placement. The direct exec above skips the wait before main that only a LaunchServices launch pays
    # (cmux#44204: about 600 ms on the nightly against about 50 ms by direct exec), so only this part sees it.
    {"name": "launch-dock", "args": [*MEASURE, "--suite=launch", "--profile", "empty", "--mode", "warm", "--runs", "5",
                                     "--timeout", "20", "--activation", "active", "--window-placement", "restore"],
     "artifact": "artifacts/split-spring/report.json", "kind": "launch", "needs": "launch-dock", "row_prefix": "launch.dock"},
    # A cold launch as a Dock click opens it: no daemon (the app starts it), an empty home, and before every run the
    # staged bundle deleted and copied again, so each launch is the first exec of new files (an update in place, the
    # first launch after a build) and pays the system's check of a new copy before main. Rows launch.cold.<mark>,
    # judged against LAUNCH_COLD_BUDGETS; the run also waits for Home on screen (reveal.home).
    # One word per option (the controller's step takes at most 16 args).
    {"name": "launch-cold", "args": [*MEASURE, "--suite=launch", "--profile=empty", "--mode=cold", "--runs=5", "--timeout=20",
                                     "--activation=active", "--window-placement=restore", "--fresh-copy",
                                     "--ready-mark=reveal.home"],
     "artifact": "artifacts/split-spring/report.json", "kind": "launch", "needs": "launch-cold"},
    # 400 workspaces, 6 scenarios: not timed against 900 s yet (perf-budgets' own per-bench cap is 900 s).
    {"name": "sidebar", "args": [*MEASURE, "--suite=budgets", "--only=sidebar"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "run_seconds": 1500},
    # 1/100/1000 workspace topology: warning-only constant-scaling trend budget. This is the one 60-minute
    # part: seeding and measuring all three topologies is intentionally longer than the normal 15-minute tick.
    {"name": "workspace-scaling", "args": [*MEASURE, "--vdisplay-hold=3600", "--suite=workspace-scaling"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "workspace-scaling", "run_seconds": 3600},
    {"name": "home-idle", "args": [*MEASURE, "--suite=budgets", "--only=home,idle"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    # Wakeups and threads per process kind at idle (scripts/cmux-next/idle-budget.py, its `light` session: the launch
    # window and its terminal, Home's pages in Chromium; 60 s settle, 60 s window): idle_budget.light.<kind>.<field>,
    # judged against idle-budget.json. Chromium's GPU, renderer and utility processes each get <= 1 wakeup/s there
    # (plans/cmux-next/idle-wakeups.md section 7); before this part their wakeups were in no stored row.
    # run_seconds: its first run (2026-11-19, cmux21, cold build) took 2060 s, about 1850 s of it the build.
    {"name": "idle-budget", "args": [*MEASURE, "--suite=idle-budget", "--sessions=light"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "idle-budget", "run_seconds": 2400},
    {"name": "chat-anim", "args": [*MEASURE, "--suite=budgets", "--only=acp,anim"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    # Tabs and terminals as they grow (Leo 2026-11-10: "opening/closing tabs was p important to lawrence ... we defo need
    # to encode and warn sometimes if those get slow"): tab switch at 2 and 30 tabs, 20 quick Cmd-W on terminal and chat
    # tabs, Cmd-T and Ctrl-` at 10 and 30 workspaces. Not timed yet: 25 minutes, as the other multi-bench parts.
    {"name": "tabs", "args": [*MEASURE, "--suite=budgets", "--only=tab_scale,tab_close,surfaces_scale"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "tabs", "run_seconds": 1500},
    # The app's idle memory, empty and with 10 idle agent chats open (memory-agents-cron.py, bench_memory.py on the
    # acpmux test agent): the rows behind goals ram-baseline and memory-per-chat in cmuxterm-hq's NOW (CMUX-571). Its
    # settled samples (150 s after the launch and after the last open, memory.app_agents.settled.) add about 5 minutes.
    # It measures the bench configuration (Release optimization, split-spring.sh --config=bench), the build people
    # run: the goal compares it with other apps' release builds and with the 2026-11-08 Release baseline (app process
    # 243-285 MB). Rows before this were the Debug build, whose app process read 323.3 MB at 8c515cc5, so a Debug row
    # read as growth that was the build. The bench build is the one throughput uses: one build serves both parts.
    {"name": "memory-agents", "args": [*MEASURE, "--config=bench", "--suite=memory-agents", "--agents=10"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "memory-agents",
     "run_seconds": 2700},  # 1800 s for the bench (with its settled samples), plus a cold bench build (800 s) when this part runs first
    # Terminal throughput (scripts/cmux-next/terminal-throughput-bench.py): a 200 MB burst through a NEXT terminal and
    # through standalone Ghostty on the same host, MB/s each and NEXT/Ghostty. Reporting only (REPORT_ONLY_ROW_RE): the
    # CMUX-571 goal terminal-throughput reads terminal.throughput.ratio. One step runs both terminals. NEXT runs in the
    # bench configuration (Release optimization, split-spring.sh --config=bench), since Ghostty is its optimized
    # release; the default Debug build made the ratio a Debug-against-Release one. Rows before this were Debug.
    {"name": "throughput", "args": [*MEASURE, "--config=bench", "--suite=terminal-throughput"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "terminal-throughput",
     "run_seconds": 1800},  # a cold bench-configuration build alone took 800 s (2026-11-15)
    # Late frames and the frame's commit time while a pane divider drags and the window zooms beside a Chromium page
    # (cef-resize-cron.py: cef-resize-sync-bench.py's light bench on the build as it ships): cef_resize.<action>.<layout>
    # .missed (budget 0) and .commit_p95_ms (budget half a display frame), from plans/cmux-next/cef-layer-hosting-DESIGN.md
    # "Live resize". The bench build, like memory-agents and throughput: the frames people see are Release frames.
    {"name": "cef-resize", "args": [*MEASURE, "--config=bench", "--suite=cef-resize"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "cef-resize",
     "run_seconds": 1800},  # 156 s with the bench app cached (step 5574ba49fb74, 2026-11-19); a cold bench build adds ~800 s
    # Terminal key to echo (scripts/cmux-next/typing-frame-bench.py, the cron's run of bench-typing.py's probe): one
    # key at a time typed into a `zsh -f` prompt, from the key event's timestamp to the frame Ghostty reports shown on
    # the layer with the echoed glyph (the typing probe's contents_ms; the photon follows at the next vsync). Idle, 3
    # rounds of 80 keys pooled: row terminal.key_to_echo.idle, target p95 TYPING_KEY_TO_ECHO_MS. The load phase is not
    # in the part yet: on cmux23 (2026-11-19) the agent chats it opens kept the window's keyboard, so no terminal had
    # focus and it measured no key. The bench configuration, like the throughput part next to it (one build serves
    # both): an optimized app is the latency people feel.
    {"name": "typing", "args": [*MEASURE, "--config=bench", "--suite=typing-frame", "--surfaces=terminal",
                                "--phases=idle", "--rounds=3", "--samples=80"],
     "artifact": "artifacts/split-spring/report.json", "kind": "typing", "needs": "typing",
     "run_seconds": 2700},  # cmux23 2026-11-19: 2225 s with a cold bench build (about 1950 s) and idle plus load
    # Power (scripts/cmux-next/power-cron.py, bench_power.py): the app and every process it owns in mW, idle with one
    # terminal, idle with one Chromium page and scrolling a page, and standalone Ghostty idle in the same step. The
    # terminal row's budget is that Ghostty number; the page rows' are the best other browser's in the checked-in
    # xbench baseline. The bench configuration, as for throughput: power of a Debug build is not the app's.
    {"name": "power", "args": [*MEASURE, "--config=bench", "--suite=power"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "power",
     # Measured 2026-11-19 (step bb11176fe4ba, a macOS 27 measure Mac with no cached app): 2738 s, of which the cold
     # bench build took about 2100 s and the scenarios plus the comparison about 640 s. A cached build runs in about
     # 11 minutes; the cap holds the cold case with about 20 % to spare.
     "run_seconds": 3300},
    # Quit and reopen with the chats restored (relaunch-wake-cron.py): the window and the shown chat drawn and live
    # again, warm and after an in-place update. Budgets in that file, each with its source. Its rows
    # (launch.relaunch.*) and the wake part's (launch.wake_proxy.*) are in the launch family, whose target is each
    # row's own budget (target_of), and ROW_PARTS sends them to their parts before the plain launch rows.
    # run_seconds: step ab0db3de ran 2202 s on aws-m4pro-7 with its build (2026-11-19), plus margin.
    {"name": "relaunch", "args": [*MEASURE, "--suite=relaunch"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "relaunch", "run_seconds": 2400},
    # The app after a wake, by proxy (wake-proxy-bench.py): every process of it frozen 30 s and resumed, to the main
    # thread answering and a typed command's output drawn. A measure Mac can't sleep and wake itself in a step.
    # run_seconds: step 343b7e82 ran 2768 s with a cold build of 2522 s and its three rounds (2026-11-19), plus margin.
    {"name": "wake", "args": [*MEASURE, "--suite=wake"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "wake", "run_seconds": 3300},
    # Typing in an agent chat's composer under load (typing-frame-bench.py --modes, the load modes every under-load
    # harness shares in webviews/bench/load-modes.json; Leo, 2026-11-16: "but typing under load is not good enough"):
    # 200 keys per mode, L0 idle to L5 everything at once, against the real agent. Rows typing.agentpane.<mode>.*: the
    # native key dispatch to the page's after-frame callback p95 (16 ms) and p99 (33 ms), and keys lost or reordered
    # (0). A mode whose run is not complete, or that the native bench cannot fully load (its mode_missing), has no
    # row: its number would read as the whole mode. The rows behind cmuxterm-hq NOW's typing-under-load rows.
    # run_seconds: step 3b72dd7b ran all six modes in about 3200 s with its queue and build (cmux20-bench, 2026-11-20).
    # The power-user input stress harness's native half (scripts/perf-bench/power_user_native.py; Leo, 2026-11-22:
    # "you guys also need to be testing flicks of extremely fast input for scrolling and resizing/mouse movement and
    # typing/pasting/switching workspaces around. we need to test like power users more often."): a random seed's
    # bursts of window resize flicks (live drags and setFrame jumps), workspace switches (Ctrl+digit, steps,
    # goToWorkspace), tab switches and all three mixed, 0-33 ms apart, in the bench app at 120 Hz. Rows
    # power_user.native.<class>.*: frame p95 and p99 against 1.5 and 2.5 refresh periods, and long frames, blank
    # frames, flashes, unprovoked layout shift, lost switches, tab reloads and bursts not measured (a hang) against 0.
    # --report-only: the step exits 0 on a breach so its rows are stored and judged here; each breach line carries its
    # replay. run_seconds: the harness's own deadline (1500 s) plus a cold bench build (about 2100 s, the power part).
    {"name": "power-user-native", "args": [*MEASURE, "--config=bench", "--suite=power-user",
                                           "--report-only"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "power-user-native",
     "run_seconds": 3600},
    {"name": "typing-load", "args": [*MEASURE, "--suite=typing-frame", "--modes=all", "--surfaces=agentpane",
                                     "--chat-agent=real", "--rounds=1", "--samples=200"],
     "artifact": "artifacts/split-spring/report.json", "kind": "typing_frame", "needs": "typing-load", "run_seconds": 3600},
    # One chat at 1 MB, 100 MB, 1 GB and 4 GB (scripts/cmux-next/chat-size-ratio.py, goal infinite-chats in cmuxterm-hq's
    # NOW): each size seeded by the app's own acpmux store, opened in the app --runs times; open to first content, fling
    # frame p95, composer key to paint p95, renderer + GPU footprint and the daemon's footprint for the chat, each over
    # the 1 MB chat's (chat_size.<size>.<axis>_ratio) and the worst of them (chat_size.ratio_max; missing when any size
    # crashed, stalled or read nothing). The bench configuration, as memory-agents: one build serves both. Seeding the
    # 4 GB chat and 12 launches are not timed on a fleet Mac yet, so it takes workspace-scaling's 60-minute cap.
    {"name": "chat-size", "args": [*MEASURE, "--vdisplay-hold=3600", "--config=bench", "--suite=chat-size"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "chat-size", "run_seconds": 3600},
    # Leo 2026-11-25 "when you press enter, the stuff should just start playing": the agent chat's Enter to the sent
    # row's frame, its reserved turn in that frame, layout shifts per send, first token and chat switch, plain, in a
    # 1000-turn chat, with 12 other chats open and offline (scripts/measure/snappy-bench.py; chat_snappy.<duress>.*).
    {"name": "chat-snappy", "args": [*MEASURE, "--config=bench", "--suite=chat-snappy"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "needs": "chat-snappy", "run_seconds": 1800},
    # The diff-viewer budgets that left ci-web.yml (scripts/benchmark-diff-viewer.sh), on Linux.
    {"name": "diff-viewer", "where": "linux", "kind": "diff", "needs": "diff-viewer"},
    # The shared web UI perf harness (webviews/bench/web-ui-suite.ts): the web UI benches' PERF_ROW lines, on Linux.
    # run_seconds: since the part's runner job takes the mixed cmux-linux pool (2026-11-23), a small runner built the
    # agent pane in 81 s, and seven benches, each building its page cold inside its own timeout, were killed with exit
    # 137 (Actions run 45457645242, 2026-11-24): no web-ui row stored. The suite now makes those builds once before the
    # benches, within its SHARED_BUILDS_CAP_MS, and the sum of its timeouts and that (SUITE_CAP_MS) sits 30 s under.
    {"name": "web-ui", "where": "linux", "kind": "webui", "needs": "web-ui", "run_seconds": 3000},
    # The update-one bench (webviews/bench/update-one.bench.ts): one session's change at 100, 1,000 and 3,000 listed
    # sessions, its cost and its growth. Its own part, so the suite's other benches keep their 30-minute cap.
    {"name": "web-ui-scale", "where": "linux", "kind": "webui", "needs": "web-ui-scale"},
    # The state-growth bench (webviews/bench/state-growth.bench.ts): what the pane's state layer keeps per operation
    # that should keep nothing (sessions made and closed, chats reopened, reconnects mid-stream, a shell's output
    # streaming), small and god side by side, after warm-up. Its own part (about 2 minutes).
    {"name": "web-ui-growth", "where": "linux", "kind": "webui", "needs": "web-ui-growth"},
    # The chat benches on the god session (webviews/bench/godFixture.ts) beside their ordinary run, on one runner at one
    # commit: each god row, and its god_ratio row (god p95 / ordinary p95, target GOD_RATIO_MAX). Its own part: the
    # six benches take about 13 minutes. Then the paired transcript-replay rounds (GOD_PAIRED_*): the god and small
    # chats played at once, whose median per-round ratio replaces the transcript_replay god_ratio rows.
    {"name": "web-ui-god", "where": "linux", "kind": "webui", "needs": "web-ui-god"},
    # Infinite items (scripts/measure/infinite-items.py, CMUX-571): a release acpmux and headless cmux-tui with 10, 100
    # and 1,000 workspaces (a terminal tab and an agent chat each) through simulated days; memory vs empty, idle CPU
    # and growth per day, the rows behind goal infinite-items-flat in cmuxterm-hq's NOW.
    {"name": "infinite-items", "where": "linux", "kind": "webui", "needs": "infinite-items"},
    # A 1,000,000-event chat (webviews/bench/million-event-chat.bench.ts, CMUX-571, cmux#37713): the pane client's open,
    # one older page and its heap, for long turns and for 4-record turns. Its own part (about 2 minutes).
    {"name": "web-ui-million", "where": "linux", "kind": "webui", "needs": "web-ui-million"},
    # What 10 open agent chats cost one shared renderer beside an empty one (webviews/bench/chat-pages-memory.bench.ts,
    # goal memory-per-chat in cmuxterm-hq's NOW): renderer PSS empty and at 10, MB per chat and the ratio to empty
    # (chat_pages_memory.n10.ratio_vs_empty), a Linux reading that does not wait for the one Mac measure host. Its own
    # part: the suite's default benches already fill its 30-minute cap (about 1 minute).
    {"name": "web-ui-memory", "where": "linux", "kind": "webui", "needs": "web-ui-memory"},
    # A chat at any length (webviews/bench/chat-100k-flat.bench.ts, goal chats-flat-at-any-length in cmuxterm-hq's NOW):
    # a 100k-row chat opened and grown live, one and 20 at once, against empty chats: renderer idle CPU, streaming CPU
    # and PSS, and the worst of those ratios (chat_100k_flat.ratio_max). Its own part, under a 45-minute run cap.
    # run_seconds: chat-100k-flat's seven launches (each about a minute of CPU settle, then three idle and three
    # streaming windows) were still in long_x20 when the suite's 1200 s timeout killed it, so no chat_100k_flat row was
    # stored after 2026-11-17 (Actions run 45422305557). The suite's own timeoutMs sits 5 minutes under.
    {"name": "web-ui-flat", "where": "linux", "kind": "webui", "needs": "web-ui-flat", "run_seconds": 2700},
    # Scrolling up a long chat page by page (webviews/bench/transcript-scroll-up-scale.bench.ts) at 1k, 10k and 100k
    # rows: each older page's ask to its drawn frame (target 50 ms p95), loading and blank frames, the anchor's shift
    # and the 100k / 1k ratio (transcript_scroll_up_scale.*.older_page_drawn_scale, target 1.2). Its own part.
    {"name": "web-ui-scroll-up", "where": "linux", "kind": "webui", "needs": "web-ui-scroll-up"},
    # Its 20 chats grown live to 100k rows each, about 28 minutes on its own (chat_100k_flat.grown_many.*): a 55-minute
    # run cap (run_seconds), not the 30 minutes it timed out against on 2026-11-17 (bench cap 1770 s).
    {"name": "web-ui-flat-grown", "where": "linux", "kind": "webui", "needs": "web-ui-flat", "run_seconds": 3300},
    # The sim's stress ladder (webviews/bench/sim-ladder.bench.ts, goal sim-fidelity-flat-ladder in cmuxterm-hq's NOW):
    # chats and browser tabs at 1, 10 and 100, the cost per added item at 100 over at 10 on renderer CPU, script ms/s,
    # PSS and the focused chat's frame p95 (sim_ladder.ratio_max). Its own part, under the 30-minute run cap.
    {"name": "web-ui-ladder", "where": "linux", "kind": "webui", "needs": "web-ui-ladder"},
    {"name": "web-ui-fidelity", "where": "linux", "kind": "webui", "needs": "web-ui-ladder"},
    # Composer typing under load (webviews/bench/composer-typing.bench.ts, CMUX-571): 500 keys in Chromium and WebKit
    # under idle, a focused stream, ten streaming documents and a focused 100k-row stream; keydown to paint p95/p99
    # (webui.composer_typing.*) against report-only 16/33 ms targets. Its own part, under the 30-minute run cap.
    {"name": "web-ui-typing", "where": "linux", "kind": "webui", "needs": "web-ui-typing"},
    # A fast fling and clicks along the prompt rail in a long chat with 200, 500 and 1,000 listed sessions
    # (webviews/bench/chat-fast-scroll.bench.ts, Leo 2026-11-22 "lags on scrolling ... when he's scrolling really
    # fast"): fling frame intervals and blank frames, rail click to paint and clicks that never loaded. Its own part.
    {"name": "web-ui-scroll", "where": "linux", "kind": "webui", "needs": "web-ui-scroll"},
    # One orchestrator chat with 16 sub-sessions, local and Cloud, all streaming (webviews/bench/orchestrator-16.bench.ts,
    # RFD 0167 row 12): every frame's time with the frame limit off; webui.orchestrator.c16.frame_ms_p99 is NOW's
    # competitive.orchestrator.p99_frame_ms_16_children. Its own part.
    {"name": "web-ui-orchestrator", "where": "linux", "kind": "webui", "needs": "web-ui-orchestrator"},
    # The power-user input stress harness's long seed (webviews/bench/power-user-bursts.bench.ts, Leo 2026-11-22: "we
    # need to test like power users more often"): 150 seeded waves of overlapping input bursts in Chromium and WebKit;
    # frame p95/p99, input to paint, caret lag, dropped keys, stray layout shift and blank frames per input class
    # (webui.power_user.*). Its own part, under the 30-minute run cap.
    {"name": "web-ui-power-user", "where": "linux", "kind": "webui", "needs": "web-ui-power-user"},
    # A settled page after a chat or workspace switch (webviews/bench/settled-page.bench.ts, goal settled-page-ceiling,
    # Leo 2026-11-21: "reach a settled page (zero layout shift after first paint, streaming included) within 2x of a
    # derived bound"): webui.settled_page.score_max is NOW's settled_page_score_max. The suite marks it ownPart, so the
    # web-ui part never ran it and the row read unknown. Its own part, about 3 minutes.
    {"name": "web-ui-settled", "where": "linux", "kind": "webui", "needs": "web-ui-settled"},
    # One live chat's disk growth (scripts/measure/chat-disk-growth.py, the same goal): a release acpmux streams one
    # chat to 100k rows on simulated time against an empty chat; bytes per simulated hour and their ratio
    # (chat_disk.growth_ratio). About 30 s after the build, which runs first under its own cap.
    {"name": "chat-disk", "where": "linux", "kind": "webui", "needs": "chat-disk"},
    # cmux Cloud claim-to-ready (scripts/cmux-next/cloud-claim-rows.py): p50 and p95 over the newest 24 production
    # claims the hourly Cloud journey (cloud-journey-prod.yml) made, read from its probe.json artifacts; no machine is
    # made here. Its rows are cloud.claim_to_ready*, report-only (REPORT_ONLY_ROW_RE): the number is the deployed
    # Cloud's, not the measured commit's, so a bisect over cmux commits could not find its culprit. Their targets are
    # cmuxterm-hq plans/cloud/ARCHITECTURE-2026-11.md T3 "Click to agent ready", shown and marked over target.
    # Its command took 101 s for 24 claims (2026-11-19, a lane VM); the script stops reading at 240 s (DEADLINE_S).
    {"name": "cloud-claim", "where": "linux", "kind": "webui", "needs": "cloud-claim", "row_prefix": "cloud.",
     "run_seconds": 300},
    # Terminal scroll integrity (scripts/measure/terminal-scroll-stress-linux.sh, goal terminal-scroll-integrity in
    # cmuxterm-hq's NOW): blank rows, missing rows and viewport jumps while scrolled back, on a local daemon and over
    # a loopback sshd, in the byte client's own mirror and in the daemon's render viewport. Counts, target 0. Its
    # rows keep their own names (terminal.scroll.*), not webui.*.
    {"name": "terminal-scroll", "where": "linux", "kind": "webui", "needs": "terminal-scroll", "row_prefix": ""},
    # The daemon's restart to a non-empty chat attach (scripts/measure/daemon-restart-linux.sh, goal restart-to-chat's
    # daemon half in cmuxterm-hq's NOW, row restart_chat_attach_daemon_ms, target 178 ms): god_daemon.rs's small and god
    # homes, up to three runs in 15 minutes after the build (the job's 40-minute cap holds setup, a cold build of about
    # 15 minutes and this), each home's median restartChatAttachMs (daemon_restart.<shape>_home.chat_attach_ms). No god
    # home reading gives no metric, so the small home never stands in for the worst of both.
    {"name": "daemon-restart", "where": "linux", "kind": "webui", "needs": "daemon-restart"},
    # Coordinator load (scripts/measure/coord-sim-linux.sh, crate cmux-tui/crates/coord-sim): 3 synthetic coordinator
    # chats shaped like the heaviest real ones (histograms only) streamed at 10x into a release acpmux at once, with
    # readers attached: event delivery p50/p95/p99, lost and duplicated events, attach and first paint under load, a
    # reader paging history, prompt to ack and echo, the daemon's RSS, its slope (the leak signal) and memory and
    # CPU per chat (`coord-sim report`, schema coord-sim-run.v1). Then the fan-in ramp at 50 and 200 sessions (goal
    # sessions-2000-attached; 2,000 needs more than this runner and cap): attach through one controller, the fleet
    # listing, fan-out p50/p95/max, controller CPU and RSS per session and their slope over N. Its rows are
    # webui.coord_sim.*.
    {"name": "coord-sim", "where": "linux", "kind": "webui", "needs": "coord-sim"},
    # Full-text chat search (cmux-tui/crates/acpmux/tests/chats_search_bench.rs, goal chat-history-search in
    # cmuxterm-hq's NOW): phrases typed a key at a time into the Cmd-K chats page's window
    # (`_acpmux/chats_window {query, content: true}`) on a
    # 2,000-chat fixture sized like real stores; the p95 per keystroke (chat_search.keystroke) and, report-only, the
    # scan through `_acpmux/chats_search` (chat_search.scan_keystroke). The release build runs first under its own cap.
    {"name": "chat-search", "where": "linux", "kind": "webui", "needs": "chat-search"},
]
PART_BY_NAME = {p["name"]: p for p in PARTS}
# Which part measures a row (bisect re-measures only the parts of the regressed rows).
ROW_PARTS = [
    (r"^panes\.[^.]+\.stress\.", "stress"), (r"^panes\.", "motion"),
    (r"^(cmd_t|ctrl_backtick)\.idle_\d+ws\.", "tabs"), (r"^tab_switch\.terminal\.(2|30)\.", "tabs"), (r"^tab_close\.", "tabs"),
    (r"^(cmd_n|cmd_t|ctrl_backtick|cmd_d|cmd_shift_d)\.", "motion"),
    (r"^(tab_switch|palette)\.", "switch"), (r"^perf_gate\.", "perf-gate"), (r"^(sidebar|workspace_switch)\.", "sidebar"),
    (r"^workspace_scaling\.", "workspace-scaling"),
    (r"^memory\.app_agents\.", "memory-agents"), (r"^idle_budget\.", "idle-budget"), (r"^(home|idle)\.", "home-idle"), (r"^(acp|anim)\.", "chat-anim"), (r"^launch\.dock\.", "launch-dock"),
    (r"^launch\.cold\.", "launch-cold"),
    (r"^launch\.relaunch\.", "relaunch"), (r"^launch\.wake_proxy\.", "wake"), (r"^launch\.", "launch"),
    (r"^terminal\.throughput\.", "throughput"), (r"^typing\.", "typing-load"),
    (r"^terminal\.throughput\.", "throughput"), (r"^cef_resize\.", "cef-resize"), (r"^terminal\.scroll\.", "terminal-scroll"),
    (r"^power_user\.native\.", "power-user-native"), (r"^power\.", "power"),
    (r"^chat_size\.", "chat-size"), (r"^chat_snappy\.", "chat-snappy"),
    (r"^terminal\.key_to_echo\.", "typing"),
    (r"^diff\.", "diff-viewer"), (r"^webui\.update_one\.", "web-ui-scale"),
    (r"^webui\.state_growth\.", "web-ui-growth"),
    # chat-open-god's paired rows (chat-open.bench.ts PAIRED=1), the small chat's too: the part that ran them keeps them.
    (r"^webui\.chat_open_paired\.", "web-ui-god"),
    (r"^webui\.(god_ratio\.|[a-z0-9_]+\.god\.)", "web-ui-god"), (r"^webui\.infinite_items\.", "infinite-items"),
    (r"^webui\.million_event_chat\.", "web-ui-million"),
    (r"^webui\.chat_pages_memory\.", "web-ui-memory"),
    (r"^webui\.chat_100k_flat\.grown_many\.", "web-ui-flat-grown"),
    (r"^webui\.chat_100k_flat\.", "web-ui-flat"),
    (r"^webui\.sim_ladder\.", "web-ui-ladder"),
    (r"^webui\.sim_fidelity\.", "web-ui-fidelity"),
    (r"^webui\.transcript_scroll_up_scale\.", "web-ui-scroll-up"),
    (r"^webui\.composer_typing\.", "web-ui-typing"),
    (r"^webui\.chat_fast_scroll\.", "web-ui-scroll"),
    (r"^webui\.orchestrator\.", "web-ui-orchestrator"),
    (r"^webui\.sidebar_chats_fling\.", "web-ui-scroll"),
    (r"^webui\.power_user\.", "web-ui-power-user"),
    (r"^webui\.settled_page\.", "web-ui-settled"),
    (r"^webui\.chat_disk\.", "chat-disk"),
    (r"^cloud\.claim_to_ready", "cloud-claim"),
    (r"^webui\.daemon_restart\.", "daemon-restart"),
    (r"^webui\.coord_sim\.", "coord-sim"),
    (r"^webui\.chat_search\.", "chat-search"),
    (r"^webui\.", "web-ui"),
]
# Rows that are stored and shown but never judged: higher is better there (MB/s, a ratio to Ghostty), and every rule
# here reads a higher p95 as worse. The memory-agents breakdown (memory-agents-cron.py) says where the judged totals'
# memory is, per process kind; its kinds come and go with the app, so a row each is shown, not judged. The chat
# composer's typing stages (acp.<engine>.typing.to_listener and .to_work, perf-budgets.py STAGE_ROW_RE) say where
# the judged to_frame time goes: shown, not judged (measurement only, no new gate). The wake part's awake echo is the
# same echo with nothing frozen: the floor under the judged wake row, shown only. The chat-open paired rounds'
# attach_to_latest ms (webui.chat_open_paired[.god].<rail>.attach_to_latest) is shown against cmuxterm-hq's ms target
# but tracks the runner (100 to 185 ms for the same code, goal chat-attach-p95); attach_per_dcl beside it, the same
# rounds over each load's own DOMContentLoaded, is the row judged, so a slow runner opens no regression. The power
# part's Ghostty idle mW and the app's ratio to it are the terminal row's comparison: shown, not judged (that row has
# Ghostty's mW as budget). The chat search's fill and the CLI's scan (chat-search) are context for its judged
# keystroke row: shown, not judged.
REPORT_ONLY_ROW_RE = re.compile(r"^(terminal\.throughput\.|memory\.app_agents\.breakdown\.|cloud\.claim_to_ready"
                                r"|acp\.[^.]+\.typing\.(to_listener|to_work|to_frame_frames)$"
                                r"|acp\.[^.]+\.frame_interval$|acp\.[^.]+-(capped|full|nolimit)\."
                                r"|launch\.wake_proxy\.awake_echo_ms$"
                                r"|webui\.chat_open_paired\.(god\.)?[a-z0-9_]+\.attach_to_latest$"
                                r"|power\.idle\.terminal\.(ghostty_mw|vs_ghostty)$"
                                r"|webui\.chat_search\.(fill|scan_keystroke)\b)")
# The diff-viewer budgets of scripts/benchmark-diff-viewer.sh (its env defaults), as rows where lower is better.
DIFF_BUDGETS = {"diff.sidecar.manifest_decode_p95": 1000.0, "diff.sidecar.read_ms_per_gib": 1024 * 1000 / 500.0,
                "diff.stream.p95": 250.0}
# The launch-time budget that left the pull request CI (ms since process start, warm launch, empty profile).
LAUNCH_BUDGETS = {"did_finish_launching_end": 800, "first_window_frame_committed": 1000, "sidebar_rows_shown": 1000}
# A Dock launch's budget (launch-dock). The Dock's bounce ends when AppKit checks in with LaunchServices
# (NSRunningApplication.isFinishedLaunching), just before the delegate's applicationDidFinishLaunching runs: on the
# nightly (launch-ready.sh, 2026-11-18, n=10) isFinishedLaunching came at 692 ms and did_finish_launching_start at
# 719. Its target is launch-shell-first.md's "Dock bounce over", 250 ms: the icon rises once and stops. The other
# rows keep the direct exec's budgets.
# Terminal key to echo's target p95 (ms): plans/cmux-next/perf-lead.md's "Key to frame (terminal, Home composer,
# omnibar) p95 < 8 ms", whose proof is bench-typing.py's probe. Under the generic LATENCY_TARGET_MS on purpose.
TYPING_KEY_TO_ECHO_MS = 8.0
LAUNCH_DOCK_BUDGETS = {"did_finish_launching_start": 250, "did_finish_launching_end": 800,
                       "first_window_frame_committed": 1000, "sidebar_rows_shown": 1000,
                       # Before main on a relaunch of the same copy: launch-shell-first.md measured 117 to 166 ms through
                       # LaunchServices on a quiet Mac (cmux16, 2026-11-16), the bound its 250 ms first frame assumes.
                       # Chromium's code-sign clone makes XProtect rescan the executable first (about 600 ms, cmux#44204).
                       "main_start": 166}
# A cold launch's budget (launch-cold), ms from process start. Home on screen (reveal.home) within 600 ms is
# cmuxterm-hq goals/next-launch-instant.md ("launch to Home at most 600 ms"); the first frame within 300 ms is
# docs/design/launch-shell-first.md's cold row ("300 to the frame, 600 to Home"). That doc measured the cold first open
# of a new copy (launch-fresh-install.sh, nightly, n=5, 2026-11-18) at 1495 ms to main and 2800 ms to the first frame.
# main_start on a cold copy is the system's policy check and dyld (launch-shell-first.md: 1495 ms, nightly, n=5); its
# budget is the same 166 ms as a relaunch's, since stage 0's 300 ms frame has no room for more.
LAUNCH_COLD_BUDGETS = {"main_start": 166, "first_window_frame_committed": 300, "reveal.home": 600}
LAUNCH_BUDGETS_BY_PART = {"launch-dock": LAUNCH_DOCK_BUDGETS, "launch-cold": LAUNCH_COLD_BUDGETS}


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc) if s else None


def hours_between(a, b):
    return (b - a).total_seconds() / 3600.0


def load_budgets_module():
    spec = importlib.util.spec_from_file_location("perf_budgets", os.path.join(HERE, "perf-budgets.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_BUDGET_TABLE = {}


def budget_table():
    """perf-budget-table.py and its table, loaded once a process: (module, rows)."""
    if "rows" not in _BUDGET_TABLE:
        spec = importlib.util.spec_from_file_location("perf_budget_table", os.path.join(HERE, "perf-budget-table.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _BUDGET_TABLE.update(mod=mod, rows=mod.load_table())
    return _BUDGET_TABLE["mod"], _BUDGET_TABLE["rows"]


def budget_report(state, now):
    """The budget of every producer from the state (perf-budget-table.py): (module, result), or (None, error text) when
    the table does not load. Reported, never judged: it opens, closes and fails nothing."""
    try:
        mod, rows = budget_table()
        return mod, mod.evaluate(rows, state, now)
    except (OSError, ValueError, re.error) as error:
        return None, f"Budget: the table did not load ({error})"


def budget_issue_lines(state, now):
    mod, result = budget_report(state, now)
    return mod.issue_lines(result) if mod else [f"**{result}.**"]


def animation_budgets(budgets_mod):
    """perf-budgets' animation rows; scripts/perf-bench/budget.py imports its siblings, so their directory goes
    on sys.path first. None of them on this checkout: no animation rows (their default budgets apply)."""
    bench = os.path.join(ROOT, "scripts", "perf-bench")
    if bench not in sys.path:
        sys.path.insert(0, bench)
    try:
        return budgets_mod.animation_budgets()
    except Exception as error:  # noqa: BLE001 - a newer budget.py shape must not stop the report
        print(f"perf-cron: no animation budgets ({error!r})")
        return {}


def empty_state(t):
    """last: the newest finished tip measurement that re-measured every open regression (the stale clock).
    last_tried: the newest tip measurement that finished at all (the new-commit search starts after it, so a commit
    that does not build is not rebuilt every tick). row_ok: per row, the newest tip measurement in which it was
    measured and within its threshold (a row that regresses later gets its own culprit range from there). Each
    regression carries its own range {good, bad, skip, steps} and first_bad."""
    return {"schema": SCHEMA, "created_at": iso(t), "current": None, "last": None, "last_tried": None, "last_good": None,
            "row_ok": {}, "regressions": [], "issue": None, "stale_noted_for": None, "history": []}


def is_sha(value):
    return isinstance(value, str) and bool(SHA_RE.match(value))


def migrate_state(state):
    """States before 2026-10-23 kept one first_bad and range for every regressed row; each row now has its own."""
    rng, bad = state.pop("range", None), state.pop("first_bad", None)
    for r in state.get("regressions") or []:
        if isinstance(r, dict) and "range" not in r and isinstance(rng, dict):
            r["range"] = {"good": rng.get("good"), "bad": rng.get("bad"), "skip": [], "steps": 0}
            r["first_bad"] = bad
    state.setdefault("row_ok", {})
    state.setdefault("last_tried", None)
    rename_legacy_rows(state)
    name_legacy_parts(state.get("current"))
    # Regressions opened before the confirmation rule (2026-10-24) stay open with their range, bisect steps and
    # first_bad: the still/recovered rule judges them, and a noisy one closes after RECOVER_RUNS runs within its
    # threshold. Holding them as pending values instead lost real ones (review 1 of 8af6ea46de5, finding 3): the first
    # tip run that did not judge the row, or a day without one, dropped the entry with its range and closed the issue.
    for r in state.get("regressions") or []:
        if isinstance(r, dict) and not r.get("confirmed"):
            r["confirmed"] = True
        # An open regression is judged against the reference it was confirmed against (review 2 of 8af6ea46de5,
        # finding 2). One opened before the regression kept it carries the reference of its last judged run.
        if isinstance(r, dict) and "ref" not in r and isinstance(r.get("base"), (int, float)):
            r["ref"] = r["base"]
    # 8af6ea46de5 restarted full baselines and absorbed sustained steps unjudged, and wrote its restarts with no 'seen'
    # key: each opens the issue once for a person to check it (review 2 of 8af6ea46de5, finding 7).
    for x in state.get("baseline_restarts") or []:
        if isinstance(x, dict) and "seen" not in x:
            x["seen"] = False
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else {}
    # A pending entry of e1e3f6edf70's rule held one value at its top level: it becomes a streak of that value.
    for name, value in list(pending.items()):
        if isinstance(value, dict) and "values" not in value and is_sha(value.get("sha")):
            pending[name] = {"values": [{k: value.get(k) for k in ("sha", "p95", "at", "run_url")}],
                             "at": value.get("at"), "sha": value["sha"]}
    state["pending"] = pending
    state.pop("building", None)
    return state


def sanitize_state(state, ok):
    """Drop every part of the state that names a commit `ok(sha)` rejects (not 40 hex characters, or not on the
    measured branch), and unknown part names: a sha from the state goes to `git rev-list` and to `cmux-ci run
    --ref` on a measure host. Returns what was dropped."""
    dropped = []
    cur = state.get("current")
    if cur is not None:
        rng = cur.get("bisect_range") if isinstance(cur, dict) else None
        if (not isinstance(cur, dict) or not ok(cur.get("sha")) or cur.get("kind") not in ("tip", "bisect")
                or (cur.get("kind") == "bisect" and not (isinstance(rng, dict) and ok(rng.get("good")) and ok(rng.get("bad"))))):
            state["current"] = None
            dropped.append("current")
        else:
            cur["parts_todo"] = [p for p in cur.get("parts_todo") or [] if p in PART_BY_NAME]
            cur["parts"] = {k: v for k, v in (cur.get("parts") or {}).items() if k in PART_BY_NAME and isinstance(v, dict)}
            if "host" in cur and not (isinstance(cur["host"], str) and HOST_RE.match(cur["host"])):
                cur.pop("host")
                dropped.append("current host")
    for key in ("last", "last_tried", "last_good"):
        v = state.get(key)
        if v is not None and not (isinstance(v, dict) and ok(v.get("sha"))):
            state[key] = None
            dropped.append(key)
    regs = []
    for r in state.get("regressions") or []:
        rng = r.get("range") if isinstance(r, dict) else None
        valid = isinstance(r, dict) and isinstance(r.get("name"), str) and (rng is None or (
            isinstance(rng, dict) and ok(rng.get("good")) and ok(rng.get("bad")) and all(ok(x) for x in rng.get("skip") or [])))
        if valid and isinstance(r.get("first_bad"), dict) and not ok(r["first_bad"].get("sha")):
            valid = False
        if valid:
            regs.append(r)
        else:
            dropped.append(f"regression {r.get('name') if isinstance(r, dict) else r!r}")
    state["regressions"] = regs
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else {}
    kept_pending = {}
    for name, value in pending.items():
        values = (value or {}).get("values") if isinstance(value, dict) else None
        if isinstance(name, str) and isinstance(values, list) and values and all(
                isinstance(v, dict) and ok(v.get("sha")) and isinstance(v.get("p95"), (int, float)) for v in values):
            kept_pending[name] = value
    if len(kept_pending) != len(pending):
        dropped.append(f"{len(pending) - len(kept_pending)} pending entries")
    state["pending"] = kept_pending
    row_ok = state.get("row_ok") if isinstance(state.get("row_ok"), dict) else {}
    state["row_ok"] = {k: v for k, v in row_ok.items() if isinstance(k, str) and ok(v)}
    if len(state["row_ok"]) != len(row_ok):
        dropped.append(f"{len(row_ok) - len(state['row_ok'])} row_ok entries")
    # A history commit can become a creep's range start (creep_range_good): one not on the branch loses its sha (the
    # value stays a baseline value), so the regression it would start is never stored with a range dropped here later.
    unnamed = 0
    for entries in (state.get("row_history") or {}).values() if isinstance(state.get("row_history"), dict) else []:
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and "sha" in e and not ok(e["sha"]):
                e.pop("sha")
                unnamed += 1
    if unnamed:
        dropped.append(f"{unnamed} row_history commits")
    if state.get("issue") is not None and not (isinstance(state["issue"], int) and state["issue"] > 0):
        state["issue"] = None
        dropped.append("issue")
    return dropped


def base_row(name):
    """A row's name without its host ("panes.x.frame@cmux20-bench" -> "panes.x.frame")."""
    return name.split(HOST_SEP, 1)[0]


def row_host(name):
    """The host in a row's name, or None (a Linux row)."""
    return name.split(HOST_SEP, 1)[1] if HOST_SEP in name else None


def host_rows(rows, host):
    """The rows with their host in the name (pure)."""
    return {f"{base_row(n)}{HOST_SEP}{host}": r for n, r in rows.items()} if host else dict(rows)


def part_for_row(name):
    name = base_row(name)
    for pattern, part in ROW_PARTS:
        if re.search(pattern, name):
            return part
    return None


def linux_part_classes(rows):
    """{Linux part: the runner classes its rows here carry} (pure). Each Linux part runs on its own runner (the linux
    matrix; a part's PARTS runner may differ from the others'), so a class change is judged per part."""
    out = {}
    for name in rows:
        if linux_row(name):
            out.setdefault(part_for_row(name), set()).add(row_host(name))
    return out


def linux_class_changed(name, classes):
    """A Linux row whose part ran here on another runner class (pure): it is never measured on its class again."""
    part = part_for_row(name) if linux_row(name) else None
    return bool(part and classes.get(part)) and row_host(name) not in classes[part]


def linux_row(name):
    """A row of the Linux part (its host is a GitHub runner class, not a Mac)."""
    part = part_for_row(name)
    return part is not None and is_linux_part(part)


def mac_host(name):
    """The Mac host in a row's name, or None (a Linux row, or a name with no host)."""
    return None if linux_row(name) else row_host(name)


def macos_minor(version):
    """macOS major.minor of a version string ("26.4.1" -> "26.4"), or None. A patch update measures the same."""
    if not isinstance(version, str) or not version.strip():
        return None
    return ".".join(version.strip().split(".")[:2])[:16]


def legacy_row_name(name):
    """The name of a row stored before host keys (3c2bfd8efbb): every Mac row then came from BENCH_WORKER, and every
    Linux row from LEGACY_LINUX_CLASS (pure)."""
    if not isinstance(name, str) or HOST_SEP in name:
        return name
    return f"{name}{HOST_SEP}{LEGACY_LINUX_CLASS if linux_row(name) else BENCH_WORKER}"


def rename_legacy_rows(state):
    """Give every row name stored before host keys its host (legacy_row_name), so a regression, a reference or a
    pending value of the old name is judged again under the name the cron measures now."""
    def renamed(d):
        return {legacy_row_name(k): v for k, v in d.items()} if isinstance(d, dict) else d
    for key in ("last_good", "last"):
        if isinstance(state.get(key), dict) and isinstance(state[key].get("rows"), dict):
            state[key]["rows"] = renamed(state[key]["rows"])
    for key in ("row_history", "row_ok", "pending"):
        if isinstance(state.get(key), dict):
            state[key] = renamed(state[key])
    for key in ("regressions", "unconfirmed"):
        for r in state.get(key) or []:
            if isinstance(r, dict) and isinstance(r.get("name"), str):
                r["name"] = legacy_row_name(r["name"])


def name_legacy_parts(cur):
    """Give each done part of the measurement in flight that was stored before host keys its host, as
    rename_legacy_rows does for rows: every Mac part then ran on BENCH_WORKER and the Linux part on LEGACY_LINUX_CLASS.
    Since host keys the report stores the worker with every done part (one without is refused, not stored), so a done
    part with no worker is one of those. Its later parts are asked for on BENCH_WORKER (its app cache)."""
    if not isinstance(cur, dict) or not isinstance(cur.get("parts"), dict):
        return
    for name, p in cur["parts"].items():
        if isinstance(p, dict) and p.get("state") == "done" and not p.get("worker") and name in PART_BY_NAME:
            p["worker"] = LEGACY_LINUX_CLASS if is_linux_part(name) else BENCH_WORKER
            if not is_linux_part(name):
                cur.setdefault("host", BENCH_WORKER)


# ---------- rows and targets (pure) ----------

def refresh_ms_of(report):
    """The display refresh interval (ms) a part measured at, or None (unknown). The median of the `refresh_ms` keys
    its benches printed (the display the app was on), else the `display` scripts/measure/split-spring.sh put into
    the report: the virtual display's measured interval, or after a VDISPLAY-FALLBACK the real main display's (`VDisplay
    probe`; null when that did not tick either). perf-budgets.py prints no refresh, so its parts get theirs from
    `display` only."""
    found = []

    def walk(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k == "refresh_ms" and isinstance(x, (int, float)) and 2 <= x <= 50:
                    found.append(float(x))
                elif k != "display":
                    walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(report)
    found.sort()
    if found:
        return found[len(found) // 2]
    display = report.get("display") if isinstance(report, dict) else None
    r = display.get("refresh_ms") if isinstance(display, dict) else None
    return float(r) if isinstance(r, (int, float)) and 2 <= r <= 50 else None


# The typing-load part's budgets (Leo's target for typing under load): key dispatch to after-frame p95 and p99.
TYPING_P95_MS = 16.0
TYPING_P99_MS = 33.0


def typing_frame_rows(report):
    """typing.<surface>.<mode>.{after_frame, after_frame_p99, lost_keys} from typing-frame-bench.py's --modes runs: one
    set per complete run whose mode the native bench loads in full (mode_missing empty). A mode with several rounds
    keeps its worst round. An incomplete run, or a mode the bench loads only in part, gives no row."""
    out = {}
    for run in report.get("runs") or []:
        if not isinstance(run, dict) or not run.get("mode") or run.get("complete") is not True or run.get("mode_missing"):
            continue
        p50, p95 = run.get("dispatch_to_after_frame_p50_ms"), run.get("dispatch_to_after_frame_p95_ms")
        p99 = run.get("dispatch_to_after_frame_p99_ms")
        if not all(isinstance(v, (int, float)) for v in (p50, p95, p99)):
            continue
        expected, observed = run.get("expected_keys"), run.get("observed_keys")
        lost = expected - observed if isinstance(expected, int) and isinstance(observed, int) else None
        if run.get("text_exact") is not True or run.get("key_order_ok") is not True:
            lost = max(lost or 0, 1)
        prefix = f"typing.{run.get('surface') or 'agentpane'}.{run['mode']}"
        rows = {f"{prefix}.after_frame": {"p50": p50, "p95": p95, "unit": "ms", "budget": TYPING_P95_MS, "floor": 2.0},
                f"{prefix}.after_frame_p99": {"p50": p99, "p95": p99, "unit": "ms", "budget": TYPING_P99_MS, "floor": 4.0}}
        if lost is not None:
            rows[f"{prefix}.lost_keys"] = {"p50": lost, "p95": lost, "unit": "keys", "budget": 0, "floor": COUNT_FLOOR}
        for name, row in rows.items():
            if name not in out or row["p95"] > out[name]["p95"]:
                out[name] = row
    return out


def rows_of_part(part, report, budgets_mod, budgets):
    """{row name: {p50, p95, unit, budget, floor}} from one part's report."""
    out = {}
    if not isinstance(report, dict):
        return out
    if part["kind"] == "budgets":
        for r in report.get("rows") or []:
            if r.get("p95") is not None:
                out[r["name"]] = {"p50": r.get("p50"), "p95": r["p95"], "unit": r.get("unit", "ms"),
                                  "budget": r.get("budget"), "floor": r.get("floor", 1.0)}
    elif part["kind"] == "panes":
        for name, (p50, p95) in budgets_mod.rows_panes(report).items():
            if p95 is None:
                continue
            spec = budgets_mod.budget_for(name, budgets)
            out[name] = {"p50": round(p50, 2) if p50 is not None else None, "p95": round(p95, 2),
                         "unit": spec.get("unit", "ms"), "budget": spec.get("p95"), "floor": spec.get("floor", 1.0)}
        # Dropped frames, judged in frames (a 60 Hz and a 120 Hz run differ in ms, not in drops).
        for s in report.get("summary") or []:
            if isinstance(s.get("missed"), (int, float)) and s.get("action") and s.get("layout"):
                n = s["missed"]
                out[f"panes.{s['action']}.{s['layout']}.missed"] = {"p50": n, "p95": n, "unit": "frames", "budget": 0,
                                                                     "floor": COUNT_FLOOR}
    elif part["kind"] == "perf_gate":
        per = {}
        for c in report.get("checks") or []:
            per.setdefault(c.get("scenario") or "?", [0, 0])
            per[c.get("scenario") or "?"][0 if c.get("ok") else 1] += 1
        for scenario, (_ok, failed) in sorted(per.items()):
            out[f"perf_gate.{scenario}.failed_checks"] = {"p50": failed, "p95": failed, "unit": "checks", "budget": 0, "floor": 0.5}
    elif part["kind"] == "launch":
        prefix = part.get("row_prefix", "launch")
        launch_budgets = LAUNCH_BUDGETS_BY_PART.get(part["name"], LAUNCH_BUDGETS)
        for _tag, modes in report.items():
            for mode, runs in (modes or {}).items() if isinstance(modes, dict) else []:
                runs = runs if isinstance(runs, list) else []
                for mark, budget in launch_budgets.items():
                    values = [r[mark] for r in runs if isinstance(r, dict) and isinstance(r.get(mark), (int, float))]
                    if runs:
                        # A launch that hangs never sends the mark: the old CI budget failed on that, so it is a
                        # row of its own (target 0), and a run with no marks at all misses every one.
                        missing = len(runs) - len(values)
                        out[f"{prefix}.{mode}.{mark}.missing_runs"] = {"p50": missing, "p95": missing, "unit": "runs",
                                                                     "budget": 0, "floor": 0.5}
                    if values:
                        p50, p95 = budgets_mod.pct(values, 0.5), budgets_mod.pct(values, 0.95)
                        out[f"{prefix}.{mode}.{mark}"] = {"p50": round(p50, 1), "p95": round(p95, 1), "unit": "ms",
                                                        "budget": budget, "floor": 20.0}
    elif part["kind"] == "typing_frame":
        out.update(typing_frame_rows(report))
    elif part["kind"] == "diff":
        sidecar, stream = report.get("sidecar") or {}, report.get("stream") or {}

        def num(obj, *keys):  # the sidecar prints camelCase (serde rename); accept snake_case too
            return next((obj[k] for k in keys if isinstance(obj.get(k), (int, float))), None)
        decode = num(sidecar, "manifestDecodeP95Micros", "manifest_decode_p95_micros")
        read = num(sidecar, "sequentialReadMibPerSecond", "sequential_read_mib_per_second")
        values = {}
        if decode is not None:
            values["diff.sidecar.manifest_decode_p95"] = (decode, "us", 50.0)
        if read:
            values["diff.sidecar.read_ms_per_gib"] = (round(1024 * 1000 / read, 2), "ms/GiB", 50.0)
        if isinstance(stream.get("p95Ms"), (int, float)):
            values["diff.stream.p95"] = (stream["p95Ms"], "ms", 10.0)
        versions = report.get("bench_versions") if isinstance(report.get("bench_versions"), dict) else {}
        load = report.get("load") if isinstance(report.get("load"), dict) else {}
        for name, (v, unit, floor) in values.items():
            # On a busy runner a row of a LOAD_SCALED_BENCHES bench is divided by its bench's contention; any other
            # row only records it.
            bench = name.split(".")[1]
            factor = load.get(bench)
            factor = factor if isinstance(factor, (int, float)) and factor > 1 else None
            scaled = round(v / factor, 4) if factor and bench in LOAD_SCALED_BENCHES else v
            out[name] = {"p50": scaled, "p95": scaled, "unit": unit, "budget": DIFF_BUDGETS[name], "floor": floor}
            if factor:
                out[name]["load"] = factor
                if scaled != v:
                    out[name]["raw_p95"] = v
            version = versions.get(bench)
            out[name]["measure_version"] = (version if isinstance(version, int) else DIFF_LEGACY_VERSION) \
                + 100 * DIFF_LOAD_VERSION
    elif part["kind"] == "typing":
        out.update(typing_rows(report, budgets_mod))
    elif part["kind"] == "webui":
        # web-ui-suite.ts's rows (webviews/bench/perfRow.ts): its target is the row's budget, its floor the noise on
        # a shared runner (10 % of p95 when the bench names none: a change must pass both that and the 10 % rule).
        out.update(webui_rows(report.get("rows"), part.get("row_prefix", "webui.")))
        if part.get("name") == "web-ui-god":
            # The ordinary twins ran here only to pair at one commit on one runner; the web-ui part owns their rows.
            ratios = god_ratio_rows(out)
            out = {n: r for n, r in out.items() if part_for_row(n) == "web-ui-god"}
            out.update(ratios)
            # The paired rounds' median ratio replaces the one-run ratio of the same row (cmuxterm-hq's
            # god_chat_replay_ratio_max reads webui.god_ratio.transcript_replay.long.{heap_mb,thought_ms,token_ms}).
            paired = report.get("paired") if isinstance(report.get("paired"), dict) else {}
            out.update(paired_ratio_rows(paired.get("rounds") or []))
    return out


def typing_rows(report, budgets_mod):
    """{terminal.key_to_echo.<phase>: row} of a typing-frame-bench.py report (pure): every round's measured keys of
    the terminal surface pooled per session and phase, p50 and p95 of key to echoed frame, target
    TYPING_KEY_TO_ECHO_MS. The light session's rows carry no session; another session's (STRESS, a backdrop) name it.
    A run without `key_to_frame_values` (a bench before the cron's part) gives no row."""
    pooled = {}
    for run in report.get("runs") or []:
        if not isinstance(run, dict) or run.get("surface") != "terminal":
            continue
        values = [v for v in run.get("key_to_frame_values") or [] if isinstance(v, (int, float))]
        session = re.sub(r"[^a-z0-9_]+", "_", str(run.get("session") or "light").lower())
        phase = re.sub(r"[^a-z0-9_]+", "_", str(run.get("phase") or "idle").lower())
        name = f"terminal.key_to_echo.{phase}" if session == "light" else f"terminal.key_to_echo.{session}.{phase}"
        pooled.setdefault(name, []).extend(values)
    out = {}
    for name, values in pooled.items():
        if values:
            out[name] = {"p50": round(budgets_mod.pct(values, 0.5), 2), "p95": round(budgets_mod.pct(values, 0.95), 2),
                         "unit": "ms", "budget": TYPING_KEY_TO_ECHO_MS, "floor": 1.0, "n": len(values)}
    return out


def webui_rows(rows, prefix="webui."):
    """{webui.<name>: row} of a list of PERF_ROW objects (pure): a row's target is its budget, its floor the noise on
    a shared runner (10 % of p95 when the bench names none: a change must pass both that and the 10 % rule). A part
    with its own row_prefix ("" for terminal-scroll) names its rows with that instead of webui."""
    out = {}
    for r in rows or []:
        name, p95 = r.get("name") if isinstance(r, dict) else None, r.get("p95") if isinstance(r, dict) else None
        if not (isinstance(name, str) and WEBUI_ROW_RE.match(name) and isinstance(p95, (int, float))):
            continue
        p50 = r.get("p50") if isinstance(r.get("p50"), (int, float)) else p95
        floor = r.get("floor") if isinstance(r.get("floor"), (int, float)) else max(round(0.1 * p95, 4), 0.0001)
        out[f"{prefix}{name}"] = {"p50": p50, "p95": p95, "unit": r.get("unit") or "ms",
                                "budget": r.get("target") if isinstance(r.get("target"), (int, float)) else None,
                                "floor": floor,
                                "measure_version": r["version"] if isinstance(r.get("version"), int) else DIFF_LEGACY_VERSION}
    return out


def median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


def median_interval(values, draws=4000):
    """The 95% interval of VALUES' median (pure): a seeded bootstrap, as webviews/bench/god-ratio-ab.sh computes it."""
    rng = random.Random(1)
    meds = sorted(median(rng.choices(values, k=len(values))) for _ in range(draws))
    return meds[int(draws * 0.025)], meds[int(draws * 0.975)]


def paired_ratio_rows(rounds):
    """{webui.god_ratio.<twin>: row} from the web-ui-god part's paired transcript-replay rounds (pure): each round's
    god / small ratio (god_ratio_rows over that round's PERF_ROW lines, both chats played at once), and the row is the
    median over the rounds, with its 95% interval (ci_lo, ci_hi, ci_width), the per-round ratios and their count. A row
    needs GOD_PAIRED_MIN_ROUNDS rounds that measured it. Run one after the other, a round's ratio swung 0.5x to 1.9x on
    the same code; paired, about 0.08x (cmux#43874).
    The small chat's least value (GOD_RATIO_MIN) is judged on the median of the rounds' small p95, not per round: in a
    paired round both chats run on the runner at the same speed, so a fast round (small token p95 3.6 ms, god 4.4 ms)
    is as good a pair as a slow one. Judged per round, that one fast round of five dropped the token and thought rows
    under GOD_PAIRED_MIN_ROUNDS, and the board read the one-run ratio (1.578) in place of the paired median (1.384) at
    83b6f50f (perf cron run 43797713590)."""
    per = {}
    for each in rounds:
        for name, r in _paired_round_ratios(each).items():
            per.setdefault(name, []).append(r)
    out = {}
    for name, rs in sorted(per.items()):
        if len(rs) < GOD_PAIRED_MIN_ROUNDS:
            continue
        small = median([r["small_p95"] for r in rs])
        if small <= max(rs[0].get("twin_floor") or 0, rs[0]["least"]):
            continue
        ratios = [r["p95"] for r in rs]
        mid = round(median(ratios), 3)
        lo, hi = median_interval(ratios)
        first = {k: v for k, v in rs[0].items() if k not in ("least", "twin_floor")}
        out[name] = {**first, "p50": mid, "p95": mid, "god_p95": round(median([r["god_p95"] for r in rs]), 4),
                     "small_p95": round(median([r["small_p95"] for r in rs]), 4), "paired": True, "rounds": len(rs),
                     "ci_lo": round(lo, 3), "ci_hi": round(hi, 3), "ci_width": round(hi - lo, 3),
                     "round_ratios": ratios, "measure_version": max(r["measure_version"] for r in rs)}
    return out


def paired_settled(rounds):
    """Whether the paired rounds so far are enough (pure): each board row (GOD_PAIRED_BOARD_RE) has a median over
    GOD_PAIRED_MIN_ROUNDS or more rounds whose 95% interval is narrower than GOD_PAIRED_CI_WIDTH."""
    if len(rounds) < GOD_PAIRED_MIN_ROUNDS:
        return False
    # Every board row the rounds measured must have its median, not just the ones that did: a board row with no
    # median (heap settled, token and thought short of rounds) stopped the rounds at five at 83b6f50f.
    measured = {n for each in rounds for n in _paired_round_ratios(each) if GOD_PAIRED_BOARD_RE.match(n)}
    published = paired_ratio_rows(rounds)
    return bool(measured) and all(n in published and published[n]["ci_width"] < GOD_PAIRED_CI_WIDTH
                                  for n in measured)


def _paired_round_ratios(each):
    """One paired round's {webui.god_ratio.<twin>: row} (pure), with no least-twin cut (paired_ratio_rows judges
    that on the rounds' median) and the twin's floor and least kept as twin_floor and least for it."""
    rows = each.get("rows") if isinstance(each, dict) else None
    return god_ratio_rows(webui_rows(rows), least_twin=False)


def god_ratio_rows(rows, least_twin=True):
    """{webui.god_ratio.<twin>: row} for each god row with an ordinary twin in ROWS (pure): god p95 / twin p95, unit
    x, budget GOD_RATIO_MAX. Rows of another unit, slopes and per-operation rows, and twins at or under their noise
    floor get none. With least_twin False that last cut is left to the caller, and each row carries the twin's floor
    and least value (twin_floor, least)."""
    out = {}
    for name, god in rows.items():
        m = re.match(r"^webui\.([a-z0-9_]+)\.god\.(.+)$", name)
        if not m:
            continue
        twin_name = f"webui.{m.group(1)}.{m.group(2)}"
        twin = rows.get(twin_name)
        unit = god.get("unit") or "ms"
        if not twin or unit != (twin.get("unit") or "ms") or unit not in GOD_RATIO_UNITS or GOD_RATIO_SKIP_RE.search(name):
            continue
        small, big = twin.get("p95"), god.get("p95")
        if not isinstance(small, (int, float)) or not isinstance(big, (int, float)) or small <= 0:
            continue
        least = GOD_RATIO_MIN_RATE if name.endswith("_per_s") else GOD_RATIO_MIN[unit]
        if least_twin and small <= max(twin.get("floor") or 0, least):
            continue
        ratio = round(big / small, 3)
        version = max(god.get("measure_version") or DIFF_LEGACY_VERSION, twin.get("measure_version") or DIFF_LEGACY_VERSION)
        key = f"webui.god_ratio.{m.group(1)}.{m.group(2)}"
        out[key] = {"p50": ratio, "p95": ratio, "unit": "x", "budget": GOD_RATIO_MAX, "floor": 0.1,
                    "measure_version": version, "god_p95": big, "small_p95": small}
        if not least_twin:
            out[key].update(twin_floor=twin.get("floor") or 0, least=least)
    return out


def report_is_incomplete(part, report):
    """Whether a completed bench report explicitly says its coverage is incomplete.

    Budget parts run without ``--gate`` so a perf-cron step can publish its
    measurements and keep the issue tracker non-blocking. Their receipt still
    carries the completeness verdict; retain measured rows for diagnostics but
    keep the overall measurement from becoming a new last-good baseline.
    Older reports and non-budget parts have no such field and remain complete. The web-ui part's report is
    incomplete when a bench of web-ui-suite.ts failed (its `failed`, copied there by cmd_run_linux_part).
    """
    return part.get("kind") in ("budgets", "webui") and isinstance(report, dict) and bool(report.get("incomplete"))


def incomplete_why(report, limit=3):
    """What a report's `incomplete` says, short enough for the issue: its first entries, each on one line. A
    budgets entry is {name: the manifest row's pattern, reason}; a workspace-scaling one names its probe and exit
    code or what is missing; a web-ui one is a line already. Paths are left out."""
    items = report.get("incomplete") if isinstance(report, dict) else None
    items = items if isinstance(items, list) else [items] if items else []

    def one(item):
        if not isinstance(item, dict):
            return str(item)
        if "name" in item:
            return f"{str(item['name']).replace(chr(92) + '.', '.')}: {item.get('reason') or 'incomplete'}"
        return " ".join(f"{k} {v}" for k, v in item.items() if k != "report" and isinstance(v, (str, int, float)))
    shown = [one(item)[:120] for item in items[:limit]]
    return "; ".join(shown) + (f"; and {len(items) - limit} more" if len(items) > limit else "")


def frame_sensitive(name, row):
    """A row whose value depends on the display refresh (frame intervals, frame counts). Dropped frames count too: a
    frame deadline of 8.3 ms misses more often than one of 16.7 ms, so the first 120 Hz run after a 60 Hz baseline
    would open the issue for a display change (f751c486080: a display change never opens the issue)."""
    name = base_row(name)
    return (row.get("unit") == "frames" or name.endswith((".frame", "longest_frame", ".missed", ".dropped", ".over_8_33")))


COUNT_FLOOR = 0.5  # a count row (target 0) regresses by one whole count: one new dropped frame, failed check or run


def count_row(name, row):
    """A count with target 0 (dropped frames, perf-gate failed checks, launch runs that never sent a mark)."""
    name = base_row(name)
    return row.get("unit") in ("frames", "checks", "runs") or name.endswith((".missed", ".dropped"))


def row_floor(name, row):
    """The noise floor a row's change must pass; a count row's is under one count, so 0 -> 1 regresses."""
    floor = row.get("floor", 1.0)
    return min(floor, COUNT_FLOOR) if count_row(name, row) else floor


def same_refresh(a, b):
    """Two known refresh periods (ms) within 20 %. An unknown refresh is never the same as anything, itself
    included: a frame row whose display is not known (a VDISPLAY-FALLBACK run on a panel of unknown rate, a bench
    that printed no refresh) is not compared."""
    return bool(a) and bool(b) and abs(a - b) <= 0.2 * max(a, b)


def row_refresh(row, refresh_ms):
    """The display refresh (ms) a row was measured at: its own `refresh_ms` when the row carries the key (None: its
    part saw no refresh), else the measurement's."""
    return row["refresh_ms"] if "refresh_ms" in row else refresh_ms


def drop_row(name, row):
    """A count of dropped frames (judged in frames, target 0)."""
    name = base_row(name)
    return row.get("unit") == "frames" or name.endswith((".missed", ".dropped"))


def comparable(name, row, base, refresh_ms, base_refresh_ms):
    """Whether a frame-sensitive row can be judged against its reference. Frame intervals: only at the same known
    refresh. Dropped frames: also on a slower display than the reference's (a frame deadline of 16.7 ms misses no
    more often than one of 8.3 ms, so a new drop on a VDISPLAY-FALLBACK run on a 60 Hz panel is real), but not on a
    faster one (the first 120 Hz run after a 60 Hz baseline must not open the issue, f751c486080)."""
    now, then = row_refresh(row, refresh_ms), row_refresh(base, base_refresh_ms)
    if same_refresh(now, then):
        return True
    return drop_row(name, row) and bool(now) and bool(then) and now > then


def refresh_skipped(rows, base_rows, refresh_ms, base_refresh_ms):
    """The frame rows find_regressions leaves out (measured, not judged): the display refresh changed since the
    reference run (dropped frames: it got faster), or one of the two is not known."""
    return sorted(n for n, r in rows.items() if frame_sensitive(n, r) and n in base_rows
                  and not comparable(n, r, base_rows[n], refresh_ms, base_refresh_ms))


def target_of(name, row, refresh_ms):
    """The row's target p95: latency 10 ms; a frame row one display refresh (the row's own when it has one); counts
    0; diff, launch, web UI, CEF resize, terminal key-to-echo and main-thread rows their budget (a web UI row without a target has none)."""
    refresh_ms = row_refresh(row, refresh_ms)
    unit = row.get("unit") or "ms"
    name = base_row(name)
    if name.startswith("workspace_scaling."):
        # Scaling rows are judged only by their 1000-vs-baseline ratio. Their absolute
        # latency is intentionally advisory and must not inherit the generic 10 ms target.
        return None
    if name.startswith(("diff.", "launch.", "webui.", "cloud.", "terminal.key_to_echo.", "cef_resize.")):
        return row.get("budget")
    if unit in ("frames", "checks") or name.endswith(".dropped"):
        return 0
    if name.endswith(".over_8_33"):
        return None  # a count of frames longer than a 120 Hz frame: compared with the last good run only
    if unit == "ms":
        if name.endswith(".frame") or name.endswith("longest_frame"):
            if not refresh_ms:
                return None  # an unknown display: no frame target (a 60 Hz guess would hide a 120 Hz miss)
            return round(refresh_ms * 1.25, 2)  # a quarter frame of jitter; a drop is a whole frame
        if name.endswith((".main_ms_max", ".main_ms_p95")):
            return row.get("budget")
        return LATENCY_TARGET_MS
    return row.get("budget")


def over_target(name, row, refresh_ms):
    t = target_of(name, row, refresh_ms)
    return t is not None and row.get("p95") is not None and row["p95"] > t


def version_changed(rows, base_rows):
    """The rows measured another way than their reference (pure), so such a row is not compared and the tip
    measurement rebases it: a Mac row with another split-spring.sh measurement version (review 1 of the confirm rule:
    the version gated which commits run, not the baseline; a reference stored before rows carried the version measured
    with LEGACY_MEASURE_VERSION), or any row whose part ran with another part_config (this file's args for the part;
    review 2 of 8af6ea46de5, finding 10). A reference stored before rows carried a part_config is not known to differ."""
    out = []
    for n, r in rows.items():
        now = r.get("measure_version")
        base = base_rows.get(n)
        if base is None:
            continue
        if isinstance(now, int):
            then = base.get("measure_version", LEGACY_MEASURE_VERSION if mac_host(n) else DIFF_LEGACY_VERSION)
            if isinstance(then, int) and then != now:
                out.append(n)
                continue
        if isinstance(r.get("part_config"), str) and isinstance(base.get("part_config"), str) \
                and r["part_config"] != base["part_config"]:
            out.append(n)
    return sorted(out)


# A busy runner can't make a Linux row regress by accident (Leo, 2026-11-09: "we should be able to normalize based off
# load. and for a lot of situations, load shouldn't even necessarily affect it by that much"). host_contention spins
# this process for SPIN_S of wall time and reads the CPU time it got: 1 on a host with a free core, and wall / CPU
# when every core is taken, which is how much longer any CPU-bound step takes than on that host idle. The part probes
# before and after each bench (none of the bench's processes run then) and divides that bench's time rows by the
# median (rows_of_part); the web-ui part's suite does the same per bench itself (webviews/bench/hostLoad.ts).
# Only a row whose samples are long enough to share the spin's slowdown is scaled (LOAD_SCALED_BENCHES): the sidecar
# reports the median of short 16 MiB reads, which mostly picks reads the scheduler left whole, so dividing it by the
# spin's factor turned a busy run's 89 ms/GiB into 22 and made the next idle 74 a regression (#39309 F1). Its rows
# keep the factor as load, unscaled.
CONTENTION_SPIN_S, CONTENTION_SPINS, CONTENTION_MAX = 0.02, 9, 8.0
LOAD_SCALED_BENCHES = {"stream"}
# How a diff row is normalized, as part of its measure_version (bench version + 100 x this): a change of it rebases the
# bench's rows instead of comparing a scaled value with a raw one (#39353 F1: an old 22.3 scaled sidecar value made the
# next raw 74 a regression). 1: #39309 scaled every diff row; 2: only LOAD_SCALED_BENCHES' rows.
DIFF_LOAD_VERSION = 2


def spin_ratio(spin_s=CONTENTION_SPIN_S):
    """One spin's wall time / the CPU time this process got during it."""
    cpu, start, sink = time.process_time(), time.perf_counter(), 0.0
    while time.perf_counter() - start < spin_s:
        sink += (sink + 1) ** 0.5
    wall, used = time.perf_counter() - start, time.process_time() - cpu
    return wall / used if used > 0 else CONTENTION_MAX


def contention_factor(ratios):
    """The factor to divide a time row by (pure): the median ratio, clamped to 1..CONTENTION_MAX, to 2 decimals."""
    finite = sorted(r for r in ratios if isinstance(r, (int, float)) and r == r)
    if not finite:
        return 1.0
    mid = len(finite) // 2
    median = finite[mid] if len(finite) % 2 else (finite[mid - 1] + finite[mid]) / 2
    return round(min(CONTENTION_MAX, max(1.0, median)), 2)


def host_contention(spins=CONTENTION_SPINS):
    return [spin_ratio() for _ in range(spins)]


def linux_bench_runs(root, part="diff-viewer"):
    """A Linux part's benches in a checkout at root, {name: (argv, cwd, extra env)} (cmd_run_linux_part runs them;
    part_config names them with root ""). diff-viewer: scripts/benchmark-diff-viewer.sh's two benches without their
    budget env. web-ui: the shared web UI perf harness, which runs the web UI benches and prints one JSON report."""
    if part == "web-ui":
        return {"suite": (["bun", "bench/web-ui-suite.ts"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-scale":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "update-one"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-growth":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "state-growth"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-god":
        only = ",".join([b for b in GOD_BENCHES if b not in GOD_SELF_PAIRED] + [f"{b}-god" for b in GOD_BENCHES])
        # `paired` runs in rounds (run_paired_rounds): the god and small chats at once, as god-ratio-ab.sh plays them.
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", only], os.path.join(root, "webviews"), {}),
                "paired": (["bun", "bench/transcript-replay.bench.ts", "--turns", "600", "--only", "long"],
                           os.path.join(root, "webviews"),
                           {"PAIRED": "1", "GOD_PAIRED_ROUNDS": f"{GOD_PAIRED_MIN_ROUNDS}-{GOD_PAIRED_MAX_ROUNDS}"})}
    if part == "web-ui-million":
        only = "million-event-chat,million-event-chat-short"
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", only], os.path.join(root, "webviews"), {})}
    if part == "web-ui-memory":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "chat-pages-memory"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-flat":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "chat-100k-flat"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-scroll-up":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "transcript-scroll-up-scale"],
                          os.path.join(root, "webviews"), {})}
    if part == "web-ui-flat-grown":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "chat-100k-flat-grown"],
                          os.path.join(root, "webviews"), {})}
    if part == "web-ui-ladder":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "sim-ladder"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-fidelity":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "sim-fidelity"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-scroll":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "chat-fast-scroll,sidebar-chats-fling"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-orchestrator":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "orchestrator-16"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-typing":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "composer-typing"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-power-user":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "power-user-bursts"], os.path.join(root, "webviews"), {})}
    if part == "web-ui-settled":
        return {"suite": (["bun", "bench/web-ui-suite.ts", "--only", "settled-page"], os.path.join(root, "webviews"), {})}
    if part == "coord-sim":
        # The release builds first, in a run of their own (each run has its own 30-minute cap), then 300 s of load.
        script = os.path.join(root, COORD_SIM)
        return {"build": (["bash", script, "build-only"], root or ".", {}),
                "suite": (["bash", script, "coordinators=3", "rate=10", "seconds=300", "fanin=50,200", "fanin_window=60"],
                          root or ".", {})}
    if part == "chat-disk" or part == "terminal-scroll":
        script = os.path.join(root, CHAT_DISK if part == "chat-disk" else TERMINAL_SCROLL)
        return {"build": (["bash", script, "build-only"], root or ".", {}), "suite": (["bash", script], root or ".", {})}
    if part == "cloud-claim":
        return {"suite": (["python3", os.path.join(root, CLOUD_CLAIM)], root or ".", {})}
    if part == "daemon-restart":
        script = os.path.join(root, DAEMON_RESTART)
        return {"build": (["bash", script, "build-only"], root or ".", {}), "suite": (["bash", script], root or ".", {})}
    if part == "chat-search":
        script = os.path.join(root, CHAT_SEARCH)
        return {"build": (["bash", script, "build-only"], root or ".", {}), "suite": (["bash", script], root or ".", {})}
    if part == "infinite-items":
        # The release build first, in a run of its own: each run has its own 30-minute cap (linux_run_seconds) and the
        # linux job's cap covers both (linux_job_minutes). A cold build of acpmux, cmux-tui and its Zig terminal engine
        # outlasted 38 minutes on a 4-vCPU runner (2026-11-17); its leg runs on the one cmux-linux label like the others.
        # The suite's build is then a no-op; its rows are the part's (a webui part keeps the last run's).
        script = os.path.join(root, INFINITE_ITEMS)
        return {"build": (["bash", script, "build-only"], root or ".", {}),
                "suite": (["bash", script, "pages=0", "days=1", "--window=5"], root or ".", {})}
    return {
        "sidecar": ([os.path.join(root, "scripts/run-diff-sidecar-cargo.sh"), "run", "--quiet", "--release", "--locked",
                     "--manifest-path", os.path.join(root, "Native/DiffSidecar/Cargo.toml"), "--bin", "cmux-diff-sidecar",
                     "--features", "benchmark", "--", "benchmark", "16777216", "20"], root or ".", {}),
        "stream": (["bun", "run", "benchmark"], os.path.join(root, "webviews"),
                   {"CMUX_DIFF_BENCH_ITERATIONS": "10", "CMUX_DIFF_BENCH_RENDER_APP": "1"}),
    }


def part_config(name):
    """What a part measures with in this file (pure): a short hash of its split-spring.sh args, or of the Linux
    part's bench commands. Its rows carry it (record_part stores it with the done part), so a change of the args
    rebases them (version_changed) instead of comparing two configurations. run_seconds and --vdisplay-hold are caps,
    not what is measured, and stay out of it."""
    what = linux_bench_runs("", name) if is_linux_part(name) else PART_BY_NAME[name].get("args")
    return hashlib.sha256(json.dumps(what, sort_keys=True).encode()).hexdigest()[:12]


def os_changed(rows, base_rows):
    """The rows measured on another macOS (major.minor) than their reference (pure): the same host after an update or
    a re-image measures differently, so such a row is not compared; the tip measurement rebases it. A reference that
    carries no macOS (stored before rows carried one) is not known to differ."""
    out = []
    for n, r in rows.items():
        now, then = macos_minor(r.get("macos")), macos_minor((base_rows.get(n) or {}).get("macos"))
        if now and then and now != then:
            out.append(n)
    return sorted(out)


NO_REFERENCE = "over target, no reference on this host"


def find_regressions(rows, base_rows, refresh_ms, base_refresh_ms, budgets_mod):
    """Rows worse than the last good run: past perf-budgets' 10 % and floor rule, or newly over target. A frame row
    measured at another display refresh than its last good value, or a row measured on another macOS or measurement
    version, is not compared
    (the next good run rebases it). A row with no reference (its first value on this host) is listed only when it is
    over its target, with base None and why NO_REFERENCE: it has no culprit range, but it is not a silent pass."""
    skipped = (set(refresh_skipped(rows, base_rows, refresh_ms, base_refresh_ms)) | set(os_changed(rows, base_rows))
               | set(version_changed(rows, base_rows)))
    rows = {n: r for n, r in rows.items() if n not in skipped and not REPORT_ONLY_ROW_RE.match(base_row(n))}
    listed = [{"name": n, "p95": r["p95"], "floor": row_floor(n, r)} for n, r in rows.items()]
    worse = {r["name"]: r for r in budgets_mod.compare(listed, {n: b["p95"] for n, b in base_rows.items() if b.get("p95") is not None})}
    out = []
    for name in sorted(rows):
        row, base = rows[name], base_rows.get(name)
        if not base or base.get("p95") is None:
            if over_target(name, row, refresh_ms):
                out.append({"name": name, "p95": row["p95"], "base": None, "unit": row.get("unit", "ms"),
                            "target": target_of(name, row, refresh_ms), "refresh_ms": row_refresh(row, refresh_ms),
                            "why": NO_REFERENCE})
            continue
        crossed = (over_target(name, row, refresh_ms) and not over_target(name, base, base_refresh_ms)
                   and row["p95"] - base["p95"] > row_floor(name, row))
        if name in worse or crossed:
            # floor: outside_spread's margin is the row's own noise floor, not a default.
            out.append({"name": name, "p95": row["p95"], "base": base["p95"], "unit": row.get("unit", "ms"),
                        "target": target_of(name, row, refresh_ms), "refresh_ms": row_refresh(row, refresh_ms),
                        "floor": row_floor(name, row),
                        "why": "worse than last good" if name in worse else "newly over target"})
    return out


# ---------- plan (pure parts) ----------

def new_measurement(sha, kind, parts, t, bisect_range=None):
    m = {"sha": sha, "kind": kind, "started_at": iso(t), "parts_todo": list(parts), "parts": {}}
    if bisect_range:
        m["bisect_range"] = {"good": bisect_range["good"], "bad": bisect_range["bad"]}
    return m


def part_args(part, run_seconds):
    """split-spring.sh's args for a part: a part on the virtual display holds it no longer than the part may run,
    so a step killed outright does not leave it as its host's main display."""
    args = list(part["args"])
    if any(a.startswith("--vdisplay=") for a in args):
        args.append(f"--vdisplay-hold={int(run_seconds)}")
    return args


def is_linux_part(name):
    return PART_BY_NAME[name].get("where") == "linux"


def with_build(parts):
    """A measurement's parts in order: the build first whenever a fleet part needs the app."""
    fleet = [p for p in parts if p != "build" and not is_linux_part(p)]
    return (["build"] if fleet else []) + [p for p in parts if p != "build"]


def unread_parts(state):
    """The parts (build aside), Mac and Linux, that never produced a reading in the state (pure): no stored rows
    (state['part_stored'], store_part_rows) and no row of theirs in state['part_rows'] or state['row_history'].

    Linux parts count too (2026-11-24: web-ui-orchestrator, cmux#54205, merged after tip b76703549055, which had
    measured 13 of its 45 parts in 229 h; a Linux part runs only in a measurement whose commit has its bench, so NOW's
    competitive.orchestrator.p99_frame_ms_16_children read unknown until that tip ended)."""
    read = set(state.get("part_stored") or {}) if isinstance(state.get("part_stored"), dict) else set()
    for key in ("part_rows", "row_history"):
        if isinstance(state.get(key), dict):
            read |= {part_for_row(name) for name in state[key] if isinstance(name, str)}
    return [p["name"] for p in PARTS if p["name"] != "build" and p["name"] not in read]


def unread_missing(state, cur):
    """The unread parts (unread_parts) the tip measurement in flight cannot run: its commit predates them (pure).
    Empty unless it still has a Mac part to do."""
    if not cur or cur.get("kind") != "tip" or not needs_mac(cur):
        return []
    return [p for p in unread_parts(state) if p not in cur.get("parts", {}) and p not in cur.get("parts_todo", [])]


def supersede_for_unread(state, t, newest, supported_parts):
    """End the Mac parts still to do of the tip measurement in flight as 'superseded' when a part that never produced a
    reading (unread_missing) runs at newest, the newest measurable commit with a published cmux-tui tree (plan): the
    measurement finishes with the parts that ran, as after no_host_for_tip, and the next tip, which has the part,
    measures it first (part_order). Once per part: every newer tip has it. A measurement younger than
    SUPERSEDE_AFTER_HOURS keeps its parts. Returns why, or None.

    2026-11-22: tip 9a55953f had measured 24 of its 28 parts in 165 h, and chat-size (cmux#48916, merged after it)
    had never run, so NOW's infinite_chat_size_ratio_max read unknown for days."""
    cur = state.get("current")
    gave = cur.get("superseded") if isinstance(cur, dict) and isinstance(cur.get("superseded"), dict) else None
    if gave and cur.get("parts_todo"):
        # Its Linux parts may still run, for SUPERSEDED_LINUX_HOURS: the newer tip measures them again anyway, and
        # a Linux request the build controller never answers otherwise held the measurement to ABANDON_WALL_HOURS
        # while the newer tip, with the unread part, waited (tip 12aa19c2, 2026-11-23: Mac parts superseded, then
        # web-ui-growth unanswered 23 h, so chat-size never ran). A record with no `at` predates this bound: ends now.
        since = parse_started(gave.get("at"))
        if since and hours_between(since, t) < SUPERSEDED_LINUX_HOURS:
            return None
        for name in list(cur["parts_todo"]):
            cur["parts"][name] = {"state": "superseded", "reason": gave.get("why") or "superseded"}
        cur["parts_todo"] = []
        return gave.get("why") or "superseded"
    missing = unread_missing(state, cur)
    if not missing or not newest:
        return None
    # Only a measurement a day old gives way: parts land most days, so giving way at once restarted every Mac pass
    # before it finished (tip 12aa19c2, 2026-11-22: 4 Mac parts done, 17 superseded for tabs and typing 12 h in,
    # chat-size among them). Wall time, not active_hours: the stall this fixes was yielding to the fleet.
    # The hold protects a Mac pass that is making headway. One that finished no Mac part (the build aside) has none to
    # lose, so it gives way at once (tip b76703549055, 2026-11-24: 23 h in, 20 of them yielded to the fleet, its only
    # Mac part launch-dock yielded, while web-ui-orchestrator, merged after it, kept NOW's
    # competitive.orchestrator.p99_frame_ms_16_children unknown).
    mac_done = any(name != "build" and not is_linux_part(name) and (rec or {}).get("state") == "done"
                   for name, rec in cur.get("parts", {}).items())
    if mac_done and hours_between(parse_iso(cur["started_at"]), t) < SUPERSEDE_AFTER_HOURS:
        return None
    have = [p for p in missing if p in supported_parts(newest)]
    if not have:
        return None
    why = f"{', '.join(have)} never produced a reading; {newest[:12]} has it"
    for name in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
        cur["parts"][name] = {"state": "superseded", "reason": why}
        cur["parts_todo"].remove(name)
    cur.pop("host_asked_since", None)
    end_yield(cur, t)
    cur["superseded"] = {"by": newest, "why": why, "at": iso(t)}
    return why


def part_order(state, todo, t):
    """The order a tick takes a measurement's parts to do in (pure): the build first (every other Mac part reuses its
    app), then each part whose newest stored rows (state['part_stored'], store_part_rows) are older than
    PART_STALE_HOURS, oldest first, then the rest in their PARTS order. A part with no stored rows yet goes before
    the stale ones, and one with no row at all before those. A yielded part stays first in todo, so without this a part that keeps
    yielding, or a measurement dropped before its tail, starved the last parts: throughput, the 13th Mac part, went
    38 h without a row (2026-11-19), and terminal-scroll, added last, kept its place behind every stale part and never
    ran (2026-11-21)."""
    stored = state.get("part_stored") if isinstance(state.get("part_stored"), dict) else {}
    never, stale = [], []
    for i, name in enumerate(todo):
        if name == "build":
            continue
        e = stored.get(name)
        at = parse_iso(e.get("at")) if isinstance(e, dict) else None
        if not at:
            never.append(name)
        elif hours_between(at, t) > PART_STALE_HOURS:
            stale.append((at, i, name))
    # Of those, a part with no row anywhere (row_history, last, part_rows) goes first: part_stored is newer than most
    # rows, so on 2026-11-22 it named 24 of 31 parts, and terminal-scroll, with no row at all, was fifth of the Linux
    # ones (about 10 h of Linux parts at 2 h each, past ABANDON_HOURS).
    if never:
        names = set(state.get("row_history") or {}) | set((state.get("last") or {}).get("rows") or {}) \
            | set(state.get("part_rows") or {})
        seen = {part_for_row(n) for n in names}
        never = [n for n in never if n not in seen] + [n for n in never if n in seen]
    # A part with no stored rows that ran and failed in the newest tip measurement goes after the stale ones: it would
    # otherwise stay first in every measurement, since a failure stores nothing. On 2026-11-24 seven such Linux parts
    # (coord-sim with no shapes file, web-ui-flat timing out, ...) were ahead of web-ui-god, whose rows were 2.6 days
    # old and which two measurements in a row ended at their bound before reaching.
    failing = ran_failed(state)
    stale_names = [n for _, _, n in sorted(stale)]
    first = [n for n in never if n not in failing] + stale_names + [n for n in never if n in failing]
    return [n for n in todo if n == "build"] + first + [n for n in todo if n != "build" and n not in first]


# A failed_why of a history entry from before ran_failed: run-linux-part's own failure ("NAME: exit N", "NAME: timed
# out after N s"), not a part that never ran.
RAN_FAILED_WHY = re.compile(r"^[a-z0-9-]+( gen)?: (exit -?\d+|timed out after |.*No such file)")


def ran_failed(state):
    """The parts that ran and failed in the newest tip measurement (pure): its history entry's ran_failed, else for an
    older entry the failed_why reasons that are a run's own failure (RAN_FAILED_WHY)."""
    for entry in reversed(state.get("history") or []):
        if not isinstance(entry, dict) or entry.get("kind") != "tip" or "failed_parts" not in entry:
            continue
        if isinstance(entry.get("ran_failed"), list):
            return set(entry["ran_failed"])
        why = entry.get("failed_why") if isinstance(entry.get("failed_why"), dict) else {}
        return {n for n, w in why.items() if RAN_FAILED_WHY.match(str(w))}
    return set()


def measurement_id(cur):
    """What names one measurement; its part files carry it, so a later measurement (of the same commit too) never
    reads them."""
    return f"{cur.get('kind')}:{cur.get('sha')}:{cur.get('started_at')}" if isinstance(cur, dict) else None


def start_yield(cur, t):
    """The measurement waits for the fleet from t (a nightly or dev build waits, or the fleet check said no)."""
    if cur is not None and not cur.get("yield_since"):
        cur["yield_since"] = iso(t)


def end_yield(cur, t):
    """A Mac part ran or was attempted: the time spent yielding since yield_since goes into yield_hours."""
    if cur is not None and cur.get("yield_since"):
        since = parse_iso(cur.pop("yield_since"))
        cur["yield_hours"] = round(cur.get("yield_hours", 0.0) + max(0.0, hours_between(since, t)), 3)


def active_hours(cur, t):
    """Hours since the measurement started, less the time it spent yielding to nightly and dev builds."""
    waited = cur.get("yield_hours", 0.0) + (hours_between(parse_iso(cur["yield_since"]), t) if cur.get("yield_since") else 0.0)
    return hours_between(parse_iso(cur["started_at"]), t) - waited


def disable_mac_parts(cur, reason):
    """Record every Mac part still to do as not run (state 'disabled'): the measurement is then incomplete, so it
    neither resets the stale clock nor becomes the last good run."""
    for name in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
        cur["parts"][name] = {"state": "disabled", "reason": reason}
        cur["parts_todo"].remove(name)


def host_info(state, host):
    """What the state keeps about a Mac host (pure): macos, at and last_part_at (its newest done part),
    unreachable_since (the fleet check reported it offline), waited_at (a measurement gave it up), absent_since (the
    first time the cron missed it with no part on record)."""
    hosts = state.get("hosts") if isinstance(state.get("hosts"), dict) else {}
    info = hosts.get(host)
    return info if isinstance(info, dict) else {}


def mark_host(state, host, **fields):
    """Update the state's entry of a host (other keys kept)."""
    hosts = state["hosts"] = state.get("hosts") if isinstance(state.get("hosts"), dict) else {}
    hosts[host] = {**host_info(state, host), **fields}


def _within(state, host, key, hours, t):
    since = parse_iso(host_info(state, host).get(key) or None)
    return since is not None and hours_between(since, t) < hours


def host_unreachable(state, host, t):
    """The fleet check reported host offline less than HOST_RETRY_HOURS ago (pure)."""
    return _within(state, host, "unreachable_since", HOST_RETRY_HOURS, t)


def host_avoided(state, host, t):
    """No measurement is pinned to host now (pure): it was reported offline (host_unreachable), or a measurement gave
    it up for taking no part less than HOST_WAIT_HOURS ago."""
    return host_unreachable(state, host, t) or _within(state, host, "waited_at", HOST_WAIT_HOURS, t)


def host_last_seen(state, host):
    """When the cron last knew of host (pure): its newest done part, else the first time the cron missed it."""
    info = host_info(state, host)
    return parse_iso(info.get("last_part_at") or info.get("at") or info.get("absent_since") or None)


def host_retired(state, host):
    """The controller said it has no such worker (gone_at, a host_gone result), and the host ran no part since (pure)."""
    info = host_info(state, host)
    return bool(info.get("gone_at") and not (info.get("last_part_at") and info["last_part_at"] > info["gone_at"]))


def host_gone(state, host, t):
    """host left the fleet (pure): the controller said it has no such worker (host_retired), or it ran no part for
    HOST_GONE_HOURS (the caller checks that Mac parts ran elsewhere meanwhile)."""
    if host_retired(state, host):
        return True
    seen = host_last_seen(state, host)
    return seen is not None and hours_between(seen, t) > HOST_GONE_HOURS


def note_host_offline(state, host, reason, t):
    """Mark host unreachable when the fleet check's reason says it cannot take work at all (OFFLINE_REASONS), never
    when it is only busy, wanted or held: a busy host keeps its pin and its ranges (HOST_WAIT_HOURS bounds the wait)."""
    if isinstance(host, str) and HOST_RE.match(host) and any(f"{host} {why}" in (reason or "") for why in OFFLINE_REASONS):
        mark_host(state, host, unreachable_since=iso(t))


def needs_mac(cur):
    """The measurement still has a Mac part to run (pure): only then does the fleet's script version matter."""
    return any(not is_linux_part(p) for p in cur.get("parts_todo") or [])


def rerun_stale_linux(state, cur, t):
    """Put back to do each Linux part the tip measurement in flight already ran whose newest stored rows
    (state['part_stored']) are older than PART_STALE_HOURS, while the measurement still waits on a Mac part and has no
    Linux part left (pure on state). A Linux part takes no Mac, so it need not wait for the Mac parts to end; each part
    runs again at most once per PART_STALE_HOURS (cur['linux_reruns'], else the measurement's start). Returns the parts
    put back.

    2026-11-25: tip b76703549055 ran web-ui-god on 11-24, when its incomplete report stored no row (cmux#55126 fixed
    that), and then waited on Mac parts until its 48 h bound, so NOW's idle_chat_rest_wakeups_per_s stayed 3 days
    stale after the fix merged: a one-minute Linux bench waited behind a two-day measurement."""
    if cur.get("kind") != "tip" or cur.get("closed_at") or not needs_mac(cur):
        return []
    if any(is_linux_part(p) for p in cur.get("parts_todo") or []):
        return []
    stored = state.get("part_stored") if isinstance(state.get("part_stored"), dict) else {}
    reruns = cur.get("linux_reruns") if isinstance(cur.get("linux_reruns"), dict) else {}
    back = []
    for name in list(cur.get("parts") or {}):
        if name not in PART_BY_NAME or not is_linux_part(name):
            continue
        e = stored.get(name)
        at = parse_iso(e.get("at")) if isinstance(e, dict) and e.get("at") else None
        if at and hours_between(at, t) <= PART_STALE_HOURS:
            continue
        last = parse_iso(reruns[name]) if reruns.get(name) else parse_iso(cur.get("started_at"))
        if not last or hours_between(last, t) <= PART_STALE_HOURS:
            continue  # its last run, or the measurement's start, is newer than PART_STALE_HOURS
        back.append(name)
    if back:
        cur["parts_todo"].extend(back)
        cur["linux_reruns"] = {**reruns, **{name: iso(t) for name in back}}
    return back


def drop_dead_measurement(state, t, measurable):
    """End the measurement in flight when it ran too long (ABANDON_HOURS of active time, or ABANDON_WALL_HOURS in
    all) or, while it still has a Mac part to run, the cron no longer measures its commit (another split-spring.sh
    measurement version than the tip's). Returns why, or None. The plan calls it before it looks for a new commit, so
    a dropped measurement is replaced in the same tick (cmd_plan then deletes its part files).

    An abandon blames neither the commit nor a host unless the commit itself could not be judged: a bisect step's
    commit goes into its range's skip list (`git bisect skip`) only when one of its parts failed on it (its build, or a
    part that ran and failed), never when its parts were only waiting for the fleet (that commit is still measurable,
    and skipping it could keep the range from narrowing to the culprit). No host is marked: only the fleet check's
    offline report does that (note_host_offline), and a pinned measurement gives a busy host up after HOST_WAIT_HOURS
    (give_up_host)."""
    cur = state.get("current")
    why = None
    over = cur and (active_hours(cur, t) > ABANDON_HOURS or hours_between(parse_iso(cur["started_at"]), t) > ABANDON_WALL_HOURS)
    if over and close_at_bound(cur, t):
        return "closed at its bound"
    if over and not (cur.get("closed_at") and hours_between(parse_iso(cur["closed_at"]), t) <= CLOSE_GRACE_HOURS):
        why = "abandoned"
    elif cur and needs_mac(cur) and not measurable(cur["sha"]):
        why = "unmeasurable"
    if why:
        entry = {"sha": cur["sha"], "kind": cur["kind"], "status": why, "at": iso(t), "parts": sorted(cur.get("parts", {}))}
        if why == "abandoned":
            entry["cause"] = "a part failed on the commit" if commit_failed(cur) else "its parts waited for the fleet"
        state.setdefault("history", []).append(entry)
        state["current"] = None
    if why == "abandoned" and cur["kind"] == "bisect" and commit_failed(cur):
        for r in state.get("regressions") or []:
            rng = r.get("range")
            if same_range(rng, cur.get("bisect_range")) and cur["sha"] not in rng.setdefault("skip", []):
                rng["skip"].append(cur["sha"])
    return why


def close_at_bound(cur, t):
    """A tip measurement that reached its bound with a part done ends with what it has (pure on cur): each part
    still to do is recorded as not run (state 'not_run', its reason the bound), so the next decide finishes it and
    the report judges its rows; the measurement ends incomplete instead of abandoned. Returns whether it closed.
    Abandoning threw the whole measurement away: from 2026-11-15 08:03Z the cron finished none for 165 h while each
    one ran 8 to 20 of its 27 parts and was dropped at ABANDON_HOURS. A bisect step still abandons (its verdict needs
    its parts), and so does a measurement with no part done (nothing to judge). cur['closed_at'] holds the close: the
    finish gets CLOSE_GRACE_HOURS before the abandon applies again."""
    if cur.get("kind") != "tip" or not cur.get("parts_todo") or cur.get("closed_at"):
        return False
    if not any(isinstance(p, dict) and p.get("state") == "done" for p in (cur.get("parts") or {}).values()):
        return False
    reason = (f"not run: the measurement reached its bound ({ABANDON_HOURS} h active or {ABANDON_WALL_HOURS} h in "
              "all) and ended with the parts it had")
    for name in cur["parts_todo"]:
        cur["parts"][name] = {"state": "not_run", "reason": reason}
    cur["parts_todo"] = []
    cur["closed_at"] = iso(t)
    return True


def commit_failed(cur):
    """A part of the measurement failed on its commit (pure): its build failed, or a part ran and failed. A part
    refused for its host (it carries a reason: another host, or no host on record) is the fleet's, not the commit's."""
    return any(isinstance(p, dict) and (p.get("state") == "build_failed" or (p.get("state") == "failed" and not p.get("reason")))
               for p in (cur.get("parts") or {}).values())


def batch_parts(state, cur, first, t):
    """The Mac parts a controller request lists after first, in part_order (pure): [first] and the measurement's
    other Mac parts to do, at most BATCH_MAX; [first] alone when there is no other."""
    rest = [p for p in part_order(state, cur["parts_todo"], t) if p != first and not is_linux_part(p)]
    return [first, *rest][:BATCH_MAX]


def host_wait_hours(cur):
    """How long the measurement's host may stay silent before give_up_host and no_host_for_tip (pure): HOST_WAIT_HOURS,
    plus the deadline of the batch asked for (cur['batch']), whose results all come when its last part ends."""
    batch = cur.get("batch") if isinstance(cur.get("batch"), dict) else {}
    parts = [p for p in batch.get("parts") or [] if p in PART_BY_NAME]
    if len(parts) < 2:
        return HOST_WAIT_HOURS
    run = sum(PART_BY_NAME[p].get("run_seconds", PART_RUN_SECONDS) for p in parts)
    return HOST_WAIT_HOURS + BATCH_SLACK_HOURS + run / 3600


def give_up_host(state, t):
    """End the pin of the measurement in flight when its host took none of its parts for HOST_WAIT_HOURS since the
    first request to it (cur['host_asked_since'], cleared by every Mac part result), or when the fleet check reported
    the host offline. A tip measurement goes on on any idle measure host; a bisect step ends ('waited': no skip, its
    commit is still measurable). The host is not pinned again for HOST_WAIT_HOURS (host_avoided). Returns why, or None.

    The cron cannot tell a busy host from a fleet that is busy everywhere (the controller route answers a request only
    with a result), so the bound is on the host's silence, not on a reason."""
    cur = state.get("current")
    host = (cur or {}).get("host")
    if not host or not needs_mac(cur):
        return None
    asked = parse_iso(cur.get("host_asked_since") or None)
    offline = host_unreachable(state, host, t)
    wait = host_wait_hours(cur)
    if not offline and not (asked and hours_between(asked, t) > wait):
        return None
    why = f"{host} is offline" if offline else f"{host} took no part for {round(wait, 1):g} h"
    if not offline:
        mark_host(state, host, waited_at=iso(t))
    cur.pop("host_asked_since", None)
    cur.pop("batch", None)
    if cur["kind"] == "bisect":
        state.setdefault("history", []).append({"sha": cur["sha"], "kind": "bisect", "status": "waited", "at": iso(t),
                                                "parts": sorted(cur.get("parts", {})), "note": why})
        state["current"] = None
    else:
        cur.pop("host")
        cur.setdefault("gave_up", []).append({"host": host, "at": iso(t), "why": why})
    return why


def no_host_for_tip(state, t):
    """End the Mac parts still to do of the tip measurement in flight as 'no_host' when no measure host took one for
    HOST_WAIT_HOURS while any host could (cur['host_asked_since']: the first request since the last Mac part result):
    the measurement is unpinned, or it gave a host up before (give_up_host) and the host it is pinned to again went
    silent. A pinned tip that never gave its host up goes to give_up_host first (any idle host may take it). The
    measurement then finishes with the parts that ran: their rows are stored as usual, a no_host part's rows keep
    their last value and age (the measurement is incomplete, so the stale clock keeps running), and the next tick
    starts a newer tip, whose parts run wherever they can. Returns why, or None.

    2026-11-16 00:59Z: tip 83b6f50f waited on cmux20-bench (reserved, given up twice) for memory-agents and throughput
    until the 48 h ABANDON_WALL_HOURS cap, and no newer tip started meanwhile: chat_100k_flat_ratio_max never got a
    row although cmux#44161 fixed its Linux part on a newer commit, and every other row went stale with it."""
    cur = state.get("current")
    if not cur or cur.get("kind") != "tip" or not needs_mac(cur):
        return None
    asked = parse_iso(cur.get("host_asked_since") or None)
    wait = host_wait_hours(cur)
    if not (asked and hours_between(asked, t) > wait):
        return None
    host = cur.get("host")
    if host and not cur.get("gave_up"):
        return None
    tried = sorted({g.get("host") for g in cur.get("gave_up") or [] if isinstance(g, dict) and g.get("host")} | {host} - {None})
    why = f"no measure host took a Mac part for {round(wait, 1):g} h" + (f" (gave up {', '.join(tried)})" if tried else "")
    if host:
        mark_host(state, host, waited_at=iso(t))
        cur.pop("host")
    for name in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
        cur["parts"][name] = {"state": "no_host", "reason": why}
        cur["parts_todo"].remove(name)
    cur.pop("host_asked_since", None)
    cur.pop("batch", None)
    end_yield(cur, t)
    cur["no_host"] = {"at": iso(t), "why": why}
    return why


def tip_pin_host(state, t, idle_hosts=None):
    """The Mac host a new tip measurement is pinned to (pure): the host of the oldest Mac row waiting for its confirming
    run (state['pending']: only a run there can confirm or clear it, so its run comes first), else of the earliest open regression of a Mac row,
    unless that host is avoided now (offline, or a measurement just gave it up: host_avoided) or gone (host_gone). A
    host's rows are judged only on that host, so a tip measured elsewhere can never confirm or clear them. None: any
    idle measure host.

    idle_hosts: the measure hosts the controller called idle this tick (controller_idle_hosts), or None when it was not
    read. With it, a host not in it is not pinned: the tip goes to any idle measure host. Every Mac row was
    @cmux20-bench, so every tip pinned there; it refused claims for 3.5 days from 2026-11-18 and was leased about 80 % of
    2026-11-22, and each time give_up_host waited HOST_WAIT_HOURS before letting go, then supersede_for_unread dropped
    the parts done (cmuxterm-hq docs/findings/2026-11-22-perf-cron-coverage.md: 2 of 21 Mac parts in 5 days)."""
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else {}
    waiting = sorted((str((v or {}).get("at") or ""), n) for n, v in pending.items() if isinstance(n, str))
    regs = [r for r in state.get("regressions") or [] if isinstance(r, dict) and isinstance(r.get("name"), str)]
    regs.sort(key=lambda r: (str((r.get("first_bad") or {}).get("measured_at") or ""), r["name"]))
    for name in [n for _, n in waiting] + [r["name"] for r in regs]:
        host = mac_host(name)
        if host and HOST_RE.match(host) and not host_avoided(state, host, t) and not host_gone(state, host, t) \
                and (idle_hosts is None or host in idle_hosts):
            return host
    return None


def tip_due(state, t):
    """A tip measurement may start: none finished (or was dropped) in the last TIP_EVERY_HOURS, or no complete tip
    measurement finished within STALE_HOURS (stale_hours). Only consulted while a bisect step is also possible.

    Stale first: only a tip measurement stores rows (a bisect step only narrows its range), and cmuxterm-hq's NOW
    Benches reads those rows within 48 h. On 2026-11-21 the rows were 136.8 h old when a tip measurement that waited
    for the fleet was abandoned; that abandon counted as a tip tried, so the next tick started a bisect step instead
    (run 44846739082), and the rows could not refresh before the bisect finished. A bisect against a reference that
    old also judges less than a fresh tip would."""
    if stale_hours(state, t) > STALE_HOURS:
        return True
    times = [(state.get("last_tried") or {}).get("at")]
    times += [h.get("at") for h in state.get("history") or [] if isinstance(h, dict) and h.get("kind") == "tip"]
    times = [parse_iso(x) for x in times if isinstance(x, str)]
    return not times or hours_between(max(times), t) >= TIP_EVERY_HOURS


def wait_for_tree(cur, t, tree_ready):
    """A tip measurement's Mac parts wait for its commit's published cmux-tui tree (a fleet build needs it); its Linux
    parts never do. Returns why the Mac parts wait now, or "" (the tree is published, or no Mac part is left to do).
    Past TREE_WAIT_HOURS of waiting, its Mac parts still to do end as 'no_tree' (not run): the measurement finishes
    with the parts that ran, as after no_host_for_tip, and the next tip starts on a newer commit."""
    if cur.get("kind") != "tip" or not needs_mac(cur) or cur.get("tree_seen"):
        return ""
    if tree_ready(cur["sha"]):
        cur["tree_seen"] = True
        cur.pop("tree_wait_since", None)
        return ""
    since = parse_iso(cur.setdefault("tree_wait_since", iso(t)))
    if hours_between(since, t) <= TREE_WAIT_HOURS:
        return f"the Mac parts wait for the cmux-tui tree of {cur['sha'][:12]} (since {iso(since)})"
    why = f"no published cmux-tui tree of {cur['sha'][:12]} for {TREE_WAIT_HOURS} h"
    for name in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
        cur["parts"][name] = {"state": "no_tree", "reason": why}
        cur["parts_todo"].remove(name)
    cur.pop("tree_wait_since", None)
    return ""


def decide(state, t, candidate, bisect, supported_parts, github_busy, measurable=lambda sha: True, mac_disabled=None,
           controller_route=False, tree_ready=lambda sha: True, newest=None, idle_hosts=None):
    """The tick's work: {'action': 'part'|'none'|'finish', 'part': a fleet part or '', 'linux_parts': [every Linux
    part still to do]}. The Linux parts run at once, one runner each (the workflow's linux matrix): one at a time, a
    measurement's ten Linux parts took ten ticks, each paying a runner queue wait of up to hours.
    May set state['current'] (a new measurement). With both a candidate and a bisect step, the bisect goes first
    unless a tip measurement is due (tip_due): a newer tip always exists, so 'bisect when idle' would never bisect.
    candidate: the newest measurable tip commit newer than the last one measured (or None).
    bisect: {'sha', 'range': {good, bad}, 'rows': [row names]}: a measurable commit inside one group of regressed
    rows' culprit range (or None); the step measures only the parts of those rows.
    supported_parts(sha) -> the PARTS names the commit can run. github_busy: a reason string or None (it holds
    back the Mac parts of a measurement pinned to a host that runs CI jobs; any other goes to the bench host, and
    the Linux part takes no Mac). measurable(sha): the fleet would still run the commit
    (its scripts/measure/split-spring.sh is the reviewed one). mac_disabled: why no Mac part can run at all (no
    gateway runner label), or None: a tip measurement records its Mac parts as not run (so it is incomplete), and a
    bisect step measures only Linux rows. controller_route: the Mac part goes to the build controller as a request
    that has no answer until the part's result run, so the time from the request to the result is the fleet's wait
    (start_yield; record_part ends it), not the measurement's active time. tree_ready(sha): the commit's cmux-tui
    tree is published; a tip whose tree is not runs only its Linux parts until it is (wait_for_tree). newest: the newest
    measurable commit with a published tree, given while the tip in flight lacks a part that never produced a reading
    (unread_missing); its Mac parts then end so the next tip measures that part first (supersede_for_unread).
    idle_hosts: the measure hosts the controller called idle (controller_idle_hosts), or None; a new tip pins only to
    one of them (tip_pin_host). A bisect step keeps its host: its rows are judged only there."""
    drop_dead_measurement(state, t, measurable)
    no_host = no_host_for_tip(state, t)
    give_up_host(state, t)
    superseded = None if mac_disabled else supersede_for_unread(state, t, newest, supported_parts)
    cur = state.get("current")
    if not cur and bisect and not (candidate and tip_due(state, t)):
        regressed = {part_for_row(name) for name in bisect["rows"]}
        parts = [p for p in supported_parts(bisect["sha"]) if p in regressed and not (mac_disabled and not is_linux_part(p))]
        if parts:
            state["current"] = cur = new_measurement(bisect["sha"], "bisect", with_build(parts), t, bisect["range"])
            hosts = {mac_host(name) for name in bisect["rows"]} - {None}
            if len(hosts) == 1 and HOST_RE.match(next(iter(hosts))):
                cur["host"] = hosts.pop()  # the regressed rows' host: a bisect step compares only on it
    if not cur and candidate:
        state["current"] = cur = new_measurement(candidate, "tip", with_build(supported_parts(candidate)), t)
        pin = tip_pin_host(state, t, idle_hosts)
        if pin:
            cur["host"] = pin
    if cur and mac_disabled:
        disable_mac_parts(cur, mac_disabled)
    if cur:
        rerun_stale_linux(state, cur, t)
    tree_wait = wait_for_tree(cur, t, tree_ready) if cur else ""
    if not cur:
        return {"action": "none", "reason": "nothing new to measure: the newest measurable feat-cmux-next commit "
                                            "was measured, and no regression range to bisect"}
    if not cur["parts_todo"]:
        return {"action": "finish", "sha": cur["sha"],
                "reason": (f"its Mac parts have no host ({no_host}); report only" if no_host else
                           f"its Mac parts gave way ({superseded}); report only" if superseded else "every part ran; report only")}
    todo = part_order(state, cur["parts_todo"], t)  # a part past PART_STALE_HOURS goes first
    linux = [p for p in todo if is_linux_part(p)]
    fleet = "" if tree_wait else next((p for p in todo if not is_linux_part(p)), "")
    done = f"{len(cur['parts'])} of {len(cur['parts']) + len(cur['parts_todo'])} done"
    if tree_wait and not linux:
        return {"action": "none", "sha": cur["sha"], "reason": tree_wait}
    # A nightly or dev build waiting for a Mac holds back only a part that could take a Mac from it. The bench host
    # runs no CI job (it is a controller worker only), so a part there takes nothing: a measurement not pinned to
    # another host goes to it. From 2026-11-13 16:43Z to 11-14 02:29Z a nightly job was queued for a signing runner
    # at every tick, and no Mac part ran while the bench host could have taken each one.
    # A bench host the measurement gave up for its silence (give_up_host) is still asked here: the give-up is for
    # trying another host, and this rule leaves none. 2026-11-15 00:54Z to 02:54Z: no Mac part was asked for.
    # Only the controller's word retires the bench host here (host_retired), never its silence: host_gone's
    # HOST_GONE_HOURS clause assumes Mac parts ran elsewhere meanwhile, and with the bench host the only measure host
    # none did. From 2026-11-18 cmux20-bench refused every claim (not isolated) for 3.5 days; once repaired, it was
    # "gone" by silence, so every tick a nightly waited for a Mac held its parts back and no Mac row could refresh.
    bench_only = bool(github_busy and fleet and cur.get("host") in (None, BENCH_WORKER)
                      and not host_unreachable(state, BENCH_WORKER, t) and not host_retired(state, BENCH_WORKER))
    if github_busy and fleet and not bench_only:
        fleet = ""
        start_yield(cur, t)  # the wait does not count against ABANDON_HOURS
        cur.setdefault("host_asked_since", iso(t))  # ...but it counts for give_up_host (the bench host) and no_host_for_tip
    if not fleet and not linux:
        return {"action": "none", "sha": cur["sha"], "reason": github_busy, "yielded": True}
    if fleet:
        # give_up_host's clock for a pinned host, no_host_for_tip's for any host: cleared by the next Mac part result.
        cur.setdefault("host_asked_since", iso(t))
    if fleet and controller_route:
        start_yield(cur, t)
    what = " and ".join(x for x in (fleet, ", ".join(linux)) if x)
    waits = f"; {tree_wait}" if tree_wait else ""
    if github_busy and bench_only:
        waits = f"; only on {BENCH_WORKER}, which runs no CI job: {github_busy}"
    elif github_busy and linux:
        waits = f"; the Mac parts wait: {github_busy}"
    return {"action": "part", "sha": cur["sha"], "kind": cur["kind"], "part": fleet, "linux_parts": linux,
            "worker": (BENCH_WORKER if bench_only else cur.get("host") or "") if fleet else "",
            "reason": f"{cur['kind']} measurement of {cur['sha'][:12]}: part {what} ({done})" + waits}


def bisect_midpoint(commits, measurable, skip=()):
    """commits: first-parent commits strictly between good and bad, oldest first. The measurable one nearest
    the middle that is not in skip (commits a bisect step could not judge: `git bisect skip`), or None."""
    return bisect_next(commits, measurable, skip)[0]


def bisect_next(commits, measurable, skip=(), start=0, budget=None):
    """bisect_midpoint from a place in its order, judging at most budget commits (None: no bound). The order is
    every commit's, nearest the middle first, skip included, so a place stays valid when a step adds to skip; a
    commit in skip costs nothing. start: how far earlier ticks got (the commits before it were not measurable).
    Returns (the commit or None, the place after the last commit judged)."""
    mid = len(commits) // 2
    order = sorted(range(len(commits)), key=lambda i: (abs(i - mid), i))
    skip, judged, place = set(skip), 0, start
    for place in range(start, len(order)):
        c = commits[order[place]]
        if c in skip:
            continue
        if budget is not None and judged >= budget:
            return None, place
        judged += 1
        if measurable(c):
            return c, place
    return None, len(order)


def bisect_measurable(rows, mac_measurable, supported_parts):
    """Whether a bisect step can judge a group's rows at commit c (returns the predicate; pure): the commit runs
    every part of the rows (supported_parts), and, when a part is a Mac part, the cron measures the commit on the
    fleet (mac_measurable: the tip's split-spring.sh measurement version and a published cmux-tui tree). A group of
    Linux rows needs neither: the diff-viewer and web-ui parts run on a GitHub runner from the commit's own checkout."""
    parts = {part_for_row(name) for name in rows}
    mac = any(p is None or not is_linux_part(p) for p in parts)
    return lambda c: parts <= set(supported_parts(c)) and (not mac or mac_measurable(c))


def bisect_groups(state):
    """The open regressions grouped by culprit range, in the order they regressed: [{'range', 'rows'}]. Rows with
    no range on record are left out."""
    groups = {}
    for r in state.get("regressions") or []:
        rng = r.get("range") or {}
        if rng.get("good") and rng.get("bad"):
            groups.setdefault((rng["good"], rng["bad"]), {"range": rng, "rows": []})["rows"].append(r["name"])
    return list(groups.values())


def same_range(a, b):
    return bool(a) and bool(b) and a.get("good") == b.get("good") and a.get("bad") == b.get("bad")


# ---------- fleet (gateway) ----------

def controller_url():
    if os.environ.get("CMUX_CI_CONTROLLER"):
        return os.environ["CMUX_CI_CONTROLLER"].rstrip("/")
    for path in (os.path.expanduser("~/.local/share/cmux-fleet-client/client.json"),):
        try:
            url = json.load(open(path)).get("controller")
            if url:
                return url.rstrip("/")
        except (OSError, ValueError):
            pass
    return "http://100.89.225.106:18765"


# The controller's public idle-host feed (cmuxterm-hq#19352: GET /perf-cron/hosts.json, beside results.json):
# {"at": RFC 3339, "hosts": {"<worker>": {"idle": bool, "why": "leased" | "running a step" | ...}}}. The plan job runs on
# a runner off the tailnet, so /v1/workers is not readable from it.
CONTROLLER_HOSTS_URL = "https://gh-events.cmux.com/perf-cron/hosts.json"


def idle_hosts_from(raw):
    """The workers the hosts feed calls idle, or None when the answer has no hosts map (pure)."""
    hosts = raw.get("hosts") if isinstance(raw, dict) else None
    if not isinstance(hosts, dict):
        return None
    return {name for name, h in hosts.items() if isinstance(name, str) and isinstance(h, dict) and h.get("idle") is True}


def controller_idle_hosts(url=None, timeout=10):
    """The measure hosts the controller calls idle now, or None when the feed was not read (no route yet, a timeout,
    a bad answer): then nothing changes and tip_pin_host pins as before."""
    try:
        return idle_hosts_from(http_json(url or os.environ.get("PERF_CRON_HOSTS_URL") or CONTROLLER_HOSTS_URL, timeout=timeout))
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"perf-cron: the controller's idle hosts were not read ({error!r}); a tip pins as before")
        return None


def http_json(url, timeout=30):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-perf-cron"}), timeout=timeout) as r:
        return json.load(r)


# What a measurement step asks the host to have free (the controller's min_free_bytes of a bench or measure job).
MEASURE_MIN_FREE_BYTES = 11811160064


def disk_starved(w):
    """Why the worker cannot be leased a measurement step for want of disk, or "" (pure): its free disk is under
    MEASURE_MIN_FREE_BYTES and its heartbeat counts too little evictable for the controller or worker to free it."""
    free = w.get("free_bytes")
    if not isinstance(free, (int, float)) or isinstance(free, bool) or free >= MEASURE_MIN_FREE_BYTES:
        return ""
    evictable = (w.get("disk") or {}).get("evictable_bytes")
    if not isinstance(evictable, (int, float)) or isinstance(evictable, bool):
        evictable = 0
    if free + evictable >= MEASURE_MIN_FREE_BYTES:
        return ""
    return (f"disk {free / 1e9:.1f} GB free of the {MEASURE_MIN_FREE_BYTES / 1e9:.1f} GB a measurement step needs, "
            f"{evictable / 1e9:.1f} GB evictable")


def fleet_verdict(status, workers, jobs, worker, yield_mode, mine=()):
    """None when the fleet lets the perf cron run a part on `worker` now, else the reason it yields.
    status: /v1/status; workers: `cmux-ci workers` ({name: heartbeat}); jobs: /v1/jobs (all recent)."""
    w = (workers or {}).get(worker)
    if not w:
        return f"{worker} is not a controller worker now"
    if not w.get("healthy"):
        return f"{worker} is not healthy"
    starved = disk_starved(w)
    if starved:
        # Healthy and idle, yet the controller leases it nothing: a measurement step asks MEASURE_MIN_FREE_BYTES and the
        # worker has nothing to evict. 2026-11-16: the bench host sat at 10.9 GB free, every request to it queued until
        # the cron gave it up, and no Mac row was stored for 34 h (tabs-keep-speed red).
        return f"{worker} is not healthy: {starved}"
    seen = parse_iso((w.get("last_seen") or "")[:19] + "Z") if w.get("last_seen") else None
    if not seen or hours_between(seen, now_utc()) * 3600 > 180:
        return f"{worker} has not been seen for over 3 minutes"
    if w.get("claim_paused"):
        return f"{worker} takes no work ({w['claim_paused']})"
    for j in jobs or []:
        if j.get("id") in mine or j.get("state") not in ("queued", "leased", "running"):
            continue
        if j.get("worker") == worker or j.get("target_worker") == worker or (j.get("state") == "queued" and "bench" in (j.get("labels") or [])):
            return f"{worker} is busy or wanted: job {j['id'][:12]} ({j.get('script') or j.get('kind')}, {j['state']})"
    other = wanted_by_other(status, set(mine), jobs, worker)
    if other:
        return (f"{worker} is wanted: foreground job {other['id'][:12]} ({', '.join(other.get('labels') or []) or other.get('kind')}) "
                f"queued {round(other.get('wait_seconds') or 0)} s")
    # The worker's heartbeat offers the exclusive class only while nothing runs there and its host lock is free
    # (hq build-fleet/cmd/worker/ci_step.go exclusiveFits; `fits` is left out when empty), and the controller leases
    # a measurement step only to a worker that offers it (controller stepFitsWorker): no fits, no step there.
    if "exclusive" not in (w.get("fits") or []):
        why = f"job {str(w['current_job'])[:12]} runs there" if w.get("current_job") else "a step runs there or its host lock is held"
        return f"{worker} offers no exclusive slot now ({why}); the controller would not place the part there either"
    for q in (status or {}).get("queue") or []:
        if q.get("id") in mine:
            continue
        if q.get("kind") != "ci-step":
            return f"a dev build waits in the controller queue (job {q['id'][:12]}, {q.get('kind')}, {round(q.get('wait_seconds') or 0)} s)"
    if yield_mode == "running":
        for wk in (status or {}).get("workers") or []:
            for r in wk.get("running") or []:
                if r.get("kind") != "ci-step":
                    return f"a dev build runs on {wk['name']} (job {r['id'][:12]}); CMUX_NEXT_PERF_CRON_YIELD=running"
    hold = (status or {}).get("exclusive_hold") or {}
    if hold.get("worker") == worker and hold.get("job_id") not in mine:
        return f"{worker} is reserved for job {str(hold.get('job_id'))[:12]}"
    return None


def wanted_by_other(status, mine, jobs=None, worker=BENCH_WORKER):
    """A queued foreground job that could run on `worker` (the part's host), or None: the perf cron yields to it.
    status: /v1/status (queue entries carry labels, `background`, blocked and placement_wait, but no target worker;
    workers carry their labels). jobs: `cmux-ci status` (/v1/jobs, with target_worker), or None when not read this
    round. A job wants the host when it carries the `bench` label, when every label it needs is one the host
    has, when its blocked or placement_wait text names the host, or when it targets the host."""
    host_labels = set()
    for w in (status or {}).get("workers") or []:
        if w.get("name") == worker:
            host_labels = set(w.get("labels") or [])
    for q in (status or {}).get("queue") or []:
        if q.get("id") in mine or q.get("background"):
            continue
        labels = set(q.get("labels") or [])
        text = f"{q.get('blocked') or ''} {q.get('placement_wait') or ''}"
        if "bench" in labels or (labels and host_labels and labels <= host_labels) or worker in text:
            return q
    for j in jobs or []:
        if j.get("id") in mine or j.get("state") != "queued" or j.get("background"):
            continue
        if j.get("target_worker") == worker:
            return j
    return None


# ---------- GitHub ----------

# The GitHub API calls of this process, by method and path shape (printed at the end of each subcommand). The tick's
# token shares the repository's installation limit with every other workflow (2026-10-24: 'API rate limit exceeded
# for installation' failed two ticks), so the cron keeps its calls few and backs off when GitHub says no.
GH_CALLS = collections.Counter()
# fetch-state leaves this file in the state directory when GitHub refused for the rate limit: the plan and the report
# then do nothing (no state is read, saved or replaced) and the next tick tries again.
RATE_LIMITED = "RATE_LIMITED"


class RateLimited(Exception):
    """GitHub refused a call for the rate limit (403 or 429 with no calls left, a Retry-After, or that message)."""

    # Seconds until GitHub says it takes calls again (Retry-After, or the reset time of a spent limit); None when
    # the refusal does not say.
    wait = None


def limit_wait(error):
    headers = getattr(error, "headers", None) or {}
    try:
        if headers.get("retry-after"):
            return max(0, int(headers.get("retry-after")))
        if headers.get("x-ratelimit-remaining") == "0" and headers.get("x-ratelimit-reset"):
            return max(0, int(headers.get("x-ratelimit-reset")) - int(time.time()))
    except ValueError:
        pass
    return None


def refused_for_the_limit(what, error):
    refused = RateLimited(f"{what}: HTTP {error.code}")
    refused.wait = limit_wait(error)
    return refused


def rate_limited(error):
    if not isinstance(error, urllib.error.HTTPError) or error.code not in (403, 429):
        return False
    headers = error.headers or {}
    if headers.get("x-ratelimit-remaining") == "0" or headers.get("retry-after"):
        return True
    try:
        text = error.read().decode("utf-8", "replace").lower()
    except Exception:  # noqa: BLE001 - an unreadable body is no rate-limit message
        text = ""
    return "rate limit" in text


def gh_shape(path):
    return re.sub(r"/[0-9a-f]{40}(\.\.\.[0-9a-f]{40})?|/\d+", "/N", path.split("?")[0].replace("https://api.github.com", ""))


def gh_request(path, method="GET", body=None, raw=False, timeout=30):
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = path if path.startswith("http") else f"{api}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-perf-cron"})
    GH_CALLS[f"{method} {gh_shape(path)}"] += 1
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = r.read()
    except urllib.error.HTTPError as error:
        if rate_limited(error):
            raise refused_for_the_limit(f"{method} {gh_shape(path)}", error) from error
        raise
    return payload if raw else (json.loads(payload) if payload else {})


def print_calls(cmd):
    """One line with this process's GitHub API calls (the run log shows each tick's cost)."""
    total = sum(GH_CALLS.values())
    detail = ", ".join(f"{n} {k}" for k, n in sorted(GH_CALLS.items()))
    print(f"perf-cron {cmd}: {total} GitHub API call(s){': ' + detail if detail else ''}")


# A fleet runner, named positively: glaeda's labels (glaeda-mini, glaeda-trusted-std-xcode-26.6, glaeda-side-...), or
# `self-hosted` with a macOS label. Anything else is rented or hosted capacity (GitHub's macos-26, Blacksmith,
# Depot, Namespace, Warp, ...), which a perf part never competes with: on 2026-10-24 a dev build waiting 2 h for
# blacksmith-12vcpu-macos-26 held every Mac part back while cmux20-bench was idle.
FLEET_RUNNER_LABEL = re.compile(r"^glaeda-", re.IGNORECASE)
MACOS_LABEL = re.compile(r"^(macos|osx|darwin)$|macos", re.IGNORECASE)


def fleet_mac_job(job):
    """The job's labels name a fleet Mac runner: a glaeda label, or self-hosted with a macOS label. A job with no
    labels on record counts too (it may want a fleet runner; GitHub has not said yet)."""
    labels = [str(label) for label in job.get("labels") or []]
    if not labels:
        return True
    if any(FLEET_RUNNER_LABEL.match(label) for label in labels):
        return True
    return any(label.lower() == "self-hosted" for label in labels) and any(MACOS_LABEL.search(label) for label in labels)


def mac_job_waiting(job):
    """A job queued for a fleet Mac runner (not one waiting on an environment approval)."""
    return job.get("status") == "queued" and fleet_mac_job(job)


FRAME_PACING_WORKFLOW = "cmux-next-frame-pacing.yml"
FRAME_PACING_EVERY_HOURS = 24


def frame_pacing_due(runs, now, busy):
    """Whether the perf cron starts the frame-pacing bench (fling and golden interactions on a 120 Hz virtual
    display, cmux-next-frame-pacing.yml) now (pure): no run of it on feat-cmux-next in the last 24 h, none
    queued or running, and no nightly or dev build waiting for a Mac (busy is None). It left its fixed 09:37
    schedule (2026-10-23), which ran whatever the fleet was doing. Returns (due, reason)."""
    if busy:
        return False, f"frame pacing waits: {busy}"
    for run in runs:
        if run.get("status") in ("queued", "in_progress", "waiting", "requested", "pending"):
            return False, f"frame pacing run {run.get('id')} is {run.get('status')}"
        created = parse_iso((run.get("created_at") or "")[:19] + "Z") if run.get("created_at") else None
        if created and hours_between(created, now) < FRAME_PACING_EVERY_HOURS:
            return False, f"frame pacing ran {round(hours_between(created, now), 1)} h ago (run {run.get('id')})"
    return True, f"no frame pacing run on feat-cmux-next for {FRAME_PACING_EVERY_HOURS} h"


def frame_pacing_runs(repo):
    """The newest runs of the frame-pacing bench on feat-cmux-next."""
    return gh_request(f"/repos/{repo}/actions/workflows/{FRAME_PACING_WORKFLOW}/runs?branch=feat-cmux-next&per_page=20"
                      ).get("workflow_runs", [])


def github_busy(repo, yield_mode, now=None):
    """A reason when a nightly or dev build waits for a Mac runner (or, with yield_mode running, runs at all).
    Runs older than ABANDON_HOURS are left out (a run parked on an approval for days is not load)."""
    now = now or now_utc()

    def runs(workflow):
        out = []
        for status in ("queued", "in_progress"):
            out += gh_request(f"/repos/{repo}/actions/workflows/{workflow}/runs?status={status}&per_page=30").get("workflow_runs", [])
        return [r for r in out if r.get("created_at") and hours_between(parse_iso(r["created_at"]), now) < ABANDON_HOURS]

    checks = [(wf, None) for wf in NIGHTLY_WORKFLOWS] + [("cmux-next.yml", DEV_DAILY_TITLE)]
    for workflow, title in checks:
        try:
            found = runs(workflow)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        for run in found:
            name = run.get("display_title") or run.get("name") or ""
            if title and not name.startswith(title):
                continue
            if yield_mode == "running":
                return f"{workflow} run {run['id']} ({name[:50]}) is {run['status']}; CMUX_NEXT_PERF_CRON_YIELD=running"
            jobs = gh_request(f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100").get("jobs", [])
            waiting = [j for j in jobs if mac_job_waiting(j)]
            if waiting:
                return (f"{workflow} run {run['id']} ({name[:50]}) has {len(waiting)} job(s) waiting for a Mac runner, "
                        f"e.g. {waiting[0].get('name')}")
    return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def download_redirected(url, timeout=120):
    """An artifact archive: GitHub answers 302 to a signed storage URL, which refuses the GitHub token, so the
    redirect is followed without it."""
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                                               "Accept": "application/vnd.github+json", "User-Agent": "cmux-perf-cron"})
    GH_CALLS[f"GET {gh_shape(url)}"] += 1
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as error:
        if rate_limited(error):
            raise refused_for_the_limit(f"GET {gh_shape(url)}", error) from error
        if error.code not in (301, 302, 303, 307, 308) or not error.headers.get("Location"):
            raise
        location = error.headers["Location"]
    with urllib.request.urlopen(urllib.request.Request(location, headers={"User-Agent": "cmux-perf-cron"}), timeout=timeout) as r:
        return r.read()


def untrusted_state_artifact(artifact, repo_id, run_of):
    """Why the state artifact cannot be trusted, or None. Only a run of STATE_WORKFLOW on STATE_BRANCH of this
    repository writes the state: the artifact search covers every run of the repository, and a fork pull request
    or a run on any branch can upload an artifact named perf-cron-state. run_of(run_id) -> the workflow run."""
    wr = artifact.get("workflow_run") or {}
    if not repo_id or wr.get("repository_id") != repo_id or wr.get("head_repository_id") != repo_id:
        return f"run {wr.get('id')} is from another repository"
    if wr.get("head_branch") != STATE_BRANCH:
        return f"run {wr.get('id')} is on {wr.get('head_branch')!r}, not {STATE_BRANCH}"
    run = run_of(wr.get("id")) or {}
    path = (run.get("path") or "").split("@")[0]
    if path != STATE_WORKFLOW:
        return f"run {wr.get('id')} is {path or 'an unknown workflow'}, not {STATE_WORKFLOW}"
    if run.get("event") not in STATE_EVENTS:
        return f"run {wr.get('id')} was started by {run.get('event')!r}"
    if (run.get("head_repository") or {}).get("id") != repo_id or run.get("head_branch") != STATE_BRANCH:
        return f"run {wr.get('id')} does not run {STATE_BRANCH} of this repository"
    return None


STATE_PAGES = 10  # artifact pages (100 each) read for a trusted state: forged artifacts cannot push it off page 1


def fetch_state(repo, out_dir):
    """Download the newest trusted perf-cron-state artifact into out_dir; True when one was found. The artifact list
    is newest first; the pages are read in turn (up to STATE_PAGES), so a flood of same-named artifacts from fork pull
    requests delays the search but cannot hide the trusted state and reset the cron to a fresh one."""
    os.makedirs(out_dir, exist_ok=True)
    # Actions sets GITHUB_REPOSITORY_ID for the run's own repository: no call for it.
    env_id = os.environ.get("GITHUB_REPOSITORY_ID", "")
    repo_id = int(env_id) if env_id.isdigit() and os.environ.get("GITHUB_REPOSITORY") == repo \
        else gh_request(f"/repos/{repo}").get("id")
    runs = {}

    def run_of(run_id):
        if run_id not in runs:
            try:
                runs[run_id] = gh_request(f"/repos/{repo}/actions/runs/{int(run_id)}")
            except (TypeError, ValueError, urllib.error.HTTPError):
                runs[run_id] = None
        return runs[run_id]
    skipped = 0
    for page in range(1, STATE_PAGES + 1):
        found = gh_request(f"/repos/{repo}/actions/artifacts?name={STATE_ARTIFACT}&per_page=100&page={page}").get("artifacts", [])
        for a in sorted(found, key=lambda a: a.get("created_at") or "", reverse=True):
            if a.get("expired"):
                continue
            why = untrusted_state_artifact(a, repo_id, run_of)
            if why:
                skipped += 1
                if skipped <= 20:
                    print(f"perf-cron: state artifact {a.get('id')} skipped: {why}")
                continue
            blob = download_redirected(a["archive_download_url"])
            zipfile.ZipFile(io.BytesIO(blob)).extractall(out_dir)
            print(f"perf-cron: state from artifact {a['id']} (run {a.get('workflow_run', {}).get('id')}, {a.get('created_at')}; "
                  f"{skipped} untrusted skipped)")
            return True
        if len(found) < 100:
            break
    print(f"perf-cron: no trusted state artifact ({skipped} untrusted skipped); starting fresh")
    return False


def own_issue(issue):
    """The cron's own regression issue: its title, opened by the workflow's bot, its body carrying ISSUE_MARK, and
    not a pull request. A person's issue with the same title is never edited, commented on or closed."""
    return (isinstance(issue, dict) and issue.get("title") == ISSUE_TITLE and "pull_request" not in issue
            and (issue.get("user") or {}).get("login") == ISSUE_AUTHOR and ISSUE_MARK in (issue.get("body") or ""))


def find_issue(repo, number=None):
    if number:
        try:
            issue = gh_request(f"/repos/{repo}/issues/{number}")
            if own_issue(issue):
                return issue
        except urllib.error.HTTPError:
            pass
    q = urllib.parse.quote(f'repo:{repo} is:issue in:title "{ISSUE_TITLE}" author:app/github-actions')
    items = gh_request(f"/search/issues?q={q}&sort=created&order=desc&per_page=10").get("items", [])
    items = [i for i in items if own_issue(i)]
    return items[0] if items else None


# ---------- git (plan) ----------

def git(*args, check=True):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=check, timeout=120).stdout.strip()


def have_range(good, bad):
    """True: good is an ancestor of bad in the checkout. False: not in the shallow checkout's history yet (a missing
    commit, or one a partial clone fetched lazily past the shallow boundary). None: the checkout is complete and good
    is not an ancestor (deepening cannot help)."""
    try:
        git("merge-base", "--is-ancestor", "--end-of-options", good, bad)
        return True
    except subprocess.CalledProcessError:
        return False if git("rev-parse", "--is-shallow-repository", check=False) == "true" else None


def range_commits(good, bad, remote="origin", branch=STATE_BRANCH):
    """The first-parent commits strictly between good and bad, oldest first, or None (logged) when the range cannot
    be listed. The plan's checkout is shallow: a range whose good commit is older than its boundary is deepened
    DEEPEN_STEP commits at a time (at most DEEPEN_ROUNDS times) first, else `git rev-list good..bad` would list
    nothing and the range would never narrow."""
    rounds = 0
    while True:
        have = have_range(good, bad)
        if have:
            break
        if have is None:
            print(f"perf-cron: cannot list the range {good[:12]}...{bad[:12]}: {good[:12]} is not an ancestor of {bad[:12]}")
            return None
        if rounds >= DEEPEN_ROUNDS:
            print(f"perf-cron: cannot list the range {good[:12]}...{bad[:12]}: {good[:12]} is not an ancestor of "
                  f"{bad[:12]} within {DEEPEN_ROUNDS * DEEPEN_STEP} commits past the shallow boundary; not bisected")
            return None
        rounds += 1
        try:
            git("fetch", "--no-tags", "--filter=blob:none", f"--deepen={DEEPEN_STEP}", remote, branch)
        except subprocess.CalledProcessError as error:
            print(f"perf-cron: cannot deepen the checkout for {good[:12]}...{bad[:12]} ({(error.stderr or '').strip()[-300:]})")
            return None
    commits = git("rev-list", "--first-parent", "--reverse", f"{good}..{bad}").split()
    if rounds:
        print(f"perf-cron: deepened the checkout {rounds * DEEPEN_STEP} commits for {good[:12]}...{bad[:12]} ({len(commits)} commits)")
    return [c for c in commits if c != bad]


def part_minutes(run_seconds):
    """(step, job) timeout minutes of a measure job for a part of run_seconds: the step covers fleet-check, the queue,
    the run, the artifact download and slack; the job adds the cleanup step that cancels a step left running (a
    job GitHub kills writes no result, so the part would run again every tick)."""
    step = run_seconds + FLEET_CHECK_SECONDS + PART_QUEUE_SECONDS + ARTIFACT_SECONDS + STEP_SLACK_SECONDS
    step_minutes = -(-step // 60)
    return step_minutes, step_minutes + 5


def tree_published(sha, deadline=None):
    """Whether sha's cmux-tui tree is on files.cmux.com. deadline (time.monotonic()) bounds the key and the fetch: past
    it the answer is False, as for a tree not yet published, and the caller says so (plan's tree_ready)."""
    for version in ("v2", "v1"):
        left = 120 if deadline is None else min(120, deadline - time.monotonic())
        if left <= 1:
            return False
        try:
            key = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/ci/cmux_tui_tree_key.py"), "--version", version, sha],
                                 capture_output=True, text=True, check=True, timeout=left).stdout.strip()
        except subprocess.SubprocessError:
            continue
        url = f"https://files.cmux.com/cmux-tui/tree/{key}/cmux-tui-aarch64-apple-darwin.sha256"
        left = 20 if deadline is None else min(20, deadline - time.monotonic())
        if left <= 1:
            return False
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-ci"}), timeout=left) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError):
            pass
    return False


# A plan takes about a minute. Each path check is bounded: in a partial clone `cat-file -e` can fetch a missing object
# from the remote, and a fetch that never answers held the plan step until its 75-minute cap (run 44731310755,
# 2026-11-20: no output for 74 minutes after fetch-state). No prompt either: the checkout has no credentials.
PATH_CHECK_TIMEOUT_S = 60


def has_path(sha, path):
    """sha's tree holds path; False when git says no, fails, or takes past PATH_CHECK_TIMEOUT_S (logged)."""
    try:
        return subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}:{path}"], capture_output=True,
                              timeout=PATH_CHECK_TIMEOUT_S, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).returncode == 0
    except subprocess.TimeoutExpired:
        print(f"perf-cron: git cat-file {sha[:12]}:{path} took past {PATH_CHECK_TIMEOUT_S} s; counted as absent", flush=True)
        return False


def supported_parts_at(sha):
    names = []
    for p in PARTS:
        need = p.get("needs")
        if need == "stress":
            ok = has_path(sha, f"scripts/cmux-next/perf-stress-session.py")
        elif need == "diff-viewer":
            ok = all(has_path(sha, f"{path}")
                     for path in ("Native/DiffSidecar/Cargo.toml", "webviews/bench/diff-stream.bench.ts"))
        elif need == "web-ui":
            ok = has_path(sha, f"{WEBUI_SUITE}")
        elif need == "web-ui-scale":
            ok = has_path(sha, f"{UPDATE_ONE_BENCH}")
        elif need == "web-ui-god":
            ok = has_path(sha, f"{GOD_FIXTURE}")
        elif need == "web-ui-growth":
            ok = has_path(sha, f"{STATE_GROWTH_BENCH}")
        elif need == "web-ui-flat":
            ok = has_path(sha, f"{FLAT_100K_BENCH}")
        elif need == "web-ui-ladder":
            ok = has_path(sha, f"{SIM_LADDER_BENCH}")
        elif need == "web-ui-scroll-up":
            ok = has_path(sha, f"{SCROLL_UP_SCALE_BENCH}")
        elif need == "web-ui-scroll":
            ok = has_path(sha, f"{CHAT_FAST_SCROLL_BENCH}")
        elif need == "web-ui-orchestrator":
            ok = has_path(sha, f"{ORCHESTRATOR_BENCH}")
        elif need == "web-ui-typing":
            ok = has_path(sha, f"{COMPOSER_TYPING_ROWS}")
        elif need == "power-user-native":
            ok = has_path(sha, f"{POWER_USER_NATIVE}")
        elif need == "web-ui-power-user":
            ok = has_path(sha, f"{POWER_USER_BENCH}")
        elif need == "web-ui-settled":
            ok = has_path(sha, f"{SETTLED_PAGE_BENCH}")
        elif need == "web-ui-million":
            ok = has_path(sha, f"{MILLION_EVENT_BENCH}")
        elif need == "web-ui-memory":
            ok = has_path(sha, f"{CHAT_PAGES_MEMORY_BENCH}")
        elif need == "infinite-items":
            ok = has_path(sha, f"{INFINITE_ITEMS}")
        elif need == "chat-disk":
            ok = has_path(sha, f"{CHAT_DISK}")
        elif need == "cloud-claim":
            ok = has_path(sha, f"{CLOUD_CLAIM}")
        elif need == "typing":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            bench = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/typing-frame-bench.py"],
                                   capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--suite=typing-frame" in text and '"key_to_frame_values"' in bench
        elif need == "terminal-scroll":
            ok = has_path(sha, f"{TERMINAL_SCROLL}")
        elif need == "daemon-restart":
            ok = has_path(sha, f"{DAEMON_RESTART}")
        elif need == "coord-sim":
            # The harness, and a driver that is built (the crate landed with stub subcommands first).
            drive = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:{COORD_SIM_DRIVE}"], capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S)
            ok = coord_sim_ready(has_path(sha, f"{COORD_SIM}"),
                                 drive.stdout if drive.returncode == 0 else None)
        elif need == "chat-search":
            ok = has_path(sha, f"{CHAT_SEARCH}")
        elif need == "terminal-throughput":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--suite=terminal-throughput" in text
        elif need == "launch-dock":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            bench = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/bench-startup.py"],
                                   capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--suite=launch" in text and '"--activation"' in bench
        elif need == "launch-cold":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            bench = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/bench-startup.py"],
                                   capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--suite=launch" in text and '"--fresh-copy"' in bench and '"--ready-mark"' in bench
        elif need in ("perf-gate", "launch", "memory-agents", "relaunch", "wake", "power", "chat-size", "cef-resize",
                      "chat-snappy"):
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = f"--suite={need}" in text
        elif need == "typing-load":
            # The load modes (--modes) and the agent chat surface arrived together with load_modes.py (cmux#44479).
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/typing-frame-bench.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--modes" in text and "agentpane" in text and has_path(sha, "scripts/cmux-next/load_modes.py")
        elif need == "tabs":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/perf-budgets.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = '"surfaces_scale":' in text
        elif need == "idle-budget":
            # Its report's perf-cron rows (cron_report): an older idle-budget.py writes none.
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/idle-budget.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "def cron_report(" in text
        elif need == "workspace-scaling":
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
            ok = "--suite=workspace-scaling" in text and has_path(sha, "scripts/cmux-next/workspace-scaling-bench.py")
        else:
            ok = True
        if ok:
            names.append(p["name"])
    return names


MEASURE_SCRIPT = "scripts/measure/split-spring.sh"
# What split-spring.sh prints when its tagged build fails (it prints up to 60 compiler lines after it).
BUILD_FAILED_MARK = "the tagged reload printed no app path"


# The assignment line, with an optional export/readonly/declare, quotes and a trailing `# comment` (5d4878cf9dd wrote
# `SPLIT_SPRING_MEASURE_VERSION=3  # 3: ...`, which an end-anchored pattern read as no version: nothing was measured).
MEASURE_VERSION_RE = re.compile(r"""^(?:(?:export|readonly|declare(?:\s+-\w+)*)\s+)?SPLIT_SPRING_MEASURE_VERSION=(["']?)(\d+)\1"""
                                r"""\s*(?:#.*)?$""", re.MULTILINE)
# split-spring.sh blobs from before SPLIT_SPRING_MEASURE_VERSION, with the version they measure as. The cron passes no
# --config, so it measures the default Debug build with each: 626c77ac (b5b629ddfd2..36289e3cd3b^), 07ed24bb
# (36289e3cd3b, which added --config=bench, unused here) and 9a147625 (3c2bfd8efbb, which added a report key, macos).
# Older blobs built or displayed differently, so they have no version (not measured).
LEGACY_MEASURE_VERSION = 2  # the version of every row stored before rows carried one (2026-10-24)
# The diff part's benches run at the measured commit (the Rust sidecar's `benchmark` feature, webviews `bun run
# benchmark`): each may carry `DIFF_BENCH_VERSION` (a `pub const ...: u32` in Native/DiffSidecar/src/benchmark.rs, an
# `export const` in webviews/bench/diff-stream.bench.ts), bumped by an edit that changes what it measures; a bench
# without one measures as DIFF_LEGACY_VERSION, so adding the constant at 1 rebases nothing.
DIFF_LEGACY_VERSION = 1
# The web-ui part's runner; a commit without it does not run the part. Its rows are webui.<the bench's PERF_ROW name>.
WEBUI_SUITE = "webviews/bench/web-ui-suite.ts"
UPDATE_ONE_BENCH = "webviews/bench/update-one.bench.ts"
STATE_GROWTH_BENCH = "webviews/bench/state-growth.bench.ts"
MILLION_EVENT_BENCH = "webviews/bench/million-event-chat.bench.ts"
CHAT_PAGES_MEMORY_BENCH = "webviews/bench/chat-pages-memory.bench.ts"
FLAT_100K_BENCH = "webviews/bench/chat-100k-flat.bench.ts"
SIM_LADDER_BENCH = "webviews/bench/sim-ladder.bench.ts"
SCROLL_UP_SCALE_BENCH = "webviews/bench/transcript-scroll-up-scale.bench.ts"
# The web-ui-typing part needs the load modes (composer-load.ts) and their rows (composerTypingRows.ts).
COMPOSER_TYPING_ROWS = "webviews/bench/composerTypingRows.ts"
CHAT_FAST_SCROLL_BENCH = "webviews/bench/chat-fast-scroll.bench.ts"
ORCHESTRATOR_BENCH = "webviews/bench/orchestrator-16.bench.ts"
# The web-ui-power-user part's adapter around the power-user input stress harness.
POWER_USER_BENCH = "webviews/bench/power-user-bursts.bench.ts"
POWER_USER_NATIVE = "scripts/perf-bench/power_user_native.py"
SETTLED_PAGE_BENCH = "webviews/bench/settled-page.bench.ts"
INFINITE_ITEMS = "scripts/measure/infinite-items-linux.sh"
CHAT_DISK = "scripts/measure/chat-disk-growth-linux.sh"
CLOUD_CLAIM = "scripts/cmux-next/cloud-claim-rows.py"
CHAT_SEARCH = "scripts/measure/chat-search-linux.sh"
TERMINAL_SCROLL = "scripts/measure/terminal-scroll-stress-linux.sh"
DAEMON_RESTART = "scripts/measure/daemon-restart-linux.sh"
COORD_SIM = "scripts/measure/coord-sim-linux.sh"
COORD_SIM_DRIVE = "cmux-tui/crates/coord-sim/src/drive.rs"
COORD_SIM_STUB = "not built yet"


def coord_sim_ready(has_script, drive_source):
    """Whether a commit can run the coord-sim part (pure): it has the harness and a drive subcommand past its stub."""
    return bool(has_script) and isinstance(drive_source, str) and COORD_SIM_STUB not in drive_source

# The web-ui-god part: the benches that take FIXTURE=god (web-ui-suite.ts lists each as NAME and NAME-god) and the
# shared fixture a commit needs for the part. A god row is webui.<prefix>.god.<rest>; its ordinary twin drops `.god`.
GOD_FIXTURE = "webviews/bench/godFixture.ts"
GOD_BENCHES = ["chat-open", "chat-switch", "transcript-replay"]
# The god benches that run their ordinary twin themselves, in the same rounds (chat-open-god: PAIRED=1, interleaved
# with a runner calibration page), so the part runs no separate ordinary bench for them: its rows would duplicate the
# paired run's ordinary rows, and come from other minutes of the runner than the god rows they pair with.
GOD_SELF_PAIRED = ("chat-open",)
# Leo, 2026-11-10: a god session must open and run the same, or close to the same, as a small one. A god row more
# than this many times its twin is over target. Only time, size and shift rows have a ratio: a count or a slope
# (a growth per operation or per row) has its own target, and a twin under its noise floor says nothing.
GOD_RATIO_MAX = 1.2
GOD_RATIO_UNITS = ("ms", "MB", "KB", "score")
# The smallest twin a ratio means anything against: a 2 ms long task on the small chat would make 84 ms on the god chat
# 42x, and a ratio of noise flaps. A god row whose twin is under it is still judged by its own target.
GOD_RATIO_MIN = {"ms": 5.0, "MB": 1.0, "KB": 16.0, "score": 0.01}
GOD_RATIO_MIN_RATE = 0.5  # a rate (idle_ms_per_s): main-thread ms per second at rest
# A rate per second (idle_ms_per_s) keeps its ratio. The paired chat-open rows get none: god_ratio.chat_open.* already
# divides the same rounds.
GOD_RATIO_SKIP_RE = re.compile(r"(slope|_per_(?!s$)[a-z]+$|^webui\.chat_open_paired\.)")
# The web-ui-god part's paired transcript-replay rounds (transcript-replay.bench.ts PAIRED=1, cmux#43874): at least MIN
# rounds, then more until each board row's (GOD_PAIRED_BOARD_RE, cmuxterm-hq god_chat_replay_ratio_max) median has a
# 95% interval narrower than CI_WIDTH, up to MAX rounds. A round starts only while the part's benches have run under
# DEADLINE_S with room for one more round as long as the longest so far (the Linux job's cap is 40 minutes with about
# 5 of setup); each round is cut at ROUND_TIMEOUT_S.
GOD_PAIRED_MIN_ROUNDS = 5
GOD_PAIRED_MAX_ROUNDS = 12
GOD_PAIRED_CI_WIDTH = 0.1
GOD_PAIRED_DEADLINE_S = 1950
GOD_PAIRED_ROUND_TIMEOUT_S = 600
GOD_PAIRED_BOARD_RE = re.compile(r"^webui\.god_ratio\.transcript_replay\.long\.(heap_mb|thought_ms|token_ms)$")
PERF_ROW_MARK = "PERF_ROW "
WEBUI_ROW_RE = re.compile(r"^[a-z0-9_]+(\.[a-z0-9_-]+)*$")
DIFF_BENCH_FILES = {"sidecar": "Native/DiffSidecar/src/benchmark.rs", "stream": "webviews/bench/diff-stream.bench.ts"}
DIFF_BENCH_VERSION_RE = re.compile(r"\bDIFF_BENCH_VERSION\s*(?::\s*u32\s*)?=\s*(\d+)")


def diff_bench_versions(root):
    """{bench: version} of the diff part's benches in a checkout ROOT (pure but for reading the files)."""
    out = {}
    for bench, rel in DIFF_BENCH_FILES.items():
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                m = DIFF_BENCH_VERSION_RE.search(f.read())
        except OSError:
            m = None
        out[bench] = int(m.group(1)) if m else DIFF_LEGACY_VERSION
    return out
KNOWN_MEASURE_VERSIONS = {"626c77accc2f511146571fbb9314b1af95d2d7c9": 2, "07ed24bb2427ca2681f2762221a579d6185feeda": 2,
                          "9a14762578b353ec46d64c67049a3bade4c3d0ea": 2}
_versions_by_blob = {}


def script_blob(sha):
    return subprocess.run(["git", "-C", ROOT, "rev-parse", f"{sha}:{MEASURE_SCRIPT}"], capture_output=True, text=True).stdout.strip()


def measure_version_of(blob, text):
    """The measurement version of a split-spring.sh blob (pure): its SPLIT_SPRING_MEASURE_VERSION, else the known
    version of an older blob, else None (not measurable)."""
    m = MEASURE_VERSION_RE.search(text or "")
    return int(m.group(2)) if m else KNOWN_MEASURE_VERSIONS.get(blob)


def measure_version(sha):
    """split-spring.sh's measurement version at a commit (one read per blob; most commits share one)."""
    blob = script_blob(sha)
    if not blob:
        return None
    if blob not in _versions_by_blob:
        text = subprocess.run(["git", "-C", ROOT, "cat-file", "blob", blob], capture_output=True, text=True, timeout=PATH_CHECK_TIMEOUT_S).stdout
        _versions_by_blob[blob] = measure_version_of(blob, text)
    return _versions_by_blob[blob]


def not_measuring_reason(tip, tip_version):
    """Why the cron's own logic measures no commit at TIP, or None (pure): the tip's split-spring.sh has no
    measurement version this file can read, so fleet_runs is false for every commit."""
    if tip_version is None:
        return (f"the tip {tip[:12]}'s {MEASURE_SCRIPT} has no SPLIT_SPRING_MEASURE_VERSION this cron can read "
                "(perf-cron.py MEASURE_VERSION_RE), so no commit is measured")
    return None


def fleet_runs(sha, tip_version):
    """The cron measures a commit only when its split-spring.sh measures as the tip's does (the same measurement
    version), so the args it passes are understood there and the rows compare. The fleet itself runs a commit of
    feat-cmux-next whatever its blob (cmd/worker/step_reviewed.go: that commit is its own merge base)."""
    return tip_version is not None and measure_version(sha) == tip_version


def is_ancestor(a, b):
    return subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", "--end-of-options", a, b],
                          capture_output=True).returncode == 0


ON_BRANCH_KEEP = 300  # commits the state remembers as verified on the branch (each later tick asks GitHub for none)


def commit_on_branch(repo, tip, known=()):
    """ok(sha): the sha is 40 hex characters and an ancestor of tip (or tip). The plan's checkout is shallow, so a
    commit it cannot place under tip is asked of the GitHub compare API ('ahead' or 'identical': on the branch), once:
    known holds the commits a trusted earlier tick verified (feat-cmux-next is never rewritten). ok.verified lists
    every commit found on the branch, for the state. A rate-limit refusal is raised, never read as 'not on the branch'
    (that would drop the state's commits).

    Only the checkout's yes counts. It is a partial clone too, so asking for a commit older than its depth fetches
    that one commit with no path to tip, and 'not an ancestor' is then true of every such commit: on 2026-11-14 each
    tick dropped its bisect step at 281f9aa9680d that way and started it again (15:20Z to 17:27Z, 0 of 3 parts)."""
    cache = {sha: True for sha in known if is_sha(sha)}

    def ok(sha):
        if not is_sha(sha):
            return False
        if sha not in cache:
            have = subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, timeout=PATH_CHECK_TIMEOUT_S).returncode == 0
            if have and is_ancestor(sha, tip):
                cache[sha] = True
            else:
                try:
                    cache[sha] = gh_request(f"/repos/{repo}/compare/{sha}...{tip}").get("status") in ("ahead", "identical")
                except (urllib.error.URLError, ValueError, KeyError):  # KeyError: no GH_TOKEN
                    cache[sha] = False
        return cache[sha]
    ok.verified = lambda: [sha for sha, on in cache.items() if on]
    return ok


# ---------- report (pure) ----------

def stale_basis(state):
    """When the newest complete tip measurement finished (rows, and every open regression measured again), else
    when the cron first ran. A commit that does not build, or a regressed row's part that keeps failing, does not
    reset it."""
    return (state.get("last") or {}).get("measured_at") or state.get("created_at")


def stale_hours(state, now):
    basis = stale_basis(state)
    return hours_between(parse_iso(basis), now) if basis else 0.0


def link(repo, sha):
    return f"[`{sha[:11]}`](https://github.com/{repo}/commit/{sha})"


def hz(refresh_ms):
    return f"{round(1000 / refresh_ms)} Hz" if refresh_ms else "n/a"


def fmt_list(values):
    return "[" + ", ".join(fmt(v) for v in values or []) + "]"


def fmt(v):
    return "n/a" if v is None else (f"{v:g}" if isinstance(v, (int, float)) else str(v))


def unfinished_parts(entry, limit=8):
    """The parts of a finished measurement that did not finish, each with its reason (finish_measurement's
    failed_parts and failed_why), as one line of the issue; '' when every part finished."""
    parts = [p for p in entry.get("failed_parts") or [] if isinstance(p, str)]
    why = entry.get("failed_why") if isinstance(entry.get("failed_why"), dict) else {}
    shown = [f"{p} (`{str(why[p]).replace('`', chr(39))}`)" if why.get(p) else p for p in parts[:limit]]
    return "; ".join(shown) + (f"; and {len(parts) - limit} more" if len(parts) > limit else "")


def incomplete_streak(state):
    """The newest tip measurements in a row that ran and ended incomplete, oldest first (bisect steps and abandoned
    ones between them are left out; a good, regressed or first one ends the streak). From 2026-11-11 to 11-13 every
    tip measurement ended that way on the same five parts while the issue guessed a busy fleet."""
    streak = []
    for entry in reversed([e for e in state.get("history") or [] if isinstance(e, dict)]):
        if entry.get("kind") != "tip" or entry.get("status") == "abandoned":
            continue
        if entry.get("status") != "incomplete":
            break
        streak.append(entry)
    return streak[::-1]


def streak_parts(streak):
    """The parts that did not finish in every measurement of the streak."""
    sets = [set(p for p in e.get("failed_parts") or [] if isinstance(p, str)) for e in streak]
    return sorted(set.intersection(*sets)) if sets else []


def issue_body(state, repo, now):
    good = state.get("last_good")
    last = state.get("last") or {}
    lines = [ISSUE_MARK, ""]
    if state.get("not_measuring"):
        lines += [f"**NOT MEASURING:** {state['not_measuring']}. The cron measures nothing until this is fixed.", ""]
    regs = state.get("regressions") or []
    if regs:
        lines.append(f"**{len(regs)} row(s) regressed.** " + (f"Last good {link(repo, good['sha'])} ([run]({good.get('run_url')}))."
                                                              if good else "No good run on record."))
        for g in bisect_groups(state):
            rng, rows = g["range"], g["rows"]
            first = next((r.get("first_bad") for r in regs if r["name"] == rows[0]), None) or {}
            narrowed = [f"{rng['steps']} bisect step(s)"] if rng.get("steps") else []
            narrowed += [f"{len(rng['skip'])} commit(s) skipped"] if rng.get("skip") else []
            named = next((c for c in reversed(state.get("culprits") or []) if c.get("sha") == rng.get("culprit")), None)
            if rng.get("culprit"):
                pr = f" (#{named['pr']})" if named and named.get("pr") else " (a direct push)" if named else ""
                lines.append(f"- **Culprit** of {', '.join(rows[:6])}{f' and {len(rows) - 6} more' if len(rows) > 6 else ''}: "
                             f"{link(repo, rng['culprit'])}{pr}; its parent {link(repo, rng['good'])} is good (a bisect "
                             f"commit is decided by {BISECT_RUNS} agreeing runs; {', '.join(narrowed) or 'no bisect step'}).")
                continue
            if rng.get("unresolved"):
                narrowed += [f"unresolved: only {len(rng['unresolved'])} commit(s) that could not be judged are left"]
            lines.append(f"- Culprit range of {', '.join(rows[:6])}{f' and {len(rows) - 6} more' if len(rows) > 6 else ''}: "
                         f"[`{rng['good'][:11]}...{rng['bad'][:11]}`](https://github.com/{repo}/compare/{rng['good']}...{rng['bad']})"
                         + (f" ({', '.join(narrowed)})" if narrowed else "")
                         + (f"; first bad tip measurement {link(repo, first['sha'])} ([run]({first.get('run_url')}))" if first.get("sha") else "")
                         + ".")
        lines += ["", "| row | reference p95 | now p95 | change | target | display | why | range |", "|---|---|---|---|---|---|---|---|"]
        for r in regs:
            change = f"+{round(100 * (r['p95'] - r['base']) / r['base'], 1)} %" if r.get("base") else "new"
            rng = r.get("range") or {}
            why = r.get("why", "") + (" (not measured again since)" if r.get("unmeasured_at") else "")
            if r.get("recovering"):
                why += f" (within its threshold in {len(r['recovering'])} of the {RECOVER_RUNS} runs in a row that close it)"
            lines.append(f"| {r['name']} | {fmt(r.get('base'))} {r.get('unit', '')} | {fmt(r.get('p95'))} {r.get('unit', '')} | {change} | "
                         f"{fmt(r.get('target'))} | {hz(r.get('refresh_ms'))} | {why} | "
                         f"{str(rng.get('good') or '?')[:7]}..{str(rng.get('bad') or '?')[:7]} |")
    else:
        lines.append("No confirmed regression.")
    lines += ["", *budget_issue_lines(state, now)]
    unconfirmed = [u for u in state.get("unconfirmed") or [] if isinstance(u, dict)]
    if unconfirmed:
        lines += ["", f"**Unconfirmed ({len(unconfirmed)} row(s), not a regression):** a row is a regression only with "
                      f"{CONFIRM_SAMPLES} baseline values on its host, and worse than its reference in consecutive tip "
                      f"measurements that show a shift: 2 outside the baseline's spread (its max, or its second-highest "
                      f"value from {REF_RUNS} values on) and above its max, {CONFIRM_SAMPLES} above its max, or "
                      f"{REF_RUNS} in a row; a candidate's value never enters a full baseline.",
                  "", "| row | now p95 | reference p95 | spread top | values | commit | why |", "|---|---|---|---|---|---|---|"]
        for u in unconfirmed[:20]:
            sha_link = f"[`{str(u.get('sha'))[:11]}`]({u.get('run_url')})" if u.get("sha") else "?"
            lines.append(f"| {u['name']} | {fmt(u.get('p95'))} {u.get('unit') or ''} | {fmt(u.get('base'))} | {fmt(u.get('top', u.get('max')))} | "
                         f"{u.get('samples')} | {sha_link} | {u.get('why')} |")
    every = [x for x in state.get("baseline_restarts") or [] if isinstance(x, dict)]
    # Every restart not seen yet (each keeps the issue open), and the newest seen ones.
    restarts = [x for i, x in enumerate(every) if x.get("seen") is False or i >= len(every) - 5]
    if restarts:
        lines += ["", "Baseline restarts (an earlier rule restarted a row's baseline from its higher values in a row; "
                      "a regression may have landed then: check these by hand; one not seen yet keeps this issue open "
                      "until a person closes it):"]
        lines += [f"- {x.get('name')} at {x.get('at')}: {fmt_list(x.get('before'))} -> {fmt_list(x.get('after'))} "
                  f"([run]({x.get('run_url')}))" + (" **(not seen yet)**" if x.get("seen") is False else "")
                  for x in restarts]
    if last:
        refresh = last.get("refresh_ms")
        macos = f" (macOS {last['macos']})" if last.get("macos") else ""
        lines += ["", f"Last measurement: {link(repo, last['sha'])} at {last.get('measured_at')} on {last.get('host') or BENCH_WORKER}{macos}, "
                      f"display {round(1000 / refresh) if refresh else 'unknown'} Hz ({fmt(refresh)} ms frames), "
                      f"[run]({last.get('run_url')})." + (f" Parts that did not run: {', '.join(last['failed_parts'])}." if last.get("failed_parts") else "")]
        moved = last.get("os_rebased") if isinstance(last.get("os_rebased"), dict) else {}
        if moved:
            changes = sorted({f"{(v or [None, None])[0]} -> {(v or [None, None])[1]}" for v in moved.values()})
            lines += ["", f"macOS changed ({', '.join(changes)}): {len(moved)} row(s) were not compared and start a new "
                          f"reference ({', '.join(sorted(moved)[:8])}" + (", ..." if len(moved) > 8 else "") + ")."]
        versioned = last.get("version_rebased") if isinstance(last.get("version_rebased"), list) else []
        if versioned:
            lines += ["", f"Measured another way (split-spring.sh measurement version or the part's args changed): "
                          f"{len(versioned)} row(s) were not compared and start a new reference "
                          f"({', '.join(sorted(versioned)[:8])}" + (", ..." if len(versioned) > 8 else "") + ")."]
        if last.get("refresh_skipped"):
            lines += ["", f"Not compared: {len(last['refresh_skipped'])} frame row(s) ran at another display refresh than "
                          f"their last good value ({', '.join(last['refresh_skipped'][:8])}"
                          + (", ..." if len(last["refresh_skipped"]) > 8 else "") + ")."]
    rebases = [x for x in state.get("rebases") or [] if isinstance(x, dict)][-5:]
    if rebases:
        lines += ["", "Rebases (a row measured another way starts a new reference and is not compared; a regression open "
                      "on it closes, not judged):"]
        lines += [f"- {x.get('at')} at {link(repo, x['sha']) if is_sha(x.get('sha')) else '?'}: {x.get('why')} changed, "
                  f"{len(x.get('rows') or [])} row(s) ({', '.join((x.get('rows') or [])[:6])}"
                  + (", ..." if len(x.get("rows") or []) > 6 else "") + ")"
                  + (f"; closed: {', '.join(x['closed'][:6])}" if x.get("closed") else "") + f" ([run]({x.get('run_url')}))"
                  for x in rebases]
    tried = state.get("last_tried") or {}
    if tried.get("sha") and tried.get("sha") != last.get("sha"):
        if "failed_parts" not in tried:  # stored before last_tried carried them: the history entry has the parts
            tried = next((e for e in reversed(state.get("history") or []) if isinstance(e, dict)
                          and e.get("sha") == tried["sha"] and e.get("kind") == "tip" and e.get("failed_parts")), tried)
        unfinished = unfinished_parts(tried)
        lines += ["", f"Newest attempt: {link(repo, tried['sha'])} at {tried.get('at')} ([run]({tried.get('run_url')})) "
                      + (f"is not the last measurement: {len(tried['failed_parts'])} part(s) did not finish: {unfinished}."
                         if unfinished else "measured no row, or not every regressed row; it is not the last measurement.")]
    if stale_hours(state, now) > STALE_HOURS:
        streak = incomplete_streak(state)
        lines += ["", f"**Stale:** no finished measurement since {stale_basis(state)} ({round(stale_hours(state, now))} h): "
                      + (f"the last {len(streak)} tip measurement(s) each ran and ended incomplete"
                         + (f", every one without {', '.join(streak_parts(streak))}" if streak_parts(streak) else "")
                         + " (a part that does not finish keeps a measurement from counting)."
                         if streak else
                         "no measure host had idle time, a nightly or dev build kept waiting for a Mac, the commits did not "
                         "build, the regressed rows' parts kept failing, or the tick failed.")]
    cur_parts = (state.get("current") or {}).get("parts") if isinstance(state.get("current"), dict) else None
    failed = [(p, e["why"]) for p, e in sorted((cur_parts or {}).items())
              if isinstance(e, dict) and e.get("state") == "failed" and e.get("why")]
    if failed:
        lines += ["", "Failed parts of the measurement in flight: "
                  + "; ".join(f"{p}: `{why.replace('`', chr(39))}`" for p, why in failed[:8]) + "."]
    hosts = state.get("hosts") if isinstance(state.get("hosts"), dict) else {}
    def host_line(h):
        info, last = host_info(state, h), host_last_seen(state, h)
        flags = [f"macOS {info.get('macos') or '?'}"]
        flags += [f"last part {info['last_part_at']}"] if info.get("last_part_at") else []
        flags += ["offline"] if host_unreachable(state, h, now) else []
        flags += [f"gone: no part for over {HOST_GONE_HOURS} h, its regressions closed"] \
            if last and host_gone(state, h, now) else []
        return f"{h} ({', '.join(flags)})"
    seen = ", ".join(host_line(h) for h in sorted(hosts))
    coverage = ("Coverage: each Mac part runs on an idle measure worker of the build controller, the parts of one "
                "measurement on the host that built its app (or that holds a regressed row) unless that host takes no part "
                f"for {HOST_WAIT_HOURS} h; a row (named row@host) is compared only with values of the same host and macOS. "
                + (f"Hosts measured so far: {seen}." if seen else "No Mac part has run yet."))
    if state.get("mac_off"):
        coverage += f" **Mac parts disabled:** {state['mac_off']}; each measurement records them as not run."
    if state.get("bench_missing"):
        coverage += (f" **Bench host missing:** {state['bench_missing']['reason']} (since {state['bench_missing']['since']}); "
                     "no Mac part can run until it is back.")
    lines += ["", coverage]
    rows = (last or {}).get("rows") or {}
    if rows:
        lines += ["", "<details><summary>Every row of the last measurement</summary>", "",
                  "| row | p50 | p95 | target | reference p95 | display | |", "|---|---|---|---|---|---|---|"]
        base = judging_rows(state, now)
        for name in sorted(rows):
            r = rows[name]
            tgt = target_of(name, r, last.get("refresh_ms"))
            mark = "over target" if over_target(name, r, last.get("refresh_ms")) else ""
            lines.append(f"| {name} | {fmt(r.get('p50'))} | {fmt(r.get('p95'))} {r.get('unit', '')} | {fmt(tgt)} | "
                         f"{fmt((base.get(name) or {}).get('p95'))} | {hz(r.get('refresh_ms'))} | {mark} |")
        lines += ["", "</details>"]
    lines += ["", "Opened and closed by the perf cron (scripts/cmux-next/perf-cron.py, workflow cmux-next-perf-budgets.yml); "
                  "it never fails a check. Latency target 10 ms p95; frame rows one display refresh, dropped frames 0, judged in "
                  f"frames. Frame rows run on a {VDISPLAY_HZ} Hz virtual display; a row on another refresh than its last good "
                  "value is not compared until a good run rebases it. A row's reference is the median of its last "
                  f"{REF_RUNS} good values, or the median of its good values from {CREEP_DAYS} days ago (at least "
                  f"{CONFIRM_SAMPLES} of them) when lower; an open regression keeps the reference it was confirmed against."]
    return "\n".join(lines)


def _median(values):
    values = sorted(values)
    n = len(values)
    return values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2.0


def _history_time(entry):
    try:
        return parse_iso(entry.get("at"))
    except (TypeError, ValueError):
        return None


def remember_good(state, rows, refresh_ms, t, prev_good=None, sha=None):
    """Append each accepted row's good p95 (and the commit, sha) to state['row_history'] (kept HISTORY_DAYS, at most
    HISTORY_MAX values a row). A row with no history yet starts from its value in prev_good (a state from before the
    history existed)."""
    hist = state.setdefault("row_history", {})
    since = t - datetime.timedelta(days=HISTORY_DAYS)
    for name, r in rows.items():
        if not isinstance(r.get("p95"), (int, float)):
            continue
        h = hist.get(name) if isinstance(hist.get(name), list) else []
        prev = ((prev_good or {}).get("rows") or {}).get(name) or {}
        if not h and isinstance(prev.get("p95"), (int, float)) and prev_good.get("measured_at"):
            h.append({"at": prev_good["measured_at"], "p95": prev["p95"]})
        h.append({"at": iso(t), "p95": r["p95"], **({"sha": sha} if is_sha(sha) else {})})
        hist[name] = [e for e in h if (_history_time(e) or since) >= since][-HISTORY_MAX:]


def aged_window(history, t):
    """A row's last REF_RUNS good history entries at least CREEP_DAYS old at t, or [] when fewer than CONFIRM_SAMPLES
    are (pure): one or two week-old values (the first after a rebase, or a sparse week) are no reference, and a
    baseline window that short would never be full (review 2 of 8af6ea46de5, finding 4)."""
    cutoff = t - datetime.timedelta(days=CREEP_DAYS)
    aged = [e for e in history if (_history_time(e) or t) <= cutoff][-REF_RUNS:]
    return aged if len(aged) >= CONFIRM_SAMPLES else []


def row_reference(history, t):
    """The p95 a row is compared with (pure): the median of its last REF_RUNS good values, or, when lower, the median
    of its aged_window (the last REF_RUNS good values at least CREEP_DAYS old, at least CONFIRM_SAMPLES of them). None
    with no history.

    A single good run cannot move the median, so the baseline does not ratchet up by just under the 10 % rule each
    run; the CREEP_DAYS reference catches a creep too slow for the recent median."""
    h = [e for e in history or [] if isinstance(e, dict) and isinstance(e.get("p95"), (int, float))]
    if not h:
        return None
    ref = _median([e["p95"] for e in h[-REF_RUNS:]])
    old = aged_window(h, t)
    if old:
        ref = min(ref, _median([e["p95"] for e in old]))
    return ref


def reference_rows(state, t):
    """The last good rows with each row's p95 replaced by its row_reference (the row's own last good value when it
    has no history)."""
    hist = state.get("row_history") if isinstance(state.get("row_history"), dict) else {}
    out = {}
    for name, r in ((state.get("last_good") or {}).get("rows") or {}).items():
        ref = row_reference(hist.get(name), t)
        out[name] = r if ref is None or r.get("p95") is None else {**r, "p95": ref, "last_good_p95": r["p95"]}
    return out


def judging_rows(state, t):
    """What each row is judged against at t (pure): reference_rows, except that an open regression's row keeps the
    reference it was confirmed against (its 'ref'). Its history does not move while it is open, but the CREEP_DAYS
    window does, so the week-old median climbs to the crept level within days: judged against that, a creep that stopped
    would 'recover' unfixed and its closing values would raise the baseline, and a bisect step would call the culprit
    good (review 2 of 8af6ea46de5, finding 2)."""
    out = reference_rows(state, t)
    for r in state.get("regressions") or []:
        name = r.get("name") if isinstance(r, dict) else None
        if name in out and isinstance(r.get("ref"), (int, float)) and out[name].get("p95") is not None:
            out[name] = {**out[name], "p95": r["ref"]}
    return out


# A bisect step's commit is decided by repeated runs, as a perf bisect should: BISECT_RUNS runs that
# agree with at most one against. A commit with no decision after BISECT_MAX_RUNS runs is within noise (skipped). Each
# run is bad or good by the row's candidate rule (worse_than: past its reference by 10 % and its floor), so the noise
# threshold of a bisect is the row's own. scripts/cmux-next/perf_bisect.py replays a range with the same rule.
BISECT_RUNS = 3
BISECT_MAX_RUNS = 5
BAD, GOOD, AGAIN, NOISE = "bad", "good", "again", "noise"
SUBJECT_PR_RE = re.compile(r"\(#(\d+)\)\s*$")


def bisect_threshold(ref, floor, regression):
    """How much worse than its reference a run must be to count as bad (pure): worse_than's rule as one number."""
    return max(floor, abs(ref) * regression)


def commit_verdict(bad_runs, runs=BISECT_RUNS, max_runs=BISECT_MAX_RUNS):
    """A commit's verdict from its runs (pure); bad_runs lists, per run, whether it was bad. BAD or GOOD when `runs`
    runs agree and at most one disagrees; AGAIN before that; NOISE after max_runs runs without it."""
    n, bad = len(bad_runs), sum(1 for b in bad_runs if b)
    side = max(bad, n - bad)
    if side >= runs and n - side <= 1:
        return BAD if bad == side else GOOD
    return NOISE if n >= max_runs else AGAIN


def group_verdict(verdicts):
    """The verdict of the rows of one range at a commit (pure): BAD when any row is bad there, AGAIN when any row
    still needs a run, GOOD when every row is good, NOISE otherwise."""
    v = set(verdicts)
    if BAD in v:
        return BAD
    if AGAIN in v:
        return AGAIN
    return GOOD if v == {GOOD} else NOISE


def range_culprit(between, skip, bad):
    """What a range names once no commit is left to try (pure). between: the first-parent commits strictly between its
    ends; skip: those that could not be judged. (bad, []) when nothing is between (bad is the culprit), (None, the
    unjudged commits) when only skipped ones are, None while a commit is left to try."""
    if any(c not in set(skip) for c in between):
        return None
    return (bad, []) if not between else (None, list(between))


def culprit_nominee(sha, subject, parent, rows, steps):
    """What culprit_revert.py (cmuxterm-hq tools/fleet-reconcilers) takes for a one-commit perf culprit (pure): the
    commit, its PR from its squash subject's `(#N)` (None for a direct push), its parent and the rows' numbers."""
    m = SUBJECT_PR_RE.search(subject or "")
    return {"kind": "perf", "sha": sha, "pr": int(m.group(1)) if m else None, "subject": subject or "",
            "parent": parent, "rows": rows, "steps": steps, "runs": BISECT_RUNS}


CULPRITS_KEEP = 40


def name_culprit(state, group, named, subject, t):
    """Record what a range with nothing left to bisect names (pure but for t), once per range. named: range_culprit's
    (sha or None, unjudged commits). A one-commit culprit goes into state['culprits'] as culprit_nominee's record (the
    issue names it; culprit_revert.py takes it); a range of only skipped commits is marked unresolved. Returns
    whether a new culprit was recorded."""
    sha, unjudged = named
    rng = group["range"]
    if rng.get("culprit") == sha and (sha or rng.get("unresolved") == unjudged):
        return False
    regs = [r for r in state.get("regressions") or [] if r["name"] in group["rows"]]
    for r in regs:
        r["range"]["culprit"] = sha
        r["range"]["unresolved"] = unjudged
    if not sha:
        return False
    rows = [{"name": r["name"], "ref": r.get("ref", r.get("base")), "value": r.get("p95"), "floor": r.get("floor")}
            for r in regs]
    nominee = {**culprit_nominee(sha, subject, rng["good"], rows, rng.get("steps", 0)), "at": iso(t)}
    state["culprits"] = (state.get("culprits") or [])[-(CULPRITS_KEEP - 1):] + [nominee]
    return True


def bisect_step(state, cur, part_rows, regs):
    """Fold a bisect step into the culprit range it searched (pure). part_rows: the rows the step measured AND could
    compare (a frame row on another display refresh than its reference is not judged). A step is one run of its
    commit: a row's run is bad when the row regressed in it (the candidate rule: worse than its reference by more than
    10 % and its floor), good when it was judged and within. On 2026-11-15 one slow-runner run called 48ec7aa (no web
    code) bad and every later step searched the wrong half, so a commit is decided only by commit_verdict
    (BISECT_RUNS agreeing runs, at most one against): until then the step is 'again' and the range is left as it
    is, so the next step runs the same commit. After BISECT_MAX_RUNS runs without a decision the commit is within
    noise and skipped (`git bisect skip`), as is a run that judged none of the range's rows (the commit did not build,
    a part failed or yielded, or the display refresh differed). bad: a row of the range is bad at the commit; good:
    every row is good there. Returns (verdict, note): 'bad', 'good', 'again', 'skip' or 'gone'."""
    key = cur.get("bisect_range") or {}
    group = [r for r in state.get("regressions") or [] if same_range(r.get("range"), key)]
    if not group:
        return "gone", f"the range {str(key.get('good'))[:11]}...{str(key.get('bad'))[:11]} is no longer open"
    sha = cur["sha"]
    names = {r["name"] for r in group}
    regressed = names & {r["name"] for r in regs}
    unmeasured = sorted(names - set(part_rows))
    # The runs kept are the current commit's only: a range that moved, or a step on another commit, starts again.
    tries = 1 + max((r["range"].get("tries") or {}).get(sha, 0) for r in group)
    per_row = {}
    for r in group:
        rng = r["range"]
        rng["steps"] = rng.get("steps", 0) + 1
        runs = list((rng.get("runs") or {}).get(sha) or [])
        if r["name"] in part_rows:
            runs.append(r["name"] in regressed)
        rng["runs"], rng["tries"] = {sha: runs}, {sha: tries}
        v = commit_verdict(runs) if runs else AGAIN
        per_row[r["name"]] = NOISE if v == AGAIN and tries >= BISECT_MAX_RUNS else v
    verdict = "skip" if len(unmeasured) == len(names) else group_verdict(list(per_row.values()))
    counts = "; ".join(f"{name} {sum(runs)} of {len(runs)} bad" for name, runs in
                       sorted((r["name"], r["range"]["runs"][sha]) for r in group) if runs)
    for r in group:
        rng = r["range"]
        if verdict == AGAIN:
            continue
        rng.pop("runs", None)
        rng.pop("tries", None)
        if verdict == BAD:
            rng["bad"] = sha
        elif verdict == GOOD:
            rng["good"] = sha
        elif sha not in (rng.setdefault("skip", [])):
            rng["skip"].append(sha)
    rng = group[0]["range"]
    where = f"range now {rng['good'][:11]}...{rng['bad'][:11]}"
    if verdict == "skip":
        return verdict, f"skipped, {', '.join(unmeasured[:6])} not measured; {where}"
    if verdict == AGAIN:
        return "again", f"run {tries} of {sha[:12]} not decided ({counts}), runs it again; {where}"
    if verdict == NOISE:
        return "skip", f"within noise after {tries} run(s) ({counts}), skipped; {where}"
    return verdict, f"{verdict} after {tries} run(s) ({counts or 'every row within its threshold'}); {where}"


def rebase_rows(state, part_rows, names, t):
    """Take each named row's value as its new reference: last_good's row and its history restart from it (the row
    could not be judged against the old reference and never will be). Returns the rebased names."""
    good = state.get("last_good") or {}
    rows = dict(good.get("rows") or {})
    hist = state.setdefault("row_history", {})
    rebased = []
    for name in sorted(names):
        r = part_rows.get(name)
        if r is None or r.get("p95") is None:
            continue
        rows[name] = r
        hist[name] = [{"at": iso(t), "p95": r["p95"]}]
        rebased.append(name)
    if rebased:
        state["last_good"] = {**good, "rows": rows}
    return rebased


def rebase_faster_rows(state, part_rows, skipped, refresh_ms, t):
    """Rebase (rebase_rows) each refresh-skipped row measured at a faster known refresh than its last good value (or
    against an unknown one). Returns the rebased names. A slower refresh (a VDISPLAY-FALLBACK run on a 60 Hz panel
    after 120 Hz runs) rebases nothing: that row stays not judged. Without this, a frame row regressed at 60 Hz stays
    open forever once the 120 Hz display works, and every later measurement is incomplete."""
    good = state.get("last_good") or {}
    rows = good.get("rows") or {}
    faster = []
    for name in sorted(skipped):
        r = part_rows.get(name)
        if r is None or r.get("p95") is None:
            continue
        now = row_refresh(r, refresh_ms)
        then = row_refresh(rows.get(name) or {}, good.get("refresh_ms"))
        if now and not (then and now >= then):
            faster.append(name)
    return rebase_rows(state, part_rows, faster, t)


def worse_than(reg, p95, ref, regression):
    """p95 is worse than the reference ref by the candidate rule (pure): perf-budgets' 10 % rule and the row's floor, or
    the floor alone for a row newly over target. outside_spread is this rule against the top of the spread."""
    rel = 0.0 if reg.get("why") == "newly over target" else regression
    return p95 - ref > reg.get("floor", 1.0) and p95 > ref * (1 + rel)


def baseline_window(state, reg, t, regression):
    """A candidate row's baseline entries (pure), the ones behind its reference (row_reference). Returns (entries,
    aged_ref): its last REF_RUNS good values and None, or, for a creep, its last REF_RUNS good values at least
    CREEP_DAYS old and their median. A creep is a value that is a candidate against that week-old median and NOT
    against the recent one: a step the recent median flags is judged against the recent values, so its range starts at
    row_ok and not at a week-old commit (review 1 of 8af6ea46de5, finding 2: on a flat noisy row the week-old median is
    lower about half the time, and a 7-day range of feat-cmux-next is too long to list or bisect). Its last good value
    when it has no history."""
    name = reg["name"]
    hist = [e for e in (state.get("row_history") or {}).get(name) or []
            if isinstance(e, dict) and isinstance(e.get("p95"), (int, float))]
    recent = hist[-REF_RUNS:]
    if not recent:
        last = (((state.get("last_good") or {}).get("rows") or {}).get(name) or {}).get("p95")
        return ([{"p95": last}] if isinstance(last, (int, float)) else []), None
    aged = aged_window(hist, t)
    if aged:
        aged_ref, recent_ref = _median([e["p95"] for e in aged]), _median([e["p95"] for e in recent])
        if aged_ref < recent_ref and worse_than(reg, reg["p95"], aged_ref, regression) \
                and not worse_than(reg, reg["p95"], recent_ref, regression):
            return aged, aged_ref
    return recent, None


def creep_range_good(state, reg, aged_ref, window, regression):
    """Where a confirmed creep's culprit range starts (pure): the newest commit of the row's history that is still good
    against the week-old reference aged_ref (the creep crossed the rule after it), so the range stays short enough to
    list and bisect; the newest commit of the week-old window when every newer value is over the rule."""
    hist = [e for e in (state.get("row_history") or {}).get(reg["name"]) or []
            if isinstance(e, dict) and isinstance(e.get("p95"), (int, float)) and is_sha(e.get("sha"))]
    good = [e["sha"] for e in hist if not worse_than(reg, e["p95"], aged_ref, regression)]
    return good[-1] if good else next((e.get("sha") for e in reversed(window) if is_sha(e.get("sha"))), None)


def spread_top(samples):
    """The top of a baseline's spread (pure): its max until the baseline has REF_RUNS values, then its second-highest
    value, so one outlier among enough good values cannot widen the spread and let a real step in (review 1 of the
    confirm rule). With fewer values the second-highest is the median or below, and the spread rule would be the
    candidate rule again (review 1 of 8af6ea46de5, finding 6)."""
    s = sorted(samples)
    return s[-2] if len(s) >= REF_RUNS else s[-1]


def outside_spread(reg, p95, samples, regression):
    """A candidate's value p95 is above the top of its baseline's spread (spread_top) by more than the margin of
    worse_than, and above the baseline's max (pure). A value at or under a value the baseline holds is no proof of a
    shift (review 2 of 8af6ea46de5, finding 1: a count row with baseline [0, 0, 1, 0, 0] has spread top 0, and two runs
    with one dropped frame opened a regression)."""
    return worse_than(reg, p95, spread_top(samples), regression) and p95 > max(samples)


def confirming_tail(reg, streak, samples, regression):
    """How many of the newest values of a candidate streak confirm a regression against a full baseline (pure), or 0.
    Every value of the streak is a candidate (worse than the reference); the tail must also show a shift, not values
    the baseline's own noise reaches (review 2 of 8af6ea46de5, finding 1: baseline [19, 20, 20.5, 22, 23] made any
    value over 22.55 a candidate, so 22.7, 23.0, 22.8 confirmed although none is above the baseline's max):
    - 2: the last 2 values are outside the spread (outside_spread);
    - CONFIRM_SAMPLES: the last CONFIRM_SAMPLES values are above the baseline's max (a step inside a wide spread,
      review 1 of 8af6ea46de5, finding 1);
    - REF_RUNS: REF_RUNS candidates in a row, as many runs as the reference has values (a step that stays under an
      outlier the baseline holds, which no value can rise above: without this it would stay held forever, since a
      held value never enters the baseline).
    The shortest rule that holds wins, so first_bad is the newest commit the rule calls bad (a range from row_ok to it
    holds the culprit)."""
    top = max(samples)
    if len(streak) >= 2 and all(outside_spread(reg, v["p95"], samples, regression) for v in streak[-2:]):
        return 2
    if len(streak) >= CONFIRM_SAMPLES and all(v["p95"] > top for v in streak[-CONFIRM_SAMPLES:]):
        return CONFIRM_SAMPLES
    return REF_RUNS if len(streak) >= REF_RUNS else 0


def confirm_regressions(state, regs, cur, run_url, t, regression):
    """Judge this tip measurement's candidates (rows worse than their reference) of rows not regressed already.
    Returns (confirmed, unconfirmed, building names).
    - building: the row's baseline has fewer than CONFIRM_SAMPLES values (a new host, or after a rebase): the rule
      cannot judge it, so the value is a baseline value like any other (review 2 of 8af6ea46de5, finding 5: holding
      it restarted the baseline after every measurement version bump whose first value was low, a false alarm a
      person had to close). It is listed as unconfirmed.
    - confirmed: CONFIRM_SAMPLES baseline values and a confirming_tail of the row's streak of consecutive candidate
      values (state['pending']); first_bad is the first value of that tail. The range starts at row_ok, or for a creep
      (baseline_window) at creep_range_good. The regression keeps the reference it was confirmed against ('ref').
    - unconfirmed: every other candidate, with why. Its value never enters the baseline. finish_measurement ends a
      streak when the row is judged within its threshold, when its host's next tip run that ran its part does not
      judge it, or when its host is gone."""
    pending = state.setdefault("pending", {})
    confirmed, unconfirmed, building = [], [], set()
    for r in regs:
        name = r["name"]
        window, aged_ref = baseline_window(state, r, t, regression)
        samples = [e["p95"] for e in window]
        value = {"sha": cur["sha"], "p95": r["p95"], "at": iso(t), "run_url": run_url}
        prior = pending.get(name) if isinstance(pending.get(name), dict) else {}
        streak = [v for v in prior.get("values") or [] if isinstance(v, dict)][-(REF_RUNS - 1):] + [value]
        entry = {"name": name, "p95": r["p95"], "unit": r.get("unit"), "base": r.get("base"),
                 "top": spread_top(samples) if samples else None, "max": max(samples) if samples else None,
                 "samples": len(samples), "sha": cur["sha"], "at": iso(t), "run_url": run_url, "held": len(streak)}
        if len(samples) < CONFIRM_SAMPLES:
            pending.pop(name, None)
            building.add(name)
            entry.update(held=0, why=f"the baseline has {len(samples)} of {CONFIRM_SAMPLES} values: taken into it, "
                                     "not judged")
            unconfirmed.append(entry)
            continue
        tail = confirming_tail(r, streak, samples, regression)
        if tail:
            first = streak[-tail]
            reg = {**r, "confirmed": True, "ref": aged_ref if aged_ref is not None else r.get("base"),
                   "first_bad": {"sha": first["sha"], "run_url": first.get("run_url"), "measured_at": first.get("at")}}
            if aged_ref is not None:
                reg["range_good"] = creep_range_good(state, r, aged_ref, window, regression)
                reg["why"] = f"{r.get('why')}: a creep, against its values from {CREEP_DAYS} days ago ({fmt(aged_ref)})"
            if tail > 2:
                reg["why"] = f"{reg.get('why')}, {tail} tip measurements in a row"
            confirmed.append(reg)
            pending.pop(name, None)
            continue
        pending[name] = {"values": streak, "at": iso(t), "sha": cur["sha"]}
        if outside_spread(r, r["p95"], samples, regression):
            entry["why"] = "outside the baseline's spread once; the next tip measurement confirms it or clears it"
        else:
            entry["why"] = (f"within the baseline's values (its max {fmt(max(samples))}); held out of it ({len(streak)} "
                            f"of {REF_RUNS} candidates in a row confirm it, or {CONFIRM_SAMPLES} above its max)")
        unconfirmed.append(entry)
    return confirmed, unconfirmed, building


def note_list(prefix, names):
    return f"{prefix}: {', '.join(names[:6])}" + (f" and {len(names) - 6} more" if len(names) > 6 else "")


def finish_measurement(state, part_rows, refresh_ms, host, run_url, t, budgets_mod, macos=None):
    """Fold a finished measurement into the state. Returns the issue event: 'regressed', 'still', 'recovered',
    'narrowed' or 'skipped' (a bisect step), 'first', 'good', 'partial' (no measured row regressed, but a planned
    part did not run), or 'empty' (no row measured: neither a baseline nor a verdict). The newest history entry gets
    the status and a note.

    A tip measurement counts as recovered only when it measured every open regression's row again and each is
    within its threshold for the RECOVER_RUNS-th judged run in a row (before that the row stays open, 'still'). When
    it misses one (its part failed or yielded, or the bench printed no value), the
    missing rows stay regressed, the event is 'still', and last stays as it was (the stale clock keeps running). Only
    a regression of a host this measurement ran on can be missing: a row is judged only on its own host, so another
    host's open regression stays open (not measured again) without making the measurement incomplete. A Linux row of
    another runner class than the one that ran is closed, not judged (the class changed; it is never measured again).
    A row that regresses while another regression is open gets its own culprit range: from the newest tip
    measurement in which it was within its threshold to this commit.

    Each row is its own baseline: a judged row that is not regressed (nor waiting for its confirming run) adds its
    value to its reference on every tip measurement, also one that is incomplete or has another row regressed. A row
    with no reference yet (its first value on a host) starts its baseline that way, so a host's rows are compared from
    their second value on. last_good's sha, run and refresh still name the newest complete good measurement."""
    cur = state["current"]
    failed = sorted(n for n, p in cur["parts"].items() if p.get("state") != "done")
    good = state.get("last_good")
    state["current"] = None
    entry = {"sha": cur["sha"], "kind": cur["kind"], "at": iso(t), "run_url": run_url, "failed_parts": failed}
    # Why each of them did not finish (its own reason, else its state): the issue names it (unfinished_parts).
    failed_why = {n: str(cur["parts"][n].get("why") or cur["parts"][n].get("reason") or cur["parts"][n].get("state"))[:300]
                  for n in failed}
    if failed_why:
        entry["failed_why"] = failed_why
    # The parts that ran and failed (not those never run): part_order puts them after the stale parts next time.
    entry["ran_failed"] = [n for n in failed if cur["parts"][n].get("state") == "failed"]
    state.setdefault("history", []).append(entry)
    state["history"] = state["history"][-60:]
    base_rows = judging_rows(state, t)
    good_refresh = (good or {}).get("refresh_ms")
    found = find_regressions(part_rows, base_rows, refresh_ms, good_refresh, budgets_mod) if part_rows else []
    # A row over target with no reference has no culprit range: it is listed, never a regression.
    regs = [r for r in found if r.get("base") is not None]
    no_ref = [{"name": r["name"], "p95": r["p95"], "unit": r.get("unit"), "base": None, "max": None, "samples": 0,
               "sha": cur["sha"], "at": iso(t), "run_url": run_url, "why": r["why"]} for r in found if r.get("base") is None]
    # The rows find_regressions could judge: a frame row on another display refresh than its reference (or an
    # unknown one), or a row on another macOS, was measured but not compared, so it neither clears a regression nor
    # counts as good.
    skipped = set(refresh_skipped(part_rows, base_rows, refresh_ms, good_refresh))
    versioned = set(version_changed(part_rows, base_rows)) - skipped
    moved = (set(os_changed(part_rows, base_rows)) | versioned) - skipped
    judged = {n: r for n, r in part_rows.items() if n not in skipped and n not in moved}
    if cur["kind"] == "bisect":
        entry["status"], entry["note"] = bisect_step(state, cur, judged, regs)
        return "narrowed" if entry["status"] in ("good", "bad") else "skipped"
    state["last_tried"] = {"sha": cur["sha"], "at": iso(t), "run_url": run_url,
                           **({"failed_parts": failed, "failed_why": failed_why} if failed else {})}
    if not part_rows:
        entry["status"] = "empty"
        return "empty"
    record = {"sha": cur["sha"], "measured_at": iso(t), "rows": part_rows, "refresh_ms": refresh_ms, "host": host,
              "macos": macos, "run_url": run_url, "failed_parts": failed,
              "refresh_skipped": sorted(skipped)}
    row_ok = state.setdefault("row_ok", {})
    if not good:
        state["last_good"] = record
        remember_good(state, part_rows, refresh_ms, t, sha=cur["sha"])
        if not failed:
            state["last"] = record  # a first run with a part that did not run is the baseline, not a stale reset
        state["regressions"] = []
        state["unconfirmed"] = no_ref
        row_ok.update({name: cur["sha"] for name in part_rows})
        entry["status"] = "first"
        return "first"
    open_names = {r.get("name") for r in state.get("regressions") or []}
    notes = []
    # The row's reference is now this run's value: an open regression of it (measured at the old, slower refresh, or
    # on the old macOS) can never be judged again, so it closes here instead of staying open with the stale clock
    # running; a row that regresses afterwards opens again against the new reference.
    rebased = rebase_faster_rows(state, part_rows, skipped, refresh_ms, t)
    if rebased:
        record["refresh_rebased"] = rebased
        closed = sorted(n for n in rebased if n in open_names)
        if closed:
            notes.append(note_list("rebased on a faster display refresh, not judged", closed))
    os_rebased = rebase_rows(state, part_rows, moved, t)
    if os_rebased:
        # A measurement version (or part config) rebase is not a macOS change: each has its own line in the issue.
        by_os = {n: [macos_minor((base_rows.get(n) or {}).get("macos")), macos_minor(part_rows[n].get("macos"))]
                 for n in os_rebased if n not in versioned}
        if by_os:
            record["os_rebased"] = by_os
        if set(os_rebased) & versioned:
            record["version_rebased"] = sorted(set(os_rebased) & versioned)
        closed = sorted(n for n in os_rebased if n in open_names)
        by_version = sorted(n for n in closed if n in versioned)
        if by_version:
            notes.append(note_list("rebased on a measurement version change, not judged", by_version))
        if set(closed) - set(by_version):
            notes.append(note_list("rebased on a macOS change, not judged", sorted(set(closed) - set(by_version))))
    all_rebased = set(rebased) | set(os_rebased)
    if all_rebased:
        # Every rebase goes into the issue (lead 2026-10-24), also one of an incomplete measurement (not `last`).
        kinds = [("measurement version or part args", sorted(set(os_rebased) & versioned)),
                 ("macOS", sorted(set(os_rebased) - versioned)), ("display refresh", sorted(rebased))]
        log = state.setdefault("rebases", [])
        log += [{"at": iso(t), "sha": cur["sha"], "run_url": run_url, "why": why, "rows": rows,
                 "closed": sorted(n for n in rows if n in open_names)} for why, rows in kinds if rows]
        state["rebases"] = log[-20:]
        entry["rebased"] = sorted(all_rebased)
        row_ok.update({name: cur["sha"] for name in all_rebased})
        skipped -= set(rebased)
        judged = {**judged, **{n: part_rows[n] for n in all_rebased}}
    old = {r["name"]: r for r in state.get("regressions") or []}
    # A row regressed already stays regressed while it is still worse; a new candidate must be confirmed first.
    confirmed, unconfirmed, building = confirm_regressions(state, [r for r in regs if r["name"] not in old], cur, run_url,
                                                            t, getattr(budgets_mod, "REGRESSION", 0.10))
    # Rows judged in this run that are no candidate any more: a pending one was noise.
    candidates = {r["name"] for r in regs}
    for name in [n for n in state.get("pending") or {} if n in judged and n not in candidates]:
        state["pending"].pop(name)
    # A pending row that this measurement did not judge although its part was done on the row's host expires: its
    # confirming run must be the next one on its host, however long after (no wall-clock limit: the streak is
    # consecutive runs on that host, and its range from row_ok to first_bad holds the culprit whatever their gap).
    # A part that failed or yielded did not judge the row: that keeps it (done-failed-done confirms). A row whose host
    # is gone (host_gone, while Mac parts ran elsewhere) or whose Linux runner class changed is never judged again.
    ran_here = {row_host(n) for n in part_rows}
    done_parts = {n for n, p in cur["parts"].items() if p.get("state") == "done"}
    mac_ran = {mac_host(n) for n in part_rows} - {None}
    linux_classes = linux_part_classes(part_rows)
    for name in list(state.get("pending") or {}):
        unjudged = name not in judged and row_host(name) in ran_here and part_for_row(name) in done_parts
        gone = bool(mac_ran) and bool(mac_host(name)) and host_gone(state, mac_host(name), t)
        class_changed = linux_class_changed(name, linux_classes)
        if unjudged or gone or class_changed:
            state["pending"].pop(name)
    # A candidate's value is never a good value (review 1 of the confirm rule): it moves neither row_ok nor the
    # baseline, so a later confirmation's range starts at the newest commit good against the reference. A row whose
    # baseline is still building takes it (confirm_regressions).
    held = candidates - building
    state["unconfirmed"] = no_ref + unconfirmed
    regressions = []
    # An open regression judged within its threshold closes only on the RECOVER_RUNS-th such run in a row, as opening
    # needs 2 runs (review 1 of 8af6ea46de5, finding 5): until then it stays open, and its row_ok and baseline do not
    # move, so one lucky run on a noisy row neither flaps the issue nor starts a later range after the culprit. A run
    # in which the row is worse again ends the streak (the row is rebuilt from find_regressions below); a rebased row
    # closes at once (it can never be judged against the old reference).
    closing = {}
    for name, prev in old.items():
        if name not in judged or name in candidates or name in all_rebased:
            continue
        p95 = judged[name].get("p95")
        if not isinstance(p95, (int, float)):
            regressions.append(prev)
            continue
        streak = [v for v in prev.get("recovering") or [] if isinstance(v, dict)]
        streak.append({"sha": cur["sha"], "p95": p95, "at": iso(t), "run_url": run_url})
        if len(streak) < RECOVER_RUNS:
            # Its newest reading, so the probe and NOW read this run's value, not the one it was detected at.
            regressions.append({**prev, "recovering": streak, "last_p95": p95, "last_at": iso(t)})
        else:
            closing[name] = streak[:-1]
    for r in [r for r in regs if r["name"] in old] + confirmed:
        prev = old.get(r["name"])
        # Judged against the reference it was confirmed against (judging_rows) until it closes.
        r["ref"] = prev["ref"] if prev and isinstance(prev.get("ref"), (int, float)) else r.get("ref", r.get("base"))
        if prev and prev.get("range"):
            r["range"], r["first_bad"] = prev["range"], prev.get("first_bad")
        else:
            first = (r.get("first_bad") or {}).get("sha") or cur["sha"]
            start = r.pop("range_good", None) or row_ok.get(r["name"]) or good["sha"]
            r["range"] = {"good": start, "bad": first, "skip": [], "steps": 0}
            r.setdefault("first_bad", {"sha": cur["sha"], "run_url": run_url, "measured_at": iso(t)})
        r["confirmed"] = True
        # The newest reading of an open regression (this run's value), as a recovering one keeps above.
        r["last_p95"], r["last_at"] = r["p95"], iso(t)
        regressions.append(r)
    now_bad = {r["name"] for r in regressions} | held
    row_ok.update({name: cur["sha"] for name in judged if name not in now_bad})
    # Every good value is a baseline value of its own row (see the docstring); a rebased row restarted already.
    accepted = {n: r for n, r in judged.items() if n not in now_bad and n not in all_rebased}
    hist = state.setdefault("row_history", {})
    for name, values in closing.items():
        # The earlier runs of a closing regression's recovery are good values too, older than this one.
        h = hist.get(name) if isinstance(hist.get(name), list) else []
        hist[name] = h + [{"at": v.get("at"), "p95": v["p95"], **({"sha": v["sha"]} if is_sha(v.get("sha")) else {})}
                          for v in values if isinstance(v.get("p95"), (int, float))]
    state["last_good"] = {**state["last_good"], "rows": {**(state["last_good"].get("rows") or {}), **accepted}}
    remember_good(state, accepted, refresh_ms, t, good, sha=cur["sha"])
    ran_on = {row_host(n) for n in part_rows}
    linux_classes = linux_part_classes(part_rows)
    class_gone = sorted(n for n in old if n not in judged and linux_class_changed(n, linux_classes))
    if class_gone:
        now = sorted({c for n in class_gone for c in linux_classes[part_for_row(n)]})
        notes.append(note_list(f"the Linux runner class is now {', '.join(map(str, now))}, not judged", class_gone))
    elsewhere = sorted(n for n in old if n not in judged and n not in class_gone and row_host(n) not in ran_on)
    # A Mac host that ran no part for HOST_GONE_HOURS while this measurement ran Mac parts elsewhere has left the
    # fleet or is never idle: its regressions can never be confirmed or cleared, so they close (not judged). A host
    # with nothing on record starts its clock here. A measurement with no Mac part (the Mac route is down) retires none.
    mac_ran = {mac_host(n) for n in part_rows} - {None}
    for h in mac_ran:
        mark_host(state, h, last_part_at=iso(t))
    host_gone_rows = []
    if mac_ran:
        for h in sorted({mac_host(n) for n in elsewhere} - {None}):
            if host_last_seen(state, h) is None:
                mark_host(state, h, absent_since=iso(t))
            elif host_gone(state, h, t):
                host_gone_rows += [n for n in elsewhere if mac_host(n) == h]
    if host_gone_rows:
        gone_hosts = sorted({mac_host(n) for n in host_gone_rows})
        notes.append(note_list(f"host gone ({', '.join(gone_hosts)}: no part for over {HOST_GONE_HOURS} h while other "
                               "hosts measured), not judged", sorted(host_gone_rows)))
        elsewhere = [n for n in elsewhere if n not in host_gone_rows]
    missing = sorted(n for n in old if n not in judged and n not in class_gone and n not in elsewhere
                     and n not in host_gone_rows)
    for name in missing + elsewhere:
        regressions.append({**old[name], "unmeasured_at": cur["sha"]})
    regressions.sort(key=lambda r: r["name"])
    state["regressions"] = regressions
    if notes:
        entry["rebased_note"] = "; ".join(notes)
    if missing:
        parts = sorted({part_for_row(n) or "?" for n in missing})
        entry["status"] = "incomplete"
        entry["note"] = (f"{len(missing)} regressed row(s) not measured again (part(s) {', '.join(parts)}"
                         + (f"; failed: {', '.join(failed)}" if failed else "")
                         + (f"; on another display refresh: {', '.join(sorted(set(missing) & skipped)[:6])}"
                            if set(missing) & skipped else "") + ")")
        return "still"
    if failed:
        # Rows of the parts that ran are judged (a regression of theirs opens, one they measured within its
        # threshold again clears), but a measurement with a planned part that did not run is not complete: it is
        # not the last measurement (the stale clock keeps running while those parts keep failing).
        entry["status"] = "incomplete"
        entry["note"] = f"part(s) that did not run: {', '.join(failed)}"
        if regressions:
            return "still" if old else "regressed"
        return "recovered" if old else "partial"
    state["last"] = record
    if regressions:
        entry["status"] = "regressed"
        return "still" if old else "regressed"
    state["last_good"] = {**record, "rows": state["last_good"]["rows"]}
    entry["status"] = "good"
    return "recovered" if old else "good"


# ---------- subcommands ----------

def write_outputs(path, values):
    if not path:
        print(json.dumps(values, indent=1))
        return
    with open(path, "a") as f:
        for k, v in values.items():
            f.write(f"{k}={v}\n")


# Past the time GitHub names, before the state is read again.
LIMIT_WAIT_SLACK_S = 5


def cmd_fetch_state(o):
    # A result run (--wait-limit) carries the controller's result of a part that ran on the bench: doing nothing
    # drops it and the next tick asks for the same part again (2026-11-14: the build of babcb18cd895 ran twice and
    # both results met a spent limit). It waits for the limit's reset, once, and reads the state then.
    limit = getattr(o, "wait_limit", 0) or 0
    try:
        try:
            fetch_state(o.repo, o.dir)
        except RateLimited as error:
            if error.wait is None or error.wait > limit:
                raise
            print(f"perf-cron: GitHub rate limit ({error}); waiting {error.wait} s for its reset to keep this run's result",
                  flush=True)
            time.sleep(error.wait + LIMIT_WAIT_SLACK_S)  # sleep-ok: GitHub's named rate-limit reset time
            fetch_state(o.repo, o.dir)
    except RateLimited as error:
        # No state read: the plan must not start from an empty one. It and the report see the mark and do nothing.
        os.makedirs(o.dir, exist_ok=True)
        with open(os.path.join(o.dir, RATE_LIMITED), "w") as f:
            f.write(str(error))
        print(f"perf-cron: GitHub rate limit ({error}); this tick does nothing, the next one tries again")
    print_calls("fetch-state")


def load_state(d, t):
    try:
        state = json.load(open(os.path.join(d, "state.json")))
        if isinstance(state, dict) and state.get("schema") == SCHEMA:
            return migrate_state(state)
    except (OSError, ValueError):
        pass
    return empty_state(t)


def clear_parts(d):
    """Delete the stored part reports (the state directory's parts/, uploaded with the state)."""
    parts = os.path.join(d, "parts")
    for name in os.listdir(parts) if os.path.isdir(parts) else []:
        os.remove(os.path.join(parts, name))


# A Linux part's benches each run under this cap (cmd_run_linux_part; a part's run_seconds overrides it), after about
# LINUX_SETUP_MINUTES of the job's checkout, toolchain and browser installs.
LINUX_RUN_TIMEOUT_S = 1800
LINUX_SETUP_MINUTES = 10


def linux_run_seconds(part):
    """The cap of each of a Linux part's bench runs (pure): its run_seconds, else LINUX_RUN_TIMEOUT_S."""
    return int(PART_BY_NAME[part].get("run_seconds") or LINUX_RUN_TIMEOUT_S)


def linux_job_minutes(part):
    """The timeout of a Linux part's job (pure): its setup and every bench's cap, so GitHub never kills a part that
    is still within them (a killed job leaves no result; infinite-items, a build and a suite of up to 30 minutes
    each, outlived the old flat 40 minutes). The paired god rounds stop starting a round at GOD_PAIRED_DEADLINE_S
    after the part's start, and a round may then run GOD_PAIRED_ROUND_TIMEOUT_S more."""
    runs = linux_bench_runs("", part)
    benches = sum(linux_run_seconds(part) for name in runs if name != "paired")
    if "paired" in runs:
        benches = max(benches, GOD_PAIRED_DEADLINE_S + GOD_PAIRED_ROUND_TIMEOUT_S)
    return LINUX_SETUP_MINUTES + -(-benches // 60)


def linux_matrix(parts):
    """The plan's linux_matrix output (pure): a JSON list of {part, minutes}, the workflow's linux job matrix (one
    runner per part, all at once, each on the plan's linux_runner: every own-branch Linux job takes one label)."""
    return json.dumps([{"part": p, "minutes": linux_job_minutes(p)} for p in parts],
                      separators=(",", ":"))


def cmd_plan(o):
    try:
        plan(o)
    except RateLimited as error:
        # Nothing written: the state file stays the one fetched, so the report saves nothing and the next tick
        # starts from the same state.
        out = {"action": "none", "sha": "", "part": "", "linux_matrix": "[]", "worker": "", "frame_pacing": "false",
               "rate_limited": "true", "reason": f"GitHub rate limit ({error}); the next tick tries again"}
        print(f"perf-cron plan: {json.dumps(out)}")
        write_outputs(o.output, out)
    print_calls("plan")


def plan(o):
    t = now_utc()
    if os.path.exists(os.path.join(o.dir, RATE_LIMITED)):
        raise RateLimited("the state was not read")
    state = load_state(o.dir, t)
    tip = git("rev-parse", "--verify", "--end-of-options", f"{o.tip}^{{commit}}")
    tip_version = measure_version(tip)
    before = json.dumps(state, sort_keys=True)
    loaded_id = measurement_id(state.get("current"))
    on_branch = commit_on_branch(o.repo, tip, state.get("on_branch") or [])
    dropped = sanitize_state(state, on_branch)
    state["on_branch"] = list(getattr(on_branch, "verified", lambda: [])())[-ON_BRANCH_KEEP:]  # newest last
    if dropped:
        print(f"perf-cron: dropped from the state (not a commit of {o.tip}): {', '.join(dropped)}")
    if getattr(o, "perf_result", ""):
        result_plan(o, state, t)
        return
    no_mac = None
    if o.no_mac:
        no_mac = ("no route for the Mac parts (neither vars.CI_PERF_CRON_GATEWAY nor "
                  "vars.CMUX_NEXT_PERF_CRON_CONTROLLER=1 is set): no Mac part runs")
    # A refusal of the cron's own making is loud (lead 2026-10-24: 5d4878cf9dd's version line read as none, and
    # the cron measured nothing for hours with a quiet "nothing new"); only a busy fleet is a quiet wait.
    state["not_measuring"] = not_measuring_reason(tip, tip_version)
    dead = drop_dead_measurement(state, t, lambda sha: fleet_runs(sha, tip_version))
    if dead:
        print(f"perf-cron: the measurement in flight ended ({dead}); looking for a new commit")
    last_sha = (state.get("last_tried") or state.get("last") or {}).get("sha")
    candidate, newest = None, None
    trees = {}
    # Every tree lookup of this plan shares one budget: the step's `timeout 600` killed a plan that walked the unread
    # loop's 80 commits at up to 280 s each (run 45536170489, 2026-11-25), so no tick planned and the cron stopped.
    # Past it a commit reads as unpublished, which every caller already handles (the next tick looks again).
    tree_deadline = time.monotonic() + TREE_LOOKUP_SECONDS

    def tree_ready(sha):
        if sha not in trees:
            if time.monotonic() >= tree_deadline:
                if not trees.get("_spent"):
                    trees["_spent"] = True
                    print(f"perf-cron: tree lookups used this plan's {TREE_LOOKUP_SECONDS} s; later commits read as "
                          "unpublished this tick")
                return False
            started = time.monotonic()
            trees[sha] = tree_published(sha, tree_deadline)
            if time.monotonic() - started > 30:
                print(f"perf-cron: the tree lookup of {sha[:12]} took {round(time.monotonic() - started)} s")
        return trees[sha]
    if not state.get("current"):
        for sha in git("rev-list", "--first-parent", f"-n{CANDIDATE_DEPTH}", tip).split():
            if sha == last_sha or (last_sha and is_ancestor(sha, last_sha)):
                break
            if not fleet_runs(sha, tip_version):
                print(f"perf-cron: {sha[:12]} has another {MEASURE_SCRIPT} measurement version than the tip's ({tip_version})")
                break
            newest = newest or sha
            if tree_ready(sha):
                candidate = sha
                break
            print(f"perf-cron: {sha[:12]} has no published cmux-tui tree yet; trying its parent")
        if not candidate and newest:
            # Only the Mac parts need the tree: the Linux parts measure the newest commit now (wait_for_tree).
            candidate = newest
            print(f"perf-cron: no commit since the last tip has a published cmux-tui tree; the tip is {newest[:12]}, "
                  f"its Mac parts wait for its tree (at most {TREE_WAIT_HOURS} h)")
    bisect = None
    budget = BISECT_JUDGED_PER_TICK
    if not state.get("current") and not (candidate and tip_due(state, t)):
        for group in bisect_groups(state):
            rng = group["range"]
            if budget <= 0:
                print(f"perf-cron: the bisect judged {BISECT_JUDGED_PER_TICK} commits this tick; the range "
                      f"{rng['good'][:12]}...{rng['bad'][:12]} and the rest wait for the next tick")
                break
            if any(host_avoided(state, h, t) or host_gone(state, h, t) for h in {mac_host(n) for n in group["rows"]} - {None}):
                # A gone host (the controller has no such worker) would answer every step with host_gone: its rows
                # close at the next tip measurement elsewhere instead.
                print(f"perf-cron: the range {rng['good'][:12]}...{rng['bad'][:12]} waits: its host was offline, "
                      "took no part lately, or left the fleet")
                continue
            between = range_commits(rng["good"], rng["bad"])
            if between is None:
                continue
            named = range_culprit(between, rng.get("skip") or [], rng["bad"])
            if named is not None:
                if name_culprit(state, group, named, git("log", "-1", "--format=%s", rng["bad"]).strip(), t):
                    print(f"perf-cron: PERF_CULPRIT={json.dumps(state['culprits'][-1], sort_keys=True)}")
                continue
            ok = bisect_measurable(group["rows"], lambda c: fleet_runs(c, tip_version) and tree_ready(c),
                                   supported_parts_at)
            judged = []
            looked = rng.get("looked") if isinstance(rng.get("looked"), dict) else {}
            start = looked.get("place", 0) if (looked.get("good"), looked.get("bad")) == (rng["good"], rng["bad"]) else 0
            sha, place = bisect_next(between, lambda c: judged.append(c) or ok(c), rng.get("skip") or [],
                                     start if isinstance(start, int) else 0, budget)
            budget -= len(judged)
            # Where this range's walk stopped, for the next tick; a narrowed range (new good or bad) starts over.
            rng["looked"] = {"good": rng["good"], "bad": rng["bad"], "place": place}
            if sha:
                bisect = {"sha": sha, "range": rng, "rows": group["rows"]}
                break
    newest = None
    gone_by = state.get("current") or {}
    if not no_mac and unread_missing(state, gone_by):
        # A part that never produced a reading (unread_parts) and that the tip in flight predates: the newest commit
        # that can run it on the fleet (supersede_for_unread). Once per part: every later tip has it.
        for sha in git("rev-list", "--first-parent", f"-n{CANDIDATE_DEPTH}", tip).split():
            if sha == gone_by["sha"] or is_ancestor(sha, gone_by["sha"]) or not fleet_runs(sha, tip_version):
                break
            if tree_ready(sha):
                newest = sha
                break
    busy, busy_known = None, False
    if not no_mac and (candidate or bisect or state.get("current")):
        busy, busy_known = github_busy(o.repo, o.yield_mode), True
    controller_route = bool(getattr(o, "controller", False)) and not no_mac
    # Read only when this tick may start a tip that could pin a host (tip_pin_host).
    idle_hosts = controller_idle_hosts() if controller_route and candidate and not state.get("current") else None
    d = decide(state, t, candidate, bisect, supported_parts_at, busy, lambda sha: fleet_runs(sha, tip_version), no_mac,
               controller_route=controller_route, tree_ready=tree_ready, newest=newest, idle_hosts=idle_hosts)
    state["mac_off"] = no_mac  # the issue says why no Mac row is measured
    if state.get("current") and isinstance(tip_version, int):
        # The measurement version its Mac rows carry (fleet_runs measures only commits of the tip's version).
        state["current"].setdefault("measure_version", tip_version)
    if measurement_id(state.get("current")) != loaded_id:
        clear_parts(o.dir)  # a dropped or replaced measurement's part files must never be read as the new one's
    linux_request, waiting, runners = "", [], []
    if d.get("linux_parts") and state.get("current"):
        cur = state["current"]
        runners, linux_request, waiting = linux_picks(cur, d["linux_parts"], t, bool(getattr(o, "linux_controller", False)),
                                                      commit_has(d["sha"], LINUX_SCRIPT))
        for part in waiting:
            print(f"perf-cron: Linux part {part}: its request to the build controller waits for an answer")
        if linux_request:
            print(f"perf-cron: Linux part {linux_request}: asked of the build controller")
        if runners != d["linux_parts"]:
            d["reason"] += (f"; Linux: {', '.join(runners) or 'none'} on the runners, {linux_request or 'none'} asked of "
                            f"the controller, {len(waiting)} waiting for its answer")
    cur = state.get("current")
    if cur and waiting and not (d.get("part") or runners or linux_request):
        # Only the controller's answer is awaited: the wait does not count against ABANDON_HOURS (review of
        # cmux#48328: two unanswered windows of a part are about 4 h).
        if not cur.get("yield_since"):
            start_yield(cur, t)
            cur["linux_wait_yield"] = True
    elif cur and cur.pop("linux_wait_yield", None):
        end_yield(cur, t)
    mac_parts = []
    if d.get("part") and cur and getattr(o, "controller", False) and not no_mac:
        # The controller runs these back to back (BATCH_PREFIX); the request job prints them.
        mac_parts = batch_parts(state, cur, d["part"], t)
        if len(mac_parts) > 1 and not (cur.get("batch") or {}).get("parts"):
            cur["batch"] = {"parts": mac_parts, "asked_at": iso(t)}
    for requested in (*mac_parts, d.get("part"), *runners, linux_request):
        if requested and state.get("current"):
            # What this file asks the part to measure with: its rows carry it (a later tick may run a newer file).
            state["current"].setdefault("configs", {})[requested] = part_config(requested)
    out = {"action": d["action"], "sha": d.get("sha", ""), "part": d.get("part", ""),
           "linux_matrix": linux_matrix(runners), "linux_request": linux_request, "mac_parts": " ".join(mac_parts) if len(mac_parts) > 1 else "",
           "worker": d.get("worker", ""), "reason": d["reason"], "stale_hours": round(stale_hours(state, t), 1),
           "not_measuring": state.get("not_measuring") or ""}
    if d.get("part"):
        p = PART_BY_NAME[d["part"]]
        out["run_seconds"] = p.get("run_seconds", PART_RUN_SECONDS)
        out["step_minutes"], out["job_minutes"] = part_minutes(out["run_seconds"])
        out["args"] = json.dumps(part_args(p, out["run_seconds"]))
        out["artifact"] = p["artifact"]
    seen = parse_iso(state.get("frame_pacing_seen")) if isinstance(state.get("frame_pacing_seen"), str) else None
    if seen and hours_between(seen, t) < FRAME_PACING_EVERY_HOURS:
        # The newest frame pacing run the state saw is under 24 h old: not due, no call.
        fp_due, fp_reason = False, f"frame pacing ran {round(hours_between(seen, t), 1)} h ago (from the state)"
    elif no_mac:
        fp_due, fp_reason = False, "frame pacing waits: no route for the Mac parts"
    else:
        try:
            fp_runs = frame_pacing_runs(o.repo)
            newest = max((r.get("created_at") or "" for r in fp_runs), default="")
            if newest:
                state["frame_pacing_seen"] = newest[:19] + "Z"
            fp_due, fp_reason = frame_pacing_due(fp_runs, t, None)
            if fp_due:
                fp_due, fp_reason = frame_pacing_due(fp_runs, t, busy if busy_known else github_busy(o.repo, o.yield_mode))
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            fp_due, fp_reason = False, f"frame pacing: GitHub did not answer ({error!r})"
    out["frame_pacing"] = "true" if fp_due else "false"
    out["frame_pacing_reason"] = fp_reason
    if json.dumps(state, sort_keys=True) != before:
        state["dirty"] = True  # the report job saves it even when no part ran
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    print(f"perf-cron plan: {json.dumps(out)}")
    write_outputs(o.output, out)


def run_capture(argv, timeout=120):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def cmd_fleet_check(o):
    client = o.client
    try:
        status = http_json(controller_url() + "/v1/status")
        workers = json.loads(run_capture([client, "workers"]).stdout or "{}")
        workers = workers.get("workers", workers)
        jobs = json.loads(run_capture([client, "status"], timeout=300).stdout or "[]")
    except (OSError, ValueError, urllib.error.URLError, subprocess.SubprocessError) as error:
        reason = f"the controller did not answer ({error!r})"
    else:
        reason = fleet_verdict(status, workers, jobs, o.worker, o.yield_mode)
    print(f"perf-cron fleet: {reason or 'idle; the part may run'}")
    if reason and o.not_started:
        os.makedirs(os.path.dirname(os.path.abspath(o.not_started)), exist_ok=True)
        with open(o.not_started, "w") as f:
            json.dump({"reason": reason, "worker": o.worker}, f)
    write_outputs(o.output, {"ok": "false" if reason else "true", "reason": reason or ""})


# `cmux-ci run` exit codes that are the fleet's, not the measured commit's (hq build-fleet/ci-client.py): no worker
# takes steps (69), the step never left the queue within --queue-timeout (75), a newer head superseded it (76). The
# part gives its place back and runs on a later tick (at most MAX_YIELDS times). A run past --timeout (124) fails.
STEP_YIELD_EXITS = {69: "no fleet worker takes steps", 75: "queue-timeout", 76: "superseded"}
STEP_TIMEOUT_EXIT = 124
JOBS_POLL_EVERY = 4  # read /v1/jobs (target workers) every 4th watch round: it is the slow call


STEP_END_RE = re.compile(r"^cmux-ci: step [0-9a-f]{12,} \w+ on ([A-Za-z0-9][A-Za-z0-9._-]{0,62})(?::|$)", re.MULTILINE)


def step_worker(text):
    """The worker a `cmux-ci run` step ended on, from its log (`cmux-ci: step ID STATE on WORKER`), or None (pure).
    The step asks for --target-worker, but the worker that ran it is the one its rows belong to."""
    m = None
    for m in STEP_END_RE.finditer(text or ""):
        pass
    return m.group(1) if m and m.group(1) != "no" else None


def part_state(code, yielded_to):
    """'done', 'yielded' or 'failed' for a part that exited with code (cancelled by the cron when yielded_to)."""
    if code == 0:
        return "done"
    return "yielded" if yielded_to or code in STEP_YIELD_EXITS else "failed"


def step_labels(status, worker):
    """A perf step's labels on worker, as the controller gives them (perf_cron.go perfCronLabels): measure, and bench
    only on a host with the bench label (a bench worker runs only steps that ask for it; any other host never takes a
    step that asks for bench). None when /v1/status does not list the worker (pure)."""
    for w in (status or {}).get("workers") or []:
        if w.get("name") == worker:
            return ["bench", "measure"] if "bench" in (w.get("labels") or []) else ["measure"]
    return None


def cmd_run_part(o):
    """Run one part through `cmux-ci run` (background class, pinned to o.worker) and watch the queue: a foreground
    job that could run on that host cancels it (the part runs again on a later tick, at most MAX_YIELDS times). The
    step's labels are the worker's (step_labels); a worker the controller does not list starts no step (not an
    attempt: NOT_STARTED, as when the fleet check says no)."""
    if not is_sha(o.sha):
        raise SystemExit(f"perf-cron: --sha must be a full commit sha, not {o.sha!r}")
    os.makedirs(o.out, exist_ok=True)
    try:
        labels = step_labels(http_json(controller_url() + "/v1/status"), o.worker)
        why = None if labels else f"{o.worker} is not a controller worker now"
    except (OSError, ValueError, urllib.error.URLError) as error:
        labels, why = None, f"the controller did not answer ({error!r})"
    if why:
        with open(os.path.join(o.out, NOT_STARTED), "w") as f:
            json.dump({"reason": why, "worker": o.worker}, f)
        print(f"perf-cron part: not started: {why}")
        return
    argv = [o.client, "run", "--class", "exclusive", "--background", "--measurement",
            *[x for label in labels for x in ("--label", label)],
            "--target-worker", o.worker, "--no-supersede", "--script", "scripts/measure/split-spring.sh", "--ref", o.sha, "--key", o.key,
            "--artifact", o.artifact, "--timeout", str(o.run_seconds), "--queue-timeout", str(PART_QUEUE_SECONDS),
            *[f"--arg={a}" for a in json.loads(o.args)]]
    print("perf-cron: " + " ".join(argv), flush=True)
    log_path = os.path.join(o.out, "step.log")
    started = time.monotonic()
    step_id, yielded_to, rounds = None, None, 0
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            time.sleep(15)  # the watch interval: a bounded poll of the controller while the step runs
            rounds += 1
            if not step_id:
                m = re.search(rb"cmux-ci: step ([0-9a-f]{12,}) ", open(log_path, "rb").read())
                step_id = m.group(1).decode() if m else None
            if step_id and not yielded_to:
                try:
                    status = http_json(controller_url() + "/v1/status")
                except (OSError, ValueError, urllib.error.URLError):
                    status = None
                jobs = None
                if rounds % JOBS_POLL_EVERY == 1:
                    try:
                        jobs = json.loads(run_capture([o.client, "status"], timeout=120).stdout or "[]")
                    except (OSError, ValueError, subprocess.SubprocessError):
                        jobs = None
                other = wanted_by_other(status, {step_id}, jobs if isinstance(jobs, list) else None, o.worker)
                if other:
                    yielded_to = other["id"]
                    print(f"perf-cron: job {other['id'][:12]} queued for {o.worker}; cancelling this part", flush=True)
                    run_capture([o.client, "cancel", step_id, "--reason", f"perf cron yields to {other['id']}"])
    code = proc.returncode
    text = open(log_path, "rb").read().decode(errors="replace")
    if not step_id:
        m = re.search(r"cmux-ci: step ([0-9a-f]{12,}) ", text)
        step_id = m.group(1) if m else None
    state = part_state(code, yielded_to)
    result = {"state": state, "exit": code, "step_id": step_id, "seconds": round(time.monotonic() - started),
              "yielded_to": yielded_to or STEP_YIELD_EXITS.get(code), "timed_out": code == STEP_TIMEOUT_EXIT,
              "worker": step_worker(text), "asked_worker": o.worker, "tail": text.splitlines()[-40:],
              "build_failed": BUILD_FAILED_MARK in text}
    if state == "done" and step_id:
        got = run_capture([o.client, "artifact", step_id, os.path.join(o.out, "report.json")], timeout=600)
        if got.returncode != 0:
            result["state"], result["artifact_error"] = "failed", (got.stderr or got.stdout)[-500:]
    json.dump(result, open(os.path.join(o.out, "result.json"), "w"), indent=1)
    print(f"perf-cron part: {json.dumps({k: v for k, v in result.items() if k != 'tail'})}")


# A Linux part that failed before its bench could measure anything: the runner had no browser (Playwright's
# "Executable doesn't exist", runs 43809071719 and 43812228014 on 2026-11-16) or refused the job. The commit is not
# to blame, so record_part runs the part once more (a runner that writes no result at all is NO_RESULT, a yield).
SETUP_FAILURE_RE = re.compile(r"Executable doesn't exist|Please run the following command to download new browsers"
                              r"|browserType\.launch(?:Server)?: |Chrome printed no DevTools endpoint:"
                              r"|The runner refused the job|No space left on device"
                              r"|runner left no result")


def setup_failure(result):
    """The line of a failed part's tail that names a setup failure (SETUP_FAILURE_RE), or None (pure)."""
    return next((str(line) for line in result.get("tail") or [] if SETUP_FAILURE_RE.search(str(line))), None)


NOT_STARTED = "not-started.json"  # a part dir with this file: the fleet check said no, no part ran (no attempt)
NO_RESULT = {"state": "yielded", "no_result": True,
             "reason": "the job ended without the part's result (cancelled, timed out, no fleet client, or a setup step "
                       "failed): one attempt"}


def missing_result(part_dir, part=None, linux_job="", linux_download=""):
    """The result to record for a part whose job wrote none (pure but for the file checks): None when the fleet
    check said no (not an attempt), else NO_RESULT (it counts against MAX_YIELDS, so a part whose job keeps dying
    ends as failed instead of being retried every tick). A Linux part's runner of the linux matrix that left no
    result failed, with why (its job died in setup, hit its timeout or lost its runner), unless the run was
    cancelled (linux_job 'cancelled': not the commit's failure, so one attempt as before) or the report could not
    download the results (linux_download other than '' or 'success': the same). The failure names SETUP_FAILURE_RE's
    "runner left no result", so it runs once more first (record_part's setup retry)."""
    if os.path.exists(os.path.join(part_dir, NOT_STARTED)):
        return None
    if part and is_linux_part(part) and linux_job != "cancelled" and linux_download in ("", "success"):
        job = f"the linux job ended {linux_job}" if linux_job else "the linux job's result is unknown"
        return {"state": "failed", "no_result": True,
                "tail": [f"perf cron: the {part} runner left no result ({job}: a setup step failed, it hit its "
                         f"{linux_job_minutes(part)}-minute timeout, or it lost its runner)"]}
    return dict(NO_RESULT)


def cmd_part_cleanup(o):
    """The gateway job's last step (always runs, also on a cancel or the job timeout): when run-part wrote no
    result.json, cancel the fleet step it started (its id is in step.log) and write a result that counts as one
    attempt."""
    os.makedirs(o.out, exist_ok=True)
    if os.path.exists(os.path.join(o.out, "result.json")) or os.path.exists(os.path.join(o.out, NOT_STARTED)):
        return
    step_id = None
    try:
        with open(os.path.join(o.out, "step.log"), errors="replace") as f:
            m = re.search(r"cmux-ci: step ([0-9a-f]{12,}) ", f.read())
        step_id = m.group(1) if m else None
    except OSError:
        pass
    result = {**NO_RESULT, "step_id": step_id, "why": o.why}
    if step_id and os.path.exists(o.client):
        try:
            got = run_capture([o.client, "cancel", step_id, "--reason", f"perf cron: the gateway job ended ({o.why})"], timeout=60)
            result["cancel"] = f"exit {got.returncode}"
        except (OSError, subprocess.SubprocessError) as error:
            result["cancel"] = f"failed: {error!r}"
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)
    print(f"perf-cron part: {json.dumps(result)}")


def unseen_restarts(state):
    """The baseline restarts no person has seen yet (pure): each keeps the issue open until a person closes it
    (acknowledge_restarts). A restart absorbed a level change unjudged; listed only in the body of an issue that was
    closed, nobody saw it (review 1 of 8af6ea46de5, finding 1)."""
    return [x for x in state.get("baseline_restarts") or [] if isinstance(x, dict) and x.get("seen") is False]


def acknowledge_restarts(state, issue):
    """A person closed the cron's issue while the cron kept it open (state['issue_seen']): every baseline restart
    listed by then (at or before its closed_at) counts as seen, so the issue does not reopen for them; a later restart
    reopens it. A close by the cron itself acknowledges none."""
    if issue and issue.get("state") != "open" and (state.get("issue_seen") or {}).get("open") is True:
        closed_at = issue.get("closed_at")
        for x in unseen_restarts(state):
            if not isinstance(closed_at, str) or str(x.get("at") or "") <= closed_at:
                x["seen"] = True


def unnoted_restarts(state):
    """The unseen baseline restarts no comment of the issue named yet (pure): manage_issue names them once (a body
    edit notifies nobody)."""
    return [x for x in unseen_restarts(state) if not x.get("noted")]


def issue_plan(state, event, now, is_open, exists, set_changed):
    """What to do with the issue (pure): {'open': bool, 'comment': kind or None}. kinds: summary, stale, recovered,
    restart (unnoted_restarts, when nothing else is to say: an issue reopened only for them gets no summary that says
    no row regressed, review 2 of 8af6ea46de5, finding 8)."""
    stale = stale_hours(state, now) > STALE_HOURS
    regressed = bool(state.get("regressions"))
    not_measuring = state.get("not_measuring")
    want_open = regressed or stale or bool(unseen_restarts(state)) or bool(not_measuring)
    if not want_open:
        return {"open": False, "comment": "recovered" if is_open else None}
    if not_measuring and state.get("not_measuring_noted") != not_measuring:
        return {"open": True, "comment": "summary" if exists else None}
    restart = "restart" if unnoted_restarts(state) else None
    if not exists:
        return {"open": True, "comment": None}
    if not is_open:
        return {"open": True, "comment": "summary" if regressed or stale or not restart else restart}
    if event in ("regressed", "narrowed") or (event == "still" and set_changed):
        return {"open": True, "comment": "summary"}
    if restart:
        return {"open": True, "comment": restart}
    if stale and state.get("stale_noted_for") != stale_basis(state):
        return {"open": True, "comment": "stale"}
    return {"open": True, "comment": None}


def restart_note(restarts):
    """The sentence that names baseline restarts to check by hand."""
    names = sorted({str(x.get("name")) for x in restarts})
    return (f"{len(restarts)} baseline restart(s) to check by hand (listed in the body): {', '.join(names[:6])}"
            + (f" and {len(names) - 6} more" if len(names) > 6 else "") + ". Close this issue when they are checked")


def run_capped(argv, cwd, env, timeout):
    """(stdout, stderr, exit code) of argv; the exit code is None when it ran past timeout seconds. It runs in its
    own process group, and a timeout kills the whole group: subprocess.run's timeout kills only the direct child (bash),
    so a build-only run past its cap left its cargo building, and the suite's own cargo build then waited on that
    build's lock until GitHub cancelled the job and the part left no result at all."""
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
        return out or "", err or "", proc.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            pass
        out, err = proc.communicate()
        return out or "", err or "", None


def last_json_object(text):
    """The last top-level JSON object a bench printed (it may log lines before it), or None."""
    starts = [i for i in range(len(text)) if text[i] == "{" and (i == 0 or text[i - 1] == "\n")]
    for i in reversed(starts):
        try:
            value, _ = json.JSONDecoder().raw_decode(text[i:])
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


def webui_summary(report, prefix="webui"):
    """The web-ui part's rows as Markdown lines, slowest first relative to their target (rows with no target after,
    by p95), then the benches that failed (pure): what a lane fixes first."""
    rows = [r for r in (report.get("rows") or []) if isinstance(r, dict) and isinstance(r.get("p95"), (int, float))
            and isinstance(r.get("name"), str) and WEBUI_ROW_RE.match(r["name"])]  # the rows rows_of_part keeps

    def ratio(r):
        target = r.get("target")
        return r["p95"] / target if isinstance(target, (int, float)) and target > 0 else -1.0
    rows.sort(key=lambda r: (-ratio(r), -r["p95"]))
    lines = ["| row | p95 | target | of target |", "| --- | ---: | ---: | ---: |"]
    for r in rows:
        unit = r.get("unit") or "ms"
        target = f"{r['target']} {unit}" if ratio(r) >= 0 else "-"
        lines.append(f"| {prefix}.{r.get('name')} | {r['p95']} {unit} | {target} | "
                     + (f"{ratio(r) * 100:.0f} %" if ratio(r) >= 0 else "-") + " |")
    for f in report.get("failed") or []:
        if isinstance(f, dict):
            lines.append(f"failed: {f.get('bench')} ({f.get('why')})")
    return lines


# Parts whose script builds cmux-tui, whose Zig terminal engine needs the ghostty-next submodule and Zig. The Linux job
# checks out the measured commit with submodules: false and runs this file from the tip, so the tip prepares both
# here: a measured commit whose script predates #50961 (which made the script do it) still builds instead of failing
# every run with "suite: exit 101".
GHOSTTY_PARTS = {"terminal-scroll"}


def prepare_ghostty(root, env, run=run_capped, timeout=900):
    """(env with CMUX_ZIG set, tail lines) for a GHOSTTY_PARTS part: checks out ghostty-next when it is empty and
    installs Zig with the checkout's scripts/install-zig-ci.sh when none is on PATH. A step that fails is recorded in
    the tail and the part runs anyway, so its own error shows too."""
    tail = []
    if not os.path.isfile(os.path.join(root, "ghostty-next", "build.zig")) and not env.get("CMUX_GHOSTTY_SRC"):
        out, err, code = run(["git", "submodule", "update", "--init", "--depth", "1", "ghostty-next"], root, env, timeout)
        tail += [f"ghostty-next checkout: exit {code if code is not None else f'timeout ({timeout} s)'}"]
        if code != 0:
            tail += (err.strip() or out).splitlines()[-5:]
    installer = os.path.join(root, "scripts", "install-zig-ci.sh")
    have_zig = env.get("ZIG") or env.get("CMUX_ZIG") or shutil.which("zig", path=env.get("PATH"))
    if have_zig or not os.path.isfile(installer):
        return env, tail
    with tempfile.TemporaryDirectory() as tmp:
        zig_env = os.path.join(tmp, "zig.env")
        open(zig_env, "w").close()
        out, err, code = run(["bash", installer], root, {**env, "GHOSTTY_ZIG_SOURCE": "ghostty-next",
                                                         "GITHUB_ENV": zig_env, "GITHUB_PATH": os.devnull}, timeout)
        tail += [f"zig install: exit {code if code is not None else f'timeout ({timeout} s)'}"]
        if code != 0:
            tail += (err.strip() or out).splitlines()[-5:]
        zig = [line.split("=", 1)[1].strip() for line in open(zig_env) if line.startswith("CMUX_ZIG=")]
    if zig:
        env = {**env, "CMUX_ZIG": zig[-1]}
    return env, tail


WAKEUP_LINE_RE = re.compile(r"(left alone for|at rest for) [0-9.]+ s: [0-9]+ wakeups \(")


def webui_wakeup_lines(stdout, limit=40):
    """The web UI suite's bench lines that count and name an idle page's wakeups (pure), at most LIMIT."""
    return [line.strip()[:1200] for line in (stdout or "").splitlines() if WAKEUP_LINE_RE.search(line)][:limit]


def cmd_run_linux_part(o):
    """One Linux part, in a checkout of the measured commit with the webviews packages installed. diff-viewer (Rust
    too): scripts/benchmark-diff-viewer.sh's two benches without their budget env, so they report instead of failing.
    web-ui (Playwright's browsers too): webviews/bench/web-ui-suite.ts; a bench of it that failed makes the report
    incomplete (its rows still count), and a run with no row at all fails the part. perf-cron judges the numbers."""
    os.makedirs(o.out, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_DIFF_BENCH_MAX") and not k.startswith("CMUX_DIFF_BENCH_MIN")}
    started = time.monotonic()
    part = getattr(o, "part", "diff-viewer")
    runs = linux_bench_runs(ROOT, part)
    report, tail, ok = {}, [], True
    load = {}
    if part in GHOSTTY_PARTS:
        env, tail = prepare_ghostty(ROOT, env)
    for name, (argv, cwd, extra) in runs.items():
        if name == "paired":
            report["paired"] = run_paired_rounds(argv, cwd, {**env, **extra}, started)
            tail += [f"paired: {len(report['paired']['rounds'])} rounds, {report['paired']['stopped']}"]
            continue
        before = host_contention() if part != "web-ui" else []
        stdout, stderr, code = run_capped(argv, cwd, {**env, **extra}, linux_run_seconds(part))
        value = last_json_object(stdout) if code is not None else None
        if code is None:
            code = f"timeout ({linux_run_seconds(part)} s)"
        # A script that prints its error to stdout (no stderr) still shows it.
        tail += [f"{name}: exit {code}"] + (stderr.strip() or (stdout if code != 0 else "")).splitlines()[-10:]
        if before:
            load[name] = contention_factor(before + host_contention())
        if PART_BY_NAME[part]["kind"] == "webui":
            # The benches' own lines naming what woke an idle page (chat-switch's "left alone for 10 s: N wakeups
            # (...); <sources>"): the report keeps only the counts, so the job log carries the callbacks behind a
            # nonzero rest_wakeups (goal idle-wakeups) instead of a rerun to find them.
            for line in webui_wakeup_lines(stdout):
                print(f"perf-cron web-ui: {line}")
            if isinstance(value, dict):
                report = value
                failed = [f for f in value.get("failed") or [] if isinstance(f, dict)]
                if failed:
                    report["incomplete"] = [f"{f.get('bench')}: {f.get('why')}" for f in failed]
                    # A bench's setup failure (no browser) is in its own tail, not its exit code: record_part reads it.
                    tail += [str(x) for f in failed for x in f.get("tail") or [] if SETUP_FAILURE_RE.search(str(x))][-3:]
                    tail += [f"{f.get('bench')}: {f.get('why')}" for f in failed]
            ok = isinstance(value, dict) and bool(value.get("rows"))
        elif code != 0 or value is None:
            ok = False
        else:
            report[name] = value
    if PART_BY_NAME[part]["kind"] == "webui":
        for line in webui_summary(report, PART_BY_NAME[part].get("row_prefix", "webui")):
            print(f"perf-cron web-ui: {line}")
    else:
        report["bench_versions"] = diff_bench_versions(ROOT)
        report["load"] = load
    json.dump(report, open(os.path.join(o.out, "report.json"), "w"), indent=1)
    result = {"state": "done" if ok else "failed", "seconds": round(time.monotonic() - started), "tail": tail[-40:],
              "worker": o.runner_class}
    json.dump(result, open(os.path.join(o.out, "result.json"), "w"), indent=1)
    print(f"perf-cron linux part: {json.dumps({k: v for k, v in result.items() if k != 'tail'})} {json.dumps(report)[:600]}")


def perf_rows(text):
    """The PERF_ROW objects a bench printed (pure)."""
    out = []
    for line in (text or "").splitlines():
        if line.startswith(PERF_ROW_MARK):
            try:
                row = json.loads(line[len(PERF_ROW_MARK):])
            except ValueError:
                continue
            if isinstance(row, dict):
                out.append(row)
    return out


def run_paired_rounds(argv, cwd, env, started, clock=time.monotonic, run=subprocess.run):
    """The web-ui-god part's paired rounds (GOD_PAIRED_*), until settled, the deadline or MAX rounds:
    {"rounds": [{"rows", "seconds", "exit"}], "stopped"}. STARTED is the part's start on CLOCK."""
    rounds, longest, stopped = [], 0.0, "max rounds"
    for _ in range(GOD_PAIRED_MAX_ROUNDS):
        if paired_settled(rounds):
            stopped = "settled"
            break
        if clock() - started + longest > GOD_PAIRED_DEADLINE_S:
            stopped = "deadline"
            break
        at = clock()
        try:
            proc = run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=GOD_PAIRED_ROUND_TIMEOUT_S)
            rows, code = perf_rows(proc.stdout), proc.returncode
        except subprocess.TimeoutExpired:
            rows, code = [], f"timeout ({GOD_PAIRED_ROUND_TIMEOUT_S} s)"
        seconds = clock() - at
        longest = max(longest, seconds)
        rounds.append({"rows": rows, "seconds": round(seconds), "exit": code})
        print(f"perf-cron web-ui-god: paired round {len(rounds)}: exit {code}, {round(seconds)} s, {len(rows)} rows")
    else:
        stopped = "settled" if paired_settled(rounds) else stopped
    for name, r in paired_ratio_rows(rounds).items():
        print(f"perf-cron web-ui-god: paired {name} {r['p95']} [{r['ci_lo']}, {r['ci_hi']}] over {r['rounds']} rounds")
    return {"rounds": rounds, "stopped": stopped}


def manage_issue(repo, state, event, now, run_url, summary, set_changed):
    """Open, update, comment on or close the one regression issue. Returns a line for the run summary."""
    issue = find_issue(repo, state.get("issue"))
    acknowledge_restarts(state, issue)
    number = issue["number"] if issue else None
    is_open = bool(issue) and issue.get("state") == "open"
    plan = issue_plan(state, event, now, is_open, bool(issue), set_changed)
    body = issue_body(state, repo, now)
    state["issue_seen"] = {"hash": body_hash(body), "open": plan["open"]}
    if stale_hours(state, now) > STALE_HOURS:
        state["stale_noted_for"] = stale_basis(state)
    if not plan["open"]:
        if is_open:
            gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body})
            gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"Recovered: {summary} ([run]({run_url}))."})
            gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"state": "closed", "state_reason": "completed"})
            state["issue"] = None  # refresh_issue_body reads only an issue on record; a new regression finds it again
            return f"closed issue #{number}"
        state["issue"] = None
        return "no issue needed"
    restarts = unnoted_restarts(state)
    if not issue:
        created = gh_request(f"/repos/{repo}/issues", "POST", {"title": ISSUE_TITLE, "body": body})
        state["issue"] = created["number"]
        for x in restarts:
            x["noted"] = True  # the new issue's body names them, and a new issue notifies
        return f"opened issue #{created['number']}"
    state["issue"] = number
    gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body, **({} if is_open else {"state": "open"})})
    if plan["comment"] in ("summary", "restart"):
        text = summary if plan["comment"] == "summary" else ""
        if restarts:
            text = f"{text}; {restart_note(restarts)}" if text else restart_note(restarts)
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"{text} ([run]({run_url}))."})
        for x in restarts:
            x["noted"] = True
    elif plan["comment"] == "stale":
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body":
                   f"No finished measurement for over {STALE_HOURS} h (since {stale_basis(state)}) ([run]({run_url}))."})
    return f"{'reopened' if not is_open else 'updated'} issue #{number}"


def body_hash(body):
    return hashlib.sha256(body.encode()).hexdigest()[:16]


def refresh_issue_body(repo, state, now):
    """Rewrite the open issue's body when it no longer matches the state (a tick that finished no part: the Mac route
    or bench status changed), and close it when no confirmed regression is open, no baseline restart is unseen
    (unseen_restarts) and the cron is not stale. No call
    when the body and the open state are the ones this cron last wrote (state['issue_seen']). Returns a line for the
    run summary, or ""."""
    body = issue_body(state, repo, now)
    want_open = issue_plan(state, None, now, True, True, False)["open"]
    if state.get("issue_seen") == {"hash": body_hash(body), "open": want_open}:
        return ""
    closed_by_cron = (state.get("issue_seen") or {}).get("open") is False
    issue = find_issue(repo, state.get("issue"))
    acknowledge_restarts(state, issue)
    if not issue or issue.get("state") != "open":
        # Closed (here, by a person, or gone): no GET of it on every tick. manage_issue finds it again by its title
        # and reopens it when a regression opens.
        state["issue"] = None
        return ""
    number, changed = issue["number"], (issue.get("body") or "") != body
    if not want_open and not closed_by_cron:
        # No confirmed regression and not stale (an unconfirmed row opened it under the old rule): the body and the
        # close in one write. An issue the cron closed and a person reopened stays open (only its body is kept).
        n = len(state.get("unconfirmed") or [])
        gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body, "state": "closed", "state_reason": "completed"})
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body":
                   f"No confirmed regression; {n} unconfirmed row(s) stay listed in the body."})
        state["issue_seen"] = {"hash": body_hash(body), "open": False}
        return f"closed issue #{number} (no confirmed regression)"
    if changed:
        gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body})
    state["issue_seen"] = {"hash": body_hash(body), "open": want_open} if closed_by_cron else {"hash": body_hash(body), "open": True}
    return f"rewrote the body of issue #{number}" if changed else ""


def record_part(cur, part, result, run_url, t=None):
    """Fold one part's run into the measurement in flight (pure). A yielded part stays to do; after MAX_YIELDS it
    ends as 'yielded_out' (not run: the fleet was busy, not a failure of the commit). A part whose app build failed
    (split-spring.sh's BUILD_FAILED_MARK, or result['build_failed']) ends the measurement's other fleet parts as
    'build_failed' (each would build the same); the Linux part still runs. A pre-empted build part is no build
    failure: the next part builds the app itself (split-spring.sh --app-cache builds on a cache miss)."""
    if t is not None and not is_linux_part(part):
        end_yield(cur, t)
    if is_linux_part(part) and t is not None and cur.pop("linux_wait_yield", None):
        end_yield(cur, t)  # the wait for the controller's answer (plan) ends with the answer
    asks = cur.get("linux_requests") if isinstance(cur.get("linux_requests"), dict) else {}
    ask = asks.get(part) if is_linux_part(part) else None
    if isinstance(ask, dict) and not ask.get("fell_back_at") and result["state"] == "yielded":
        # The controller answered without running the part (not queued: no idle Linux worker; pre-empted; the step's
        # queue timeout; a setup failure of perf-cron-linux.sh): one unanswered request now, no answer window
        # (linux_route), and no yield of the part, so the runner job is the last try before yielded_out (review of
        # cmux#48328: three such answers ended the part yielded_out and the runner never ran it).
        ask["answered_at"] = iso(t or now_utc())
        entry = dict(cur["parts"].get(part) or {"yields": 0})
        entry.update({"state": "yielded", "step_id": result.get("step_id"), "run_url": run_url,
                      "seconds": result.get("seconds")})
        cur["parts"][part] = entry
        return entry
    if is_linux_part(part):
        asks.pop(part, None)  # answered (a run, or the runner's yield): the next ask starts a new count
    if not is_linux_part(part) and (not cur.get("host") or result.get("worker") in (None, cur.get("host"))):
        cur.pop("host_asked_since", None)  # the host answered (any result): give_up_host's wait starts again
        cur.pop("batch", None)  # ...and the batch asked for ended (or never started): the next request lists again
    entry = dict(cur["parts"].get(part) or {"yields": 0})
    entry.update({"state": result["state"], "step_id": result.get("step_id"), "run_url": run_url,
                  "seconds": result.get("seconds")})
    if result.get("timed_out"):
        entry["timed_out"] = True
    if entry["state"] == "failed":
        # The issue names why. From 2026-10-23 to 11-10 every Mac part exited 0 and then failed on a refused artifact
        # read, and only the report job's log said so; the issue guessed a busy fleet.
        why = next((str(line).strip() for line in reversed(result.get("tail") or []) if str(line).strip()), "")
        if why:
            entry["why"] = why[:200]
    if result["state"] == "yielded":
        entry["yields"] = entry.get("yields", 0) + 1
        if entry["yields"] >= MAX_YIELDS:
            entry["state"] = "yielded_out"
    retry = (entry["state"] == "failed" and is_linux_part(part) and not entry.get("setup_retried")
             and setup_failure(result))
    if retry:
        entry["setup_retried"] = retry[:200]  # runs once more on the same commit; a second failure ends it
    if entry["state"] != "yielded" and not retry and part in cur["parts_todo"]:
        cur["parts_todo"].remove(part)
    cur["parts"][part] = entry
    build_failed = bool(result.get("build_failed")) or any(BUILD_FAILED_MARK in line for line in result.get("tail") or [])
    if entry["state"] == "failed" and build_failed:
        for other in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
            cur["parts"][other] = {"state": "build_failed", "run_url": run_url}
            cur["parts_todo"].remove(other)
    return entry


def not_started_reason(part_dir):
    """(reason, worker) of a part the fleet check did not start; worker is the host it checked, or None."""
    try:
        with open(os.path.join(part_dir, NOT_STARTED)) as f:
            value = json.load(f) or {}
        return str(value.get("reason") or ""), (value.get("worker") if isinstance(value.get("worker"), str) else None)
    except (OSError, ValueError, AttributeError):
        return "", None


def part_host_refusal(cur, part, result):
    """Why a done part's rows cannot be kept, or None (pure). A part's rows are named with the host that ran it
    (result['worker']: the Mac worker, or the Linux part's runner class), so a result that names no valid host is
    refused, never given a default host, and a Mac part that ran on another host than the measurement's (a pinned
    bisect step, or the host that built the app) is refused: its rows would be judged against the wrong host's
    reference, and its app was not the measurement's build."""
    if result.get("state") != "done":
        return None
    worker = result.get("worker")
    if not (isinstance(worker, str) and HOST_RE.match(worker)):
        what = "runner class" if is_linux_part(part) else "worker"
        return f"the result names no valid {what}, so its rows have no host"
    host = cur.get("host")
    if not is_linux_part(part) and host and worker != host:
        return f"ran on {worker}, not on {host} (the measurement's host); its rows are not compared"
    return None


def note_bench_host(state, reason, t):
    """Keep state['bench_missing'] while the fleet check says the bench host is not a controller worker (the issue
    shows it; it goes when a Mac part runs or the check gives another reason)."""
    if f"{BENCH_WORKER} is not a controller worker" in reason:
        state["bench_missing"] = {"reason": reason, "since": (state.get("bench_missing") or {}).get("since") or iso(t)}
    else:
        state.pop("bench_missing", None)


def cmd_report(o):
    if os.path.exists(os.path.join(o.dir, RATE_LIMITED)):
        # The plan read no state (GitHub's rate limit): nothing to store, compare or save.
        print("perf-cron report: no state this tick (GitHub rate limit); the next tick tries again")
        write_outputs(o.output, {"changed": "false", "line": "no state this tick (GitHub rate limit)", "next_now": "false"})
        print_calls("report")
        return
    report(o)
    print_calls("report")


def load_budgets():
    """The budgets module and perf-budgets.json (with the animation budgets), for rows_of_part."""
    mod = load_budgets_module()
    budgets = json.load(open(os.path.join(HERE, "perf-budgets.json")))
    budgets["_animations"] = animation_budgets(mod)
    return mod, budgets


def part_rows_named(cur, name, p, report, mod, budgets, worker):
    """A finished part's rows as the measurement stores them (named row@host, with the refresh, macOS, measurement
    version and part config they were measured under), and the refresh the part saw (None when it saw none). One
    function for the finish of a measurement and for the part-by-part store (store_part_rows), so a row reads the same
    in both."""
    part_rows = rows_of_part(PART_BY_NAME[name], report, mod, budgets)
    # Each fleet part's rows carry the refresh that part saw (split-spring.sh puts its display into the
    # report): a part that saw none leaves its frame rows unknown, never another part's rate.
    r = refresh_ms_of(report)
    if not is_linux_part(name):
        for row in part_rows.values():
            row.setdefault("refresh_ms", r)
            row.setdefault("macos", macos_minor(p.get("macos")))
            if isinstance(cur.get("measure_version"), int):
                row.setdefault("measure_version", cur["measure_version"])
    config = (cur.get("configs") or {}).get(name) if isinstance(cur.get("configs"), dict) else None
    if isinstance(config, str):
        for row in part_rows.values():
            row.setdefault("part_config", config)
    # Each part's rows carry the host that ran that part (a Mac worker, or the Linux part's runner class).
    return host_rows(part_rows, worker), r


def store_part_rows(state, cur, name, p, report, mod, budgets, run_url, t):
    """Store a finished tip part's rows now, tagged with the tip's SHA (state['part_rows'], state['part_stored']),
    instead of only when the whole measurement ends: a part that finishes keeps its rows when another part fails, the
    host goes quiet or the tip is replaced (rows and comparison at the end of the measurement are unchanged: this
    store feeds neither row_history nor any regression). A complete part only (an incomplete one is judged at the
    finish); a bisect step measures an old commit, not the tip. Returns the number of rows stored.

    An incomplete part (a bench of it failed or timed out) stores the rows its finished benches measured: its report
    carries no row of the failed bench, whose own rows keep their older date. On 2026-11-24 web-ui-god's
    transcript-replay-god timed out at 420 s and the 87 rows its four other benches measured (the rest-wakeup rows
    among them) were dropped, so those rows read 3 days old while each tick measured them. part_stored names what
    was missing, and its date still moves, so a part that keeps failing one bench does not take every Linux turn."""
    if cur.get("kind") != "tip":
        return 0
    named, _ = part_rows_named(cur, name, p, report, mod, budgets, p.get("worker"))
    store = state.setdefault("part_rows", {})
    keep = ("p50", "p95", "unit", "refresh_ms", "macos", "measure_version", "part_config")
    for row_name, row in named.items():
        if isinstance(row, dict) and isinstance(row.get("p95"), (int, float)):
            store[row_name] = {**{k: v for k, v in row.items() if k in keep},
                               "sha": cur["sha"], "at": iso(t), "run_url": run_url, "part": name}
    stored = {"sha": cur["sha"], "at": iso(t), "run_url": run_url, "rows": len(named)}
    if report_is_incomplete(PART_BY_NAME[name], report):
        stored["incomplete"] = incomplete_why(report)
    state.setdefault("part_stored", {})[name] = stored
    return len(named)


def stale_parts(state, now):
    """The parts whose newest stored rows (store_part_rows) are older than STALE_HOURS, oldest first; per part, not
    per measurement: a measurement that keeps failing one part leaves the others' rows fresh."""
    old = []
    for name, e in (state.get("part_stored") or {}).items():
        at = parse_iso((e or {}).get("at")) if isinstance(e, dict) else None
        if at and hours_between(at, now) > STALE_HOURS:
            old.append((e["at"], name))
    return [n for _, n in sorted(old)]


def report(o, t=None):
    t = t or now_utc()
    state = load_state(o.dir, t)
    changed = not state.get("persisted") or bool(state.pop("dirty", False))
    state["persisted"] = True
    event, summary = None, ""
    cur = state.get("current")
    fleet_done = False
    before_names = sorted(r["name"] for r in state.get("regressions") or [])
    for spec in o.result:
        part, _, part_dir = spec.partition("=")
        path = os.path.join(part_dir, "result.json")
        if not (cur and part in PART_BY_NAME and part in cur["parts_todo"]):
            continue
        try:
            with open(path) as f:
                result = json.load(f)
        except (OSError, ValueError):
            result = missing_result(part_dir, part, getattr(o, "linux_job", ""), getattr(o, "linux_download", ""))
        if result is None and not is_linux_part(part):
            # The fleet check said no: no attempt, but the wait does not count against ABANDON_HOURS, the issue
            # says when the bench host is gone from the controller, and a host it found offline is not pinned.
            changed = True
            start_yield(cur, t)
            reason, worker = not_started_reason(part_dir)
            note_bench_host(state, reason, t)
            note_host_offline(state, worker, reason, t)
            continue
        if not isinstance(result, dict) or result.get("state") not in ("done", "failed", "yielded"):
            continue
        # A budget bench writes a report and exits zero even when its manifest has missing rows. Keep that
        # incomplete run out of the cron baseline: a partial report is a failed part, just like a missing artifact.
        report_value = None
        if result.get("state") == "done":
            try:
                with open(os.path.join(part_dir, "report.json")) as src:
                    report_value = json.load(src)
            except (OSError, ValueError):
                report_value = None
            if report_value is None or not isinstance(report_value, dict):
                result = dict(result)
                result["state"] = "failed"
                result["tail"] = [*(result.get("tail") or []), "perf cron: completed part has no report artifact"]
        changed = True
        gone = result.get("worker") if result.get("host_gone") else None
        if isinstance(gone, str) and HOST_RE.match(gone) and not is_linux_part(part):
            # The controller has no such worker (hq perf_cron.go goneLocked): retire the host now, not after
            # HOST_GONE_HOURS; the measurement's pin goes, and the part is asked for again on any idle host (no yield).
            mark_host(state, gone, gone_at=iso(t))
            if cur.get("host") == gone:
                cur.pop("host")
                cur.setdefault("gave_up", []).append({"host": gone, "at": iso(t), "why": str(result.get("tail") or "gone")[:200]})
            continue
        if not is_linux_part(part):
            state.pop("bench_missing", None)
        refused = part_host_refusal(cur, part, result)
        if refused:
            # Its rows would be labeled with a host that did not measure them: the part did not run here.
            result = {**result, "state": "failed", "build_failed": False, "tail": []}
        entry = record_part(cur, part, result, o.run_url, t)
        if refused:
            entry["reason"] = refused
        if entry["state"] == "done":
            entry["worker"] = result["worker"]
            if not is_linux_part(part):
                fleet_done = True
                # The host that ran the part: the measurement's later parts are asked for on it (its app cache).
                cur.setdefault("host", result["worker"])
                mark_host(state, result["worker"], last_part_at=iso(t))
                for key in ("unreachable_since", "waited_at", "absent_since"):
                    state["hosts"][result["worker"]].pop(key, None)  # it ran a part: online, not silent, not absent
            os.makedirs(os.path.join(o.dir, "parts"), exist_ok=True)
            if isinstance(report_value, dict) and isinstance(report_value.get("macos"), str) and not is_linux_part(part):
                cur["macos"] = entry["macos"] = report_value["macos"][:16]
                mark_host(state, result["worker"], macos=cur["macos"], at=iso(t))
            with open(os.path.join(o.dir, "parts", f"{part}.json"), "w") as dst:
                json.dump({"measurement": measurement_id(cur), "report": report_value}, dst)
            if isinstance(report_value, dict):
                try:
                    stored_mod, stored_budgets = load_budgets()
                    store_part_rows(state, cur, part, entry, report_value, stored_mod, stored_budgets, o.run_url, t)
                except Exception as error:  # a row that does not parse is the finish's to report; never fail the tick
                    print(f"perf-cron report: part {part}: rows not stored now ({error!r})", file=sys.stderr)
    if cur and not cur["parts_todo"] and (changed or o.finish):
        changed = True
        mod, budgets = load_budgets()
        rows, refresh = {}, []
        for name, p in cur["parts"].items():
            # Only a part that finished in THIS measurement: a failed, yielded-out or build_failed part, or a file
            # left over from a dropped measurement, has no rows here.
            if p.get("state") != "done":
                continue
            worker = p.get("worker")
            if not (isinstance(worker, str) and HOST_RE.match(worker)):
                # Stored before parts carried the host that ran them: no host to name its rows with.
                p.update(state="failed", reason="the part was stored without the host that ran it")
                continue
            try:
                with open(os.path.join(o.dir, "parts", f"{name}.json")) as f:
                    stored = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(stored, dict) or stored.get("measurement") != measurement_id(cur):
                continue
            report = stored.get("report")
            if report_is_incomplete(PART_BY_NAME[name], report):
                # Keep the rows below so a partial run can still identify a
                # regression, but make finish_measurement preserve the prior
                # last/last_good records just as it does for a failed part.
                cur["parts"][name]["state"] = "incomplete"
                cur["parts"][name]["incomplete"] = report.get("incomplete")
                cur["parts"][name]["why"] = incomplete_why(report)
                if not is_linux_part(name):
                    # The host did run, but this is not a completed fleet part
                    # for next_now(): do not immediately chain another tick
                    # into a still-open regression after partial coverage.
                    fleet_done = False
            named, r = part_rows_named(cur, name, p, report, mod, budgets, worker)
            if r:
                refresh.append(r)
            rows.update(named)
        refresh_ms = sorted(refresh)[len(refresh) // 2] if refresh else None
        sha = cur["sha"]
        fleet_ran = any(p.get("state") in ("done", "incomplete") and not is_linux_part(n)
                        for n, p in cur["parts"].items())
        host = cur.get("host") if fleet_ran else "a GitHub Linux runner (no Mac part ran)"
        macos = cur.get("macos") if fleet_ran else None
        event = finish_measurement(state, rows, refresh_ms, host, o.run_url, t, mod, macos)
        rebased_note = (state.get("history") or [{}])[-1].get("rebased_note") or ""
        clear_parts(o.dir)
        regs = state.get("regressions") or []
        note = (state.get("history") or [{}])[-1].get("note") or ""
        summary = {"first": f"first measurement {sha[:12]} ({len(rows)} rows) is the baseline",
                   "good": f"{sha[:12]}: no row regressed ({len(rows)} rows)",
                   "recovered": f"{sha[:12]}: every row is back within its threshold ({len(rows)} rows)"
                                + (f"; {rebased_note}" if rebased_note else ""),
                   "regressed": f"{sha[:12]}: {len(regs)} row(s) regressed: " + ", ".join(r["name"] for r in regs[:8]),
                   "still": f"{sha[:12]}: still regressed, {len(regs)} row(s): " + ", ".join(r["name"] for r in regs[:8])
                            + (f"; {note}" if note else ""),
                   "empty": f"{sha[:12]}: no row measured (failed parts: "
                            f"{', '.join((state.get('history') or [{}])[-1].get('failed_parts') or []) or 'none'})",
                   "partial": f"{sha[:12]}: no measured row regressed ({len(rows)} rows); {note}",
                   "narrowed": f"bisect {sha[:12]}: {note}",
                   "skipped": f"bisect {sha[:12]}: {note}"}[event]
    if event == "empty":
        event = None  # neither a baseline nor a verdict: the issue is left as it is (staleness still counts)
    line = summary or "no measurement finished this tick"
    stale = stale_hours(state, t) > STALE_HOURS
    if stale:
        line += f"; stale: no finished measurement since {stale_basis(state)}"
    old_parts = stale_parts(state, t)
    if old_parts:
        line += (f"; {len(old_parts)} of {len(state.get('part_stored') or {})} part(s) stored no rows for over "
                 f"{STALE_HOURS} h: {', '.join(old_parts[:8])}")
    # An issue update GitHub refused for the rate limit is made by the next tick (its event and summary are kept).
    retry = state.pop("issue_retry", None) if not event else None
    if retry:
        event, summary = retry.get("event"), retry.get("summary") or summary
        changed = True
    before = json.dumps(state, sort_keys=True)
    seen_before = state.get("issue_seen") if isinstance(state.get("issue_seen"), dict) else None
    not_measuring = state.get("not_measuring")
    if not not_measuring:
        state.pop("not_measuring_noted", None)
    else:
        line += f"; NOT MEASURING: {not_measuring}"
    try:
        if o.issues and (event or (stale and state.get("stale_noted_for") != stale_basis(state))
                         or unnoted_restarts(state) or (not_measuring and state.get("not_measuring_noted") != not_measuring)):
            set_changed = bool(retry and retry.get("set_changed")) or \
                sorted(r["name"] for r in state.get("regressions") or []) != before_names
            noting = not_measuring and state.get("not_measuring_noted") != not_measuring
            line += "; " + manage_issue(o.repo, state, event, t, o.run_url,
                                        f"NOT MEASURING: {not_measuring}" if noting and not summary else summary or line,
                                        set_changed)
            if noting:
                state["not_measuring_noted"] = not_measuring
        elif o.issues and state.get("issue"):
            try:
                rewrote = refresh_issue_body(o.repo, state, t)
            except RateLimited:
                raise
            except (urllib.error.URLError, TimeoutError, ValueError) as error:
                rewrote = f"the issue body was not checked ({error!r})"
            line += f"; {rewrote}" if rewrote else ""
    except RateLimited as error:
        if event:
            state["issue_retry"] = {"event": event, "summary": summary or line, "set_changed":
                                    sorted(r["name"] for r in state.get("regressions") or []) != before_names}
        # The next tick checks the issue again (no hash), but keeps whether the cron last left it open: a person's close
        # after this tick still acknowledges the restarts (acknowledge_restarts), and the cron does not reopen for them.
        if seen_before is None:
            state.pop("issue_seen", None)
        else:
            state["issue_seen"] = {"hash": None, "open": seen_before.get("open")}
        line += f"; the issue was not updated (GitHub rate limit: {error}); the next tick does it"
    changed = changed or json.dumps(state, sort_keys=True) != before
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    nxt = next_now(state, fleet_done)
    if nxt:
        line += "; a measure host is idle: the next tick starts now"
    # The budget of every producer, each tick (perf-budget-table.py): one summary line, then each row over or not measured.
    mod, budget = budget_report(state, t)
    budget_lines = mod.text_lines(budget) if mod else [budget]
    line += f"; {budget_lines[0]}"
    print(f"perf-cron report: {line}")
    for text in budget_lines:
        print(f"perf-cron budget: {text}")
    write_outputs(o.output, {"changed": "true" if changed else "false", "line": line.replace("\n", " "),
                             "next_now": "true" if nxt else "false",
                             "not_measuring": (not_measuring or "").replace("\n", " ")})


def next_now(state, fleet_done):
    """Start the next tick at once (pure): a Mac part finished this tick (so its host was idle and stayed
    free for the whole part) and Mac work is left: a fleet part of the measurement in flight, or an open culprit
    range to bisect. The next tick plans and checks the fleet itself, so it still yields; the chain ends at the first
    tick whose Mac part does not finish (yield, fleet check no, failure) or when no Mac work is left."""
    if not fleet_done:
        return False
    cur = state.get("current")
    if cur:
        return any(not is_linux_part(p) for p in cur.get("parts_todo") or [])
    return bool(bisect_groups(state))


# The Linux parts on the build controller (Leo, 2026-11-19, on Blacksmith: "stop ... relying on it"; Blacksmith stays
# only as an overflow fallback). With vars.CMUX_NEXT_PERF_CRON_LINUX_CONTROLLER=1 the plan asks for the Linux part with
# the job `perf cron request <sha> <part>` (the Mac parts' route, cmuxterm-hq perf_cron.go perfCronLinuxParts): the
# controller runs LINUX_SCRIPT on an idle Linux pool worker of one machine type, which calls run-linux-part unchanged
# and returns its report and result as LINUX_STEP_ARTIFACT. The rows carry LINUX_FLEET_CLASS, never the VM's name
# (each pool VM is new, so its rows would never have a reference). A request with no answer within
# linux_answer_minutes is unanswered, and so is a yielded answer at once (the controller found no idle Linux worker,
# the step was pre-empted or timed out in its queue, or its setup failed); after LINUX_REQUESTS_MAX of them the part
# runs on the runner job once, and then the controller is asked again.
LINUX_SCRIPT = "scripts/measure/perf-cron-linux.sh"
LINUX_STEP_ARTIFACT = "artifacts/perf-cron-linux/step.json"
LINUX_FLEET_CLASS = "fleet-linux-c4d-32"
LINUX_REQUESTS_MAX = 2
# Past the part's own cap: the controller keeps a request until a worker is idle (perfCronWaitFor), and the result
# reaches the state through a result run or replay-results.
LINUX_ANSWER_SLACK_MINUTES = 60
# The Linux parts the controller never runs: cloud-claim reads the production Cloud journey's artifacts with the run's
# own token (the linux job's GH_TOKEN), which a pool worker has not. Asked of the controller, it waited two answer
# windows (about 3 h 20 min) for an answer that never comes before it ran on the runner.
LINUX_RUNNER_ONLY = frozenset({"cloud-claim"})


def linux_answer_minutes(part):
    """How long a Linux part's request may go unanswered before it counts as such (pure)."""
    return linux_job_minutes(part) + LINUX_ANSWER_SLACK_MINUTES


def linux_route(cur, part, t, controller, has_script):
    """Where this tick runs Linux part PART: 'request' (ask the build controller), 'wait' (a request is in its answer
    window: nothing else runs it) or 'runner' (the linux job). Keeps cur['linux_requests'][part]; record_part clears
    it. Without the controller route, or at a commit without LINUX_SCRIPT, always 'runner'."""
    if not controller or not has_script or part in LINUX_RUNNER_ONLY:
        return "runner"
    asks = cur.setdefault("linux_requests", {})
    ask = asks.get(part) if isinstance(asks.get(part), dict) else None
    if ask is None:
        asks[part] = {"asked_at": iso(t), "unanswered": 0}
        return "request"
    asked = parse_started(ask.get("asked_at"))
    if asked and (t - asked).total_seconds() < linux_answer_minutes(part) * 60 and not ask.get("answered_at"):
        return "wait"
    ask.pop("answered_at", None)  # a yielded answer (record_part): unanswered now
    if ask.get("fell_back_at"):
        # The runner had its window too: back to the controller, a new count.
        asks[part] = {"asked_at": iso(t), "unanswered": 0}
        return "request"
    ask["unanswered"] = int(ask.get("unanswered") or 0) + 1
    ask["asked_at"] = iso(t)
    if ask["unanswered"] >= LINUX_REQUESTS_MAX:
        ask["fell_back_at"] = iso(t)
        return "runner"
    return "request"


def linux_picks(cur, order, t, controller, has_script):
    """This tick's Linux parts (runner parts, controller request, parts waiting), taking ORDER's parts in turn: every
    part linux_route sends to the runner joins the linux matrix (one runner each, all at once), the first it sends to
    the controller is asked, and a part whose request is in its answer window (linux_route 'wait') holds back only
    itself. The linux and linux-request jobs are separate, so one tick may run parts on the runners and ask the
    controller for another. linux_route keeps state, so it runs on a copy to look and on CUR only for the parts
    picked. Before 2026-11-23 the first part in order alone was routed: while coord-sim's request waited (about 3 h a
    window), no Linux part ran, and a superseded measurement (no Mac part) stored 5 Linux parts in 19 h."""
    look = {"linux_requests": copy.deepcopy(cur.get("linux_requests") if isinstance(cur.get("linux_requests"), dict) else {})}
    runners, request, waiting = [], "", []
    for part in order:
        how = linux_route(look, part, t, controller, has_script)
        if how == "wait":
            waiting.append(part)
        elif how == "runner":
            runners.append(part)
        elif how == "request" and not request:
            request = part
    for part in (*runners, request):
        if part:
            linux_route(cur, part, t, controller, has_script)
    return runners, request, waiting


def commit_has(sha, path):
    """Whether commit SHA has PATH (the clone the plan runs in)."""
    return bool(sha) and has_path(sha, path)


def linux_step_files(artifact, result):
    """(report, result) of a Linux part's controller step from its LINUX_STEP_ARTIFACT (pure): run-linux-part's own
    report and result, the result's worker the fleet class. An artifact without both is a failed part, no report."""
    inner = artifact.get("result") if isinstance(artifact, dict) else None
    report = artifact.get("report") if isinstance(artifact, dict) else None
    if isinstance(inner, dict) and inner.get("state") == "yielded" and report is None:
        # perf-cron-linux.sh's setup failed: a yield (record_part counts it as an unanswered request), no rows.
        tail = [str(x) for x in inner.get("tail") or []][-40:]
        return None, {**result, "state": "yielded", "worker": LINUX_FLEET_CLASS, "tail": [*result.get("tail", []), *tail]}
    if not isinstance(inner, dict) or not isinstance(report, dict):
        return None, {**result, "state": "failed", "tail": [*result.get("tail", []), "the Linux step's artifact has no report and result"]}
    worker = inner.get("worker") if isinstance(inner.get("worker"), str) and HOST_RE.match(inner["worker"]) else LINUX_FLEET_CLASS
    state = inner.get("state") if inner.get("state") in ("done", "failed") else "failed"
    tail = [str(x) for x in inner.get("tail") or []][-40:]
    return report, {**result, "state": state, "worker": worker, "seconds": inner.get("seconds", result.get("seconds")),
                    "tail": [*result.get("tail", []), *tail]}


# The controller route (cmuxterm-hq build-fleet/cmd/controller/perf_cron.go, CMUX_CI_PERF_CRON=1): the plan's job
# `perf cron request <sha> <part>[ on <worker>]` asks the controller for the part; it queues the background step on an
# idle measure worker (the named one, else cmux20-bench first, then the others), and dispatches this workflow with
# perf_result when the step ends. A request it does not queue gets no answer: decide counts the wait as a yield.
RESULT_STATES = ("done", "failed", "yielded")


def controller_result(raw):
    """The controller's perf_result input as a dict, or None when it is not one (pure)."""
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return None
    # A field of the wrong type (a feed entry's "part": []) is no result, not a TypeError (review of cmux#47673).
    if not isinstance(value, dict) or not is_sha(str(value.get("sha") or "")) or not isinstance(value.get("part"), str) \
            or value.get("part") not in PART_BY_NAME \
            or not isinstance(value.get("state"), str) or value.get("state") not in RESULT_STATES \
            or not isinstance(value.get("step_id"), (str, int, type(None))):
        return None
    return value


def controller_results(raw):
    """The controller's perf_result as a list of results (pure): one result (controller_result), or a batch's
    {"results": [...]} (perfCronDispatchBatch), each kept only when it is a result. Empty when none is."""
    one = controller_result(raw)
    if one is not None:
        return [one]
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return []
    listed = value.get("results") if isinstance(value, dict) else None
    if not isinstance(listed, list):
        return []
    out = [controller_result(json.dumps(v)) for v in listed[:BATCH_MAX + 1]]  # the parts and the one pre-empted
    return [v for v in out if v is not None]


def result_refusal(state, value):
    """Why the controller's result (controller_result) is not stored into state, or None (pure). A result for another
    measurement, or for a part not to do, is dropped (a late result after an abandon); so is a step stored already
    (the controller may send a result twice: a lost answer, a restart; replay-results reads it again), and so is a step
    that ended before the measurement started (an older measurement of the same SHA; review of cmux#47673)."""
    cur = state.get("current") or {}
    if value is None:
        return "the controller's perf_result is not a result"
    ended, started = controller_ended_at(value), parse_started(cur.get("started_at"))
    if ended and started and ended < started:
        return (f"the controller's {value['part']} result of step {value.get('step_id') or '?'} ended "
                f"{iso(ended)}, before the measurement in flight started ({iso(started)}); dropped")
    if value.get("step_id") and value["step_id"] in {(e or {}).get("step_id") for e in (cur.get("parts") or {}).values()}:
        return f"the controller's result of step {value['step_id']} was stored already; dropped"
    if value["sha"] != cur.get("sha") or value["part"] not in (cur.get("parts_todo") or []):
        return (f"the controller's {value['part']} result for {value['sha'][:12]} is not for the measurement in "
                f"flight ({str(cur.get('sha') or 'none')[:12]}); dropped")
    return None


def result_plan(o, state, t):
    """A run the controller started with a part's result, or a batch's results: plan nothing new; the report job
    stores the parts (result_refusal says which results it drops). result_parts: the parts it stores, in the order
    they ran; part: the first of them."""
    values = controller_results(o.perf_result) or [None]
    out = {"action": "none", "sha": "", "part": "", "linux_matrix": "[]", "result_parts": "", "frame_pacing": "false",
           "stale_hours": round(stale_hours(state, t), 1)}
    kept, refused = [], []
    for value in values:
        why = result_refusal(state, value)
        if not why and value["part"] in {v["part"] for v in kept}:
            why = f"the controller's batch has a second result of part {value['part']}; dropped"
        (refused.append(why) if why else kept.append(value))
    for why in refused:
        print(f"perf-cron plan: {why}")
    if not kept:
        out["reason"] = "; ".join(refused)
    else:
        first = kept[0]
        what = (f"the controller's {first['state']} result of part {first['part']} at {first['sha'][:12]}"
                f" (step {first.get('step_id') or '?'})") if len(kept) == 1 else \
            (f"the controller's batch at {first['sha'][:12]}: " + ", ".join(f"{v['part']} {v['state']}" for v in kept))
        out.update({"action": "result", "sha": first["sha"], "part": first["part"],
                    "result_parts": " ".join(v["part"] for v in kept), "reason": what})
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    print(f"perf-cron plan: {json.dumps(out)}")
    write_outputs(o.output, out)


def result_files(value):
    """result.json for record_part from the controller's result (pure): a failed build part ends the other Mac
    parts (build_failed), a step past its cap is timed out, a pre-empted or unstarted one yielded."""
    tail = [line for line in (value.get("error"),) if line]
    return {"state": value["state"], "step_id": value.get("step_id"), "seconds": value.get("seconds"),
            "exit": value.get("exit_code"), "yielded_to": value.get("preempted_by"),
            "worker": LINUX_FLEET_CLASS if is_linux_part(value.get("part")) else value.get("worker"),
            "timed_out": bool(value.get("timed_out")), "tail": tail, "host_gone": bool(value.get("host_gone")),
            "build_failed": value.get("part") == "build" and value["state"] == "failed" and not value.get("timed_out")}


def cmd_fetch_result(o):
    """The report job's side of the controller route: result.json, and report.json from the step's signed artifact
    URL, in --out, or for each part in --out/PART with --each (a batch's results; the first of a part is kept). A
    done step whose artifact cannot be read is a failed part (its rows would be missing)."""
    if getattr(o, "each", False):
        values = controller_results(o.result)
        if not values:
            print("perf-cron fetch-result: no result; nothing written")
        for value in values:
            out = os.path.join(o.out, value["part"])  # an allowlisted name (controller_result), never a path
            if not os.path.exists(out):
                write_result(value, out)
        return
    value = controller_result(o.result)
    if value is None:
        os.makedirs(o.out, exist_ok=True)
        print("perf-cron fetch-result: not a result; nothing written")
        return
    write_result(value, o.out)


def write_result(value, out):
    """cmd_fetch_result's files for one result in the directory out."""
    os.makedirs(out, exist_ok=True)
    result = result_files(value)
    if value["state"] == "done":
        url = str(value.get("artifact_url") or "")
        try:
            if not url.startswith("https://"):
                raise ValueError("no https artifact URL")
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-perf-cron"}), timeout=120) as r:
                report = json.load(r)
            if is_linux_part(value["part"]):
                report, result = linux_step_files(report, result)
            if report is not None:
                with open(os.path.join(out, "report.json"), "w") as f:
                    json.dump(report, f)
        except (OSError, ValueError, urllib.error.URLError) as error:
            result.update(state="failed", tail=result["tail"] + [f"artifact not read: {error!r}"])
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(result, f)
    print(f"perf-cron fetch-result: part {value['part']} at {value['sha'][:12]}: {result['state']}")


# The controller also serves its done results itself (cmuxterm-hq perf_cron.go servePerfCronResults: GET
# /perf-cron/results.json, the last 24 h): a result run waits for a runner on the shared Linux queue (each tick took
# ~16 h on 2026-11-19, and no Mac row was stored for 2 days), so a reader of the state replays them into its copy.
CONTROLLER_RESULTS_URL = "https://gh-events.cmux.com/perf-cron/results.json"
GO_TIME_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z$")


def controller_ended_at(value):
    """When the controller's step ended (its ended_at, Go's RFC 3339 with nanoseconds), to the second, or None (pure)."""
    m = GO_TIME_RE.match(str(value.get("ended_at") or ""))
    try:
        return parse_iso(m.group(1) + "Z") if m else None
    except ValueError:
        return None


def controller_ended_key(value):
    """A sort key for the controller's results in the order their steps ended, fractional seconds included (text
    puts .11Z before .1Z; review of cmux#47673); a result with no readable end sorts last (pure)."""
    at = controller_ended_at(value)
    m = GO_TIME_RE.match(str(value.get("ended_at") or ""))
    return (0, at, (m.group(2) or "").ljust(9, "0")) if at and m else (1,)


def parse_started(s):
    """A measurement's started_at, or None when it is not a time (pure)."""
    try:
        return parse_iso(s) if isinstance(s, str) else None
    except ValueError:
        return None


def cmd_replay_results(o):
    """A reader's copy of the state (the probe's, after fetch-state): store the controller's done results whose result
    run has not stored them yet, oldest first, each with this script's own report (no issue, no GitHub call) at the
    time its step ended, so a row reads as old as its measurement. The cron's own state is not touched: its result
    run stores the same part when it runs. Prints what it stored; never fails for a result it cannot read."""
    try:
        if o.file:
            raw = json.load(open(o.file))
        else:
            with urllib.request.urlopen(urllib.request.Request(o.url, headers={"User-Agent": "cmux-perf-cron"}), timeout=60) as r:
                raw = json.load(r)
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"perf-cron replay-results: the controller's results were not read ({error!r}); the state is as fetched")
        return
    listed = raw.get("results") if isinstance(raw, dict) else None
    values = [v for v in listed if isinstance(v, dict)] if isinstance(listed, list) else []
    stored = 0
    os.makedirs(os.path.join(o.dir, "replay"), exist_ok=True)
    for value in sorted(values, key=controller_ended_key):
        value = controller_result(json.dumps(value))
        at = controller_ended_at(value) if value else None
        if value is None or value["state"] != "done" or at is None:
            continue
        why = result_refusal(load_state(o.dir, at), value)
        if why:
            print(f"perf-cron replay-results: {why}")
            continue
        # A fresh directory per part, never named from the feed: a step_id of "../x" or "/abs" must not place
        # result.json or report.json outside the copy (review of cmux#47673).
        part_dir = tempfile.mkdtemp(prefix="part-", dir=os.path.join(o.dir, "replay"))
        cmd_fetch_result(argparse.Namespace(result=json.dumps(value), out=part_dir))
        # An artifact not read (expired, a network error) is no verdict on the part: fetch-result writes it as failed,
        # which report would take out of parts_todo and a later readable result of the part would be dropped.
        if not os.path.exists(os.path.join(part_dir, "report.json")):
            print(f"perf-cron replay-results: the artifact of step {value.get('step_id') or '?'} was not read; "
                  f"part {value['part']} left pending")
            continue
        report(argparse.Namespace(repo="", dir=o.dir, result=[f"{value['part']}={part_dir}"], run_url="", finish=False,
                                  issues=False, output=os.path.join(o.dir, "replay", "report.out")), t=at)
        stored += 1
    print(f"perf-cron replay-results: {stored} of {len(values)} controller result(s) stored into this copy")


def cmd_dispatch_next(o):
    """Dispatch this workflow on the measured branch (the report job's last step when next_now said so)."""
    try:
        gh_request(f"/repos/{o.repo}/actions/workflows/{os.path.basename(STATE_WORKFLOW)}/dispatches", "POST",
                   {"ref": STATE_BRANCH})
        print(f"perf-cron: dispatched the next tick of {os.path.basename(STATE_WORKFLOW)} on {STATE_BRANCH}")
    except RateLimited as error:
        print(f"perf-cron: the next tick was not dispatched (GitHub rate limit: {error}); the dispatcher starts one")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("fetch-state", help="download the newest perf-cron-state artifact")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--wait-limit", type=int, default=0,
                   help="wait at most this many seconds for a rate limit's reset, then read the state again (0: never)")
    s = sub.add_parser("plan", help="pick this tick's work (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--tip", default="HEAD")
    s.add_argument("--yield-mode", default="queued", choices=["queued", "running"])
    s.add_argument("--no-mac", action="store_true", help="no route for the Mac parts: plan only the Linux part")
    s.add_argument("--linux-controller", action="store_true",
                   help="ask the build controller for the Linux part first (vars.CMUX_NEXT_PERF_CRON_LINUX_CONTROLLER=1)")
    s.add_argument("--controller", action="store_true",
                   help="the Mac parts go through the build controller's request route: a request has no answer until "
                        "its result run, so that wait is a yield, not active time")
    s.add_argument("--perf-result", default="", help="the controller's perf_result: plan nothing, the report stores it")
    s.add_argument("--output")
    s = sub.add_parser("fleet-check", help="may a part run on its host now (gateway)")
    s.add_argument("--worker", default=BENCH_WORKER)
    s.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
    s.add_argument("--yield-mode", default="queued", choices=["queued", "running"])
    s.add_argument("--output")
    s.add_argument("--not-started", help=f"when the answer is no, write {NOT_STARTED} with the reason here")
    s = sub.add_parser("run-part", help="run one part on its host (gateway)")
    s.add_argument("--sha", required=True)
    s.add_argument("--args", required=True, help="JSON list of split-spring.sh args")
    s.add_argument("--artifact", required=True)
    s.add_argument("--key", required=True)
    s.add_argument("--run-seconds", type=int, default=PART_RUN_SECONDS)
    s.add_argument("--out", required=True)
    s.add_argument("--worker", default=BENCH_WORKER)
    s.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
    s = sub.add_parser("part-cleanup", help="after run-part, on every exit: cancel a step left running, write a result (gateway)")
    s.add_argument("--out", required=True)
    s.add_argument("--why", default="the job ended")
    s.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
    s = sub.add_parser("run-linux-part", help="run one Linux part (in a checkout of the measured commit)")
    s.add_argument("--part", default="diff-viewer", choices=[p["name"] for p in PARTS if p.get("where") == "linux"])
    s.add_argument("--out", required=True)
    s.add_argument("--runner-class", default=os.environ.get("PERF_CRON_RUNNER_CLASS", ""),
                   help="the runner label the job ran on: the Linux rows' host (compared only within one class)")
    s = sub.add_parser("report", help="store the parts, finish the measurement, keep the issue (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--result", action="append", default=[], metavar="PART=DIR",
                   help="a part that ran this tick and the directory with its result.json (repeatable)")
    s.add_argument("--run-url", default="")
    s.add_argument("--linux-job", default="",
                   help="the linux matrix job's result (needs.linux.result): why a Linux part left no result.json")
    s.add_argument("--linux-download", default="",
                   help="the outcome of the report's download of the Linux parts' artifacts (not success: one attempt)")
    s.add_argument("--finish", action="store_true", help="finish a measurement whose parts all ran")
    s.add_argument("--issues", action="store_true", help="open, update or close the regression issue")
    s.add_argument("--output")
    s = sub.add_parser("fetch-result", help="write a controller result's result.json and report.json (report job)")
    s.add_argument("--result", required=True, help="the perf_result JSON")
    s.add_argument("--out", required=True)
    s.add_argument("--each", action="store_true", help="each result's files in OUT/PART (a batch's results)")
    s = sub.add_parser("replay-results", help="store the controller's done results into a reader's copy of the state")
    s.add_argument("--dir", required=True, help="fetch-state's directory")
    s.add_argument("--url", default=CONTROLLER_RESULTS_URL)
    s.add_argument("--file", help="read the results from this file instead of --url")
    s = sub.add_parser("dispatch-next", help="start the next tick now (report, when a measure host stayed idle)")
    s.add_argument("--repo", required=True)
    o = ap.parse_args(argv)
    {"fetch-state": cmd_fetch_state, "plan": cmd_plan, "fleet-check": cmd_fleet_check, "run-part": cmd_run_part,
     "part-cleanup": cmd_part_cleanup, "run-linux-part": cmd_run_linux_part,
     "report": cmd_report, "dispatch-next": cmd_dispatch_next, "fetch-result": cmd_fetch_result,
     "replay-results": cmd_replay_results}[o.cmd](o)


if __name__ == "__main__":
    main()
