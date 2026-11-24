#!/usr/bin/env python3
"""The budget of every producer, read from the perf cron's state: "Budget: N over, N not measured".

The table is scripts/cmux-next/perf-budget-table.tsv (one row a budget: a producer, a limit, the cron rows that measure
it, the harness). perf-cron.py's report prints the summary line and each row that is over or not measured, and the
regression issue's body carries the same table. Nothing here fails a check or a tick: a budget row is a number to know,
the regression rule of perf-cron.py stays the only verdict (Lawrence 2026-10-23: no gate).

A row's value is the worst (largest) newest value of the cron rows its regex matches (row names with the host left off,
"panes.split.4x2.frame@cmux20-bench" is "panes.split.4x2.frame"), on any host. A row with no regex, no matching value,
or only values older than its max_age_h is NOT MEASURED: never a pass (the rule of the frame-pipeline lab's budget gate,
its scripts/budget-remote.sh: "a number could not be measured" is its own count).

The newest value of a cron row comes from the state the cron already keeps, one entry a row (so the cost does not grow
with the number of measurements or the history): state['part_rows'] (every stored tip part, any verdict), the last
measurement's rows, the open regressions, the unconfirmed and pending rows, and the row's newest good value in
row_history; the newest by time wins.

Usage: perf-budget-table.py STATE.json [--table TSV] [--now ISO]   (prints the report; for a hand check)
Tests: scripts/cmux-next/tests/test_perf_budget_table.py
"""
import datetime, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "perf-budget-table.tsv")
COLUMNS = ("name", "producer", "most", "unit", "rows", "max_age_h", "harness", "what")
HOST_SEP = "@"


def load_table(path=TABLE):
    """The budget rows (a list of dicts with COLUMNS; most and max_age_h as floats, rows a compiled regex or None).
    A malformed line raises ValueError: a table that does not parse is a bug of the table, not a row to skip."""
    rows, names = [], set()
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) != len(COLUMNS):
                raise ValueError(f"{path}:{n}: {len(cells)} cells, want {len(COLUMNS)}")
            row = dict(zip(COLUMNS, cells))
            if row["name"] in names:
                raise ValueError(f"{path}:{n}: {row['name']} twice")
            names.add(row["name"])
            row["most"] = float(row["most"])
            row["max_age_h"] = float(row["max_age_h"])
            row["rows"] = re.compile(row["rows"]) if row["rows"] else None
            rows.append(row)
    return rows


def _time(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def newest_values(state):
    """{cron row name (row@host): {'value', 'at', 'sha', 'unit'}}: each row's newest value in the state (pure)."""
    out = {}

    def offer(name, value, at, sha=None, unit=None):
        t = _time(at)
        if not isinstance(name, str) or not isinstance(value, (int, float)) or isinstance(value, bool) or t is None:
            return
        old = out.get(name)
        if old is None or t >= old["t"]:
            out[name] = {"value": value, "at": at, "t": t, "sha": sha, "unit": unit or (old or {}).get("unit")}

    hist = state.get("row_history") if isinstance(state.get("row_history"), dict) else {}
    for name, entries in hist.items():
        last = next((e for e in reversed(entries or []) if isinstance(e, dict)), None) if isinstance(entries, list) else None
        if last:
            offer(name, last.get("p95"), last.get("at"), last.get("sha"))
    last = state.get("last") if isinstance(state.get("last"), dict) else {}
    for name, r in (last.get("rows") or {}).items():
        if isinstance(r, dict):
            offer(name, r.get("p95"), last.get("measured_at"), last.get("sha"), r.get("unit"))
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else {}
    for name, p in pending.items():
        values = [v for v in (p or {}).get("values") or [] if isinstance(v, dict)] if isinstance(p, dict) else []
        if values:
            offer(name, values[-1].get("p95"), values[-1].get("at"), values[-1].get("sha"))
    for u in state.get("unconfirmed") or []:
        if isinstance(u, dict):
            offer(u.get("name"), u.get("p95"), u.get("at"), u.get("sha"), u.get("unit"))
    last_rows = last.get("rows") or {}
    for r in state.get("regressions") or []:
        if not isinstance(r, dict):
            continue
        # A regression's p95 is its newest judged value: the last measurement's when it measured the row, else the
        # first bad one's.
        first = r.get("first_bad") if isinstance(r.get("first_bad"), dict) else {}
        when, sha = (last.get("measured_at"), last.get("sha")) if r.get("name") in last_rows else (first.get("measured_at"), first.get("sha"))
        offer(r.get("name"), r.get("p95"), when, sha, r.get("unit"))
    part_rows = state.get("part_rows") if isinstance(state.get("part_rows"), dict) else {}
    for name, r in part_rows.items():
        if isinstance(r, dict):
            offer(name, r.get("p95"), r.get("at"), r.get("sha"), r.get("unit"))
    return out


def evaluate(table, state, now):
    """{'over': n, 'not_measured': n, 'rows': [...]} (pure). Each row: the table row's fields, 'value' (None: not
    measured), 'state' ('ok', 'over', 'not measured'), 'why' (for a row not measured), 'worst' (the cron row of the
    value), 'at', 'sha', 'matched' (cron rows that matched, any age)."""
    values = newest_values(state)
    by_base = {}
    for name, v in values.items():
        by_base.setdefault(name.split(HOST_SEP, 1)[0], []).append((name, v))
    out = []
    for b in table:
        entry = {k: b[k] for k in ("name", "producer", "most", "unit", "harness", "what", "max_age_h")}
        entry.update(value=None, worst=None, at=None, sha=None, matched=0)
        if b["rows"] is None:
            entry.update(state="not measured", why="no harness feeds the perf cron")
            out.append(entry)
            continue
        matched = [nv for base, nvs in by_base.items() if b["rows"].fullmatch(base) for nv in nvs]
        entry["matched"] = len(matched)
        fresh = [(n, v) for n, v in matched if (now - v["t"]).total_seconds() <= b["max_age_h"] * 3600]
        if not fresh:
            if matched:
                newest = max(v["at"] for _, v in matched)
                entry.update(state="not measured", why=f"no value in {b['max_age_h']:g} h (newest {newest})")
            else:
                entry.update(state="not measured", why="the cron has no row it matches")
            out.append(entry)
            continue
        name, v = max(fresh, key=lambda nv: (nv[1]["value"], nv[0]))
        entry.update(value=v["value"], worst=name, at=v["at"], sha=v["sha"],
                     state="over" if v["value"] > b["most"] else "ok")
        out.append(entry)
    return {"over": sum(e["state"] == "over" for e in out),
            "not_measured": sum(e["state"] == "not measured" for e in out), "rows": out}


def fmt(x):
    if not isinstance(x, (int, float)):
        return "-"
    return f"{x:.4g}" if abs(x) < 1000 else f"{x:.0f}"


def summary_line(result):
    return f"Budget: {result['over']} over, {result['not_measured']} not measured ({len(result['rows'])} rows)"


def text_lines(result):
    """The summary, then one line for each row that is over or not measured (the run's log and step summary)."""
    lines = [summary_line(result)]
    for e in result["rows"]:
        if e["state"] == "over":
            lines.append(f"OVER {e['name']} ({e['producer']}): {fmt(e['value'])} {e['unit']} of {fmt(e['most'])} "
                         f"({e['worst']} at {str(e['sha'] or '?')[:12]})")
        elif e["state"] == "not measured":
            lines.append(f"NOT MEASURED {e['name']} ({e['producer']}, limit {fmt(e['most'])} {e['unit']}): {e['why']}; "
                         f"harness: {e['harness']}")
    return lines


def issue_lines(result):
    """The issue body's section: the summary, a table of the rows over or not measured, and every row folded."""
    cell = lambda s: str(s).replace("|", "\\|")
    lines = [f"**{summary_line(result)}.** The budget of each producer (scripts/cmux-next/perf-budget-table.tsv): a row "
             "with no value is not measured, never a pass; the target is 0 over, 0 not measured. A budget row is "
             "reported, not judged: only the regression rule above opens a regression."]
    bad = [e for e in result["rows"] if e["state"] != "ok"]
    if bad:
        lines += ["", "| budget | producer | now | limit | state | worst row, or why | harness |", "|---|---|---|---|---|---|---|"]
        for e in bad:
            lines.append(f"| {e['name']} | {e['producer']} | {fmt(e['value'])} {e['unit'] if e['value'] is not None else ''} | "
                         f"{fmt(e['most'])} {e['unit']} | {e['state']} | {cell(e['worst'] or e['why'])} | {cell(e['harness'])} |")
    ok = [e for e in result["rows"] if e["state"] == "ok"]
    if ok:
        lines += ["", f"<details><summary>{len(ok)} budget row(s) within their limit</summary>", "",
                  "| budget | producer | now | limit | worst row |", "|---|---|---|---|---|"]
        lines += [f"| {e['name']} | {e['producer']} | {fmt(e['value'])} {e['unit']} | {fmt(e['most'])} {e['unit']} | {cell(e['worst'])} |"
                  for e in ok]
        lines += ["", "</details>"]
    return lines


def main(argv):
    import argparse, json
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("state")
    ap.add_argument("--table", default=TABLE)
    ap.add_argument("--now", help="ISO time (default: now)")
    o = ap.parse_args(argv)
    now = _time(o.now) if o.now else datetime.datetime.now(datetime.timezone.utc)
    with open(o.state) as f:
        state = json.load(f)
    for line in text_lines(evaluate(load_table(o.table), state, now)):
        print(line)


if __name__ == "__main__":
    main(sys.argv[1:])
