#!/usr/bin/env python3
"""grid-menu-restore-check.py PNG HEX LABEL APP < describe-ui JSON: grid-menu-restore.sh's
check (the long-pressed card is drawn in its slot and is in the accessibility tree)."""
import json, subprocess, sys

png, hexc, label, app = sys.argv[1:5]


def walk(n):
    if isinstance(n, list):
        for x in n:
            yield from walk(x)
        return
    yield n
    for ch in n.get('children') or []:
        yield from walk(ch)


try:
    nodes = list(walk(json.loads(sys.stdin.read())))
except Exception:
    nodes = []
problems = []
if not any((n.get('AXLabel') or '').startswith(label) for n in nodes):
    problems.append(f'no "{label}" element')
if hexc != '-':
    # Its header in row 1 (header y 122-150 pt; Close Other Tabs moves it left).
    w, h = 402 * 3, 874 * 3
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', png, '-vf', f'scale={w}:{h}', '-f', 'rawvideo',
                          '-pix_fmt', 'rgb24', '-'], capture_output=True).stdout
    c = [int(hexc[i:i + 2], 16) for i in (0, 2, 4)]
    hits = 0
    if len(raw) == w * h * 3:
        for y in range(124 * 3, 148 * 3, 3):
            row = raw[(y * w + 16 * 3) * 3:(y * w + 386 * 3) * 3]
            hits += sum(1 for k in range(0, len(row), 9) if all(abs(row[k + j] - c[j]) < 28 for j in range(3)))
    if hits < 200:
        problems.append(f'its header is not drawn ({hits} px)')
print('ok' if not problems else '; '.join(problems))
