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
      --before-ms 600 --after-ms 1800

This renderer uses Quick Look only to rasterize the small SVG overlays.  It is
the same macOS environment used by the tagged app recorder, and fails clearly
when the overlay or ffmpeg prerequisites are unavailable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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


def validate_frame_sequence(frames: list[Path]) -> None:
    numbers = []
    for frame in frames:
        match = re.fullmatch(r"frame-(\d{5})\.jpg", frame.name)
        if not match:
            raise SystemExit(f"motion-receipt: invalid frame name: {frame.name}")
        numbers.append(int(match.group(1)))
    expected = list(range(len(numbers)))
    if numbers != expected:
        missing = sorted(set(expected) - set(numbers))
        raise SystemExit(f"motion-receipt: frames must be contiguous from 00000; missing={missing[:8]}")


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
    # A tiny neutral chip keeps the phase legible without turning the receipt
    # into a presentation slide. Full state IDs stay in receipt.json.
    safe = lambda text: (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                         .replace('"', "&quot;"))
    # qlmanage flattens transparent SVGs onto white.  Use a chroma-key matte
    # so the rasterized overlay cannot replace the real UI with a white card.
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="800">
      <rect width="1280" height="800" fill="#ff00ff"/>
      <rect x="20" y="20" width="220" height="34" rx="17" fill="#151515" fill-opacity="0.72" stroke="white" stroke-opacity="0.22"/>
      <text x="36" y="42" font-family="Verdana, sans-serif" font-size="14" font-weight="bold" fill="white">{safe(title)} · {safe(timing)}</text>
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


def encode_hold(frame: Path, seconds: float, out: Path, fps: int) -> None:
    # Keep the app pixels clean. Phase labels and IDs live in receipt.json and
    # the PR comment; putting a generated SVG over the UI makes the evidence
    # harder to judge and can tint the whole frame on macOS Quick Look.
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-loop", "1", "-i", str(frame),
         "-t", f"{seconds:.3f}", "-vf", "scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black",
         "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])


def encode_transition(frames: Path, count: int, out: Path, fps: int) -> None:
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-framerate", str(fps),
         "-i", str(frames / "frame-%05d.jpg"),
         "-t", f"{count / fps:.3f}",
         "-vf", "scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black",
         "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True,
                        help="event JSON containing before_state_id and after_state_id")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--before-ms", type=int, default=600)
    parser.add_argument("--after-ms", type=int, default=1800,
                        help="real final-frame hold after the transition (default: 1800)")
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()
    if shutil.which("ffmpeg") is None:
        raise SystemExit("motion-receipt: ffmpeg is required")
    if args.before_ms <= 0 or args.after_ms <= 0 or args.fps <= 0:
        raise SystemExit("motion-receipt: hold durations and fps must be positive")
    frames = sorted(args.frames.glob("frame-*.jpg"))
    validate_frame_sequence(frames)
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
        transition_ms = len(frames) / args.fps * 1000
        after_start_ms = args.before_ms + transition_ms
        total_ms = after_start_ms + args.after_ms
        before_mp4, transition_mp4, after_mp4 = (scratch / name for name in ("before.mp4", "transition.mp4", "after.mp4"))
        encode_hold(first, args.before_ms / 1000, before_mp4, args.fps)
        encode_transition(args.frames, len(frames), transition_mp4, args.fps)
        encode_hold(last, args.after_ms / 1000, after_mp4, args.fps)
        concat = scratch / "concat.txt"
        concat.write_text("\n".join(f"file '{p}'" for p in (before_mp4, transition_mp4, after_mp4)) + "\n")
        # Do not stream-copy the three independently encoded segments. Their
        # time bases start at different offsets, and concat demuxer + ``-c
        # copy`` can discard the final segment (the exact failure this receipt
        # guard is meant to catch). Re-encode through the concat filter so the
        # after hold is part of one continuous timeline.
        run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error",
             "-i", str(before_mp4), "-i", str(transition_mp4), "-i", str(after_mp4),
             "-filter_complex", "[0:v][1:v][2:v]concat=n=3:v=1:a=0,format=yuv420p[v]",
             "-map", "[v]", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", str(args.out)])
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                            "format=duration:stream=nb_frames", "-of", "json", str(args.out)],
                           capture_output=True, text=True, check=False)
    if probe.returncode:
        raise SystemExit("motion-receipt: ffprobe could not inspect output")
    inspected = json.loads(probe.stdout)
    actual_duration = float((inspected.get("format") or {}).get("duration") or 0)
    actual_frames = int(((inspected.get("streams") or [{}])[0]).get("nb_frames") or 0)
    expected_duration = (args.before_ms + len(frames) / args.fps * 1000 + args.after_ms) / 1000
    expected_frames = round(expected_duration * args.fps)
    if actual_frames < expected_frames - 1 or abs(actual_duration - expected_duration) > 1 / args.fps:
        raise SystemExit(f"motion-receipt: output shortened: expected={expected_duration:.3f}s/{expected_frames}f "
                         f"actual={actual_duration:.3f}s/{actual_frames}f")
    receipt = {
        "source_head": args.head,
        "action": event.get("action", "unknown"),
        "trigger_at": event.get("trigger_at"),
        "before_hold_ms": args.before_ms,
        "transition_frames": len(frames),
        "transition_fps": args.fps,
        "after_hold_ms": args.after_ms,
        "after_start_ms": args.before_ms + len(frames) / args.fps * 1000,
        "labels": "sidecar-only; video intentionally contains clean app pixels",
        "output_duration_s": actual_duration,
        "output_frames": actual_frames,
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
