#!/usr/bin/env bash
# A/B of the lazy cuts on one runner: after (this tree), then before (the cuts reverted), then after again.
set -uo pipefail
cd "$(dirname "$0")/.."
out=${FAST_CHECKS_OUT:-/tmp/ab}
echo "=== AFTER (CPU=${CPU:-1}) ==="
SHOTS=$out/after ROUNDS=${ROUNDS:-5} bun bench/home-pane-imports.bench.ts; echo "after rc=$?"
git -C .. apply -R webviews/bench/.lazy-cut.patch 2>/dev/null || (cd .. && patch -R -p1 < webviews/bench/.lazy-cut.patch); echo "revert rc=$?"
echo "=== BEFORE (CPU=${CPU:-1}) ==="
SHOTS=$out/before ROUNDS=${ROUNDS:-5} bun bench/home-pane-imports.bench.ts; echo "before rc=$?"
python3 - "$out" <<'PY'
import hashlib,sys,os
o=sys.argv[1]
for p in ("home-channels","home-messages"):
    h=[hashlib.sha256(open(f"{o}/{s}/{p}-settled.png","rb").read()).hexdigest()[:16] if os.path.exists(f"{o}/{s}/{p}-settled.png") else "missing" for s in ("before","after")]
    print(f"screenshot {p}: before {h[0]} after {h[1]} {'IDENTICAL' if h[0]==h[1] else 'DIFFERENT'}")
PY
