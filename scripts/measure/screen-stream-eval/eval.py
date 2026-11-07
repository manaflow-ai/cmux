#!/usr/bin/env python3
"""The screen stream eval's results: one target's files into the stable schema, and the run's
summary.md with each number's change against an earlier run's results.json.

  eval.py target NAME DIR OUT.json      DIR holds what the harness and the target wrote
  eval.py empty ERROR...                a schema-complete target that measured nothing
  eval.py summary RESULTS.json OUT.md [--previous EARLIER.json]

Schema (SCHEMA below; README.md): results.json is
  {"schema", "run": {...}, "scenarios": [...], "targets": {NAME: TARGET}}
and each TARGET is
  {"ok", "errors": [...],
   "latency": {"key"|"pointer": {"p50_ms", "p95_ms", "n", "lost"}},
   "kbps": {"idle"|"typing"|"scroll": number}, "fps": {same},
   "ocr": {"cer", "host_cer_vs_truth", "viewer_cer_vs_truth", ...},
   "split": {"key"|"pointer": {"encode_ms", "transport_ms", "decode_ms", "input_to_capture_ms", "method",
                                [rd: "input_to_capture_parts": {"render_ms"|"sck_ms"|"pickup_ms"|"gate_ms"|"encode_ms": {"n", "p50", "p95"}}]},
             "typing": {"encode_ms", "decode_ms"}},
   "extra": {..., "repeats": [{"repeat", "kbps", "fps", "ocr_cer", ...}]}}
The window and OCR scenarios run several times (the harness's repeats=, 3 by default): each of
their numbers is the median of the repeats that measured it, and extra.repeats keeps every repeat's
own. Latency runs once: its p50 and p95 are already over SAMPLES inputs.
A number nobody could measure is null, never left out, so two runs always line up key by key.
New fields may be added; a field is never renamed or given another meaning without a new SCHEMA.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

SCHEMA = "cmux.screen-stream-eval/1"
SCENARIOS = ["idle", "typing", "scroll", "ocr"]
WINDOW_PHASES = ["idle", "typing", "scroll"]
# Seconds dropped at the start of each phase, so one phase's tail does not count in the next.
PHASE_GUARD_MS = 1000


def load(path: Path):
    try:
        text = path.read_text().strip()
        return json.loads(text) if text else None
    except (OSError, ValueError):
        return None


def phase_numbers(series: list[dict], phases: dict[str, dict]) -> tuple[dict, dict, dict, dict]:
    kbps, fps, encode, decode = {}, {}, {}, {}
    for name in WINDOW_PHASES:
        span = phases.get(name)
        rows = [] if not span else [s for s in series if span["start_unix_ms"] + PHASE_GUARD_MS < s["unix_ms"] <= span["end_unix_ms"]]
        if not rows:
            kbps[name] = fps[name] = encode[name] = decode[name] = None
            continue
        kbps[name] = round(sum(s["bytes"] for s in rows) * 8 / 1000 / len(rows), 1)
        fps[name] = round(sum(s["frames"] for s in rows) / len(rows), 1)
        enc = [s["encode_ms"] for s in rows if isinstance(s.get("encode_ms"), (int, float))]
        dec = [s["decode_ms"] for s in rows if isinstance(s.get("decode_ms"), (int, float))]
        encode[name] = round(statistics.median(enc), 2) if enc else None
        decode[name] = round(statistics.median(dec), 2) if dec else None
    return kbps, fps, encode, decode


OCR_FIELDS = ["cer", "host_cer_vs_truth", "viewer_cer_vs_truth", "host_chars", "viewer_chars", "truth_chars", "host_image", "viewer_image"]


def empty_target(errors: list[str]) -> dict:
    """A target with every schema field present and null: what a run that measured nothing reports."""
    return {
        "ok": False, "errors": errors,
        "latency": {k: {"p50_ms": None, "p95_ms": None, "n": None, "lost": None} for k in ("key", "pointer")},
        "kbps": dict.fromkeys(WINDOW_PHASES), "fps": dict.fromkeys(WINDOW_PHASES),
        "ocr": dict.fromkeys(OCR_FIELDS),
        "split": {**{k: {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None, "decode_ms": None, "method": None}
                     for k in ("key", "pointer")}, "typing": {"encode_ms": None, "decode_ms": None}},
        "extra": {},
    }


def target(name: str, folder: Path, out: Path) -> None:
    errors = [line for line in (folder / "errors.txt").read_text().splitlines() if line] if (folder / "errors.txt").exists() else []
    result: dict = {"ok": False, "errors": errors, "latency": {}, "kbps": {}, "fps": {}, "ocr": {}, "split": {}, "extra": {}}
    for kind in ("key", "pointer"):
        lat = load(folder / f"latency-{kind}.json") or {}
        g2g = lat.get("g2g_ms") or {}
        result["latency"][kind] = {"p50_ms": g2g.get("p50"), "p95_ms": g2g.get("p95"), "n": g2g.get("n"), "lost": lat.get("lost")}
        split = lat.get("split") or {}
        result["split"][kind] = {k: split.get(k) for k in ("input_to_capture_ms", "encode_ms", "transport_ms", "decode_ms", "method")}
        if split.get("input_to_capture_parts"):
            result["split"][kind]["input_to_capture_parts"] = split["input_to_capture_parts"]
        if g2g.get("p50") is None:
            errors.append(f"latency {kind}: no samples")
    # Repeats (window-N.json, phases-N.jsonl, ocr-N.json): every number is the median of the repeats
    # that measured it, and extra.repeats keeps each repeat's own numbers.
    reps = sorted(int(f.stem.split("-")[1]) for f in folder.glob("window-*.json") if f.stem.split("-")[1].isdigit())
    reps = sorted(set(reps) | {int(f.stem.split("-")[1]) for f in folder.glob("ocr-*.json") if f.stem.split("-")[1].isdigit()})
    per_rep, ocrs, extras = [], [], []
    for rep in reps:
        window = load(folder / f"window-{rep}.json") or {}
        phases = {}
        if (folder / f"phases-{rep}.jsonl").exists():
            for line in (folder / f"phases-{rep}.jsonl").read_text().splitlines():
                if line.strip():
                    row = json.loads(line)
                    phases[row["phase"]] = row
        kbps, fps, encode, decode = phase_numbers(window.get("series") or [], phases)
        ocr = load(folder / f"ocr-{rep}.json")
        if None in kbps.values():
            errors.append(f"window {rep}: no numbers for {[k for k, v in kbps.items() if v is None]} (phases logged: {sorted(phases)})")
        if ocr is None:
            errors.append(f"ocr {rep}: no result")
        else:
            ocrs.append(ocr)
        extras.append(window.get("extra") or {})
        per_rep.append({"repeat": rep, "kbps": kbps, "fps": fps, "typing_encode_ms": encode.get("typing"),
                        "typing_decode_ms": decode.get("typing"), "ocr_cer": (ocr or {}).get("cer"),
                        "ocr": {k: (ocr or {}).get(k) for k in OCR_FIELDS},
                        **{f"window_{k}": v for k, v in (window.get("extra") or {}).items()}})
    if not reps:
        errors.append("window: no repeat ran")

    def median_of(values):
        values = [v for v in values if isinstance(v, (int, float))]
        return round(statistics.median(values), 4) if values else None

    result["kbps"] = {k: median_of(r["kbps"][k] for r in per_rep) for k in WINDOW_PHASES}
    result["fps"] = {k: median_of(r["fps"][k] for r in per_rep) for k in WINDOW_PHASES}
    result["split"]["typing"] = {"encode_ms": median_of(r["typing_encode_ms"] for r in per_rep),
                                 "decode_ms": median_of(r["typing_decode_ms"] for r in per_rep)}
    # OCR: each numeric field's median over the repeats that measured it (extra.repeats keeps each
    # repeat's); the image names, which have no median, are the median-CER repeat's.
    result["ocr"] = dict.fromkeys(OCR_FIELDS)
    if ocrs:
        # Among the repeats that measured a CER (any repeat when none did), so the images never
        # come from a repeat with no measurement while others have one.
        measured = [o for o in ocrs if isinstance(o.get("cer"), (int, float))] or ocrs
        middle = sorted(measured, key=lambda o: o.get("cer") if isinstance(o.get("cer"), (int, float)) else 0)[(len(measured) - 1) // 2]
        for k in OCR_FIELDS:
            if any(isinstance(o.get(k), (int, float)) for o in ocrs):
                result["ocr"][k] = median_of(o.get(k) for o in ocrs)
            else:
                result["ocr"][k] = middle.get(k)
    else:
        errors.append("ocr: no result")
    result["extra"] = {**(extras[0] if extras else {}), "repeats": per_rep}
    result["ok"] = not errors
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


def fmt(value, unit: str = "", digits: int = 1) -> str:
    if value is None:
        return "–"
    if unit == "%":
        return f"{value * 100:.{digits}f} %"
    return f"{value:.{digits}f}{unit}"


def delta(now, before, unit: str = "", digits: int = 1) -> str:
    if now is None or before is None:
        return ""
    change = (now - before) * (100 if unit == "%" else 1)
    if round(change, digits) == 0:
        return " (=)"
    return f" ({change:+.{digits}f})"


def summary(results_path: Path, out: Path, previous_path: Path | None) -> None:
    results = json.loads(results_path.read_text())
    previous = load(previous_path) if previous_path else None
    if previous and previous.get("schema") != results.get("schema"):
        previous = None
    run = results.get("run", {})
    lines = [f"# Screen stream eval, {run.get('at', '?')}", ""]
    lines.append(f"Host {run.get('host', '?')} ({run.get('cpu', '?')}, macOS {run.get('macos', '?')}), display {run.get('display', '?')}, "
                 f"link {run.get('link', '?')}, rev `{str(run.get('rev', '?'))[:12]}`"
                 + (", rd host `--input-frame-now 1`" if run.get("rd_input_frame_now") == "1" else "") + ".")
    if previous:
        prev_run = previous.get("run", {})
        lines.append(f"Changes in brackets are against {prev_run.get('at', '?')} (rev `{str(prev_run.get('rev', '?'))[:12]}`).")
    else:
        lines.append("No earlier run to compare against.")
    if run.get("blocked"):
        lines += ["", f"**Not measured:** {run['blocked']}"]
    for name, t in results.get("targets", {}).items():
        p = ((previous or {}).get("targets") or {}).get(name) or {}

        def get(obj, *keys):
            for k in keys:
                obj = (obj or {}).get(k)
            return obj

        def cell(*keys, unit=" ms", digits=1):
            now = get(t, *keys)
            return fmt(now, unit, digits) + delta(now, get(p, *keys), unit, digits)

        lines += ["", f"## {name}" + ("" if t.get("ok") else " (incomplete)"), ""]
        lines += ["| Measure | Value |", "| --- | --- |"]
        for kind, label in (("key", "Key"), ("pointer", "Pointer (click)")):
            lines.append(f"| {label} glass-to-glass p50 / p95 | {cell('latency', kind, 'p50_ms')} / {cell('latency', kind, 'p95_ms')}"
                         f" (n {get(t, 'latency', kind, 'n') or 0}, lost {get(t, 'latency', kind, 'lost') or 0}) |")
        for phase, label in (("idle", "idle 30 s"), ("typing", "typing burst"), ("scroll", "scrolling 5k lines")):
            lines.append(f"| kbps, {label} | {cell('kbps', phase, unit='', digits=0)} at {cell('fps', phase, unit=' fps')} |")
        lines.append(f"| Text OCR error (13 pt code, viewer vs host screenshot) | {cell('ocr', 'cer', unit='%', digits=2)}"
                     f" (host OCR vs drawn text {fmt(get(t, 'ocr', 'host_cer_vs_truth'), '%', 2)}) |")
        for kind in ("key", "pointer"):
            lines.append(f"| {kind.capitalize()} split: input→capture / encode / transport / decode | "
                         f"{cell('split', kind, 'input_to_capture_ms')} / {cell('split', kind, 'encode_ms', digits=2)} / "
                         f"{cell('split', kind, 'transport_ms', digits=2)} / {cell('split', kind, 'decode_ms', digits=2)} |")
        for kind in ("key", "pointer"):
            parts = get(t, "split", kind, "input_to_capture_parts") or {}
            if parts:
                lines.append(f"| {kind.capitalize()} input→capture parts (p50): render / SCK / pickup / gate | "
                             + " / ".join(fmt((parts.get(k) or {}).get("p50"), " ms", 2) for k in ("render_ms", "sck_ms", "pickup_ms", "gate_ms")) + " |")
        lines.append(f"| Typing split: encode / decode | {cell('split', 'typing', 'encode_ms', digits=2)} / {cell('split', 'typing', 'decode_ms', digits=2)} |")
        reps = (t.get("extra") or {}).get("repeats") or []
        if len(reps) > 1:
            lines += ["", f"Medians of {len(reps)} window and OCR repeats. Each repeat: OCR error "
                      + " / ".join(fmt(r.get("ocr_cer"), "%", 2) for r in reps)
                      + "; kbps idle / typing / scroll "
                      + ", ".join("/".join(fmt((r.get("kbps") or {}).get(k), "", 0) for k in WINDOW_PHASES) for r in reps) + "."]
        method = get(t, "split", "key", "method")
        if method:
            lines += ["", f"Split method ({name}): {method}. Transport is not comparable across targets."]
        for error in t.get("errors") or []:
            lines.append(f"- {error}")
    out.write_text("\n".join(lines) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "target":
        target(argv[1], Path(argv[2]), Path(argv[3]))
        return 0
    if len(argv) >= 2 and argv[0] == "empty":
        print(json.dumps(empty_target(argv[1:])))
        return 0
    if len(argv) in (3, 5) and argv[0] == "summary":
        previous = Path(argv[4]) if len(argv) == 5 and argv[3] == "--previous" else None
        summary(Path(argv[1]), Path(argv[2]), previous)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
