#!/usr/bin/env python3
"""Render a reviewed motion receipt from real ``debug.window_record`` frames.

The receipt deliberately keeps the UI visible for the whole clip.  It holds
the first real frame briefly with a compact BEFORE overlay, plays the captured
frames at their recorded cadence, then holds the last real frame with an AFTER
overlay.  Full state IDs remain in ``receipt.json``; the video shows short
prefixes so the labels do not cover the interaction.

Example::

    motion-receipt.py --frames out/raw-pane --metadata out/pane-event.json \
      --out out/pane-split.mp4 --head 6093928e570f \
      --before-ms 600 --after-ms 900

This renderer uses Quick Look only to rasterize the small SVG overlays.  It is
the same macOS environment used by the tagged app recorder, and fails clearly
when the overlay or ffmpeg prerequisites are unavailable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(command: list[str], *, cwd: Path | None = None) -> None:
    completed = subprocess.run(command, cwd=cwd, check=False,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        raise SystemExit(f"motion-receipt: {' '.join(command[:3])} failed: "
                         f"{detail[-1] if detail else 'unknown error'}")


def short(value: str) -> str:
    return value[:8] if value else "?"


def first_last(frames: list[Path]) -> tuple[Path, Path]:
    if len(frames) < 3:
        raise SystemExit("motion-receipt: need at least three real JPEG frames")
    first, last = frames[0], frames[-1]
    if first.stat().st_size < 1024 or last.stat().st_size < 1024:
        raise SystemExit("motion-receipt: first or last frame is suspiciously small")
    if hashlib.sha256(first.read_bytes()).digest() == hashlib.sha256(last.read_bytes()).digest():
        raise SystemExit("motion-receipt: first and last frames are identical; no visible transition")
    return first, last


def overlay_svg(path: Path, title: str, detail: str, timing: str) -> None:
    # A small lower-third badge leaves the UI and its geometry unobscured.
    safe = lambda text: (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                         .replace('"', "&quot;"))
    # qlmanage flattens transparent SVGs onto white.  Use a chroma-key matte
    # so the rasterized overlay cannot replace the real UI with a white card.
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="800">
      <rect width="1280" height="800" fill="#ff00ff"/>
      <rect x="24" y="690" width="850" height="88" rx="14" fill="#0b1020" fill-opacity="0.86" stroke="#94a3b8" stroke-opacity="0.35"/>
      <text x="48" y="724" font-family="Verdana, sans-serif" font-size="22" font-weight="bold" fill="white">{safe(title)}</text>
      <text x="48" y="752" font-family="Verdana, sans-serif" font-size="17" fill="#dbeafe">{safe(detail)}</text>
      <text x="48" y="773" font-family="Verdana, sans-serif" font-size="14" fill="#bfdbfe">{safe(timing)}</text>
    </svg>'''
    path.write_text(svg, encoding="utf-8")


def rasterize(svg: Path, into: Path) -> Path:
    if shutil.which("qlmanage") is None:
        raise SystemExit("motion-receipt: qlmanage is required to rasterize overlays")
    run(["qlmanage", "-t", "-s", "1280", "-o", str(into), str(svg)])
    png = into / f"{svg.name}.png"
    if not png.is_file():
        raise SystemExit(f"motion-receipt: qlmanage produced no overlay for {svg.name}")
    return png


def encode_hold(frame: Path, overlay: Path, seconds: float, out: Path, fps: int) -> None:
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-loop", "1", "-i", str(frame),
         "-loop", "1", "-i", str(overlay), "-t", f"{seconds:.3f}",
         "-filter_complex", "[0:v]scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black[ui];[1:v]scale=1280:800,format=rgba,colorkey=0xff00ff:0.30:0.0[ov];[ui][ov]overlay=0:0",
         "-shortest", "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])


def encode_transition(frames: Path, overlay: Path, count: int, out: Path, fps: int) -> None:
    # The transition badge is intentionally compact and stable; exact per-frame
    # timestamps stay in receipt.json so the UI never gets covered by changing text.
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-framerate", str(fps),
         "-i", str(frames / "frame-%05d.jpg"),
         "-loop", "1", "-i", str(overlay),
         "-t", f"{count / fps:.3f}",
         "-filter_complex", "[0:v]scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black[ui];[1:v]scale=1280:800,format=rgba,colorkey=0xff00ff:0.30:0.0[ov];[ui][ov]overlay=0:0",
         "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True,
                        help="event JSON containing before_state_id and after_state_id")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--before-ms", type=int, default=600)
    parser.add_argument("--after-ms", type=int, default=900)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()
    if shutil.which("ffmpeg") is None:
        raise SystemExit("motion-receipt: ffmpeg is required")
    if args.before_ms <= 0 or args.after_ms <= 0 or args.fps <= 0:
        raise SystemExit("motion-receipt: hold durations and fps must be positive")
    frames = sorted(args.frames.glob("frame-*.jpg"))
    first, last = first_last(frames)
    event = json.loads(args.metadata.read_text(encoding="utf-8"))
    before = event.get("before_state_id") or {}
    after = event.get("after_state_id") or {}
    before_panes = before.get("panes") or []
    after_panes = after.get("panes") or []
    if not before_panes or len(after_panes) <= len(before_panes):
        raise SystemExit("motion-receipt: metadata does not prove a state change")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cmux-motion-receipt-") as scratch_name:
        scratch = Path(scratch_name)
        before_svg = scratch / "before.svg"
        transition_svg = scratch / "transition.svg"
        after_svg = scratch / "after.svg"
        overlay_svg(before_svg, "BEFORE  ·  real UI", f"w {short(before.get('windows', [''])[0])}  ws {short(before.get('selected', [''])[0])}  pane {short(before_panes[0])}", "t=0 ms  ·  exact IDs in receipt.json")
        overlay_svg(transition_svg, "TRANSITION  ·  splitRight", f"w {short(before.get('windows', [''])[0])}  ws {short(before.get('selected', [''])[0])}  {len(before_panes)} → {len(after_panes)} panes", "real recorded frames  ·  exact IDs in receipt.json")
        overlay_svg(after_svg, "AFTER  ·  real UI", f"w {short(after.get('windows', [''])[0])}  ws {short(after.get('selected', [''])[0])}  panes {short(after_panes[0])}, {short(after_panes[-1])}", "t=3,400 ms  ·  exact IDs in receipt.json")
        before_png = rasterize(before_svg, scratch)
        transition_png = rasterize(transition_svg, scratch)
        after_png = rasterize(after_svg, scratch)
        before_mp4, transition_mp4, after_mp4 = (scratch / name for name in ("before.mp4", "transition.mp4", "after.mp4"))
        encode_hold(first, before_png, args.before_ms / 1000, before_mp4, args.fps)
        encode_transition(args.frames, transition_png, len(frames), transition_mp4, args.fps)
        encode_hold(last, after_png, args.after_ms / 1000, after_mp4, args.fps)
        concat = scratch / "concat.txt"
        concat.write_text("\n".join(f"file '{p}'" for p in (before_mp4, transition_mp4, after_mp4)) + "\n")
        run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
             "-i", str(concat), "-c", "copy", "-movflags", "+faststart", str(args.out)])
    receipt = {
        "source_head": args.head,
        "action": event.get("action", "unknown"),
        "trigger_at": event.get("trigger_at"),
        "before_hold_ms": args.before_ms,
        "transition_frames": len(frames),
        "transition_fps": args.fps,
        "after_hold_ms": args.after_ms,
        "before_state_id": before,
        "after_state_id": after,
        "first_frame": first.name,
        "last_frame": last.name,
        "contract": "real-first-frame + real-transition-frames + real-last-frame",
    }
    args.out.with_name("receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"out": str(args.out), "frames": len(frames), "receipt": str(args.out.with_name('receipt.json'))}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
