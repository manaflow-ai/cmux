#!/usr/bin/env python3
"""Tables for KeyboardInjectBenchUITests (the keyboard bench's second input fired in-app).

Usage: python3 -I ios_keyboard_inject.py TAG=ATTACHMENTS_DIR ... [--json]
ATTACHMENTS_DIR holds manifest.json and the kbm-trace-*/kbm-marks-* attachments
(an xcresult export: ui-duress-SLUG-attachments in cmux-next-ios-sim.sh's evidence).

slide: per surface, direction and offset after willShow/willHide: n, hit-test on the
target (ok), touch delivered on the target, wrong target (show: the hit-test picked a
control of the stack, not the field), the field still first responder after the tap
(injectFocus), drag taken by the content (hide), main-thread
lag of the injection, ms to the app taking it.
tti: per surface and direction: the XCUITest command's touch, the keyboard's notification,
the keyboard drawn at its end (after it was drawn off it: a frame before the move's animation
is committed reads the placeholder's model frame, already at the end), the injected input
fired and taken, ms each; on a show also a key fired right after willShow (`will` columns:
touch -> taken there is when the field takes input while the keyboard is still coming).
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
        # This step's own direction: a show whose keyboard fell at once holds
        # the hide's injection too (step cb5cfa1c: show.0 held id=1 and id=2,
        # hide.0 none), and the first injection in the window is not the step's.
        injs = [(t, e) for t, e in win if e['ev'] == 'inject' and 'id' in e and e.get('dir', d) == d]
        at_will = next(((t, e) for t, e in injs if e.get('off') == 'will'), None)
        inj = next(((t, e) for t, e in injs if e.get('off') != 'will'), None)
        if inj is None:
            # Why: the keyboard never moved this way in the step (the test's
            # command brought no keyboard, or it was already gone), the
            # injector skipped (no field to touch), or it did not fire.
            moved = any(e['ev'] == ('willShow' if d == 'show' else 'willHide') for _, e in win)
            skip = next((e for _, e in win if e['ev'] == 'injectSkip' and e.get('dir', d) == d), None)
            why = 'skip:' + skip.get('why', '?') if skip else 'noinject' if moved else 'nomove'
            out.append({'mode': mode, 'dir': d, 'miss': why})
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
        # A wrong target: the hit-test missed the field and picked a control
        # of the stack (a button, the glass's tap interaction), which a tap
        # activates. A miss on a bare view only drops the tap.
        hit = e.get('hit') or ''
        r['wrong'] = d == 'show' and not r['ok'] and any(k in hit for k in ('Button', 'Control', 'Interaction'))
        focus = next((x for _, x in win if x['ev'] == 'injectFocus' and x.get('id') == e['id']), None)
        r['focused'] = None if focus is None else focus.get('fr') == '1'
        if d == 'show' and mode == 'tti':
            r['taken'] = key is not None
            r['handled_ms'] = r['key_ms']
        elif d == 'show':
            r['taken'] = r['ok'] and r['touch_tgt']
            r['handled_ms'] = r['touch_ms']
        else:
            # A drag is taken when a scroll or pan under the finger drags.
            r['taken'] = r['sent'] and r['drag_trk']
            r['handled_ms'] = r['touch_ms']
        if at_will is not None:
            tw, ew = at_will
            kw = next((x for _, x in win if x['ev'] == 'injectDone' and x.get('id') == ew['id'] and x.get('got') == 'key'), None)
            r['will_taken'] = kw is not None
            r['will_handled_ms'] = float(kw['ms']) if kw else None
            r['will_fired'] = tw
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
                if 'will_fired' in r:
                    r['will_to_fired'] = 1000 * (r['will_fired'] - will)
                    r['will_touch_to_taken'] = 1000 * (r['will_fired'] - cmd) + r['will_handled_ms'] if r['will_taken'] else None
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
    print('| run | surface | dir | off ms | n | hit-test on target | delivered on target | wrong target | field focused after | drag taken | taken | lag p50/p95 ms | handled p50/p95 ms |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
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
                fg = [r for r in g if r['focused'] is not None]
                focused = '%d/%d' % (sum(1 for r in fg if r['focused']), len(fg)) if d == 'show' and fg else '-'
                print('| %s | %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                    tag, name[:-6], d, off, n, c('ok'), c('touch_tgt'), c('wrong') if d == 'show' else '-', focused,
                    c('drag_trk') if d == 'hide' else '-', c('taken'),
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
    print('\n## tti at will: a key fired right after willShow (in-app; p50 / p95 ms)\n')
    print('| run | surface | n | touch -> will | will -> input fired | input handled | touch -> taken | taken |')
    print('|---|---|---|---|---|---|---|---|')
    for (tag, name), rs in sorted(res.items()):
        if not name.endswith('-tti'):
            continue
        g = [r for r in rs if r.get('dir') == 'show' and 'miss' not in r and 'will_fired' in r]
        if not g:
            continue
        print('| %s | %s | %d | %s | %s | %s | %s | %d/%d |' % (
            tag, name[:-4], len(g), fmt([r['touch_to_will'] for r in g]),
            fmt([r['will_to_fired'] for r in g]),
            fmt([r['will_handled_ms'] for r in g]), fmt([r['will_touch_to_taken'] for r in g]),
            sum(1 for r in g if r['will_taken']), len(g)))
    misses = {f'{t}/{n}': sum(1 for r in rs if 'miss' in r) for (t, n), rs in res.items()}
    print('\nmissed steps:', {k: v for k, v in misses.items() if v} or 'none')
    # By reason and direction: nomove (no willShow/willHide in the step: the
    # test's command moved no keyboard), skip:WHY (the injector declined),
    # noinject (the keyboard moved and nothing fired), noevents (tti).
    for (t, n), rs in sorted(res.items()):
        why = {}
        for r in rs:
            if 'miss' in r:
                k = '%s/%s' % (r['dir'], r['miss'])
                why[k] = why.get(k, 0) + 1
        if why:
            print('  %s/%s: %s' % (t, n, ', '.join('%s %d' % kv for kv in sorted(why.items()))))


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
