#!/usr/bin/env python3
"""check.py MOTION VIDEO [--json]: compare one recorded motion of the Tabs grid
with Safari's own curve (SafariCurves.swift, built from Safari's per-frame
positions on the same simulator and input).

The recording is tracked by a page/card header colour (real frame times),
normalised to progress over the motion's span, aligned to Safari's curve by a
least-squares fit of its onset half, and compared with Safari's curve sampled
at the same times. Pass: every crossing (t10/t50/t90/t99) within one 60 Hz frame of
Safari's (none missing), or the whole curve within 2 pt; and the first moving
frame within 8 pt of Safari's first (no first-frame jump). Exit 1 on a failure.
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
    # The same release: GitHub's lift (x 1.093) scales back to its card
    # width (re-audit 3 3h).
    'liftBack': ('1f853c', 'w', None, 176.7),
    # A 100 pt drag right, released: GitHub's left edge springs back from
    # the rubber band to its slot (re-audit 3 3i; its right edge is clipped
    # by the screen).
    'rubberRelease': ('1f853c', 'x0', None, 209.33),
    # GitHub flies off from where the finger ended (right edge to 0).
    'fling': ('1f853c', 'x1', None, 0.0, 90, 28, True),
    # Two tabs, ✕ on cmux: GitHub (green) moves to the lone slot (x0 at
    # 209.33 to 67; Safari's 3l reference tracks the same edge).
    'twoToOne': ('1f853c', 'x0', 209.33, 67.0),
    # One tab, ✕: the fresh Start Page (black) grows from the lone card's
    # slot (x0 67.3) to the screen (Safari's D2 tracks the page's x0). Rows
    # 150-600 pt only (the Dynamic Island and the bars are black too).
    'lastTab': ('000000', 'x0', 67.3, 0.0, 90, 6, False, (150, 600)),
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
    'kit-liftBack': ('ff9f0a', 'w', None, 176.7, 90),
    'kit-rubberRelease': ('ff9f0a', 'x0', None, 16.0, 90),
}


# Safari curves the app does not replay (it runs a spring fitted to them):
# progress at 1/60 s from the onset, built like SafariCurves.swift's.
EXTRA_CURVES = {
    # The lift's scale back on a spring back: Safari, 2 runs (re-audit 3 3h).
    'liftBack': [0.0, 0.0414, 0.0669, 0.111, 0.1788, 0.2654, 0.3371, 0.385, 0.4843, 0.5423, 0.6084, 0.6602, 0.7127,
                 0.7436, 0.7872, 0.8305, 0.8524, 0.8947, 0.9369, 0.939, 0.9644, 0.9804, 1.0042, 0.9804, 0.9863, 1.0],
}
# A motion checked against a curve of another name.
CURVE_OF = {'rubberRelease': 'snapBackRight'}


def curves():
    src = open(SWIFT).read()
    out = {k: np.array(v) for k, v in EXTRA_CURVES.items()}
    for name, body in re.findall(r'static let (\w+) = SafariCurve\(samples: \[(.*?)\]\)', src, re.S):
        out[name] = np.array([float(v) for v in body.replace('\n', ' ').split(',') if v.strip()])
    return out


def track(video, hexc, band_px=90, tol=28, lock_rows=False, rows_pt=None):
    """Per frame (real pts): bbox of the header colour, in points (402 pt wide).

    lock_rows: once the header band is found, keep looking in its rows when
    too little of it is left on screen to pass the band width (a card flung
    off the edge moves sideways only)."""
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
    locked = None
    for i in range(n):
        f = np.frombuffer(raw[i * w * h * 3:(i + 1) * w * h * 3], dtype=np.uint8).reshape(h, w, 3).astype(np.int16)
        m = np.abs(f - c).max(axis=2) < tol
        if rows_pt:
            m[:int(rows_pt[0] * s)] = False
            m[int(rows_pt[1] * s):] = False
        # The header band only: rows where the colour runs across at least
        # 60 pt (the page's own coloured bars and dots are narrower).
        band = m.sum(1) >= band_px
        if lock_rows:
            # Keep the widest band found: as the card leaves, the rows
            # beside its close button drop under the band width first, and
            # a band of only the rows above it put x1 at the button (9 pt).
            if band.sum() >= max(6, 0 if locked is None else locked.sum()):
                locked = band
            elif locked is not None:
                band = locked
        m = m & band[:, None]
        cols = np.nonzero(m.sum(0) >= 6)[0]
        if len(cols) < (1 if lock_rows else 3):
            rows.append((pts[i], None))
            continue
        x0, x1 = cols[0] / s, (cols[-1] + 1) / s
        rows.append((pts[i], {'x0': x0, 'x1': x1, 'w': x1 - x0, 'cx': (x0 + x1) / 2}))
    return rows


# The bottom bar's "N Tabs" label (points), for the count timing.
COUNT_BOX = (150, 800, 252, 828)
# When the count may change. reflow: on the presented frame just before the
# first moving one (Safari's frame-before, whatever the frame rate: the kit
# demo's grid presents at about 30 Hz there). fling: (lo, hi) ms after the
# finger's end (Safari +5..12 ms).
COUNT_WINDOW = {'reflow': 'frame-before', 'kit-reflow': 'frame-before', 'fling': (0.0, 25.0)}


def frame_times(video):
    return [float(p.strip(',')) for p in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0', video],
        capture_output=True, text=True).stdout.split() if p.strip(',')]


def count_change(video):
    """Real time of the first frame whose count label differs from the first frame's."""
    w, h = 603, 1311
    s = w / 402
    x0, y0, x1, y1 = (int(v * s) for v in COUNT_BOX)
    pts = [float(p.strip(',')) for p in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0', video],
        capture_output=True, text=True).stdout.split() if p.strip(',')]
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-fps_mode', 'passthrough', '-vf', f'scale={w}:{h}',
                          '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], capture_output=True).stdout
    n = len(raw) // (w * h)
    first = None
    for i in range(n):
        f = np.frombuffer(raw[i * w * h:(i + 1) * w * h], dtype=np.uint8).reshape(h, w)[y0:y1, x0:x1].astype(np.int16)
        if first is None:
            first = f
            continue
        # The label's glyphs change (not a tint): enough pixels move a lot.
        if int((np.abs(f - first) > 60).sum()) > 40:
            return pts[i]
    return None


def progress(rows, field, a, b):
    t = np.array([r[0] for r in rows if r[1]])
    v = np.array([r[1][field] for r in rows if r[1]])
    if field == 'x1' and b == 0.0:   # fling: from x1 = 300 (Safari's table) to the edge
        # The frame after the card's last tracked one has it fully off
        # screen (x1 <= 0): progress 1 there, not a missing sample.
        last = max(i for i, r in enumerate(rows) if r[1])
        if v[-1] < 25 and last + 1 < len(rows):
            t = np.append(t, rows[last + 1][0])
            v = np.append(v, 0.0)
        a = 300.0
        k = int(np.argmax(v <= a))
        f = (v[k - 1] - a) / (v[k - 1] - v[k]) if k > 0 and v[k - 1] > v[k] else 1.0
        tc = t[k - 1] + (t[k] - t[k - 1]) * f if k > 0 else t[k]
        t = np.concatenate([[tc], t[k:]])
        v = np.concatenate([[a], v[k:]])
        return t, (a - v) / a, a, True
    if a is None:                    # spring back: from the turnaround (the far end from `b`)
        # The last frame at the extreme (a lift holds its width for the
        # whole drag, a pixel either way; the scale back starts where it ends).
        ext = v.min() if b > v.mean() else v.max()
        i = int(np.nonzero(np.abs(v - ext) <= 0.8)[0][-1])   # a pixel step is 0.67 pt
        t, v, a = t[i:], v[i:], v[i]
    p = (v - a) / (b - a)
    return t, p, abs(b - a), False


def compare(motion, video):
    hexc, field, a, b, *band = SPECS[motion]
    name = motion.split('-')[-1]
    saf = curves()[CURVE_OF.get(name, name)]
    t, p, span, at_release = progress(track(video, hexc, *band), field, a, b)
    count_ms = None
    if motion in COUNT_WINDOW:
        tc = count_change(video)
        ref = t[0] if at_release else t[max(1, int(np.argmax(p > 0.005)))]
        count_ms = None if tc is None else (tc - ref) * 1000
    st = np.arange(len(saf)) * 1000 / 60
    # Aligned by a least-squares fit of the onset half (progress 0.5 %-50 %)
    # to Safari's curve: a recording has no frames while the screen is still,
    # so the frame before the onset can be 5-35 ms earlier, and a first frame
    # that barely moves put a whole run a frame off. The first frame's own
    # step is checked apart (`jump`). The fling's onset is the finger's end.
    i = 1 if at_release else max(1, int(np.argmax(p > 0.005)))
    base = (t - t[i]) * 1000 + st[int(np.argmax(saf > 0.005))]
    sel = (p > 0.005) & (p < 0.5)
    if at_release:
        sel = (p > 0.0) & (p < 0.5)
    best = (float('inf'), 0.0)
    for tau in np.arange(-50, 50.25, 0.25):
        e = float(np.sum((p[sel] - np.interp(base[sel] + tau, st, saf)) ** 2))
        best = min(best, (e, tau))
    tt = base + best[1]
    # The first moving frame against Safari's (a jump shows here).
    k0 = int(np.argmax(p > 0.005))
    jump = (p[k0] - saf[int(np.argmax(saf > 0.005))]) * span

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
    # A crossing closer to the end than one point is below the tracker's
    # resolution (1.5 px/pt): lastTab's t99 is 0.67 pt from the edge.
    rows = [r for r in rows if r[0] < 0.99 or span * 0.01 >= 1.0]
    cross_ok = all(abs(d) <= 16.7 for _, _, _, d in rows) and all(o == o for _, o, _, _ in rows)
    ok = (cross_ok or worst <= 2.0) and (at_release or abs(jump) <= 8.0)
    if motion in COUNT_WINDOW:
        window = COUNT_WINDOW[motion]
        if window == 'frame-before':
            # The count's frame is the presented frame right before the first move.
            pts = frame_times(video)
            ref = t[max(1, int(np.argmax(p > 0.005)))]
            tc = None if count_ms is None else ref + count_ms / 1000
            between = None if tc is None else sum(1 for x in pts if tc + 1e-4 < x < ref - 1e-4)
            ok = ok and count_ms is not None and count_ms < 0 and between == 0
        else:
            lo, hi = window
            ok = ok and count_ms is not None and lo <= count_ms <= hi
    return {'motion': motion, 'crossings': rows, 'max_delta_pt': worst, 'jump_pt': float(jump), 'count_ms': count_ms, 'pass': ok}


# A card tapped during the zoom-out: from the zoom-out's onset (cmux, purple,
# leaves full width) to the tapped card's zoom-in onset (GitHub, green, grows
# past its card). Safari: 470-570 ms (re-audit 3, 8-interrupt).
TAP_ZOOMOUT_WINDOW = (470.0, 570.0)


def compare_tap_zoomout(video):
    out = track(video, '5b59e4')
    t_out = next((t for t, r in out if r and r['w'] < 398), None)
    grow = track(video, '1f853c')
    t_in = None
    if t_out is not None:
        # The green card first settles at its grid width, then grows.
        settled = False
        for t, r in grow:
            if t <= t_out or not r:
                continue
            if r['w'] < 185:
                settled = True
            elif settled and r['w'] > 190:
                t_in = t
                break
    ms = None if t_out is None or t_in is None else (t_in - t_out) * 1000
    lo, hi = TAP_ZOOMOUT_WINDOW
    return {'motion': 'tapZoomOut', 'open_ms': ms, 'pass': ms is not None and lo <= ms <= hi}


# A 100 pt drag over 1.0 s on GitHub's card (the snapBack input): the card's
# offset from its slot, timed as the re-audits time it (re-audit 5 cx.py and
# onset.py): from the last frame at rest, at most one 60 Hz frame before the
# first moving one (0.5 pt out), and the farthest it gets (the carry past the
# finger). Safari, mean of 3 runs timed the same way (re-audit 3
# saf-drag-{1,2,3}.csv): -30.1 / -39.0 / -61.5 pt at +100 / +200 / +500 ms,
# -103.8 pt at most. Timed from the first moving frame instead (round 22),
# a run that jumped 16 pt in one frame passed while the re-audit's runs that
# ran 9-12 pt behind were not seen.
DRAG_SAFARI = {100: -30.1, 200: -39.0, 500: -61.5, 'min': -103.8}
DRAG_TOLERANCE_PT = 2.0
# The largest step between two recorded frames in the first 120 ms: Safari
# 7.4-8.4 pt (it glides over the slop); round 22's runs jumped 15-18 pt.
DRAG_MAX_STEP_PT = 10.0


def compare_drag(video):
    rows = track(video, '1f853c')
    t = np.array([r[0] for r in rows if r[1]])
    off = np.array([r[1]['cx'] for r in rows if r[1]]) - 297.65
    k = max(1, int(np.argmax(off < -0.5)))
    t0 = max(t[k - 1], t[k] - 1 / 60)
    tt = (t - t0) * 1000
    ours = {ms: float(np.interp(ms, tt, off)) for ms in (100, 200, 500)}
    ours['min'] = float(off.min())
    steps = [off[j] - off[j + 1] for j in range(k - 1, len(off) - 1) if tt[j] < 120]
    step = float(max(steps)) if steps else 0.0
    ok = all(abs(ours[key] - DRAG_SAFARI[key]) <= DRAG_TOLERANCE_PT for key in DRAG_SAFARI) and step <= DRAG_MAX_STEP_PT
    return {'motion': 'drag', 'ours': ours, 'max_step_pt': step, 'pass': ok}


if __name__ == '__main__':
    if sys.argv[1] == 'drag':
        r = compare_drag(sys.argv[2])
        print('drag: ' + '  '.join(f"{k if k == 'min' else f'+{k}'} {r['ours'][k]:.1f}/{DRAG_SAFARI[k]:.1f} ({r['ours'][k] - DRAG_SAFARI[k]:+.1f})"
                                   for k in DRAG_SAFARI) + f"  step {r['max_step_pt']:.1f}/{DRAG_MAX_STEP_PT:.0f}  {'PASS' if r['pass'] else 'FAIL'}")
        sys.exit(0 if r['pass'] else 1)
    if sys.argv[1] == 'tapZoomOut':
        r = compare_tap_zoomout(sys.argv[2])
        print('tapZoomOut: opens ' + ('never' if r['open_ms'] is None else f"{r['open_ms']:.0f} ms")
              + f" after the zoom-out starts (Safari {TAP_ZOOMOUT_WINDOW[0]:.0f}-{TAP_ZOOMOUT_WINDOW[1]:.0f})  {'PASS' if r['pass'] else 'FAIL'}")
        sys.exit(0 if r['pass'] else 1)
    r = compare(sys.argv[1], sys.argv[2])
    if '--json' in sys.argv:
        print(json.dumps(r))
    else:
        print(f"{r['motion']}: " + '  '.join(f't{int(q*100)} {o:.0f}/{s:.0f} ({d:+.0f})' for q, o, s, d in r['crossings'])
              + f"  max {r['max_delta_pt']:.1f} pt  jump {r['jump_pt']:+.1f} pt"
              + ('' if r['count_ms'] is None else f"  count {r['count_ms']:+.0f} ms")
              + f"  {'PASS' if r['pass'] else 'FAIL'}")
    sys.exit(0 if r['pass'] else 1)
