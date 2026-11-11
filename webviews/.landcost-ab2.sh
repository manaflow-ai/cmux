set -u
cd webviews
A=src/agent-session/acpmux
cp -R $A /tmp/after-acpmux
git checkout HEAD -- $A
for i in 1 2 3; do echo "== BEFORE run $i"; TURNS=600 ENGINES=chromium,webkit bun bench/transcript-scroll-up.bench.ts 2>&1 | grep -E "transcript-scroll-up (chromium|webkit) [a-zA-Z0-9]+: " ; done
rm -rf $A && cp -R /tmp/after-acpmux $A
for i in 1 2 3; do echo "== AFTER run $i"; TURNS=600 ENGINES=chromium,webkit bun bench/transcript-scroll-up.bench.ts 2>&1 | grep -E "transcript-scroll-up (chromium|webkit) [a-zA-Z0-9]+: " ; done
echo "== AFTER writes"; LANDINGS=1 TURNS=600 ENGINES=chromium bun bench/transcript-scroll-up.bench.ts 2>&1 | grep "landing gap" | sed 's/ | .*//' | head -25
echo "== tsc"; bunx tsc --noEmit -p . 2>&1 | tail -5
