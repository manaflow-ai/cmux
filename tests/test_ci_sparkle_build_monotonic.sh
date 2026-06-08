#!/usr/bin/env bash
# Regression test for the Sparkle "stuck build number" bug that broke updates
# from v0.63.1 -> v0.63.2 (both shipped with CURRENT_PROJECT_VERSION=78, so
# Sparkle saw the same build number and refused to offer the update).
#
# Invariant: the local CURRENT_PROJECT_VERSION must be strictly greater than
# the Sparkle build number in the latest published stable appcast. Sparkle
# compares CFBundleVersion (CURRENT_PROJECT_VERSION) against <sparkle:version>
# — the marketing string is informational only.
#
# If the published appcast cannot be fetched locally, the test soft-passes with
# a warning so offline developer machines can still run pretag checks. In CI,
# the release guard fails closed because a missing appcast means Sparkle update
# eligibility was not verified.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/cmux.xcodeproj/project.pbxproj"
APPCAST_URL="${CMUX_SPARKLE_APPCAST_URL:-https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml}"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "FAIL: $PROJECT_FILE not found" >&2
  exit 1
fi

LOCAL_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= //;s/;.*//')
if ! [[ "$LOCAL_BUILD" =~ ^[0-9]+$ ]]; then
  echo "FAIL: could not parse CURRENT_PROJECT_VERSION (got '$LOCAL_BUILD')" >&2
  exit 1
fi

# Sanity check: every CURRENT_PROJECT_VERSION in the project must match.
# Mixed values would mean some build configs ship with a stale build number.
MISMATCHED=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u | wc -l | tr -d ' ')
if [[ "$MISMATCHED" != "1" ]]; then
  echo "FAIL: CURRENT_PROJECT_VERSION values are inconsistent across build configurations:" >&2
  grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u >&2
  exit 1
fi

PUBLISHED_BUILD=$(curl -fsSL --max-time 15 "$APPCAST_URL" 2>/dev/null \
  | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
  | head -n1 || true)

if ! [[ "$PUBLISHED_BUILD" =~ ^[0-9]+$ ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" ]]; then
    echo "FAIL: could not fetch or parse latest published Sparkle build from appcast.xml" >&2
    echo "      Refusing to skip the monotonic release guard in CI." >&2
    exit 1
  fi

  echo "WARN: could not fetch latest published Sparkle build; skipping local-only monotonic check"
  echo "PASS (local soft): local CURRENT_PROJECT_VERSION=$LOCAL_BUILD"
  exit 0
fi

if (( LOCAL_BUILD <= PUBLISHED_BUILD )); then
  cat >&2 <<EOF
FAIL: CURRENT_PROJECT_VERSION ($LOCAL_BUILD) must be strictly greater than the
      latest published Sparkle build ($PUBLISHED_BUILD).

      Sparkle compares build numbers, not the marketing version. If you ship a
      release with the same build number as a previously-published release,
      existing users will never receive the update.

      Run \`./scripts/bump-version.sh\` (which auto-corrects the build number
      against the published appcast), commit the change, and re-push.
EOF
  exit 1
fi

echo "PASS: local CURRENT_PROJECT_VERSION=$LOCAL_BUILD > published Sparkle build=$PUBLISHED_BUILD"
