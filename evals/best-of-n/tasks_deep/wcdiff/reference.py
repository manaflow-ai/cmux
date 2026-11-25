"""Line diffs for the agent's "changes" panel and for `cmux diff` between two snapshots of a file.

An edit script is a list of (op, line) pairs: op "=" for a line both sides share, "-" for a line only in `a`,
"+" for a line only in `b`. Reading the "=" and "-" lines in order gives `a`; reading the "=" and "+" lines gives
`b`. Scripts are minimal: they keep as many shared lines as possible.

House rules the panel relies on:
- Lines are compared with one trailing "\\r" removed, so a CRLF and an LF copy of the same text are equal. An "="
  pair carries the line as it is in `b` (the panel shows the new file's bytes).
- Within each run of consecutive changes, every "-" comes before every "+" (a replaced block reads as the old
  lines, then the new ones), each kind in its original order.
"""


def _norm(line: str) -> str:
    return line[:-1] if line.endswith("\r") else line


def _group(script):
    """Reorder each run of changes so its removals come before its additions."""
    out, minus, plus = [], [], []
    for op, line in script:
        if op == "=":
            out += minus + plus
            minus, plus = [], []
            out.append((op, line))
        elif op == "-":
            minus.append((op, line))
        else:
            plus.append((op, line))
    return out + minus + plus


def _myers(na, nb):
    """Shortest edit script on normalized lines, as ops "=", "-", "+" with indexes (Myers' O((N+M)D) algorithm)."""
    n, m = len(na), len(nb)
    maxd = n + m
    v = {1: 0}
    trace = []
    for d in range(maxd + 1):
        trace.append(dict(v))
        for k in range(-d, d + 1, 2):
            if k == -d or (k != d and v[k - 1] < v[k + 1]):
                x = v[k + 1]
            else:
                x = v[k - 1] + 1
            y = x - k
            while x < n and y < m and na[x] == nb[y]:
                x += 1
                y += 1
            v[k] = x
            if x >= n and y >= m:
                return _backtrack(trace, n, m, d)
    raise AssertionError("unreachable")


def _backtrack(trace, n, m, d_end):
    ops = []
    x, y = n, m
    for d in range(d_end, -1, -1):
        v = trace[d]
        k = x - y
        if d == 0:
            prev_k = None
        elif k == -d or (k != d and v[k - 1] < v[k + 1]):
            prev_k = k + 1
        else:
            prev_k = k - 1
        if prev_k is None:
            px, py = 0, 0
        else:
            px = v[prev_k]
            py = px - prev_k
        start_x = px if prev_k is None else (px if prev_k == k + 1 else px + 1)
        start_y = start_x - k
        while x > start_x and y > start_y:
            x -= 1
            y -= 1
            ops.append(("=", x, y))
        if prev_k is not None:
            if prev_k == k + 1:
                y -= 1
                ops.append(("+", x, y))
            else:
                x -= 1
                ops.append(("-", x, y))
    ops.reverse()
    return ops


def diff_lines(a: list[str], b: list[str]) -> list[tuple[str, str]]:
    """A minimal edit script turning `a` into `b`."""
    na, nb = [_norm(x) for x in a], [_norm(x) for x in b]
    lo = 0
    while lo < len(na) and lo < len(nb) and na[lo] == nb[lo]:
        lo += 1
    hi = 0
    while hi < len(na) - lo and hi < len(nb) - lo and na[-1 - hi] == nb[-1 - hi]:
        hi += 1
    script = [("=", line) for line in b[:lo]]
    for op, i, j in _myers(na[lo:len(na) - hi], nb[lo:len(nb) - hi]):
        script.append((op, b[lo + j] if op != "-" else a[lo + i]))
    script += [("=", line) for line in b[len(b) - hi:]]
    return _group(script)


def diff_text(old: str, new: str) -> list[tuple[str, str]]:
    """`diff_lines` over the lines of two texts (split on "\\n"; a trailing "\\n" does not make an extra line)."""
    def lines(s):
        parts = s.split("\n")
        return parts[:-1] if parts and parts[-1] == "" else parts
    return diff_lines(lines(old), lines(new))


def stats(script) -> tuple[int, int]:
    """(added, removed) line counts of an edit script."""
    return sum(op == "+" for op, _ in script), sum(op == "-" for op, _ in script)


def hunks(script, context: int = 3) -> list[tuple[int, int, int, int]]:
    """Change regions as (a_start, a_len, b_start, b_len), 0-based, each widened by up to `context` shared lines
    on both sides; regions whose context touches or overlaps are merged."""
    regions = []
    ia = ib = 0
    for op, _ in script:
        if op == "=":
            ia += 1
            ib += 1
            continue
        if regions and regions[-1][1] == ia and regions[-1][3] == ib:
            r = regions[-1]
        else:
            r = [ia, ia, ib, ib]
            regions.append(r)
        if op == "-":
            ia += 1
            r[1] = ia
        else:
            ib += 1
            r[3] = ib
    total_a, total_b = ia, ib
    out = []
    for a0, a1, b0, b1 in regions:
        lo = min(context, a0, b0)
        hi = min(context, total_a - a1, total_b - b1)
        a0, b0, a1, b1 = a0 - lo, b0 - lo, a1 + hi, b1 + hi
        if out and out[-1][0] + out[-1][1] >= a0:
            pa, _, pb, _ = out[-1]
            out[-1] = (pa, a1 - pa, pb, b1 - pb)
        else:
            out.append((a0, a1 - a0, b0, b1 - b0))
    return out
