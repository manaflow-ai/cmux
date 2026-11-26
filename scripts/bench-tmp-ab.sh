set -o pipefail
bash scripts/ci/ensure-system-chrome.sh >/dev/null 2>&1
cd webviews && bun install --frozen-lockfile >/dev/null 2>&1
row() {
  bun bench/composer-typing.bench.ts --mode L0 --engines chromium --lengths 60 --keys 500 --gap 20 > /tmp/b.out 2>&1
  echo "bench exit $?"
  grep -E 'rror' /tmp/b.out | head -5 | cut -c1-400
  grep 'COMPOSER-TYPING \[' /tmp/b.out | head -1 | grep -oE '"(to_frame_p95|to_paint_p50|to_paint_p95|to_paint_p99|keys_missed_refresh|keys_sharing_frame|painted_keys|valid)":[a-z0-9.]+' | tr '\n' ' ' | sed "s/^/ROW $1 /"; echo
}
for i in 1 2 3; do row base; done
sed -i 's/"position:fixed;left:0;top:0;width:1px;height:1px;overflow:hidden;"/"position:absolute;left:0;top:0;width:1px;height:1px;overflow:hidden;"/' src/agent-session/acpmux/keyPresentation.ts
grep -c 'position:absolute;left:0;top:0;width:1px' src/agent-session/acpmux/keyPresentation.ts
for i in 1 2 3; do row absglyph; done
