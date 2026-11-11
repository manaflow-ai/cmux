#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos

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

# A changed cef-manifest.json is checked for each arch it names, in R2 only:
# cmux#31594 pinned CEF cmux.41 with no R2 object and the check never looked.
printf '%s\n' '{"version":"cef-1","asset":"a","sha256":"cccc","x86_64":{"asset":"b","sha256":"dddd"}}' \
  > "$TMP/scripts/cmux-next/cef-manifest.json"
git -C "$TMP" add .
git -C "$TMP" commit -qm cef
cef_base="$(git -C "$TMP" rev-parse HEAD^1)"
cat > "$stub/ensure-cef.sh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s %s\n' "$2" "${CMUX_CEF_NO_STORE:-}" "${CMUX_CEF_NO_GITHUB:-}" "${CMUX_CEF_MANIFEST:?}" >> "${STUB_CALLED:?}"
EOF2
chmod +x "$stub/ensure-cef.sh"
rm -f "$TMP/called"
STUB_CALLED="$TMP/called" RUNNER_TEMP="$TMP/cache" \
  PIN_ASSET_SCRIPT_DIR="$stub" PIN_ASSET_REPO_ROOT="$TMP" \
  bash "$CHECK" "$cef_base" >/dev/null
expected="arm64 1 1 $TMP/scripts/cmux-next/cef-manifest.json
x86_64 1 1 $TMP/scripts/cmux-next/cef-manifest.json"
[[ "$(cat "$TMP/called")" == "$expected" ]] || { echo "unexpected ensure-cef calls:"; cat "$TMP/called"; exit 1; }

# A missing R2 object fails the check.
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/ensure-cef.sh"
if PIN_ASSET_SCRIPT_DIR="$stub" PIN_ASSET_REPO_ROOT="$TMP" RUNNER_TEMP="$TMP/cache" \
  bash "$CHECK" "$cef_base" >/dev/null 2>&1; then
  echo "a CEF pin with no R2 object passed"; exit 1
fi

echo "check-pinned-assets fixture passed"
