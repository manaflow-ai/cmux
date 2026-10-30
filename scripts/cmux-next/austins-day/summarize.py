#!/usr/bin/env python3
"""Austin's day: one JSON and a short text summary from the runs of one or two arms.

  summarize.py OUT.json RUN_DIR [RUN_DIR...]      (each RUN_DIR has run.json and arm.json)

arm.json (written by austins-day.sh): {"arm": "base"|"head"|"run", "sha", "job", "round", "host"}.
Every metric is over the load phase. Distributions are {n, p50, p95, p99, max} (nearest rank);
counts are plain numbers. Per arm, each metric is listed per run and as the median over runs.

The base must be the PR's parent commit (for a stacked PR, the head of the PR below it), so base..head is
exactly the PR's own commits; the summary lists them, and a base that is not an ancestor of the head is
invalid. Cumulative daemon counters (refused, accepted) are compared as a rate per second over each run's
own server-stats window and as a share of connects, because the last answered server-stats comes at a
different time in each run.

An A/B (base and head arms) gives a verdict per metric: a paired percentile bootstrap 95 % confidence
interval of mean(head - base) over the rounds (each round is one base and one head run on one host),
10,000 resamples with a fixed seed. Every metric is lower-is-better: `better` when the whole interval is
below 0, `worse` when it is above 0, else `no difference`. No verdict at all ("invalid: ...") when:
- any base run showed none of Austin's failures ("invalid: base did not reproduce"): the scenario did not
  load that base the way Austin's day did, so a difference proves nothing (cmux-ad 2026-10-30);
- the head commit changes scripts/cmux-next/austins-day/ ("invalid: head edits the harness"): the
  harness is held out; only its owner changes it, in its own PR;
- a run has no results.
Per metric, a verdict also needs every base run to show that metric's own failure (METRIC_FAILURE: a
budget the product or the brief states); else that metric says "invalid: base did not reproduce".

`austin_failure` per run names which of Austin's failures the run showed: refused daemon
connections, app requests with no reply in time, registry lock waits over 1 s at p99, acpmux
restarts, cmux main-thread CODE stalls over 100 ms. A run that shows none did not reproduce his day.

Stalls (P-MAIN rule G, lead 2026-10-30): a stall over 100 ms is CODE when the main thread was on the CPU
for at least 50 % of it (cpu_ms >= duration_ms / 2; or the app's own `cause` from debug.hangs), else a
WAIT (page faults, swap-ins, a lock). Only CODE stalls with a cmux frame are reds, named by their top
cmux symbol; WAITs are counted apart and reported next to memory and swap (owner: B8, memory).
"""
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def dist(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool))
    if not values:
        return {"n": 0, "p50": None, "p95": None, "p99": None, "max": None}

    def rank(p):
        return values[max(0, min(len(values) - 1, math.ceil(p / 100 * len(values)) - 1))]
    return {"n": len(values), "p50": round(rank(50), 2), "p95": round(rank(95), 2), "p99": round(rank(99), 2),
            "max": round(values[-1], 2)}


def counts(values):
    out = {}
    for v in values:
        if v:
            out[str(v)] = out.get(str(v), 0) + 1
    return out


def histogram_dist(start, end):
    """Percentiles of the app probe over the run: end minus start of a fixed-bucket histogram
    ({"bounds_us": [...], "counts": [...], "timeouts", "max_us"}); None when the build has no probe."""
    if not isinstance(end, dict) or "counts" not in end or "bounds_us" not in end:
        return None
    before = start.get("counts") if isinstance(start, dict) and start.get("bounds_us") == end["bounds_us"] else None
    window = [e - (before[i] if before else 0) for i, e in enumerate(end["counts"])]
    total = sum(window)
    bounds = end["bounds_us"]

    def rank(p):
        if not total:
            return None
        need = math.ceil(p / 100 * total)
        seen = 0
        for i, c in enumerate(window):
            seen += c
            if seen >= need:
                return round((bounds[i] if i < len(bounds) else end.get("max_us", bounds[-1])) / 1000, 2)
        return None
    timeouts = end.get("timeouts", 0) - ((start or {}).get("timeouts", 0) if before else 0)
    return {"n": total, "p50": rank(50), "p95": rank(95), "p99": rank(99), "max": round(end.get("max_us", 0) / 1000, 2),
            "timeouts": timeouts, "unit": "ms (bucket upper bounds)"}


def owners_table():
    path = os.path.join(REPO, "plans", "cmux-next", "OWNERS.md")
    rows = []
    try:
        for line in open(path):
            cells = [c.strip() for c in line.split("|")]
            if len(cells) > 4 and "`" in cells[2]:
                for p in re.findall(r"`([^`]+)`", cells[2]):
                    rows.append((p, cells[3]))
    except OSError:
        pass
    return rows


OWNERS = owners_table()


def owner_of(symbol):
    """The OWNERS.md owner of the module a demangled symbol names (CmuxNextX.Type.method -> Sources/CmuxNextX/)."""
    found = re.search(r"\b(CmuxNext[A-Za-z0-9_]*)\.", symbol or "")
    if not found:
        return None
    module = found.group(1)
    best = None
    for path, owner in OWNERS:
        if f"/Sources/{module}/" in path or path.endswith(f"/Sources/{module}") or f"/Sources/{module}/" in path + "/":
            if best is None or len(path) < len(best[0]):
                best = (path, owner)
    return best[1] if best else None


CODE_CPU_SHARE = 0.5


def stall_cause(stall):
    """`code` or `wait` (P-MAIN rule G, lead 2026-10-30): the app's own `cause` when its debug.hangs gives one;
    else `code` when the main thread was on the CPU for at least half the stall (cpu_ms >= 50 % of
    duration_ms), `wait` when less (blocked: page faults and swap-ins under memory pressure, a lock, I/O).
    A stall without cpu_ms counts as code, so an unknown is never hidden as a wait."""
    cause = stall.get("cause")
    if cause in ("code", "wait"):
        return cause
    duration, cpu = stall.get("duration_ms"), stall.get("cpu_ms")
    if not isinstance(duration, (int, float)) or not isinstance(cpu, (int, float)) or duration <= 0:
        return "code"
    return "code" if cpu >= CODE_CPU_SHARE * duration else "wait"


def stall_sites(stalls):
    """CODE stalls with a cmux frame, by their top cmux symbol (the reds of rule G); WAITs are not listed."""
    sites = {}
    for s in stalls:
        if not s.get("cmux_frame") or stall_cause(s) != "code":
            continue
        site = sites.setdefault(s["symbol"], {"symbol": s["symbol"], "count": 0, "total_ms": 0.0, "max_ms": 0.0,
                                               "owner": owner_of(s["symbol"])})
        site["count"] += 1
        site["total_ms"] = round(site["total_ms"] + (s.get("duration_ms") or 0), 1)
        site["max_ms"] = round(max(site["max_ms"], s.get("duration_ms") or 0), 1)
    return sorted(sites.values(), key=lambda s: -s["total_ms"])


def stat(snapshot, *path):
    value = snapshot
    for key in path:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def slope_per_hour(samples, key):
    """Least-squares slope of `key` over time, per hour (memory and fd growth over a run); None with fewer
    than 3 samples. One process's pid change (a restart) resets nothing: a restart shows as a step."""
    points = [(s["t"], s[key]) for s in samples if isinstance(s.get(key), (int, float)) and isinstance(s.get("t"), (int, float))]
    if len(points) < 3:
        return None
    mean_t = sum(t for t, _ in points) / len(points)
    mean_v = sum(v for _, v in points) / len(points)
    var = sum((t - mean_t) ** 2 for t, _ in points)
    if var == 0:
        return None
    return round(sum((t - mean_t) * (v - mean_v) for t, v in points) / var * 3600, 2)


def run_metrics(run):
    series = run["series"]
    load = lambda rows: [r for r in rows if r.get("phase") == "load"]
    stats = [s for s in series["server_stats"] if s.get("stats")]
    first = stats[0]["stats"] if stats else {}
    last = stats[-1]["stats"] if stats else {}
    # Cumulative counters are read at the first and last answered server-stats; those times differ per run
    # (a refused server-stats call is itself lost), so they are compared as a rate over that window and as a
    # share of connects, never as a raw difference (#28159 review, 2026-10-30).
    window_s = (stats[-1]["t"] - stats[0]["t"]) if len(stats) >= 2 else None
    accepted_n = (stat(last, "connections", "accepted") or 0) - (stat(first, "connections", "accepted") or 0)
    refused_n = (stat(last, "connections", "refused") or 0) - (stat(first, "connections", "refused") or 0)
    stats_fail = counts(s.get("code") for s in series["server_stats"] if not s.get("stats"))
    agents = run["agent_records"]
    hooks = [r for r in agents if r.get("kind") == "hook"]
    tools = [r for r in agents if r.get("kind") == "tool"]
    agent_cli = [r for r in agents if r.get("kind") == "cli"]
    starts = [r for r in agents if r.get("kind") == "start"]
    person = load(series["person_cli"])
    control = load(series["app_control"])
    closes = [c for c in series["closes"] if c.get("made")]
    answers = [a for w in series["waves"] for a in w["answers"]]
    pids = [p["pid"] for p in series["acpmux_pids"] if p.get("pid")]
    restarts = max(0, len(dict.fromkeys(pids)) - 1)
    samples = series["samples"]
    load_samples = load(samples) or samples
    memory = {}
    for proc in ("app", "daemon", "acpmux"):
        memory[proc] = {"rss_mb": dist(s.get(f"{proc}_rss_mb") for s in samples),
                        "footprint_mb": dist(s.get(f"{proc}_footprint_mb") for s in samples),
                        "rss_mb_first": next((s.get(f"{proc}_rss_mb") for s in samples if s.get(f"{proc}_rss_mb")), None),
                        "rss_mb_last": next((s.get(f"{proc}_rss_mb") for s in reversed(samples) if s.get(f"{proc}_rss_mb")), None)}
    lock_wait = stat(last, "registry_lock", "wait_us") or {}
    m = {
        "agents": run["agents"], "agents_started": len(starts), "agents_hooked": sum(1 for s in starts if s.get("hooked")),
        "app_requests": histogram_dist(run["app_probe"].get("start"), run["app_probe"].get("end")),
        "app_no_reply_within": run["app_log"].get("no_reply_within"),
        "app_no_reply_by_cmd": run["app_log"].get("no_reply_by_cmd"),
        "app_log_ok": run["app_log"].get("ok"),
        "app_daemon_failed_log": run["app_log"].get("daemon_failed"),
        "app_control_ms": dist(c["ms"] for c in control), "app_control_errors": sum(1 for c in control if c.get("error")),
        "person_cli_ms": dist(p["ms"] for p in person), "person_cli_refusals": counts(p.get("code") for p in person),
        "agent_hook_ms": dist(h["ms"] for h in hooks), "agent_hooks": len(hooks),
        "agent_hook_cpu_ms": dist(h.get("cpu_ms") for h in hooks),
        "agent_hook_cpu_total_s": round(sum(h.get("cpu_ms") or 0 for h in hooks) / 1000, 2),
        "agent_hook_failures": counts(h.get("rc") for h in hooks if h.get("rc") not in (0, None)),
        "agent_tool_ms": dist(t["ms"] for t in tools),
        "agent_cli_ms": dist(c["ms"] for c in agent_cli), "agent_cli_refusals": counts(c.get("code") for c in agent_cli),
        "daemon_connections": {"accepted": accepted_n, "refused": refused_n,
                               "window_s": window_s and round(window_s, 1),
                               "refused_per_s": round(refused_n / window_s, 3) if window_s else None,
                               "refused_share": round(refused_n / (refused_n + accepted_n), 4) if refused_n + accepted_n else None,
                               "peak": stat(last, "connections", "peak"), "limit": stat(last, "connections", "limit")},
        "server_stats_unanswered": stats_fail,
        "daemon_lock_wait_us": {k: lock_wait.get(k) for k in ("count", "p50", "p90", "p99", "max")},
        "daemon_lock_hold_us": {k: (stat(last, "registry_lock", "hold_us") or {}).get(k) for k in ("p50", "p90", "p99", "max")},
        "daemon_lock_stalls": stat(last, "registry_lock", "stalls"),
        "daemon_lock_top_sites": (stat(last, "registry_lock", "top_sites") or [])[:5],
        "journal_commit_us": {k: (stat(last, "journal_writer", "commit_us") or {}).get(k) for k in ("p50", "p90", "p99", "max")},
        "workspace_close_app_ms": dist(c.get("app_gone_ms") for c in closes),
        "workspace_close_daemon_ms": dist(c.get("daemon_gone_ms") for c in closes),
        "workspace_close_not_done": sum(1 for c in closes if c.get("app_gone_ms") is None or c.get("daemon_gone_ms") is None),
        "workspace_close_attempts": len(series["closes"]),
        "acpmux_new_ms": dist(a["ms"] for a in answers if a["method"] == "session/new"),
        "acpmux_prompt_ms": dist(a["ms"] for a in answers if a["method"] == "session/prompt"),
        "acpmux_errors": counts(a["error"][:80] for a in answers if a.get("error")),
        "acpmux_waves": len(series["waves"]),
        "acpmux_restarts": restarts, "acpmux_unresponsive_log": run["app_log"].get("acpmux_unresponsive"),
        "load1": dist(s.get("load1") for s in load_samples),
        "swap_used_mb": dist(s.get("swap_used_mb") for s in load_samples),
        "memory_level_min": min((s.get("memory_level") for s in load_samples if s.get("memory_level") is not None), default=None),
        "memory": memory,
        "fds": {proc: dist(s.get(f"{proc}_fds") for s in samples) for proc in ("app", "daemon", "acpmux")},
        "growth_per_hour": {proc: {key: slope_per_hour(samples, f"{proc}_{key}") for key in ("rss_mb", "footprint_mb", "fds")}
                            for proc in ("app", "daemon", "acpmux")},
        "stalls_over_100ms_cmux": sum(1 for s in run["stalls"] if s.get("cmux_frame") and stall_cause(s) == "code"),
        "stalls_over_100ms_all": len(run["stalls"]),
        "stall_code_count": sum(1 for s in run["stalls"] if stall_cause(s) == "code"),
        "stall_code_total_ms": round(sum(s.get("duration_ms") or 0 for s in run["stalls"] if stall_cause(s) == "code"), 1),
        "stall_wait_count": sum(1 for s in run["stalls"] if stall_cause(s) == "wait"),
        "stall_wait_total_ms": round(sum(s.get("duration_ms") or 0 for s in run["stalls"] if stall_cause(s) == "wait"), 1),
        "stall_wait_cpu_share_max": max((round(s["cpu_ms"] / s["duration_ms"], 3) for s in run["stalls"]
                                         if stall_cause(s) == "wait" and isinstance(s.get("cpu_ms"), (int, float))
                                         and (s.get("duration_ms") or 0) > 0), default=None),
        "stall_wait_task_pageins": sum(s.get("task_pageins") or 0 for s in run["stalls"] if stall_cause(s) == "wait"),
        "stall_sites": stall_sites(run["stalls"]),
        "notes": series.get("notes", []),
    }
    # The harness's own faults: a hooked agent that logged no hook run, or a hook thread that crashed.
    faults = []
    if m["agents_hooked"] and not hooks:
        faults.append("hooked agents logged no hook runs")
    crashed = [h["rc"] for h in hooks if str(h.get("rc", "")).startswith("harness-error")]
    if crashed:
        faults.append(f"{len(crashed)} hook runs hit a harness error ({crashed[0][:120]})")
    m["harness_faults"] = faults
    # Who fills the connection pool (descriptive): median per load sample of the daemon's own client list by
    # label, and of the live client processes by role; plus the refusals each client kind saw itself.
    holders = load(series.get("holders", []))
    labels = sorted({k for h in holders for k in (h.get("by_label") or {})})
    m["pool_holders"] = {
        "samples": len(holders), "listed_ok": sum(1 for h in holders if h.get("listed") is not None),
        "listed_median": {k: statistics.median([(h.get("by_label") or {}).get(k, 0) for h in holders if h.get("listed") is not None] or [0])
                          for k in labels},
        "processes_median": {k: statistics.median([(h.get("processes") or {}).get(k, 0) for h in holders] or [0])
                             for k in ("hook_helper", "cli", "other_bundle")},
        "refusals_seen": {"agent_cli": sum(1 for c in agent_cli if c.get("code") in ("server.busy", "session.busy")),
                          "person_cli": sum(1 for p in person if p.get("code") in ("server.busy", "session.busy")),
                          "app_log_server_busy": run["app_log"].get("server_busy"),
                          "hook_timeouts": sum(1 for h in hooks if h.get("rc") == "timeout")}}
    m["austin_failure"] = {
        "refused_connections": (m["daemon_connections"]["refused"] or 0) > 0
        or any(k in ("server.busy", "session.busy") for k in {**m["person_cli_refusals"], **m["agent_cli_refusals"]}),
        "app_no_reply": (m["app_no_reply_within"] or 0) > 0 or bool(m["app_requests"] and m["app_requests"].get("timeouts")),
        "lock_wait_p99_over_1s": (lock_wait.get("p99") or 0) > 1_000_000,
        "acpmux_restarts": restarts > 0 or (m["acpmux_unresponsive_log"] or 0) > 0,
        # Only CODE stalls are a cmux red (rule G); WAITs are the memory owner's (B8), reported apart.
        "cmux_stalls": m["stalls_over_100ms_cmux"] > 0,
    }
    return m


KEY = [  # (label, path in metrics) for the text summary
    ("app request p99 ms", ("app_requests", "p99")),
    ("app no-reply timeouts (log)", ("app_no_reply_within",)),
    ("person CLI p99 ms", ("person_cli_ms", "p99")),
    ("agent CLI p99 ms", ("agent_cli_ms", "p99")),
    ("agent hook p99 ms", ("agent_hook_ms", "p99")),
    ("agent hook CPU total s", ("agent_hook_cpu_total_s",)),
    ("agent hook CPU p99 ms", ("agent_hook_cpu_ms", "p99")),
    ("daemon refused per s", ("daemon_connections", "refused_per_s")),
    ("daemon refused share of connects", ("daemon_connections", "refused_share")),
    ("daemon peak/limit", ("daemon_connections", "peak")),
    ("lock wait p99 us", ("daemon_lock_wait_us", "p99")),
    ("workspace close p99 ms", ("workspace_close_app_ms", "p99")),
    ("workspace close p95 ms", ("workspace_close_app_ms", "p95")),
    ("workspace close not done", ("workspace_close_not_done",)),
    ("acpmux restarts", ("acpmux_restarts",)),
    ("acpmux new p99 ms", ("acpmux_new_ms", "p99")),
    ("app RSS max MB", ("memory", "app", "rss_mb", "max")),
    ("daemon RSS max MB", ("memory", "daemon", "rss_mb", "max")),
    ("acpmux RSS max MB", ("memory", "acpmux", "rss_mb", "max")),
    ("load1 max", ("load1", "max")),
    ("swap used max MB", ("swap_used_mb", "max")),
    ("cmux CODE stalls >100 ms", ("stalls_over_100ms_cmux",)),
    ("WAIT stalls total ms", ("stall_wait_total_ms",)),
    ("WAIT stalls count", ("stall_wait_count",)),
    ("app fds max", ("fds", "app", "max")),
    ("daemon fds max", ("fds", "daemon", "max")),
    ("app RSS growth MB/h", ("growth_per_hour", "app", "rss_mb")),
    ("daemon RSS growth MB/h", ("growth_per_hour", "daemon", "rss_mb")),
    ("acpmux RSS growth MB/h", ("growth_per_hour", "acpmux", "rss_mb")),
]


def pick(metrics, path):
    value = metrics
    for key in path:
        value = value.get(key) if isinstance(value, dict) else None
    return value


HARNESS_DIR = "scripts/cmux-next/austins-day"
BOOTSTRAP_RESAMPLES = 10000
CONFIDENCE = 0.95


def head_edits_harness(base_sha, head_sha, repo=REPO):
    """True when the head commit's tree differs from the base's under the harness folder; None when git
    cannot tell (a commit missing from the checkout: fetch it)."""
    if not base_sha or not head_sha:
        return None
    try:
        done = subprocess.run(["git", "-C", repo, "diff", "--quiet", base_sha, head_sha, "--", HARNESS_DIR],
                              capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return {0: False, 1: True}.get(done.returncode)


def base_is_ancestor(base_sha, head_sha, repo=REPO):
    if not base_sha or not head_sha:
        return None
    try:
        done = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", base_sha, head_sha], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return {0: True, 1: False}.get(done.returncode)


def measured_commits(base_sha, head_sha, repo=REPO):
    """The commits the A/B measures (base..head, first line each): the reader checks they are the PR's own."""
    try:
        done = subprocess.run(["git", "-C", repo, "log", "--format=%h %s", f"{base_sha}..{head_sha}"], capture_output=True,
                              text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.splitlines() if done.returncode == 0 else None


def paired_bootstrap(pairs, seed=27698):
    """Percentile bootstrap 95 % CI of mean(head - base) over the rounds' paired differences; (mean, low, high).
    Deterministic (fixed seed), so the same runs always give the same verdict."""
    diffs = [h - b for b, h in pairs]
    if len(diffs) < 2:
        return (diffs[0] if diffs else None), None, None
    rng = random.Random(seed)
    means = sorted(sum(rng.choice(diffs) for _ in diffs) / len(diffs) for _ in range(BOOTSTRAP_RESAMPLES))
    tail = (1 - CONFIDENCE) / 2
    low = means[int(tail * BOOTSTRAP_RESAMPLES)]
    high = means[min(BOOTSTRAP_RESAMPLES - 1, int((1 - tail) * BOOTSTRAP_RESAMPLES))]
    return sum(diffs) / len(diffs), low, high


def verdict(low, high):
    """Every KEY metric is lower-is-better. `better`/`worse` only when the interval excludes 0."""
    if low is None or high is None:
        return "no interval"
    if high < 0:
        return "better"
    if low > 0:
        return "worse"
    return "no difference"


# Per metric: what counts as Austin's failure for it, so a metric whose failure the base did not show gets
# no verdict ("invalid: base did not reproduce"). Each bound is a budget the product or the brief already
# states, not a number fitted to a run:
#   refused connections: any (#27698; diagnostics.rs: a refused connect is a lost hook event);
#   lock wait p99: over 100 ms (LOCK_STALL_THRESHOLD, diagnostics.rs: the daemon's own stall line);
#   app request: p99 over 50 ms or any time-out (P-AUSTIN B3 target: p99 under 50 ms, 0 time-outs);
#   workspace close: over the 2 s action.run deadline, or a close that never finished;
#   CLI and hook latency and hook CPU: the base refused connections (their failure in #27698 is the full
#   connection pool: retries, server.busy, session.no_answer).
def _refused(m):
    return m["austin_failure"]["refused_connections"]


def _app(m):
    a = m.get("app_requests") or {}
    return (a.get("p99") or 0) > 50 or bool(a.get("timeouts")) or (m.get("app_no_reply_within") or 0) > 0


def _close(label):
    def failed(m):
        if (m.get("workspace_close_not_done") or 0) > 0:
            return True
        return (pick(m, {"workspace close p95 ms": ("workspace_close_app_ms", "p95"),
                         "workspace close p99 ms": ("workspace_close_app_ms", "p99")}[label]) or 0) > 2000
    return failed


METRIC_FAILURE = {
    "daemon refused per s": _refused,
    "daemon refused share of connects": _refused,
    "person CLI p99 ms": _refused,
    "agent CLI p99 ms": _refused,
    "agent hook p99 ms": _refused,
    "agent hook CPU total s": _refused,
    "agent hook CPU p99 ms": _refused,
    "lock wait p99 us": lambda m: (pick(m, ("daemon_lock_wait_us", "p99")) or 0) > 100_000,
    "app request p99 ms": _app,
    "app no-reply timeouts (log)": _app,
    "workspace close p95 ms": _close("workspace close p95 ms"),
    "workspace close p99 ms": _close("workspace close p99 ms"),
    "workspace close not done": _close("workspace close p99 ms"),
}


def compare(runs):
    """The A/B verdict per metric over rounds that have both a base and a head run on one host."""
    by_round = {}
    for r in runs:
        if "metrics" in r and r.get("arm") in ("base", "head"):
            by_round.setdefault(r.get("round"), {})[r["arm"]] = r
    rounds = [v for _, v in sorted(by_round.items(), key=lambda kv: str(kv[0]))
              if "base" in v and "head" in v and v["base"].get("host") == v["head"].get("host")]
    out = {"method": f"paired percentile bootstrap, {int(CONFIDENCE * 100)} % CI of mean(head - base) over rounds, "
                     f"{BOOTSTRAP_RESAMPLES} resamples, seed 27698; lower is better for every metric",
           "rounds": len(rounds), "metrics": {}}
    for label, path in KEY:
        pairs = [(pick(v["base"]["metrics"], path), pick(v["head"]["metrics"], path)) for v in rounds]
        pairs = [(b, h) for b, h in pairs if isinstance(b, (int, float)) and isinstance(h, (int, float))]
        mean, low, high = paired_bootstrap(pairs)
        failed = METRIC_FAILURE.get(label)
        quiet = [r for r in rounds if failed and not failed(r["base"]["metrics"])]
        out["metrics"][label] = {"pairs": len(pairs), "mean_diff": mean, "ci_low": low, "ci_high": high,
                                 "verdict": ("not measured" if not pairs else
                                             "invalid: base did not reproduce" if quiet else verdict(low, high))}
    return out


def validity(runs):
    """Why this A/B gives no verdict, or None. A run counts only when the base reproduced Austin's day
    (cmux-ad 2026-10-30): any base run that showed none of Austin's failures makes the whole A/B invalid. A
    head whose commit changes the harness folder is refused too (the harness is held out)."""
    base = [r for r in runs if r.get("arm") == "base"]
    head = [r for r in runs if r.get("arm") == "head"]
    if not base or not head:
        return None
    missing = [r["dir"] for r in base + head if "metrics" not in r]
    if missing:
        return f"invalid: runs without results: {', '.join(missing)}"
    broken = [f"{r.get('arm')} round {r.get('round')}" for r in base + head if r["metrics"]["harness_faults"]]
    if broken:
        return f"invalid: harness faults ({', '.join(broken)}): {base[0]['metrics']['harness_faults'] or head[0]['metrics']['harness_faults']}"
    quiet = [f"round {r.get('round')}" for r in base if not any(r["metrics"]["austin_failure"].values())]
    if quiet:
        return f"invalid: base did not reproduce ({', '.join(quiet)} showed none of Austin's failures)"
    ancestor = base_is_ancestor(base[0].get("sha"), head[0].get("sha"))
    if ancestor is False:
        return "invalid: base is not an ancestor of head (the base must be the PR's parent commit)"
    edits = head_edits_harness(base[0].get("sha"), head[0].get("sha"))
    if edits is None:
        return "invalid: cannot check the head for harness edits (fetch both commits into this checkout)"
    if edits:
        return f"invalid: head edits the harness ({HARNESS_DIR} differs between base and head)"
    return None


def main():
    out_path, run_dirs = sys.argv[1], sys.argv[2:]
    runs = []
    for d in run_dirs:
        try:
            arm = json.load(open(os.path.join(d, "arm.json")))
        except (OSError, ValueError):
            arm = {"arm": "run"}
        try:
            run = json.load(open(os.path.join(d, "run.json")))
        except (OSError, ValueError) as error:
            runs.append({"dir": d, **arm, "error": f"no run.json: {error}"})
            continue
        runs.append({"dir": d, **arm, "host": arm.get("host") or run.get("host"), "metrics": run_metrics(run)})
    arms = {}
    for r in runs:
        if "metrics" in r:
            arms.setdefault(r["arm"], []).append(r)
    summary = {"schema": 2, "runs": runs, "arms": {}}
    for name, members in arms.items():
        medians = {}
        for label, path in KEY:
            values = [pick(r["metrics"], path) for r in members]
            values = [v for v in values if isinstance(v, (int, float))]
            medians[label] = statistics.median(values) if values else None
        summary["arms"][name] = {"sha": members[0].get("sha"), "runs": len(members), "hosts": sorted({m["host"] for m in members}),
                                 "median": medians}
    rounds = {}
    for r in runs:
        rounds.setdefault(r.get("round"), set()).add(r.get("host"))
    summary["same_host_per_round"] = {str(k): len(v) == 1 for k, v in rounds.items()}
    summary["invalid"] = validity(runs)
    if "base" in arms and "head" in arms:
        summary["measured_commits"] = measured_commits(arms["base"][0].get("sha"), arms["head"][0].get("sha"))
    if "base" in arms and "head" in arms and not summary["invalid"]:
        summary["comparison"] = compare(runs)
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=1, default=str)
    names = list(summary["arms"])
    lines = [f"Austin's day: {len(runs)} runs; arms {', '.join(f'{n} ({summary['arms'][n]['sha'] or '?'}, {summary['arms'][n]['runs']} runs)' for n in names)}"]
    lines.append(f"same host per round: {summary['same_host_per_round']}")
    if summary.get("measured_commits") is not None:
        commits = summary["measured_commits"]
        lines.append(f"measured commits (base..head): {len(commits)}; check they are the PR's own (base = the PR's parent)")
        lines.extend(f"   {c}" for c in commits[:30])
    if summary["invalid"]:
        lines.append(f"{summary['invalid']} -- NO VERDICT")
    width = max(len(label) for label, _ in KEY)
    comparison = summary.get("comparison")
    header = " " * width + "  " + "  ".join(f"{n:>12}" for n in names)
    if comparison:
        header += f"  {'head-base [95% CI]':>34}  verdict"
    lines.append(header)
    for label, _ in KEY:
        line = f"{label:<{width}}  " + "  ".join(f"{str(summary['arms'][n]['median'][label]):>12}" for n in names)
        if comparison:
            c = comparison["metrics"][label]
            fmt = lambda v: "?" if v is None else f"{v:.4g}"
            line += f"  {fmt(c['mean_diff']) + ' [' + fmt(c['ci_low']) + ', ' + fmt(c['ci_high']) + ']':>34}  {c['verdict']}"
        lines.append(line)
    if comparison:
        lines.append(f"({comparison['method']}; {comparison['rounds']} rounds)")
    for r in runs:
        if "metrics" not in r:
            lines.append(f"{r['dir']}: {r['error']}")
            continue
        m = r["metrics"]
        seen = [k for k, v in m["austin_failure"].items() if v]
        lines.append(f"{r.get('arm')} round {r.get('round')} on {r.get('host')}: agents {m['agents_started']}/{m['agents']} "
                     f"(hooked {m['agents_hooked']}), hooks {m['agent_hooks']}; Austin's failures seen: {', '.join(seen) or 'NONE'}"
                     + (f"; HARNESS FAULTS: {'; '.join(m['harness_faults'])}" if m["harness_faults"] else ""))
        lines.append(f"   stalls >100 ms: CODE {m['stall_code_count']} ({m['stall_code_total_ms']} ms), "
                     f"WAIT {m['stall_wait_count']} ({m['stall_wait_total_ms']} ms, max CPU share {m['stall_wait_cpu_share_max']}) "
                     f"next to swap max {m['swap_used_mb']['max']} MB, memory level min {m['memory_level_min']}; WAITs: owner B8 (memory)")
        for site in m["stall_sites"][:5]:
            lines.append(f"   stall {site['total_ms']} ms x{site['count']} (max {site['max_ms']}) {site['symbol']} owner {site['owner']}")
        for n in m["notes"][:5]:
            lines.append(f"   note: {n}")
    text = "\n".join(lines)
    with open(os.path.splitext(out_path)[0] + ".txt", "w") as f:
        f.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
