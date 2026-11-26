set -o pipefail
bash scripts/ci/ensure-system-chrome.sh >/dev/null 2>&1
cd webviews && bun install --frozen-lockfile >/dev/null
row() { bun bench/composer-typing.bench.ts --mode L0 --engines chromium --lengths 60 --keys 500 --gap 20 2>&1 | grep -o 'COMPOSER-TYPING .*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import json,sys
for r in json.load(sys.stdin): print("ROW",sys.argv[1],{k:r.get(k) for k in ["mode","valid","painted_keys","to_frame_p95","to_paint_p95","to_paint_p99","keys_missed_refresh","keys_sharing_frame"]})' "$1"; }
for i in 1 2 3; do row base; done
sed -i 's/"position:fixed;left:0;top:0;width:1px;height:1px;overflow:hidden;"/"position:absolute;left:0;top:0;width:1px;height:1px;overflow:hidden;"/' src/agent-session/acpmux/keyPresentation.ts
grep -c 'position:absolute;left:0;top:0;width:1px' src/agent-session/acpmux/keyPresentation.ts
for i in 1 2 3; do row absglyph; done
