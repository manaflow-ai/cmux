#!/usr/bin/env bash
# chat-100k-flat-sweep.sh [rows...]: chat-100k-flat.bench.ts at each row count (default 1000 10000 100000), one launch
# set after another, then the cost per row of each reading: a least-squares line of value over rows per case
# (renderer MB as KB/row, idle and streaming CPU as % of a core per 1k rows) and each ratio at each count. A ratio
# says how far from flat a chat is; the slope says what each row costs, which is what a cut has to remove
# (cmuxterm-hq goals/chats-flat-at-any-length.md, "Report the slope per row").
# The bench's own env passes through (CASES, CHATS, IDLE_S, STREAM_S, REPEAT, PROFILE, HEAP_RETAINERS, ...).
# OUT=DIR keeps each count's log (default a temp dir). Linux only, like the bench.
#   CASES=grown-many bench/chat-100k-flat-sweep.sh 1000 10000 100000
set -euo pipefail
cd "$(dirname "$0")/.."
rows=("$@")
[ ${#rows[@]} -gt 0 ] || rows=(1000 10000 100000)
chats="${CHATS:-20}"
out="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/chat-100k-flat-sweep-XXXX")}"
mkdir -p "$out"
for r in "${rows[@]}"; do
  echo "chat-100k-flat-sweep: rows $r chats $chats CASES=${CASES:-all} -> $out/rows-$r.log" >&2
  bun bench/chat-100k-flat.bench.ts "$r" "$chats" 2>&1 | tee "$out/rows-$r.log" | grep -E '^PERF_ROW .*(ratio|_cpu_pct"|renderer_mb"|heap_mb")' || true
done
python3 - "$out" "${rows[@]}" <<'PY'
import json, re, sys
out, rows = sys.argv[1], [int(r) for r in sys.argv[2:]]
vals = {}
for r in rows:
    for line in open(f"{out}/rows-{r}.log", errors="replace"):
        if line.startswith("PERF_ROW "):
            row = json.loads(line[9:])
            vals.setdefault(row["name"], {})[r] = row["p50"]
def fit(pts):
    xs, ys = zip(*pts)
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    return (sum((x - mx) * (y - my) for x, y in pts) / sxx) if sxx else 0.0
print("\nname | " + " | ".join(f"{r} rows" for r in rows) + " | slope")
for name in sorted(vals):
    m = re.search(r"\.(idle_cpu_pct|stream_cpu_pct|renderer_mb|heap_mb|[a-z_]*ratio[a-z_]*)$", name)
    if not m:
        continue
    per = vals[name]
    pts = [(r, per[r]) for r in rows if r in per]
    cells = " | ".join(f"{per[r]:.3f}" if r in per else "-" for r in rows)
    slope = ""
    if len(pts) >= 2 and "ratio" not in m.group(1):
        s = fit(pts)
        slope = f"{s * 1024:.4f} KB/row" if m.group(1).endswith("_mb") else f"{s * 1000:.4f} %core/1k rows"
    print(f"{name} | {cells} | {slope}")
PY
