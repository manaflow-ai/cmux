"""The screen-share probe of the shared budget gate (design: cmuxterm-hq
docs/design/screen-share-under-100ms.md, piece 6, decision D8): every stage's p50 against its budget
in "Budget per stage"; a stage over budget fails the run and names the stage.

SOURCE is either the eval's results.json (schema cmux.screen-stream-eval/1; the rd target is
judged) or a budget record (schema cmux.screen-share-budget/1, the {"budget": ...} line that
cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py writes with --out, or a target in
results.json that carries one under "budget"). A budget record is judged as it is; results.json
is mapped onto the stages first (below).

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

MARKERS read the eval step's log (the cmux-ci client's lines and the eval script's
SCREEN-STREAM-EVAL-* lines), so a run that ends early names the last stage it reached.
"""
from __future__ import annotations

import json
from pathlib import Path

NAME = "screen-share"
SCHEMA = "cmux.screen-share-budget-gate/1"  # cmuxterm-hq tools/fleet-reconcilers/screen_share_fast_receipt.py
TITLE = "Screen share budget gate"
ERROR_TITLE = "screen share budget"
BUDGET_SCHEMA = "cmux.screen-share-budget/1"
RESULTS_SCHEMA = "cmux.screen-stream-eval/1"
# "Budget per stage", p50 on a 60 Hz LAN pair (ms). screen-share-vs.py's BUDGET_ROWS carry the
# same numbers; screen-stream-eval/test_budget_gate.py keeps the two equal.
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

# (regex, kind, stage): the eval step's log lines, in the order a run reaches them. A kind repeats
# in place (the queue wait's minutes), so the record keeps one row per stage.
MARKERS = (
    (r"^cmux-ci: step ([0-9a-f]{24}) \(", "submitted", "submitted to the fleet (step {0})"),
    (r"^cmux-ci: step [0-9a-f]{24} still queued after (\d+) min", "queued", "queued in the fleet {0} min"),
    (r"^ci-step source", "on-worker", "taken by a worker (source fetched)"),
    (r'^SCREEN-STREAM-EVAL-MACHINE .*"host": "([^"]+)"', "machine", "eval started on {0}"),
    (r"^SCREEN-STREAM-EVAL-STAGE (.+)$", None, "eval stage {0}"),
    (r"^SCREEN-STREAM-EVAL-TARGET (\S+) ", None, "target {0} reported"),
    (r"^ci-step \S+ exited (\d+)", "exited", "fleet step exited {0}"),
    (r"^cmux-ci: step [0-9a-f]{24} failed on (\S+): (.*)$", "exited", "fleet step failed on {0}: {1}"),
)


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


def _records(path):
    text = Path(path).read_text().strip()
    try:
        return [json.loads(text) if text else None]
    except ValueError:
        out = []
        for line in text.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out


def load_source(path):
    """[(stage names, cell)] and a label from SOURCE (results.json, a budget record, or a
    screen-share-vs.py --out JSON lines file whose last budget line counts)."""
    for rec in reversed(_records(path)):
        if not isinstance(rec, dict):
            continue
        if rec.get("schema") == RESULTS_SCHEMA:
            run = rec.get("run") or {}
            return stages_from_results(rec), f"{run.get('link') or '?'} @ {str(run.get('rev') or '?')[:12]}"
        budget = rec.get("budget") if isinstance(rec.get("budget"), dict) else rec
        if budget.get("schema") == BUDGET_SCHEMA:
            return stages_from_budget(budget), f"{budget.get('label') or ''} @ {str(budget.get('rev') or '?')[:12]}"
    raise NothingToJudge(f"{path}: neither {RESULTS_SCHEMA} nor {BUDGET_SCHEMA}")


def suspect(path):
    """The commit a failing run measured (results.json's run.rev, or a budget record's rev): the first commit to
    bisect from. None when the source names none."""
    for rec in reversed(_records(path)):
        if not isinstance(rec, dict):
            continue
        rev = (rec.get("run") or {}).get("rev") if rec.get("schema") == RESULTS_SCHEMA else (
            (rec.get("budget") if isinstance(rec.get("budget"), dict) else rec).get("rev"))
        if isinstance(rev, str) and rev:
            return {"sha": rev[:40], "why": "the commit this run measured"}
    return None
