#!/usr/bin/env python3
"""Frame table for BrowserButtonMotionBenchUITests.

Usage: python3 -I ios_browser_button.py TAG=ATTACHMENTS_DIR ... [--window 0.9]
ATTACHMENTS_DIR holds manifest.json with kbm-trace-browser / kbm-marks-browser (ui-duress-SLUG-attachments).
Per step (grid.open, card.open): n, frames over 8.3 ms (gap between consecutive display-link ticks, in the
window after the mark), worst gap, the observed frame interval (median), main-thread busy per frame (mean,
p95, max of mtb=). A simulator's link may not run at 120 Hz: the interval column says what it did.
"""
import json
import os
import statistics
import sys


def load(dirp):
    out = {}
    for t in json.load(open(os.path.join(dirp, 'manifest.json'))):
        for a in t.get('attachments', []):
            n = a.get('suggestedHumanReadableName', '')
            for kind in ('kbm-trace-browser', 'kbm-marks-browser'):
                if n.startswith(kind):
                    out[kind] = os.path.join(dirp, a['exportedFileName'])
    return out


def frames(path):
    lines = open(path).read().split('\n')
    ep = float(lines[0].split('=')[1])
    fr = []
    for r in lines[1:]:
        if r.startswith('t=') and ' mtb=' in r:
            f = dict(x.split('=', 1) for x in r.split() if '=' in x)
            fr.append((float(f['t']), float(f['mtb'])))
    return ep, fr


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else float('nan')


def main():
    win = 0.9
    if '--window' in sys.argv:
        win = float(sys.argv[sys.argv.index('--window') + 1])
    print('| run | step | n | frames | interval ms (median) | frames >8.3 ms | share | worst gap ms | gap p95 ms | busy/frame mean ms | busy p95 | busy max |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    for spec in [a for a in sys.argv[1:] if '=' in a and not a.startswith('--')]:
        tag, d = spec.split('=', 1)
        f = load(d)
        ep, fr = frames(f['kbm-trace-browser'])
        marks = []
        for line in open(f['kbm-marks-browser']):
            p = line.split()
            if len(p) >= 4 and p[0] == 'kbm-mark':
                marks.append((float(p[1]) - ep, p[3]))
        for step in ('grid.open', 'card.open'):
            gaps, busy, n = [], [], 0
            for t0, label in marks:
                if not label.startswith(step + '.'):
                    continue
                n += 1
                w = [x for x in fr if t0 <= x[0] < t0 + win]
                gaps += [(b[0] - a[0]) * 1000 for a, b in zip(w, w[1:])]
                busy += [x[1] for x in w]
            if not gaps:
                continue
            over = sum(1 for g in gaps if g > 8.3)
            print('| %s | %s | %d | %d | %.2f | %d | %.0f%% | %.1f | %.1f | %.2f | %.1f | %.1f |' % (
                tag, step, n, len(gaps), statistics.median(gaps), over, 100 * over / len(gaps), max(gaps),
                pct(gaps, .95), statistics.mean(busy), pct(busy, .95), max(busy)))


if __name__ == '__main__':
    main()
