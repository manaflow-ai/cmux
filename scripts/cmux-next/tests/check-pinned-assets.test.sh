#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/check-pinned-assets.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-pinned-assets.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name test
mkdir -p "$TMP/scripts/cmux-next"
printf '%s\n' '{"asset":"host","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
  > "$TMP/scripts/cmux-next/remote-browser-host.pin.json"
git -C "$TMP" add .
git -C "$TMP" commit -qm base
base="$(git -C "$TMP" rev-parse HEAD)"
printf '%s\n' '{"asset":"host","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
  > "$TMP/scripts/cmux-next/remote-browser-host.pin.json"
git -C "$TMP" add .
git -C "$TMP" commit -qm pin

stub="$TMP/stub"
mkdir -p "$stub"
cat > "$stub/ensure-remote-browser-host.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CMUX_NEXT_RB_HOST_CACHE_DIR:?}" > "${STUB_CALLED:?}"
EOF
chmod +x "$stub/ensure-remote-browser-host.sh"

# Run the production script against the fixture repo while replacing only the
# store client; changed-file and unknown-pin checks remain real.
STUB_CALLED="$TMP/called" RUNNER_TEMP="$TMP/cache" \
  PIN_ASSET_SCRIPT_DIR="$stub" PIN_ASSET_REPO_ROOT="$TMP" \
  bash "$CHECK" "$base" >/dev/null
[[ -s "$TMP/called" ]]

# A staging pin (cef-pin-staging.sh) is refused before the store is asked: it was never published.
base="$(git -C "$TMP" rev-parse HEAD)"
printf '%s\n' '{"asset":"host","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","staging":{"store_expires":"2099-01-01"}}' \
  > "$TMP/scripts/cmux-next/remote-browser-host.pin.json"
git -C "$TMP" commit -qam staging
rm -f "$TMP/called"
if STUB_CALLED="$TMP/called" RUNNER_TEMP="$TMP/cache" PIN_ASSET_SCRIPT_DIR="$stub" PIN_ASSET_REPO_ROOT="$TMP" \
  bash "$CHECK" "$base" > /dev/null 2> "$TMP/staging.err"; then
  echo "FAIL: a staging pin passed the store check" >&2; exit 1
fi
grep -q "is a staging pin" "$TMP/staging.err" || { echo "FAIL: no staging refusal: $(cat "$TMP/staging.err")" >&2; exit 1; }
[[ ! -e "$TMP/called" ]] || { echo "FAIL: the store was asked for a staging pin" >&2; exit 1; }

echo "check-pinned-assets fixture passed"
