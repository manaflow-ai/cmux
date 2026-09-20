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

identity() { # [manifest-url] [manifest-snapshot]; env selects the client source
  PATH="$FAKEBIN:$PATH" reload_incremental_tui_client_identity "$INSTALLER" "$BUILT_APP" "${1:-}" "${2:-}"
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

# A publication can land between resolving the identity and installing. The install
# must bundle the client the identity describes, so both use one manifest snapshot.
cat > "$FAKEBIN/curl" <<SH
#!/bin/bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    https://*) url="\$1" ;;
  esac
  shift
done
case "\$url" in
  */latest/manifest.json) cp "$SERVE/manifest.json" "\$out" 2>/dev/null ;;
  *) cp "$SERVE/\$(basename "\$(dirname "\$url")")/\$(basename "\$url")" "\$out" 2>/dev/null ;;
esac
SH
cat > "$FAKEBIN/lipo" <<'SH'
#!/bin/bash
if [ "$1" = -create ]; then
  out=""; first="$2"
  while [ $# -gt 0 ]; do [ "$1" = -output ] && out="$2"; shift; done
  cp "$first" "$out"
fi
exit 0
SH
GH_EVENTS="$TEST_DIR/gh-events.log"
cat > "$FAKEBIN/gh" <<SH
#!/bin/bash
printf 'gh %s\\n' "\$*" >> "$GH_EVENTS"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/lipo" "$FAKEBIN/gh"

publish() { # <name> <commit>; writes $SERVE/<commit>/ slices and $TEST_DIR/manifest-<name>.json
  local name="$1" commit="$2" slice sha
  mkdir -p "$SERVE/$commit"
  for slice in cmux-tui-aarch64-apple-darwin cmux-tui-x86_64-apple-darwin; do
    cat > "$SERVE/$commit/$slice" <<SH
#!/bin/sh
# build $name
printf '%s\\n' '{"app":"cmux-tui","capabilities":[]}'
SH
    chmod +x "$SERVE/$commit/$slice"
  done
  sha="$(reload_incremental_sha256_file "$SERVE/$commit/cmux-tui-aarch64-apple-darwin")"
  printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s","cmux-tui-x86_64-apple-darwin":"%s"}}\n' \
    "$commit" "$sha" "$sha" > "$TEST_DIR/manifest-$name.json"
}
COMMIT_ONE="$(printf 'a%.0s' $(seq 1 40))"
COMMIT_TWO="$(printf 'b%.0s' $(seq 1 40))"
publish one "$COMMIT_ONE"
publish two "$COMMIT_TWO"

install_snapshot() { # <app> <manifest-snapshot> [installer options]
  local app="$1" snapshot="$2"; shift 2
  mkdir -p "$app/Contents"
  PATH="$FAKEBIN:$PATH" CMUX_TUI_CLIENT_CACHE="$TEST_DIR/cache" /bin/bash "$INSTALLER" "$app" \
    --manifest-url "$ROLLING_URL" --manifest-file "$snapshot" "$@"
}

SNAPSHOT="$TEST_DIR/receipts/cmux-tui-manifest.json"
cp "$TEST_DIR/manifest-one.json" "$SERVE/manifest.json"
SNAPSHOT_IDENTITY="$(identity "$ROLLING_URL" "$SNAPSHOT")"
[[ "$SNAPSHOT_IDENTITY" == "$(identity "$ROLLING_URL")" ]] || fail "keeping the manifest changed the identity"
cmp -s "$SNAPSHOT" "$TEST_DIR/manifest-one.json" || fail "the identity did not keep the manifest it hashed"
cp "$TEST_DIR/manifest-two.json" "$SERVE/manifest.json"
RACED_APP="$TEST_DIR/Raced.app"
install_snapshot "$RACED_APP" "$SNAPSHOT" --allow-unattested > "$TEST_DIR/raced.log" 2>&1 \
  || fail "install from the manifest snapshot failed: $(cat "$TEST_DIR/raced.log")"
cmp -s "$RACED_APP/Contents/Resources/bin/cmux-tui" "$SERVE/$COMMIT_ONE/cmux-tui-aarch64-apple-darwin" \
  || fail "a publication after the identity was resolved changed the bundled client"

# The snapshot is still authenticated before anything it names is trusted.
: > "$GH_EVENTS"
install_snapshot "$TEST_DIR/Attested.app" "$SNAPSHOT" > "$TEST_DIR/attested.log" 2>&1 \
  || fail "attested install from the manifest snapshot failed: $(cat "$TEST_DIR/attested.log")"
grep -q "^gh attestation verify $SNAPSHOT " "$GH_EVENTS" || fail "the manifest snapshot was not attested"

# An identity that cannot be resolved leaves no stale snapshot for the install.
rm "$SERVE/manifest.json"
if identity "$ROLLING_URL" "$SNAPSHOT" >/dev/null 2>&1; then
  fail "an unreachable manifest resolved to an identity"
fi
[[ ! -e "$SNAPSHOT" ]] || fail "a failed identity left a stale manifest snapshot"

# Interleave two reloads for the same tag at the production identity-resolution
# boundary. Execute reload.sh's real allocation/resolution block so this catches
# accidentally sharing a snapshot even though the installer itself is correct.
SNAPSHOT_SETUP="$(python3 - "$ROOT/scripts/reload.sh" <<'PYCODE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index('RELOAD_RECEIPT_DIR=')
end = source.index('RELOAD_INPUT_DIGEST=', start)
print(source[start:end])
PYCODE
)"
resolve_reload_snapshot() {
  local DERIVED_DATA="$TEST_DIR/shared-derived-data" TAG_SLUG="same-tag"
  local APP_PATH="$BUILT_APP" CMUX_TUI_CLIENT_MANIFEST_URL_VALUE="$ROLLING_URL"
  local TMPDIR="$TEST_DIR"
  eval "$SNAPSHOT_SETUP"
}

cp "$TEST_DIR/manifest-one.json" "$SERVE/manifest.json"
PATH="$FAKEBIN:$PATH" resolve_reload_snapshot
FIRST_SNAPSHOT="$RELOAD_TUI_CLIENT_MANIFEST"
FIRST_IDENTITY="$RELOAD_TUI_CLIENT_IDENTITY"
cp "$TEST_DIR/manifest-two.json" "$SERVE/manifest.json"
PATH="$FAKEBIN:$PATH" resolve_reload_snapshot
SECOND_SNAPSHOT="$RELOAD_TUI_CLIENT_MANIFEST"
SECOND_IDENTITY="$RELOAD_TUI_CLIENT_IDENTITY"
[[ "$FIRST_IDENTITY" != "$SECOND_IDENTITY" ]] || fail "interleaved reloads did not resolve distinct clients"
install_snapshot "$TEST_DIR/FirstReload.app" "$FIRST_SNAPSHOT" --allow-unattested > "$TEST_DIR/first.log" 2>&1 \
  || fail "first interleaved reload failed: $(cat "$TEST_DIR/first.log")"
cmp -s "$TEST_DIR/FirstReload.app/Contents/Resources/bin/cmux-tui" "$SERVE/$COMMIT_ONE/cmux-tui-aarch64-apple-darwin" \
  || fail "second reload replaced the first reload's resolved manifest"

# A third reload failing resolution must not remove either earlier snapshot.
rm "$SERVE/manifest.json"
PATH="$FAKEBIN:$PATH" resolve_reload_snapshot
[[ "$RELOAD_TUI_CLIENT_RESOLVED" -eq 0 ]] || fail "missing manifest unexpectedly resolved"
[[ -f "$FIRST_SNAPSHOT" && -f "$SECOND_SNAPSHOT" ]] || fail "failed reload removed another reload's snapshot"
install_snapshot "$TEST_DIR/SecondReload.app" "$SECOND_SNAPSHOT" --allow-unattested > "$TEST_DIR/second.log" 2>&1 \
  || fail "second interleaved reload failed: $(cat "$TEST_DIR/second.log")"
cmp -s "$TEST_DIR/SecondReload.app/Contents/Resources/bin/cmux-tui" "$SERVE/$COMMIT_TWO/cmux-tui-aarch64-apple-darwin" \
  || fail "second reload did not install its own resolved client"

echo "PASS: reload cmux-tui client identity follows the client content"
