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
# One binary: invoked as acpmux (argv[0]) it answers acpmux --version, as in
# cmux-tui's main.rs.
cat > "$CLIENT" <<'SH'
#!/bin/sh
if [ "$(basename "$0")" = acpmux ]; then
  [ "$1" = --version ] || exit 64
  printf '%s\n' 'acpmux 0.1.0 (test)'
  exit 0
fi
[ "$1" = remote-probe ] && [ "$2" = --json ] || exit 64
if [ "${FAKE_SSH_MACOS_FROM_CLIENT:-0}" = 1 ]; then
  printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub","test-capability","ssh-payload-download","ssh-payload-macos-from-client"]}'
elif [ "${FAKE_SSH_PAYLOAD_DOWNLOAD:-0}" = 1 ]; then
  printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub","test-capability","ssh-payload-download"]}'
else
  printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub","test-capability"]}'
fi
SH
chmod +x "$CLIENT"

install_client() {
  # Exercise the runner's system Bash: macOS ships 3.2, whose nounset handling
  # differs from modern Bash for an initialized but empty array.
  CMUX_TUI_CLIENT_LOCAL="$CLIENT" /bin/bash \
    "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$APP" "$@"
}

assert_layout() { # <app>: bin/cmux is the file, cmux-tui and acpmux link to it
  local bin="$1/Contents/Resources/bin" name
  [ -f "$bin/cmux" ] && [ ! -L "$bin/cmux" ]
  for name in cmux-tui acpmux; do
    [ -L "$bin/$name" ] && [ "$(readlink "$bin/$name")" = cmux ]
  done
}

install_client
cmp "$CLIENT" "$APP/Contents/Resources/bin/cmux"
assert_layout "$APP"
# Release bundles carry no agent screen detector until its notices are mapped
# (scripts/cmux-next/bundle-cmux-tui.sh places it in dev builds only): an
# install drops a stale copy, even one beside a local client.
printf stale > "$APP/Contents/Resources/bin/cmux-agent-screen-detection"
printf detector > "$TEST_DIR/cmux-agent-screen-detection"
install_client
[ ! -e "$APP/Contents/Resources/bin/cmux-agent-screen-detection" ]
rm -f "$TEST_DIR/cmux-agent-screen-detection"
# A reinstall over an earlier layout (a real bin/cmux-tui and bin/acpmux)
# replaces both files with the symlinks.
rm "$APP/Contents/Resources/bin/cmux-tui" "$APP/Contents/Resources/bin/acpmux"
cp "$CLIENT" "$APP/Contents/Resources/bin/cmux-tui"
cp "$CLIENT" "$APP/Contents/Resources/bin/acpmux"
install_client
assert_layout "$APP"
echo "PASS: bin/cmux is the binary; cmux-tui and acpmux are relative symlinks to it"
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
  cmp "$CLIENT" "$APP/Contents/Resources/bin/cmux"
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
cp "$CLIENT" "$SERVE/cmux-tui-aarch64-unknown-linux-musl"
cp "$CLIENT" "$SERVE/cmux-tui-x86_64-unknown-linux-musl"
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
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA","cmux-tui-aarch64-unknown-linux-musl":"$ARM_SHA","cmux-tui-x86_64-unknown-linux-musl":"$ARM_SHA"}}
JSON
cat > "$FAKEBIN/curl" <<SH
#!/bin/bash
url=""; out=""; args="\$*"
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    http://*|https://*) url="\$1" ;;
  esac
  shift
done
# The published Sigstore bundle (cmux-tui-attestations/) is logged to its own
# file, so the ordering checks below read only the manifest and slices. It is
# served only when a case put it in \$SERVE; otherwise it answers like a 404.
if [[ "\$url" == */cmux-tui-attestations/* ]]; then
  printf 'bundle %s\n' "\$url" >> "$EVENTS.bundle"
  [[ -f "$SERVE/\$(basename "\$url")" ]] || exit 22
  cp "$SERVE/\$(basename "\$url")" "\$out"
  exit 0
fi
printf 'curl %s\n' "\$url" >> "$EVENTS"
if [[ -n "\${FAKE_CURL_ARGS_LOG:-}" ]]; then printf '%s\n' "\$args" >> "\$FAKE_CURL_ARGS_LOG"; fi
if [[ "\${FAKE_CURL_FAIL_MANIFEST:-0}" == 1 && "\$url" == */manifest.json ]]; then
  printf 'incomplete manifest\n' > "\$out"
  exit 22
fi
if [[ "\${FAKE_CURL_RESUME_RESET:-0}" == 1 && "\$url" == */cmux-tui-aarch64-apple-darwin ]]; then
  marker="\$out.resume-reset-seen"
  if [[ ! -e "\$marker" ]]; then
    printf 'stale partial\n' > "\$out"
    : > "\$marker"
    exit 33
  fi
  [[ "\$args" == *'--continue-at -'* ]] || { echo 'missing resume flag' >&2; exit 99; }
  [[ ! -s "\$out" ]] || { echo 'rejected partial was not removed' >&2; exit 99; }
fi
if [[ "\${FAKE_CURL_TRANSIENT_503:-0}" == 1 && "\$url" == */cmux-tui-aarch64-apple-darwin ]]; then
  marker="\$out.transient-503-seen"
  if [[ ! -e "\$marker" ]]; then
    head -c 4 "$SERVE/\$(basename "\$url")" > "\$out"
    : > "\$marker"
    printf '503'
    exit 22
  fi
  [[ "\$args" == *'--continue-at -'* && -s "\$out" ]] || { echo 'transient HTTP failure did not resume its partial' >&2; exit 99; }
  printf 'resume-preserved\n' >> "$EVENTS"
fi
cp "$SERVE/\$(basename "\$url")" "\$out"
SH
cat > "$FAKEBIN/gh" <<SH
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$EVENTS"
# A verify against a downloaded bundle (--bundle) is offline: it never meets the
# API quota. FAKE_GH_BUNDLE_EXIT is its verdict.
if [[ " \$* " == *" --bundle "* ]]; then exit "\${FAKE_GH_BUNDLE_EXIT:-0}"; fi
# FAKE_GH_RATE_LIMITED_FILE holds how many more calls answer like an exhausted
# GitHub API installation quota (nightly run 37526635018) before gh recovers.
if [ -n "\${FAKE_GH_RATE_LIMITED_FILE:-}" ]; then
  left="\$(cat "\$FAKE_GH_RATE_LIMITED_FILE")"
  if [ "\$left" -gt 0 ]; then
    echo \$((left - 1)) > "\$FAKE_GH_RATE_LIMITED_FILE"
    echo "Error: HTTP 403: API rate limit exceeded for installation." >&2
    exit 1
  fi
fi
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
cat > "$FAKEBIN/codesign" <<'SH'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$EVENTS"
exit 0
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/gh" "$FAKEBIN/lipo" "$FAKEBIN/codesign"

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
  : > "$EVENTS.bundle"
  REMOTE_INSTALL_SEQ=$((REMOTE_INSTALL_SEQ + 1))
  PATH="$FAKEBIN:$PATH" CMUX_TUI_CLIENT_CACHE="$TEST_DIR/cache-$REMOTE_INSTALL_SEQ" \
    CMUX_TUI_CLIENT_DOWNLOAD_MAX_SECONDS="$DOWNLOAD_BUDGET" /bin/bash \
    "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$app" \
    --manifest-url "https://files.example.test/cmux-tui/$COMMIT/manifest.json" "$@"
}

export FAKE_CURL_ARGS_LOG="$TEST_DIR/curl-args.log"
DOWNLOAD_BUDGET=600
: > "$FAKE_CURL_ARGS_LOG"
ATTESTED_APP="$TEST_DIR/Attested.app"
install_remote "$ATTESTED_APP" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
  --require-capability wireguard-hub > "$TEST_DIR/attested.log" 2>&1
cmp "$CLIENT" "$ATTESTED_APP/Contents/Resources/bin/cmux"
grep -q "^gh attestation verify .*manifest.* --repo manaflow-ai/cmux --signer-workflow $SIGNER --source-digest $COMMIT\$" "$EVENTS"
# The manifest is verified before any slice it names is fetched.
[ "$(sed -n '1p' "$EVENTS")" = "curl https://files.example.test/cmux-tui/$COMMIT/manifest.json" ]
[ "$(sed -n '2p' "$EVENTS" | cut -d' ' -f1-3)" = "gh attestation verify" ]
[ "$(sed -n '3p' "$EVENTS")" = "curl https://files.example.test/cmux-tui/$COMMIT/cmux-tui-aarch64-apple-darwin" ]
echo "PASS: attested manifest is verified before slices are downloaded"
# Manifest downloads are never resumed, while binary slices use range resumes
# and inherit the total per-download deadline. A fast retry may receive less
# than the full budget, but never exceeds it.
awk -v budget="$DOWNLOAD_BUDGET" '
  BEGIN { valid = 1 }
  {
    found = 0
    for (i = 1; i < NF; i++) {
      if ($i == "--max-time") {
        found = 1
        value = $(i + 1)
        if (value !~ /^[1-9][0-9]*$/ || (value + 0) > budget) valid = 0
      }
    }
    if (!found) valid = 0
  }
  END { exit !(valid && NR > 0) }
' "$FAKE_CURL_ARGS_LOG"
grep -q -- '--continue-at -' "$FAKE_CURL_ARGS_LOG"
manifest_args="$(sed -n '1p' "$FAKE_CURL_ARGS_LOG")"
[[ "$manifest_args" != *'--continue-at -'* ]]
echo "PASS: manifest is atomic and slices are resumable within a bounded budget"

# A rejected range must delete the stale partial before the final retry. The
# fake server checks both the resume flag and that the second attempt starts
# from an empty temporary file.
RESUME_APP="$TEST_DIR/ResumeReset.app"
FAKE_CURL_RESUME_RESET=1 install_remote "$RESUME_APP" --arch arm64 > "$TEST_DIR/resume-reset.log" 2>&1
cmp "$CLIENT" "$RESUME_APP/Contents/Resources/bin/cmux-tui"
echo "PASS: rejected ranges clear partial slices before retrying"

# A transient HTTP error must preserve a valid partial so the next attempt can
# resume it instead of restarting within the same bounded download budget.
TRANSIENT_APP="$TEST_DIR/Transient503.app"
FAKE_CURL_TRANSIENT_503=1 install_remote "$TRANSIENT_APP" --arch arm64 > "$TEST_DIR/transient-503.log" 2>&1
cmp "$CLIENT" "$TRANSIENT_APP/Contents/Resources/bin/cmux-tui"
grep -q '^resume-preserved$' "$EVENTS"
echo "PASS: transient HTTP failures preserve resumable partial slices"

# A manifest is published only after a complete successful download. A failed
# manifest request must leave neither the final cache path nor a reusable temp.
FAILED_MANIFEST_CACHE="$TEST_DIR/failed-manifest-cache"
mkdir -p "$FAILED_MANIFEST_CACHE"
mkdir -p "$TEST_DIR/FailedManifest.app/Contents"
if FAKE_CURL_FAIL_MANIFEST=1 PATH="$FAKEBIN:$PATH" \
    CMUX_TUI_CLIENT_CACHE="$FAILED_MANIFEST_CACHE" \
    CMUX_TUI_CLIENT_DOWNLOAD_MAX_SECONDS="$DOWNLOAD_BUDGET" \
    /bin/bash "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$TEST_DIR/FailedManifest.app" \
    --manifest-url "https://files.example.test/cmux-tui/$COMMIT/manifest.json" --allow-unattested \
    > "$TEST_DIR/failed-manifest.log" 2>&1; then
  echo "FAIL: installed after a failed manifest download" >&2
  exit 1
fi
if find "$FAILED_MANIFEST_CACHE" -maxdepth 1 -name 'manifest.*' -print -quit | grep -q .; then
  echo "FAIL: failed manifest was published" >&2
  exit 1
fi
echo "PASS: failed manifest downloads are never published"


UNATTESTED_APP="$TEST_DIR/Unattested.app"
if FAKE_GH_EXIT=1 install_remote "$UNATTESTED_APP" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
    > "$TEST_DIR/unattested.log" 2>&1; then
  echo "FAIL: installed a client from a manifest without a valid attestation" >&2
  exit 1
fi
grep -q 'no valid build-provenance attestation for the cmux-tui manifest' "$TEST_DIR/unattested.log"
[ ! -e "$UNATTESTED_APP/Contents/Resources/bin/cmux" ]
if grep -q 'apple-darwin' "$EVENTS"; then
  echo "FAIL: downloaded a slice named by an unverified manifest" >&2
  exit 1
fi
echo "PASS: a manifest without a valid attestation installs nothing"

# An exhausted API quota is not a verdict on the attestation. The installer
# waits and asks again instead of failing a 40-minute signed nightly leg.
RATE_LIMITED_APP="$TEST_DIR/RateLimited.app"
echo 2 > "$TEST_DIR/rate-limited-left"
FAKE_GH_RATE_LIMITED_FILE="$TEST_DIR/rate-limited-left" CMUX_TUI_ATTEST_RETRY_DELAY_SECONDS=0 \
  install_remote "$RATE_LIMITED_APP" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
  > "$TEST_DIR/rate-limited.log" 2>&1 || {
    echo "FAIL: a rate-limited attestation lookup failed the install instead of retrying" >&2
    cat "$TEST_DIR/rate-limited.log" >&2
    exit 1
  }
cmp "$CLIENT" "$RATE_LIMITED_APP/Contents/Resources/bin/cmux-tui"
[ "$(grep -c '^gh attestation verify' "$EVENTS")" = 3 ]
echo "PASS: a rate-limited attestation lookup is retried, then verified"

# A quota that never resets ends the loop after the default retries (sized to
# outlast GitHub's hourly reset), and the error names the rate limit instead
# of claiming the manifest has no valid attestation.
echo 1000 > "$TEST_DIR/rate-limited-forever"
# Delay 0 runs all nine retries instantly instead of sleeping through the 65-minute schedule.
FAKE_GH_RATE_LIMITED_FILE="$TEST_DIR/rate-limited-forever" CMUX_TUI_ATTEST_RETRY_DELAY_SECONDS=0 \
  install_remote "$TEST_DIR/RateLimitedForever.app" --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" \
  > "$TEST_DIR/rate-limited-forever.log" 2>&1 && {
    echo "FAIL: installed while the attestation lookup stayed rate-limited" >&2
    exit 1
  }
[ "$(grep -c '^gh attestation verify' "$EVENTS")" = 10 ] || {
  echo "FAIL: expected 1 attempt + 9 retries, got $(grep -c '^gh attestation verify' "$EVENTS")" >&2
  exit 1
}
grep -q 'error: the GitHub API rate limit did not reset' "$TEST_DIR/rate-limited-forever.log" || {
  echo "FAIL: exhausted rate-limit retries did not report the rate limit" >&2
  cat "$TEST_DIR/rate-limited-forever.log" >&2
  exit 1
}
if grep -q 'no valid build-provenance attestation' "$TEST_DIR/rate-limited-forever.log"; then
  echo "FAIL: exhausted rate-limit retries claimed the attestation is invalid" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/RateLimitedForever.app/Contents/Resources/bin/cmux" ]
echo "PASS: a rate limit that never resets stops after the retries with a rate-limit error"

# A real verification failure is final on the first answer.
FAKE_GH_EXIT=1 CMUX_TUI_ATTEST_RETRY_DELAY_SECONDS=0 install_remote "$TEST_DIR/Rejected.app" \
  --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" > "$TEST_DIR/rejected.log" 2>&1 && {
    echo "FAIL: installed after a rejected attestation" >&2
    exit 1
  }
[ "$(grep -c '^gh attestation verify' "$EVENTS")" = 1 ]
echo "PASS: a rejected attestation is not retried"

# The publisher uploads the manifest's Sigstore bundle under its digest
# (cmux-tui-artifacts.yml, "Publish the manifest's Sigstore bundle"). With it the
# attestation is verified offline, so a spent API quota holds nothing: nightly
# run 41150090913 (2026-10-31) waited 37 minutes for the quota in "Bundle the
# cmux-tui client" with its app compiled.
MANIFEST_DIGEST="$(slice_sha "$SERVE/manifest.json")"
BUNDLE_NAME="sha256-$MANIFEST_DIGEST.sigstore.json"
printf '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n' > "$SERVE/$BUNDLE_NAME"
echo 1000 > "$TEST_DIR/bundle-rate-limited"
FAKE_GH_RATE_LIMITED_FILE="$TEST_DIR/bundle-rate-limited" CMUX_TUI_ATTEST_RETRY_DELAY_SECONDS=0 \
  CMUX_TUI_ATTEST_RATE_LIMIT_RETRIES=0 install_remote "$TEST_DIR/Bundled.app" \
  --expected-commit "$COMMIT" --attest-signer-workflow "$SIGNER" > "$TEST_DIR/bundled.log" 2>&1 || {
    echo "FAIL: a published bundle did not let the install through a spent API quota" >&2
    cat "$TEST_DIR/bundled.log" >&2; exit 1; }
cmp "$CLIENT" "$TEST_DIR/Bundled.app/Contents/Resources/bin/cmux"
grep -q "^bundle https://files.example.test/cmux-tui-attestations/$BUNDLE_NAME\$" "$EVENTS.bundle"
[ "$(grep -c '^gh ' "$EVENTS")" = 1 ] || { echo "FAIL: the bundled install also asked the API" >&2; cat "$EVENTS" >&2; exit 1; }
grep -q "^gh attestation verify .*manifest.* --bundle .* --repo manaflow-ai/cmux --signer-workflow $SIGNER --source-digest $COMMIT\$" "$EVENTS"
# Verified before any slice is fetched.
[ "$(grep -n '^gh attestation verify' "$EVENTS" | cut -d: -f1)" -lt "$(grep -n 'cmux-tui-aarch64-apple-darwin$' "$EVENTS" | head -1 | cut -d: -f1)" ]
echo "PASS: a published Sigstore bundle verifies the manifest offline, through a spent API quota"

# A bundle that does not verify admits nothing by itself: the API lookup decides.
FAKE_GH_BUNDLE_EXIT=1 install_remote "$TEST_DIR/BadBundle.app" --expected-commit "$COMMIT" \
  --attest-signer-workflow "$SIGNER" > "$TEST_DIR/bad-bundle.log" 2>&1
cmp "$CLIENT" "$TEST_DIR/BadBundle.app/Contents/Resources/bin/cmux"
[ "$(grep -c '^gh attestation verify .* --bundle ' "$EVENTS")" = 1 ]
[ "$(grep '^gh attestation verify' "$EVENTS" | grep -vc -- ' --bundle ')" = 1 ]
grep -q 'did not verify; asking the GitHub attestations API' "$TEST_DIR/bad-bundle.log"
if FAKE_GH_BUNDLE_EXIT=1 FAKE_GH_EXIT=1 install_remote "$TEST_DIR/BadBoth.app" --expected-commit "$COMMIT" \
  --attest-signer-workflow "$SIGNER" > "$TEST_DIR/bad-both.log" 2>&1; then
  echo "FAIL: installed with a rejected bundle and a rejected API attestation" >&2; exit 1
fi
[ ! -e "$TEST_DIR/BadBoth.app/Contents/Resources/bin/cmux" ]
grep -q 'no valid build-provenance attestation' "$TEST_DIR/bad-both.log"
rm -f "$SERVE/$BUNDLE_NAME"
echo "PASS: a bundle that does not verify falls back to the API lookup and never admits on its own"

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
cmp "$CLIENT" "$DEFAULT_APP/Contents/Resources/bin/cmux"
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
cmp "$CLIENT" "$OPT_OUT_APP/Contents/Resources/bin/cmux"
grep -q 'warning: installing an unattested cmux-tui manifest' "$TEST_DIR/opt-out.log"
if grep -q '^gh ' "$EVENTS"; then
  echo "FAIL: --allow-unattested still invoked gh" >&2
  exit 1
fi
echo "PASS: --allow-unattested is the only unverified remote install path"

# Architecture selection is opt-in: the existing default still fetches and
# verifies both slices. Native selects only its app executable; SSH companions cover every remote platform.
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
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA","cmux-tui-aarch64-unknown-linux-musl":"$ARM_SHA","cmux-tui-x86_64-unknown-linux-musl":"$ARM_SHA"}}
JSON
for arch in arm64 x86_64; do
  if [[ "$arch" == arm64 ]]; then slice=aarch64; other=x86_64; else slice=x86_64; other=aarch64; fi
  native_app="$TEST_DIR/Native-$arch.app"
  install_remote "$native_app" --arch "$arch" --expected-commit "$COMMIT" \
    --require-capability wireguard-hub > "$TEST_DIR/native-$arch.log" 2>&1
  cmp "$SERVE/cmux-tui-$slice-apple-darwin" "$native_app/Contents/Resources/bin/cmux"
  grep -q "^gh attestation verify .* --source-digest $COMMIT\$" "$EVENTS"
  grep -q "curl .*cmux-tui-$slice-apple-darwin\$" "$EVENTS"
  [[ "$(sed -n '2p' "$EVENTS" | cut -d' ' -f1-3)" == "gh attestation verify" ]]
  [[ "$(sed -n '3p' "$EVENTS")" == "curl https://files.example.test/cmux-tui/$COMMIT/cmux-tui-$slice-apple-darwin" ]]

  for target in aarch64-unknown-linux-musl x86_64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin; do
    cmp "$SERVE/cmux-tui-$target" "$native_app/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$target"
  done
  cmp "$SERVE/manifest.json" "$native_app/Contents/Resources/bin/cmux-tui-ssh/manifest.json"
  if grep -q '^lipo -create ' "$EVENTS"; then
    echo "FAIL: $arch unnecessarily created a universal binary" >&2; exit 1
  fi
  grep -q "^lipo .* -verify_arch $arch\$" "$EVENTS"
  echo "PASS: $arch installs its verified client and all verified SSH companion artifacts"

  # A client that downloads unbundled SSH payloads itself gets only the macOS
  # payloads (signed with the app) plus the manifest that pins every platform.
  ondemand_app="$TEST_DIR/OnDemand-$arch.app"
  FAKE_SSH_PAYLOAD_DOWNLOAD=1 install_remote "$ondemand_app" --arch "$arch" --expected-commit "$COMMIT" \
    --require-capability wireguard-hub > "$TEST_DIR/ondemand-$arch.log" 2>&1
  ondemand_ssh="$ondemand_app/Contents/Resources/bin/cmux-tui-ssh"
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cmp "$SERVE/cmux-tui-$target" "$ondemand_ssh/cmux-tui-$target"
  done
  for target in aarch64-unknown-linux-musl x86_64-unknown-linux-musl; do
    if [[ -e "$ondemand_ssh/cmux-tui-$target" ]]; then
      echo "FAIL: $arch bundled cmux-tui-$target although the client downloads it on demand" >&2; exit 1
    fi
  done
  cmp "$SERVE/manifest.json" "$ondemand_ssh/manifest.json"
  echo "PASS: $arch leaves Linux SSH payloads to a client that downloads them"

  # A client that uploads its own slice to a Mac (and downloads an architecture
  # it lacks) needs no SSH payload at all, only the manifest's pins.
  client_app="$TEST_DIR/FromClient-$arch.app"
  FAKE_SSH_MACOS_FROM_CLIENT=1 install_remote "$client_app" --arch "$arch" --expected-commit "$COMMIT" \
    --require-capability wireguard-hub > "$TEST_DIR/fromclient-$arch.log" 2>&1
  client_ssh="$client_app/Contents/Resources/bin/cmux-tui-ssh"
  for target in aarch64-unknown-linux-musl x86_64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin; do
    if [[ -e "$client_ssh/cmux-tui-$target" ]]; then
      echo "FAIL: $arch bundled cmux-tui-$target although the client serves macOS hosts itself" >&2; exit 1
    fi
  done
  cmp "$SERVE/manifest.json" "$client_ssh/manifest.json"
  echo "PASS: $arch bundles no SSH payload for a client that serves macOS hosts itself"

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
  [[ ! -e "$TEST_DIR/BadDigest-$arch.app/Contents/Resources/bin/cmux" ]]
  mv "$TEST_DIR/original-slice" "$SERVE/cmux-tui-$slice-apple-darwin"
  echo "PASS: $arch keeps attestation, architecture, capability and digest checks"
done
if install_remote "$TEST_DIR/UnknownArch.app" --arch sparc > "$TEST_DIR/unknown-arch.log" 2>&1; then
  echo "FAIL: accepted unsupported architecture" >&2; exit 1
fi
grep -q 'unsupported cmux-tui architecture' "$TEST_DIR/unknown-arch.log"
[[ ! -s "$EVENTS" ]]
echo "PASS: unsupported architecture fails before network access"

# The app host (apps-v1) installs beside the client when the manifest has it,
# and a manifest without it removes a copy left by an earlier install.
printf 'app host arm\n' > "$SERVE/cmux-tui-app-host-aarch64-apple-darwin"
printf 'app host intel\n' > "$SERVE/cmux-tui-app-host-x86_64-apple-darwin"
MANIFEST_WITHOUT_APP_HOST="$(cat "$SERVE/manifest.json")"
APP_HOST_ARM_SHA="$(slice_sha "$SERVE/cmux-tui-app-host-aarch64-apple-darwin")"
APP_HOST_X64_SHA="$(slice_sha "$SERVE/cmux-tui-app-host-x86_64-apple-darwin")"
cat > "$SERVE/manifest.json" <<JSON
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA","cmux-tui-aarch64-unknown-linux-musl":"$ARM_SHA","cmux-tui-x86_64-unknown-linux-musl":"$ARM_SHA","cmux-tui-app-host-aarch64-apple-darwin":"$APP_HOST_ARM_SHA","cmux-tui-app-host-x86_64-apple-darwin":"$APP_HOST_X64_SHA"}}
JSON
APP_HOST_APP="$TEST_DIR/AppHost.app"
install_remote "$APP_HOST_APP" --arch arm64 > "$TEST_DIR/app-host-arm.log" 2>&1
cmp "$SERVE/cmux-tui-app-host-aarch64-apple-darwin" "$APP_HOST_APP/Contents/Resources/bin/cmux-app-host"
[ -x "$APP_HOST_APP/Contents/Resources/bin/cmux-app-host" ]
# A thin slice keeps the signature it was published with.
if grep -q '^codesign ' "$EVENTS"; then
  echo "FAIL: a thin companion slice was signed again" >&2; exit 1
fi
install_remote "$TEST_DIR/AppHostUniversal.app" > "$TEST_DIR/app-host-universal.log" 2>&1
grep -q '^lipo -create .*cmux-tui-app-host-aarch64-apple-darwin' "$EVENTS"
[ -x "$TEST_DIR/AppHostUniversal.app/Contents/Resources/bin/cmux-app-host" ]
# The published x86_64 slices carry no signature (only arm64 links ad-hoc
# signed), so a lipo'd companion is signed ad hoc as a whole; unsigned, the
# tagged build's check-bundled-browser-host.sh refuses bin/cmux-browser-host.
grep -q '^codesign --force --sign - .*/AppHostUniversal.app/Contents/Resources/bin/cmux-app-host$' "$EVENTS"
printf '%s\n' "$MANIFEST_WITHOUT_APP_HOST" > "$SERVE/manifest.json"
install_remote "$APP_HOST_APP" --arch arm64 > "$TEST_DIR/app-host-gone.log" 2>&1
[ ! -e "$APP_HOST_APP/Contents/Resources/bin/cmux-app-host" ]
grep -q 'publishes no cmux-app-host' "$TEST_DIR/app-host-gone.log"
echo "PASS: the app host installs from the same build and a build without one removes it"

# The Cloud app server (cmux/cloud) installs beside the app host as bin/cmux-cloud the
# same way; a wrong sha256 is refused and leaves no binary; a build without it removes it.
printf 'cloud arm\n' > "$SERVE/cmux-tui-cloud-server-aarch64-apple-darwin"
printf 'cloud intel\n' > "$SERVE/cmux-tui-cloud-server-x86_64-apple-darwin"
CLOUD_ARM_SHA="$(slice_sha "$SERVE/cmux-tui-cloud-server-aarch64-apple-darwin")"
CLOUD_X64_SHA="$(slice_sha "$SERVE/cmux-tui-cloud-server-x86_64-apple-darwin")"
cloud_manifest() {
  cat > "$SERVE/manifest.json" <<JSON
{"commit":"$COMMIT","binaries":{"cmux-tui-aarch64-apple-darwin":"$ARM_SHA","cmux-tui-x86_64-apple-darwin":"$X64_SHA","cmux-tui-aarch64-unknown-linux-musl":"$ARM_SHA","cmux-tui-x86_64-unknown-linux-musl":"$ARM_SHA","cmux-tui-cloud-server-aarch64-apple-darwin":"$1","cmux-tui-cloud-server-x86_64-apple-darwin":"$CLOUD_X64_SHA"}}
JSON
}
CLOUD_APP="$TEST_DIR/Cloud.app"
cloud_manifest "$CLOUD_ARM_SHA"
install_remote "$CLOUD_APP" --arch arm64 > "$TEST_DIR/cloud-arm.log" 2>&1
cmp "$SERVE/cmux-tui-cloud-server-aarch64-apple-darwin" "$CLOUD_APP/Contents/Resources/bin/cmux-cloud"
[ -x "$CLOUD_APP/Contents/Resources/bin/cmux-cloud" ]
[ ! -e "$CLOUD_APP/Contents/Resources/bin/cmux-app-host" ]
cloud_manifest "$(printf '0%.0s' {1..64})"
if install_remote "$TEST_DIR/CloudBad.app" --arch arm64 > "$TEST_DIR/cloud-bad.log" 2>&1; then
  echo "FAIL: a wrong cmux-cloud sha256 was accepted" >&2; exit 1
fi
[ ! -e "$TEST_DIR/CloudBad.app/Contents/Resources/bin/cmux-cloud" ]
printf '%s\n' "$MANIFEST_WITHOUT_APP_HOST" > "$SERVE/manifest.json"
install_remote "$CLOUD_APP" --arch arm64 > "$TEST_DIR/cloud-gone.log" 2>&1
[ ! -e "$CLOUD_APP/Contents/Resources/bin/cmux-cloud" ]
grep -q 'publishes no cmux-cloud' "$TEST_DIR/cloud-gone.log"
echo "PASS: the Cloud app server installs from the same build, a wrong sha256 is refused, and a build without one removes it"

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
  cmp "$SERVE/cmux-tui-$wanted-apple-darwin" "$TEST_DIR/NativeHost-$scenario.app/Contents/Resources/bin/cmux"
  grep -q "curl .*cmux-tui-$wanted-apple-darwin\$" "$EVENTS"
  cmp "$SERVE/cmux-tui-$rejected-apple-darwin" "$TEST_DIR/NativeHost-$scenario.app/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$rejected-apple-darwin"
  echo "PASS: native $scenario selects $wanted"
done
if FAKE_HOST_ARCH=unsupported install_remote "$TEST_DIR/UnknownNative.app" --arch native > "$TEST_DIR/unknown-native.log" 2>&1; then
  echo "FAIL: accepted an unsupported native host architecture" >&2; exit 1
fi
[[ ! -s "$EVENTS" ]]
echo "PASS: unsupported native host fails before network access"

# --- acpmux (linked into the binary, run through bin/acpmux) -----------------
OLD_CLIENT="$TEST_DIR/old-client"
cat > "$OLD_CLIENT" <<'SH'
#!/bin/sh
[ "$1" = remote-probe ] && [ "$2" = --json ] || exit 64
printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub"]}'
SH
chmod +x "$OLD_CLIENT"

install_remote "$TEST_DIR/Acpmux.app" --arch arm64 --require-acpmux > "$TEST_DIR/acpmux.log" 2>&1
assert_layout "$TEST_DIR/Acpmux.app"
[ "$("$TEST_DIR/Acpmux.app/Contents/Resources/bin/acpmux" --version)" = 'acpmux 0.1.0 (test)' ]
if grep -q 'acpmux-' "$EVENTS"; then
  echo "FAIL: downloaded a separate acpmux binary" >&2; exit 1
fi
echo "PASS: acpmux runs from the installed binary with no separate download"

# A build from before acpmux was linked in still installs, with a warning,
# and fails with --require-acpmux.
mkdir -p "$TEST_DIR/OldLocal.app/Contents" "$TEST_DIR/OldRequired.app/Contents"
CMUX_TUI_CLIENT_LOCAL="$OLD_CLIENT" /bin/bash \
  "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$TEST_DIR/OldLocal.app" > "$TEST_DIR/old-local.log" 2>&1
assert_layout "$TEST_DIR/OldLocal.app"
grep -q 'warning: installed binary does not run acpmux through bin/acpmux' "$TEST_DIR/old-local.log"
if CMUX_TUI_CLIENT_LOCAL="$OLD_CLIENT" /bin/bash \
  "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$TEST_DIR/OldRequired.app" --require-acpmux > "$TEST_DIR/old-required.log" 2>&1; then
  echo "FAIL: --require-acpmux accepted a binary without acpmux" >&2
  exit 1
fi
grep -q 'error: installed binary does not run acpmux through bin/acpmux' "$TEST_DIR/old-required.log"
echo "PASS: a binary without acpmux warns, and fails with --require-acpmux"

# --- Stalled download -----------------------------------------------------------
# To curl, a dead HTTP/2 stream is a server that answers and then sends nothing.
# With no stall bound one Release job waited twenty minutes per attempt for the
# server to reset the stream and hit its job timeout (CI run 36685498203). Serve
# exactly that over TLS and require the real installer and the real curl to give
# up within the attempt budget instead of hanging.
STALL_DIR="$TEST_DIR/stall"
mkdir -p "$STALL_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$STALL_DIR/key.pem" -out "$STALL_DIR/cert.pem" > "$STALL_DIR/openssl.log" 2>&1
# The server certificate is self-signed; this test is about stalls, not trust.
printf 'insecure\n' > "$STALL_DIR/.curlrc"
python3 - "$STALL_DIR" <<'PY' &
import os, socket, ssl, sys, threading, time
root = sys.argv[1]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(f"{root}/cert.pem", f"{root}/key.pem")
listener = socket.create_server(("127.0.0.1", 0))
with open(f"{root}/port.tmp", "w") as handle:
    handle.write(str(listener.getsockname()[1]))
os.rename(f"{root}/port.tmp", f"{root}/port")
def stall(connection):
    try:
        with context.wrap_socket(connection, server_side=True) as tls:
            tls.recv(65536)
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n{")
            time.sleep(3600)
    except OSError:
        pass
while True:
    connection, _ = listener.accept()
    with open(f"{root}/connections", "a") as handle:
        handle.write("accepted\n")
    threading.Thread(target=stall, args=(connection,), daemon=True).start()
PY
STALL_SERVER_PID=$!
trap 'kill "$STALL_SERVER_PID" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
port_deadline=$((SECONDS + 10))
while (( SECONDS < port_deadline )) && [[ ! -s "$STALL_DIR/port" ]]; do
  sleep 0.1
done
[[ -s "$STALL_DIR/port" ]] || { echo "FAIL: stall server did not start" >&2; exit 1; }
STALL_PORT="$(cat "$STALL_DIR/port")"
mkdir -p "$TEST_DIR/Stalled.app/Contents"
stall_status=0
started=$SECONDS
CURL_HOME="$STALL_DIR" CMUX_TUI_CLIENT_DOWNLOAD_ATTEMPTS=2 CMUX_TUI_CLIENT_DOWNLOAD_STALL_SECONDS=2 \
  python3 -c 'import os, signal, subprocess, sys
child = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    sys.exit(child.wait(timeout=60))
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    sys.exit(124)' \
  /bin/bash "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$TEST_DIR/Stalled.app" --allow-unattested \
  --cache-dir "$STALL_DIR/cache" --manifest-url "https://127.0.0.1:$STALL_PORT/manifest.json" \
  > "$TEST_DIR/stalled.log" 2>&1 || stall_status=$?
if [[ "$stall_status" -eq 124 ]]; then
  echo "FAIL: a stalled download hung the installer for 60 s" >&2; cat "$TEST_DIR/stalled.log" >&2; exit 1
fi
if [[ "$stall_status" -eq 0 ]]; then
  echo "FAIL: installed from a stalled download" >&2; exit 1
fi
[[ ! -e "$TEST_DIR/Stalled.app/Contents/Resources/bin/cmux-tui" ]]
# The stall bound is what ended each attempt (curl exit 28, twice), the budget
# is what ended the install, and each attempt dialed its own connection.
[[ "$(grep -c '^curl: (28)' "$TEST_DIR/stalled.log")" -eq 2 ]] \
  || { echo "FAIL: the stall bound did not end both attempts" >&2; cat "$TEST_DIR/stalled.log" >&2; exit 1; }
grep -q "could not download https://127.0.0.1:$STALL_PORT/manifest.json after 2 attempts" "$TEST_DIR/stalled.log"
[[ "$(wc -l < "$STALL_DIR/connections" | tr -d ' ')" -eq 2 ]] \
  || { echo "FAIL: a retry reused the stalled connection" >&2; exit 1; }
echo "PASS: a stalled download fails after $((SECONDS - started)) s instead of hanging"
