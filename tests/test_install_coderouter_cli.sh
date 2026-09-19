#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-coderouter-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/Test.app"
mkdir -p "$APP/Contents"

# A stand-in binary that answers the credential-free probe the installer checks.
CLIENT="$TEST_DIR/coderouter"
cat > "$CLIENT" <<'SH'
#!/bin/sh
[ "$1" = capabilities ] && [ "$2" = --json ] || exit 64
printf '%s\n' '{"product":"coderouter","cliVersion":"0.0.0","protocolVersion":1,"authModes":["standalone-stack"],"features":[]}'
SH
chmod +x "$CLIENT"
BOGUS="$TEST_DIR/not-coderouter"
printf '#!/bin/sh\nexit 0\n' > "$BOGUS"
chmod +x "$BOGUS"
# Prints the right product but exits non-zero: the probe must check the status.
LIAR="$TEST_DIR/liar"
printf '#!/bin/sh\nprintf %%s "{\\"product\\":\\"coderouter\\"}"\nexit 1\n' > "$LIAR"
chmod +x "$LIAR"

# Local install path (offline/dev builds), through the runner's system Bash 3.2.
CMUX_CODEROUTER_CLI_LOCAL="$CLIENT" /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP"
cmp "$CLIENT" "$APP/Contents/Resources/bin/coderouter"
if CMUX_CODEROUTER_CLI_LOCAL="$BOGUS" /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" > "$TEST_DIR/bogus.log" 2>&1; then
  echo "FAIL: installed a binary that does not probe as coderouter" >&2
  exit 1
fi
grep -q 'does not probe as coderouter' "$TEST_DIR/bogus.log"
if CMUX_CODEROUTER_CLI_LOCAL="$LIAR" /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" > "$TEST_DIR/liar.log" 2>&1; then
  echo "FAIL: installed a binary whose probe exits non-zero" >&2
  exit 1
fi
grep -q 'capabilities --json failed' "$TEST_DIR/liar.log"

# Download path against a local file:// release mirror: manifest version check,
# sha256 verification, and lipo into one universal binary. Needs cc and lipo, so
# it runs on macOS only; the Linux guard job covers the local path above.
if [[ "$(uname -s)" == "Darwin" ]]; then
RELEASE="$TEST_DIR/releases/v9.9.9"
mkdir -p "$RELEASE"
ARM_SRC="$(mktemp "$TEST_DIR/arm.XXXXXX.c")"
printf 'int main(void){return 0;}\n' > "$ARM_SRC"
cc -arch arm64 -o "$RELEASE/coderouter-darwin-arm64" "$ARM_SRC"
cc -arch x86_64 -o "$RELEASE/coderouter-darwin-x64" "$ARM_SRC"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
cat > "$RELEASE/manifest.json" <<JSON
{"version":"9.9.9","binaries":{"coderouter-darwin-arm64":"$(sha "$RELEASE/coderouter-darwin-arm64")","coderouter-darwin-x64":"$(sha "$RELEASE/coderouter-darwin-x64")"}}
JSON
MANIFEST_SHA="$(sha "$RELEASE/manifest.json")"
# A version without a pinned digest is refused before any download.
if CMUX_CODEROUTER_CLI_BASE_URL="file://$TEST_DIR/releases" /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" \
    --version 9.9.9 --cache-dir "$TEST_DIR/cache" > "$TEST_DIR/nopin.log" 2>&1; then
  echo "FAIL: installed a version with no pinned manifest digest" >&2
  exit 1
fi
grep -q 'no pinned manifest digest' "$TEST_DIR/nopin.log"
# A wrong digest rejects the manifest.
if CMUX_CODEROUTER_CLI_BASE_URL="file://$TEST_DIR/releases" CMUX_CODEROUTER_CLI_MANIFEST_SHA256="$(printf 'x%.0s' {1..64} | tr x 0)" \
    /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" --version 9.9.9 --cache-dir "$TEST_DIR/cache" > "$TEST_DIR/badpin.log" 2>&1; then
  echo "FAIL: accepted a manifest with the wrong digest" >&2
  exit 1
fi
grep -q 'sha256 mismatch for manifest.json' "$TEST_DIR/badpin.log"
# The stand-in slices cannot answer the probe, so this exercises everything up
# to it and expects the probe itself to fail.
if CMUX_CODEROUTER_CLI_BASE_URL="file://$TEST_DIR/releases" CMUX_CODEROUTER_CLI_MANIFEST_SHA256="$MANIFEST_SHA" \
    /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" \
    --version 9.9.9 --cache-dir "$TEST_DIR/cache" > "$TEST_DIR/download.log" 2>&1; then
  echo "FAIL: probe should have rejected the stand-in universal binary" >&2
  exit 1
fi
grep -q 'does not probe as coderouter' "$TEST_DIR/download.log"
lipo "$TEST_DIR/cache/9.9.9/coderouter-universal" -verify_arch arm64
lipo "$TEST_DIR/cache/9.9.9/coderouter-universal" -verify_arch x86_64

# A tampered slice must fail its checksum before anything is installed.
printf 'x' >> "$RELEASE/coderouter-darwin-x64"
rm -rf "$TEST_DIR/cache"
if CMUX_CODEROUTER_CLI_BASE_URL="file://$TEST_DIR/releases" CMUX_CODEROUTER_CLI_MANIFEST_SHA256="$MANIFEST_SHA" \
    /bin/bash "$ROOT_DIR/scripts/install-coderouter-cli.sh" "$APP" \
    --version 9.9.9 --cache-dir "$TEST_DIR/cache" > "$TEST_DIR/tamper.log" 2>&1; then
  echo "FAIL: installed a slice with a bad checksum" >&2
  exit 1
fi
grep -q 'sha256 mismatch for coderouter-darwin-x64' "$TEST_DIR/tamper.log"
fi

# The pin files are well formed.
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$ROOT_DIR/scripts/coderouter-cli-version"
grep -Eq '^[0-9a-f]{64}$' "$ROOT_DIR/scripts/coderouter-cli-manifest.sha256"
echo "PASS: coderouter CLI installation (local, probe, manifest, checksum, universal)"
