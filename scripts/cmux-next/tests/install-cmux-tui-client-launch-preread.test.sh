#!/usr/bin/env bash
# The installer carries the optional launch-time pre-read beside the local
# cmux-tui client and removes stale output when an older client has none.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
APP="$TMP/cmux.app"
CLIENT="$TMP/client"
mkdir -p "$APP/Contents/Resources/bin" "$CLIENT"
cat > "$CLIENT/cmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  remote-probe) printf '{"app":"cmux-tui","capabilities":[]}' ;;
  __daemon-capabilities|capabilities) printf '{"capabilities":["test"]}' ;;
  *) printf 'cmux-tui 0.1.0 (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)\n' ;;
esac
SH
chmod 755 "$CLIENT/cmux"
# A stale reader is removed before a client that has no reader is installed.
printf 'stale\n' > "$APP/Contents/Resources/bin/cmux-launch-preread"
CMUX_TUI_CLIENT_LOCAL="$CLIENT/cmux" bash "$ROOT/scripts/install-cmux-tui-client.sh" "$APP" --arch arm64
[[ ! -e "$APP/Contents/Resources/bin/cmux-launch-preread" ]] || { echo 'stale launch preread survived a client without one' >&2; exit 1; }
# A client set carrying the optional reader copies it beside bin/cmux.
printf 'reader two\n' > "$CLIENT/cmux-launch-preread"
chmod 755 "$CLIENT/cmux-launch-preread"
CMUX_TUI_CLIENT_LOCAL="$CLIENT/cmux" bash "$ROOT/scripts/install-cmux-tui-client.sh" "$APP" --arch arm64
cmp -s "$CLIENT/cmux-launch-preread" "$APP/Contents/Resources/bin/cmux-launch-preread" || {
  echo 'launch preread was not installed beside cmux' >&2; exit 1;
}
echo 'install-cmux-tui-client launch preread: ok'
