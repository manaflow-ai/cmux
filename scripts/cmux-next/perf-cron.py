#!/usr/bin/env python3
"""cmux-next perf cron: opportunistic, lowest-priority perf measurement of the feat-cmux-next tip.

Lawrence 2026-10-23: no perf gate may block or slow a push, a pull request merge or a nightly build; perf
runs on a cron instead, only on idle fleet capacity, behind every nightly and dev build. The workflow
(.github/workflows/cmux-next-perf-budgets.yml, started by main's cmux-next-perf-cron-dispatch.yml every
20 minutes) runs one tick:

  plan (Linux)      reads the state (the newest `perf-cron-state` artifact), picks the work: the next part of
                    the measurement in flight, else the newest feat-cmux-next commit whose cmux-tui tree is
                    published (a fleet build needs it) when it is newer than the last measured one (commits
                    in between are skipped), else one bisect step of an open regression. Skips while a
                    nightly or dev build waits for a Mac on GitHub.
  measure (gateway) runs only on its own runner label (vars.CI_PERF_CRON_GATEWAY), skips unless the part's host
                    (the measurement's, else cmux20-bench) is idle and no dev build waits in the controller queue,
                    then runs ONE part (its run_seconds: 15 minutes, the build 20, STRESS and sidebar 25) as a
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

Subcommands: fetch-state, plan, fleet-check, run-part, part-cleanup, run-linux-part, report, dispatch-next (see each
--help). Tests: scripts/cmux-next/tests/test_perf_cron.py (decisions) and test_perf_cron_io.py (GitHub, git, the
fleet client and multi-tick runs, faked) (run them yourself; no CI job runs them).
"""
import argparse, collections, datetime, hashlib, importlib.util, io, json, os, re, subprocess, sys, time, urllib.error
import urllib.parse, urllib.request, zipfile

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
# A Mac host that ran no part for this long while Mac parts ran on other hosts is gone (it left the fleet, or it is
# never idle): its open regressions close as not judged, since it can neither confirm nor clear them (12 tip
# measurements at TIP_EVERY_HOURS went to other hosts meanwhile).
HOST_GONE_HOURS = 72
LATENCY_TARGET_MS = 10.0
STALE_HOURS = 24
ABANDON_HOURS = 12          # of active time: the hours a measurement spent yielding to the fleet do not count
ABANDON_WALL_HOURS = 48     # the hard cap, yielding included
MAX_YIELDS = 3
PART_RUN_SECONDS = 900      # one part, its app build included (Lawrence: under 15 minutes each)
PART_QUEUE_SECONDS = 300    # a part that does not start at once gives its place back
CANDIDATE_DEPTH = 80
# feat-cmux-next gets ~400 first-parent commits a day and a tip measurement takes 3 h or more, so a newer tip
# always exists: while a regression range can be bisected, a tip measurement starts at most once per TIP_EVERY_HOURS
# and the ticks in between go to the bisect.
TIP_EVERY_HOURS = 6
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
    # 400 workspaces, 6 scenarios: not timed against 900 s yet (perf-budgets' own per-bench cap is 900 s).
    {"name": "sidebar", "args": [*MEASURE, "--suite=budgets", "--only=sidebar"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets", "run_seconds": 1500},
    {"name": "home-idle", "args": [*MEASURE, "--suite=budgets", "--only=home,idle"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "chat-anim", "args": [*MEASURE, "--suite=budgets", "--only=acp,anim"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    # The diff-viewer budgets that left ci-web.yml (scripts/benchmark-diff-viewer.sh), on Linux.
    {"name": "diff-viewer", "where": "linux", "kind": "diff", "needs": "diff-viewer"},
]
PART_BY_NAME = {p["name"]: p for p in PARTS}
# Which part measures a row (bisect re-measures only the parts of the regressed rows).
ROW_PARTS = [
    (r"^panes\.[^.]+\.stress\.", "stress"), (r"^panes\.", "motion"), (r"^(cmd_n|cmd_t|ctrl_backtick|cmd_d|cmd_shift_d)\.", "motion"),
    (r"^(tab_switch|palette)\.", "switch"), (r"^perf_gate\.", "perf-gate"), (r"^(sidebar|workspace_switch)\.", "sidebar"),
    (r"^(home|idle)\.", "home-idle"), (r"^(acp|anim)\.", "chat-anim"), (r"^launch\.", "launch"),
    (r"^diff\.", "diff-viewer"),
]
# The diff-viewer budgets of scripts/benchmark-diff-viewer.sh (its env defaults), as rows where lower is better.
DIFF_BUDGETS = {"diff.sidecar.manifest_decode_p95": 1000.0, "diff.sidecar.read_ms_per_gib": 1024 * 1000 / 500.0,
                "diff.stream.p95": 250.0}
# The launch-time budget that left the pull request CI (ms since process start, warm launch, empty profile).
LAUNCH_BUDGETS = {"did_finish_launching_end": 800, "first_window_frame_committed": 1000, "sidebar_rows_shown": 1000}


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
        for _tag, modes in report.items():
            for mode, runs in (modes or {}).items() if isinstance(modes, dict) else []:
                runs = runs if isinstance(runs, list) else []
                for mark, budget in LAUNCH_BUDGETS.items():
                    values = [r[mark] for r in runs if isinstance(r, dict) and isinstance(r.get(mark), (int, float))]
                    if runs:
                        # A launch that hangs never sends the mark: the old CI budget failed on that, so it is a
                        # row of its own (target 0), and a run with no marks at all misses every one.
                        missing = len(runs) - len(values)
                        out[f"launch.{mode}.{mark}.missing_runs"] = {"p50": missing, "p95": missing, "unit": "runs",
                                                                     "budget": 0, "floor": 0.5}
                    if values:
                        p50, p95 = budgets_mod.pct(values, 0.5), budgets_mod.pct(values, 0.95)
                        out[f"launch.{mode}.{mark}"] = {"p50": round(p50, 1), "p95": round(p95, 1), "unit": "ms",
                                                        "budget": budget, "floor": 20.0}
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
        for name, (v, unit, floor) in values.items():
            out[name] = {"p50": v, "p95": v, "unit": unit, "budget": DIFF_BUDGETS[name], "floor": floor}
            version = versions.get(name.split(".")[1])  # sidecar or stream
            out[name]["measure_version"] = version if isinstance(version, int) else DIFF_LEGACY_VERSION
    return out


def report_is_incomplete(part, report):
    """Whether a completed bench report explicitly says its coverage is incomplete.

    Budget parts run without ``--gate`` so a perf-cron step can publish its
    measurements and keep the issue tracker non-blocking. Their receipt still
    carries the completeness verdict; retain measured rows for diagnostics but
    keep the overall measurement from becoming a new last-good baseline.
    Older reports and non-budget parts have no such field and remain complete.
    """
    return part.get("kind") == "budgets" and isinstance(report, dict) and bool(report.get("incomplete"))


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
    0; diff, launch and main-thread rows their budget."""
    refresh_ms = row_refresh(row, refresh_ms)
    unit = row.get("unit") or "ms"
    name = base_row(name)
    if name.startswith(("diff.", "launch.")):
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


def linux_bench_runs(root):
    """The diff-viewer part's two benches in a checkout at root, {name: (argv, cwd, extra env)}:
    scripts/benchmark-diff-viewer.sh's benches without their budget env (cmd_run_linux_part runs them; part_config
    names them with root "")."""
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
    what = linux_bench_runs("") if is_linux_part(name) else PART_BY_NAME[name].get("args")
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
    rows = {n: r for n, r in rows.items() if n not in skipped}
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


def host_gone(state, host, t):
    """host left the fleet (pure): the controller said it has no such worker (gone_at, a host_gone result), or it ran
    no part for HOST_GONE_HOURS (the caller checks that Mac parts ran elsewhere meanwhile)."""
    info = host_info(state, host)
    if info.get("gone_at") and not (info.get("last_part_at") and info["last_part_at"] > info["gone_at"]):
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
    if cur and (active_hours(cur, t) > ABANDON_HOURS or hours_between(parse_iso(cur["started_at"]), t) > ABANDON_WALL_HOURS):
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


def commit_failed(cur):
    """A part of the measurement failed on its commit (pure): its build failed, or a part ran and failed. A part
    refused for its host (it carries a reason: another host, or no host on record) is the fleet's, not the commit's."""
    return any(isinstance(p, dict) and (p.get("state") == "build_failed" or (p.get("state") == "failed" and not p.get("reason")))
               for p in (cur.get("parts") or {}).values())


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
    if not offline and not (asked and hours_between(asked, t) > HOST_WAIT_HOURS):
        return None
    why = f"{host} is offline" if offline else f"{host} took no part for {HOST_WAIT_HOURS} h"
    if not offline:
        mark_host(state, host, waited_at=iso(t))
    cur.pop("host_asked_since", None)
    if cur["kind"] == "bisect":
        state.setdefault("history", []).append({"sha": cur["sha"], "kind": "bisect", "status": "waited", "at": iso(t),
                                                "parts": sorted(cur.get("parts", {})), "note": why})
        state["current"] = None
    else:
        cur.pop("host")
        cur.setdefault("gave_up", []).append({"host": host, "at": iso(t), "why": why})
    return why


def tip_pin_host(state, t):
    """The Mac host a new tip measurement is pinned to (pure): the host of the oldest Mac row waiting for its confirming
    run (state['pending']: only a run there can confirm or clear it, so its run comes first), else of the earliest open regression of a Mac row,
    unless that host is avoided now (offline, or a measurement just gave it up: host_avoided) or gone (host_gone). A
    host's rows are judged only on that host, so a tip measured elsewhere can never confirm or clear them. None: any
    idle measure host."""
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else {}
    waiting = sorted((str((v or {}).get("at") or ""), n) for n, v in pending.items() if isinstance(n, str))
    regs = [r for r in state.get("regressions") or [] if isinstance(r, dict) and isinstance(r.get("name"), str)]
    regs.sort(key=lambda r: (str((r.get("first_bad") or {}).get("measured_at") or ""), r["name"]))
    for name in [n for _, n in waiting] + [r["name"] for r in regs]:
        host = mac_host(name)
        if host and HOST_RE.match(host) and not host_avoided(state, host, t) and not host_gone(state, host, t):
            return host
    return None


def tip_due(state, t):
    """A tip measurement may start: none finished (or was dropped) in the last TIP_EVERY_HOURS. Only consulted while
    a bisect step is also possible."""
    times = [(state.get("last_tried") or {}).get("at")]
    times += [h.get("at") for h in state.get("history") or [] if isinstance(h, dict) and h.get("kind") == "tip"]
    times = [parse_iso(x) for x in times if isinstance(x, str)]
    return not times or hours_between(max(times), t) >= TIP_EVERY_HOURS


def decide(state, t, candidate, bisect, supported_parts, github_busy, measurable=lambda sha: True, mac_disabled=None,
           controller_route=False):
    """The tick's work: {'action': 'part'|'none'|'finish', 'part': a fleet part or '', 'linux_part': '' or one}.
    May set state['current'] (a new measurement). With both a candidate and a bisect step, the bisect goes first
    unless a tip measurement is due (tip_due): a newer tip always exists, so 'bisect when idle' would never bisect.
    candidate: the newest measurable tip commit newer than the last one measured (or None).
    bisect: {'sha', 'range': {good, bad}, 'rows': [row names]}: a measurable commit inside one group of regressed
    rows' culprit range (or None); the step measures only the parts of those rows.
    supported_parts(sha) -> the PARTS names the commit can run. github_busy: a reason string or None (it holds
    back the Mac parts only; the Linux part takes no Mac). measurable(sha): the fleet would still run the commit
    (its scripts/measure/split-spring.sh is the reviewed one). mac_disabled: why no Mac part can run at all (no
    gateway runner label), or None: a tip measurement records its Mac parts as not run (so it is incomplete), and a
    bisect step measures only Linux rows. controller_route: the Mac part goes to the build controller as a request
    that has no answer until the part's result run, so the time from the request to the result is the fleet's wait
    (start_yield; record_part ends it), not the measurement's active time."""
    drop_dead_measurement(state, t, measurable)
    give_up_host(state, t)
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
        pin = tip_pin_host(state, t)
        if pin:
            cur["host"] = pin
    if cur and mac_disabled:
        disable_mac_parts(cur, mac_disabled)
    if not cur:
        return {"action": "none", "reason": "nothing new to measure: the newest measurable feat-cmux-next commit "
                                            "was measured, and no regression range to bisect"}
    if not cur["parts_todo"]:
        return {"action": "finish", "sha": cur["sha"], "reason": "every part ran; report only"}
    linux = next((p for p in cur["parts_todo"] if is_linux_part(p)), "")
    fleet = next((p for p in cur["parts_todo"] if not is_linux_part(p)), "")
    done = f"{len(cur['parts'])} of {len(cur['parts']) + len(cur['parts_todo'])} done"
    if github_busy and fleet:
        fleet = ""
        start_yield(cur, t)  # the wait does not count against ABANDON_HOURS
    if not fleet and not linux:
        return {"action": "none", "sha": cur["sha"], "reason": github_busy, "yielded": True}
    if fleet and cur.get("host"):
        cur.setdefault("host_asked_since", iso(t))  # give_up_host's clock: cleared by the host's next part result
    if fleet and controller_route:
        start_yield(cur, t)
    what = " and ".join(x for x in (fleet, linux) if x)
    return {"action": "part", "sha": cur["sha"], "kind": cur["kind"], "part": fleet, "linux_part": linux,
            "worker": (cur.get("host") or "") if fleet else "",
            "reason": f"{cur['kind']} measurement of {cur['sha'][:12]}: part {what} ({done})"
                      + (f"; the Mac parts wait: {github_busy}" if github_busy and linux else "")}


def bisect_midpoint(commits, measurable, skip=()):
    """commits: first-parent commits strictly between good and bad, oldest first. The measurable one nearest
    the middle that is not in skip (commits a bisect step could not judge: `git bisect skip`), or None."""
    commits = [c for c in commits if c not in set(skip)]
    if not commits:
        return None
    mid = len(commits) // 2
    order = sorted(range(len(commits)), key=lambda i: (abs(i - mid), i))
    for i in order:
        if measurable(commits[i]):
            return commits[i]
    return None


def bisect_measurable(rows, mac_measurable, supported_parts):
    """Whether a bisect step can judge a group's rows at commit c (returns the predicate; pure): the commit runs
    every part of the rows (supported_parts), and, when a part is a Mac part, the cron measures the commit on the
    fleet (mac_measurable: the tip's split-spring.sh measurement version and a published cmux-tui tree). A group of
    Linux rows needs neither: the diff-viewer part runs on a GitHub runner from the commit's own checkout."""
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


def http_json(url, timeout=30):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-perf-cron"}), timeout=timeout) as r:
        return json.load(r)


def fleet_verdict(status, workers, jobs, worker, yield_mode, mine=()):
    """None when the fleet lets the perf cron run a part on `worker` now, else the reason it yields.
    status: /v1/status; workers: `cmux-ci workers` ({name: heartbeat}); jobs: /v1/jobs (all recent)."""
    w = (workers or {}).get(worker)
    if not w:
        return f"{worker} is not a controller worker now"
    if not w.get("healthy"):
        return f"{worker} is not healthy"
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
            raise RateLimited(f"{method} {gh_shape(path)}: HTTP {error.code}") from error
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
            raise RateLimited(f"GET {gh_shape(url)}: HTTP {error.code}") from error
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


def tree_published(sha):
    for version in ("v2", "v1"):
        try:
            key = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/ci/cmux_tui_tree_key.py"), "--version", version, sha],
                                 capture_output=True, text=True, check=True, timeout=120).stdout.strip()
        except subprocess.SubprocessError:
            continue
        url = f"https://files.cmux.com/cmux-tui/tree/{key}/cmux-tui-aarch64-apple-darwin.sha256"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-ci"}), timeout=20) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError):
            pass
    return False


def supported_parts_at(sha):
    names = []
    for p in PARTS:
        need = p.get("needs")
        if need == "stress":
            ok = subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}:scripts/cmux-next/perf-stress-session.py"],
                                capture_output=True).returncode == 0
        elif need == "diff-viewer":
            ok = all(subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}:{path}"], capture_output=True).returncode == 0
                     for path in ("Native/DiffSidecar/Cargo.toml", "webviews/bench/diff-stream.bench.ts"))
        elif need in ("perf-gate", "launch"):
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True).stdout
            ok = f"--suite={need}" in text
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
        text = subprocess.run(["git", "-C", ROOT, "cat-file", "blob", blob], capture_output=True, text=True).stdout
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
    commit it does not have is asked of the GitHub compare API ('ahead' or 'identical': on the branch), once: known
    holds the commits a trusted earlier tick verified (feat-cmux-next is never rewritten). ok.verified lists every
    commit found on the branch, for the state. A rate-limit refusal is raised, never read as 'not on the branch' (that
    would drop the state's commits)."""
    cache = {sha: True for sha in known if is_sha(sha)}

    def ok(sha):
        if not is_sha(sha):
            return False
        if sha not in cache:
            have = subprocess.run(["git", "-C", ROOT, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode == 0
            if have:
                cache[sha] = is_ancestor(sha, tip)
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
        lines += ["", f"Newest attempt: {link(repo, tried['sha'])} at {tried.get('at')} ([run]({tried.get('run_url')})) measured no row, "
                      "or not every regressed row; it is not the last measurement."]
    if stale_hours(state, now) > STALE_HOURS:
        lines += ["", f"**Stale:** no finished measurement since {stale_basis(state)} ({round(stale_hours(state, now))} h): "
                      "no measure host had idle time, a nightly or dev build kept waiting for a Mac, the commits did not "
                      "build, the regressed rows' parts kept failing, or the tick failed."]
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


def bisect_step(state, cur, part_rows, regs):
    """Fold a bisect step into the culprit range it searched (pure). part_rows: the rows the step measured AND could
    compare (a frame row on another display refresh than its reference is not judged). bad: a row of that range
    regressed; good: every row of it was judged and is within its threshold; skip (`git bisect skip`): some row of it
    was not judged (the commit did not build, a part failed or yielded, or the display refresh differed), so the next
    step picks another commit. Returns (verdict, note)."""
    key = cur.get("bisect_range") or {}
    group = [r for r in state.get("regressions") or [] if same_range(r.get("range"), key)]
    if not group:
        return "gone", f"the range {str(key.get('good'))[:11]}...{str(key.get('bad'))[:11]} is no longer open"
    names = {r["name"] for r in group}
    regressed = names & {r["name"] for r in regs}
    unmeasured = sorted(names - set(part_rows))
    verdict = "bad" if regressed else ("skip" if unmeasured else "good")
    for r in group:
        rng = r["range"]
        rng["steps"] = rng.get("steps", 0) + 1
        if verdict == "bad":
            rng["bad"] = cur["sha"]
        elif verdict == "good":
            rng["good"] = cur["sha"]
        elif cur["sha"] not in (rng.setdefault("skip", [])):
            rng["skip"].append(cur["sha"])
    rng = group[0]["range"]
    where = f"range now {rng['good'][:11]}...{rng['bad'][:11]}"
    if verdict == "skip":
        return verdict, f"skipped, {', '.join(unmeasured[:6])} not measured; {where}"
    return verdict, f"{verdict} ({', '.join(sorted(regressed)[:6]) or 'every row within its threshold'}); {where}"


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
    state["last_tried"] = {"sha": cur["sha"], "at": iso(t), "run_url": run_url}
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
    linux_classes = {row_host(n) for n in part_rows if linux_row(n)}
    for name in list(state.get("pending") or {}):
        unjudged = name not in judged and row_host(name) in ran_here and part_for_row(name) in done_parts
        gone = bool(mac_ran) and bool(mac_host(name)) and host_gone(state, mac_host(name), t)
        class_changed = linux_row(name) and bool(linux_classes) and row_host(name) not in linux_classes
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
            regressions.append({**prev, "recovering": streak})
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
    linux_classes = {row_host(n) for n in part_rows if linux_row(n)}
    class_gone = sorted(n for n in old if n not in judged and linux_row(n) and linux_classes
                        and row_host(n) not in linux_classes)
    if class_gone:
        notes.append(note_list(f"the Linux runner class is now {', '.join(sorted(map(str, linux_classes)))}, not judged",
                               class_gone))
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


def cmd_fetch_state(o):
    try:
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


def cmd_plan(o):
    try:
        plan(o)
    except RateLimited as error:
        # Nothing written: the state file stays the one fetched, so the report saves nothing and the next tick
        # starts from the same state.
        out = {"action": "none", "sha": "", "part": "", "linux_part": "", "worker": "", "frame_pacing": "false",
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
    candidate = None
    if not state.get("current"):
        for sha in git("rev-list", "--first-parent", f"-n{CANDIDATE_DEPTH}", tip).split():
            if sha == last_sha or (last_sha and is_ancestor(sha, last_sha)):
                break
            if not fleet_runs(sha, tip_version):
                print(f"perf-cron: {sha[:12]} has another {MEASURE_SCRIPT} measurement version than the tip's ({tip_version})")
                break
            if tree_published(sha):
                candidate = sha
                break
            print(f"perf-cron: {sha[:12]} has no published cmux-tui tree yet; trying its parent")
    bisect = None
    if not state.get("current") and not (candidate and tip_due(state, t)):
        for group in bisect_groups(state):
            rng = group["range"]
            if any(host_avoided(state, h, t) or host_gone(state, h, t) for h in {mac_host(n) for n in group["rows"]} - {None}):
                # A gone host (the controller has no such worker) would answer every step with host_gone: its rows
                # close at the next tip measurement elsewhere instead.
                print(f"perf-cron: the range {rng['good'][:12]}...{rng['bad'][:12]} waits: its host was offline, "
                      "took no part lately, or left the fleet")
                continue
            between = range_commits(rng["good"], rng["bad"])
            if between is None:
                continue
            ok = bisect_measurable(group["rows"], lambda c: fleet_runs(c, tip_version) and tree_published(c),
                                   supported_parts_at)
            sha = bisect_midpoint(between, ok, rng.get("skip") or [])
            if sha:
                bisect = {"sha": sha, "range": rng, "rows": group["rows"]}
                break
    busy, busy_known = None, False
    if not no_mac and (candidate or bisect or state.get("current")):
        busy, busy_known = github_busy(o.repo, o.yield_mode), True
    d = decide(state, t, candidate, bisect, supported_parts_at, busy, lambda sha: fleet_runs(sha, tip_version), no_mac,
               controller_route=bool(getattr(o, "controller", False)) and not no_mac)
    state["mac_off"] = no_mac  # the issue says why no Mac row is measured
    if state.get("current") and isinstance(tip_version, int):
        # The measurement version its Mac rows carry (fleet_runs measures only commits of the tip's version).
        state["current"].setdefault("measure_version", tip_version)
    if measurement_id(state.get("current")) != loaded_id:
        clear_parts(o.dir)  # a dropped or replaced measurement's part files must never be read as the new one's
    for requested in (d.get("part"), d.get("linux_part")):
        if requested and state.get("current"):
            # What this file asks the part to measure with: its rows carry it (a later tick may run a newer file).
            state["current"].setdefault("configs", {})[requested] = part_config(requested)
    out = {"action": d["action"], "sha": d.get("sha", ""), "part": d.get("part", ""), "linux_part": d.get("linux_part", ""),
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


NOT_STARTED = "not-started.json"  # a part dir with this file: the fleet check said no, no part ran (no attempt)
NO_RESULT = {"state": "yielded", "no_result": True,
             "reason": "the job ended without the part's result (cancelled, timed out, no fleet client, or a setup step "
                       "failed): one attempt"}


def missing_result(part_dir):
    """The result to record for a part whose job wrote none (pure but for the file checks): None when the fleet
    check said no (not an attempt), else NO_RESULT (it counts against MAX_YIELDS, so a part whose job keeps dying
    ends as failed instead of being retried every tick)."""
    if os.path.exists(os.path.join(part_dir, NOT_STARTED)):
        return None
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


def cmd_run_linux_part(o):
    """The diff-viewer part on Linux, in a checkout of the measured commit with Rust and the webviews packages
    installed: scripts/benchmark-diff-viewer.sh's two benches without their budget env, so they report instead of
    failing; perf-cron judges the numbers."""
    os.makedirs(o.out, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_DIFF_BENCH_MAX") and not k.startswith("CMUX_DIFF_BENCH_MIN")}
    started = time.monotonic()
    runs = linux_bench_runs(ROOT)
    report, tail, ok = {}, [], True
    for name, (argv, cwd, extra) in runs.items():
        proc = subprocess.run(argv, cwd=cwd, env={**env, **extra}, capture_output=True, text=True, timeout=1800)
        value = last_json_object(proc.stdout)
        tail += [f"{name}: exit {proc.returncode}"] + (proc.stderr or "").splitlines()[-10:]
        if proc.returncode != 0 or value is None:
            ok = False
        else:
            report[name] = value
    report["bench_versions"] = diff_bench_versions(ROOT)
    json.dump(report, open(os.path.join(o.out, "report.json"), "w"), indent=1)
    result = {"state": "done" if ok else "failed", "seconds": round(time.monotonic() - started), "tail": tail[-40:],
              "worker": o.runner_class}
    json.dump(result, open(os.path.join(o.out, "result.json"), "w"), indent=1)
    print(f"perf-cron linux part: {json.dumps({k: v for k, v in result.items() if k != 'tail'})} {json.dumps(report)[:600]}")


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
    if not is_linux_part(part) and result.get("worker") in (None, cur.get("host")):
        cur.pop("host_asked_since", None)  # the host answered (any result): give_up_host's wait starts again
    entry = dict(cur["parts"].get(part) or {"yields": 0})
    entry.update({"state": result["state"], "step_id": result.get("step_id"), "run_url": run_url,
                  "seconds": result.get("seconds")})
    if result.get("timed_out"):
        entry["timed_out"] = True
    if result["state"] == "yielded":
        entry["yields"] = entry.get("yields", 0) + 1
        if entry["yields"] >= MAX_YIELDS:
            entry["state"] = "yielded_out"
    if entry["state"] != "yielded" and part in cur["parts_todo"]:
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


def report(o):
    t = now_utc()
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
            result = missing_result(part_dir)
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
    if cur and not cur["parts_todo"] and (changed or o.finish):
        changed = True
        mod = load_budgets_module()
        budgets = json.load(open(os.path.join(HERE, "perf-budgets.json")))
        budgets["_animations"] = animation_budgets(mod)
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
                if not is_linux_part(name):
                    # The host did run, but this is not a completed fleet part
                    # for next_now(): do not immediately chain another tick
                    # into a still-open regression after partial coverage.
                    fleet_done = False
            part_rows = rows_of_part(PART_BY_NAME[name], report, mod, budgets)
            # Each fleet part's rows carry the refresh that part saw (split-spring.sh puts its display into the
            # report): a part that saw none leaves its frame rows unknown, never another part's rate.
            r = refresh_ms_of(report)
            if r:
                refresh.append(r)
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
            rows.update(host_rows(part_rows, worker))
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
    print(f"perf-cron report: {line}")
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
    if not isinstance(value, dict) or not is_sha(str(value.get("sha") or "")) or value.get("part") not in PART_BY_NAME \
            or is_linux_part(value.get("part")) or value.get("state") not in RESULT_STATES:
        return None
    return value


def result_plan(o, state, t):
    """A run the controller started with a part's result: plan nothing new; the report job stores the part. A
    result for another measurement, or for a part not to do, is dropped (a late result after an abandon)."""
    value = controller_result(o.perf_result)
    cur = state.get("current") or {}
    out = {"action": "none", "sha": "", "part": "", "linux_part": "", "frame_pacing": "false", "stale_hours": round(stale_hours(state, t), 1)}
    if value is None:
        out["reason"] = "the controller's perf_result is not a result"
    elif value.get("step_id") and value["step_id"] in {(e or {}).get("step_id") for e in (cur.get("parts") or {}).values()}:
        # The controller may send a result twice (a lost answer, a restart): the step was stored already.
        out["reason"] = f"the controller's result of step {value['step_id']} was stored already; dropped"
    elif value["sha"] != cur.get("sha") or value["part"] not in (cur.get("parts_todo") or []):
        out["reason"] = (f"the controller's {value['part']} result for {value['sha'][:12]} is not for the measurement in "
                         f"flight ({str(cur.get('sha') or 'none')[:12]}); dropped")
    else:
        out.update({"action": "result", "sha": value["sha"], "part": value["part"],
                    "reason": f"the controller's {value['state']} result of part {value['part']} at {value['sha'][:12]}"
                              f" (step {value.get('step_id') or '?'})"})
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    print(f"perf-cron plan: {json.dumps(out)}")
    write_outputs(o.output, out)


def result_files(value):
    """result.json for record_part from the controller's result (pure): a failed build part ends the other Mac
    parts (build_failed), a step past its cap is timed out, a pre-empted or unstarted one yielded."""
    tail = [line for line in (value.get("error"),) if line]
    return {"state": value["state"], "step_id": value.get("step_id"), "seconds": value.get("seconds"),
            "exit": value.get("exit_code"), "yielded_to": value.get("preempted_by"), "worker": value.get("worker"),
            "timed_out": bool(value.get("timed_out")), "tail": tail, "host_gone": bool(value.get("host_gone")),
            "build_failed": value.get("part") == "build" and value["state"] == "failed" and not value.get("timed_out")}


def cmd_fetch_result(o):
    """The report job's side of the controller route: result.json, and report.json from the step's signed artifact
    URL. A done step whose artifact cannot be read is a failed part (its rows would be missing)."""
    value = controller_result(o.result)
    os.makedirs(o.out, exist_ok=True)
    if value is None:
        print("perf-cron fetch-result: not a result; nothing written")
        return
    result = result_files(value)
    if value["state"] == "done":
        url = str(value.get("artifact_url") or "")
        try:
            if not url.startswith("https://"):
                raise ValueError("no https artifact URL")
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-perf-cron"}), timeout=120) as r:
                report = json.load(r)
            with open(os.path.join(o.out, "report.json"), "w") as f:
                json.dump(report, f)
        except (OSError, ValueError, urllib.error.URLError) as error:
            result.update(state="failed", tail=result["tail"] + [f"artifact not read: {error!r}"])
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(result, f)
    print(f"perf-cron fetch-result: part {value['part']} at {value['sha'][:12]}: {result['state']}")


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
    s = sub.add_parser("plan", help="pick this tick's work (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--tip", default="HEAD")
    s.add_argument("--yield-mode", default="queued", choices=["queued", "running"])
    s.add_argument("--no-mac", action="store_true", help="no route for the Mac parts: plan only the Linux part")
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
    s = sub.add_parser("run-linux-part", help="run the diff-viewer part (Linux, in a checkout of the measured commit)")
    s.add_argument("--out", required=True)
    s.add_argument("--runner-class", default=os.environ.get("PERF_CRON_RUNNER_CLASS", ""),
                   help="the runner label the job ran on: the Linux rows' host (compared only within one class)")
    s = sub.add_parser("report", help="store the parts, finish the measurement, keep the issue (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--result", action="append", default=[], metavar="PART=DIR",
                   help="a part that ran this tick and the directory with its result.json (repeatable)")
    s.add_argument("--run-url", default="")
    s.add_argument("--finish", action="store_true", help="finish a measurement whose parts all ran")
    s.add_argument("--issues", action="store_true", help="open, update or close the regression issue")
    s.add_argument("--output")
    s = sub.add_parser("fetch-result", help="write a controller result's result.json and report.json (report job)")
    s.add_argument("--result", required=True, help="the perf_result JSON")
    s.add_argument("--out", required=True)
    s = sub.add_parser("dispatch-next", help="start the next tick now (report, when a measure host stayed idle)")
    s.add_argument("--repo", required=True)
    o = ap.parse_args(argv)
    {"fetch-state": cmd_fetch_state, "plan": cmd_plan, "fleet-check": cmd_fleet_check, "run-part": cmd_run_part,
     "part-cleanup": cmd_part_cleanup, "run-linux-part": cmd_run_linux_part,
     "report": cmd_report, "dispatch-next": cmd_dispatch_next, "fetch-result": cmd_fetch_result}[o.cmd](o)


if __name__ == "__main__":
    main()
