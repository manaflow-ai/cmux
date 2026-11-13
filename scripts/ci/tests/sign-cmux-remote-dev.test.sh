#!/usr/bin/env bash
# Local contract test for the main-only Remote signer and its workflow route.
# This is intentionally not a GitHub job: codesign/ditto are macOS-only, while
# the checks below catch accidental credential-boundary and pin-shape changes
# on any checkout.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
signer="$scripts/ci/sign-cmux-remote-dev.sh"
workflow="$scripts/../.github/workflows/cmux-next-cua-helper-dev-sign.yml"

bash -n "$signer"
grep -Fq 'com.cmuxterm.remote.dev' "$signer"
grep -Fq 'Developer ID Application' "$signer"
grep -Fq 'TeamIdentifier=' "$signer"
grep -Fq 'libWebRTC.dylib' "$signer"
grep -Fq 'libcua_driver_sdk.dylib' "$signer"
if grep -Eq 'mapfile|readarray|-maxdepth|-quit' "$signer"; then
  echo "sign-cmux-remote-dev.sh must run on macOS Bash/find" >&2
  exit 1
fi
grep -Fq 'cua-helper-dev/{sha}/cmux-remote-dev-macos-arm64.zip' "$signer"
if grep -Fq 'Apple Development' "$signer"; then
  echo "sign-cmux-remote-dev.sh must reject Apple Development identities" >&2
  exit 1
fi

grep -Fq 'type: choice' "$workflow"
grep -Fq -- '- remote' "$workflow"
grep -Fq 'scripts/ci/sign-cmux-remote-dev.sh' "$workflow"
grep -Fq 'environment: release' "$workflow"
grep -Fq 'environment: cef-publish' "$workflow"
grep -Fq 'CMUX_CEF_R2_WRITE_ACCESS_KEY_ID' "$workflow"
grep -Fq 'cmux-remote-dev.pin.json' "$workflow"
grep -Fq 'cmux-next-helper-dev-signed' "$workflow"
grep -Fq 'product="cmux Remote"' "$workflow"
echo "cmux Remote signing route contract: ok"
