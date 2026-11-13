#!/usr/bin/env bash
# Run once through cmux-ci Linux. The caller owns the baseline and candidate pins.
# bash scripts/cmux-next/tests/pages-size-open-bench.sh --baseline SHA --candidate SHA
# Artifacts default to the fleet's FAST_CHECKS_OUT/pages-proof (expanded here, not by the caller).
set -euo pipefail
BASELINE=""
CANDIDATE=""
OUT=""
SAMPLES=20
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then OUT="${FAST_CHECKS_OUT%/}/pages-proof"; fi
while (($#)); do
  case "$1" in
    --baseline|--candidate|--out|--samples)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --baseline) BASELINE="$2" ;;
        --candidate) CANDIDATE="$2" ;;
        --out) OUT="$2" ;;
        --samples) SAMPLES="$2" ;;
      esac
      shift 2 ;;
    *) echo "usage: $0 --baseline SHA --candidate SHA [--out ABSOLUTE_DIR] [--samples N]" >&2; exit 2 ;;
  esac
done
# Validate BEFORE mkdir: a literal '$FAST_CHECKS_OUT' must never become a checkout directory.
case "$OUT" in /*) ;; *) echo 'OUT must be absolute; set FAST_CHECKS_OUT or pass --out' >&2; exit 2 ;; esac
case "$OUT" in *'$'*) echo 'OUT contains an unexpanded dollar expression' >&2; exit 2 ;; esac
[[ "$OUT" != / ]] || { echo 'OUT cannot be /' >&2; exit 2; }
[[ "$BASELINE" =~ ^[0-9a-f]{40}$ && "$CANDIDATE" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Both full 40-character source pins are required' >&2; exit 2;
}
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || { echo 'samples must be positive' >&2; exit 2; }
[[ "$(uname -s)" == Linux ]] || { echo 'Run on cmux-ci Linux' >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"
[[ ! -e "$OUT/pins.json" ]] || { echo "Use a fresh receipt directory: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ACTIVE_LOG=""
STAGE=prepare
finish() {
  rc=$?
  printf '%s\n' "$rc" > "$OUT/exit-code.txt"
  if ((rc)); then
    printf 'pages-proof failed: stage=%s exit=%s artifacts=%s\n' "$STAGE" "$rc" "$OUT" >&2
    if [[ -n "$ACTIVE_LOG" && -f "$ACTIVE_LOG" ]]; then tail -n 60 "$ACTIVE_LOG" >&2; fi
  fi
}
trap finish EXIT
WORK="$(mktemp -d /tmp/cmux-pages-proof.XXXXXX)"
printf '%s\n' "$WORK" > "$OUT/source-directory.txt"
git -C "$ROOT" rev-parse HEAD 'HEAD^{tree}' > "$OUT/wrapper-snapshot.txt"
python3 - "$OUT" "$BASELINE" "$CANDIDATE" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1], "pins.json").write_text(json.dumps({"baseline": sys.argv[2], "candidate": sys.argv[3]}, indent=2) + "\n")
PY
for variant in baseline candidate; do
  if [[ "$variant" == baseline ]]; then pin="$BASELINE"; else pin="$CANDIDATE"; fi
  STAGE="$variant source"
  # A missing pin comes from origin into the real checkout (not a fixture repo; it needs the user's git auth).
  # Auto maintenance stays off so no detached gc is still writing .git while the bench runs.
  if ! git -C "$ROOT" cat-file -e "$pin^{commit}" 2>/dev/null; then git -C "$ROOT" -c maintenance.auto=false fetch origin "$pin"; fi
  git -C "$ROOT" rev-parse "$pin" "$pin^{tree}" > "$OUT/$variant-source.txt"
  mkdir -p "$WORK/$variant" "$OUT/$variant/metafiles"
  git -C "$ROOT" archive "$pin" | tar -x -C "$WORK/$variant"
  STAGE="$variant production Pages build"
  ACTIVE_LOG="$OUT/$variant/build.log"
  (
    cd "$WORK/$variant/webviews"
    unset CMUX_SHARED_REACT_RUNTIME_OUT CMUX_STRINGS_BEST_EFFORT
    bun install --frozen-lockfile
    # Production builder generates strings from this exact tree and runs its real CSS/JS plugins.
    CMUX_PAGES_METAFILE="$OUT/$variant/metafiles/pages.json" \
      bash ../scripts/cmux-next/build-pages-web.sh --out "$OUT/$variant/pages"
  ) > "$ACTIVE_LOG" 2>&1
  printf 'pages-proof built %s %s\n' "$variant" "$pin"
done
STAGE='browser provisioning'
ACTIVE_LOG="$OUT/chrome-install.log"
bash "$ROOT/scripts/ci/ensure-system-chrome.sh" > "$ACTIVE_LOG" 2>&1
chrome_shell="$(sed -n 's/^CMUX_CHROME_HEADLESS_SHELL=//p' "$ACTIVE_LOG" | tail -n 1)"
if [[ -n "$chrome_shell" ]]; then export CMUX_CHROME_HEADLESS_SHELL="$chrome_shell"; fi
{ node --version; bun --version; uname -a; } > "$OUT/toolchain.txt"
STAGE='Pages browser measurement'
ACTIVE_LOG="$OUT/browser.log"
cd "$ROOT/webviews"
bun scripts/pages-size-open-bench.mjs --out "$OUT" --samples "$SAMPLES" > "$ACTIVE_LOG" 2>&1
# Browser output is already compact: one size line and one timing line per page, not every request/sample.
cat "$ACTIVE_LOG"
printf 'pages-proof completed: %s\n' "$OUT"
