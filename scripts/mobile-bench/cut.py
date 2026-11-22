#!/usr/bin/env python3
"""Cut one recording into per-flow clips by its marker lines.

    cut.py RECORDING.mp4 MARKERS.txt OUT_DIR --app cmux [--source simulator]
           [--device NAME] [--os VER] [--build SHA] [--video-start EPOCH]

MARKERS.txt is any log holding lines like

    MOBILEBENCH flow=keyboard-show event=stimulus t=1795086710.512
    MOBILEBENCH flow=keyboard-show event=end t=1795086713.020
    MOBILEBENCH flow=voice-start unsupported reason=no voice mode

`t` is wall-clock seconds; --video-start (or a `MOBILEBENCH video-start t=...`
line) is the wall-clock time of the recording's first frame. A `t_video=`
field instead of `t=` is already seconds into the recording.

Each flow gets OUT_DIR/<flow>/clip.mp4 (from 0.5 s before the stimulus to its
end, stream-copied when the cut lands on a keyframe, else re-encoded
losslessly with the original timestamps kept) and meta.json (README.md,
"Clip contract"). Unsupported flows get meta.json with "unsupported".
Only flow ids listed in flows.json are cut; any other id in the markers (they
come from fleet logs) is reported and skipped, so no marker can name a path
outside OUT_DIR.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from measure import ffmpeg_bin  # noqa: E402

LINE = re.compile(r"MOBILEBENCH\s+(.*)")
LEAD_S = 0.5


def parse(text: str) -> tuple[float | None, dict[str, dict]]:
    start, flows = None, {}
    for m in LINE.finditer(text):
        fields = dict(re.findall(r"(\w+)=(\"[^\"]*\"|\S+)", m.group(1)))
        fields = {k: v.strip('"') for k, v in fields.items()}
        if m.group(1).startswith("video-start"):
            start = float(fields["t"])
            continue
        flow = fields.get("flow")
        if not flow:
            continue
        rec = flows.setdefault(flow, {})
        if "unsupported" in m.group(1).split():
            rec["unsupported"] = fields.get("reason", "")
        ev = fields.get("event")
        if ev:
            rec[ev] = ("v", float(fields["t_video"])) if "t_video" in fields else ("t", float(fields["t"]))
    return start, flows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("recording", type=Path)
    ap.add_argument("markers", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--app", required=True)
    ap.add_argument("--source", default="simulator")
    ap.add_argument("--device", default=None)
    ap.add_argument("--os", default=None)
    ap.add_argument("--build", default=None)
    ap.add_argument("--video-start", type=float, default=None)
    args = ap.parse_args()
    start, flows = parse(args.markers.read_text(errors="replace"))
    known = {f["id"] for f in json.loads((HERE / "flows.json").read_text())["flows"]}
    for bad in sorted(set(flows) - known):
        print(f"cut.py: skipped marker flow {bad!r}: not a flow in flows.json", file=sys.stderr)
        del flows[bad]
    out_root = args.out.resolve()
    start = args.video_start if args.video_start is not None else start
    ff = ffmpeg_bin()
    recorded = dt.datetime.fromtimestamp(args.recording.stat().st_mtime, dt.timezone.utc).isoformat(timespec="seconds")
    made = 0
    for flow, rec in flows.items():
        d = (out_root / flow).resolve()
        if d.parent != out_root:
            sys.exit(f"cut.py: flow {flow!r} resolves outside {out_root}")
        d.mkdir(parents=True, exist_ok=True)
        meta = {"app": args.app, "flow": flow, "source": args.source, "device": args.device, "os": args.os,
                "build": args.build, "recorded_at": recorded}
        if "unsupported" in rec or "stimulus" not in rec:
            meta["unsupported"] = rec.get("unsupported") or "no stimulus marker"
            (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
            continue

        def video_t(ev):
            kind, val = ev
            if kind == "v":
                return val
            if start is None:
                sys.exit("cut.py: markers carry wall-clock t= but no video start (--video-start or a video-start line)")
            return val - start

        s = video_t(rec["stimulus"])
        e = video_t(rec["end"]) if "end" in rec else s + 3.0
        a = max(0.0, s - LEAD_S)
        # -ss after -i: frame-accurate; libx264 -qp 0 keeps every pixel, -fps_mode passthrough keeps
        # the recorder's own timestamps (the measure reads drops from them)
        subprocess.run([ff, "-hide_banner", "-loglevel", "error", "-y", "-i", str(args.recording), "-ss", f"{a:.4f}",
                        "-to", f"{e + 0.3:.4f}", "-an", "-fps_mode", "passthrough", "-c:v", "libx264", "-qp", "0",
                        "-preset", "veryfast", "-pix_fmt", "yuv420p", str(d / "clip.mp4")], check=True)
        meta["stimulus_t"] = round(s - a, 4)
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        made += 1
    print(f"cut.py: {made} clips, {len(flows) - made} unsupported, in {args.out}")
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
