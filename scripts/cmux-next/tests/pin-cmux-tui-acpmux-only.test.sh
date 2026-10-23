#!/usr/bin/env bash
# fetch-acpmux verifies the published tree and downloads only the acpmux
# companion needed by build-nightly-app. Missing and mismatched companions
# remain fail-closed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo source > "$TMP/src/cmux-tui/source"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m source
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"
git_q -C "$TMP/src" remote add origin "$TMP/origin.git"
git_q -C "$TMP/src" fetch origin
sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)

# The CDN shim logs every request so the test proves the reduced transfer set.
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
printf '%s\n' "${url#https://cdn.test/cmux-tui/}" >> "$TEST_REQUESTS"
[[ -f "$path" ]] || exit 22
if [[ -n "$out" ]]; then cp "$path" "$out"; else cat "$path"; fi
SHIM
chmod +x "$TMP/bin/curl"

printf '%s' daemon > "$TMP/cdn/$sha/cmux-tui-aarch64-apple-darwin"
printf '%s' acpmux > "$TMP/cdn/$sha/cmux-tui-acpmux-aarch64-apple-darwin"
daemon_sha=$(sha256 "$TMP/cdn/$sha/cmux-tui-aarch64-apple-darwin")
acpmux_sha=$(sha256 "$TMP/cdn/$sha/cmux-tui-acpmux-aarch64-apple-darwin")
printf '%s  cmux-tui-aarch64-apple-darwin\n' "$daemon_sha" > "$TMP/cdn/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"
printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s","cmux-tui-acpmux-aarch64-apple-darwin":"%s"}}\n' "$sha" "$daemon_sha" "$acpmux_sha" > "$TMP/cdn/$sha/manifest.json"
printf '{"commit":"%s"}\n' "$sha" > "$TMP/cdn/tree/$key/source.json"

run() {
  (cd "$TMP/src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR PATH="$TMP/bin:$PATH" \
    REAL_CURL="$real_curl" TEST_CDN_ROOT="$TMP/cdn" TEST_REQUESTS="$TMP/requests" \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_KEY="$key" \
    CMUX_TUI_TREE_WAIT_SECONDS=1 CMUX_TUI_TREE_POLL_SECONDS=1 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch-acpmux 2>&1)
}

out=$(run)
grep -q 'using attested same-tree acpmux companion' <<<"$out" || { printf '%s\n' "$out" >&2; exit 1; }
grep -q '^tree/' "$TMP/requests" || true
grep -q 'cmux-tui-aarch64-apple-darwin.sha256' "$TMP/requests" || { cat "$TMP/requests" >&2; exit 1; }
grep -q 'cmux-tui-acpmux-aarch64-apple-darwin' "$TMP/requests" || { cat "$TMP/requests" >&2; exit 1; }
for unwanted in 'cmux-tui-aarch64-apple-darwin$' cmux-tui-app-host- cmux-tui-cloud-server- cmux-tui-browser-host- cmux-tui-host- cmux-tui-holder-; do
  ! grep -q "$unwanted" "$TMP/requests" || { echo "unexpected companion request: $unwanted" >&2; cat "$TMP/requests" >&2; exit 1; }
done

# Missing acpmux is a hard failure, even when the tree and daemon manifest are valid.
rm -rf "$TMP/src/cmux-tui/target" "$TMP/requests"
printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s"}}\n' "$sha" "$daemon_sha" > "$TMP/cdn/$sha/manifest.json"
status=0; out=$(run) || status=$?
[[ "$status" != 0 ]] && grep -q 'no verified acpmux companion' <<<"$out" || { printf 'missing acpmux was accepted (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }

# A companion whose bytes disagree with its attested manifest is also rejected.
rm -rf "$TMP/src/cmux-tui/target" "$TMP/requests"
printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s","cmux-tui-acpmux-aarch64-apple-darwin":"%064d"}}\n' "$sha" "$daemon_sha" 0 > "$TMP/cdn/$sha/manifest.json"
status=0; out=$(run) || status=$?
[[ "$status" != 0 ]] && grep -q 'does not match its manifest' <<<"$out" || { printf 'invalid acpmux was accepted (exit %s):\n%s\n' "$status" "$out" >&2; exit 1; }

echo "pin-cmux-tui-acpmux-only.test.sh: ok"
