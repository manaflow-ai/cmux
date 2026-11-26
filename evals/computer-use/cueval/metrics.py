# SPDX-License-Identifier: MIT
"""Per-call and per-trial cost metrics: where an attempt's time and tokens go.

Each tool call gets: tool name, argument size, latency (the agent emitted the
tool_use to the tool_result arriving, from line arrival times), the model's
think time before it, result text bytes, images (pixel size, base64 bytes, an
estimate of their input tokens), and outcome flags ("No change"/no_effect,
a repeat of the previous identical acting call, an error).
"""

from __future__ import annotations

import base64
import json
import math
import re
import struct

ACTING = {"click", "type_text", "press_key", "hotkey", "scroll", "drag", "set_value",
          "perform_action", "invoke_menu", "move_cursor", "launch_app", "set_window_frame", "batch"}
NO_EFFECT_RE = re.compile(r"(\bno[ _]effect\b|\bNo change\b)", re.I)


def base_name(name: str) -> str:
    name = name.split("__")[-1].split(".")[-1]
    return name[3:] if name.startswith("cu_") else name


def image_size(b64: str) -> tuple[int | None, int | None]:
    """Pixel width and height from a PNG or JPEG header (first few KB only)."""
    try:
        head = base64.b64decode(b64[:65536] + "=" * (-len(b64[:65536]) % 4), validate=False)
    except (ValueError, TypeError):
        return None, None
    if head[:8] == b"\x89PNG\r\n\x1a\n" and len(head) >= 24:
        return struct.unpack(">II", head[16:24])
    if head[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(head):
            if head[i] != 0xFF:
                i += 1
                continue
            marker = head[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", head[i + 5:i + 9])
                return w, h
            seg = struct.unpack(">H", head[i + 2:i + 4])[0]
            i += 2 + seg
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP" and head[12:16] == b"VP8X" and len(head) >= 30:
        w = 1 + int.from_bytes(head[24:27], "little")
        h = 1 + int.from_bytes(head[27:30], "little")
        return w, h
    return None, None


def est_image_tokens(w: int | None, h: int | None) -> int | None:
    """Anthropic's published estimate: tokens ~= w*h/750 after the API downsizes
    the image to a long edge of at most 1568 px and about 1.15 megapixels."""
    if not w or not h:
        return None
    scale = min(1.0, 1568 / max(w, h), math.sqrt(1_150_000 / (w * h)))
    return int(round((w * scale) * (h * scale) / 750))


def describe_images(blocks: list) -> list[dict]:
    out = []
    for b in blocks:
        if not isinstance(b, dict) or b.get("type") != "image":
            continue
        src = b.get("source") or {}
        data = src.get("data") if isinstance(src, dict) else None
        data = data or b.get("data") or ""
        w, h = image_size(data) if data else (None, None)
        out.append({"w": w, "h": h, "b64_bytes": len(data),
                    "media": src.get("media_type") if isinstance(src, dict) else b.get("mimeType"),
                    "est_tokens": est_image_tokens(w, h)})
    return out


def strip_images(line: str) -> str:
    """The stream line with base64 image data replaced by its length (logs stay small)."""
    if '"data"' not in line or len(line) < 2000:
        return line
    try:
        ev = json.loads(line)
    except ValueError:
        return line

    def walk(o):
        if isinstance(o, dict):
            if o.get("type") == "image":
                src = o.get("source")
                if isinstance(src, dict) and isinstance(src.get("data"), str):
                    src["data"] = f"<{len(src['data'])} base64 bytes>"
                if isinstance(o.get("data"), str):
                    o["data"] = f"<{len(o['data'])} base64 bytes>"
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(ev)
    return json.dumps(ev)


def annotate_repeats(calls: list[dict]) -> None:
    """Mark an acting call identical to the previous acting call (same tool, same args)."""
    prev = None
    for c in calls:
        name = base_name(c.get("name", ""))
        if name not in ACTING:
            continue
        key = (name, json.dumps(c.get("args", {}), sort_keys=True))
        c["repeat"] = key == prev
        prev = key


def trial_summary(calls: list[dict], turn_usage: list[dict]) -> dict:
    """Totals for one trial (written into its results row)."""
    lat = [c["latency_s"] for c in calls if c.get("latency_s") is not None]
    think = [c["think_s"] for c in calls if c.get("think_s") is not None]
    imgs = [i for c in calls for i in c.get("images", [])]
    fresh = sum((u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) for u in turn_usage)
    img_tokens = sum(i.get("est_tokens") or 0 for i in imgs)
    looks = {"screenshot", "get_ui_tree", "list_windows", "list_apps", "wait", "status"}
    names = [base_name(c.get("name", "")) for c in calls]
    relooks = sum(1 for a, b in zip(names, names[1:]) if a in ACTING and b in looks)
    return {
        "tool_time_s": round(sum(lat), 2), "think_time_s": round(sum(think), 2),
        "images": len(imgs), "image_b64_bytes": sum(i["b64_bytes"] for i in imgs),
        "image_est_tokens": img_tokens,
        "result_text_bytes": sum(c.get("result_bytes") or 0 for c in calls),
        "no_effect": sum(1 for c in calls if c.get("no_effect")),
        "repeats": sum(1 for c in calls if c.get("repeat")),
        "tool_errors": sum(1 for c in calls if c.get("is_error")),
        "relooks_after_action": relooks,
        "fresh_input_tokens": fresh,
        "cache_read_tokens": sum(u.get("cache_read_input_tokens") or 0 for u in turn_usage),
        "tools": dict(sorted({n: names.count(n) for n in set(names)}.items())),
    }


def result_fields(body: str) -> dict:
    """What a cmux CU result reports about itself: outcome, the settle wait (state.waited_ms,
    state.settle, state.unchanged), and the bytes of text after the JSON head (the outline)."""
    out: dict = {}
    text = (body or "").lstrip()
    if not text.startswith("{"):
        return out
    try:
        head, end = json.JSONDecoder().raw_decode(text)
    except ValueError:
        return out
    if not isinstance(head, dict):
        return out
    st = head.get("state") if isinstance(head.get("state"), dict) else {}
    out["outcome"] = head.get("outcome")
    out["waited_ms"] = st.get("waited_ms")
    out["settle"] = st.get("settle")
    out["unchanged"] = st.get("unchanged", head.get("unchanged"))
    timing = head.get("timing") if isinstance(head.get("timing"), dict) else {}
    enc = timing.get("encode_ms", head.get("encode_ms"))
    out["encode_ms"] = enc if isinstance(enc, (int, float)) else None
    if isinstance(head.get("results"), list):  # batch: the steps' own waits
        waits = [r.get("waited_ms") or (r.get("state") or {}).get("waited_ms") for r in head["results"]
                 if isinstance(r, dict)]
        waits = [w for w in waits if isinstance(w, (int, float))]
        if waits and out["waited_ms"] is None:
            out["waited_ms"] = sum(waits)
        out["outcome"] = out["outcome"] or ",".join(sorted({str(r.get("outcome")) for r in head["results"]
                                                              if isinstance(r, dict) and r.get("outcome")}))
    out["head_bytes"] = len(text[:end].encode())
    out["outline_bytes"] = len(text[end:].encode())
    return out
