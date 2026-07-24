#!/usr/bin/env bash
set -euo pipefail

# Push a TestFlight build's "What to Test" notes from ios/CHANGELOG.md.
#
# Testers see this text in TestFlight on install and auto-update; without it a
# build is just an opaque MARKETING_VERSION (timestamp). upload-testflight.sh
# calls this automatically after a successful upload, but it is also a standalone
# tool: re-apply or fix notes on any already-uploaded build by build number.
#
# Notes source: the TOP entry of ios/CHANGELOG.md. The audience selects the block:
#   --audience internal  -> the "### Internal" block (terse, dev-facing). Default.
#   --audience external  -> the "### External" block (curated, user-facing).
#
# Auth: ASC_API_KEY_ID / ASC_API_ISSUER_ID / ASC_API_KEY_PATH from the env, else
# ios/Config/AppStoreConnect.local.plist (same resolution as upload-testflight.sh).
#
# Usage:
#   ios/scripts/set-testflight-notes.sh --build-number 20260613120501 \
#       [--audience internal|external] [--bundle-id dev.cmux.app.beta] \
#       [--changelog <path>] [--locale en-US] \
#       [--expect-marketing-version X.Y.Z] \
#       [--notes "literal override text"] [--timeout-seconds 900]
#
# --expect-marketing-version asserts the changelog TOP entry's version equals the
# build's marketing version, so notes for the wrong version are never published
# (upload-testflight.sh passes the archived CFBundleShortVersionString).
#
# --validate-only checks the LOCAL preconditions (changelog present, top version
# matches, audience block has bullets) and exits WITHOUT contacting App Store
# Connect; no --build-number or credentials needed. upload-testflight.sh runs this
# before the archive so bad notes inputs fail fast instead of after the upload.
#
# Exit codes mirror asc_set_testflight_notes.py: 0 set/valid, 3 build not yet
# visible, 1 other error (incl. validation failure).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

BUILD_NUMBER=""
AUDIENCE="internal"
BUNDLE_ID="${IOS_BETA_BUNDLE_ID:-dev.cmux.app.beta}"
CHANGELOG="$IOS_DIR/CHANGELOG.md"
LOCALE="en-US"
NOTES_OVERRIDE=""
TIMEOUT_SECONDS="900"
# When set, the TOP changelog version MUST equal this (the MARKETING_VERSION of
# the build being annotated). Guards against attaching e.g. 1.0.3 notes to a build
# archived as 1.0.0 when a cut forgets to bump the version. upload-testflight.sh
# passes the archived CFBundleShortVersionString here.
EXPECT_MARKETING_VERSION=""
# Validate-only: run the LOCAL preconditions (changelog present, top version
# matches, the audience block has bullets) and exit WITHOUT contacting App Store
# Connect. upload-testflight.sh runs this BEFORE the archive so a deterministic
# local error (missing entry, version mismatch) fails fast instead of being
# discovered only after the build is already uploaded. No --build-number or ASC
# credentials are needed in this mode.
VALIDATE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --audience) AUDIENCE="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --changelog) CHANGELOG="${2:-}"; shift 2 ;;
    --locale) LOCALE="${2:-}"; shift 2 ;;
    --notes) NOTES_OVERRIDE="${2:-}"; shift 2 ;;
    --expect-marketing-version) EXPECT_MARKETING_VERSION="${2:-}"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$AUDIENCE" in
  internal|external) ;;
  *) echo "error: --audience must be internal or external (got '$AUDIENCE')" >&2; exit 2 ;;
esac

if [[ "$VALIDATE_ONLY" -ne 1 ]]; then
  [[ -n "$BUILD_NUMBER" ]] || { echo "error: --build-number is required" >&2; usage >&2; exit 2; }

  # Resolve ASC API auth: env first, then the local plist (same as upload-testflight.sh).
  LOCAL_ASC_CONFIG="$IOS_DIR/Config/AppStoreConnect.local.plist"
  if [[ -f "$LOCAL_ASC_CONFIG" ]]; then
    ASC_API_KEY_ID="${ASC_API_KEY_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
    ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_ISSUER_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
    ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_PATH' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  fi

  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" ]] \
     || [[ -z "${ASC_API_KEY_PATH:-}" && -z "${ASC_API_KEY_P8_BASE64:-}" ]]; then
    echo "error: missing App Store Connect API credentials (ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64), and none found in ${LOCAL_ASC_CONFIG:-ios/Config/AppStoreConnect.local.plist}" >&2
    exit 1
  fi
fi

NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/cmux-testflight-notes.XXXXXX")"
trap 'rm -f "$NOTES_FILE"' EXIT

if [[ -n "$NOTES_OVERRIDE" ]]; then
  printf '%s\n' "$NOTES_OVERRIDE" > "$NOTES_FILE"
else
  [[ -f "$CHANGELOG" ]] || { echo "error: changelog not found: $CHANGELOG" >&2; exit 1; }

  # The TOP entry must describe the build we are annotating. Read the top version
  # heading (## [X.Y.Z] - date) and, when the caller told us the build's marketing
  # version, refuse to attach notes for a different version. This is the guard for
  # the "archived 1.0.0 but changelog top is 1.0.3" mismatch: better to skip notes
  # (the binary is already uploaded; the caller treats this as non-fatal) than to
  # publish release notes for the wrong version.
  TOP_VERSION="$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$CHANGELOG" | head -n1)"
  [[ -n "$TOP_VERSION" ]] || { echo "error: no '## [version]' entry found in $CHANGELOG" >&2; exit 1; }
  if [[ -n "$EXPECT_MARKETING_VERSION" && "$TOP_VERSION" != "$EXPECT_MARKETING_VERSION" ]]; then
    echo "error: changelog top entry is [$TOP_VERSION] but the build's marketing version is $EXPECT_MARKETING_VERSION; refusing to attach mismatched What to Test notes. Add a [$EXPECT_MARKETING_VERSION] entry to the top of $CHANGELOG (or bump the beta marketing version with ios/scripts/bump-ios-version.sh before cutting)." >&2
    exit 1
  fi

  # Extract the bullet items of the requested block from the TOP version entry.
  # The top entry is everything from the first "## [" version heading up to the
  # next "## [" heading. Within it, the "### Internal" / "### External" block runs
  # until the next "### " or "## " heading. We emit each "- " bullet as a clean
  # line (one leading "- ") so TestFlight shows a readable list.
  AUDIENCE="$AUDIENCE" awk '
    BEGIN { want = toupper(substr(ENVIRON["AUDIENCE"],1,1)) tolower(substr(ENVIRON["AUDIENCE"],2)); }
    /^## \[/ { vers++; if (vers > 1) exit; next }   # stop at the 2nd version
    vers != 1 { next }
    /^### / {
      sect = $0; sub(/^### +/, "", sect);
      insect = (sect == want) ? 1 : 0;
      next
    }
    insect && /^- / {
      line = $0; sub(/^- +/, "", line);
      print "- " line;
    }
  ' "$CHANGELOG" > "$NOTES_FILE"

  if [[ ! -s "$NOTES_FILE" ]]; then
    TOP_VER="$(grep -m1 '^## \[' "$CHANGELOG" || true)"
    echo "error: no '### ${AUDIENCE^}' bullet items found in the top entry ($TOP_VER) of $CHANGELOG" >&2
    exit 1
  fi
fi

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  # All deterministic local preconditions passed (changelog present, top version
  # matches if --expect-marketing-version was given, audience block has bullets).
  # Show what WILL be published and exit without touching App Store Connect.
  echo "set-testflight-notes: validate-only OK; $AUDIENCE notes that will be published:" >&2
  sed 's/^/  /' "$NOTES_FILE" >&2
  exit 0
fi

echo "set-testflight-notes: $AUDIENCE notes for build $BUILD_NUMBER ($BUNDLE_ID, $LOCALE):" >&2
sed 's/^/  /' "$NOTES_FILE" >&2

ASC_API_KEY_ID="$ASC_API_KEY_ID" \
ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}" \
ASC_API_KEY_P8_BASE64="${ASC_API_KEY_P8_BASE64:-}" \
python3 "$SCRIPT_DIR/asc_set_testflight_notes.py" \
  --bundle-id "$BUNDLE_ID" \
  --build-number "$BUILD_NUMBER" \
  --notes-file "$NOTES_FILE" \
  --locale "$LOCALE" \
  --timeout-seconds "$TIMEOUT_SECONDS"
