#!/usr/bin/env python3
"""Render a reviewed motion receipt from real ``debug.window_record`` frames.

The receipt deliberately keeps the UI visible for the whole clip. It holds
the first real frame briefly with a compact BEFORE marker, plays the captured
frames at their recorded cadence, then holds the last real frame with an AFTER
marker. Full state IDs remain in ``receipt.json``; the video only shows the
phase and its boundary time.

Example::

    motion-receipt.py --frames out/raw-pane --metadata out/pane-event.json \
      --out out/pane-split.mp4 --head 6093928e570f \
      --before-ms 600 --after-ms 1800

The marker is rasterized from a small SVG with a keyed matte. It is cropped to
the normalized 1280x800 canvas before compositing, so it cannot stretch into a
card or tint the app pixels.
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


def overlay_svg(path: Path, title: str, timing: str, accent: str) -> None:
    """Write a tiny phase marker on a matte that can be keyed out safely."""
    safe = lambda text: (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                         .replace('"', "&quot;"))
    # qlmanage renders into a square bitmap and scales an SVG to fit it. Use
    # an 800x500 source so the top 1280x800 crop maps 1:1 to the output UI.
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500">
      <rect width="800" height="500" fill="#000000"/>
      <rect x="680" y="470" width="108" height="15" rx="7" fill="#151515"/>
      <rect x="680" y="470" width="2" height="15" fill="{accent}"/>
      <text x="686" y="480" font-family="Helvetica, sans-serif" font-size="7" font-weight="bold" fill="white">{safe(title)} | {safe(timing)}</text>
    </svg>'''
    path.write_text(svg, encoding="utf-8")


def rasterize(svg: Path, into: Path) -> Path:
    if shutil.which("qlmanage") is None:
        raise SystemExit("motion-receipt: qlmanage is required to rasterize overlays")
    into.mkdir(parents=True, exist_ok=True)
    run(["qlmanage", "-t", "-s", "1280", "-o", str(into), str(svg)])
    png = into / f"{svg.name}.png"
    if not png.is_file():
        raise SystemExit(f"motion-receipt: qlmanage produced no overlay for {svg.name}")
    return png


def encode_hold(frame: Path, seconds: float, out: Path, fps: int, marker: Path) -> None:
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-loop", "1", "-i", str(frame),
         "-i", str(marker), "-t", f"{seconds:.3f}",
         "-filter_complex", "[0:v]scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black[ui];"
         "[1:v]crop=1280:800:0:0,format=rgba,colorkey=0x000000:0.05:0.05[marker];[ui][marker]overlay=0:0:format=auto[v]",
         "-map", "[v]", "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])


def encode_transition(frames: Path, times: list[float], out: Path, fps: int, marker: Path, scratch: Path) -> float:
    """Encode frames with recorder timestamps, retaining slow gaps."""
    paths = [frames / f"frame-{index:05d}.jpg" for index in range(len(times))]
    concat = scratch / "transition.ffconcat"
    with concat.open("w", encoding="utf-8") as stream:
        for index, path in enumerate(paths):
            stream.write(f"file '{path.resolve()}'\n")
            duration = (times[index + 1] - times[index]) if index + 1 < len(times) else 1 / fps
            stream.write(f"duration {max(duration, 1 / fps):.9f}\n")
        stream.write(f"file '{paths[-1].resolve()}'\n")
    duration = times[-1] + 1 / fps
    run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(concat),
         "-loop", "1", "-i", str(marker), "-t", f"{duration:.3f}",
         "-filter_complex", "[0:v]scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=black[ui];"
         "[1:v]crop=1280:800:0:0,format=rgba,colorkey=0x000000:0.05:0.05[marker];[ui][marker]overlay=0:0:format=auto[v]",
         "-map", "[v]", "-r", str(fps), "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out)])
    return duration


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
        frames_json = args.frames / "frames.json"
        if frames_json.is_file():
            times = json.loads(frames_json.read_text(encoding="utf-8")).get("times") or []
            if len(times) != len(frames) or any(float(b) <= float(a) for a, b in zip(times, times[1:])):
                raise SystemExit("motion-receipt: frames.json timestamps must be strictly increasing and match frames")
            times = [float(value) for value in times]
        else:
            times = [index / args.fps for index in range(len(frames))]
        transition_seconds = times[-1] + 1 / args.fps
        transition_ms = transition_seconds * 1000
        after_start_ms = args.before_ms + transition_ms
        total_ms = after_start_ms + args.after_ms
        before_mp4, transition_mp4, after_mp4 = (scratch / name for name in ("before.mp4", "transition.mp4", "after.mp4"))
        markers = []
        for name, title, timing, accent in (("before.svg", "BEFORE", "0.0s", "#54a0ff"),
                                             ("motion.svg", "MOTION", f"{args.before_ms / 1000:.1f}s", "#f2b84b"),
                                             ("after.svg", "AFTER", f"{after_start_ms / 1000:.1f}s", "#62d890")):
            svg = scratch / name
            overlay_svg(svg, title, timing, accent)
            markers.append(rasterize(svg, scratch / (name + ".out")))
        encode_hold(first, args.before_ms / 1000, before_mp4, args.fps, markers[0])
        encode_transition(args.frames, times, transition_mp4, args.fps, markers[1], scratch)
        encode_hold(last, args.after_ms / 1000, after_mp4, args.fps, markers[2])
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
    expected_duration = (args.before_ms + transition_ms + args.after_ms) / 1000
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
        "recorded_times_s": times,
        "transition_duration_ms": transition_ms,
        "after_hold_ms": args.after_ms,
        "after_start_ms": args.before_ms + transition_ms,
        "labels": "in-video phase markers: BEFORE/MOTION/AFTER; full state IDs remain in receipt.json",
        "marker_bounds_px": {"x": 1088, "y": 752, "width": 173, "height": 24},
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
