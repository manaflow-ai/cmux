#!/usr/bin/env bash
# resolve-acpmux.sh, build-acpmux.sh and pin-cmux-tui.sh fetch-acpmux together, against a fake CDN: the acpmux
# a fetch just brought is the one the resolver bundles, for every architecture set a reload asks for.
# Regression (a RAM bench on a developer Mac at 7802ece0, 2026-11-22): pin-cmux-tui.sh had just fetched the tree's
# verified acpmux to cmux-tui/target/hosted/tree/<key>/acpmux, and reload.sh then failed with "no cached
# acpmux for this checkout ... no published acpmux of its cmux-tui tree could be fetched". The published
# companion is thin arm64 and a Release reload asks for "arm64 x86_64": build-acpmux.sh silently declined
# it, fetch-acpmux never fetched the x86_64 slice the manifest attests, and the resolver blamed the fetch.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# git_q, and no background git maintenance in the scratch repositories.
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$ROOT/scripts/cmux-next/tests/lib/git-fixture.sh"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui/crates/acpmux" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ROOT/scripts/cmux-next/build-acpmux.sh" "$ROOT/scripts/cmux-next/resolve-acpmux.sh" \
  "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo '[package]' > "$src/cmux-tui/crates/acpmux/Cargo.toml"
git_q -C "$src" add -A
git_q -C "$src" commit -m source
git_q -C "$src" branch -M feat-cmux-next
git_fixture_clone --bare "$src" "$TMP/origin.git"
git_q -C "$src" remote add origin "$TMP/origin.git"
git_q -C "$src" fetch origin
sha=$(git -C "$src" rev-parse HEAD)
key=$(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh key)

# A CDN shim serving $TMP/cdn, and a lipo that reads and writes the "# archs:" line of these fake binaries.
mkdir -p "$TMP/bin" "$TMP/cdn/tree/$key" "$TMP/cdn/$sha"
real_curl=$(command -v curl)
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
out=""; url=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -o) out="${args[i+1]}" ;;
    https://cdn.test/*) url="${args[i]}" ;;
  esac
done
if [[ -z "$url" ]]; then exec "$REAL_CURL" "$@"; fi
path="$TEST_CDN_ROOT/${url#https://cdn.test/cmux-tui/}"; path="${path%%\?*}"
[[ -f "$path" ]] || exit 22
if [[ -n "$out" ]]; then cp "$path" "$out"; else cat "$path"; fi
SHIM
cat > "$TMP/bin/lipo" <<'SHIM'
#!/usr/bin/env bash
archs_of() { sed -n 's/^# archs: //p' "$1"; }
fat() { printf '#!/bin/sh\n# archs: %s\n' "$*" > "$out"; }
case "$1" in
  -archs) archs_of "$2" ;;
  -create) shift; ins=(); all=""
    while [[ $# -gt 0 ]]; do [[ "$1" == -output ]] && { out="$2"; shift 2; continue; }; ins+=("$1"); shift; done
    for f in "${ins[@]}"; do all+=" $(archs_of "$f")"; done; fat $all ;;
  *) in="$1"; arch="$3"; out="$5"; [[ "$2" == -thin && "$4" == -output ]] || exit 2
     [[ " $(archs_of "$in") " == *" $arch "* ]] || exit 1; fat "$arch" ;;
esac
SHIM
chmod +x "$TMP/bin/curl" "$TMP/bin/lipo"

# The tree's publication: the daemon, its attested manifest, and the acpmux slices given as arguments.
publish() {
  local daemon_sha binaries t
  printf '%s' daemon > "$TMP/cdn/$sha/cmux-tui-aarch64-apple-darwin"
  daemon_sha=$(sha256 "$TMP/cdn/$sha/cmux-tui-aarch64-apple-darwin")
  printf '%s  cmux-tui-aarch64-apple-darwin\n' "$daemon_sha" > "$TMP/cdn/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"
  printf '{"commit":"%s"}\n' "$sha" > "$TMP/cdn/tree/$key/source.json"
  binaries="\"cmux-tui-aarch64-apple-darwin\":\"$daemon_sha\""
  for t in "$@"; do
    printf '#!/bin/sh\n# archs: %s\n' "$([[ "$t" == aarch64-apple-darwin ]] && echo arm64 || echo x86_64)" > "$TMP/cdn/$sha/cmux-tui-acpmux-$t"
    binaries+=",\"cmux-tui-acpmux-$t\":\"$(sha256 "$TMP/cdn/$sha/cmux-tui-acpmux-$t")\""
  done
  printf '{"commit":"%s","binaries":{%s}}\n' "$sha" "$binaries" > "$TMP/cdn/$sha/manifest.json"
  rm -rf "$src/cmux-tui/target"
}
# reload.sh's call, from a developer Mac that never runs Cargo.
resolve() {
  (cd "$src" && env -u GITHUB_ACTIONS -u CI -u CI_JOB_DIR -u CMUX_FLEET_BUILD_TAG -u NX_JOB_ID -u NX_APP -u ARCHS \
    PATH="$TMP/bin:$PATH" REAL_CURL="$real_curl" TEST_CDN_ROOT="$TMP/cdn" \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_KEY="$key" CMUX_TUI_TREE_POLL_SECONDS=1 \
    CMUX_NEXT_ACPMUX_ARCHS="$1" bash scripts/cmux-next/resolve-acpmux.sh --repo "$src" 2>"$TMP/err")
}

# A native-architecture build: the fetched arm64 companion.
publish aarch64-apple-darwin
out=$(resolve arm64) || fail "arm64 build: $(cat "$TMP/err")"
[[ "$("$TMP/bin/lipo" -archs "$out")" == arm64 ]] || fail "arm64 build bundles $out"

# The regression: a universal (Release) build of a tree whose manifest attests both slices bundles both.
publish aarch64-apple-darwin x86_64-apple-darwin
out=$(resolve "arm64 x86_64") || fail "universal build missed the acpmux the fetch just brought: $(cat "$TMP/err")"
[[ "$("$TMP/bin/lipo" -archs "$out")" == "arm64 x86_64" ]] || fail "universal build bundles $("$TMP/bin/lipo" -archs "$out"): $out"
[[ "$out" == "$src/cmux-tui/target/hosted/acpmux/in-tree-$sha/arm64-x86_64/acpmux" ]] || fail "universal acpmux is not in the commit cache: $out"

# A universal build of a tree that published arm64 alone (every tree off main and rc/**): a clear failure
# naming the missing slice and what to do, not "could not be fetched".
publish aarch64-apple-darwin
if out=$(resolve "arm64 x86_64"); then fail "an arm64-only tree resolved a universal acpmux: $out"; fi
grep -q 'no x86_64 slice' "$TMP/err" || fail "missing slice not named: $(cat "$TMP/err")"
grep -q -- '--native-arch' "$TMP/err" || fail "no next step: $(cat "$TMP/err")"
! grep -q 'could not be fetched' "$TMP/err" || fail "blamed the fetch that worked: $(cat "$TMP/err")"

echo "resolve-acpmux-tree-archs.test.sh: ok"
