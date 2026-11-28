#!/usr/bin/env python3
"""Resident agent harnesses on this host and what keeps each one up: what the lane cap should count.

For every `acpmux __agent-host` this daemon runs (each is one session's harness, its session id in its
environment, ACPMUX_SESSION_ID) it reads the process tree and the recorded harness PID
(after custody recovery it may no longer be a child), deduplicates PIDs, and joins them with
`acpmux ls --json --machine local`:
  status      the session's acpmux status (running, ready, idle, ...)
  idle_s      seconds since its last turn ended (None while one runs)
  rss_mb      the tree's summed RSS (harness, MCP servers, everything under it)
  cpu_s       the tree's CPU seconds so far
  pin         what holds a ready (no turn) harness up past acpmux's idle period (hub/idle.rs, 2 min):
              "wait"  only waits run under it besides its MCP servers (sleep, tail --pid, timeout,
                      glaeda-gh wait, acpmux pr-wait, task-wait, wait_for), which hub/idle_wait.rs hands
                      to the daemon so the harness hibernates;
              "work"  something else runs (a build, a test, a dev server);
              "none"  nothing does: it hibernates at its deadline.
Prints one JSON line per harness with --rows, then the summary: resident harnesses, their RSS, how many
are busy (a turn) vs idle, idle ones by pin, and the RSS the idle ones hold.

    scripts/measure/idle-residents.py [--rows] [--ls FILE]
Run (any lane host): cmux-ci run --class light --measurement --label measure --script scripts/measure/idle-residents.py --ref SHA
"""
from __future__ import annotations

import argparse
import collections
from pathlib import Path
import json
import os
import subprocess
import time

WAITS = ("sleep", "tail", "timeout", "task-wait", "wait_for", "glaeda-gh", "pr-wait", "acpmux")
WRAPPERS = ("bash", "sh", "zsh", "env", "python3", "python")


def procs() -> dict[int, tuple[int, int, str, float]]:
    tick = os.sysconf("SC_CLK_TCK")
    page = os.sysconf("SC_PAGE_SIZE")
    out = {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            st = open(f"/proc/{p}/stat").read()
            f = st[st.rfind(")") + 2:].split()
            cmd = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
            out[int(p)] = (int(f[1]), int(f[21]) * page, cmd, (int(f[11]) + int(f[12])) / tick)
        except (OSError, IndexError, ValueError):
            continue
    return out


def session_of(pid: int) -> str | None:
    try:
        for kv in open(f"/proc/{pid}/environ", "rb").read().split(b"\0"):
            if kv.startswith(b"ACPMUX_SESSION_ID="):
                return kv.split(b"=", 1)[1].decode()
    except OSError:
        return None
    return None


def is_wait(cmd: str) -> bool:
    """A process that only waits: sleep, tail --pid / -f, timeout, or a waiting tool (and their shells)."""
    argv = cmd.split()
    if not argv:
        return True
    name = os.path.basename(argv[0])
    text = " ".join(argv[:6])
    if name in ("sleep", "timeout"):
        return True
    if name == "tail":
        return True
    if any(w in text for w in (" wait ", "pr-wait", "task-wait", "wait_for", "glaeda-gh wait")):
        return True
    if name in WRAPPERS:
        # A shell or python running a waiting tool is that wait (its child decides).
        return any(w in cmd for w in ("glaeda-gh wait", "task-wait", "wait_for", "pr-wait")) or argv[1:2] == ["-c"]
    return False


def is_mcp(cmd: str) -> bool:
    return "mcp" in cmd.lower() or "code-mode-host" in cmd


def host_records(folder):
    """Read only identity fields; never emit credentials stored alongside them."""
    out = {}
    for path in Path(folder).glob("*.json"):
        try:
            record = json.loads(path.read_text())
            host = record.get("host_pid")
            if isinstance(host, int):
                out[host] = {k: record.get(k) for k in ("session_id", "harness_pid")}
        except (OSError, ValueError, AttributeError):
            continue
    return out


def process_rows(table, sessions, records, now, identify=session_of):
    kids = collections.defaultdict(list)
    for pid, info in table.items():
        kids[info[0]].append(pid)
    rows, counted = [], set()
    for host, info in table.items():
        if "__agent-host" not in info[2]:
            continue
        record = records.get(host, {})
        harness = list(kids[host])
        recorded = record.get("harness_pid")
        sid = identify(host) or next((sid for sid in map(identify, harness) if sid), None)
        # Custody leaves the harness orphaned. Match its session identity before trusting a PID
        # from disk, which could have been reused since a stale record was written.
        if (recorded in table and record.get("session_id")
                and identify(recorded) == record["session_id"]
                and (sid is None or sid == record["session_id"])):
            if recorded not in harness:
                harness.append(recorded)
            sid = sid or record["session_id"]
        tree, stack = set(), [host] + harness
        while stack:
            pid = stack.pop()
            if pid in tree or pid in counted or pid not in table:
                continue
            tree.add(pid)
            stack.extend(kids[pid])
        if not tree:
            continue
        counted.update(tree)
        session = sessions.get(sid or "", {})
        below = {pid for pid in tree if table[pid][0] in harness}
        extra = tree - set(harness) - {host}
        non_mcp = [pid for pid in extra if not is_mcp(table[pid][2]) and not any(
            is_mcp(table[parent][2]) for parent in ancestors(pid, table, host)
            if parent in tree and parent not in harness)]
        pin = "none" if not non_mcp else "wait" if all(is_wait(table[pid][2]) for pid in non_mcp) else "work"
        ended = (session.get("lastTurn") or {}).get("endedAt")
        status = session.get("status") or "?"
        rows.append({
            "session": sid, "name": session.get("name"), "status": status, "harness": session.get("harness"),
            "idle_s": None if status == "running" or not ended else round((now - ended) / 1000),
            "rss_mb": round(sum(table[pid][1] for pid in tree) / 1e6),
            "cpu_s": round(sum(table[pid][3] for pid in tree), 1),
            "procs": len(tree), "pin": pin, "below": len(below),
        })
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", action="store_true")
    ap.add_argument("--ls", help="a saved `acpmux ls --json` instead of asking the daemon")
    ap.add_argument("--hosts-dir", default=os.path.join(os.environ.get("ACPMUX_HOME", os.path.expanduser("~/.acpmux")), "hosts"),
                    help="agent-host record directory for custody-recovered harness PIDs")
    a = ap.parse_args()
    raw = open(a.ls).read() if a.ls else subprocess.run(
        ["acpmux", "ls", "--json", "--machine", "local"], capture_output=True, text=True, timeout=120).stdout
    sessions = {}
    for s in json.loads(raw).get("sessions") or []:
        sid = (s.get("qualifiedSessionId") or "").split("/")[-1] or s.get("sessionId")
        sessions[sid] = s
    now = time.time() * 1000
    table = procs()
    rows = process_rows(table, sessions, host_records(a.hosts_dir), now)
    if a.rows:
        for r in sorted(rows, key=lambda r: (r["status"], -(r["idle_s"] or 0))):
            print(json.dumps(r))
    busy = [r for r in rows if r["status"] == "running"]
    idle = [r for r in rows if r["status"] != "running"]
    pins = collections.Counter(r["pin"] for r in idle if (r["idle_s"] or 0) > 150)
    summary = {
        "host": os.uname().nodename.split(".")[0],
        "records_not_closed": sum(1 for s in sessions.values() if s.get("status") != "closed"),
        "acpmux_ready_running": sum(1 for s in sessions.values() if s.get("status") in ("ready", "running", "waiting")),
        "resident": len(rows), "resident_rss_gb": round(sum(r["rss_mb"] for r in rows) / 1e3, 2),
        "busy": len(busy), "busy_rss_gb": round(sum(r["rss_mb"] for r in busy) / 1e3, 2),
        "idle": len(idle), "idle_rss_gb": round(sum(r["rss_mb"] for r in idle) / 1e3, 2),
        "idle_past_period_by_pin": dict(pins),
        "idle_past_period_rss_gb_by_pin": {k: round(sum(r["rss_mb"] for r in idle if r["pin"] == k and (r["idle_s"] or 0) > 150) / 1e3, 2) for k in pins},
        "median_tree_mb": sorted(r["rss_mb"] for r in rows)[len(rows) // 2] if rows else None,
    }
    print(json.dumps(summary))
    return 0


def ancestors(pid: int, table: dict, stop: int):
    seen = 0
    while pid in table and pid != stop and seen < 64:
        pid = table[pid][0]
        seen += 1
        if pid == stop:
            return
        yield pid


if __name__ == "__main__":
    raise SystemExit(main())
