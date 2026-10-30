#!/usr/bin/env python3
"""Austin's day: one JSON and a short text summary from the runs of one or two arms.

  summarize.py OUT.json RUN_DIR [RUN_DIR...]      (each RUN_DIR has run.json and arm.json)

arm.json (written by austins-day.sh): {"arm": "base"|"head"|"run", "sha", "job", "round", "host"}.
Every metric is over the load phase. Distributions are {n, p50, p95, p99, max} (nearest rank);
counts are plain numbers. Per arm, each metric is listed per run and as the median over runs. An
A/B is evidence only when both arms ran on the same host (the summary says so per round).

`austin_failure` per run names which of Austin's failures the run showed: refused daemon
connections, app requests with no reply in time, registry lock waits over 1 s at p99, acpmux
restarts, cmux main-thread stalls over 100 ms. A run that shows none did not reproduce his day.
"""
import json
import math
import os
import re
import statistics
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
    found = re.match(r"^(?:\(extension in )?([A-Za-z0-9_]+)\)?[.:]", symbol or "")
    if not found:
        return None
    module = found.group(1)
    best = None
    for path, owner in OWNERS:
        if f"/Sources/{module}/" in path or path.endswith(f"/Sources/{module}") or f"/Sources/{module}/" in path + "/":
            if best is None or len(path) < len(best[0]):
                best = (path, owner)
    return best[1] if best else None


def stall_sites(stalls):
    sites = {}
    for s in stalls:
        if not s.get("cmux_frame"):
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


def run_metrics(run):
    series = run["series"]
    load = lambda rows: [r for r in rows if r.get("phase") == "load"]
    stats = [s for s in series["server_stats"] if s.get("stats")]
    first = stats[0]["stats"] if stats else {}
    last = stats[-1]["stats"] if stats else {}
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
        "app_control_ms": dist(c["ms"] for c in control), "app_control_errors": sum(1 for c in control if c.get("error")),
        "person_cli_ms": dist(p["ms"] for p in person), "person_cli_refusals": counts(p.get("code") for p in person),
        "agent_hook_ms": dist(h["ms"] for h in hooks), "agent_hooks": len(hooks),
        "agent_hook_failures": counts(h.get("rc") for h in hooks if h.get("rc") not in (0, None)),
        "agent_tool_ms": dist(t["ms"] for t in tools),
        "agent_cli_ms": dist(c["ms"] for c in agent_cli), "agent_cli_refusals": counts(c.get("code") for c in agent_cli),
        "daemon_connections": {"accepted": (stat(last, "connections", "accepted") or 0) - (stat(first, "connections", "accepted") or 0),
                               "refused": (stat(last, "connections", "refused") or 0) - (stat(first, "connections", "refused") or 0),
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
        "stalls_over_100ms_cmux": sum(1 for s in run["stalls"] if s.get("cmux_frame")),
        "stalls_over_100ms_all": len(run["stalls"]),
        "stall_sites": stall_sites(run["stalls"]),
        "notes": series.get("notes", []),
    }
    m["austin_failure"] = {
        "refused_connections": (m["daemon_connections"]["refused"] or 0) > 0
        or any(k in ("server.busy", "session.busy") for k in {**m["person_cli_refusals"], **m["agent_cli_refusals"]}),
        "app_no_reply": (m["app_no_reply_within"] or 0) > 0 or bool(m["app_requests"] and m["app_requests"].get("timeouts")),
        "lock_wait_p99_over_1s": (lock_wait.get("p99") or 0) > 1_000_000,
        "acpmux_restarts": restarts > 0 or (m["acpmux_unresponsive_log"] or 0) > 0,
        "cmux_stalls": m["stalls_over_100ms_cmux"] > 0,
    }
    return m


KEY = [  # (label, path in metrics) for the text summary
    ("app request p99 ms", ("app_requests", "p99")),
    ("app no-reply timeouts (log)", ("app_no_reply_within",)),
    ("person CLI p99 ms", ("person_cli_ms", "p99")),
    ("agent hook p99 ms", ("agent_hook_ms", "p99")),
    ("daemon refused", ("daemon_connections", "refused")),
    ("daemon peak/limit", ("daemon_connections", "peak")),
    ("lock wait p99 us", ("daemon_lock_wait_us", "p99")),
    ("workspace close p95 ms", ("workspace_close_app_ms", "p95")),
    ("workspace close not done", ("workspace_close_not_done",)),
    ("acpmux restarts", ("acpmux_restarts",)),
    ("acpmux new p99 ms", ("acpmux_new_ms", "p99")),
    ("app RSS max MB", ("memory", "app", "rss_mb", "max")),
    ("daemon RSS max MB", ("memory", "daemon", "rss_mb", "max")),
    ("acpmux RSS max MB", ("memory", "acpmux", "rss_mb", "max")),
    ("load1 max", ("load1", "max")),
    ("swap used max MB", ("swap_used_mb", "max")),
    ("cmux stalls >100 ms", ("stalls_over_100ms_cmux",)),
]


def pick(metrics, path):
    value = metrics
    for key in path:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def main():
    out_path, run_dirs = sys.argv[1], sys.argv[2:]
    runs = []
    for d in run_dirs:
        try:
            run = json.load(open(os.path.join(d, "run.json")))
        except (OSError, ValueError) as error:
            runs.append({"dir": d, "error": f"no run.json: {error}"})
            continue
        try:
            arm = json.load(open(os.path.join(d, "arm.json")))
        except (OSError, ValueError):
            arm = {"arm": "run"}
        runs.append({"dir": d, **arm, "host": arm.get("host") or run.get("host"), "metrics": run_metrics(run)})
    arms = {}
    for r in runs:
        if "metrics" in r:
            arms.setdefault(r["arm"], []).append(r)
    summary = {"schema": 1, "runs": runs, "arms": {}}
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
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=1, default=str)
    names = list(summary["arms"])
    lines = [f"Austin's day: {len(runs)} runs; arms {', '.join(f'{n} ({summary['arms'][n]['sha'] or '?'}, {summary['arms'][n]['runs']} runs)' for n in names)}"]
    lines.append(f"same host per round: {summary['same_host_per_round']}")
    width = max(len(label) for label, _ in KEY)
    lines.append(" " * width + "  " + "  ".join(f"{n:>12}" for n in names))
    for label, _ in KEY:
        lines.append(f"{label:<{width}}  " + "  ".join(f"{str(summary['arms'][n]['median'][label]):>12}" for n in names))
    for r in runs:
        if "metrics" not in r:
            lines.append(f"{r['dir']}: {r['error']}")
            continue
        m = r["metrics"]
        seen = [k for k, v in m["austin_failure"].items() if v]
        lines.append(f"{r.get('arm')} round {r.get('round')} on {r.get('host')}: agents {m['agents_started']}/{m['agents']} "
                     f"(hooked {m['agents_hooked']}), hooks {m['agent_hooks']}; Austin's failures seen: {', '.join(seen) or 'NONE'}")
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
