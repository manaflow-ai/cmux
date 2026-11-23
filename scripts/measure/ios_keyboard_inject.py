#!/usr/bin/env python3
"""Tables for KeyboardInjectBenchUITests (the keyboard bench's second input fired in-app).

Usage: python3 -I ios_keyboard_inject.py TAG=ATTACHMENTS_DIR ... [--json]
ATTACHMENTS_DIR holds manifest.json and the kbm-trace-*/kbm-marks-* attachments
(an xcresult export: ui-duress-SLUG-attachments in cmux-next-ios-sim.sh's evidence).

slide: per surface, direction and offset after willShow/willHide: n, hit-test on the
target (ok), touch delivered on the target, drag taken by the content (hide), main-thread
lag of the injection, ms to the app taking it.
tti: per surface and direction: the XCUITest command's touch, the keyboard's notification,
the keyboard drawn at its end, the injected input fired and taken, ms each.
"""
import json
import os
import statistics
import sys


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


def parse(trace, marks):
    lines = open(trace).read().split('\n')
    ep = float(lines[0].split('=')[1])
    evs = []
    for r in lines[1:]:
        if r.startswith('t=') and ' ev=' in r:
            f = r.split()
            evs.append((float(f[0][2:]), kv(f[1:])))
    ms = []
    for line in open(marks):
        p = line.split()
        if len(p) >= 4 and p[0] == 'kbm-mark':
            ms.append((float(p[1]) - ep, p[3]))
    return evs, ms


def rows(trace, marks):
    evs, ms = parse(trace, marks)
    out = []
    for i, (t0, label) in enumerate(ms):
        mode, d = label.split('.')[0], label.split('.')[1]
        if mode not in ('slide', 'tti'):
            continue
        t1 = ms[i + 1][0] if i + 1 < len(ms) else t0 + 5
        win = [(t, e) for t, e in evs if t0 <= t < t1]
        inj = next(((t, e) for t, e in win if e['ev'] == 'inject' and 'id' in e), None)
        if inj is None:
            out.append({'mode': mode, 'dir': d, 'miss': 'noinject'})
            continue
        t, e = inj
        done = [x for _, x in win if x['ev'] == 'injectDone' and x.get('id') == e['id']]
        touch = next((x for x in done if x.get('got') == 'touch'), None)
        drag = next((x for x in done if x.get('got') == 'drag'), None)
        key = next((x for x in done if x.get('got') == 'key'), None)
        r = {'mode': mode, 'dir': d, 'off': e.get('off'), 'lag': float(e.get('lag', 'nan')),
             'ok': e.get('ok') == '1', 'sent': e.get('sent') == '1', 'hit': e.get('hit'), 'tgt': e.get('tgt'),
             'touch_tgt': touch is not None and touch.get('tgt') == '1',
             'touch_ms': float(touch['ms']) if touch else None,
             'drag_trk': drag is not None and drag.get('trk') == '1',
             'key_ms': float(key['ms']) if key else None}
        if d == 'show' and mode == 'tti':
            r['taken'] = key is not None
            r['handled_ms'] = r['key_ms']
        elif d == 'show':
            r['taken'] = r['ok'] and r['touch_tgt']
            r['handled_ms'] = r['touch_ms']
        else:
            r['taken'] = r['ok'] and r['drag_trk']
            r['handled_ms'] = r['touch_ms']
        if mode == 'tti':
            cmd = next((tt for tt, x in win if x['ev'] == 'touchBegan'), None)
            will = next((tt for tt, x in win if x['ev'] == ('willShow' if d == 'show' else 'willHide')), None)
            stop = next((tt for tt, x in win if x['ev'] == 'kbStop'), None)
            if None in (cmd, will, stop):
                r['miss'] = 'noevents'
            else:
                r.update({'cmd_to_touch': 1000 * (cmd - t0), 'touch_to_will': 1000 * (will - cmd),
                          'will_to_stop': 1000 * (stop - will), 'stop_to_fired': 1000 * (t - stop),
                          'touch_to_taken': 1000 * (t - cmd) + (r['handled_ms'] or 0) if r['taken'] else None})
        out.append(r)
    return out


def pct(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return float('nan')
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def fmt(xs):
    return '%.0f / %.0f' % (pct(xs, 0.5), pct(xs, 0.95))


def tables(res):
    print('## slide: a touch during the keyboard move (in-app, trace clock)\n')
    print('| run | surface | dir | off ms | n | hit-test on target | delivered on target | drag taken | taken | lag p50/p95 ms | handled p50/p95 ms |')
    print('|---|---|---|---|---|---|---|---|---|---|---|')
    for (tag, name), rs in sorted(res.items()):
        if not name.endswith('-slide'):
            continue
        for d in ('show', 'hide'):
            for off in ('100', '200', '300', '900'):
                g = [r for r in rs if r.get('dir') == d and r.get('off') == off and 'miss' not in r]
                if not g:
                    continue
                n = len(g)
                c = lambda k: '%d/%d' % (sum(1 for r in g if r[k]), n)
                print('| %s | %s | %s | %s | %d | %s | %s | %s | %s | %s | %s |' % (
                    tag, name[:-6], d, off, n, c('ok'), c('touch_tgt'), c('drag_trk') if d == 'hide' else '-', c('taken'),
                    fmt([r['lag'] for r in g]), fmt([r['handled_ms'] for r in g])))
    print('\n## tti: the second input at the keyboard\'s stop (in-app; p50 / p95 ms)\n')
    print('| run | surface | dir | n | cmd -> touch | touch -> will | will -> kb drawn at end | stop -> input fired | input handled | touch -> taken | taken |')
    print('|---|---|---|---|---|---|---|---|---|---|---|')
    for (tag, name), rs in sorted(res.items()):
        if not name.endswith('-tti'):
            continue
        for d in ('show', 'hide'):
            g = [r for r in rs if r.get('dir') == d and 'miss' not in r]
            if not g:
                continue
            print('| %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %d/%d |' % (
                tag, name[:-4], d, len(g), fmt([r['cmd_to_touch'] for r in g]), fmt([r['touch_to_will'] for r in g]),
                fmt([r['will_to_stop'] for r in g]), fmt([r['stop_to_fired'] for r in g]),
                fmt([r['handled_ms'] for r in g]), fmt([r['touch_to_taken'] for r in g]),
                sum(1 for r in g if r['taken']), len(g)))
    misses = {f'{t}/{n}': sum(1 for r in rs if 'miss' in r) for (t, n), rs in res.items()}
    print('\nmissed steps:', {k: v for k, v in misses.items() if v} or 'none')


if __name__ == '__main__':
    res = {}
    for spec in [a for a in sys.argv[1:] if '=' in a]:
        tag, dirp = spec.split('=', 1)
        for name, f in load(dirp).items():
            if 'kbm-trace-' in f and 'kbm-marks-' in f:
                res[(tag, name)] = rows(f['kbm-trace-'], f['kbm-marks-'])
    if '--json' in sys.argv:
        json.dump({f'{t}/{n}': rs for (t, n), rs in res.items()}, sys.stdout, indent=1)
    else:
        tables(res)
