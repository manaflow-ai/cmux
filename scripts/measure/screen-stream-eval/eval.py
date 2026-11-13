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
    "kbps": {"idle"|"typing"|"scroll"|"video": number}, "fps": {same},
   "ocr": {"cer", "host_cer_vs_truth", "viewer_cer_vs_truth", ...},
   "split": {"key"|"pointer": {"encode_ms", "transport_ms", "decode_ms", "input_to_capture_ms", "method",
                                [rd: "input_to_capture_parts": {"render_ms"|"sck_ms"|"pickup_ms"|"gate_ms"|"encode_ms": {"n", "p50", "p95"}}]},
             "typing": {"encode_ms", "decode_ms"}},
   "extra": {..., "first_frame_ms", "cpu_pct", "repeats": [{"repeat", "kbps", "fps", "ocr_cer", ...}]}}
The window and OCR scenarios run several times (the harness's repeats=, 3 by default): each of
their numbers is the median of the repeats that measured it, and extra.repeats keeps every repeat's
own. Latency runs once: its p50 and p95 are already over SAMPLES inputs.
A number nobody could measure is null, never left out, so two runs always line up key by key.
New fields may be added; a field is never renamed or given another meaning without a new SCHEMA.
"""

from __future__ import annotations

import json
import math
import re
import statistics
import sys
from pathlib import Path

SCHEMA = "cmux.screen-stream-eval/2"
SCENARIOS = ["idle", "typing", "scroll", "video", "ocr"]
REQUIRED_WINDOW_PHASES = ["idle", "typing", "scroll"]
WINDOW_PHASES = [*REQUIRED_WINDOW_PHASES, "video"]
# Seconds dropped at the start of each phase, so one phase's tail does not count in the next.
PHASE_GUARD_MS = 1000


def load(path: Path):
    try:
        text = path.read_text().strip()
        return json.loads(text) if text else None
    except (OSError, ValueError):
        return None


def phase_numbers(series: list[dict], phases: dict[str, dict]) -> tuple[dict, dict, dict, dict, dict]:
    kbps, fps, sampled_fps, encode, decode = {}, {}, {}, {}, {}
    for name in WINDOW_PHASES:
        span = phases.get(name)
        rows = []
        if span:
            for sample in series:
                # Fixed-second transport buckets may omit duration. Explicit durations
                # describe the whole bucket ending at unix_ms. Discard overlaps rather
                # than inventing when the counted frames or bytes arrived.
                duration = sample.get("duration_ms", 1000)
                if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
                    continue
                if (span["start_unix_ms"] + PHASE_GUARD_MS <= sample["unix_ms"] - duration
                        and sample["unix_ms"] <= span["end_unix_ms"]):
                    rows.append(sample)
        if not rows:
            kbps[name] = fps[name] = sampled_fps[name] = encode[name] = decode[name] = None
            continue
        byte_rows = [s.get("bytes") for s in rows]
        elapsed_s = sum(s.get("duration_ms", 1000) for s in rows) / 1000
        kbps[name] = (round(sum(byte_rows) * 8 / 1000 / elapsed_s, 1)
                      if all(isinstance(value, (int, float)) for value in byte_rows) else None)
        frame_rows = [s.get("frames") for s in rows]
        fps[name] = (round(sum(frame_rows) / elapsed_s, 1)
                     if all(isinstance(value, (int, float)) for value in frame_rows) else None)
        sampled_rows = [s.get("sampled_changes") for s in rows]
        durations = [s.get("duration_ms") for s in rows]
        elapsed_ms = (sum(durations) if all(isinstance(d, (int, float)) and d > 0 for d in durations) else 0)
        sampled_fps[name] = (round(sum(sampled_rows) / (elapsed_ms / 1000), 1)
                             if elapsed_ms > 0
                             and all(isinstance(value, (int, float)) for value in sampled_rows) else None)
        enc = [s["encode_ms"] for s in rows if isinstance(s.get("encode_ms"), (int, float))]
        dec = [s["decode_ms"] for s in rows if isinstance(s.get("decode_ms"), (int, float))]
        encode[name] = round(statistics.median(enc), 2) if enc else None
        decode[name] = round(statistics.median(dec), 2) if dec else None
    return kbps, fps, sampled_fps, encode, decode


OCR_FIELDS = ["cer", "host_cer_vs_truth", "viewer_cer_vs_truth", "host_chars", "viewer_chars", "truth_chars", "host_image", "viewer_image"]


def video_error(request, media, phase) -> str | None:
    """Bind a video phase to the requested prebuilt clip; source counts are not viewer FPS."""
    if (not isinstance(request, dict) or not isinstance(request.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", request["sha256"])
            or request.get("duration_s") != 20):
        return "invalid video-requested.json (expected SHA256 and duration_s=20)"
    if not isinstance(media, dict) or not isinstance(phase, dict):
        return "missing video media or phase receipt"
    if media.get("sha256") != request["sha256"]:
        return "video media does not match requested SHA256"
    for field in ("width", "height", "presented_frames"):
        if type(media.get(field)) is not int or media[field] <= 0:
            return f"invalid source video {field}"
    for field in ("nominal_fps", "duration_s"):
        value = media.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            return f"invalid source video {field}"
    if media["duration_s"] < request["duration_s"]:
        return "source video is shorter than requested phase"
    for field in ("start_unix_ms", "end_unix_ms"):
        value = media.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value != phase.get(field):
            return "video media timestamps do not match phase"
    if media["end_unix_ms"] - media["start_unix_ms"] < request["duration_s"] * 1000:
        return "video phase ended before requested duration"
    return None


def empty_target(errors: list[str]) -> dict:
    """A target with every schema field present and null: what a run that measured nothing reports."""
    return {
        "ok": False, "errors": errors,
        "latency": {k: {"p50_ms": None, "p95_ms": None, "n": None, "lost": None} for k in ("key", "pointer")},
        "kbps": dict.fromkeys(WINDOW_PHASES), "fps": dict.fromkeys(WINDOW_PHASES),
        "sampled_fps": dict.fromkeys(WINDOW_PHASES),
        "ocr": dict.fromkeys(OCR_FIELDS),
        "split": {**{k: {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None, "decode_ms": None, "method": None}
                     for k in ("key", "pointer")}, "typing": {"encode_ms": None, "decode_ms": None}},
        "extra": {"first_frame_ms": None, "cpu_pct": None, "video_requested": None, "video_complete": False},
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
        unavailable = (split.get("method") or "").startswith("apple-screen-sharing-app:")
        if g2g.get("p50") is None and not unavailable:
            errors.append(f"latency {kind}: no samples")
    # Repeats (window-N.json, phases-N.jsonl, ocr-N.json): every number is the median of the repeats
    # that measured it, and extra.repeats keeps each repeat's own numbers.
    reps = sorted(int(f.stem.split("-")[1]) for f in folder.glob("window-*.json") if f.stem.split("-")[1].isdigit())
    reps = sorted(set(reps) | {int(f.stem.split("-")[1]) for f in folder.glob("ocr-*.json") if f.stem.split("-")[1].isdigit()})
    per_rep, ocrs, extras = [], [], []
    video_requested = (folder / "video-requested.json").exists()
    video_request = load(folder / "video-requested.json") if video_requested else None
    for rep in reps:
        window = load(folder / f"window-{rep}.json") or {}
        phases = {}
        if (folder / f"phases-{rep}.jsonl").exists():
            for line in (folder / f"phases-{rep}.jsonl").read_text().splitlines():
                if line.strip():
                    row = json.loads(line)
                    phases[row["phase"]] = row
        media = load(folder / f"video-media-{rep}.json") if video_requested else None
        video_failure = video_error(video_request, media, phases.get("video")) if video_requested else None
        if video_failure:
            errors.append(f"video {rep}: {video_failure}")
        # A timestamped phase without the pinned media receipt cannot supply video numbers.
        if not video_requested or video_failure:
            phases.pop("video", None)
        kbps, fps, sampled_fps, encode, decode = phase_numbers(window.get("series") or [], phases)
        ocr = load(folder / f"ocr-{rep}.json")
        required = WINDOW_PHASES if video_requested else REQUIRED_WINDOW_PHASES
        missing = [k for k in required if fps[k] is None and sampled_fps[k] is None]
        if missing:
            errors.append(f"window {rep}: no frame or sampled-change numbers for {missing} (phases logged: {sorted(phases)})")
        if ocr is None:
            errors.append(f"ocr {rep}: no result")
        else:
            ocrs.append(ocr)
        extras.append(window.get("extra") or {})
        per_rep.append({"repeat": rep, "kbps": kbps, "fps": fps, "sampled_fps": sampled_fps, "typing_encode_ms": encode.get("typing"),
                        "video_media": media, "video_valid": video_requested and not video_failure and "video" not in missing,
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
    first_extra = extras[0] if extras else {}
    metadata = {k: v for k, v in first_extra.items() if k not in {"first_frame_ms", "cpu_pct", "process_cpu_pct"}}
    cpu_values = (e.get("cpu_pct") if isinstance(e.get("cpu_pct"), (int, float)) else None
                  for e in extras)
    result["extra"] = {**metadata,
                        "video_requested": video_requested,
                        "video_complete": bool(per_rep) and all(r["video_valid"] for r in per_rep),
                        "first_frame_ms": median_of(e.get("first_frame_ms") for e in extras),
                        "cpu_pct": median_of(cpu_values),
                        "process_cpu_pct": median_of(e.get("process_cpu_pct") for e in extras),
                        "repeats": per_rep}
    result["sampled_fps"] = {k: median_of(r["sampled_fps"][k] for r in per_rep) for k in WINDOW_PHASES}
    if not result["extra"]["video_complete"]:
        for field in ("kbps", "fps", "sampled_fps"):
            result[field]["video"] = None
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
        for phase, label in (("idle", "idle 30 s"), ("typing", "typing burst"), ("scroll", "scrolling 5k lines"), ("video", "pinned video 20 s")):
            lines.append(f"| kbps, {label} | {cell('kbps', phase, unit='', digits=0)} at {cell('fps', phase, unit=' fps')} |")
        lines.append(f"| Text OCR error (13 pt code, viewer vs host screenshot) | {cell('ocr', 'cer', unit='%', digits=2)}"
                     f" (host OCR vs drawn text {fmt(get(t, 'ocr', 'host_cer_vs_truth'), '%', 2)}) |")
        lines.append(f"| First decoded frame / viewer CPU / capture CPU | {cell('extra', 'first_frame_ms')} / {cell('extra', 'cpu_pct', unit=' %', digits=1)} / {cell('extra', 'process_cpu_pct', unit=' %', digits=1)} |")
        if any(v is not None for v in (t.get('sampled_fps') or {}).values()):
            lines.append(f"| Apple sampled screenshot changes (not decoded FPS) | "
                         + " / ".join(cell('sampled_fps', phase, unit=' changes/s', digits=1) for phase in WINDOW_PHASES) + " |")
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
                      + "; kbps idle / typing / scroll / video "
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
