#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-client-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Most assertions below are a bare `cmp`, `grep -q` or `[ ... ]`, and the
# installer's own output is redirected into a per-case log. When one of them
# fails, `set -e` exits 1 having printed nothing after the last PASS line, which
# is all a CI log preserves. Name the line that failed and dump the event log.
report_failure() { # <line>
  local status=$?
  echo "FAIL: assertion at $(basename "${BASH_SOURCE[0]}"):$1 exited $status" >&2
  if [[ -n "${EVENTS:-}" && -f "${EVENTS:-}" ]]; then
    echo "--- installer events ---" >&2
    cat "$EVENTS" >&2
  fi
}
trap 'report_failure "$LINENO"' ERR
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
# Architecture selection applies only to downloads: the explicit local fixture
# remains authoritative and is still capability-probed, even though it is a script.
for arch in arm64 x86_64 universal; do
  install_client --arch "$arch" --require-capability wireguard-hub
  cmp "$CLIENT" "$APP/Contents/Resources/bin/cmux-tui"
done
echo "PASS: local override stays unchanged for each architecture selection"

# --- Manifest attestation gate ------------------------------------------------
# The download path is exercised against fake curl/gh/lipo tools on PATH: curl
# serves files from a local directory and gh records its arguments. Every tool
# appends to one event log so the order (manifest, attestation, slices) is
# observable.
FAKEBIN="$TEST_DIR/bin"
SERVE="$TEST_DIR/serve"
EVENTS="$TEST_DIR/events.log"
export EVENTS
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
printf 'lipo %s\n' "$*" >> "$EVENTS"
[ "${FAKE_LIPO_EXIT:-0}" = 0 ] || exit "$FAKE_LIPO_EXIT"
if [ "$1" = -create ]; then
  out=""; first="$2"
  while [ $# -gt 0 ]; do [ "$1" = -output ] && out="$2"; shift; done
  cp "$first" "$out"
fi
exit 0
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/gh" "$FAKEBIN/lipo"

# Every case needs its own download cache: the installer skips the curl for a
# slice already cached under the manifest's commit, and that commit is one
# constant for the whole file. $RANDOM draws from 32768 values, so across the 25
# calls made here two cases collided about once in a hundred runs, the second
# silently served both slices from the first one's cache, and the `curl` and
# `lipo` assertions below failed with no output. Number the caches instead.
REMOTE_INSTALL_SEQ=0
install_remote() { # <app> [installer options]
  local app="$1"; shift
  mkdir -p "$app/Contents"
  : > "$EVENTS"
  REMOTE_INSTALL_SEQ=$((REMOTE_INSTALL_SEQ + 1))
  PATH="$FAKEBIN:$PATH" CMUX_TUI_CLIENT_CACHE="$TEST_DIR/cache-$REMOTE_INSTALL_SEQ" /bin/bash \
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

# Verification is the default for a remote install: no flag, and the publishing
# workflow is still required to have signed the manifest.
DEFAULT_APP="$TEST_DIR/Default.app"
install_remote "$DEFAULT_APP" --expected-commit "$COMMIT" > "$TEST_DIR/default.log" 2>&1
cmp "$CLIENT" "$DEFAULT_APP/Contents/Resources/bin/cmux-tui"
grep -q "^gh attestation verify .* --signer-workflow $SIGNER --source-digest $COMMIT\$" "$EVENTS"
if FAKE_GH_EXIT=1 install_remote "$TEST_DIR/DefaultDenied.app" --expected-commit "$COMMIT" > "$TEST_DIR/default-denied.log" 2>&1; then
  echo "FAIL: a remote install without flags skipped attestation" >&2
  exit 1
fi
grep -q 'no valid build-provenance attestation' "$TEST_DIR/default-denied.log"
echo "PASS: remote installs verify the publishing workflow's attestation by default"

# Only the explicit local-development opt-out installs without gh, and it says so.
OPT_OUT_APP="$TEST_DIR/OptOut.app"
FAKE_GH_EXIT=1 install_remote "$OPT_OUT_APP" --allow-unattested > "$TEST_DIR/opt-out.log" 2>&1
cmp "$CLIENT" "$OPT_OUT_APP/Contents/Resources/bin/cmux-tui"
grep -q 'warning: installing an unattested cmux-tui manifest' "$TEST_DIR/opt-out.log"
if grep -q '^gh ' "$EVENTS"; then
  echo "FAIL: --allow-unattested still invoked gh" >&2
  exit 1
fi
echo "PASS: --allow-unattested is the only unverified remote install path"

# Architecture selection is opt-in: the existing default still fetches and
# verifies both slices, while a native install never requests the other slice.
install_remote "$TEST_DIR/Universal.app" > "$TEST_DIR/universal.log" 2>&1
grep -q 'curl .*cmux-tui-aarch64-apple-darwin$' "$EVENTS"
grep -q 'curl .*cmux-tui-x86_64-apple-darwin$' "$EVENTS"
grep -q '^lipo -create ' "$EVENTS"
grep -q '^lipo .* -verify_arch arm64$' "$EVENTS"
grep -q '^lipo .* -verify_arch x86_64$' "$EVENTS"
echo "PASS: remote default remains universal"
install_remote "$TEST_DIR/ExplicitUniversal.app" --arch universal > "$TEST_DIR/explicit-universal.log" 2>&1
grep -q 'curl .*cmux-tui-aarch64-apple-darwin$' "$EVENTS"
grep -q 'curl .*cmux-tui-x86_64-apple-darwin$' "$EVENTS"
grep -q '^lipo -create ' "$EVENTS"
echo "PASS: explicit universal mode fetches both slices"


# Make slices distinct so copying the wrong slice cannot pass the comparison.
printf '\n# Intel fixture\n' >> "$SERVE/cmux-tui-x86_64-apple-darwin"
X64_SHA="$(slice_sha "$SERVE/cmux-tui-x86_64-apple-darwin")"
cat > "$SERVE/manifest.json" <<JSON
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA"}}
JSON
for arch in arm64 x86_64; do
  if [[ "$arch" == arm64 ]]; then slice=aarch64; other=x86_64; else slice=x86_64; other=aarch64; fi
  native_app="$TEST_DIR/Native-$arch.app"
  install_remote "$native_app" --arch "$arch" --expected-commit "$COMMIT" \
    --require-capability wireguard-hub > "$TEST_DIR/native-$arch.log" 2>&1
  cmp "$SERVE/cmux-tui-$slice-apple-darwin" "$native_app/Contents/Resources/bin/cmux-tui"
  grep -q "^gh attestation verify .* --source-digest $COMMIT\$" "$EVENTS"
  grep -q "curl .*cmux-tui-$slice-apple-darwin\$" "$EVENTS"
  [[ "$(sed -n '2p' "$EVENTS" | cut -d' ' -f1-3)" == "gh attestation verify" ]]
  [[ "$(sed -n '3p' "$EVENTS")" == "curl https://files.example.test/cmux-tui/$COMMIT/cmux-tui-$slice-apple-darwin" ]]

  if grep -q "curl .*cmux-tui-$other-apple-darwin\$" "$EVENTS"; then
    echo "FAIL: $arch fetched the unrequested slice" >&2; exit 1
  fi
  if grep -q '^lipo -create ' "$EVENTS"; then
    echo "FAIL: $arch unnecessarily created a universal binary" >&2; exit 1
  fi
  grep -q "^lipo .* -verify_arch $arch\$" "$EVENTS"
  echo "PASS: $arch installs only its attested, verified slice"

  if FAKE_GH_EXIT=1 install_remote "$TEST_DIR/NativeDenied-$arch.app" --arch "$arch" > "$TEST_DIR/native-denied.log" 2>&1; then
    echo "FAIL: native install skipped manifest attestation" >&2; exit 1
  fi
  if grep -q 'curl .*apple-darwin$' "$EVENTS"; then
    echo "FAIL: native install fetched a slice before attestation passed" >&2; exit 1
  fi
  if FAKE_LIPO_EXIT=1 install_remote "$TEST_DIR/WrongArch-$arch.app" --arch "$arch" > "$TEST_DIR/wrong-arch.log" 2>&1; then
    echo "FAIL: native install ignored architecture verification failure" >&2; exit 1
  fi
  if install_remote "$TEST_DIR/MissingCapability-$arch.app" --arch "$arch" --require-capability missing > "$TEST_DIR/native-capability.log" 2>&1; then
    echo "FAIL: native install skipped capability verification" >&2; exit 1
  fi
  grep -q 'required cmux-tui capability is missing: missing' "$TEST_DIR/native-capability.log"
  # The selected slice must match the authenticated manifest even in native mode.
  cp "$SERVE/cmux-tui-$slice-apple-darwin" "$TEST_DIR/original-slice"
  printf '\n# corrupt bytes\n' >> "$SERVE/cmux-tui-$slice-apple-darwin"
  if install_remote "$TEST_DIR/BadDigest-$arch.app" --arch "$arch" > "$TEST_DIR/bad-digest.log" 2>&1; then
    echo "FAIL: native install ignored the selected slice digest" >&2; exit 1
  fi
  grep -q "sha256 mismatch for cmux-tui-$slice-apple-darwin" "$TEST_DIR/bad-digest.log"
  [[ ! -e "$TEST_DIR/BadDigest-$arch.app/Contents/Resources/bin/cmux-tui" ]]
  mv "$TEST_DIR/original-slice" "$SERVE/cmux-tui-$slice-apple-darwin"
  echo "PASS: $arch keeps attestation, architecture, capability and digest checks"
done
if install_remote "$TEST_DIR/UnknownArch.app" --arch sparc > "$TEST_DIR/unknown-arch.log" 2>&1; then
  echo "FAIL: accepted unsupported architecture" >&2; exit 1
fi
grep -q 'unsupported cmux-tui architecture' "$TEST_DIR/unknown-arch.log"
[[ ! -s "$EVENTS" ]]
echo "PASS: unsupported architecture fails before network access"

# Native means the hardware architecture, including an Intel process translated
# by Rosetta on Apple Silicon. Exercise through the actual installer entry point.
cat > "$FAKEBIN/uname" <<'SH'
#!/bin/bash
[[ "$1" == -m ]] || exit 64
printf '%s\n' "${FAKE_HOST_ARCH:-arm64}"
SH
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/bash
[[ "$*" == '-in hw.optional.arm64' ]] || exit 64
[[ "${FAKE_SYSCTL_EXIT:-0}" == 0 ]] || exit "$FAKE_SYSCTL_EXIT"
printf '%s\n' "${FAKE_ARM_CAPABLE:-0}"
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/sysctl"
for scenario in apple-silicon intel rosetta sysctl-unavailable aarch64; do
  host=arm64; capable=1; sysctl_exit=0; wanted=aarch64; rejected=x86_64
  case "$scenario" in
    intel) host=x86_64; capable=0; wanted=x86_64; rejected=aarch64 ;;
    rosetta) host=x86_64 ;;
    sysctl-unavailable) host=x86_64; capable=0; sysctl_exit=1; wanted=x86_64; rejected=aarch64 ;;
    aarch64) host=aarch64 ;;
  esac
  FAKE_HOST_ARCH="$host" FAKE_ARM_CAPABLE="$capable" FAKE_SYSCTL_EXIT="$sysctl_exit" \
    install_remote "$TEST_DIR/NativeHost-$scenario.app" --arch native \
    --require-capability wireguard-hub > "$TEST_DIR/native-host-$scenario.log" 2>&1
  cmp "$SERVE/cmux-tui-$wanted-apple-darwin" "$TEST_DIR/NativeHost-$scenario.app/Contents/Resources/bin/cmux-tui"
  grep -q "curl .*cmux-tui-$wanted-apple-darwin\$" "$EVENTS"
  if grep -q "curl .*cmux-tui-$rejected-apple-darwin\$" "$EVENTS"; then
    echo "FAIL: native $scenario selected the wrong client slice" >&2; exit 1
  fi
  echo "PASS: native $scenario selects $wanted"
done
if FAKE_HOST_ARCH=unsupported install_remote "$TEST_DIR/UnknownNative.app" --arch native > "$TEST_DIR/unknown-native.log" 2>&1; then
  echo "FAIL: accepted an unsupported native host architecture" >&2; exit 1
fi
[[ ! -s "$EVENTS" ]]
echo "PASS: unsupported native host fails before network access"
