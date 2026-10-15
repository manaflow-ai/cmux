#!/usr/bin/env python3
"""check.py MOTION VIDEO [--json]: compare one recorded motion of the Tabs grid
with Safari's own curve (SafariCurves.swift, built from Safari's per-frame
positions on the same simulator and input).

The recording is tracked by a page/card header colour (real frame times),
normalised to progress over the motion's span, aligned at its onset (the last
frame before it moves 0.5 %) and compared with Safari's curve sampled at the
same times. Pass: every crossing (t10/t50/t90/t99) within one 60 Hz frame of
Safari's, or the whole curve within 2 pt. Exit 1 on a failure.
"""
import json, re, subprocess, sys
import numpy as np

HERE = __file__.rsplit('/', 1)[0]
SWIFT = HERE + '/../../Packages/CmuxNextMobile/Sources/CNBrowserUI/SafariCurves.swift'

# motion -> (header colour, field, from, to): the tracked value and its span (pt)
SPECS = {
    # ✕ on cmux: Hacker News (orange) moves from row 2 left to row 1 right.
    'reflow': ('fa6500', 'x0', 16.0, 209.33),
    # The page (cmux, purple) shrinks into its card / grows back out.
    'zoomOut': ('5b59e4', 'w', 402.0, 176.7),
    'swipeUp': ('5b59e4', 'w', 402.0, 176.7),
    # A card (GitHub, green) grows into the page.
    'zoomIn': ('1f853c', 'w', 176.7, 402.0),
    # GitHub springs back from the turnaround (centre x to its slot).
    'snapBack': ('1f853c', 'cx', None, 297.65),
    # GitHub flies off from where the finger ended (right edge to 0).
    'fling': ('1f853c', 'x1', None, 0.0),
    # CmuxTabsKit demo (run.sh --app kit): Springs (orange, active) zooms and
    # springs back; ✕ on it moves Note (cream) from row 3 left to row 2
    # right. Its orange tiles are up to ~106 px wide at full size, so the
    # header band needs 160 px; Note's cream is told from Springs' white page
    # (fading out under it) with a tolerance of 12. Springs is the left card,
    # so its spring back is tracked at its right edge (the left one leaves
    # the screen).
    'kit-reflow': ('fffae0', 'x0', 16.0, 209.33, 90, 12),
    'kit-zoomOut': ('ff9f0a', 'w', 402.0, 176.7, 160),
    'kit-swipeUp': ('ff9f0a', 'w', 402.0, 176.7, 160),
    'kit-zoomIn': ('ff9f0a', 'w', 176.7, 402.0, 160),
    'kit-snapBack': ('ff9f0a', 'x1', None, 192.67, 90),
}


def curves():
    src = open(SWIFT).read()
    out = {}
    for name, body in re.findall(r'static let (\w+) = SafariCurve\(samples: \[(.*?)\]\)', src, re.S):
        out[name] = np.array([float(v) for v in body.replace('\n', ' ').split(',') if v.strip()])
    return out


def track(video, hexc, band_px=90, tol=28):
    """Per frame (real pts): bbox of the header colour, in points (402 pt wide)."""
    w, h = 603, 1311
    s = w / 402
    pts = [float(p.strip(',')) for p in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0', video],
        capture_output=True, text=True).stdout.split() if p.strip(',')]
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-fps_mode', 'passthrough', '-vf', f'scale={w}:{h}',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True).stdout
    c = np.array([int(hexc[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.int16)
    n = len(raw) // (w * h * 3)
    rows = []
    for i in range(n):
        f = np.frombuffer(raw[i * w * h * 3:(i + 1) * w * h * 3], dtype=np.uint8).reshape(h, w, 3).astype(np.int16)
        m = np.abs(f - c).max(axis=2) < tol
        # The header band only: rows where the colour runs across at least
        # 60 pt (the page's own coloured bars and dots are narrower).
        band = m.sum(1) >= band_px
        m = m & band[:, None]
        cols = np.nonzero(m.sum(0) >= 6)[0]
        if len(cols) < 3:
            rows.append((pts[i], None))
            continue
        x0, x1 = cols[0] / s, (cols[-1] + 1) / s
        rows.append((pts[i], {'x0': x0, 'x1': x1, 'w': x1 - x0, 'cx': (x0 + x1) / 2}))
    return rows


def progress(rows, field, a, b):
    t = np.array([r[0] for r in rows if r[1]])
    v = np.array([r[1][field] for r in rows if r[1]])
    if field == 'x1' and b == 0.0:   # fling: from the finger's end (x1 at about 300)
        k = int(np.argmax(v <= 302.5))
        t, v, a = t[k:], v[k:], v[k]
        return t, (a - v) / a, a, True
    if a is None:                    # spring back: from the turnaround
        i = int(np.argmin(v))
        t, v, a = t[i:], v[i:], v[i]
    p = (v - a) / (b - a)
    return t, p, abs(b - a), False


def compare(motion, video):
    hexc, field, a, b, *band = SPECS[motion]
    saf = curves()[motion.split('-')[-1]]
    t, p, span, at_release = progress(track(video, hexc, *band), field, a, b)
    # Aligned at the onset (Safari's tables start at rest), or for the fling
    # at the finger's end (Safari's table starts there, holds included).
    i = 1 if at_release else int(np.argmax(p > 0.005))
    t0 = t[max(0, i - 1)]
    tt = (t - t0) * 1000
    st = np.arange(len(saf)) * 1000 / 60

    def cross(times, prog, q):
        """The time `prog` first reaches `q`, interpolated between frames."""
        k = int(np.argmax(prog >= q))
        if prog[k] < q:
            return float('nan')
        if k == 0:
            return float(times[0])
        a, b = prog[k - 1], prog[k]
        f = (q - a) / (b - a) if b > a else 1.0
        return float(times[k - 1] + (times[k] - times[k - 1]) * f)

    rows = []
    worst = 0.0
    for q in (0.1, 0.5, 0.9, 0.99):
        o, s = cross(tt[i - 1:], p[i - 1:], q), cross(st, saf, q)
        rows.append((q, o, s, o - s))
    mask = (tt >= 0) & (tt <= st[-1])
    delta = np.abs(p[mask] - np.interp(tt[mask], st, saf)) * span
    worst = float(delta.max()) if len(delta) else float('nan')
    cross_ok = all(abs(d) <= 16.7 for _, _, _, d in rows if d == d)
    ok = cross_ok or worst <= 2.0
    return {'motion': motion, 'crossings': rows, 'max_delta_pt': worst, 'pass': ok}


if __name__ == '__main__':
    r = compare(sys.argv[1], sys.argv[2])
    if '--json' in sys.argv:
        print(json.dumps(r))
    else:
        print(f"{r['motion']}: " + '  '.join(f't{int(q*100)} {o:.0f}/{s:.0f} ({d:+.0f})' for q, o, s, d in r['crossings'])
              + f"  max {r['max_delta_pt']:.1f} pt  {'PASS' if r['pass'] else 'FAIL'}")
    sys.exit(0 if r['pass'] else 1)
