#!/usr/bin/env python3
"""The shared nightly budget gate: one runner for every perf probe's stage budgets, so a run that
crashes, hangs or is killed reads as a red naming the last stage it reached, never as no value.

  budget_gate.py init --probe NAME --out GATE.json [--budget STAGE=MS ...]
  budget_gate.py mark-stage STAGE --probe NAME --out GATE.json [--kind KIND]
  budget_gate.py follow LOG --probe NAME --out GATE.json [--once] [--stop-file FILE]
  budget_gate.py check SOURCE --probe NAME [--out GATE.json] [--summary FILE] [--budget STAGE=MS ...]

`init` writes a fail-by-default record before the run starts (verdict "fail", stage "unknown",
last_stage_reached null). `mark-stage` records each stage the run reaches; `follow` does that from
a log as it grows, by the probe's MARKERS. `check` judges the finished run and overwrites the
record. A run that ends before `check` leaves the init record, so the job's artifact still holds a
gate.json, and it says fail with the last stage reached.

Exit status of check: 0 when every measured stage is within its budget, 1 when one or more is
over (each is named), 2 when nothing could be judged. The other commands exit 0 unless their
arguments are wrong: a gate that cannot write its progress never fails the run it follows.

A probe is a module in probes/ (probes/screen_share.py is the first). It supplies:
  NAME, SCHEMA (the gate record's schema), TITLE (the summary heading), optionally ERROR_TITLE
  (the ::error annotations' title), BUDGETS {stage: ms},
  load_source(path) -> ([(stage names, cell)], label), MARKERS [(regex, kind, format)], and
  optionally suspect(source_path) -> {"sha": ..., "why": ...} | None (the commit to look at when
  the run fails). A cell is {"p50": ms, "source": text}, {"null": why}, or None.
tabs-keep-speed, instant-splits and cloud-last-seen cold start add a probes/ module each.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import math
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROGRESS_MAX = 60  # stages kept in a record's progress list (the newest; the last one is what counts)


class NothingToJudge(Exception):
    pass


def load_probe(name):
    """The probe module NAME from probes/ (a dash and an underscore are the same)."""
    safe = name.replace("-", "_")
    if not re.fullmatch(r"[a-z][a-z0-9_]*", safe):
        raise SystemExit(f"--probe {name!r}: not a probe name")
    path = HERE / "probes" / f"{safe}.py"
    if not path.is_file():
        known = sorted(p.stem.replace("_", "-") for p in (HERE / "probes").glob("*.py") if not p.stem.startswith("_"))
        raise SystemExit(f"--probe {name!r}: no {path.name} in probes/ (probes: {', '.join(known)})")
    spec = importlib.util.spec_from_file_location(f"budget_gate_probe_{safe}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_record(path, record):
    """Write atomically, so a kill mid-write never leaves a torn gate.json for the upload."""
    path = Path(path)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    os.replace(tmp, path)


def read_record(path):
    try:
        record = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    return record if isinstance(record, dict) else None


def parse_overrides(pairs, budgets):
    out = {}
    names = {k.lower(): k for k in budgets}
    for pair in pairs or []:
        name, _, ms = pair.partition("=")
        stage = names.get(name.strip().lower())
        if stage is None:
            raise SystemExit(f"--budget {pair}: no stage {name!r} (stages: {', '.join(budgets)})")
        try:
            value = float(ms)
        except ValueError:
            value = math.nan
        if not math.isfinite(value) or value < 0:
            raise SystemExit(f"--budget {pair}: {ms!r} is not a number of ms")
        out[stage] = value
    return out


def pending_reason(last):
    if last is None:
        return "the run ended before it reached its first stage, and before its gate judged it"
    return f"the run ended after stage {last!r}, before its gate judged it"


def init_record(probe, overrides=None):
    """The fail-by-default record a run starts with: it stays the answer unless check replaces it."""
    overrides = overrides or {}
    return {"schema": probe.SCHEMA, "probe": probe.NAME, "label": None,
            "budgets": dict(probe.BUDGETS, **overrides), "overrides": overrides, "rows": [], "over": [],
            "verdict": "fail", "stage": "unknown", "last_stage_reached": None, "judged": False,
            "reason": pending_reason(None), "started_at": _now(), "progress": []}


def mark_stage(record, stage, kind=None, at=None):
    """Record STAGE as the last stage reached. A judged record is final and stays as it is. A stage of the
    same KIND as the last one replaces it (a queue wait's minutes), so progress stays short."""
    if not isinstance(record, dict) or record.get("judged"):
        return record
    stage = str(stage).strip()[:160]
    if not stage:
        return record
    entry = {"stage": stage, "at": at or _now()}
    if kind:
        entry["kind"] = kind
    progress = [p for p in record.get("progress") or [] if isinstance(p, dict)]
    if kind and progress and progress[-1].get("kind") == kind:
        progress[-1] = entry
    else:
        progress.append(entry)
    record["progress"] = progress[-PROGRESS_MAX:]
    record["last_stage_reached"] = stage
    record["reason"] = pending_reason(stage)
    return record


def match_markers(probe, line):
    """(stage, kind) for a log LINE the probe's MARKERS name, else None."""
    for pattern, kind, fmt in getattr(probe, "MARKERS", ()):
        m = re.search(pattern, line)
        if m:
            try:
                return fmt.format(*m.groups(), **m.groupdict()), kind
            except (IndexError, KeyError):
                return fmt, kind
    return None


def judge(stages, budgets):
    """The judged rows: [{"stage", "budget_ms", "p50", "source", "verdict"}]; verdict is
    "ok", "over" or "not measured"."""
    rows = []
    for names, cell in stages:
        name = " + ".join(names)
        budget = sum(budgets[n] for n in names if n in budgets)
        if not cell or "null" in cell:
            rows.append({"stage": name, "budget_ms": budget, "p50": None,
                         "source": (cell or {}).get("null") or "no samples", "verdict": "not measured"})
            continue
        rows.append({"stage": name, "budget_ms": budget, "p50": cell["p50"], "source": cell["source"],
                     "verdict": "over" if cell["p50"] > budget else "ok"})
    return rows


def markdown(title, rows, label, overrides):
    lines = [f"## {title} ({label})", ""]
    if overrides:
        lines.append("Budgets replaced for this run: " + ", ".join(f"{k} {v:g} ms" for k, v in overrides.items()))
        lines.append("")
    lines += ["| Stage | Budget p50 | Measured p50 | Verdict | From |", "| --- | ---: | ---: | --- | --- |"]
    for r in rows:
        measured = "–" if r["p50"] is None else f"{r['p50']:g} ms"
        verdict = {"over": "**over**", "ok": "ok"}.get(r["verdict"], r["verdict"])
        lines.append(f"| {r['stage']} | {r['budget_ms']:g} ms | {measured} | {verdict} | {r['source']} |")
    over = [r["stage"] for r in rows if r["verdict"] == "over"]
    lines += ["", f"**Over budget: {', '.join(over)}**" if over else "Every measured stage is within budget."]
    return "\n".join(lines) + "\n"


def _suspect(probe, source):
    lookup = getattr(probe, "suspect", None)
    if lookup is None:
        return None
    try:
        return lookup(source)
    except Exception:  # noqa: BLE001: a lookup that fails never changes the verdict
        return None


def check(probe, source, out=None, summary=None, overrides=None):
    """Judge SOURCE; write the judged record over OUT (keeping the progress a run's init and marks wrote)."""
    overrides = overrides or {}
    budgets = dict(probe.BUDGETS, **overrides)
    title = getattr(probe, "TITLE", f"{probe.NAME} budget gate")
    tag = getattr(probe, "ERROR_TITLE", title)  # the ::error title= annotations carry
    before = read_record(out) if out else None
    progress = (before or {}).get("progress") or []
    last = (before or {}).get("last_stage_reached")
    base = {"schema": probe.SCHEMA, "probe": probe.NAME, "budgets": budgets, "overrides": overrides,
            "started_at": (before or {}).get("started_at"), "progress": progress, "judged": True,
            "judged_at": _now()}
    try:
        stages, label = probe.load_source(source)
    except (getattr(probe, "NothingToJudge", NothingToJudge), NothingToJudge, OSError, ValueError) as error:
        print(f"::error title={tag}::nothing judged: {error}")
        if out:
            write_record(out, dict(base, label=None, rows=[], over=[], verdict="fail", stage="nothing judged",
                                   last_stage_reached=last, reason=f"nothing judged: {error}"[:300],
                                   suspect=_suspect(probe, source)))
        return 2
    rows = judge(stages, budgets)
    over = [r["stage"] for r in rows if r["verdict"] == "over"]
    measured = any(r["verdict"] != "not measured" for r in rows)
    if over:
        verdict, stage, reason = "fail", over[0], f"over budget: {', '.join(over)}"
    elif not measured:
        verdict, stage, reason = "fail", "nothing judged", "nothing judged: no stage was measured"
    else:
        verdict, stage, reason = "pass", None, "every measured stage is within its budget"
    record = dict(base, label=label, rows=rows, over=over, verdict=verdict, stage=stage,
                  last_stage_reached="judged", reason=reason,
                  suspect=_suspect(probe, source) if verdict == "fail" else None)
    if out:
        write_record(out, record)
    text = markdown(title, rows, label, overrides)
    if summary:
        with open(summary, "a") as f:
            f.write(text)
    print(text, end="")
    if not measured:
        print(f"::error title={tag}::nothing judged: no stage was measured")
        return 2
    for r in rows:
        if r["verdict"] == "over":
            print(f"::error title={tag}: {r['stage']}::{r['stage']} p50 {r['p50']:g} ms is over "
                  f"its {r['budget_ms']:g} ms budget ({r['source']})")
    return 1 if over else 0


def _mark_file(probe, out, stage, kind=None):
    try:
        record = read_record(out) or init_record(probe)
        if record.get("judged"):
            return
        write_record(out, mark_stage(record, stage, kind))
    except OSError as error:
        print(f"budget_gate: could not record stage {stage!r} in {out}: {error}", file=sys.stderr)


def follow(probe, log, out, once=False, stop_file=None, poll_s=2.0, max_s=None):
    """Read LOG as it grows; each line a MARKER names is the run's newest stage in OUT. Ends at EOF with
    --once, when STOP_FILE exists (after one last read), or after MAX_S."""
    pos, carry = 0, ""
    started = time.monotonic()
    while True:
        stopping = once or bool(stop_file and Path(stop_file).exists())
        try:
            with open(log, "r", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            chunk = ""
        if chunk:
            text = carry + chunk
            lines = text.split("\n")
            carry = lines.pop()
            if stopping and carry:
                lines.append(carry)
                carry = ""
            for line in lines:
                hit = match_markers(probe, line.rstrip("\r"))
                if hit:
                    _mark_file(probe, out, *hit)
        if stopping or (max_s is not None and time.monotonic() - started > max_s):
            return 0
        time.sleep(poll_s)


def main(argv=None, default_probe=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def probe_arg(p):
        p.add_argument("--probe", default=default_probe, required=default_probe is None)

    p_init = sub.add_parser("init", help="write the fail-by-default record a run starts with")
    probe_arg(p_init)
    p_init.add_argument("--out", required=True)
    p_init.add_argument("--budget", action="append", metavar="STAGE=MS")
    p_mark = sub.add_parser("mark-stage", help="record the last stage the run reached")
    p_mark.add_argument("stage")
    probe_arg(p_mark)
    p_mark.add_argument("--out", required=True)
    p_mark.add_argument("--kind")
    p_follow = sub.add_parser("follow", help="mark stages from a log as it grows, by the probe's markers")
    p_follow.add_argument("log")
    probe_arg(p_follow)
    p_follow.add_argument("--out", required=True)
    p_follow.add_argument("--once", action="store_true")
    p_follow.add_argument("--stop-file")
    p_follow.add_argument("--max-s", type=float)
    p_check = sub.add_parser("check", help="judge every stage against its budget")
    p_check.add_argument("source")
    probe_arg(p_check)
    p_check.add_argument("--out")
    p_check.add_argument("--summary")
    p_check.add_argument("--budget", action="append", metavar="STAGE=MS")
    args = parser.parse_args(argv)
    probe = load_probe(args.probe)
    if args.cmd == "init":
        write_record(args.out, init_record(probe, parse_overrides(args.budget, probe.BUDGETS)))
        return 0
    if args.cmd == "mark-stage":
        _mark_file(probe, args.out, args.stage, args.kind)
        return 0
    if args.cmd == "follow":
        return follow(probe, args.log, args.out, once=args.once, stop_file=args.stop_file, max_s=args.max_s)
    return check(probe, args.source, args.out, args.summary, parse_overrides(args.budget, probe.BUDGETS))


if __name__ == "__main__":
    sys.exit(main())
