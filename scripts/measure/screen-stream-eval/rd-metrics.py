#!/usr/bin/env python3
"""Derive loss/IDR/bitrate/PSNR observations from rd's existing raw artifacts."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def main(argv: list[str]) -> int:
    raw_path, out_path, timing_path = map(Path, argv[1:4])
    result = json.loads(out_path.read_text())
    raw_obj = json.loads(raw_path.read_text()) if raw_path.exists() else {}
    raw_lines = []
    if timing_path.exists():
        for line in timing_path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                raw_lines.append(json.loads(line))
            except ValueError:
                pass
    series = raw_obj.get("series") or []
    seconds = number(raw_obj.get("seconds"))
    if seconds is None:
        duration_ms = number(raw_obj.get("duration_ms"))
        seconds = duration_ms / 1000 if duration_ms is not None else None
    duration_ok = seconds is not None and seconds > 0
    byte_values = [number(row.get("bytes")) for row in series]
    bytes_total = number(raw_obj.get("bytes"))
    if bytes_total is None and byte_values and all(v is not None for v in byte_values):
        bytes_total = sum(byte_values)
    decoded = number(raw_obj.get("decoded_frames"))
    # Frame identity is the exact host encode request timestamp, NOT a
    # capture-time claim. Join to the source's actual displayed-frame time.
    by_release = {r["release_us"]: r for r in raw_lines if number(r.get("release_us")) is not None}
    decode_records = raw_obj.get("decode_records")
    matched = []
    if isinstance(decode_records, list):
        for frame in decode_records:
            host = by_release.get(frame.get("release_us"), {})
            shown, done = number(host.get("shown_us")), number(frame.get("decoded_us"))
            if shown is not None and done is not None and done >= shown:
                matched.append(done - shown)
    measured = (raw_obj.get("eval_clock") == "same-host protocol monotonic microseconds"
                and raw_obj.get("decode_records_truncated") is False
                and isinstance(decode_records, list) and decoded is not None
                and len(matched) == len(decode_records) == decoded)
    on_time = sum(age <= 100_000 for age in matched) if measured else None
    begin, end = number(raw_obj.get("eval_begin_us")), number(raw_obj.get("eval_end_us"))
    attempts_rows = [r for r in raw_lines if number(r.get("encoded_bytes")) is not None
                     and isinstance(r.get("idr"), bool)
                     and (begin is None or begin <= r.get("release_us", -1))
                     and (end is None or r.get("release_us", end + 1) <= end)]
    attempts = len(attempts_rows) if attempts_rows else None
    skips = sum(r["encoded_bytes"] == 0 for r in attempts_rows) if attempts is not None else None
    frames = attempts - skips if attempts is not None else None
    idrs = sum(r["encoded_bytes"] > 0 and r["idr"] for r in attempts_rows) if attempts is not None else None
    quality = [r for r in (raw_obj.get("quality_samples") or [])
               if r.get("identity_verified") is True and number(r.get("squared_error_sum")) is not None
               and number(r.get("pixels")) is not None and r["pixels"] > 0]
    mse = sum(r["squared_error_sum"] for r in quality) / sum(r["pixels"] for r in quality) if quality else None
    extra = result.setdefault("extra", {})
    extra["netem_metrics"] = {
        "first_frame_ms": number(raw_obj.get("first_frame_ms")),
        "attempts": attempts, "frames": frames, "skips": skips, "idrs": idrs,
        "p_frames": frames - idrs if frames is not None else None,
        "bytes": bytes_total,
        "bitrate_bps": round(bytes_total * 8 / seconds, 2) if bytes_total is not None and duration_ok else None,
        "bitrate_boundary": "viewer received video and FEC datagram bytes",
        "decoded_fps": round(decoded / seconds, 3) if decoded is not None and duration_ok else None,
        "on_time_fps": round(on_time / seconds, 3) if on_time is not None and duration_ok else None,
        "on_time_frames": on_time, "on_time_deadline_ms": 100,
        "matched_decode_records": len(matched),
        "on_time_endpoint": "same-host captured display-frame timestamp to headless decoder completion",
        "psnr_db": round(10 * math.log10(255**2 / mse), 3) if mse is not None and mse > 0 else None,
        "psnr_status": "exact match" if mse == 0 else "identity matched luma ROI" if mse is not None else "unmeasured",
        "quality_samples": quality,
        "idr_count_source": "per-encode timing records" if idrs is not None else None,
        "psnr_source": "source and decoded luma ROI matched by encode-request key and exact access unit" if quality else None,
    }
    out_path.write_text(json.dumps(result))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: rd-metrics.py RAW OUT TIMING")
    raise SystemExit(main(sys.argv))
