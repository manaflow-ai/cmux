#!/usr/bin/env python3
"""Find motion segments in a variable-frame-rate simctl recording.

simctl recordVideo only emits a frame when the screen changes, so runs of
closely spaced frames (< 25 ms apart) are animations. Prints each segment's
start/end time and frame count.
Usage: frame_times.py video.mp4 [min_frames]
"""
import os, subprocess, sys
os.environ["PATH"] = "/opt/homebrew/bin:" + os.environ.get("PATH", "")

def main():
    v = sys.argv[1]
    min_frames = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
                          "frame=pts_time", "-of", "csv=p=0", v], capture_output=True, text=True).stdout
    ts = [float(x.strip(",")) for x in out.split() if x.strip(",")]
    seg = [ts[0]]
    segs = []
    for a, b in zip(ts, ts[1:]):
        if b - a < 0.025:
            seg.append(b)
        else:
            if len(seg) >= min_frames:
                segs.append(seg)
            seg = [b]
    if len(seg) >= min_frames:
        segs.append(seg)
    for s in segs:
        print(f"{s[0]:8.3f} -> {s[-1]:8.3f}  {len(s):4d} frames  {1000*(s[-1]-s[0]):7.0f} ms")

if __name__ == "__main__":
    main()
