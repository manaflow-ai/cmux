#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-client-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/Test.app"
mkdir -p "$APP/Contents"
CLIENT="$TEST_DIR/client"
cat > "$CLIENT" <<'SH'
#!/bin/sh
[ "$1" = remote-probe ] && [ "$2" = --json ] || exit 64
printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub","test-capability"]}'
SH
chmod +x "$CLIENT"

install_client() {
  # Exercise the runner's system Bash: macOS ships 3.2, whose nounset handling
  # differs from modern Bash for an initialized but empty array.
  CMUX_TUI_CLIENT_LOCAL="$CLIENT" /bin/bash \
    "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$APP" "$@"
}

install_client
cmp "$CLIENT" "$APP/Contents/Resources/bin/cmux-tui"
install_client --require-capability wireguard-hub
install_client --require-capability wireguard-hub --require-capability test-capability
if install_client --require-capability wireguard-hub --require-capability missing > "$TEST_DIR/missing.log" 2>&1; then
  echo "FAIL: installed a client missing a required capability" >&2
  exit 1
fi
grep -q 'required cmux-tui capability is missing: missing' "$TEST_DIR/missing.log"
echo "PASS: client installation with zero, one, and multiple required capabilities"

# --- Manifest attestation gate ------------------------------------------------
# The download path is exercised against fake curl/gh/lipo tools on PATH: curl
# serves files from a local directory and gh records its arguments. Every tool
# appends to one event log so the order (manifest, attestation, slices) is
# observable.
FAKEBIN="$TEST_DIR/bin"
SERVE="$TEST_DIR/serve"
EVENTS="$TEST_DIR/events.log"
mkdir -p "$FAKEBIN" "$SERVE"
COMMIT="$(printf 'a%.0s' $(seq 1 40))"
SIGNER="manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml"
cp "$CLIENT" "$SERVE/cmux-tui-aarch64-apple-darwin"
cp "$CLIENT" "$SERVE/cmux-tui-x86_64-apple-darwin"
if command -v shasum >/dev/null 2>&1; then
  slice_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  slice_sha() { sha256sum "$1" | awk '{print $1}'; }
  printf '#!/bin/sh\nsha256sum "$3"\n' > "$FAKEBIN/shasum"
  chmod +x "$FAKEBIN/shasum"
fi
ARM_SHA="$(slice_sha "$SERVE/cmux-tui-aarch64-apple-darwin")"
X64_SHA="$(slice_sha "$SERVE/cmux-tui-x86_64-apple-darwin")"
cat > "$SERVE/manifest.json" <<JSON
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA"}}
JSON
cat > "$FAKEBIN/curl" <<SH
#!/bin/bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    http://*|https://*) url="\$1" ;;
  esac
  shift
done
printf 'curl %s\n' "\$url" >> "$EVENTS"
cp "$SERVE/\$(basename "\$url")" "\$out"
SH
cat > "$FAKEBIN/gh" <<SH
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$EVENTS"
exit "\${FAKE_GH_EXIT:-0}"
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
chmod +x "$FAKEBIN/curl" "$FAKEBIN/gh" "$FAKEBIN/lipo"

install_remote() { # <app> [installer options]
  local app="$1"; shift
  mkdir -p "$app/Contents"
  : > "$EVENTS"
  PATH="$FAKEBIN:$PATH" CMUX_TUI_CLIENT_CACHE="$TEST_DIR/cache-$RANDOM" /bin/bash \
    "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$app" \
    --manifest-url "https://files.example.test/cmux-tui/$COMMIT/manifest.json" "$@"
}

ATTESTED_APP="$TEST_DIR/Attested.app"
install_remote "$ATTESTED_APP" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
  --require-capability wireguard-hub > "$TEST_DIR/attested.log" 2>&1
cmp "$CLIENT" "$ATTESTED_APP/Contents/Resources/bin/cmux-tui"
grep -q "^gh attestation verify .*manifest.* --repo manaflow-ai/cmux --signer-workflow $SIGNER --source-digest $COMMIT\$" "$EVENTS"
# The manifest is verified before any slice it names is fetched.
[ "$(sed -n '1p' "$EVENTS")" = "curl https://files.example.test/cmux-tui/$COMMIT/manifest.json" ]
[ "$(sed -n '2p' "$EVENTS" | cut -d' ' -f1-3)" = "gh attestation verify" ]
[ "$(sed -n '3p' "$EVENTS")" = "curl https://files.example.test/cmux-tui/$COMMIT/cmux-tui-aarch64-apple-darwin" ]
echo "PASS: attested manifest is verified before slices are downloaded"

UNATTESTED_APP="$TEST_DIR/Unattested.app"
if FAKE_GH_EXIT=1 install_remote "$UNATTESTED_APP" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
    > "$TEST_DIR/unattested.log" 2>&1; then
  echo "FAIL: installed a client from a manifest without a valid attestation" >&2
  exit 1
fi
grep -q 'no valid build-provenance attestation for the cmux-tui manifest' "$TEST_DIR/unattested.log"
[ ! -e "$UNATTESTED_APP/Contents/Resources/bin/cmux-tui" ]
if grep -q 'apple-darwin' "$EVENTS"; then
  echo "FAIL: downloaded a slice named by an unverified manifest" >&2
  exit 1
fi
echo "PASS: a manifest without a valid attestation installs nothing"

if install_remote "$TEST_DIR/Malformed.app" --attest-signer-workflow "cmux-tui-artifacts.yml" \
    > "$TEST_DIR/malformed.log" 2>&1; then
  echo "FAIL: accepted a malformed --attest-signer-workflow" >&2
  exit 1
fi
grep -q 'attest-signer-workflow must look like owner/repo/.github/workflows/name.yml' "$TEST_DIR/malformed.log"
[ ! -s "$EVENTS" ]
echo "PASS: a malformed signer workflow is rejected before any download"
