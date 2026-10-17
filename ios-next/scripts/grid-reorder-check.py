#!/usr/bin/env python3
"""grid-reorder-check.py PNG HEX FX FY WANT [MODE] < describe-ui JSON: grid-reorder.sh's check.

MODE move (left, right): the dragged card under the finger mid-drag; the
order and count after the drop. MODE menu (up): Safari's menu keeps the
touch, so no drag: the order is unchanged. MODE select (down): no drag, and
the release over the menu ran the row under the finger (Select Tabs)."""
import json, subprocess, sys
png, hexc, fx, fy, want = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5].split('|')
mode = sys.argv[6] if len(sys.argv) > 6 else 'move'
# The dragged card's header near the finger (points; 3 px per point).
w, h = 402 * 3, 874 * 3
try:
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', png, '-vf', f'scale={w}:{h}', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True).stdout
except FileNotFoundError:
    raw = b''
c = [int(hexc[i:i + 2], 16) for i in (0, 2, 4)] if hexc != '-' else [0, 0, 0]
hits = 0
if len(raw) == w * h * 3:
    x0, x1 = int(max(0, fx - 110) * 3), int(min(402, fx + 110) * 3)
    y0, y1 = int(max(0, fy - 200) * 3), int(min(874, fy + 40) * 3)
    for y in range(y0, y1, 3):
        row = raw[(y * w + x0) * 3:(y * w + x1) * 3]
        for k in range(0, len(row), 9):
            if all(abs(row[k + j] - c[j]) < 60 for j in range(3)):
                hits += 1
def walk(n):
    if isinstance(n, list):
        for x in n: yield from walk(x)
        return
    yield n
    for ch in n.get('children') or []: yield from walk(ch)
try:
    nodes = list(walk(json.loads(sys.stdin.read())))
except Exception:
    nodes = []
cards = sorted(((n['frame']['y'], n['frame']['x'], n['AXLabel']) for n in nodes
                if (n.get('AXLabel') or '').endswith(', tab') or 'debounce resize' in (n.get('AXLabel') or '')),
               key=lambda t: (round(t[0]), t[1]))
order = [next((wnt for wnt in want if lab.startswith(wnt)), lab[:20]) for _, _, lab in cards]
count = any(n.get('AXLabel') == '5 Tabs' for n in nodes)
problems = []
if mode == 'move' and hexc != '-' and hits < 40: problems.append(f'no dragged card under the finger ({hits} header px)')
selected = any((n.get('AXLabel') or '').endswith(' selected') for n in nodes)
if mode == 'select' and not selected: problems.append('the release ran no menu row (not in Select Tabs)')
if not count: problems.append('not 5 Tabs')
if order != want: problems.append('order ' + ' | '.join(order))
print('ok' if not problems else '; '.join(problems))
