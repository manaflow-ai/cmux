# Scratch: per update_one row and tree, the median over rounds of the run's p95 and p50 (ms).
#   python3 summ.py OUTDIR TAG...
import glob
import re
import statistics as st
import sys
from collections import defaultdict

pat = re.compile(r"^(home|chat) (\w+) n=(\d+): p50 ([\d.]+) ms p95 ([\d.]+) ms")
out, tags = sys.argv[1], sys.argv[2:]
rows = defaultdict(lambda: defaultdict(list))
for tag in tags:
    for path in sorted(glob.glob(f"{out}/{tag}-r*.log")):
        for line in open(path, errors="replace"):
            m = pat.match(line)
            if m:
                rows[f"{m[1]}.{m[2]}.n{m[3]}"][tag].append((float(m[4]), float(m[5])))
print("row".ljust(18) + "".join(f"{t:>26}" for t in tags))
print("(each cell: median p95 [min-max of p95] / median p50)")
for row in sorted(rows):
    cells = []
    for tag in tags:
        v = rows[row][tag]
        if not v:
            cells.append(" " * 26)
            continue
        p95 = [x[1] for x in v]
        cells.append(f"{st.median(p95):6.2f} [{min(p95):.1f}-{max(p95):.1f}] /{st.median(x[0] for x in v):5.2f}".rjust(26))
    print(row.ljust(18) + "".join(cells))
