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
# Modes (CMUX_SPARKLE_MONOTONIC_MODE):
#   enforce (default) - a stale build number fails, and so does an appcast that
#                       cannot be fetched: a tag push is about to publish, and a
#                       missing signal must fail closed rather than let a stale
#                       build number reach users. Tag pushes and the local
#                       pre-tag guard use this.
#   warn              - a stale or unknown published build is reported but does
#                       not fail. release.yml selects this for a non-tag
#                       workflow_dispatch dry run, which publishes nothing and is
#                       expected to run from a branch that has not been bumped.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${CMUX_SPARKLE_PROJECT_FILE:-$ROOT_DIR/cmux.xcodeproj/project.pbxproj}"
APPCAST_URL="${CMUX_SPARKLE_APPCAST_URL:-https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml}"
MODE="${CMUX_SPARKLE_MONOTONIC_MODE:-enforce}"

case "$MODE" in
  enforce|warn) ;;
  *)
    echo "FAIL: CMUX_SPARKLE_MONOTONIC_MODE must be 'enforce' or 'warn' (got '$MODE')" >&2
    exit 1
    ;;
esac

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

# Retry transient fetch failures so enforce mode does not fail a real release
# on a blip; the retry knobs exist so tests can exercise the unreachable path fast.
PUBLISHED_BUILD=$(curl -fsSL --max-time 15 \
  --retry "${CMUX_SPARKLE_APPCAST_RETRIES:-3}" --retry-delay "${CMUX_SPARKLE_APPCAST_RETRY_DELAY:-2}" --retry-all-errors \
  "$APPCAST_URL" 2>/dev/null \
  | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
  | head -n1 || true)

if ! [[ "$PUBLISHED_BUILD" =~ ^[0-9]+$ ]]; then
  if [[ "$MODE" == "warn" ]]; then
    echo "WARN: could not fetch latest published Sparkle build; skipping monotonic check"
    echo "PASS (soft): local CURRENT_PROJECT_VERSION=$LOCAL_BUILD"
    exit 0
  fi
  cat >&2 <<EOF
FAIL: could not fetch the latest published Sparkle build from
      $APPCAST_URL
      so enforce mode cannot prove CURRENT_PROJECT_VERSION ($LOCAL_BUILD) is newer
      than what users already run. A tag push must not publish on a missing
      signal. Check connectivity and that the latest GitHub release carries
      appcast.xml; a non-publishing check can use CMUX_SPARKLE_MONOTONIC_MODE=warn.
EOF
  exit 1
fi

if (( LOCAL_BUILD <= PUBLISHED_BUILD )); then
  if [[ "$MODE" == "warn" ]]; then
    cat <<EOF
WARN: CURRENT_PROJECT_VERSION ($LOCAL_BUILD) is not greater than the latest
      published Sparkle build ($PUBLISHED_BUILD). This is a dry run that publishes
      nothing, so it continues; a tag push with this build number would fail here.
      Run \`./scripts/bump-version.sh\` before tagging.
EOF
    echo "PASS (warn mode): stale build number tolerated for a non-publishing run"
    exit 0
  fi
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
