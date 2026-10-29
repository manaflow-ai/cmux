#!/usr/bin/env python3
"""The process-model baseline (task p01-process-005): per-role budgets and the perf-lead.md section 5 rows.

Pure, no app and no Mac. `chromium-host-bench.py --baseline` imports it to turn its result into section 5 rows;
`scripts/cmux-next/tests/chromium-host-baseline.test.sh` runs it on canned results.

  --budgets            print the per-role budget table (markdown, as in perf-lead.md section 5)
  --check PERF_LEAD    exit 1 when a budget group does not sum to its program target, or when PERF_LEAD's
                       budget table is not the one --budgets prints
  --rows RESULT...     print one section 5 row per number and session from chromium-host-bench.json results
  --date YYYY-MM-DD    the rows' date (default: today, UTC)

The targets are the done checks of plans/cmux-next/chrome-parity/p01-process.md section 5 (6, 12, 13). Each group's
parts sum exactly to its target, so a role that goes over its part shows which role broke the program row.
"""
import argparse, datetime, json, sys

# One group per program target. A part is (role, what it holds, budget, today's number and its source).
# The roles are the census roles (process-model-census.py).
BUDGETS = [
    {
        "id": "memory_per_hidden_terminal_mb",
        "title": "Memory per hidden terminal, all cmux roles, shared mappings counted once (the shell is the user's)",
        "unit": "MB", "target": 1.5, "check": "done check 13",
        "parts": [
            ("holder", "PTY master and the resident pages of its 1 MiB byte ring (one mapping, also mapped by the daemon)", 0.60,
             "terminal_host 2.1-2.5 MB footprint per host (new-terminal-100x, aws-m4pro-6)"),
            ("daemon / vt_worker", "VT state: screen, bounded scrollback, modes (vt-pool in phase A, cmux-vt-worker in phase B)", 0.55,
             "daemon about 1.5 MB per workspace, a full VT mirror (speed-of-sound-DESIGN.md gap 11)"),
            ("daemon", "model: session tree, journal entry, stream state", 0.10, "in the 1.5 MB above"),
            ("app", "app surface after the 30 s hidden grace (task 140): model, stream offset, view state; no Ghostty surface", 0.25,
             "about 3 MB, one Ghostty surface per hidden terminal (speed-of-sound-DESIGN.md gap 11)"),
        ],
    },
    {
        "id": "threads_heavy",
        "title": "Threads in the heavy session (150 workspaces, 172 terminals), cmux-owned, Chromium helpers excluded",
        "unit": "threads", "target": 400, "check": "done check 13",
        "parts": [
            ("app", "UI, render and IO threads of the visible surfaces, Chromium client", 120, "91 (p07-memory.md, cmux20)"),
            ("daemon", "O(cores) pools, mux-io, child-exit, pty-writer; peak too (agent burst, restart)", 64, "797"),
            ("holder", "one poll loop, signals, spawn", 8, "0 (holder off; 172 terminal hosts x 7-9 threads)"),
            ("vt_worker", "4 shards x 8", 32, "0 (no workers)"),
            ("chromium_host", "Chromium's browser process (UI, IO, ThreadPool, crashpad, hang watcher)", 100, "0 (in the app process)"),
            ("daemon children", "acpmux helper per chat, the remote-browser host, VS Code serve-web", 76, "not counted yet"),
        ],
    },
    {
        "id": "idle_wakes_per_s",
        "title": "Idle wakes with 10 Chromium tabs (app hidden, app visible, workspace hidden); renderers and GPU are their own row",
        "unit": "wakes/s", "target": 1.0, "check": "done check 12",
        "parts": [
            ("app", "every thread of the app process; its main thread <= 0.5 by itself", 0.5, "89/s app kernel wakeups, 1 tab (perf-lead.md 2026-10-25 PL-cefhost row)"),
            ("daemon", "all daemon threads", 0.2, "not measured"),
            ("holder", "the poll loop", 0.1, "not measured"),
            ("vt_worker", "all shards together", 0.1, "no workers"),
            ("chromium_host", "Chromium's browser process", 0.1, "in the app process (3.3/s pump wakes on main, 1 tab)"),
        ],
    },
    {
        "id": "key_to_paint_p95_delta_ms",
        "title": "Key and click to page paint, host mode minus in process, p95 (120 Hz; p50 <= 8.3 ms and p99 <= 16.7 ms hold too)",
        "unit": "ms", "target": 1.0, "check": "done check 6",
        "parts": [
            ("app", "KeyRouter decision, input ring write and doorbell on cmux's main thread", 0.2, "not measured"),
            ("wire", "doorbell to the host's UI thread dispatch (`hop_us`)", 0.6, "p95 1.96 ms (prototype, sandbox off, 2026-10-25)"),
            ("chromium_host", "host UI thread dispatch to the renderer's input queue", 0.2, "not measured"),
        ],
    },
]

PROCESS_COUNTS = [("app", 1), ("daemon", 1), ("holder", 1), ("vt_worker", "<= 4 (+1 per extra trust class)"),
                  ("terminal_host", 0), ("chromium_host", 1)]


def check_sums(budgets=BUDGETS):
    """The groups whose parts do not sum to their target: [(id, sum, target)]."""
    bad = []
    for group in budgets:
        total = round(sum(part[2] for part in group["parts"]), 6)
        if total != round(group["target"], 6):
            bad.append((group["id"], total, group["target"]))
    return bad


def number(value):
    return f"{value:g}" if isinstance(value, (int, float)) else str(value)


def budget_table(budgets=BUDGETS):
    """The markdown per-role budget table perf-lead.md section 5 holds."""
    lines = ["| Target (program check) | Role | Holds | Budget | Today |", "|---|---|---|---|---|"]
    for group in budgets:
        for index, (role, holds, budget, today) in enumerate(group["parts"]):
            head = f"{group['title']}: {number(group['target'])} {group['unit']} ({group['check']})" if index == 0 else ""
            lines.append(f"| {head} | {role} | {holds} | {number(budget)} {group['unit']} | {today} |")
    lines.append("| Processes in the heavy session (done check 13) | "
                 + ", ".join(f"{role} {number(count)}" for role, count in PROCESS_COUNTS) + " | | | 392 processes, 172 terminal hosts |")
    return "\n".join(lines)


def table_in(text):
    """The budget table in a perf-lead.md text: the lines from its header row to the first non-table line."""
    lines = text.splitlines()
    header = budget_table().splitlines()[0]
    if header not in lines:
        return None
    start = lines.index(header)
    end = start
    while end < len(lines) and lines[end].startswith("|"):
        end += 1
    return "\n".join(lines[start:end])


# ---- rows ---------------------------------------------------------------------------------------------------------

def pct(value):
    return f"{value * 100:.2f} %" if isinstance(value, (int, float)) else "n/a"


def spread(stats, unit="ms"):
    if not isinstance(stats, dict) or not stats.get("n"):
        return None
    keys = [k for k in ("p50", "p95", "p99", "max") if stats.get(k) is not None]
    return "/".join(number(stats[k]) for k in keys) + f" {unit} ({'/'.join(keys)}, n {stats['n']})"


def pump_text(share):
    if not isinstance(share, dict) or "idle" not in share:
        return None
    parts = []
    for phase in ("idle", "scroll"):
        p = share.get(phase) or {}
        wakes = p.get("wakes") or {}
        parts.append(f"{phase} {pct(p.get('share'))} of main-thread time, pump {number(wakes.get('cef_pump_per_s'))}/s "
                     f"of {number(wakes.get('ledger_per_s'))}/s ledger wakes")
    return "; ".join(parts)


SCENARIOS = (("app_visible", "app visible"), ("workspace_hidden", "workspace hidden"), ("app_hidden", "app hidden"))


def wakes_text(row):
    """An idle row of chromium-host-bench.py (idle_scenarios): its tab count, then each scenario's wakes."""
    if not isinstance(row, dict):
        return None
    if row.get("error") or not row.get("scenarios"):
        return row.get("error")
    if row.get("chromium_tabs") is not None:
        tabs = f"{row['chromium_tabs']} Chromium tabs"
    else:
        tabs = f"{row.get('browser_tabs')} browser tabs (Chromium and WebKit; the topology has no engine)"
    parts = []
    for key, label in SCENARIOS:
        scenario = row["scenarios"].get(key) or {"error": "not run"}
        wakes = scenario.get("wakes")
        if not wakes:
            parts.append(f"{label}: {scenario.get('error')}")
            continue
        kinds = ", ".join(f"{kind} {number(rate)}/s" for kind, rate in sorted((wakes.get("by_kind_per_s") or {}).items()))
        parts.append(f"{label}: app {number(wakes.get('app_wakeups_per_s'))}/s kernel wakeups, ledger "
                     f"{number(wakes.get('ledger_per_s'))}/s, pump {number(wakes.get('cef_pump_per_s'))}/s" + (f" ({kinds})" if kinds else ""))
    return (f"{tabs}, {number(row.get('settle_s'))} s settle; " + "; ".join(parts)
            + ". The ledger is the app's sanctioned wakes; macOS counts kernel wakeups per process, so the main thread's own is not split out")


def key_text(row):
    if not isinstance(row, dict):
        return None
    key, click = spread(row.get("key_to_paint_ms")), spread(row.get("click_to_paint_ms"))
    if not key and not click:
        return row.get("error")
    return f"key {key or 'n/a'}; click {click or 'n/a'}"


def stall_text(row):
    if not isinstance(row, dict):
        return None
    if row.get("error"):
        return row["error"]
    return (f"{row.get('stall_ms')} ms stall every {row.get('every_ms')} ms ({row.get('stalls')} sent): rAF interval "
            f"{spread(row.get('raf_ms')) or 'n/a'}, {row.get('long_frames')} long frames, pass {row.get('pass')}")


def census_text(row):
    if not isinstance(row, dict):
        return None
    if row.get("error"):
        return row["error"]
    report = row.get("census") or {}
    roles = report.get("roles") or {}
    memory = lambda r: (f"{number(r['unique_mb'])} MB unique" if r.get("unique_mb") is not None
                        else f"{number(r.get('rss_mb'))} MB RSS")
    parts = [f"{role} {r.get('processes')} proc / {r.get('threads')} thr (peak {r.get('peak_threads')}) / {memory(r)}"
             for role, r in roles.items() if isinstance(r, dict) and r.get("processes")]
    session = report.get("session") or {}
    return (f"{session.get('terminals')} terminals ({session.get('hidden_terminals')} hidden): "
            + ("; ".join(parts) or "no roles"))


def split_text(row):
    if not isinstance(row, dict):
        return None
    if row.get("error"):
        return row["error"]
    roles = ", ".join(f"{role} {number(mb)} MB" for role, mb in (row.get("per_role_mb") or {}).items())
    shared = row.get("shared_once_mb")
    return (f"per added hidden terminal ({row.get('terminals_added')} added), {row.get('basis')}: {roles}"
            + (f"; shared mappings (the byte ring among them), counted once, {number(shared)} MB" if shared is not None else "")
            + f". Census per hidden terminal {number(row.get('census_per_hidden_terminal_mb'))} MB "
            f"({row.get('census_per_hidden_terminal_basis')}). By process role: the census does not split the ring from "
            "the VT state or the app surface")


def memory_split(before, heavy):
    """Per-role MB per added hidden terminal, from a census of the session (`before`) and the heavy census after it,
    with the hidden terminal counts each census read (its `session`). Each role's private memory growth, plus the
    growth of the shared mappings counted once (total unique minus every role's private): they sum to the growth of
    the cmux roles' unique memory. A role's own unique_mb is not used: a mapping two roles share (the byte ring,
    holder and daemon) is in each. Without the census's region walk (no private memory) it falls back to RSS
    growth, which counts a shared mapping in every role that maps it, and says so in `basis`.
    {"per_role_mb", "shared_once_mb", "basis", "terminals_added", "census_per_hidden_terminal_mb",
    "census_per_hidden_terminal_basis"} or {"error"}."""
    for name, run in (("before heavy", before), ("heavy", heavy)):
        if not isinstance(run, dict) or run.get("error"):
            return {"error": f"census {name}: " + ((run or {}).get("error") if isinstance(run, dict) else "not run")}
    report_before, report_heavy = before.get("census") or {}, heavy.get("census") or {}
    hidden = lambda report: (report.get("session") or {}).get("hidden_terminals")
    if hidden(report_before) is None or hidden(report_heavy) is None:
        return {"error": "a census read no hidden terminal count (its session)"}
    added = hidden(report_heavy) - hidden(report_before)
    if added <= 0:
        return {"error": f"the heavy session adds no hidden terminals ({hidden(report_before)} -> {hidden(report_heavy)})"}
    roles_before, roles_heavy = report_before.get("roles") or {}, report_heavy.get("roles") or {}
    names = sorted(set(roles_before) | set(roles_heavy))
    private_known = all((roles.get(role) or {}).get("private_mb") is not None
                        for roles in (roles_before, roles_heavy) for role in names if (roles.get(role) or {}).get("processes"))
    key = "private_mb" if private_known else "rss_mb"
    value = lambda roles, role: float((roles.get(role) or {}).get(key) or 0)
    per_role = {}
    for role in names:
        grown = value(roles_heavy, role) - value(roles_before, role)
        if grown or (roles_heavy.get(role) or {}).get("processes"):
            per_role[role] = round(grown / added, 3)
    shared = None
    if private_known:
        unique = lambda report: float((report.get("totals") or {}).get("unique_mb") or 0)
        shared_of = lambda report, roles: unique(report) - sum(value(roles, role) for role in names)
        shared = round((shared_of(report_heavy, roles_heavy) - shared_of(report_before, roles_before)) / added, 3)
    return {"per_role_mb": per_role, "shared_once_mb": shared, "terminals_added": added,
            "basis": ("private memory per role, shared mappings counted once" if private_known else
                      "RSS growth per role (no private memory in the census: a shared mapping counts in every role that maps it)"),
            "census_per_hidden_terminal_mb": report_heavy.get("per_hidden_terminal_mb"),
            "census_per_hidden_terminal_basis": report_heavy.get("per_hidden_terminal_basis")}


# (row title, session, text of the result) for every number task 005 records.
def numbers(result):
    modes, sessions = result.get("modes") or {}, result.get("sessions") or {}
    inproc, helper = modes.get("inproc") or {}, modes.get("helper") or {}
    stress = sessions.get("stress") or {}
    baseline = result.get("baseline") or {}
    pump = inproc.get("pump_share") or {}
    return [
        ("in-process Chromium pump share", "light", pump_text(pump.get("light"))),
        ("in-process Chromium pump share", "STRESS", pump_text(pump.get("stress"))),
        ("idle wakes, 10 Chromium tabs", "light", wakes_text((sessions.get("light") or {}).get("tabs10"))),
        ("idle wakes, the STRESS tab mix", "STRESS", wakes_text(stress.get("idle"))),
        ("key and click to paint, in process", "light", key_text(inproc)),
        ("key and click to paint, in process", "STRESS", key_text(stress.get("inproc"))),
        ("key and click to paint, Chromium Host", "light", key_text(helper) if helper else None),
        ("key and click to paint, Chromium Host", "STRESS", key_text(stress.get("helper"))),
        ("stall 9a, in process", "light", stall_text(inproc.get("stall"))),
        ("stall 9a, in process", "STRESS", stall_text((stress.get("inproc") or {}).get("stall"))),
        ("stall 9a, Chromium Host", "light", stall_text(helper.get("stall")) if helper else None),
        ("stall 9a, Chromium Host", "STRESS", stall_text((stress.get("helper") or {}).get("stall"))),
        ("process census", "light", census_text(baseline.get("census_light"))),
        ("process census", "heavy", census_text(baseline.get("census_heavy"))),
        ("per-role memory split", "light to heavy", split_text(baseline.get("memory_split"))),
    ]


def rows(result, date):
    host = result.get("host") or {}
    where = (f"{host.get('name') or '?'}, macOS {host.get('macos') or '?'}, {number(result.get('refresh_hz') or '?')} Hz, "
             f"{result.get('build', 'Debug')}")
    sha = host.get("sha") or host.get("sha_error") or "?"
    out = []
    for title, session, text in numbers(result):
        out.append(f"| {date} | p01-process-005 baseline | {sha} | {title} ({session}) | {where}: "
                   f"{text if text else 'not measured in this run'} | - |")
    return out


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--budgets", action="store_true")
    parser.add_argument("--check")
    parser.add_argument("--rows", nargs="*")
    parser.add_argument("--date", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    opts = parser.parse_args(argv)
    status = 0
    if opts.budgets:
        print(budget_table())
    if opts.check:
        for group, total, target in check_sums():
            print(f"chromium-host-baseline: {group} parts sum to {number(total)}, not its target {number(target)}", file=sys.stderr)
            status = 1
        with open(opts.check) as source:
            found = table_in(source.read())
        if found != budget_table():
            print(f"chromium-host-baseline: the budget table in {opts.check} is not the one --budgets prints", file=sys.stderr)
            status = 1
    for path in opts.rows or []:
        with open(path) as source:
            print("\n".join(rows(json.load(source), opts.date)))
    return status


if __name__ == "__main__":
    sys.exit(main())
