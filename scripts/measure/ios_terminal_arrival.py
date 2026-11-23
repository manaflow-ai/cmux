#!/usr/bin/env python3
"""Tables for TerminalArrivalBenchUITests (arriving at a terminal from the Workspaces list).

Leo, 2026-11-23: "there's like various little like odd little like shifts when I like
arrive at the terminal. Like it doesn't settle well."

Usage: python3 -I ios_terminal_arrival.py TAG=ATTACHMENTS_DIR ... [--json] [--frames N]
ATTACHMENTS_DIR holds manifest.json and the kbm-trace-arrival / kbm-marks-arrival
attachments (cmux-next-ios-sim.sh's ui-duress-SLUG-attachments).

Per arrival (a mark `arrive.N` or `cold.arrive.0` to the next mark), from the trace's
per-frame arrival fields (TerminalArrivalFields), on the trace's clock from the row's touch:

- paint ms: the first frame the terminal page is on screen with its surface drawn and a
  Ghostty present since the touch (the first paint).
- push ms: the frame after which the page's x stays put (the push transition is over).
- moves: frames after the first paint where one of the page's views changed by more than
  0.5 pt (x taken relative to the page, so the push slide is not a move) or appeared or went;
  after the push ends the navigation bar's items and the tab bar count too.
- max pt: the largest distance of a view from where it rests, over those frames.
- rest ms: the touch to the last frame anything changed (push included).
- by view: which view moved, how many frames, its largest step and the first step's
  time and delta (dx, dy, dw, dh), and whether the page's safe area changed in that frame.
"""
import json
import os
import statistics
import sys

PAGE = ('pg', 'sv', 'ss', 'kr', 'cp', 'fd')
BARS = ('nb', 'nt', 'nl', 'nr', 'tb')
EPS = 0.5


def load(dirp):
    m = json.load(open(os.path.join(dirp, 'manifest.json')))
    out = {}
    for t in m:
        for a in t.get('attachments', []):
            n = a.get('suggestedHumanReadableName', '')
            for kind in ('kbm-trace-', 'kbm-marks-'):
                if n.startswith(kind + 'arrival'):
                    out[kind] = os.path.join(dirp, a['exportedFileName'])
    return out


def kv(fields):
    return dict(x.split('=', 1) for x in fields if '=' in x)


def rect(s):
    if s is None or s == '-':
        return None
    return tuple(float(x) for x in s.split(','))


def parse(trace, marks):
    lines = open(trace).read().split('\n')
    ep = float(lines[0].split('=')[1])
    frames, evs = [], []
    for r in lines[1:]:
        if not r.startswith('t='):
            continue
        f = r.split()
        t = float(f[0][2:])
        d = kv(f[1:])
        if 'ev' in d:
            evs.append((t, d))
        elif 'ar' in d:
            frames.append((t, d))
    ms, cond = [], '?'
    for line in open(marks):
        p = line.split()
        if len(p) >= 4 and p[0] == 'kbm-mark':
            ms.append((float(p[1]) - ep, p[3]))
        elif p and p[0] == 'arr-cond':
            cond = ' '.join(p[1:])
    return frames, evs, ms, cond


def view_rects(d):
    """The frame's views; page views with x relative to the page."""
    pg = rect(d.get('pg'))
    px = pg[0] if pg else 0.0
    out = {}
    for k in PAGE:
        r = rect(d.get(k))
        out[k] = None if r is None else (r[0] - px, r[1], r[2], r[3])
    for k in BARS:
        out[k] = rect(d.get(k))
    return out


def step(a, b):
    """(changed, delta, distance) between two rects (None: not shown)."""
    if a is None and b is None:
        return False, None, 0.0
    if a is None or b is None:
        return True, 'appear' if a is None else 'gone', 0.0
    delta = tuple(y - x for x, y in zip(a, b))
    dist = max(abs(x) for x in delta)
    return dist > EPS, delta, dist


def arrival(frames, evs, t0, t1, seen):
    touch = next((t for t, e in evs if t0 <= t < t1 and e.get('ev') == 'touchBegan'), None)
    start = touch if touch is not None else t0
    win = [(t, d) for t, d in frames if start <= t < t1]
    r = {'touch': touch is not None}
    if not win:
        r['miss'] = 'noframes'
        return r
    width = float(win[0][1].get('win', '0x0').split('x')[0] or 0)
    paint = None
    for i, (t, d) in enumerate(win):
        if d.get('ar') != '1':
            continue
        sv = rect(d.get('sv'))
        pn, pr = d.get('pn'), int(d.get('pr', '0'))
        on = sv is not None and sv[0] < width and sv[0] + sv[2] > 0 and sv[2] > 0 and sv[3] > 0
        if on and pr > seen.get(pn, 0):
            paint = i
            break
    # What each page presented so far, for the next arrival's baseline.
    for t, d in win:
        if d.get('ar') == '1':
            seen[d['pn']] = max(seen.get(d['pn'], -1), int(d.get('pr', '0')))
    if paint is None:
        r['miss'] = 'nopaint'
        return r
    r['paint_ms'] = 1000 * (win[paint][0] - start)
    # The push ends where the page's x reaches its last value and stays.
    xs = [rect(d.get('pg'))[0] if rect(d.get('pg')) else None for _, d in win]
    last_x = xs[-1]
    push = len(win) - 1
    while push > 0 and xs[push - 1] is not None and last_x is not None and abs(xs[push - 1] - last_x) <= EPS:
        push -= 1
    r['push_ms'] = 1000 * (win[push][0] - start)
    rects = [view_rects(d) for _, d in win]
    rest = rects[-1]
    moves, last_change, max_pt = 0, None, 0.0
    by = {}
    sa_prev = win[0][1].get('sa')
    for i in range(1, len(win)):
        moved = False
        sa = win[i][1].get('sa')
        sa_changed = sa != sa_prev
        sa_prev = sa
        any_abs = False
        for k in PAGE + BARS:
            ch, delta, dist = step(rects[i - 1][k], rects[i][k])
            # Absolute change (push included) for the time to rest.
            if k in PAGE:
                a, b = rect(win[i - 1][1].get(k)), rect(win[i][1].get(k))
                if step(a, b)[0]:
                    any_abs = True
            elif ch:
                any_abs = True
            if i <= paint or not ch:
                continue
            if k in BARS and i <= push:
                continue
            moved = True
            b = by.setdefault(k, {'frames': 0, 'max_step': 0.0, 'first': None, 'sa': 0})
            b['frames'] += 1
            b['max_step'] = max(b['max_step'], dist)
            if sa_changed:
                b['sa'] += 1
            if b['first'] is None:
                b['first'] = (round(1000 * (win[i][0] - start)),
                              delta if isinstance(delta, str) else tuple(round(x, 1) for x in delta))
        if any_abs:
            last_change = i
        if moved:
            moves += 1
        if i >= paint:
            for k in PAGE + (BARS if i > push else ()):
                a, b = rects[i][k], rest[k]
                if a is not None and b is not None:
                    max_pt = max(max_pt, max(abs(x - y) for x, y in zip(a, b)))
    so = [float(d.get('so', 'nan')) for _, d in win[paint:]]
    so_changes = sum(1 for a, b in zip(so, so[1:]) if abs(b - a) > EPS)
    r.update({'moves': moves, 'max_pt': max_pt, 'by': by, 'so_changes': so_changes,
              'so_max': max((abs(x - so[-1]) for x in so), default=0.0),
              'rest_ms': 1000 * (win[last_change][0] - start) if last_change is not None else 0.0,
              'mtb_max': max(float(d.get('mtb', '0')) for _, d in win)})
    return r


def rows(trace, marks):
    frames, evs, ms, cond = parse(trace, marks)
    out, seen = [], {}
    for i, (t0, label) in enumerate(ms):
        t1 = ms[i + 1][0] if i + 1 < len(ms) else t0 + 5
        if not (label.startswith('arrive.') or label == 'cold.arrive.0'):
            # Keep the baseline of presents current through the other steps.
            for t, d in frames:
                if t0 <= t < t1 and d.get('ar') == '1':
                    seen[d['pn']] = max(seen.get(d['pn'], -1), int(d.get('pr', '0')))
            continue
        r = arrival(frames, evs, t0, t1, seen)
        r['label'] = label
        r['cold'] = label.startswith('cold.')
        out.append(r)
    return cond, out


def pct(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return float('nan')
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def fmt(xs, f='%.0f'):
    return (f + ' / ' + f) % (pct(xs, 0.5), pct(xs, 0.95))


def tables(res):
    print('## Terminal arrival: frames after the first paint (trace clock, from the row\'s touch)\n')
    print('| run | cond | arrivals | n | with a move | moves p50/p95 | max pt p50/p95 | max pt max | paint ms p50/p95 | push ms p50/p95 | rest ms p50/p95 | scroll changes p50/p95 | main busy max ms p50/p95 |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    for tag, (cond, rs) in sorted(res.items()):
        for kind, g in (('cold', [r for r in rs if r['cold']]), ('warm', [r for r in rs if not r['cold']])):
            g = [r for r in g if 'miss' not in r]
            if not g:
                continue
            print('| %s | %s | %s | %d | %d/%d | %s | %s | %.1f | %s | %s | %s | %s | %s |' % (
                tag, cond, kind, len(g), sum(1 for r in g if r['moves']), len(g), fmt([r['moves'] for r in g]),
                fmt([r['max_pt'] for r in g], '%.1f'), max(r['max_pt'] for r in g), fmt([r['paint_ms'] for r in g]),
                fmt([r['push_ms'] for r in g]), fmt([r['rest_ms'] for r in g]), fmt([r['so_changes'] for r in g]),
                fmt([r['mtb_max'] for r in g], '%.1f')))
    print('\n## Which view moves after the first paint\n')
    print('| run | view | arrivals | frames p50/p95 | largest step pt | first step (ms after touch: dx,dy,dw,dh) | with a safe-area change |')
    print('|---|---|---|---|---|---|---|')
    names = {'pg': 'page', 'sv': 'surface', 'ss': 'bottom stack', 'kr': 'key row', 'cp': 'composer', 'fd': 'composer field',
             'nb': 'nav bar', 'nt': 'nav title', 'nl': 'nav left item', 'nr': 'nav right item', 'tb': 'tab bar'}
    for tag, (cond, rs) in sorted(res.items()):
        g = [r for r in rs if 'miss' not in r]
        for k in PAGE + BARS:
            hits = [r['by'][k] for r in g if k in r['by']]
            if not hits:
                continue
            firsts = [h['first'] for h in hits if h['first']]
            print('| %s | %s | %d/%d | %s | %.1f | %s | %d |' % (
                tag, names[k], len(hits), len(g), fmt([h['frames'] for h in hits]), max(h['max_step'] for h in hits),
                '; '.join('%d: %s' % (t, d if isinstance(d, str) else ','.join('%g' % x for x in d)) for t, d in firsts[:3]),
                sum(1 for h in hits if h['sa'])))
    misses = {t: [r['label'] + ':' + r['miss'] for r in rs if 'miss' in r] for t, (_, rs) in res.items()}
    print('\nmissed arrivals:', {k: v for k, v in misses.items() if v} or 'none')


if __name__ == '__main__':
    res = {}
    for spec in [a for a in sys.argv[1:] if '=' in a and not a.startswith('--')]:
        tag, dirp = spec.split('=', 1)
        f = load(dirp)
        if 'kbm-trace-' in f and 'kbm-marks-' in f:
            res[tag] = rows(f['kbm-trace-'], f['kbm-marks-'])
        else:
            print(f'{tag}: no kbm-trace-arrival/kbm-marks-arrival in {dirp}', file=sys.stderr)
    if '--json' in sys.argv:
        json.dump({t: {'cond': c, 'rows': rs} for t, (c, rs) in res.items()}, sys.stdout, indent=1, default=str)
    else:
        tables(res)
