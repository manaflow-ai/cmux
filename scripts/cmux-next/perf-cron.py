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
  measure (gateway) skips unless the bench host is idle and no dev build waits in the controller queue, then
                    runs ONE part (at most 15 minutes, the build included) as a background (lowest priority)
                    measurement step on the bench host, and cancels it when another job queues for that host.
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

# One part = one fleet step through the allowlisted scripts/measure/split-spring.sh (each builds the app at
# the measured commit, then runs one suite). `needs`: a capability the measured commit must have.
PARTS = [
    {"name": "stress", "args": ["--suite=pane-perf", "--layouts=stress", "--rounds=2", "--actions=split,close,column,zoom"],
     "artifact": "artifacts/split-spring/report.json", "kind": "panes", "needs": "stress"},
    {"name": "motion", "args": ["--suite=budgets", "--only=panes,new_surfaces"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "switch", "args": ["--suite=budgets", "--only=tab_switch,palette"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "perf-gate", "args": ["--suite=perf-gate", "--frames=auto"],
     "artifact": "artifacts/split-spring/perf-gate.json", "kind": "perf_gate", "needs": "perf-gate"},
    {"name": "launch", "args": ["--suite=launch", "--profile", "empty", "--mode", "warm", "--runs", "5", "--timeout", "20"],
     "artifact": "artifacts/split-spring/report.json", "kind": "launch", "needs": "launch"},
    {"name": "sidebar", "args": ["--suite=budgets", "--only=sidebar"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "home-idle", "args": ["--suite=budgets", "--only=home,idle"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
    {"name": "chat-anim", "args": ["--suite=budgets", "--only=acp,anim"],
     "artifact": "artifacts/split-spring/report.json", "kind": "budgets"},
]
PART_BY_NAME = {p["name"]: p for p in PARTS}
# Which part measures a row (bisect re-measures only the parts of the regressed rows).
ROW_PARTS = [
    (r"^panes\.[^.]+\.stress\.", "stress"), (r"^panes\.", "motion"), (r"^(cmd_n|cmd_t|ctrl_backtick|cmd_d|cmd_shift_d)\.", "motion"),
    (r"^(tab_switch|palette)\.", "switch"), (r"^perf_gate\.", "perf-gate"), (r"^(sidebar|workspace_switch)\.", "sidebar"),
    (r"^(home|idle)\.", "home-idle"), (r"^(acp|anim)\.", "chat-anim"), (r"^launch\.", "launch"),
]
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
    return {"schema": SCHEMA, "created_at": iso(t), "current": None, "last": None, "last_good": None,
            "first_bad": None, "range": None, "regressions": [], "issue": None, "stale_noted_for": None, "history": []}


def part_for_row(name):
    for pattern, part in ROW_PARTS:
        if re.search(pattern, name):
            return part
    return None


# ---------- rows and targets (pure) ----------

def refresh_ms_of(report):
    """The median display refresh interval any bench in the report saw (`refresh_ms` keys), or None."""
    found = []

    def walk(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k == "refresh_ms" and isinstance(x, (int, float)) and 2 <= x <= 50:
                    found.append(float(x))
                else:
                    walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(report)
    found.sort()
    return found[len(found) // 2] if found else None


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
                for mark, budget in LAUNCH_BUDGETS.items():
                    values = [r[mark] for r in runs or [] if isinstance(r, dict) and isinstance(r.get(mark), (int, float))]
                    if values:
                        p50, p95 = budgets_mod.pct(values, 0.5), budgets_mod.pct(values, 0.95)
                        out[f"launch.{mode}.{mark}"] = {"p50": round(p50, 1), "p95": round(p95, 1), "unit": "ms",
                                                        "budget": budget, "floor": 20.0}
    return out


def target_of(name, row, refresh_ms):
    """The row's target p95: latency 10 ms; a frame row one display refresh; counts 0; else its budget."""
    unit = row.get("unit") or "ms"
    if unit in ("frames", "checks") or name.endswith(".dropped"):
        return 0
    if name.endswith(".over_8_33"):
        return None  # a count of frames longer than a 120 Hz frame: compared with the last good run only
    if unit == "ms":
        if name.endswith(".frame") or name.endswith("longest_frame"):
            return round((refresh_ms or 1000 / 60) * 1.25, 2)  # a quarter frame of jitter; a drop is a whole frame
        if name.endswith((".main_ms_max", ".main_ms_p95")) or name.startswith("launch."):
            return row.get("budget")
        return LATENCY_TARGET_MS
    return row.get("budget")


def over_target(name, row, refresh_ms):
    t = target_of(name, row, refresh_ms)
    return t is not None and row.get("p95") is not None and row["p95"] > t


def find_regressions(rows, base_rows, refresh_ms, base_refresh_ms, budgets_mod):
    """Rows worse than the last good run: past perf-budgets' 10 % and floor rule, or newly over target."""
    if not base_rows:
        return []
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
                        "target": target_of(name, row, refresh_ms),
                        "why": "worse than last good" if name in worse else "newly over target"})
    return out


# ---------- plan (pure parts) ----------

def new_measurement(sha, kind, parts, t):
    return {"sha": sha, "kind": kind, "started_at": iso(t), "parts_todo": list(parts), "parts": {}}


def decide(state, t, candidate, bisect_sha, supported_parts, github_busy):
    """The tick's work: {'action': 'part'|'none', ...}. May set state['current'] (a new measurement).
    candidate: the newest measurable tip commit newer than the last one measured (or None).
    bisect_sha: a measurable commit inside an open regression's range (or None).
    supported_parts(sha) -> the PARTS names the commit can run. github_busy: a reason string or None."""
    cur = state.get("current")
    if cur and hours_between(parse_iso(cur["started_at"]), t) > ABANDON_HOURS:
        state.setdefault("history", []).append({"sha": cur["sha"], "kind": cur["kind"], "status": "abandoned",
                                                "at": iso(t), "parts": sorted(cur.get("parts", {}))})
        state["current"] = cur = None
    if not cur:
        if candidate:
            state["current"] = cur = new_measurement(candidate, "tip", supported_parts(candidate), t)
        elif bisect_sha:
            regressed = {part_for_row(r["name"]) for r in state.get("regressions") or []}
            parts = [p for p in supported_parts(bisect_sha) if p in regressed]
            if parts:
                state["current"] = cur = new_measurement(bisect_sha, "bisect", parts, t)
    if not cur:
        return {"action": "none", "reason": "nothing new to measure: the newest measurable feat-cmux-next commit "
                                            "was measured, and no regression range to bisect"}
    if not cur["parts_todo"]:
        return {"action": "finish", "sha": cur["sha"], "reason": "every part ran; report only"}
    if github_busy:
        return {"action": "none", "sha": cur["sha"], "reason": github_busy, "yielded": True}
    part = PART_BY_NAME[cur["parts_todo"][0]]
    return {"action": "part", "sha": cur["sha"], "kind": cur["kind"], "part": part["name"],
            "reason": f"{cur['kind']} measurement of {cur['sha'][:12]}: part {part['name']} "
                      f"({len(cur['parts'])} of {len(cur['parts']) + len(cur['parts_todo'])} done)"}


def bisect_midpoint(commits, measurable):
    """commits: first-parent commits strictly between good and bad, oldest first. The measurable one nearest
    the middle, or None."""
    if not commits:
        return None
    mid = len(commits) // 2
    order = sorted(range(len(commits)), key=lambda i: (abs(i - mid), i))
    for i in order:
        if measurable(commits[i]):
            return commits[i]
    return None


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
    if "exclusive" not in (w.get("fits") or []):
        return f"{worker} has no room for an exclusive step (fits {w.get('fits')})"
    for j in jobs or []:
        if j.get("id") in mine or j.get("state") not in ("queued", "leased", "running"):
            continue
        if j.get("worker") == worker or j.get("target_worker") == worker or (j.get("state") == "queued" and "bench" in (j.get("labels") or [])):
            return f"{worker} is busy or wanted: job {j['id'][:12]} ({j.get('script') or j.get('kind')}, {j['state']})"
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


def wanted_by_other(status, mine):
    """A foreground job queued for the bench host (it carries the `bench` label), or None."""
    for q in (status or {}).get("queue") or []:
        if q.get("id") not in mine and "bench" in (q.get("labels") or []) and q.get("priority_class") != "background":
            return q
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


def fetch_state(repo, out_dir):
    """Download the newest perf-cron-state artifact into out_dir; True when one was found."""
    os.makedirs(out_dir, exist_ok=True)
    found = gh_request(f"/repos/{repo}/actions/artifacts?name={STATE_ARTIFACT}&per_page=20").get("artifacts", [])
    for a in sorted(found, key=lambda a: a.get("created_at") or "", reverse=True):
        if a.get("expired"):
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
        elif need in ("perf-gate", "launch"):
            text = subprocess.run(["git", "-C", ROOT, "show", f"{sha}:scripts/cmux-next/split-spring-terminal.py"],
                                  capture_output=True, text=True).stdout
            ok = f"--suite={need}" in text
        else:
            ok = True
        if ok:
            names.append(p["name"])
    return names


def is_ancestor(a, b):
    return subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", a, b], capture_output=True).returncode == 0


# ---------- report (pure) ----------

def stale_basis(state):
    """When the newest tip measurement finished, else when the cron first ran."""
    return (state.get("last") or {}).get("measured_at") or state.get("created_at")


def stale_hours(state, now):
    basis = stale_basis(state)
    return hours_between(parse_iso(basis), now) if basis else 0.0


def link(repo, sha):
    return f"[`{sha[:11]}`](https://github.com/{repo}/commit/{sha})"


def fmt(v):
    return "n/a" if v is None else (f"{v:g}" if isinstance(v, (int, float)) else str(v))


def issue_body(state, repo, now):
    good, bad, rng = state.get("last_good"), state.get("first_bad"), state.get("range")
    last = state.get("last") or {}
    lines = [ISSUE_MARK, ""]
    regs = state.get("regressions") or []
    if regs and good and bad:
        g, b = (rng or {}).get("good") or good["sha"], (rng or {}).get("bad") or bad["sha"]
        lines += [f"**{len(regs)} row(s) regressed.** Last good {link(repo, good['sha'])} ([run]({good.get('run_url')})), "
                  f"first bad {link(repo, bad['sha'])} ([run]({bad.get('run_url')})).",
                  f"Culprit range: [`{g[:11]}...{b[:11]}`](https://github.com/{repo}/compare/{g}...{b})"
                  + (" (narrowed by bisect)" if rng and (rng.get("good") != good["sha"] or rng.get("bad") != bad["sha"]) else "") + ".",
                  "", "| row | last good p95 | now p95 | change | target | why |", "|---|---|---|---|---|---|"]
        for r in regs:
            change = f"+{round(100 * (r['p95'] - r['base']) / r['base'], 1)} %" if r["base"] else "new"
            lines.append(f"| {r['name']} | {fmt(r['base'])} {r['unit']} | {fmt(r['p95'])} {r['unit']} | {change} | {fmt(r['target'])} | {r['why']} |")
    elif regs:
        lines.append(f"**{len(regs)} row(s) regressed** (no good run on record).")
    else:
        lines.append("No row regressed in the last measurement.")
    if last:
        refresh = last.get("refresh_ms")
        lines += ["", f"Last measurement: {link(repo, last['sha'])} at {last.get('measured_at')} on {last.get('host') or BENCH_WORKER}, "
                      f"display {round(1000 / refresh) if refresh else 'unknown'} Hz ({fmt(refresh)} ms frames), "
                      f"[run]({last.get('run_url')})." + (f" Parts that did not run: {', '.join(last['failed_parts'])}." if last.get("failed_parts") else "")]
    if stale_hours(state, now) > STALE_HOURS:
        lines += ["", f"**Stale:** no finished measurement since {stale_basis(state)} ({round(stale_hours(state, now))} h): "
                      "the bench host had no idle time, a nightly or dev build kept waiting for a Mac, or the tick failed."]
    rows = (last or {}).get("rows") or {}
    if rows:
        lines += ["", "<details><summary>Every row of the last measurement</summary>", "",
                  "| row | p50 | p95 | target | last good p95 | |", "|---|---|---|---|---|---|"]
        base = (good or {}).get("rows") or {}
        for name in sorted(rows):
            r = rows[name]
            tgt = target_of(name, r, last.get("refresh_ms"))
            mark = "over target" if over_target(name, r, last.get("refresh_ms")) else ""
            lines.append(f"| {name} | {fmt(r.get('p50'))} | {fmt(r.get('p95'))} {r.get('unit', '')} | {fmt(tgt)} | "
                         f"{fmt((base.get(name) or {}).get('p95'))} | {mark} |")
        lines += ["", "</details>"]
    lines += ["", "Opened and closed by the perf cron (scripts/cmux-next/perf-cron.py, workflow cmux-next-perf-budgets.yml); "
                  "it never fails a check. Latency target 10 ms p95; frame rows one display refresh."]
    return "\n".join(lines)


def finish_measurement(state, part_rows, refresh_ms, host, run_url, t, budgets_mod):
    """Fold a finished measurement into the state. Returns the issue event: 'regressed', 'still', 'recovered',
    'narrowed', 'first' or 'good'."""
    cur = state["current"]
    failed = sorted(n for n, p in cur["parts"].items() if p.get("state") != "done")
    good = state.get("last_good")
    record = {"sha": cur["sha"], "measured_at": iso(t), "rows": part_rows, "refresh_ms": refresh_ms, "host": host,
              "run_url": run_url, "failed_parts": failed}
    state["current"] = None
    state.setdefault("history", []).append({"sha": cur["sha"], "kind": cur["kind"], "at": iso(t), "run_url": run_url,
                                            "failed_parts": failed})
    state["history"] = state["history"][-60:]
    if cur["kind"] == "bisect":
        regs = find_regressions(part_rows, (good or {}).get("rows") or {}, refresh_ms, (good or {}).get("refresh_ms"), budgets_mod)
        names = {r["name"] for r in state.get("regressions") or []}
        rng = state.get("range") or {}
        if not part_rows:
            return "good"  # nothing measured: the range stays
        if any(r["name"] in names for r in regs):
            rng["bad"] = cur["sha"]
        else:
            rng["good"] = cur["sha"]
        state["range"] = rng
        return "narrowed"
    regs = find_regressions(part_rows, (good or {}).get("rows") or {}, refresh_ms, (good or {}).get("refresh_ms"), budgets_mod)
    was = bool(state.get("regressions"))
    state["last"] = record
    if not good:
        state["last_good"] = record
        state["regressions"] = []
        return "first"
    if regs:
        state["regressions"] = regs
        if not state.get("first_bad"):
            state["first_bad"] = {"sha": cur["sha"], "run_url": run_url, "measured_at": iso(t)}
            state["range"] = {"good": good["sha"], "bad": cur["sha"]}
        return "still" if was else "regressed"
    merged = dict(good.get("rows") or {})
    merged.update(part_rows)
    state["last_good"] = {**record, "rows": merged}
    state["regressions"], state["first_bad"], state["range"] = [], None, None
    return "recovered" if was else "good"


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
        if state.get("schema") == SCHEMA:
            return state
    except (OSError, ValueError):
        pass
    return empty_state(t)


def cmd_plan(o):
    t = now_utc()
    state = load_state(o.dir, t)
    tip = git("rev-parse", o.tip)
    last_sha = (state.get("last") or {}).get("sha")
    candidate = None
    if not state.get("current"):
        for sha in git("rev-list", "--first-parent", f"-n{CANDIDATE_DEPTH}", tip).split():
            if sha == last_sha or (last_sha and is_ancestor(sha, last_sha)):
                break
            if tree_published(sha):
                candidate = sha
                break
            print(f"perf-cron: {sha[:12]} has no published cmux-tui tree yet; trying its parent")
    bisect_sha = None
    rng = state.get("range")
    if not candidate and not state.get("current") and rng and state.get("regressions"):
        between = git("rev-list", "--first-parent", "--reverse", f"{rng['good']}..{rng['bad']}", check=False).split()[:-1]
        bisect_sha = bisect_midpoint(between, tree_published)
    busy = None
    if candidate or bisect_sha or state.get("current"):
        busy = github_busy(o.repo, o.yield_mode)
    d = decide(state, t, candidate, bisect_sha, supported_parts_at, busy)
    json.dump(state, open(os.path.join(o.dir, "state.json"), "w"), indent=1)
    out = {"action": d["action"], "sha": d.get("sha", ""), "part": d.get("part", ""), "reason": d["reason"],
           "stale_hours": round(stale_hours(state, t), 1)}
    if d["action"] == "part":
        p = PART_BY_NAME[d["part"]]
        out["args"] = json.dumps(p["args"])
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


def cmd_run_part(o):
    """Run one part through `cmux-ci run` (background class, the bench host) and watch the queue: a foreground
    job for the bench host cancels it (the part runs again on a later tick, at most MAX_YIELDS times)."""
    os.makedirs(o.out, exist_ok=True)
    argv = [o.client, "run", "--class", "exclusive", "--background", "--measurement", "--label", "bench", "--label", "measure",
            "--target-worker", o.worker, "--no-supersede", "--script", "scripts/measure/split-spring.sh", "--ref", o.sha, "--key", o.key,
            "--artifact", o.artifact, "--timeout", str(PART_RUN_SECONDS), "--queue-timeout", str(PART_QUEUE_SECONDS),
            *[f"--arg={a}" for a in json.loads(o.args)]]
    print("perf-cron: " + " ".join(argv), flush=True)
    log_path = os.path.join(o.out, "step.log")
    started = time.monotonic()
    step_id, yielded_to = None, None
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            time.sleep(15)  # the watch interval: a bounded poll of the controller while the step runs
            if not step_id:
                m = re.search(rb"cmux-ci: step ([0-9a-f]{12,}) ", open(log_path, "rb").read())
                step_id = m.group(1).decode() if m else None
            if step_id and not yielded_to:
                try:
                    other = wanted_by_other(http_json(controller_url() + "/v1/status"), {step_id})
                except (OSError, ValueError, urllib.error.URLError):
                    other = None
                if other:
                    yielded_to = other["id"]
                    print(f"perf-cron: job {other['id'][:12]} queued for {o.worker}; cancelling this part", flush=True)
                    run_capture([o.client, "cancel", step_id, "--reason", f"perf cron yields to {other['id']}"])
    code = proc.returncode
    text = open(log_path, "rb").read().decode(errors="replace")
    if not step_id:
        m = re.search(r"cmux-ci: step ([0-9a-f]{12,}) ", text)
        step_id = m.group(1) if m else None
    state = "done" if code == 0 else ("yielded" if yielded_to or code == 75 else "failed")
    result = {"state": state, "exit": code, "step_id": step_id, "seconds": round(time.monotonic() - started),
              "yielded_to": yielded_to, "worker": o.worker, "tail": text.splitlines()[-40:]}
    if state == "done" and step_id:
        got = run_capture([o.client, "artifact", step_id, os.path.join(o.out, "report.json")], timeout=600)
        if got.returncode != 0:
            result["state"], result["artifact_error"] = "failed", (got.stderr or got.stdout)[-500:]
    json.dump(result, open(os.path.join(o.out, "result.json"), "w"), indent=1)
    print(f"perf-cron part: {json.dumps({k: v for k, v in result.items() if k != 'tail'})}")


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
    times); a part whose app build failed ends the measurement's other parts too (each would build the same)."""
    entry = dict(cur["parts"].get(part) or {"yields": 0})
    entry.update({"state": result["state"], "step_id": result.get("step_id"), "run_url": run_url,
                  "seconds": result.get("seconds")})
    if result["state"] == "yielded":
        entry["yields"] = entry.get("yields", 0) + 1
        if entry["yields"] >= MAX_YIELDS:
            entry["state"] = "failed"
    if entry["state"] != "yielded" and part in cur["parts_todo"]:
        cur["parts_todo"].remove(part)
    cur["parts"][part] = entry
    if entry["state"] == "failed" and any("printed no app path" in line for line in result.get("tail") or []):
        for other in list(cur["parts_todo"]):
            cur["parts"][other] = {"state": "build_failed", "run_url": run_url}
        cur["parts_todo"] = []
    return entry


def cmd_report(o):
    t = now_utc()
    state = load_state(o.dir, t)
    changed = not state.get("persisted")
    state["persisted"] = True
    event, summary = None, ""
    result = None
    if o.part_dir and os.path.exists(os.path.join(o.part_dir, "result.json")):
        result = json.load(open(os.path.join(o.part_dir, "result.json")))
    cur = state.get("current")
    before_names = sorted(r["name"] for r in state.get("regressions") or [])
    if cur and o.part and result:
        changed = True
        entry = record_part(cur, o.part, result, o.run_url)
        if entry["state"] == "done":
            os.makedirs(os.path.join(o.dir, "parts"), exist_ok=True)
            report = os.path.join(o.part_dir, "report.json")
            if os.path.exists(report):
                with open(report) as src, open(os.path.join(o.dir, "parts", f"{o.part}.json"), "w") as dst:
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
            rows.update(rows_of_part(PART_BY_NAME[name], report, mod, budgets))
            r = refresh_ms_of(report)
            if r:
                refresh.append(r)
        refresh_ms = sorted(refresh)[len(refresh) // 2] if refresh else None
        sha = cur["sha"]
        event = finish_measurement(state, rows, refresh_ms, BENCH_WORKER, o.run_url, t, mod)
        for name in os.listdir(os.path.join(o.dir, "parts")) if os.path.isdir(os.path.join(o.dir, "parts")) else []:
            os.remove(os.path.join(o.dir, "parts", name))
        regs = state.get("regressions") or []
        summary = {"first": f"first measurement {sha[:12]} ({len(rows)} rows) is the baseline",
                   "good": f"{sha[:12]}: no row regressed ({len(rows)} rows)",
                   "recovered": f"{sha[:12]}: every row is back within its threshold ({len(rows)} rows)",
                   "regressed": f"{sha[:12]}: {len(regs)} row(s) regressed: " + ", ".join(r["name"] for r in regs[:8]),
                   "still": f"{sha[:12]}: still regressed, {len(regs)} row(s): " + ", ".join(r["name"] for r in regs[:8]),
                   "narrowed": f"bisect {sha[:12]}: range now {(state.get('range') or {}).get('good', '?')[:11]}..."
                               f"{(state.get('range') or {}).get('bad', '?')[:11]}"}[event]
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
    s.add_argument("--out", required=True)
    s.add_argument("--worker", default=BENCH_WORKER)
    s.add_argument("--client", default=os.path.expanduser("~/.local/bin/cmux-ci"))
    s = sub.add_parser("report", help="store the part, finish the measurement, keep the issue (Linux)")
    s.add_argument("--repo", required=True)
    s.add_argument("--dir", required=True)
    s.add_argument("--part", default="")
    s.add_argument("--part-dir", default="")
    s.add_argument("--run-url", default="")
    s.add_argument("--finish", action="store_true", help="finish a measurement whose parts all ran")
    s.add_argument("--issues", action="store_true", help="open, update or close the regression issue")
    s.add_argument("--output")
    o = ap.parse_args(argv)
    {"fetch-state": cmd_fetch_state, "plan": cmd_plan, "fleet-check": cmd_fleet_check, "run-part": cmd_run_part,
     "report": cmd_report}[o.cmd](o)


if __name__ == "__main__":
    main()
