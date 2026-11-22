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

An A/B (base and head arms) gives a verdict per metric: a paired t-interval, the 95 % confidence interval
of mean(head - base) over the rounds (each round is one base and one head run on one host), t with n - 1
degrees of freedom. Rounds alternate which arm runs first (ABBA), and each metric also gets a position
estimate (second run - first run), so a warm-up or drift effect shows apart from the arm difference. Every metric is lower-is-better: `better` when the whole interval is
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
# The checkout (git history and OWNERS.md): the runner's private copy names it; else this file's checkout.
REPO = os.environ.get("AUSTINS_DAY_REPO") or os.path.abspath(os.path.join(HERE, "..", "..", ".."))


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
    # Without a start read the window is unknown (the histogram counts from app launch): not measured.
    if not isinstance(start, dict) or start.get("bounds_us") != end["bounds_us"]:
        return None
    before = start.get("counts")
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


# Every chat that got no answer is ranked last, at one value above any possible answer: the 150 s a wave
# waits for its chats (driver.py waves(), thread.join(timeout=150); a chat still running then is recorded as
# unanswered). Then p50 and p95 over all chats are exact
# order statistics: no-answer is "slower than every answer", whatever way the chat failed (review of
# bcbeee46824: a time-to-failure bound differed by failure path and could flip the sign of an A/B).
NO_ANSWER_MS = 150_000.0


def first_answers_all_chats(waves):
    """Every chat attempt: an answered chat at its first-answer time, every other chat at NO_ANSWER_MS."""
    out = []
    for w in waves:
        chats = w.get("chats")
        if not isinstance(chats, list):
            continue
        for chat in chats:
            if not isinstance(chat, list):
                continue
            answered = first_answers([{"chats": [chat]}])
            out.append(min(answered[0], NO_ANSWER_MS) if answered else NO_ANSWER_MS)
    return out


def first_answers(waves):
    """Per chat that got an answer: session/new ms + the prompt's first agent_message_chunk ms."""
    out = []
    for w in waves:
        chats = w.get("chats")
        if not isinstance(chats, list):
            continue
        for chat in chats:
            if not isinstance(chat, list):
                continue
            new = next((a for a in chat if a.get("method") == "session/new" and not a.get("error")), None)
            prompt = next((a for a in chat if a.get("method") == "session/prompt"), None)
            if new and prompt and isinstance(prompt.get("first_chunk_ms"), (int, float)):
                out.append(new["ms"] + prompt["first_chunk_ms"])
    return out


def lock_held_share(first, last, window_s):
    """Share of the window the registry lock was held: the change of count x mean hold between two server-stats
    reads, over the window. The daemon's mean is a whole number of microseconds (rounded down), so the result
    is low by up to about 1 µs per hold in the window (an exact value needs the daemon to report its hold sum);
    a daemon restart in the window resets its counters (clamped at 0)."""
    def held_us(snapshot):
        hold = stat(snapshot, "registry_lock", "hold_us") or {}
        return (hold.get("count") or 0) * (hold.get("mean") or 0)
    if not window_s or not stat(last, "registry_lock", "hold_us"):
        return None
    return round(max(0, held_us(last) - held_us(first)) / (window_s * 1e6), 4)


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
    answers = [a for w in series["waves"] for a in (w.get("answers") or
               [x for chat in (w["chats"] if isinstance(w.get("chats"), list) else []) if isinstance(chat, list) for x in chat])]
    # One chat = the first answer of a one_chat attempt: session/new, or the connection that failed first.
    # An empty chat (written by drivers before a84ddb0e414's fix) is a failed open: it never got an answer.
    # Drivers before 152ee4f4d1e wrote "chats": <the wave size> (an int): only a list is a chat record.
    chat_firsts = [(chat[0] if chat else {"method": "connection", "error": "no answer"})
                   for w in series["waves"] if isinstance(w.get("chats"), list)
                   for chat in w["chats"] if isinstance(chat, list)]
    if not any(isinstance(w.get("chats"), list) for w in series["waves"]):
        # Runs from before the per-chat record: one chat per session/new; their failed connections cannot be
        # told apart from a later error of a chat, so they are not counted (an undercount, said in the README).
        chat_firsts = [a for a in answers if a["method"] == "session/new"]
    chats_total = len(chat_firsts)
    chats_failed = sum(1 for a in chat_firsts if a.get("error"))
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
        # Share of wall time the registry lock was held over the run's own server-stats window: the change of
        # hold count x mean hold (both cumulative from the daemon's start) between the first and last read,
        # divided by the window (lead 2026-10-30: ~85 % in both arms of the B1 A/B).
        "registry_lock_held_share": lock_held_share(first, last, window_s),
        "daemon_lock_top_sites": (stat(last, "registry_lock", "top_sites") or [])[:5],
        "journal_commit_us": {k: (stat(last, "journal_writer", "commit_us") or {}).get(k) for k in ("p50", "p90", "p99", "max")},
        "workspace_close_app_ms": dist(c.get("app_gone_ms") for c in closes),
        "workspace_close_daemon_ms": dist(c.get("daemon_gone_ms") for c in closes),
        "workspace_close_not_done": sum(1 for c in closes if c.get("app_gone_ms") is None or c.get("daemon_gone_ms") is None),
        "workspace_close_attempts": len(series["closes"]),
        "acpmux_new_ms": dist(a["ms"] for a in answers if a["method"] == "session/new"),
        # Time to first answer per chat (#28442): from the chat's session/new to its prompt's first answer
        # text, for chats whose prompt got one (session/new time + the prompt's first-chunk time).
        "acpmux_first_answer_ms": dist(first_answers(series["waves"])),
        "acpmux_answered_chats": len(first_answers(series["waves"])),
        "acpmux_first_answer_all_chats_ms": dist(first_answers_all_chats(series["waves"])),
        "acpmux_prompt_ms": dist(a["ms"] for a in answers if a["method"] == "session/prompt"),
        "acpmux_errors": counts(a["error"][:80] for a in answers if a.get("error")),
        # pa-b10's measure: each chat of a Chief wave is one attempt (its session/new, or the connection
        # that failed before it: refused, closed, timed out); a failed chat is either.
        "acpmux_opens": chats_total,
        "acpmux_open_failures": chats_failed,
        "acpmux_open_failure_share": round(chats_failed / chats_total, 4) if chats_total else None,
        "acpmux_connection_failures": sum(1 for a in answers if a["method"] == "connection"),
        "acpmux_host_start_timeouts": sum(1 for a in answers if "agent host start did not finish" in (a.get("error") or "")),
        "acpmux_agent_start_timeouts": sum(1 for a in answers if "agent_start did not finish" in (a.get("error") or "")),
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
    # Every asked agent must start with hooks (review of aa7c09ebaed, finding 3): a run with fewer agents
    # or no hooks has less load, and its refusals and latencies would look "better".
    if run.get("agents_made", m["agents"]) < m["agents"]:
        faults.append(f"{run.get('agents_made')} of {m['agents']} agent terminals made")
    if m["agents_started"] < m["agents"]:
        faults.append(f"{m['agents_started']} of {m['agents']} agents started")
    if m["agents_hooked"] < m["agents_started"]:
        faults.append(f"{m['agents_hooked']} of {m['agents_started']} started agents got hooks")
    if m["agents_hooked"] and not hooks:
        faults.append("hooked agents logged no hook runs")
    crashed = [h["rc"] for h in hooks if str(h.get("rc", "")).startswith("harness-error")]
    if crashed:
        faults.append(f"{len(crashed)} hook runs hit a harness error ({crashed[0][:120]})")
    m["harness_faults"] = faults
    # The daemon's lock detail after the load (server-stats `locks`, #28147 and later): the top sites of the
    # registry lock and mux.state by total hold and by p99 hold, since the daemon's start. Descriptive.
    detail = next((x.get("locks") for x in reversed(series.get("locks") or []) if x.get("locks")), None)
    # Named sites (lead 2026-10-30, B3 1d): each one's hold p99 and total hold of a lock, from the post-load
    # lock detail. A site is named by its file and the function that holds the lock (NAMED_LOCK_SITES), so a
    # fix that moves the lock to another line of the same function still pairs; the line(s) each arm used are
    # recorded. Several lines of one function add up (total) or take the largest (p99). A site in neither
    # top-20 list counts as 0 when the lock's `sites` count shows every site was listed; else it is unknown.
    def site_value(lock, name, key):
        if not detail:
            return None, []
        lock_detail = detail.get(lock) or {}
        rows = {}
        for listing in ("by_hold_total", "by_hold_p99"):
            for s in lock_detail.get(listing) or []:
                rows[s.get("site")] = s
        lines = NAMED_LOCK_SITES[name]
        hits = [s for site, s in rows.items() if any((site or "").endswith(f"{path}:{line}") for path, line in lines)]
        if hits:
            values = [s.get(key) or 0 for s in hits]
            return (sum(values) if key == "hold_total_us" else max(values)), sorted(s.get("site") for s in hits)
        complete = isinstance(lock_detail.get("sites"), int) and lock_detail["sites"] <= len(lock_detail.get("by_hold_total") or [])
        return (0 if complete else None), []

    def site_bound(lock, key):
        """Upper bound for a site in neither top-20 list: the smallest value in the list ranked by that key
        (review of 7b1d2cd248a). Reported apart from the value, never mixed with a measured one."""
        lock_detail = (detail or {}).get(lock) or {}
        listing = lock_detail.get("by_hold_total" if key == "hold_total_us" else "by_hold_p99") or []
        values = [s.get(key) for s in listing if isinstance(s.get(key), (int, float))]
        return min(values) if values else None
    m["lock_sites"] = {}
    for lock in ("registry",):
        for name in NAMED_LOCK_SITES:
            p99, used = site_value(lock, name, "hold_p99_us")
            total, _ = site_value(lock, name, "hold_total_us")
            m["lock_sites"][f"{lock}:{name}"] = {
                "hold_p99_us": p99, "hold_total_us": total, "sites": used,
                # When the site is in neither list (value None), at most this: the smallest listed value.
                "hold_p99_us_at_most": site_bound(lock, "hold_p99_us") if p99 is None else None,
                "hold_total_us_at_most": site_bound(lock, "hold_total_us") if total is None else None}
    m["lock_top_sites"] = None if not detail else {
        name: {"by_hold_total": [{k: s.get(k) for k in ("site", "acquisitions", "hold_total_us", "hold_p99_us", "hold_max_us")}
                                 for s in (detail.get(name) or {}).get("by_hold_total") or []],
               "by_hold_p99": [{k: s.get(k) for k in ("site", "acquisitions", "hold_total_us", "hold_p99_us", "hold_max_us")}
                               for s in (detail.get(name) or {}).get("by_hold_p99") or []]}
        for name in ("registry", "state")}
    # Who fills the connection pool (descriptive): median per load sample of the daemon's own client list by
    # label, and of the live client processes by role; plus the refusals each client kind saw itself.
    holders = load(series.get("holders", []))
    labels = sorted({k for h in holders for k in (h.get("by_label") or {})})
    kinds = {}
    for h in holders:
        for role, shapes in (h.get("process_kinds") or {}).items():
            for shape, n in shapes.items():
                kinds.setdefault(role, {}).setdefault(shape, []).append(n)
    m["process_kinds_median"] = {role: {shape: statistics.median(ns + [0] * (len(holders) - len(ns)))
                                        for shape, ns in sorted(shapes.items(), key=lambda kv: -sum(kv[1]))[:8]}
                                 for role, shapes in kinds.items()}
    end_list = next((h for h in reversed(series.get("holders", [])) if h.get("phase") == "end" and h.get("listed") is not None), None)
    m["pool_holders_after_load"] = None if not end_list else {
        "listed": end_list.get("listed"), "by_label": end_list.get("by_label"), "max_age_s": end_list.get("max_age_s")}
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
        "acpmux_open_failures": (m["acpmux_open_failures"] or 0) > 0,
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
    ("acpmux open failure share", ("acpmux_open_failure_share",)),
    ("acpmux host-start 10 s time-outs", ("acpmux_host_start_timeouts",)),
    ("acpmux agent_start 90 s time-outs", ("acpmux_agent_start_timeouts",)),
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
# Lock sites reported by name (B3), each a function and the (file, line) of its lock calls in the builds
# measured: the terminal revision read (line 9 before B3 1d; its fallback at line 20 after) and the progress
# report.
NAMED_LOCK_SITES = {
    "terminal_registry_revision": (("mux/frontend_projection.rs", 9), ("mux/frontend_projection.rs", 20)),
    "terminal progress report": (("mux/terminal_progress.rs", 18),),
}
def scenario_note(runs):
    """The scenario's agent CLI rate, from the runs' own options."""
    rates = sorted({(r.get("opts") or {}).get("cli_every") for r in runs if isinstance(r, dict)} - {None})
    if rates == [0]:
        return "main arm: no agent cmux CLI calls (hooks and the app only)"
    if not rates:
        rates = [3]  # runs from before the option was recorded: their default was one call per 3 tool calls
    return ("assumed sensitivity arm, not from Austin's data: one cmux workspace list per " + "/".join(map(str, rates))
            + " tool calls; it fills the 64-slot pool with CLI calls, so hook-path fixes cannot show in refused connections")


AGENT_CLI_RATE_NOTE = ("assumed, not from Austin's data: one cmux workspace list per 3 tool calls; it fills the 64-slot pool with CLI calls, so hook-path fixes cannot show in refused connections")
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


def is_revert_pair(base_sha, head_sha, repo=REPO):
    """True when the base is the head plus exactly one commit that reverts a commit of the head's history (a
    "before" ref made by reverting the fix on the fix's own tree, as for B3 1d): the base has one parent, the
    head; its message says "This reverts commit X"; X is an ancestor of the head; and the base-to-head diff is
    X's own diff. Then base..head is the fix alone."""
    if not base_sha or not head_sha:
        return None

    def git(*args):
        # Bytes, not text: a file in the reverted commit need not be UTF-8 (review of 7b1d2cd248a).
        done = subprocess.run(["git", "-C", repo, *args], capture_output=True, timeout=60)
        return done.stdout.decode("utf-8", "surrogateescape") if done.returncode == 0 else None
    try:
        parents = git("rev-list", "--parents", "-n", "1", base_sha)
        head = git("rev-parse", head_sha)
        body = git("log", "-1", "--format=%B", base_sha)
    except (OSError, subprocess.SubprocessError):
        return None
    if parents is None or head is None or body is None:
        return None
    ids = parents.split()
    if len(ids) != 2 or ids[1] != head.strip():
        return False
    found = re.search(r"This reverts commit ([0-9a-f]{7,40})", body)
    if not found:
        return False
    reverted = found.group(1)
    try:
        ancestor = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", reverted, head_sha], capture_output=True, timeout=60)
        own = git("diff", f"{reverted}^", reverted)
        pair = git("diff", base_sha, head_sha)
    except (OSError, subprocess.SubprocessError):
        return None
    return ancestor.returncode == 0 and own is not None and pair is not None and own == pair and bool(own)


def measured_commits(base_sha, head_sha, repo=REPO):
    """The commits the A/B measures (base..head, first line each): the reader checks they are the PR's own."""
    try:
        done = subprocess.run(["git", "-C", repo, "log", "--format=%h %s", f"{base_sha}..{head_sha}"], capture_output=True,
                              text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.splitlines() if done.returncode == 0 else None


# Two-sided 95 % Student t quantiles, t(0.975, df) for df = 1 .. 30 (beyond: 1.96).
T975 = (12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131,
        2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042)


def paired_t_interval(pairs):
    """Paired t-interval: 95 % CI of mean(head - base) over the rounds' differences, t with n - 1 degrees of
    freedom; (mean, low, high). A percentile bootstrap over 5 or fewer pairs is far too narrow (the A/A of
    2026-10-30 failed 10 of 28 metrics with it on identical arms); the t-interval is the small-sample method."""
    diffs = [h - b for b, h in pairs]
    if len(diffs) < 2:
        return (diffs[0] if diffs else None), None, None
    mean = statistics.mean(diffs)
    half = (T975[len(diffs) - 2] if len(diffs) - 1 <= len(T975) else 1.96) * statistics.stdev(diffs) / math.sqrt(len(diffs))
    return mean, mean - half, mean + half


def position_effect(rounds, path):
    """Mean of (second run - first run) over the rounds, whichever arm ran first (ABBA order): a non-zero
    value is a warm-up or drift effect of the run position, which ABBA cancels from the arm difference."""
    diffs = []
    for v in rounds:
        b, h = pick(v["base"]["metrics"], path), pick(v["head"]["metrics"], path)
        if not isinstance(b, (int, float)) or not isinstance(h, (int, float)):
            continue
        diffs.append((h - b) if v["base"].get("position", 1) == 1 else (b - h))
    return paired_t_interval([(0, d) for d in diffs])


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
    # Chat opens fail on Austin's day (pa-b10): a share or count needs a base that failed some opens.
    "acpmux open failure share": lambda m: (m.get("acpmux_open_failures") or 0) > 0,
    "acpmux host-start 10 s time-outs": lambda m: (m.get("acpmux_host_start_timeouts") or 0) > 0,
    "acpmux agent_start 90 s time-outs": lambda m: (m.get("acpmux_agent_start_timeouts") or 0) > 0,
}


def compare(runs):
    """The A/B verdict per metric over rounds that have both a base and a head run on one host."""
    by_round = {}
    for r in runs:
        if "metrics" in r and r.get("arm") in ("base", "head"):
            by_round.setdefault(r.get("round"), {})[r["arm"]] = r
    rounds = [v for _, v in sorted(by_round.items(), key=lambda kv: str(kv[0]))
              if "base" in v and "head" in v and v["base"].get("host") == v["head"].get("host")]
    out = {"method": f"paired t-interval, {int(CONFIDENCE * 100)} % CI of mean(head - base) over rounds, t with n - 1 df; "
                     "lower is better for every metric; position = mean(second run - first run) over rounds",
           "rounds": len(rounds), "metrics": {}}
    for label, path in KEY:
        pairs = [(pick(v["base"]["metrics"], path), pick(v["head"]["metrics"], path)) for v in rounds]
        pairs = [(b, h) for b, h in pairs if isinstance(b, (int, float)) and isinstance(h, (int, float))]
        mean, low, high = paired_t_interval(pairs)
        _, pos_low, pos_high = position_effect(rounds, path)
        failed = METRIC_FAILURE.get(label)
        quiet = [r for r in rounds if failed and not failed(r["base"]["metrics"])]
        out["metrics"][label] = {"pairs": len(pairs), "mean_diff": mean, "ci_low": low, "ci_high": high,
                                 "position_ci": [pos_low, pos_high],
                                 "position_effect": None if pos_low is None else not pos_low <= 0 <= pos_high,
                                 "verdict": ("not measured" if not pairs else
                                             "invalid: base did not reproduce" if quiet else verdict(low, high))}
    return out


# Paired comparisons a lead or fix author asked for, outside the verdict set: the same paired t-interval,
# but no verdict and no A/A check (some are descriptive estimates). Label -> path in metrics.
REQUESTED = [
    ("registry lock held share", ("registry_lock_held_share",)),
    ("registry lock wait p99 us", ("daemon_lock_wait_us", "p99")),
    ("app request p99 ms", ("app_requests", "p99")),
    # #28442 (pa-b10): the time to first answer per chat (the 90 s agent_start time-outs are a verdict row).
    ("acpmux first answer median ms (answered chats only)", ("acpmux_first_answer_ms", "p50")),
    ("acpmux first answer p95 ms (answered chats only)", ("acpmux_first_answer_ms", "p95")),
    ("acpmux answered chats", ("acpmux_answered_chats",)),
    ("acpmux first answer median ms (all chats; no answer ranked last at 150 s)",
     ("acpmux_first_answer_all_chats_ms", "p50")),
    ("acpmux first answer p95 ms (all chats; no answer ranked last at 150 s)",
     ("acpmux_first_answer_all_chats_ms", "p95")),
] + [(f"{lock} lock {suffix} {what}", ("lock_sites", f"{lock}:{suffix}", key))
     for lock in ("registry",) for suffix in NAMED_LOCK_SITES
     for what, key in (("hold p99 us", "hold_p99_us"), ("hold total us", "hold_total_us"))]


def requested_comparisons(runs):
    by_round = {}
    for r in runs:
        if "metrics" in r and r.get("arm") in ("base", "head"):
            by_round.setdefault(r.get("round"), {})[r["arm"]] = r
    rounds = [v for _, v in sorted(by_round.items(), key=lambda kv: str(kv[0]))
              if "base" in v and "head" in v and v["base"].get("host") == v["head"].get("host")]
    out = {}
    for label, path in REQUESTED:
        raw = [(pick(v["base"]["metrics"], path), pick(v["head"]["metrics"], path)) for v in rounds]
        pairs = [(b, h) for b, h in raw if isinstance(b, (int, float)) and isinstance(h, (int, float))]
        mean, low, high = paired_t_interval(pairs)
        # Rounds dropped because a value was unknown (for a lock site: in neither top-20 list while the lock had
        # more sites than listed). A dropped round can hide a change, so the count is shown next to n.
        out[label] = {"n": len(pairs), "dropped": len(raw) - len(pairs), "base_median": statistics.median([b for b, _ in pairs]) if pairs else None,
                      "head_median": statistics.median([h for _, h in pairs]) if pairs else None,
                      "mean_diff": mean, "ci_low": low, "ci_high": high}
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
    broken = [f"{r.get('arm')} round {r.get('round')}: {'; '.join(r['metrics']['harness_faults'])}"
              for r in base + head if r["metrics"]["harness_faults"]]
    if broken:
        return f"invalid: harness faults ({' | '.join(broken)})"
    quiet = [f"round {r.get('round')}" for r in base if not any(r["metrics"]["austin_failure"].values())]
    if quiet:
        return f"invalid: base did not reproduce ({', '.join(quiet)} showed none of Austin's failures)"
    ancestor = base_is_ancestor(base[0].get("sha"), head[0].get("sha"))
    if ancestor is False and not is_revert_pair(base[0].get("sha"), head[0].get("sha")):
        return ("invalid: base is not an ancestor of head (the base must be the PR's parent commit, or the head "
                "plus one revert commit)")
    edits = head_edits_harness(base[0].get("sha"), head[0].get("sha"))
    if edits is None:
        return "invalid: cannot check the head for harness edits (fetch both commits into this checkout)"
    if edits:
        return f"invalid: head edits the harness ({HARNESS_DIR} differs between base and head)"
    return None


AA_FAILURES = os.path.join(HERE, "aa-failures.json")


def aa_failures():
    """Metrics that failed the last A/A self-test (aa-failures.json beside this file): every summary marks
    them 'invalid (fails A/A)' until a later A/A passes them."""
    try:
        with open(AA_FAILURES) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def main():
    args = sys.argv[1:]
    aa_mode = bool(args) and args[0] == "--aa"
    if aa_mode:
        args = args[1:]
    out_path, run_dirs = args[0], args[1:]
    runs = []
    raw_runs = []
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
        raw_runs.append(run)
    arms = {}
    for r in runs:
        if "metrics" in r:
            arms.setdefault(r["arm"], []).append(r)
    summary = {"schema": 2, "runs": runs, "arms": {}, "scenario_note": scenario_note(raw_runs)}
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
    rates = {(r.get("opts") or {}).get("cli_every") for r in raw_runs}
    if len(rates) > 1:
        summary["invalid"] = f"invalid: the runs use different agent CLI rates ({sorted(map(str, rates))}): different scenarios"
    if "base" in arms and "head" in arms:
        b, h = arms["base"][0].get("sha"), arms["head"][0].get("sha")
        if is_revert_pair(b, h):
            summary["measured_commits"] = ["(revert pair) the base reverts on the head:"] + (measured_commits(h, b) or ["?"])
        else:
            summary["measured_commits"] = measured_commits(b, h)
    if aa_mode:
        shas = {r.get("sha") for r in runs if "metrics" in r}
        if len(shas) != 1:
            summary["invalid"] = f"invalid: an A/A needs one build in both arms, got {sorted(map(str, shas))}"
    if "base" in arms and "head" in arms and not summary["invalid"]:
        summary["requested"] = requested_comparisons(runs)
        summary["comparison"] = compare(runs)
        known = aa_failures()
        # Runs that recorded no rate are from before the option existed: their default was one call per 3.
        rate = (lambda r: 3 if r is None else r)(next(iter(rates))) if len(rates) == 1 else None
        tested = known.get("scenarios", {}).get(str(rate)) if isinstance(known.get("scenarios"), dict) else None
        if not aa_mode and tested is None:
            # No A/A for this scenario yet (aa-failures.json "scenarios", keyed by the agent CLI rate).
            summary["aa_note"] = f"no A/A yet for this scenario (agent CLI rate {rate}): verdicts are not A/A-checked"
            for row in summary["comparison"]["metrics"].values():
                row["verdict"] = f"not A/A-checked: {row['verdict']}"
        for label, row in summary["comparison"]["metrics"].items():
            if tested is not None and label in tested.get("metrics", {}) and not aa_mode:
                row["verdict"] = f"invalid (fails A/A {tested.get('date', '')}): {row['verdict']}"
        if aa_mode:
            # An A/A passes a metric when its interval contains 0 (an exact [0, 0] passes; no pairs: not tested).
            failed = {label: {"ci_low": row["ci_low"], "ci_high": row["ci_high"]}
                      for label, row in summary["comparison"]["metrics"].items()
                      if row["ci_low"] is not None and row["ci_high"] is not None and not row["ci_low"] <= 0 <= row["ci_high"]}
            summary["aa"] = {"build": next(iter(shas)), "failed": failed,
                             "passed": sorted(l for l, r in summary["comparison"]["metrics"].items()
                                              if l not in failed and r["ci_low"] is not None),
                             "not_tested": sorted(l for l, r in summary["comparison"]["metrics"].items() if r["ci_low"] is None)}
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=1, default=str)
    names = list(summary["arms"])
    lines = [f"Austin's day: {len(runs)} runs; arms {', '.join(f'{n} ({summary['arms'][n]['sha'] or '?'}, {summary['arms'][n]['runs']} runs)' for n in names)}"]
    lines.append(f"same host per round: {summary['same_host_per_round']}")
    lines.append("scenario: " + summary["scenario_note"])
    if summary.get("measured_commits") is not None:
        commits = summary["measured_commits"]
        lines.append(f"measured commits (base..head): {len(commits)}; check they are the PR's own (base = the PR's parent)")
        lines.extend(f"   {c}" for c in commits[:30])
    if summary["invalid"]:
        lines.append(f"{summary['invalid']} -- NO VERDICT")
    if summary.get("aa_note"):
        lines.append(summary["aa_note"])
    width = max(len(label) for label, _ in KEY)
    comparison = summary.get("comparison")
    header = " " * width + "  " + "  ".join(f"{n:>12}" for n in names)
    if comparison:
        header += f"  {'head-base [95% CI]':>34}  verdict  (position: 2nd-1st [95% CI])"
    lines.append(header)
    for label, _ in KEY:
        line = f"{label:<{width}}  " + "  ".join(f"{str(summary['arms'][n]['median'][label]):>12}" for n in names)
        if comparison:
            c = comparison["metrics"][label]
            fmt = lambda v: "?" if v is None else f"{v:.4g}"
            line += f"  {fmt(c['mean_diff']) + ' [' + fmt(c['ci_low']) + ', ' + fmt(c['ci_high']) + ']':>34}  {c['verdict']}"
            if c.get("position_effect"):
                line += f"  (POSITION EFFECT [{fmt(c['position_ci'][0])}, {fmt(c['position_ci'][1])}])"
        lines.append(line)
    if comparison:
        lines.append(f"({comparison['method']}; {comparison['rounds']} rounds)")
    if summary.get("requested"):
        lines.append("requested paired comparisons (no verdict, not A/A-checked; head - base, paired t-interval 95 %):")
        for label, c in summary["requested"].items():
            fmt = lambda v: "?" if v is None else f"{v:.4g}"
            lines.append(f"   {label}: n={c['n']}" + (f" (dropped {c['dropped']}: value unknown)" if c.get("dropped") else "")
                         + f" base median {fmt(c['base_median'])} head median {fmt(c['head_median'])} "
                         f"diff {fmt(c['mean_diff'])} [{fmt(c['ci_low'])}, {fmt(c['ci_high'])}]")
    if summary.get("aa"):
        aa = summary["aa"]
        lines.append(f"A/A self-test of {aa['build']}: {len(aa['passed'])} metrics pass (CI contains 0), "
                     f"{len(aa['failed'])} FAIL: {', '.join(aa['failed']) or 'none'}; not tested: {', '.join(aa['not_tested']) or 'none'}")
        lines.append("Record it: add summary.json's 'aa' block to scripts/cmux-next/austins-day/aa-failures.json under "
                     "\"scenarios\" -> the agent CLI rate (\"0\" main arm, \"3\" assumed arm) as "
                     "{\"date\", \"build\", \"harness\", \"metrics\": failed}, in the harness owner's PR.")
    for r in runs:
        if "metrics" not in r:
            lines.append(f"{r['dir']}: {r['error']}")
            continue
        m = r["metrics"]
        seen = [k for k, v in m["austin_failure"].items() if v]
        lines.append(f"{r.get('arm')} round {r.get('round')} on {r.get('host')}: agents {m['agents_started']}/{m['agents']} "
                     f"(hooked {m['agents_hooked']}), hooks {m['agent_hooks']}; Austin's failures seen: {', '.join(seen) or 'NONE'}"
                     + (f"; HARNESS FAULTS: {'; '.join(m['harness_faults'])}" if m["harness_faults"] else ""))
        if m.get("lock_top_sites"):
            for lock in ("registry", "state"):
                top = (m["lock_top_sites"].get(lock) or {}).get("by_hold_total") or []
                if top:
                    lines.append(f"   {lock} lock, top holders by total hold (since the daemon started; read after the load): " + "; ".join(
                        f"{s['site'].rsplit('/', 1)[-1]} {round((s.get('hold_total_us') or 0) / 1e6, 1)} s"
                        f" p99 {round((s.get('hold_p99_us') or 0) / 1000, 1)} ms" for s in top[:3]))
        for site, v in ((m.get("lock_sites") or {}).items() if m.get("lock_top_sites") else ()):
            def show(value, bound, unit):
                if value is not None:
                    return f"{round(value / unit, 1)}"
                # A bound is rounded up, never down (review of 748dc589635: 40,000 us printed as 0.0 s).
                return (f"absent from the top 20, so at most {math.ceil(bound / unit * 10) / 10}"
                        if bound is not None else "?")
            lines.append(f"   {site}: total hold {show(v.get('hold_total_us'), v.get('hold_total_us_at_most'), 1e6)} s, "
                         f"hold p99 {show(v.get('hold_p99_us'), v.get('hold_p99_us_at_most'), 1000)} ms"
                         + (f" (lines {', '.join(s.rsplit(':', 1)[-1] for s in v['sites'])})" if v.get("sites") else ""))
        if m.get("registry_lock_held_share") is not None:
            lines.append(f"   registry lock held {m['registry_lock_held_share']:.1%} of the run's server-stats window "
                         "(descriptive, no verdict: not yet A/A-tested; the daemon's mean hold is a whole number of "
                         "microseconds, so this is low by up to about 1 µs per hold in the window)")
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
