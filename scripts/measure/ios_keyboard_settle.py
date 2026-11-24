#!/usr/bin/env python3
"""Tables for KeyboardInjectBenchUITests' testSettleChat and testSettleTerminal.

Usage: python3 -I ios_keyboard_settle.py TAG=ATTACHMENTS_DIR ... [--json]
ATTACHMENTS_DIR holds manifest.json and the kbm-trace-*/kbm-marks-* attachments
(an xcresult export: ui-duress-SLUG-attachments in cmux-next-ios-sim.sh's evidence).

Per surface, direction and TAG, from the keyboard pin trace (one line per display frame,
presentation layers): the keyboard's last drawn move (kb=, its top) after willShow/willHide,
the content's last drawn move (the content scroll view's bottom edge of its content cb= and
its frame cf=), and content last - keyboard last in ms (<= 0: the content stopped with the
keyboard). The longest frame is the largest gap between two display-link frames from the
notification to the keyboard's last move (plus the largest main-thread busy ms per tick, mtb=).
Terminal: resizes sent to the Mac in the step (rz=, a round trip) and the last terminal
present (tp=) relative to the keyboard's last move.
"""
import json
import os
import statistics
import sys

SPAN = 1.3  # seconds after the notification a step is read for


def load(dirp):
    m = json.load(open(os.path.join(dirp, 'manifest.json')))
    out = {}
    for t in m:
        for a in t.get('attachments', []):
            n = a.get('suggestedHumanReadableName', '')
            for kind in ('kbm-trace-', 'kbm-marks-'):
                if n.startswith(kind):
                    name = n[len(kind):].rsplit('_0_', 1)[0]
                    if name.endswith('.txt'):
                        name = name[:-4]
                    out.setdefault(name, {})[kind] = os.path.join(dirp, a['exportedFileName'])
    return out


def kv(fields):
    return dict(x.split('=', 1) for x in fields if '=' in x)


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse(trace, marks):
    lines = open(trace).read().split('\n')
    ep = float(lines[0].split('=')[1])
    evs, frames = [], []
    for r in lines[1:]:
        if not r.startswith('t='):
            continue
        f = r.split()
        t = float(f[0][2:])
        d = kv(f[1:])
        if 'ev' in d:
            evs.append((t, d))
        elif 'kb' in d:
            frames.append((t, d))
    ms = []
    for line in open(marks):
        p = line.split()
        if len(p) >= 4 and p[0] == 'kbm-mark':
            ms.append((float(p[1]) - ep, p[3]))
    return evs, frames, ms


def last_move(series, eps=0.5):
    """Time of the last frame whose value differs from the previous frame's."""
    last = None
    for (_, a), (t, b) in zip(series, series[1:]):
        if a is None or b is None:
            if (a is None) != (b is None):
                last = t
            continue
        if abs(a - b) > eps:
            last = t
    return last


def rows(trace, marks):
    evs, frames, ms = parse(trace, marks)
    out = []
    for i, (t0, label) in enumerate(ms):
        parts = label.split('.')
        if len(parts) < 3 or parts[0] != 'settle' or parts[1] not in ('show', 'hide'):
            continue
        d = parts[1]
        t1 = ms[i + 1][0] if i + 1 < len(ms) else t0 + 5
        will = next((t for t, e in evs if t0 <= t < t1 and e['ev'] == ('willShow' if d == 'show' else 'willHide')), None)
        if will is None:
            out.append({'dir': d, 'miss': 'nomove'})
            continue
        end = min(t1, will + SPAN)
        win = [(t, e) for t, e in frames if will - 0.02 <= t <= end]
        if len(win) < 5:
            out.append({'dir': d, 'miss': 'noframes'})
            continue
        height = num(win[0][1].get('win', '0x0').split('x')[1]) or 0
        kb = [(t, num(e.get('kb')) if e.get('kb') != '-' else height) for t, e in win]
        cb = [(t, num(e.get('cb'))) for t, e in win]
        cf = [(t, num(e.get('cf', ',').split(',')[1]) if 'cf' in e else None) for t, e in win]
        kb_last = last_move(kb)
        if kb_last is None:
            out.append({'dir': d, 'miss': 'kbstill'})
            continue
        c_last = max([x for x in (last_move(cb), last_move(cf)) if x is not None], default=None)
        has_content = any(v is not None for _, v in cb)
        # Frames from the notification to the keyboard's last move.
        slide = [(t, e) for t, e in win if will <= t <= kb_last + 1e-6]
        gaps = [(b[0] - a[0]) * 1000 for a, b in zip(slide, slide[1:])]
        mtb = [num(e.get('mtb')) or 0 for _, e in slide]
        rz = [int(e.get('rz', 0)) for _, e in win]
        tp = [(t, int(e['tp'])) for t, e in win if 'tp' in e]
        tp_last = None
        for (_, a), (t, b) in zip(tp, tp[1:]):
            if b != a:
                tp_last = t
        r = {
            'dir': d,
            'kb_ms': (kb_last - will) * 1000,
            'settle_ms': ((c_last - kb_last) * 1000) if c_last is not None else (None if has_content else None),
            'content': has_content,
            'content_moved': c_last is not None,
            'gap_ms': max(gaps) if gaps else None,
            'mtb_ms': max(mtb) if mtb else None,
            'rz': (rz[-1] - rz[0]) if rz else 0,
            'paint_ms': ((tp_last - kb_last) * 1000) if tp_last is not None else None,
            'presents': (tp[-1][1] - tp[0][1]) if tp else 0,
        }
        out.append(r)
    return out


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def f(x):
    return '-' if x is None else '%.0f' % x


def main(argv):
    as_json = '--json' in argv
    table = []
    for arg in argv:
        if arg.startswith('--') or '=' not in arg:
            continue
        tag, dirp = arg.split('=', 1)
        for name, files in sorted(load(dirp).items()):
            if 'kbm-trace-' not in files or 'kbm-marks-' not in files or not name.endswith('-settle'):
                continue
            surface = name[:-len('-settle')]
            rs = rows(files['kbm-trace-'], files['kbm-marks-'])
            for d in ('show', 'hide'):
                ok = [r for r in rs if r['dir'] == d and 'miss' not in r]
                miss = [r['miss'] for r in rs if r['dir'] == d and 'miss' in r]
                settle = [r['settle_ms'] if r['content_moved'] else None for r in ok]
                table.append({
                    'surface': surface, 'dir': d, 'load': tag, 'n': len(ok), 'miss': miss,
                    'kb_p50': pct([r['kb_ms'] for r in ok], .5),
                    'settle_p50': pct(settle, .5), 'settle_p95': pct(settle, .95),
                    'settle_max': pct(settle, 1.0),
                    'content_still': sum(1 for r in ok if not r['content_moved']),
                    'no_content': sum(1 for r in ok if not r['content']),
                    'gap_p50': pct([r['gap_ms'] for r in ok], .5), 'gap_p95': pct([r['gap_ms'] for r in ok], .95),
                    'mtb_p50': pct([r['mtb_ms'] for r in ok], .5), 'mtb_p95': pct([r['mtb_ms'] for r in ok], .95),
                    'rz_steps': sum(1 for r in ok if r['rz'] > 0),
                    'paint_p50': pct([r['paint_ms'] for r in ok], .5), 'paint_p95': pct([r['paint_ms'] for r in ok], .95),
                    'presents_p50': pct([r['presents'] for r in ok], .5),
                    'rows': rs if as_json else None,
                })
    if as_json:
        print(json.dumps(table, indent=1))
        return
    print('surface  dir  load   n  kb_notif->last p50 | kb_last->content_final p50/p95/max ms | content still | '
          'longest frame p50/p95 ms | mtb max/tick p50/p95 ms | resize steps | last terminal present after kb_last p50/p95 ms (presents/step)')
    for r in table:
        print('%-8s %-4s %-6s %2d  %6s | %s/%s/%s | %d (no content %d) | %s/%s | %s/%s | %d | %s/%s (%s)%s' % (
            r['surface'], r['dir'], r['load'], r['n'], f(r['kb_p50']),
            f(r['settle_p50']), f(r['settle_p95']), f(r['settle_max']), r['content_still'], r['no_content'],
            f(r['gap_p50']), f(r['gap_p95']), f(r['mtb_p50']), f(r['mtb_p95']), r['rz_steps'],
            f(r['paint_p50']), f(r['paint_p95']), f(r['presents_p50']),
            ('  miss ' + ','.join(r['miss'])) if r['miss'] else ''))


if __name__ == '__main__':
    main(sys.argv[1:])
