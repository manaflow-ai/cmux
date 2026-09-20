#!/usr/bin/env bash
# The reload reuse key must follow the cmux-tui client that would be bundled, not
# just the path or URL it comes from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/reload-incremental.sh"
INSTALLER="$ROOT/scripts/install-cmux-tui-client.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reload-tui-identity.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# curl serves manifest.json from a local directory and fails when it is absent.
FAKEBIN="$TEST_DIR/bin"
SERVE="$TEST_DIR/serve"
mkdir -p "$FAKEBIN" "$SERVE"
cat > "$FAKEBIN/curl" <<SH
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
  esac
  shift
done
cp "$SERVE/manifest.json" "\$out" 2>/dev/null
SH
chmod +x "$FAKEBIN/curl"

BUILT_APP="$TEST_DIR/Built.app"
mkdir -p "$BUILT_APP/Contents/Resources/bin"
ROLLING_URL="https://files.example.test/cmux-tui/latest/manifest.json"

identity() { # [manifest-url]; env selects the client source
  PATH="$FAKEBIN:$PATH" reload_incremental_tui_client_identity "$INSTALLER" "$BUILT_APP" "${1:-}"
}

# A local client that changes in place changes the identity.
LOCAL_CLIENT="$TEST_DIR/cmux-tui-local"
printf 'client-one\n' > "$LOCAL_CLIENT"
LOCAL_ONE="$(CMUX_TUI_CLIENT_LOCAL="$LOCAL_CLIENT" identity)"
[[ -n "$LOCAL_ONE" ]] || fail "local client has no identity"
[[ "$LOCAL_ONE" == "$(CMUX_TUI_CLIENT_LOCAL="$LOCAL_CLIENT" identity)" ]] || fail "local identity is unstable"
printf 'client-two\n' > "$LOCAL_CLIENT"
LOCAL_TWO="$(CMUX_TUI_CLIENT_LOCAL="$LOCAL_CLIENT" identity)"
[[ "$LOCAL_ONE" != "$LOCAL_TWO" ]] || fail "local client changed in place but the identity did not"
if CMUX_TUI_CLIENT_LOCAL="$TEST_DIR/absent" identity >/dev/null 2>&1; then
  fail "a missing local client resolved to an identity"
fi

# A rolling manifest URL that starts serving a new build changes the identity.
printf '{"commit":"one"}\n' > "$SERVE/manifest.json"
ROLLING_ONE="$(identity "$ROLLING_URL")"
[[ -n "$ROLLING_ONE" ]] || fail "manifest has no identity"
[[ "$ROLLING_ONE" == "$(identity "$ROLLING_URL")" ]] || fail "manifest identity is unstable"
[[ "$ROLLING_ONE" == "$(CMUX_TUI_CLIENT_MANIFEST_URL="$ROLLING_URL" identity)" ]] \
  || fail "the manifest URL from the environment resolved differently"
printf '{"commit":"two"}\n' > "$SERVE/manifest.json"
ROLLING_TWO="$(identity "$ROLLING_URL")"
[[ "$ROLLING_ONE" != "$ROLLING_TWO" ]] || fail "rolling manifest changed but the identity did not"
[[ "$ROLLING_TWO" != "$LOCAL_TWO" ]] || fail "manifest and local identities collide"

# An unreachable manifest has no identity, so the caller cannot reuse outputs.
rm "$SERVE/manifest.json"
if identity "$ROLLING_URL" >/dev/null 2>&1; then
  fail "an unreachable manifest resolved to an identity"
fi

# A preserved bundled client needs no network; the built app digest covers it.
printf '#!/bin/sh\n' > "$BUILT_APP/Contents/Resources/bin/cmux-tui"
chmod +x "$BUILT_APP/Contents/Resources/bin/cmux-tui"
PRESERVED="$(CMUX_SKIP_CMUX_TUI_CLIENT=1 identity "$ROLLING_URL")"
[[ -n "$PRESERVED" && "$PRESERVED" != "$ROLLING_TWO" ]] || fail "preserved client identity is wrong"
rm "$BUILT_APP/Contents/Resources/bin/cmux-tui"
if CMUX_SKIP_CMUX_TUI_CLIENT=1 identity "$ROLLING_URL" >/dev/null 2>&1; then
  fail "skip without a bundled client must resolve the manifest"
fi

echo "PASS: reload cmux-tui client identity follows the client content"
