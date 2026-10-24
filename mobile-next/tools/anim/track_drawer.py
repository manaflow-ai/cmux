"""Track the main content's horizontal offset during drawer animations.

usage: python3 -I track_drawer.py <video.mp4> <out.csv> [--row Y]

Samples one pixel row (default 18% down, through the large title) at the
video's native frame rate and reports, per frame, the x where the content's
left edge sits: the first column (scanning right to left from the middle)
where the dimmed/undimmed content boundary is. Works because the drawer and
content differ in background luminance once the dim overlay is applied, and
because the content's own left edge carries the title text.
"""
import subprocess, sys, json, csv

def frames(path, row):
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate", "-of", "json", path]))
    s = probe["streams"][0]
    w, h = s["width"], s["height"]
    y = int(h * row)
    cmd = ["ffmpeg", "-v", "fatal", "-i", path, "-vf", f"crop={w}:2:0:{y},scale=402:1:flags=area", "-fps_mode", "passthrough",
           "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    ts_cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
              "-of", "csv=p=0", path]
    times = [float(t.strip(",")) for t in subprocess.check_output(ts_cmd).decode().split() if t.strip(",")]
    i = 0
    while True:
        line = p.stdout.read(402)
        if len(line) < 402:
            break
        yield (times[i] if i < len(times) else i / 60.0), line, 402
        i += 1

def gradient(line):
    return [line[x + 1] - line[x] for x in range(len(line) - 1)]

def shift(ref, cur, max_shift):
    """Content shift (px, rightwards) that best aligns cur with ref, using
    luminance gradients so the dim overlay's uniform darkening cancels."""
    n = len(ref)
    best, best_s = None, 0
    for s in range(0, max_shift, 2):
        span = n - s
        if span < n // 4:
            break
        err = 0
        step = 3
        for x in range(0, span, step):
            a, b = ref[x], cur[x + s]
            # the overlay scales gradients by (1 - dim); compare signs + magnitude loosely
            err += abs(a - b * 1.3) if b else abs(a)
        err /= (span / step)
        if best is None or err < best:
            best, best_s = err, s
    return best_s, best

def main():
    path, out = sys.argv[1], sys.argv[2]
    row = float(sys.argv[sys.argv.index("--row") + 1]) if "--row" in sys.argv else 0.5
    rows = []
    ref = None
    for t, line, w in frames(path, row):
        g = gradient(line)
        if ref is None:
            ref = g
        x, err = shift(ref, g, int(w * 0.95))
        mean = sum(line) / w
        rows.append((round(t, 4), x, round(err or 0, 2), round(mean, 1)))
    with open(out, "w", newline="") as f:
        csv.writer(f).writerows([("t", "edge_x", "strength", "mean_luma")] + rows)
    print(f"{len(rows)} frames -> {out}")

main()
