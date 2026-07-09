#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="${ASC_APP_ID:-${IOS_APPSTORE_APP_ID:-${IOS_APPSTORE_BUNDLE_ID:-com.cmuxterm.app}}}"
VERSION=""
BUILD_NUMBER=""
BUILD_ID=""
STRICT=0
WAIT_BUILD=0
STAGE_DRY_RUN=0
SUBMIT_DRY_RUN=0
SUBMIT_REQUESTED=0
SUBMIT_CONFIRMED=0
COPY_METADATA_FROM=""
METADATA_DIR="${IOS_APPSTORE_METADATA_DIR:-$IOS_DIR/AppStoreReview/metadata}"
SCREENSHOTS_DIR="${IOS_APPSTORE_SCREENSHOTS_DIR:-$IOS_DIR/AppStoreReview/screenshots}"
REVIEW_NOTES="$IOS_DIR/AppStoreReview/review-notes.md"
CHECKLIST="$IOS_DIR/AppStoreReview/metadata-screenshots-checklist.md"
SCREENSHOT_DEVICE_TYPES=(IPHONE_65 IPAD_PRO_3GEN_129)
SCREENSHOT_DEVICE_TYPES_EXPLICIT=0
VALIDATE_DIGITAL_GOODS="${CMUX_APP_STORE_VALIDATE_DIGITAL_GOODS:-0}"

usage() {
  cat <<'EOF'
Usage:
  ios/scripts/validate-app-store-release.sh [--app <app-id-or-bundle>]
    [--version <X.Y.Z>] [--build-number <CFBundleVersion> | --build-id <id>]
    [--strict] [--wait-build] [--metadata-dir <dir>] [--screenshots-dir <dir>]
    [--screenshot-device-type <ASC_DEVICE_TYPE>] [--copy-metadata-from <version>]
    [--stage-dry-run] [--submit-dry-run | --submit --confirm-submit]

Runs the cmux iOS App Store validation package. The default path is read-only:
it checks the checked-in review package, runs canonical `asc validate`, and
validates local metadata/screenshots when those directories exist.

Mutating submission is deliberately split:
  --stage-dry-run   previews ASC release staging without mutation.
  --submit-dry-run  previews review submission without mutation.
  --submit --confirm-submit submits the prepared version for review.
EOF
}

die() { printf 'validate-app-store-release: %s\n' "$*" >&2; exit 1; }
note() { printf 'validate-app-store-release: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --build-id) BUILD_ID="${2:-}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --wait-build) WAIT_BUILD=1; shift ;;
    --metadata-dir) METADATA_DIR="${2:-}"; shift 2 ;;
    --screenshots-dir) SCREENSHOTS_DIR="${2:-}"; shift 2 ;;
    --screenshot-device-type)
      [[ -n "${2:-}" ]] || die "--screenshot-device-type requires a value"
      if [[ "$SCREENSHOT_DEVICE_TYPES_EXPLICIT" -eq 0 ]]; then
        SCREENSHOT_DEVICE_TYPES=()
        SCREENSHOT_DEVICE_TYPES_EXPLICIT=1
      fi
      SCREENSHOT_DEVICE_TYPES+=("$2")
      shift 2
      ;;
    --copy-metadata-from) COPY_METADATA_FROM="${2:-}"; shift 2 ;;
    --stage-dry-run) STAGE_DRY_RUN=1; shift ;;
    --submit-dry-run) SUBMIT_DRY_RUN=1; shift ;;
    --submit) SUBMIT_REQUESTED=1; shift ;;
    --confirm-submit) SUBMIT_CONFIRMED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$APP" ]] || die "App Store app id is required; pass --app or configure the App Store app id"
if [[ -z "$VERSION" ]]; then
  VERSION="$(
    sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+){1,2}).*/\1/p' \
      "$IOS_DIR/Config/Shared.xcconfig" 2>/dev/null | head -n 1
  )"
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "--version must be X.Y or X.Y.Z (got '${VERSION:-}')"
if [[ -n "$BUILD_NUMBER" && -n "$BUILD_ID" ]]; then
  die "--build-number and --build-id are mutually exclusive"
fi
if [[ "$SUBMIT_REQUESTED" -eq 1 && "$SUBMIT_CONFIRMED" -ne 1 ]]; then
  die "--submit requires --confirm-submit"
fi
if [[ "$SUBMIT_CONFIRMED" -eq 1 && "$SUBMIT_REQUESTED" -ne 1 ]]; then
  die "--confirm-submit requires --submit"
fi
if [[ "$SUBMIT_DRY_RUN" -eq 1 && "$SUBMIT_REQUESTED" -eq 1 ]]; then
  die "--submit-dry-run and --submit --confirm-submit are mutually exclusive"
fi
command -v asc >/dev/null || die "asc CLI is required. Install/authenticate asc, then rerun."
[[ -s "$REVIEW_NOTES" ]] || die "missing review notes: $REVIEW_NOTES"
[[ -s "$CHECKLIST" ]] || die "missing metadata/screenshots checklist: $CHECKLIST"

selector_args=()
if [[ -n "$BUILD_ID" ]]; then
  selector_args=(--build-id "$BUILD_ID")
elif [[ -n "$BUILD_NUMBER" ]]; then
  selector_args=(--app "$APP" --build-number "$BUILD_NUMBER" --version "$VERSION" --platform IOS)
fi

build_json=""
if [[ "${#selector_args[@]}" -gt 0 ]]; then
  if [[ "$WAIT_BUILD" -eq 1 ]]; then
    note "waiting for build processing"
    asc builds wait "${selector_args[@]}" --fail-on-invalid --output table
  fi
  build_json="$(mktemp "${TMPDIR:-/tmp}/cmux-appstore-build.XXXXXX")"
  trap '[[ -n "${build_json:-}" ]] && rm -f "$build_json"' EXIT
  asc builds info "${selector_args[@]}" --output json --pretty > "$build_json"
  if [[ -z "$BUILD_ID" ]]; then
    BUILD_ID="$(
      python3 - "$build_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)

data = body.get("data") if isinstance(body, dict) else None
if isinstance(data, dict):
    print(data.get("id", ""))
elif isinstance(data, list) and data and isinstance(data[0], dict):
    print(data[0].get("id", ""))
elif isinstance(body, dict):
    print(body.get("id", ""))
PY
    )"
  fi
fi

validate_args=(validate --app "$APP" --version "$VERSION" --platform IOS --output table)
[[ "$STRICT" -eq 1 ]] && validate_args+=(--strict)
note "running canonical App Store readiness validation for $APP $VERSION"
asc "${validate_args[@]}"

if [[ -d "$METADATA_DIR" ]]; then
  note "validating local metadata at $METADATA_DIR"
  asc metadata validate --dir "$METADATA_DIR" --output table
else
  note "no local metadata dir at $METADATA_DIR; use $CHECKLIST before staging"
fi

if [[ -d "$SCREENSHOTS_DIR" ]]; then
  for device_type in "${SCREENSHOT_DEVICE_TYPES[@]}"; do
    note "validating screenshots at $SCREENSHOTS_DIR for $device_type"
    asc screenshots validate --path "$SCREENSHOTS_DIR" --device-type "$device_type" --output table
  done
else
  note "no local screenshots dir at $SCREENSHOTS_DIR; use $CHECKLIST before staging"
fi

if [[ "$VALIDATE_DIGITAL_GOODS" == "1" ]]; then
  note "validating IAP and subscription readiness"
  asc validate iap --app "$APP" --output table
  asc validate subscriptions --app "$APP" --output table
else
  note "skipping IAP/subscription validation because the iOS App Store build exposes no purchase flow; payment gating is covered by web tests and $REVIEW_NOTES"
fi

if [[ "$STAGE_DRY_RUN" -eq 1 ]]; then
  [[ -n "$BUILD_ID" ]] || die "--stage-dry-run requires --build-id or --build-number"
  stage_args=(release stage --app "$APP" --version "$VERSION" --build "$BUILD_ID" --dry-run --platform IOS --output table)
  if [[ -d "$METADATA_DIR" ]]; then
    stage_args+=(--metadata-dir "$METADATA_DIR")
  elif [[ -n "$COPY_METADATA_FROM" ]]; then
    stage_args+=(--copy-metadata-from "$COPY_METADATA_FROM")
  else
    die "--stage-dry-run requires --metadata-dir or --copy-metadata-from"
  fi
  [[ "$STRICT" -eq 1 ]] && stage_args+=(--strict-validate)
  note "previewing ASC release staging"
  asc "${stage_args[@]}"
fi

if [[ "$SUBMIT_DRY_RUN" -eq 1 || "$SUBMIT_REQUESTED" -eq 1 ]]; then
  [[ -n "$BUILD_ID" ]] || die "review submission requires --build-id or --build-number"
  submit_args=(review submit --app "$APP" --version "$VERSION" --build "$BUILD_ID" --platform IOS --output table)
  if [[ "$SUBMIT_DRY_RUN" -eq 1 ]]; then
    submit_args+=(--dry-run)
    note "previewing App Store review submission"
  else
    submit_args+=(--confirm)
    note "submitting the prepared App Store version for review"
  fi
  asc "${submit_args[@]}"
fi

note "validation package complete"
