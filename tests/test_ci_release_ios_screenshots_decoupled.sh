#!/usr/bin/env bash
# Regression guard for https://github.com/manaflow-ai/cmux/issues/12149.
# The stable macOS release must not wait on, or fail because of, the iOS App
# Store screenshot capture: build-sign-notarize consumes nothing from it, and
# the capture is a long simulator run on shared macOS runners. Keep the capture
# as a sibling job in release.yml (every tag still gets screenshots at the
# release ref) but never as a dependency of the DMG pipeline.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${CMUX_RELEASE_WORKFLOW_FILE:-$ROOT_DIR/.github/workflows/release.yml}"

job_block() {
  awk -v job="$1" '
    $0 == "  " job ":" { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { exit }
    in_job { print }
  ' "$WORKFLOW"
}

screenshots="$(job_block generate-ios-screenshots)"
if [ -z "$screenshots" ] || ! grep -Eq '^    uses: \./\.github/workflows/ios-screenshots\.yml$' <<<"$screenshots"; then
  echo "FAIL: release.yml must keep the generate-ios-screenshots job calling ./.github/workflows/ios-screenshots.yml" >&2
  exit 1
fi

notarize="$(job_block build-sign-notarize)"
if [ -z "$notarize" ]; then
  echo "FAIL: build-sign-notarize job not found in $WORKFLOW" >&2
  exit 1
fi

# needs: may be a scalar (`needs: job`) or a block sequence (`needs:` + `- job` lines).
needs="$(
  awk '
    /^    needs:/ { in_needs = 1; sub(/^    needs:[[:space:]]*/, ""); if ($0 != "") print; next }
    in_needs && /^      - / { sub(/^      - /, ""); print; next }
    in_needs { in_needs = 0 }
  ' <<<"$notarize" | sed -E 's/[[:space:]]*#.*$//; s/^\[//; s/\]$//; s/,/\n/g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d'
)"

if ! grep -qx 'build-ghostty-cli-helper' <<<"$needs"; then
  echo "FAIL: build-sign-notarize must keep needs: build-ghostty-cli-helper (got: $(tr '\n' ' ' <<<"$needs"))" >&2
  exit 1
fi

if grep -qx 'generate-ios-screenshots' <<<"$needs"; then
  cat >&2 <<'MSG'
FAIL: build-sign-notarize must not depend on generate-ios-screenshots.

      The macOS DMG never consumes the screenshot artifacts, and the capture is
      a long simulator run that must not delay or fail a stable release. If the
      release really needs the screenshots, download them in a step instead of
      gating the whole job on the capture, and update this guard with the reason.
MSG
  exit 1
fi

echo "PASS: build-sign-notarize does not wait on iOS screenshot capture (needs: $(tr '\n' ' ' <<<"$needs"| sed 's/ $//'))"
