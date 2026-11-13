#!/usr/bin/env bash
# Fleet-only production build + browser evidence. Dispatch ONCE through cmux-ci test.
# Example (after integrating/pushing this harness):
# cmux-ci test --at HEAD --setup webviews --timeout 3600 --artifact /tmp/runtime-proof -- \
#   bash scripts/cmux-next/tests/shared-react-runtime-bench.sh --baseline SHA --candidate SHA
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
BASELINE=""
CANDIDATE=""
OUT="${CMUX_TEST_ARTIFACT_DIR:-${FAST_CHECKS_OUT:-/tmp}/runtime-proof}"
SAMPLES=20
while (($#)); do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --candidate) CANDIDATE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    *) echo "usage: $0 --baseline SHA --candidate SHA [--out DIR] [--samples N]" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo 'Run on cmux-ci Linux'; exit 2; }
[[ "$BASELINE" =~ ^[0-9a-f]{40}$ && "$CANDIDATE" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Both exact 40-character source pins are required' >&2; exit 2;
}
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || exit 2
[[ "$OUT" != *'$'* && "$OUT" = /* ]] || { echo "invalid artifact output path: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ ! -e "$OUT/requested-source-pins.txt" ]] || {
  echo "Use a fresh artifact directory; existing receipt: $OUT/requested-source-pins.txt" >&2; exit 2;
}
# Never mistake cmux-ci's wrapper snapshot SHA for the requested source SHA.
git rev-parse HEAD 'HEAD^{tree}' > "$OUT/wrapper-snapshot.txt"
printf '%s\n' "$BASELINE" "$CANDIDATE" > "$OUT/requested-source-pins.txt"
on_exit() {
  rc=$?
  printf "%s\n" "$rc" > "$OUT/exit-code.txt"
  if [[ -s "$OUT/summary.json" ]]; then
    echo "shared React runtime proof summary:"
    node -e 'const s=require(process.argv[1]); console.log(JSON.stringify({status:s.status,bytes:s.bytes,timing:s.timing.map(({surface,baseline,candidate,p95DeltaMs})=>({surface,baseline,candidate,p95DeltaMs})),runtimeProbes:s.runtimeProbes}))' "$OUT/summary.json"
  fi
  if (( rc != 0 )); then
    for log in "$OUT"/baseline/build.log "$OUT"/candidate/build.log "$OUT/browser.log"; do
      [[ -f "$log" ]] || continue
      echo "--- tail $log ---"
      tail -n 30 "$log"
    done
  fi
}
trap on_exit EXIT
WORK="$(mktemp -d /tmp/cmux-shared-runtime-sources.XXXXXX)"
printf '%s\n' "$WORK" > "$OUT/source-directory.txt"
# Preserve owned source/build trees for diagnosis; no broad cleanup of fleet paths.
for variant in baseline candidate; do
  if [[ "$variant" == baseline ]]; then pin="$BASELINE"; else pin="$CANDIDATE"; fi
  if ! git -C "$ROOT" cat-file -e "$pin^{commit}" 2>/dev/null; then
    git -C "$ROOT" fetch origin "$pin"
  fi
  git -C "$ROOT" rev-parse "$pin" "$pin^{tree}" > "$OUT/$variant-source.txt"
  mkdir -p "$WORK/$variant" "$OUT/$variant/metafiles" "$OUT/$variant/bundles"
  git -C "$ROOT" archive "$pin" | tar -x -C "$WORK/$variant"
  (
    cd "$WORK/$variant"
    # Cheap CJS edge probe before the full production build: the shared externalizer must leave a
    # browser-resolvable React import for use-sync-external-store's CommonJS shim.
    (cd webviews && bun install --frozen-lockfile >/dev/null)
    printf '%s\n' 'import "use-sync-external-store/shim";' > webviews/.shared-react-cjs-smoke.mjs
    (cd webviews && CMUX_SHARED_REACT_RUNTIME_OUT="$OUT/$variant/bundles/Resources/markdown-viewer/webviews-app/__runtime" \
      bun scripts/agent-pane/bundle.mjs .shared-react-cjs-smoke.mjs - "$OUT/$variant/cjs-react-smoke.js")
    if [[ "$variant" == candidate ]]; then
      grep -q '/__runtime/react.js' "$OUT/$variant/cjs-react-smoke.js" || {
        echo "$variant: CJS React smoke did not resolve the shared runtime" >&2; exit 1;
      }
    elif grep -q '/__runtime/react.js' "$OUT/$variant/cjs-react-smoke.js"; then
      echo "$variant: baseline unexpectedly externalized React" >&2; exit 1
    fi
    # No synthetic esbuild entry: exercise all production compiler, JSON and CSS plugins.
    bash scripts/cmux-next/build-web-bundles.sh \
      --out-root "$OUT/$variant/bundles" --report-dir "$OUT/$variant/metafiles"
  ) > "$OUT/$variant/build.log" 2>&1
done
{
  node --version
  bun --version
  uname -a
} > "$OUT/toolchain.txt"
bash "$ROOT/scripts/ci/ensure-system-chrome.sh" > "$OUT/chrome-install.log" 2>&1
# GITHUB_ENV takes effect only in the next job step. Export the emitted path here too.
chrome_shell="$(sed -n 's/^CMUX_CHROME_HEADLESS_SHELL=//p' "$OUT/chrome-install.log" | tail -n 1)"
if [[ -n "$chrome_shell" ]]; then export CMUX_CHROME_HEADLESS_SHELL="$chrome_shell"; fi
cd "$ROOT/webviews"
bun scripts/shared-react-runtime-bench.mjs \
  --baseline "$BASELINE" --candidate "$CANDIDATE" --out "$OUT" --samples "$SAMPLES" \
  > "$OUT/browser.log" 2>&1
