"""Track a marker's horizontal position across a screen recording.

usage: python3 -I track_marker.py <video.mp4> <out.csv> --box X Y W H [--band Y0 Y1]

Coordinates are in points (the video is scaled to 402 pt wide). The marker
is the patch at the box in the first frame (e.g. the hamburger button, which
rides on the content layer); each frame reports the x offset (pt) where that
patch matches best within the band, plus the match error.
"""
import json, subprocess, sys
import numpy as np

def arg(name, n):
    i = sys.argv.index(name)
    return [float(v) for v in sys.argv[i + 1:i + 1 + n]]

path, out = sys.argv[1], sys.argv[2]
bx, by, bw, bh = arg("--box", 4)
W = 402
probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height", "-of", "json", path]))["streams"][0]
H = int(round(probe["height"] * W / probe["width"]))
y0, y1 = int(by), int(by + bh)
times = [float(t.strip(",")) for t in subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of", "csv=p=0", path]).decode().split() if t.strip(",")]
proc = subprocess.Popen(["ffmpeg", "-v", "fatal", "-i", path, "-vf", f"scale={W}:{H}:flags=area",
    "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE)
ref = None
rows = ["t,x,err"]
i = 0
while True:
    buf = proc.stdout.read(W * H)
    if len(buf) < W * H:
        break
    frame = np.frombuffer(buf, np.uint8).reshape(H, W).astype(np.float32)
    band = frame[y0:y1]
    if ref is None:
        ref = band[:, int(bx):int(bx + bw)]
        ref = ref - ref.mean()
    best, best_x = 1e18, 0
    pw = ref.shape[1]
    for x in range(0, W - pw):
        patch = band[:, x:x + pw]
        patch = patch - patch.mean()
        err = float(np.abs(patch - ref).mean())
        if err < best:
            best, best_x = err, x
    rows.append(f"{times[i] if i < len(times) else i/60:.4f},{best_x - int(bx)},{best:.2f}")
    i += 1
open(out, "w").write("\n".join(rows) + "\n")
print(f"{i} frames -> {out}")
