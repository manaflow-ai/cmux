#!/usr/bin/env python3
"""Derive loss/IDR/bitrate/PSNR observations from rd's existing raw artifacts."""

from __future__ import annotations

import json
import math
import struct
import sys
import zlib
from pathlib import Path


def read_ppm(path: Path):
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        return None
    pos = 2
    fields = []
    while len(fields) < 3:
        while pos < len(data) and data[pos] in b" \t\r\n":
            pos += 1
        if pos < len(data) and data[pos] == 35:
            pos = data.find(b"\n", pos) + 1
            continue
        end = pos
        while end < len(data) and data[end] not in b" \t\r\n":
            end += 1
        fields.append(int(data[pos:end]))
        pos = end
    width, height, maximum = fields
    if maximum != 255:
        return None
    while pos < len(data) and data[pos] in b" \t\r\n":
        pos += 1
    pixels = data[pos:pos + width * height * 3]
    return width, height, pixels if len(pixels) == width * height * 3 else None


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def read_png(path: Path):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    pos, chunks, width, height, color, bit_depth = 8, [], None, None, None, None
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += length + 12
        if kind == b"IHDR":
            width, height, bit_depth, color = struct.unpack(">IIBB", body[:10])
            if bit_depth != 8 or color not in (2, 6) or body[10:13] != b"\x00\x00\x00":
                return None
        elif kind == b"IDAT":
            chunks.append(body)
        elif kind == b"IEND":
            break
    if not width or not height:
        return None
    raw = zlib.decompress(b"".join(chunks))
    channels = 3 if color == 2 else 4
    stride = width * channels
    rows, cursor, prior = [], 0, bytes(stride)
    for _ in range(height):
        filt, row = raw[cursor], bytearray(raw[cursor + 1:cursor + 1 + stride])
        cursor += stride + 1
        for i, value in enumerate(row):
            left = row[i - channels] if i >= channels else 0
            up = prior[i]
            upper_left = prior[i - channels] if i >= channels else 0
            if filt == 1:
                row[i] = (value + left) & 255
            elif filt == 2:
                row[i] = (value + up) & 255
            elif filt == 3:
                row[i] = (value + ((left + up) // 2)) & 255
            elif filt == 4:
                row[i] = (value + paeth(left, up, upper_left)) & 255
            elif filt != 0:
                return None
        rows.append(bytes(row))
        prior = row
    rgb = b"".join(row if channels == 3 else b"".join(row[i:i + 3] for i in range(0, len(row), 4)) for row in rows)
    return width, height, rgb


def psnr(source: Path, viewer: Path):
    a, b = read_png(source), read_ppm(viewer)
    if not a or not b or a[:2] != b[:2] or a[2] is None or b[2] is None:
        return None
    mse = sum((x - y) ** 2 for x, y in zip(a[2], b[2])) / len(a[2])
    return None if mse == 0 else round(10 * math.log10((255 * 255) / mse), 3)


def psnr_observation(source: Path, viewer: Path):
    if not source.is_file() or not viewer.is_file():
        return None, "missing image"
    a, b = read_png(source), read_ppm(viewer)
    if not a or not b:
        return None, "unsupported image"
    if a[:2] != b[:2] or a[2] is None or b[2] is None:
        return None, "unpaired dimensions or pixels"
    value = psnr(source, viewer)
    return value, "exact match" if value is None else "paired"


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def main(argv: list[str]) -> int:
    raw_path, out_path, timing_path, source_path, viewer_path = map(Path, argv[1:6])
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
        "psnr_source": "source and decoded luma ROI matched by capture key and exact access unit" if quality else None,
    }
    out_path.write_text(json.dumps(result))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("usage: rd-metrics.py RAW OUT TIMING SOURCE_PNG VIEWER_PPM")
    raise SystemExit(main(sys.argv))
