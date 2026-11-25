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


def diff_lines(a: list[str], b: list[str]) -> list[tuple[str, str]]:
    """A minimal edit script turning `a` into `b`."""
    na, nb = [_norm(x) for x in a], [_norm(x) for x in b]
    n, m = len(na), len(nb)
    # lcs[i][j]: length of the longest common subsequence of na[i:] and nb[j:]
    lcs = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        row, below = lcs[i], lcs[i + 1]
        for j in range(m - 1, -1, -1):
            if na[i] == nb[j]:
                row[j] = below[j + 1] + 1
            else:
                row[j] = max(below[j], row[j + 1])
    script = []
    i = j = 0
    while i < n and j < m:
        if na[i] == nb[j]:
            script.append(("=", b[j]))
            i += 1
            j += 1
        elif lcs[i + 1][j] >= lcs[i][j + 1]:
            script.append(("-", a[i]))
            i += 1
        else:
            script.append(("+", b[j]))
            j += 1
    script += [("-", x) for x in a[i:]]
    script += [("+", x) for x in b[j:]]
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
