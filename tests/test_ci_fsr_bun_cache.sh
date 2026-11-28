#!/usr/bin/env bash
# Behavioral tests for scripts/ci/fsr-bun-cache.sh: a VM runner guest's baked lockfile marker is a hit only when every
# lockfile the job hashes matches it (marker format: cmuxterm-hq tools/freestyle-workflow/runner-guest.sh bun_cache_bake).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/fsr-bun-cache.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" GITHUB_WORKSPACE="$TMP_DIR/ws" GITHUB_OUTPUT="$TMP_DIR/out"
marker_dir="$HOME/.bun/install/cache/.cmux-prefilled"
mkdir -p "$marker_dir" "$GITHUB_WORKSPACE"/{webviews,web,cmux-tui/frontends/web}
for d in webviews web cmux-tui/frontends/web; do echo "lock $d" > "$GITHUB_WORKSPACE/$d/bun.lock"; done
(cd "$GITHUB_WORKSPACE" && sha256sum webviews/bun.lock) > "$marker_dir/bun-webviews.sha256"
(cd "$GITHUB_WORKSPACE" && sha256sum webviews/bun.lock web/bun.lock cmux-tui/frontends/web/bun.lock) > "$marker_dir/bun-web-lint.sha256"

check() { : > "$GITHUB_OUTPUT"; bash "$SCRIPT" check "$@" > /dev/null; cat "$GITHUB_OUTPUT"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(check bun-webviews webviews/bun.lock)" == hit=true ]] || fail "matching webviews marker"
[[ "$(check bun-web-lint webviews/bun.lock web/bun.lock cmux-tui/frontends/web/bun.lock)" == hit=true ]] || fail "matching web-lint marker"
[[ "$(check bun-missing webviews/bun.lock)" == hit=false ]] || fail "no marker"
echo changed >> "$GITHUB_WORKSPACE/web/bun.lock"
[[ "$(check bun-web-lint webviews/bun.lock web/bun.lock cmux-tui/frontends/web/bun.lock)" == hit=false ]] || fail "changed lockfile"
[[ "$(check bun-webviews webviews/bun.lock)" == hit=true ]] || fail "web change leaves webviews marker"
rm "$GITHUB_WORKSPACE/webviews/bun.lock"
[[ "$(check bun-webviews webviews/bun.lock)" == hit=false ]] || fail "no lockfile in the checkout"
if bash "$SCRIPT" check only-a-name 2> /dev/null; then fail "usage"; fi
echo "test_ci_fsr_bun_cache.sh: ok"
