#!/usr/bin/env python3
"""The screen stream eval's results: one target's files into the stable schema, and the run's
summary.md with each number's change against an earlier run's results.json.

  eval.py target NAME DIR OUT.json      DIR holds what the harness and the target wrote
  eval.py empty ERROR...                a schema-complete target that measured nothing
  eval.py summary RESULTS.json OUT.md [--previous EARLIER.json]
  eval.py external NAME OUT.json --host-cmd CMD --viewer-cmd CMD [--host-stop-cmd CMD] [--takes 3]
                                        an external contender's host and viewer, measured from the
                                        viewer's marker readback (EXTERNAL below; README.md)
  eval.py readback READBACK.jsonl OUT.json   one readback file into a target

Schema (SCHEMA below; README.md): results.json is
  {"schema", "run": {...}, "scenarios": [...], "targets": {NAME: TARGET}}
and each TARGET is
  {"ok", "errors": [...],
   "latency": {"key"|"pointer": {"p50_ms", "p95_ms", "n", "lost"}},
    "kbps": {"idle"|"typing"|"scroll"|"video": number}, "fps": {same},
   "ocr": {"cer", "host_cer_vs_truth", "viewer_cer_vs_truth", ...},
   "split": {"key"|"pointer": {"encode_ms", "transport_ms", "decode_ms", "input_to_capture_ms", "method",
                                [rd: "input_to_capture_parts": {"render_ms"|"sck_ms"|"pickup_ms"|"gate_ms"|"encode_ms": {"n", "p50", "p95"}}],
                                [iphone-sim: "present": {"presented_ms"|"decoded_ms"|"decode_to_present_ms": {"n", "p50", "p95"},
                                                         "decoded_not_presented", "clock"}]},
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

SCHEMA = "cmux.screen-stream-eval/1"
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
                duration = sample.get("duration_ms", 1000)
                if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
                    continue
                if (span["start_unix_ms"] + PHASE_GUARD_MS <= sample["unix_ms"] - duration
                        and sample["unix_ms"] <= span["end_unix_ms"]):
                    rows.append(sample)
        if not rows:
            kbps[name] = fps[name] = sampled_fps[name] = encode[name] = decode[name] = None
            continue
        # Missing counts remain unmeasured; valid counts are weighted by actual duration.
        elapsed_s = sum(s.get("duration_ms", 1000) for s in rows) / 1000
        byte_rows = [s.get("bytes") for s in rows]
        frame_rows = [s.get("frames") for s in rows]
        sampled_rows = [s.get("sampled_changes") for s in rows]
        measured = lambda values: all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in values)
        kbps[name] = round(sum(byte_rows) * 8 / 1000 / elapsed_s, 1) if measured(byte_rows) else None
        fps[name] = round(sum(frame_rows) / elapsed_s, 1) if measured(frame_rows) else None
        sampled_fps[name] = round(sum(sampled_rows) / elapsed_s, 1) if measured(sampled_rows) else None
        enc = [s["encode_ms"] for s in rows if isinstance(s.get("encode_ms"), (int, float))]
        dec = [s["decode_ms"] for s in rows if isinstance(s.get("decode_ms"), (int, float))]
        encode[name] = round(statistics.median(enc), 2) if enc else None
        decode[name] = round(statistics.median(dec), 2) if dec else None
    return kbps, fps, sampled_fps, encode, decode


OCR_FIELDS = ["cer", "host_cer_vs_truth", "viewer_cer_vs_truth", "host_chars", "viewer_chars", "truth_chars", "host_image", "viewer_image", "comparison_ready", "crops"]


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
        "ocr": {**dict.fromkeys(OCR_FIELDS), "comparison_ready": False},
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
        # iphone-sim: the same input timed to the decoded frame and to the presented frame.
        if split.get("present"):
            result["split"][kind]["present"] = split["present"]
        # A window-only target (its `caps` verb; screen-stream-eval.sh) has no latency stage, and
        # Screen Sharing.app's latency is unavailable unless the presented observer measured it.
        unavailable = (split.get("method") or "").startswith("apple-screen-sharing-app:")
        if g2g.get("p50") is None and not unavailable and not (folder / "window-only").exists():
            errors.append(f"latency {kind}: no samples")
    # Repeats (window-N.json, phases-N.jsonl, ocr-N.json): every number is the median of the repeats
    # that measured it, and extra.repeats keeps each repeat's own numbers.
    requested_path = folder / "repeats-requested.json"
    requested = load(requested_path)
    count = requested.get("count") if isinstance(requested, dict) else None
    count = count if type(count) is int and count >= 1 else None
    if requested_path.exists() and count is None:
        errors.append("invalid repeats-requested.json (expected positive integer count)")
    discovered = set()
    for pattern in ("window-*.json", "ocr-*.json", "phases-*.jsonl", "video-media-*.json"):
        for path in folder.glob(pattern):
            suffix = path.stem.rsplit("-", 1)[-1]
            if suffix.isdigit():
                discovered.add(int(suffix))
    intended = set(range(1, count + 1)) if count is not None else set()
    repeat_contract_ready = count is not None and discovered <= intended
    if count is not None and not discovered <= intended:
        errors.append("repeat artifacts outside requested count")
    reps = sorted(discovered | intended)
    # A latency-only target (its `caps` verb; iphone-sim) runs no window or OCR repeats.
    latency_only = (folder / "latency-only").exists()
    per_rep, ocrs, extras = [], [], []
    video_requested = (folder / "video-requested.json").exists()
    if video_requested and not repeat_contract_ready:
        errors.append("video: complete requested-repeat receipt is unavailable")
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
        # Bytes are required, except from a viewer that marks them unavailable (Screen Sharing.app
        # when nettop read none, `bytes_unavailable: true`); that one needs frame or sampled-change counts instead. A
        # `bytes_method` alone (gui-viewer.sh's nettop) still owes bytes. The video phase is required only when requested.
        required = WINDOW_PHASES if video_requested else REQUIRED_WINDOW_PHASES
        if (window.get("extra") or {}).get("bytes_unavailable") is True:
            missing = [k for k in required if fps[k] is None and sampled_fps[k] is None]
        else:
            missing = [k for k in required if kbps[k] is None]
        if missing:
            errors.append(f"window {rep}: no numbers for {missing} (phases logged: {sorted(phases)})")
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
    if not reps and not latency_only:
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
            if k == "comparison_ready":
                continue
            if any(isinstance(o.get(k), (int, float)) for o in ocrs):
                result["ocr"][k] = median_of(o.get(k) for o in ocrs)
            else:
                result["ocr"][k] = middle.get(k)
    elif not latency_only:
        errors.append("ocr: no result")
    # Missing calibration metadata is unknown, never a successful common-content comparison.
    result["ocr"]["comparison_ready"] = repeat_contract_ready and bool(per_rep) and all(
        r["ocr"].get("comparison_ready") is True
        and isinstance(r["ocr"].get("crops"), dict)
        and type(r["ocr"].get("cer")) in (int, float)
        and math.isfinite(r["ocr"]["cer"])
        for r in per_rep)
    # Codec observations are per-repeat evidence, not first-repeat metadata: missing quality or
    # timing in one repeat stays visible in extra.repeats rather than becoming an aggregate taken
    # from another repeat. First frame and CPU are each the median of the repeats that measured it.
    metadata = {k: v for k, v in (extras[0] if extras else {}).items()
                if k not in {"netem_metrics", "first_frame_ms", "cpu_pct", "process_cpu_pct"}}
    result["extra"] = {**metadata,
                        "video_requested": video_requested,
                        "video_complete": repeat_contract_ready and bool(per_rep) and all(r["video_valid"] for r in per_rep),
                        "requested_repeats": count,
                        "first_frame_ms": median_of(e.get("first_frame_ms") for e in extras),
                        "cpu_pct": median_of(e.get("cpu_pct") for e in extras),
                        "process_cpu_pct": median_of(e.get("process_cpu_pct") for e in extras),
                        "repeats": per_rep}
    result["sampled_fps"] = {k: median_of(r["sampled_fps"][k] for r in per_rep) for k in WINDOW_PHASES}
    if not result["extra"]["video_complete"]:
        for field in ("kbps", "fps", "sampled_fps"):
            result[field]["video"] = None
    result["ok"] = not errors
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


# ---------------------------------------------------------------- external contenders

READBACK_SCHEMA = "cmux.screen-stream-eval.readback/1"
EXTERNAL = """An external contender is a host and viewer this checkout did not write. The harness knows
neither: `--host-cmd` starts the host (in the foreground until the harness stops its process
group, or it returns after starting a remote host) and creates $EVAL_STATE/host-ready once it
serves; `--viewer-cmd` connects, drives the marker, writes the readback (one JSON object a line)
to $EVAL_READBACK, and exits. `--host-stop-cmd` runs after each take (a remote host's cleanup).
Every take gets a fresh host and a fresh EVAL_STATE (0700). The readback records:

  {"type": "first_frame", "ms": N}       connect start -> first decoded frame with the marker
  {"type": "key", "g2g_ms": N}           key sent on the viewer -> decoded frame whose marker
  {"type": "key", "lost": true}            counter shows it (none within 1 s: lost)
  {"type": "second", "bytes": B, "frames": F, "duration_ms": D}
                                         one bucket of the motion window: bytes received, frames decoded
  {"type": "cpu", "side": "host" | "viewer", "pct": P}
                                         each end's process CPU over the motion window (100 = one core)
  {"type": "meta", ...}                  kept in the take

A missing record leaves its number null. extra.takes keeps each take's numbers; each number of
the target is the median of the takes that measured it. Any viewer that decodes the stream and
reads the marker (cmux-tui/crates/cmux-rd-host/src/marker.rs) from its decoded frames can write
this, so a contender is measured with the same counter as `cmux-rd bench`."""


def _rank(values: list[float], q: float):
    """The nearest-rank percentile."""
    if not values:
        return None
    values = sorted(values)
    return round(values[min(len(values) - 1, max(0, math.ceil(q / 100 * len(values)) - 1))], 2)


def readback_numbers(records: list[dict]) -> dict:
    """One take's numbers from its readback records (EXTERNAL)."""
    num = lambda v: type(v) in (int, float) and math.isfinite(v)
    keys = [r for r in records if r.get("type") == "key"]
    g2g = [float(r["g2g_ms"]) for r in keys if not r.get("lost") and num(r.get("g2g_ms"))]
    seconds = [r for r in records if r.get("type") == "second"]
    elapsed_s = sum(r.get("duration_ms", 1000) for r in seconds if num(r.get("duration_ms", 1000))) / 1000

    def rate(field: str, scale: float):
        if not seconds or elapsed_s <= 0 or not all(num(r.get(field)) and r[field] >= 0 for r in seconds):
            return None
        return round(sum(r[field] for r in seconds) * scale / elapsed_s, 1)

    cpu = {r.get("side"): r.get("pct") for r in records if r.get("type") == "cpu" and num(r.get("pct"))}
    first = [r["ms"] for r in records if r.get("type") == "first_frame" and num(r.get("ms"))]
    meta = {}
    for r in records:
        if r.get("type") == "meta":
            meta.update({k: v for k, v in r.items() if k != "type"})
    return {
        "key": {"p50_ms": _rank(g2g, 50), "p95_ms": _rank(g2g, 95), "n": len(g2g) if keys else None,
                "lost": sum(1 for r in keys if r.get("lost")) if keys else None},
        "motion_kbps": rate("bytes", 8 / 1000),
        "motion_fps": rate("frames", 1),
        "first_frame_ms": round(first[0], 1) if first else None,
        "viewer_cpu_pct": cpu.get("viewer"),
        "host_cpu_pct": cpu.get("host"),
        "meta": meta,
    }


def read_records(path: Path) -> list[dict]:
    records = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                records.append(row)
    return records


def external_target(takes: list[dict], errors: list[str]) -> dict:
    """The schema's target from external takes: each number the median of the takes that measured it."""
    def med(values):
        values = [v for v in values if type(v) in (int, float)]
        return round(statistics.median(values), 2) if values else None

    result = empty_target(list(errors))
    result["latency"]["key"] = {f: med(t["key"][f] for t in takes) for f in ("p50_ms", "p95_ms", "n", "lost")}
    result["motion"] = {"kbps": med(t["motion_kbps"] for t in takes), "fps": med(t["motion_fps"] for t in takes)}
    result["extra"].update({"first_frame_ms": med(t["first_frame_ms"] for t in takes),
                            "cpu_pct": med(t["viewer_cpu_pct"] for t in takes),
                            "process_cpu_pct": med(t["host_cpu_pct"] for t in takes),
                            "readback_schema": READBACK_SCHEMA, "takes": takes})
    if result["latency"]["key"]["p50_ms"] is None:
        result["errors"].append("latency key: no samples")
    if result["motion"]["fps"] is None:
        result["errors"].append("motion: no frame counts")
    result["ok"] = bool(takes) and not result["errors"]
    return result


def _stop_group(proc) -> None:
    """SIGTERM, then SIGKILL, to the process group this harness started for a host."""
    import os
    import signal
    import subprocess
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            continue


def external(name: str, out: Path, host_cmd: str, viewer_cmd: str, host_stop_cmd: str | None,
             takes: int, ready_timeout_s: float, viewer_timeout_s: float, keep: Path | None) -> dict:
    import os
    import shutil
    import subprocess
    import tempfile
    import time
    rows, errors = [], []
    for take in range(1, takes + 1):
        state = Path(tempfile.mkdtemp(prefix=f"eval-external-{take}-"))
        state.chmod(0o700)
        readback = state / "readback.jsonl"
        env = {**os.environ, "EVAL_STATE": str(state), "EVAL_READBACK": str(readback),
               "EVAL_TAKE": str(take), "EVAL_TARGET": name}
        with open(state / "host.log", "wb") as host_log:
            host = subprocess.Popen(["bash", "-c", host_cmd], env=env, stdout=host_log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + ready_timeout_s
                while not (state / "host-ready").exists() and time.monotonic() < deadline:
                    if host.poll() not in (None, 0):
                        break
                    time.sleep(0.1)
                if not (state / "host-ready").exists():
                    errors.append(f"take {take}: host not ready within {ready_timeout_s:.0f} s (exit {host.poll()})")
                    continue
                try:
                    viewer = subprocess.run(["bash", "-c", viewer_cmd], env=env, timeout=viewer_timeout_s,
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    (state / "viewer.log").write_bytes(viewer.stdout or b"")
                    if viewer.returncode != 0:
                        errors.append(f"take {take}: viewer exited {viewer.returncode}")
                except subprocess.TimeoutExpired:
                    errors.append(f"take {take}: viewer timed out after {viewer_timeout_s:.0f} s")
                rows.append({"take": take, **readback_numbers(read_records(readback))})
            finally:
                _stop_group(host)
                if host_stop_cmd:
                    subprocess.run(["bash", "-c", host_stop_cmd], env=env, timeout=120, check=False)
                if keep:
                    dest = keep / f"take-{take}"
                    dest.mkdir(parents=True, exist_ok=True)
                    for f in ("readback.jsonl", "host.log", "viewer.log"):
                        if (state / f).exists():
                            shutil.copy2(state / f, dest / f)
                shutil.rmtree(state, ignore_errors=True)
    result = external_target(rows, errors)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


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
                 + (", rd host `--input-frame-now 1`" if run.get("rd_input_frame_now") == "1" else "")
                 + (", rd host `--ltr 1`" if run.get("rd_ltr") == "1" else "") + ".")
    lines += ["", "Latency uses each target's recorded endpoint (see method below); "
              "a decoded-frame or display-capture endpoint does not establish physical glass-to-glass latency."]
    if previous:
        prev_run = previous.get("run", {})
        lines.append(f"Changes in brackets are against {prev_run.get('at', '?')} (rev `{str(prev_run.get('rev', '?'))[:12]}`).")
    else:
        lines.append("No earlier run to compare against.")
    if run.get("blocked"):
        lines += ["", f"**Not measured:** {run['blocked']}"]
    targets = results.get("targets", {})
    if len(targets) > 1:
        # One row per contender, so latency, bandwidth and frame rate read across targets at once.
        lines += ["", "## Side by side", "",
                  "| Target | Key / click p50 | kbps idle / typing / scroll | fps idle / typing / scroll |",
                  "| --- | --- | --- | --- |"]
        sampled_only = False
        for name, t in targets.items():
            latency = " / ".join(fmt(((t.get("latency") or {}).get(kind) or {}).get("p50_ms"), " ms")
                                 for kind in ("key", "pointer"))
            kbps = " / ".join(fmt((t.get("kbps") or {}).get(phase), "", 0) for phase in REQUIRED_WINDOW_PHASES)
            fps, mark = t.get("fps") or {}, ""
            if all(v is None for v in fps.values()) and any(v is not None for v in (t.get("sampled_fps") or {}).values()):
                fps, mark, sampled_only = t["sampled_fps"], "*", True
            rate = " / ".join(fmt(fps.get(phase), mark) for phase in REQUIRED_WINDOW_PHASES)
            lines.append(f"| {name} | {latency} | {kbps} | {rate} |")
        if sampled_only:
            lines += ["", "\\* sampled screenshot changes a second (at most 10 captures a second), not decoded FPS."]
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
            lines.append(f"| {label} latency p50 / p95 (target endpoint) | {cell('latency', kind, 'p50_ms')} / {cell('latency', kind, 'p95_ms')}"
                         f" (n {get(t, 'latency', kind, 'n') or 0}, lost {get(t, 'latency', kind, 'lost') or 0}) |")
        for phase, label in (("idle", "idle 30 s"), ("typing", "typing burst"), ("scroll", "scrolling 5k lines"), ("video", "pinned video 20 s")):
            lines.append(f"| kbps, {label} | {cell('kbps', phase, unit='', digits=0)} at {cell('fps', phase, unit=' fps')} |")
        lines.append(f"| Text OCR error (13 pt code, viewer vs host screenshot) | {cell('ocr', 'cer', unit='%', digits=2)}"
                     f" (host OCR vs drawn text {fmt(get(t, 'ocr', 'host_cer_vs_truth'), '%', 2)}) |")
        lines.append("| OCR content calibration verified in every repeat | "
                     + ("yes" if get(t, "ocr", "comparison_ready") is True else "no / unavailable") + " |")
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
                if parts.get("draw_ms") or parts.get("commit_to_vsync_ms"):
                    hz = parts.get("refresh_hz")
                    lines.append(f"| {kind.capitalize()} capture parts (p50 / p95) at {hz or '?'} Hz: draw / commit→vsync / vsync→callback | "
                                 + " · ".join(fmt((parts.get(k) or {}).get("p50"), "", 2) + " / " + fmt((parts.get(k) or {}).get("p95"), " ms", 2)
                                              for k in ("draw_ms", "commit_to_vsync_ms", "sck_ms")) + " |")
        for kind in ("key", "pointer"):
            present = get(t, "split", kind, "present") or {}
            if present:
                stats = [present.get(k) or {} for k in ("decoded_ms", "presented_ms", "decode_to_present_ms")]
                lines.append(f"| {kind.capitalize()} decoded / presented / decode→present, p50 (p95) | "
                             + " / ".join(f"{fmt(s.get('p50'), ' ms')} ({fmt(s.get('p95'), ' ms')})" for s in stats)
                             + f", decoded but never presented {present.get('decoded_not_presented') or 0} |")
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
    if len(argv) == 3 and argv[0] == "readback":
        take = {"take": 1, **readback_numbers(read_records(Path(argv[1])))}
        Path(argv[2]).write_text(json.dumps(external_target([take], []), indent=2, sort_keys=True) + "\n")
        return 0
    if len(argv) >= 3 and argv[0] == "external":
        import argparse
        ap = argparse.ArgumentParser(prog="eval.py external", description=EXTERNAL,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
        ap.add_argument("name")
        ap.add_argument("out", type=Path)
        ap.add_argument("--host-cmd", required=True)
        ap.add_argument("--viewer-cmd", required=True)
        ap.add_argument("--host-stop-cmd")
        ap.add_argument("--takes", type=int, default=3)
        ap.add_argument("--ready-timeout", type=float, default=120)
        ap.add_argument("--viewer-timeout", type=float, default=600)
        ap.add_argument("--keep", type=Path, help="copy each take's readback and logs here")
        a = ap.parse_args(argv[1:])
        result = external(a.name, a.out, a.host_cmd, a.viewer_cmd, a.host_stop_cmd, a.takes,
                          a.ready_timeout, a.viewer_timeout, a.keep)
        print(f"eval.py external {a.name}: ok {result['ok']}, errors {result['errors']}", file=sys.stderr)
        return 0 if result["ok"] else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
