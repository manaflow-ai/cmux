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
  measure (gateway) runs only on its own runner label (vars.CI_PERF_CRON_GATEWAY; unset: no Mac part is planned),
                    skips unless the bench host is idle and no dev build waits in the controller queue, then
                    runs ONE part (its run_seconds: 15 minutes, the build 20, STRESS and sidebar 25) as a background (lowest priority)
                    measurement step on the bench host, and cancels it when a foreground job queues that the
                    host could run (its labels, its name, or a target worker).
  report (Linux)    stores the part; after the last part compares every row with the last good run, and opens,
                    updates or closes the one issue "cmux-next perf regression". No check fails on a
                    regression; a missing measurement for 24 h is noted in the issue.

A row regresses when its p95 is more than 10 % and its noise floor (perf-budgets.json) over the last good
run, or when it newly misses its target (latency rows 10 ms p95; frame rows one display refresh; dropped
frames and perf-gate failed checks 0; CPU rows their perf-budgets.json budget).

Subcommands: fetch-state, plan, fleet-check, run-part, report (see each --help). Tests:
scripts/cmux-next/tests/test_perf_cron.py (run them yourself; no CI job runs them).
"""
import argparse, datetime, importlib.util, io, json, os, re, subprocess, sys, time, urllib.error, urllib.parse
import urllib.request, zipfile

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
LATENCY_TARGET_MS = 10.0
STALE_HOURS = 24
ABANDON_HOURS = 12
MAX_YIELDS = 3
PART_RUN_SECONDS = 900      # one part, its app build included (Lawrence: under 15 minutes each)
PART_QUEUE_SECONDS = 300    # a part that does not start at once gives its place back
CANDIDATE_DEPTH = 80
NIGHTLY_WORKFLOWS = ("nightly.yml", "nightly-next-train.yml")
DEV_DAILY_TITLE = "cmux NEXT DEV daily"

# One fleet part = one step through the allowlisted scripts/measure/split-spring.sh on the bench host. The first
# part builds the app once per measurement (--build-only) and leaves it in the host's app cache; every other fleet
# part reuses it (--app-cache) and asks for a 120 Hz virtual display as the main display (--vdisplay=120; the
# report's `display` says whether it came up, and a fallback run's frame rows have no known refresh: they are neither
# compared nor held to a target). No cron run has confirmed the 120 Hz display on cmux20-bench yet (2026-10-23). The `linux` part runs on a GitHub Linux runner, not on a Mac. `needs`: a capability the
# measured commit must have.
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
    return state


def sanitize_state(state, ok):
    """Drop every part of the state that names a commit `ok(sha)` rejects (not 40 hex characters, or not on the
    measured branch), and unknown part names: a sha from the state goes to `git rev-list` and to `cmux-ci run
    --ref` on the bench host. Returns what was dropped."""
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
    row_ok = state.get("row_ok") if isinstance(state.get("row_ok"), dict) else {}
    state["row_ok"] = {k: v for k, v in row_ok.items() if isinstance(k, str) and ok(v)}
    if len(state["row_ok"]) != len(row_ok):
        dropped.append(f"{len(row_ok) - len(state['row_ok'])} row_ok entries")
    if state.get("issue") is not None and not (isinstance(state["issue"], int) and state["issue"] > 0):
        state["issue"] = None
        dropped.append("issue")
    return dropped


def part_for_row(name):
    for pattern, part in ROW_PARTS:
        if re.search(pattern, name):
            return part
    return None


# ---------- rows and targets (pure) ----------

def refresh_ms_of(report):
    """The display refresh interval (ms) a part measured at, or None (unknown). The median of the `refresh_ms` keys
    its benches printed (the display the app was on), else the `display` scripts/measure/split-spring.sh put into
    the report: the virtual display's measured interval, or null after a VDISPLAY-FALLBACK (the panel's rate is not
    known). perf-budgets.py prints no refresh, so its parts get theirs from `display` only."""
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
                out[f"panes.{s['action']}.{s['layout']}.missed"] = {"p50": n, "p95": n, "unit": "frames", "budget": 0, "floor": 1.0}
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
        for name, (v, unit, floor) in values.items():
            out[name] = {"p50": v, "p95": v, "unit": unit, "budget": DIFF_BUDGETS[name], "floor": floor}
    return out


def frame_sensitive(name, row):
    """A row whose value depends on the display refresh (frame intervals, frame counts)."""
    return (row.get("unit") == "frames" or name.endswith((".frame", "longest_frame", ".missed", ".dropped", ".over_8_33")))


def same_refresh(a, b):
    """Two known refresh periods (ms) within 20 %. An unknown refresh is never the same as anything, itself
    included: a frame row whose display is not known (a VDISPLAY-FALLBACK run on a panel of unknown rate, a bench
    that printed no refresh) is not compared."""
    return bool(a) and bool(b) and abs(a - b) <= 0.2 * max(a, b)


def row_refresh(row, refresh_ms):
    """The display refresh (ms) a row was measured at: its own `refresh_ms` when the row carries the key (None: its
    part saw no refresh), else the measurement's."""
    return row["refresh_ms"] if "refresh_ms" in row else refresh_ms


def refresh_skipped(rows, base_rows, refresh_ms, base_refresh_ms):
    """The frame rows find_regressions leaves out: the display refresh changed since the last good run, or one of
    the two is not known."""
    return sorted(n for n, r in rows.items() if frame_sensitive(n, r) and n in base_rows
                  and not same_refresh(row_refresh(r, refresh_ms), row_refresh(base_rows[n], base_refresh_ms)))


def target_of(name, row, refresh_ms):
    """The row's target p95: latency 10 ms; a frame row one display refresh (the row's own when it has one); counts
    0; diff, launch and main-thread rows their budget."""
    refresh_ms = row_refresh(row, refresh_ms)
    unit = row.get("unit") or "ms"
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


def find_regressions(rows, base_rows, refresh_ms, base_refresh_ms, budgets_mod):
    """Rows worse than the last good run: past perf-budgets' 10 % and floor rule, or newly over target. A frame row
    measured at another display refresh than its last good value is not compared (the next good run rebases it)."""
    if not base_rows:
        return []
    skipped = set(refresh_skipped(rows, base_rows, refresh_ms, base_refresh_ms))
    rows = {n: r for n, r in rows.items() if n not in skipped}
    listed = [{"name": n, "p95": r["p95"], "floor": r.get("floor", 1.0)} for n, r in rows.items()]
    worse = {r["name"]: r for r in budgets_mod.compare(listed, {n: b["p95"] for n, b in base_rows.items() if b.get("p95") is not None})}
    out = []
    for name in sorted(rows):
        row, base = rows[name], base_rows.get(name)
        if not base or base.get("p95") is None:
            continue
        crossed = (over_target(name, row, refresh_ms) and not over_target(name, base, base_refresh_ms)
                   and row["p95"] - base["p95"] > row.get("floor", 1.0))
        if name in worse or crossed:
            out.append({"name": name, "p95": row["p95"], "base": base["p95"], "unit": row.get("unit", "ms"),
                        "target": target_of(name, row, refresh_ms), "refresh_ms": row_refresh(row, refresh_ms),
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
    so a step killed outright does not leave it as the bench host's main display."""
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


def drop_dead_measurement(state, t, measurable):
    """End the measurement in flight when it is too old or the fleet no longer runs its commit (its
    split-spring.sh is an older reviewed blob). Returns why, or None. The plan calls it before it looks for a
    new commit, so a dropped measurement is replaced in the same tick."""
    cur = state.get("current")
    why = None
    if cur and hours_between(parse_iso(cur["started_at"]), t) > ABANDON_HOURS:
        why = "abandoned"
    elif cur and not measurable(cur["sha"]):
        why = "unmeasurable"
    if why:
        state.setdefault("history", []).append({"sha": cur["sha"], "kind": cur["kind"], "status": why,
                                                "at": iso(t), "parts": sorted(cur.get("parts", {}))})
        state["current"] = None
    return why


def decide(state, t, candidate, bisect, supported_parts, github_busy, measurable=lambda sha: True):
    """The tick's work: {'action': 'part'|'none'|'finish', 'part': a fleet part or '', 'linux_part': '' or one}.
    May set state['current'] (a new measurement).
    candidate: the newest measurable tip commit newer than the last one measured (or None).
    bisect: {'sha', 'range': {good, bad}, 'rows': [row names]}: a measurable commit inside one group of regressed
    rows' culprit range (or None); the step measures only the parts of those rows.
    supported_parts(sha) -> the PARTS names the commit can run. github_busy: a reason string or None (it holds
    back the Mac parts only; the Linux part takes no Mac). measurable(sha): the fleet would still run the commit
    (its scripts/measure/split-spring.sh is the reviewed one)."""
    drop_dead_measurement(state, t, measurable)
    cur = state.get("current")
    if not cur:
        if candidate:
            state["current"] = cur = new_measurement(candidate, "tip", with_build(supported_parts(candidate)), t)
        elif bisect:
            regressed = {part_for_row(name) for name in bisect["rows"]}
            parts = [p for p in supported_parts(bisect["sha"]) if p in regressed]
            if parts:
                state["current"] = cur = new_measurement(bisect["sha"], "bisect", with_build(parts), t, bisect["range"])
    if not cur:
        return {"action": "none", "reason": "nothing new to measure: the newest measurable feat-cmux-next commit "
                                            "was measured, and no regression range to bisect"}
    if not cur["parts_todo"]:
        return {"action": "finish", "sha": cur["sha"], "reason": "every part ran; report only"}
    linux = next((p for p in cur["parts_todo"] if is_linux_part(p)), "")
    fleet = next((p for p in cur["parts_todo"] if not is_linux_part(p)), "")
    done = f"{len(cur['parts'])} of {len(cur['parts']) + len(cur['parts_todo'])} done"
    if github_busy:
        fleet = ""
    if not fleet and not linux:
        return {"action": "none", "sha": cur["sha"], "reason": github_busy, "yielded": True}
    what = " and ".join(x for x in (fleet, linux) if x)
    return {"action": "part", "sha": cur["sha"], "kind": cur["kind"], "part": fleet, "linux_part": linux,
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
    """A queued foreground job that could run on the bench host, or None: the perf cron yields to it.
    status: /v1/status (queue entries carry labels, `background`, blocked and placement_wait, but no target worker;
    workers carry their labels). jobs: `cmux-ci status` (/v1/jobs, with target_worker), or None when not read this
    round. A job wants the bench host when it carries the `bench` label, when every label it needs is one the host
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

def gh_request(path, method="GET", body=None, raw=False, timeout=30):
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = path if path.startswith("http") else f"{api}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-perf-cron"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = r.read()
    return payload if raw else (json.loads(payload) if payload else {})


def linux_job(job):
    labels = " ".join(job.get("labels") or []).lower()
    return bool(labels) and ("ubuntu" in labels or "linux" in labels) and "macos" not in labels and "glaeda" not in labels


def mac_job_waiting(job):
    """A job queued for a runner (not one waiting on an environment approval) that is not a Linux job."""
    return job.get("status") == "queued" and not linux_job(job)


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
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as error:
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


def fetch_state(repo, out_dir):
    """Download the newest trusted perf-cron-state artifact into out_dir; True when one was found."""
    os.makedirs(out_dir, exist_ok=True)
    repo_id = gh_request(f"/repos/{repo}").get("id")
    found = gh_request(f"/repos/{repo}/actions/artifacts?name={STATE_ARTIFACT}&per_page=100").get("artifacts", [])

    def run_of(run_id):
        try:
            return gh_request(f"/repos/{repo}/actions/runs/{int(run_id)}")
        except (TypeError, ValueError, urllib.error.HTTPError):
            return None
    for a in sorted(found, key=lambda a: a.get("created_at") or "", reverse=True):
        if a.get("expired"):
            continue
        why = untrusted_state_artifact(a, repo_id, run_of)
        if why:
            print(f"perf-cron: state artifact {a.get('id')} skipped: {why}")
            continue
        blob = download_redirected(a["archive_download_url"])
        zipfile.ZipFile(io.BytesIO(blob)).extractall(out_dir)
        print(f"perf-cron: state from artifact {a['id']} (run {a.get('workflow_run', {}).get('id')}, {a.get('created_at')})")
        return True
    print("perf-cron: no state artifact yet; starting fresh")
    return False


def find_issue(repo, number=None):
    if number:
        try:
            issue = gh_request(f"/repos/{repo}/issues/{number}")
            if issue.get("title") == ISSUE_TITLE:
                return issue
        except urllib.error.HTTPError:
            pass
    q = urllib.parse.quote(f'repo:{repo} is:issue in:title "{ISSUE_TITLE}"')
    items = gh_request(f"/search/issues?q={q}&sort=created&order=desc&per_page=10").get("items", [])
    items = [i for i in items if i.get("title") == ISSUE_TITLE]
    return items[0] if items else None


# ---------- git (plan) ----------

def git(*args, check=True):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=check, timeout=120).stdout.strip()


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


def script_blob(sha):
    return subprocess.run(["git", "-C", ROOT, "rev-parse", f"{sha}:{MEASURE_SCRIPT}"], capture_output=True, text=True).stdout.strip()


def fleet_runs(sha, tip_blob):
    """The fleet runs an allowlisted script only when its blob at the commit is the reviewed one (the tip's)."""
    return bool(tip_blob) and script_blob(sha) == tip_blob


def is_ancestor(a, b):
    return subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", "--end-of-options", a, b],
                          capture_output=True).returncode == 0


def commit_on_branch(repo, tip):
    """ok(sha): the sha is 40 hex characters and an ancestor of tip (or tip). The plan's checkout is shallow, so a
    commit it does not have is asked of the GitHub compare API ('ahead' or 'identical': on the branch)."""
    cache = {}

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


def fmt(v):
    return "n/a" if v is None else (f"{v:g}" if isinstance(v, (int, float)) else str(v))


def issue_body(state, repo, now):
    good = state.get("last_good")
    last = state.get("last") or {}
    lines = [ISSUE_MARK, ""]
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
        lines += ["", "| row | last good p95 | now p95 | change | target | display | why | range |", "|---|---|---|---|---|---|---|---|"]
        for r in regs:
            change = f"+{round(100 * (r['p95'] - r['base']) / r['base'], 1)} %" if r.get("base") else "new"
            rng = r.get("range") or {}
            why = r.get("why", "") + (" (not measured again since)" if r.get("unmeasured_at") else "")
            lines.append(f"| {r['name']} | {fmt(r.get('base'))} {r.get('unit', '')} | {fmt(r.get('p95'))} {r.get('unit', '')} | {change} | "
                         f"{fmt(r.get('target'))} | {hz(r.get('refresh_ms'))} | {why} | "
                         f"{str(rng.get('good') or '?')[:7]}..{str(rng.get('bad') or '?')[:7]} |")
    else:
        lines.append("No row regressed in the last measurement.")
    if last:
        refresh = last.get("refresh_ms")
        lines += ["", f"Last measurement: {link(repo, last['sha'])} at {last.get('measured_at')} on {last.get('host') or BENCH_WORKER}, "
                      f"display {round(1000 / refresh) if refresh else 'unknown'} Hz ({fmt(refresh)} ms frames), "
                      f"[run]({last.get('run_url')})." + (f" Parts that did not run: {', '.join(last['failed_parts'])}." if last.get("failed_parts") else "")]
        if last.get("refresh_skipped"):
            lines += ["", f"Not compared: {len(last['refresh_skipped'])} frame row(s) ran at another display refresh than "
                          f"their last good value ({', '.join(last['refresh_skipped'][:8])}"
                          + (", ..." if len(last["refresh_skipped"]) > 8 else "") + ")."]
    tried = state.get("last_tried") or {}
    if tried.get("sha") and tried.get("sha") != last.get("sha"):
        lines += ["", f"Newest attempt: {link(repo, tried['sha'])} at {tried.get('at')} ([run]({tried.get('run_url')})) measured no row, "
                      "or not every regressed row; it is not the last measurement."]
    if stale_hours(state, now) > STALE_HOURS:
        lines += ["", f"**Stale:** no finished measurement since {stale_basis(state)} ({round(stale_hours(state, now))} h): "
                      "the bench host had no idle time, a nightly or dev build kept waiting for a Mac, the commits did not "
                      "build, the regressed rows' parts kept failing, or the tick failed."]
    rows = (last or {}).get("rows") or {}
    if rows:
        lines += ["", "<details><summary>Every row of the last measurement</summary>", "",
                  "| row | p50 | p95 | target | last good p95 | display | |", "|---|---|---|---|---|---|---|"]
        base = (good or {}).get("rows") or {}
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
                  "value is not compared until a good run rebases it."]
    return "\n".join(lines)


def bisect_step(state, cur, part_rows, regs):
    """Fold a bisect step into the culprit range it searched (pure). bad: a row of that range regressed; good: every
    row of it was measured and is within its threshold; skip (`git bisect skip`): some row of it was not measured
    (the commit did not build, a part failed or yielded), so the next step picks another commit. Returns
    (verdict, note)."""
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


def finish_measurement(state, part_rows, refresh_ms, host, run_url, t, budgets_mod):
    """Fold a finished measurement into the state. Returns the issue event: 'regressed', 'still', 'recovered',
    'narrowed' or 'skipped' (a bisect step), 'first', 'good', 'partial' (no measured row regressed, but a planned
    part did not run), or 'empty' (no row measured: neither a baseline nor a verdict). The newest history entry gets
    the status and a note.

    A tip measurement counts as recovered only when it measured every open regression's row again and each is
    within its threshold. When it misses one (its part failed or yielded, or the bench printed no value), the
    missing rows stay regressed, the event is 'still', and last and last_good stay as they were (the stale clock
    keeps running). A row that regresses while another regression is open gets its own culprit range: from the
    newest tip measurement in which it was within its threshold to this commit."""
    cur = state["current"]
    failed = sorted(n for n, p in cur["parts"].items() if p.get("state") != "done")
    good = state.get("last_good")
    state["current"] = None
    entry = {"sha": cur["sha"], "kind": cur["kind"], "at": iso(t), "run_url": run_url, "failed_parts": failed}
    state.setdefault("history", []).append(entry)
    state["history"] = state["history"][-60:]
    regs = find_regressions(part_rows, (good or {}).get("rows") or {}, refresh_ms, (good or {}).get("refresh_ms"),
                            budgets_mod) if part_rows else []
    if cur["kind"] == "bisect":
        entry["status"], entry["note"] = bisect_step(state, cur, part_rows, regs)
        return "narrowed" if entry["status"] in ("good", "bad") else "skipped"
    state["last_tried"] = {"sha": cur["sha"], "at": iso(t), "run_url": run_url}
    if not part_rows:
        entry["status"] = "empty"
        return "empty"
    record = {"sha": cur["sha"], "measured_at": iso(t), "rows": part_rows, "refresh_ms": refresh_ms, "host": host,
              "run_url": run_url, "failed_parts": failed,
              "refresh_skipped": refresh_skipped(part_rows, (good or {}).get("rows") or {}, refresh_ms, (good or {}).get("refresh_ms"))}
    row_ok = state.setdefault("row_ok", {})
    if not good:
        state["last_good"] = record
        if not failed:
            state["last"] = record  # a first run with a part that did not run is the baseline, not a stale reset
        state["regressions"] = []
        row_ok.update({name: cur["sha"] for name in part_rows})
        entry["status"] = "first"
        return "first"
    old = {r["name"]: r for r in state.get("regressions") or []}
    regressions = []
    for r in regs:
        prev = old.get(r["name"])
        if prev and prev.get("range"):
            r["range"], r["first_bad"] = prev["range"], prev.get("first_bad")
        else:
            r["range"] = {"good": row_ok.get(r["name"]) or good["sha"], "bad": cur["sha"], "skip": [], "steps": 0}
            r["first_bad"] = {"sha": cur["sha"], "run_url": run_url, "measured_at": iso(t)}
        regressions.append(r)
    now_bad = {r["name"] for r in regressions}
    row_ok.update({name: cur["sha"] for name in part_rows if name not in now_bad})
    missing = sorted(n for n in old if n not in part_rows)
    for name in missing:
        regressions.append({**old[name], "unmeasured_at": cur["sha"]})
    regressions.sort(key=lambda r: r["name"])
    state["regressions"] = regressions
    if missing:
        parts = sorted({part_for_row(n) or "?" for n in missing})
        entry["status"] = "incomplete"
        entry["note"] = (f"{len(missing)} regressed row(s) not measured again (part(s) {', '.join(parts)}"
                         + (f"; failed: {', '.join(failed)}" if failed else "") + ")")
        return "still"
    if failed:
        # Rows of the parts that ran are judged (a regression of theirs opens, one they measured within its
        # threshold again clears), but a measurement with a planned part that did not run is not complete: it is
        # neither the last measurement (the stale clock keeps running while those parts keep failing) nor the
        # new last good run.
        entry["status"] = "incomplete"
        entry["note"] = f"part(s) that did not run: {', '.join(failed)}"
        if regressions:
            return "still" if old else "regressed"
        return "recovered" if old else "partial"
    state["last"] = record
    if regressions:
        entry["status"] = "regressed"
        return "still" if old else "regressed"
    # A frame row from another display refresh replaces its last good value only when it ran faster: a 60 Hz
    # fallback run never rebases a 120 Hz baseline, and the first 120 Hz run rebases a 60 Hz one.
    merged = dict(good.get("rows") or {})
    skipped = set(record["refresh_skipped"])
    for name, r in part_rows.items():
        prev = merged.get(name) or {}
        if name in skipped and (row_refresh(r, refresh_ms) or 1e9) >= (row_refresh(prev, good.get("refresh_ms")) or 1e9):
            continue
        merged[name] = r
    state["last_good"] = {**record, "rows": merged}
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
    fetch_state(o.repo, o.dir)


def load_state(d, t):
    try:
        state = json.load(open(os.path.join(d, "state.json")))
        if isinstance(state, dict) and state.get("schema") == SCHEMA:
            return migrate_state(state)
    except (OSError, ValueError):
        pass
    return empty_state(t)


def cmd_plan(o):
    t = now_utc()
    state = load_state(o.dir, t)
    tip = git("rev-parse", "--verify", "--end-of-options", f"{o.tip}^{{commit}}")
    tip_blob = script_blob(tip)
    before = json.dumps(state, sort_keys=True)
    dropped = sanitize_state(state, commit_on_branch(o.repo, tip))
    if dropped:
        print(f"perf-cron: dropped from the state (not a commit of {o.tip}): {', '.join(dropped)}")
    supported = supported_parts_at
    no_mac = None
    if o.no_mac:
        no_mac = "no gateway runner label for the perf cron (vars.CI_PERF_CRON_GATEWAY is not set): no Mac part runs"
        supported = lambda sha: [p for p in supported_parts_at(sha) if is_linux_part(p)]  # noqa: E731
    dead = drop_dead_measurement(state, t, lambda sha: fleet_runs(sha, tip_blob))
    if dead:
        print(f"perf-cron: the measurement in flight ended ({dead}); looking for a new commit")
    last_sha = (state.get("last_tried") or state.get("last") or {}).get("sha")
    candidate = None
    if not state.get("current"):
        for sha in git("rev-list", "--first-parent", f"-n{CANDIDATE_DEPTH}", tip).split():
            if sha == last_sha or (last_sha and is_ancestor(sha, last_sha)):
                break
            if not fleet_runs(sha, tip_blob):
                print(f"perf-cron: {sha[:12]} predates the reviewed {MEASURE_SCRIPT}; the fleet would refuse it")
                break
            if tree_published(sha):
                candidate = sha
                break
            print(f"perf-cron: {sha[:12]} has no published cmux-tui tree yet; trying its parent")
    bisect = None
    if not candidate and not state.get("current"):
        for group in bisect_groups(state):
            rng = group["range"]
            between = git("rev-list", "--first-parent", "--reverse", f"{rng['good']}..{rng['bad']}", check=False).split()[:-1]
            sha = bisect_midpoint(between, lambda c: fleet_runs(c, tip_blob) and tree_published(c), rng.get("skip") or [])
            if sha:
                bisect = {"sha": sha, "range": rng, "rows": group["rows"]}
                break
    busy = no_mac
    if not busy and (candidate or bisect or state.get("current")):
        busy = github_busy(o.repo, o.yield_mode)
    d = decide(state, t, candidate, bisect, supported, busy, lambda sha: fleet_runs(sha, tip_blob))
    if json.dumps(state, sort_keys=True) != before:
        state["dirty"] = True  # the report job saves it even when no part ran
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    out = {"action": d["action"], "sha": d.get("sha", ""), "part": d.get("part", ""), "linux_part": d.get("linux_part", ""),
           "reason": d["reason"], "stale_hours": round(stale_hours(state, t), 1)}
    if d.get("part"):
        p = PART_BY_NAME[d["part"]]
        out["run_seconds"] = p.get("run_seconds", PART_RUN_SECONDS)
        out["args"] = json.dumps(part_args(p, out["run_seconds"]))
        out["artifact"] = p["artifact"]
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
    write_outputs(o.output, {"ok": "false" if reason else "true", "reason": reason or ""})


# `cmux-ci run` exit codes that are the fleet's, not the measured commit's (hq build-fleet/ci-client.py): no worker
# takes steps (69), the step never left the queue within --queue-timeout (75), a newer head superseded it (76). The
# part gives its place back and runs on a later tick (at most MAX_YIELDS times). A run past --timeout (124) fails.
STEP_YIELD_EXITS = {69: "no fleet worker takes steps", 75: "queue-timeout", 76: "superseded"}
STEP_TIMEOUT_EXIT = 124
JOBS_POLL_EVERY = 4  # read /v1/jobs (target workers) every 4th watch round: it is the slow call


def part_state(code, yielded_to):
    """'done', 'yielded' or 'failed' for a part that exited with code (cancelled by the cron when yielded_to)."""
    if code == 0:
        return "done"
    return "yielded" if yielded_to or code in STEP_YIELD_EXITS else "failed"


def cmd_run_part(o):
    """Run one part through `cmux-ci run` (background class, the bench host) and watch the queue: a foreground
    job that could run on the bench host cancels it (the part runs again on a later tick, at most MAX_YIELDS
    times)."""
    if not is_sha(o.sha):
        raise SystemExit(f"perf-cron: --sha must be a full commit sha, not {o.sha!r}")
    os.makedirs(o.out, exist_ok=True)
    argv = [o.client, "run", "--class", "exclusive", "--background", "--measurement", "--label", "bench", "--label", "measure",
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
              "worker": o.worker, "tail": text.splitlines()[-40:], "build_failed": BUILD_FAILED_MARK in text}
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


def issue_plan(state, event, now, is_open, exists, set_changed):
    """What to do with the issue (pure): {'open': bool, 'comment': kind or None}. kinds: summary, stale, recovered."""
    stale = stale_hours(state, now) > STALE_HOURS
    want_open = bool(state.get("regressions")) or stale
    if not want_open:
        return {"open": False, "comment": "recovered" if is_open else None}
    if not exists or not is_open:
        return {"open": True, "comment": "summary" if exists else None}
    if event in ("regressed", "narrowed") or (event == "still" and set_changed):
        return {"open": True, "comment": "summary"}
    if stale and state.get("stale_noted_for") != stale_basis(state):
        return {"open": True, "comment": "stale"}
    return {"open": True, "comment": None}


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
    runs = {
        "sidecar": ([os.path.join(ROOT, "scripts/run-diff-sidecar-cargo.sh"), "run", "--quiet", "--release", "--locked",
                     "--manifest-path", os.path.join(ROOT, "Native/DiffSidecar/Cargo.toml"), "--bin", "cmux-diff-sidecar",
                     "--features", "benchmark", "--", "benchmark", "16777216", "20"], ROOT, {}),
        "stream": (["bun", "run", "benchmark"], os.path.join(ROOT, "webviews"),
                   {"CMUX_DIFF_BENCH_ITERATIONS": "10", "CMUX_DIFF_BENCH_RENDER_APP": "1"}),
    }
    report, tail, ok = {}, [], True
    for name, (argv, cwd, extra) in runs.items():
        proc = subprocess.run(argv, cwd=cwd, env={**env, **extra}, capture_output=True, text=True, timeout=1800)
        value = last_json_object(proc.stdout)
        tail += [f"{name}: exit {proc.returncode}"] + (proc.stderr or "").splitlines()[-10:]
        if proc.returncode != 0 or value is None:
            ok = False
        else:
            report[name] = value
    json.dump(report, open(os.path.join(o.out, "report.json"), "w"), indent=1)
    result = {"state": "done" if ok else "failed", "seconds": round(time.monotonic() - started), "tail": tail[-40:]}
    json.dump(result, open(os.path.join(o.out, "result.json"), "w"), indent=1)
    print(f"perf-cron linux part: {json.dumps({k: v for k, v in result.items() if k != 'tail'})} {json.dumps(report)[:600]}")


def manage_issue(repo, state, event, now, run_url, summary, set_changed):
    """Open, update, comment on or close the one regression issue. Returns a line for the run summary."""
    issue = find_issue(repo, state.get("issue"))
    number = issue["number"] if issue else None
    is_open = bool(issue) and issue.get("state") == "open"
    plan = issue_plan(state, event, now, is_open, bool(issue), set_changed)
    body = issue_body(state, repo, now)
    if stale_hours(state, now) > STALE_HOURS:
        state["stale_noted_for"] = stale_basis(state)
    if not plan["open"]:
        if is_open:
            gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body})
            gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"Recovered: {summary} ([run]({run_url}))."})
            gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"state": "closed", "state_reason": "completed"})
            return f"closed issue #{number}"
        return "no issue needed"
    if not issue:
        created = gh_request(f"/repos/{repo}/issues", "POST", {"title": ISSUE_TITLE, "body": body})
        state["issue"] = created["number"]
        return f"opened issue #{created['number']}"
    state["issue"] = number
    gh_request(f"/repos/{repo}/issues/{number}", "PATCH", {"body": body, **({} if is_open else {"state": "open"})})
    if plan["comment"] == "summary":
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": f"{summary} ([run]({run_url}))."})
    elif plan["comment"] == "stale":
        gh_request(f"/repos/{repo}/issues/{number}/comments", "POST", {"body":
                   f"No finished measurement for over {STALE_HOURS} h (since {stale_basis(state)}) ([run]({run_url}))."})
    return f"{'reopened' if not is_open else 'updated'} issue #{number}"


def record_part(cur, part, result, run_url):
    """Fold one part's run into the measurement in flight (pure). A yielded part stays to do (at most MAX_YIELDS
    times); a failed build part (or any part whose app build failed) ends the measurement's other fleet parts (each
    would build the same); the Linux part still runs."""
    entry = dict(cur["parts"].get(part) or {"yields": 0})
    entry.update({"state": result["state"], "step_id": result.get("step_id"), "run_url": run_url,
                  "seconds": result.get("seconds")})
    if result.get("timed_out"):
        entry["timed_out"] = True
    if result["state"] == "yielded":
        entry["yields"] = entry.get("yields", 0) + 1
        if entry["yields"] >= MAX_YIELDS:
            entry["state"] = "failed"
    if entry["state"] != "yielded" and part in cur["parts_todo"]:
        cur["parts_todo"].remove(part)
    cur["parts"][part] = entry
    build_failed = (part == "build" or bool(result.get("build_failed"))
                    or any(BUILD_FAILED_MARK in line for line in result.get("tail") or []))
    if entry["state"] == "failed" and build_failed:
        for other in [p for p in cur["parts_todo"] if not is_linux_part(p)]:
            cur["parts"][other] = {"state": "build_failed", "run_url": run_url}
            cur["parts_todo"].remove(other)
    return entry


def cmd_report(o):
    t = now_utc()
    state = load_state(o.dir, t)
    changed = not state.get("persisted") or bool(state.pop("dirty", False))
    state["persisted"] = True
    event, summary = None, ""
    cur = state.get("current")
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
        if not isinstance(result, dict) or result.get("state") not in ("done", "failed", "yielded"):
            continue
        changed = True
        entry = record_part(cur, part, result, o.run_url)
        if entry["state"] == "done":
            os.makedirs(os.path.join(o.dir, "parts"), exist_ok=True)
            report = os.path.join(part_dir, "report.json")
            if os.path.exists(report):
                with open(report) as src, open(os.path.join(o.dir, "parts", f"{part}.json"), "w") as dst:
                    dst.write(src.read())
    if cur and not cur["parts_todo"] and (changed or o.finish):
        changed = True
        mod = load_budgets_module()
        budgets = json.load(open(os.path.join(HERE, "perf-budgets.json")))
        budgets["_animations"] = animation_budgets(mod)
        rows, refresh = {}, []
        for name in cur["parts"]:
            path = os.path.join(o.dir, "parts", f"{name}.json")
            try:
                report = json.load(open(path))
            except (OSError, ValueError):
                continue
            part_rows = rows_of_part(PART_BY_NAME[name], report, mod, budgets)
            # Each fleet part's rows carry the refresh that part saw (split-spring.sh puts its display into the
            # report): a part that saw none leaves its frame rows unknown, never another part's rate.
            r = refresh_ms_of(report)
            if r:
                refresh.append(r)
            if not is_linux_part(name):
                for row in part_rows.values():
                    row.setdefault("refresh_ms", r)
            rows.update(part_rows)
        refresh_ms = sorted(refresh)[len(refresh) // 2] if refresh else None
        sha = cur["sha"]
        event = finish_measurement(state, rows, refresh_ms, BENCH_WORKER, o.run_url, t, mod)
        for name in os.listdir(os.path.join(o.dir, "parts")) if os.path.isdir(os.path.join(o.dir, "parts")) else []:
            os.remove(os.path.join(o.dir, "parts", name))
        regs = state.get("regressions") or []
        note = (state.get("history") or [{}])[-1].get("note") or ""
        summary = {"first": f"first measurement {sha[:12]} ({len(rows)} rows) is the baseline",
                   "good": f"{sha[:12]}: no row regressed ({len(rows)} rows)",
                   "recovered": f"{sha[:12]}: every row is back within its threshold ({len(rows)} rows)",
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
    if o.issues and (event or (stale and state.get("stale_noted_for") != stale_basis(state))):
        before = json.dumps(state, sort_keys=True)
        set_changed = sorted(r["name"] for r in state.get("regressions") or []) != before_names
        line += "; " + manage_issue(o.repo, state, event, t, o.run_url, summary or line, set_changed)
        changed = changed or json.dumps(state, sort_keys=True) != before
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    print(f"perf-cron report: {line}")
    write_outputs(o.output, {"changed": "true" if changed else "false", "line": line.replace("\n", " ")})


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
    s.add_argument("--no-mac", action="store_true", help="no gateway runner for the Mac parts: plan only the Linux part")
    s.add_argument("--output")
    s = sub.add_parser("fleet-check", help="may a part run on the bench host now (gateway)")
    s.add_argument("--worker", default=BENCH_WORKER)
    s.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
    s.add_argument("--yield-mode", default="queued", choices=["queued", "running"])
    s.add_argument("--output")
    s = sub.add_parser("run-part", help="run one part on the bench host (gateway)")
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
    s = sub.add_parser("report", help="store the parts, finish the measurement, keep the issue (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--result", action="append", default=[], metavar="PART=DIR",
                   help="a part that ran this tick and the directory with its result.json (repeatable)")
    s.add_argument("--run-url", default="")
    s.add_argument("--finish", action="store_true", help="finish a measurement whose parts all ran")
    s.add_argument("--issues", action="store_true", help="open, update or close the regression issue")
    s.add_argument("--output")
    o = ap.parse_args(argv)
    {"fetch-state": cmd_fetch_state, "plan": cmd_plan, "fleet-check": cmd_fleet_check, "run-part": cmd_run_part,
     "part-cleanup": cmd_part_cleanup, "run-linux-part": cmd_run_linux_part,
     "report": cmd_report}[o.cmd](o)


if __name__ == "__main__":
    main()
