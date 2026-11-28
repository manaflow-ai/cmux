#!/usr/bin/env bash
# Older remote manifests omit the optional pre-read. --require-companions must
# keep requiring the server companions while accepting that older publication.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
APP="$TMP/cmux.app"; CDN="$TMP/cdn"; BIN="$TMP/bin"; SOURCE="$TMP/source"
mkdir -p "$APP/Contents/Resources/bin" "$CDN/cmux-tui/latest" "$BIN" "$SOURCE"
cat > "$TMP/client" <<'SH'
#!/bin/sh
case "${1:-}" in
  remote-probe) printf '{"app":"cmux-tui","capabilities":["wireguard-hub","ssh-payload-macos-from-client","ssh-payload-download"]}' ;;
  __daemon-capabilities|capabilities) printf '{"capabilities":["wireguard-hub","ssh-payload-macos-from-client","ssh-payload-download"]}' ;;
  --version) printf 'acpmux 0.1.0\n' ;;
  *) printf 'cmux-tui 0.1.0 (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)\n' ;;
esac
SH
chmod 755 "$TMP/client"
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for name in cmux-tui cmux-tui-app-host cmux-tui-cloud-server cmux-tui-host cmux-tui-holder cmux-tui-browser-host cmux-tui-agent-screen-detection; do
  cp "$TMP/client" "$SOURCE/$name"
done
mkdir -p "$CDN/cmux-tui/$commit"
for name in cmux-tui cmux-tui-app-host cmux-tui-cloud-server cmux-tui-host cmux-tui-holder cmux-tui-browser-host cmux-tui-agent-screen-detection; do
  cp "$SOURCE/$name" "$CDN/cmux-tui/$commit/$name-aarch64-apple-darwin"
done
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
cat > "$CDN/cmux-tui/latest/manifest.json" <<JSON
{"commit":"$commit","binaries":{
"cmux-tui-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-aarch64-apple-darwin")",
"cmux-tui-app-host-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-app-host-aarch64-apple-darwin")",
"cmux-tui-cloud-server-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-cloud-server-aarch64-apple-darwin")",
"cmux-tui-host-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-host-aarch64-apple-darwin")",
"cmux-tui-holder-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-holder-aarch64-apple-darwin")",
"cmux-tui-browser-host-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-browser-host-aarch64-apple-darwin")",
"cmux-tui-agent-screen-detection-aarch64-apple-darwin":"$(sha "$CDN/cmux-tui/$commit/cmux-tui-agent-screen-detection-aarch64-apple-darwin")"
}}
JSON
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""; out=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [[ "${args[i]}" == -o ]] && out="${args[i+1]}"
  [[ "${args[i]}" == https://cdn.test/* ]] && url="${args[i]}"
done
path="${url#https://cdn.test/}"
src="${CDN_ROOT:?}/$path"
[[ -f "$src" ]] || { printf '404'; exit 22; }
cp "$src" "$out"
printf '200'
SH
chmod 755 "$BIN/curl"
cat > "$BIN/lipo" <<'SH'
#!/bin/sh
exit 0
SH
chmod 755 "$BIN/lipo"
PATH="$BIN:$PATH" CDN_ROOT="$CDN" CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS=1 \
  bash "$ROOT/scripts/install-cmux-tui-client.sh" "$APP" \
    --manifest-url https://cdn.test/cmux-tui/latest/manifest.json \
    --cache-dir "$TMP/cache" --expected-commit "$commit" --allow-unattested \
    --require-companions --arch arm64 \
    >"$TMP/stdout" 2>"$TMP/stderr" \
    || { cat "$TMP/stderr" >&2; echo 'older manifest rejected by --require-companions' >&2; exit 1; }
[[ -x "$APP/Contents/Resources/bin/cmux" ]] || { echo 'client was not installed' >&2; exit 1; }
[[ ! -e "$APP/Contents/Resources/bin/cmux-launch-preread" ]] || { echo 'missing optional pre-read was fabricated' >&2; exit 1; }
[[ "$(grep -c 'publishes no cmux-launch-preread' "$TMP/stdout")" == 1 ]] || { echo 'optional pre-read note missing' >&2; exit 1; }
printf 'install-cmux-tui-client --require-companions compatibility: ok\n'
