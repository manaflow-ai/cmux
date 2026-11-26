#!/usr/bin/env python3
"""The nightly budget gate (design: cmuxterm-hq docs/design/screen-share-under-100ms.md, piece 6,
decision D8): every stage's p50 against its budget in "Budget per stage"; a stage over budget
fails the run and names the stage.

  budget_gate.py check SOURCE [--out BUDGET.json] [--summary FILE] [--budget STAGE=MS ...]

SOURCE is either the eval's results.json (schema cmux.screen-stream-eval/1; the rd target is
judged) or a budget record (schema cmux.screen-share-budget/1, the {"budget": ...} line that
cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py writes with --out, or a target in
results.json that carries one under "budget"). A budget record is judged as it is; results.json
is mapped onto the stages first (below). --out writes the judged record, --summary appends the
table as markdown (the job summary), and each stage over budget prints a GitHub ::error line
naming it.

Exit status: 0 when every measured stage is within its budget, 1 when one or more is over (each
is named), 2 when nothing could be judged (no rd target, no stage measured): a gate that
measured nothing never passes.

--budget STAGE=MS replaces one stage's budget for this run (repeatable; a stage name as in the
table, case-insensitive). It exists for proving the gate end to end on the real pipeline (one
deliberately tight budget fails the run and names that stage); the nightly passes none.

From results.json, until the per-frame stage ledger (cmux.rd-stage-ledger/1) is in the rd
target, the stages read the rd target's key split (targets/rd.sh, the host's timing log joined
with the bench), each a p50 on the host's clock:

  Input       null: not split out of the key press's time
  Screen      render (input injected -> the display showed it)
  Capture     sck + pickup + gate (display -> encode start; a sum of medians)
  Encode      the host timing log's encode
  Send + Network + Reassembly   transport (capture-to-decoded minus encode and decode): one
              number for the three stages, judged against the sum of their budgets
  Decode      the viewer's decode
  Present     null: the bench viewer has no window
  Total       the key press's glass-to-glass p50 (to the decoded frame, not the presented one)

A null stage is listed as not measured; it neither passes nor fails the run.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

BUDGET_SCHEMA = "cmux.screen-share-budget/1"
RESULTS_SCHEMA = "cmux.screen-stream-eval/1"
# "Budget per stage", p50 on a 60 Hz LAN pair (ms). screen-share-vs.py's BUDGET_ROWS carry the
# same numbers; test_budget_gate.py keeps the two equal.
BUDGETS = {
    "Input": 3,
    "Screen": 12,
    "Capture": 8,
    "Encode": 8,
    "Send": 8,
    "Network": 2,
    "Reassembly": 1,
    "Decode": 5,
    "Present": 10,
    "Total": 57,
}
TRANSPORT = ("Send", "Network", "Reassembly")


class NothingToJudge(Exception):
    pass


def _p50(value):
    """A p50 from a number or a {"p50": ...} cell; None when absent."""
    if isinstance(value, dict):
        value = value.get("p50")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _cell(p50, source):
    return {"p50": round(p50, 3), "source": source} if p50 is not None else None


def stages_from_budget(record):
    """[(stage names, measured cell or None)] from a cmux.screen-share-budget/1 record."""
    out = []
    for row in record.get("rows") or []:
        cell = row.get("cmux") or {}
        p50 = None if "null" in cell else _p50(cell)
        out.append(((row.get("row"),), _cell(p50, cell.get("source") or "budget record")
                    if p50 is not None else {"null": cell.get("null") or "no value"}))
    return out


def stages_from_results(results, target_name="rd"):
    """[(stage names, cell)] from results.json's TARGET_NAME (its embedded budget record when it
    has one, else its key split)."""
    target = (results.get("targets") or {}).get(target_name)
    if not isinstance(target, dict):
        raise NothingToJudge(f"results.json has no {target_name!r} target")
    if isinstance(target.get("budget"), dict) and target["budget"].get("schema") == BUDGET_SCHEMA:
        return stages_from_budget(target["budget"])
    split = (target.get("split") or {}).get("key") or {}
    parts = split.get("input_to_capture_parts") or {}
    capture = [_p50(parts.get(k)) for k in ("sck_ms", "pickup_ms", "gate_ms")]
    encode = _p50(parts.get("encode_ms"))
    if encode is None:
        encode = _p50(split.get("encode_ms"))
    total = _p50(((target.get("latency") or {}).get("key") or {}).get("p50_ms"))
    not_split = {"null": "not split out of the key press's time until the stage ledger"}
    return [
        (("Input",), not_split),
        (("Screen",), _cell(_p50(parts.get("render_ms")), "render")),
        (("Capture",), _cell(sum(capture), "sck + pickup + gate") if None not in capture else None),
        (("Encode",), _cell(encode, "encode")),
        (TRANSPORT, _cell(_p50(split.get("transport_ms")), "transport")),
        (("Decode",), _cell(_p50(split.get("decode_ms")), "decode")),
        (("Present",), {"null": "the bench viewer has no window (it ends at decode)"}),
        (("Total",), _cell(total, "key glass to glass, to the decoded frame")),
    ]


def load_source(path):
    """[(stage names, cell)] and a label from SOURCE (results.json, a budget record, or a
    screen-share-vs.py --out JSON lines file whose last budget line counts)."""
    text = Path(path).read_text().strip()
    try:
        whole = json.loads(text) if text else None
        records = [whole]
    except ValueError:
        whole = None
        records = []
        for line in text.splitlines():
            try:
                records.append(json.loads(line))
            except ValueError:
                continue
    for rec in reversed(records):
        if not isinstance(rec, dict):
            continue
        if rec.get("schema") == RESULTS_SCHEMA:
            run = rec.get("run") or {}
            return stages_from_results(rec), f"{run.get('link') or '?'} @ {str(run.get('rev') or '?')[:12]}"
        budget = rec.get("budget") if isinstance(rec.get("budget"), dict) else rec
        if budget.get("schema") == BUDGET_SCHEMA:
            return stages_from_budget(budget), f"{budget.get('label') or ''} @ {str(budget.get('rev') or '?')[:12]}"
    raise NothingToJudge(f"{path}: neither {RESULTS_SCHEMA} nor {BUDGET_SCHEMA}")


def parse_overrides(pairs):
    out = {}
    names = {k.lower(): k for k in BUDGETS}
    for pair in pairs or []:
        name, _, ms = pair.partition("=")
        stage = names.get(name.strip().lower())
        if stage is None:
            raise SystemExit(f"--budget {pair}: no stage {name!r} (stages: {', '.join(BUDGETS)})")
        try:
            value = float(ms)
        except ValueError:
            value = math.nan
        if not math.isfinite(value) or value < 0:
            raise SystemExit(f"--budget {pair}: {ms!r} is not a number of ms")
        out[stage] = value
    return out


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


def markdown(rows, label, overrides):
    lines = [f"## Screen share budget gate ({label})", ""]
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


def cmd_check(args):
    overrides = parse_overrides(args.budget)
    budgets = dict(BUDGETS, **overrides)
    try:
        stages, label = load_source(args.source)
    except (NothingToJudge, OSError) as error:
        print(f"::error title=screen share budget::nothing judged: {error}")
        return 2
    rows = judge(stages, budgets)
    record = {"schema": "cmux.screen-share-budget-gate/1", "label": label, "budgets": budgets,
              "overrides": overrides, "rows": rows,
              "over": [r["stage"] for r in rows if r["verdict"] == "over"]}
    if args.out:
        Path(args.out).write_text(json.dumps(record, indent=2) + "\n")
    text = markdown(rows, label, overrides)
    if args.summary:
        with open(args.summary, "a") as f:
            f.write(text)
    print(text, end="")
    if not any(r["verdict"] != "not measured" for r in rows):
        print("::error title=screen share budget::nothing judged: no stage was measured")
        return 2
    for r in rows:
        if r["verdict"] == "over":
            print(f"::error title=screen share budget: {r['stage']}::{r['stage']} p50 {r['p50']:g} ms is over "
                  f"its {r['budget_ms']:g} ms budget ({r['source']})")
    return 1 if record["over"] else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check", help="judge every stage against its budget")
    check.add_argument("source")
    check.add_argument("--out")
    check.add_argument("--summary")
    check.add_argument("--budget", action="append", metavar="STAGE=MS")
    args = parser.parse_args(argv)
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())
