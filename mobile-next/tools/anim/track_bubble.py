"""Per-frame bounding box (pt) of the lowest sent (blue) bubble.

usage: python3 -I track_bubble.py <video.mp4> <out.csv> [--start S] [--dur D]

Scales the video to 402 pt wide, masks iMessage-blue pixels, and takes the
lowest connected band of masked rows (the newest bubble); reports x0,y0,x1,y1.
"""
import json, subprocess, sys
import numpy as np

path, out = sys.argv[1], sys.argv[2]
start = sys.argv[sys.argv.index("--start") + 1] if "--start" in sys.argv else "0"
dur = sys.argv[sys.argv.index("--dur") + 1] if "--dur" in sys.argv else "9999"
W = 402
probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height", "-of", "json", path]))["streams"][0]
H = int(round(probe["height"] * W / probe["width"]))
proc = subprocess.Popen(["ffmpeg", "-v", "fatal", "-ss", start, "-t", dur, "-i", path, "-vf", f"scale={W}:{H}:flags=area",
    "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
times = [float(t.strip(",")) for t in subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
    "-read_intervals", f"{start}%+{dur}", "-show_entries", "frame=pts_time", "-of", "csv=p=0", path]).decode().split() if t.strip(",")]
rows = ["t,x0,y0,x1,y1,w,h"]
i = 0
while True:
    buf = proc.stdout.read(W * H * 3)
    if len(buf) < W * H * 3:
        break
    f = np.frombuffer(buf, np.uint8).reshape(H, W, 3).astype(int)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    mask = (b > 200) & (r < 110) & (g > 100) & (g < 190)
    ys = np.where(mask.sum(1) > 6)[0]
    t = times[i] if i < len(times) else i / 60
    if len(ys):
        # lowest contiguous run of rows
        end = ys[-1]; k = len(ys) - 1
        while k > 0 and ys[k - 1] >= ys[k] - 2:
            k -= 1
        y0 = ys[k]
        cols = np.where(mask[y0:end + 1].any(0))[0]
        rows.append(f"{t:.4f},{cols.min()},{y0},{cols.max()},{end},{cols.max()-cols.min()},{end-y0}")
    else:
        rows.append(f"{t:.4f},,,,,,")
    i += 1
open(out, "w").write("\n".join(rows) + "\n")
print(f"{i} frames -> {out}")
