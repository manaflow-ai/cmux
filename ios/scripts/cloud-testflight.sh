#!/usr/bin/env bash
# Turnkey cloud TestFlight lane for the cmux iOS beta.
#
#   ios/scripts/cloud-testflight.sh --no-upload          # dry run: archive + export + re-sign + verify, NO upload
#   ios/scripts/cloud-testflight.sh                       # full lane: build on the fleet, upload to TestFlight
#   ios/scripts/cloud-testflight.sh --external            # also make the build external-tester eligible
#
# The heavy GhosttyKit + Swift Release compile runs on a leased fleet Mac (the
# same maclease pool/exclusions reload-cloud-ios uses, m1ultra excluded). The
# fleet builds an UNSIGNED Release archive for the beta bundle id
# (dev.cmux.app.beta): no signing material ever lands on the shared Macs (they
# also run GitHub Actions, i.e. arbitrary PR code). The archive is downloaded
# locally and handed to ios/scripts/upload-testflight.sh --archive-path, which
# does the local export, re-sign with the Apple Distribution cert (re-adding
# aps-environment=production), strict codesign verification, and TestFlight
# upload.
#
# The cloud build is provided by the cmuxterm-hq script scripts/reload-cloud-ios.sh
# (located the same way the worktree shim ios/scripts/reload-cloud.sh finds it).
# That script also owns builder resilience: an unreachable leased slot is released
# and the next builder is tried, and beta-archive mode applies a pre-build disk
# floor (RELOAD_CLOUD_IOS_MIN_FREE_GB, default 20G) so a nearly-full fleet host
# (cmux-aws-m4pro routinely sits ~99.7% APFS-full) is skipped instead of dying
# mid-archive; it also prunes its remote work dir after the download. A standalone
# cmux clone with no hq checkout transparently falls back to a LOCAL Release
# archive on this Mac. Either way the archive is then handed to
# upload-testflight.sh, so the export/re-sign/verify/upload path is identical.
#
# Relies on the upload-testflight.sh re-sign + aps-environment=production gate
# (shipped with this lane; a superset of the copy in PR
# https://github.com/manaflow-ai/cmux/pull/5647 with the same re-sign/gates plus
# main's --external support preserved) to make a push-working beta. This lane
# only feeds the archive in; it deliberately does NOT duplicate that signing
# logic. Without the re-sign, the export still runs but the unsigned archive's
# export carries NO aps-environment at all (profile-baseline entitlements
# only), so push would be silently dead; the --no-upload gate below catches
# exactly that.
#
# FIRST EXTERNAL BUILD OF A VERSION: an --external build must pass a one-time
# Apple Beta App Review (~24h) before external testers can install it. Internal
# testers (the "cmux beta" group) get every build instantly with no review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"

LANE="beta"
TAG="beta"
# TestFlight orders by marketing version FIRST: uploading below the testers'
# installed marketing version makes the build invisible as an update (hit
# 2026-06-10: 1.0.0 uploads hidden behind an installed 1.0.1). Override per cut.
MARKETING_VERSION_OVERRIDE="${IOS_BETA_MARKETING_VERSION:-}"
NO_UPLOAD=0
EXTERNAL=0
KEEP_ARTIFACTS=0
# After a successful upload, upload-testflight.sh sets the build's TestFlight
# "What to Test" notes from the top ios/CHANGELOG.md entry. --skip-notes turns
# that off (passed straight through).
SKIP_NOTES=0
HOST_FILTER=""
# When the fleet is busy, wait for a cloud slot rather than degrading to a local
# Release archive on this Mac (which is slow and eats the user's CPU). Mirrors
# reload-cloud-ios.sh's --wait. Set to 0 to fail/fallback fast.
WAIT_SECONDS="${CLOUD_TESTFLIGHT_WAIT:-1200}"
# Force a local Release archive on this Mac instead of the fleet (offline cloud,
# or deliberate). Also the automatic fallback when no hq cloud script is found.
FORCE_LOCAL="${CLOUD_TESTFLIGHT_FORCE_LOCAL:-0}"
BETA_BUNDLE_ID="${IOS_BETA_BUNDLE_ID:-dev.cmux.app.beta}"

err() { printf 'cloud-testflight: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: ios/scripts/cloud-testflight.sh [--lane beta|appstore] [--no-upload] [--external]
                                       [--tag <tag>] [--marketing-version <X.Y.Z>]
                                       [--host <name>] [--wait <seconds>]
                                       [--local] [--keep-artifacts]

Build an UNSIGNED Release archive for cmux iOS on a leased fleet Mac, download
it, then export/re-sign/verify/upload via upload-testflight.sh.

  --lane <beta|appstore>
                     Distribution lane. beta (default) = dev.cmux.app.beta;
                     appstore = com.cmux.app (public App Store record). Both
                     archive an unsigned Release build with display name "cmux"
                     on the fleet; upload-testflight.sh picks the matching
                     provisioning profile and uploads to that record's
                     TestFlight (the appstore build is then attached to the App
                     Store version in App Store Connect; it does not auto-submit).

  --no-upload        Dry run. Stop after the local export + re-sign + strict
                     codesign verification (aps-environment=production); do NOT
                     upload to TestFlight. Maps to upload-testflight.sh
                     --export-only.
  --external         Make the build eligible for EXTERNAL TestFlight testers
                     (requires a one-time Apple Beta App Review per version).
                     Default is internal-only (instant for the "cmux beta" group).
  --tag <tag>        Build tag for the lease description / remote work dir
                     (default: beta). Does not change the bundle id.
  --host <name>      Force a specific fleet builder (skips host preference).
  --wait <seconds>   Block up to this long for a free cloud builder before
                     falling back to a local build (default 1200).
  --local            Build the Release archive locally on this Mac instead of the
                     fleet. Used automatically when no hq cloud script is present.
  --skip-notes       Do not set the build's TestFlight "What to Test" notes after
                     upload. By default a successful upload pushes the top
                     ios/CHANGELOG.md entry (Internal block, or External with
                     --external) so testers see what changed.
  --keep-artifacts   Keep the downloaded archive + export dir.

Signing/upload credentials are resolved by upload-testflight.sh (ASC API key via
ASC_API_KEY_ID/ASC_API_ISSUER_ID/ASC_API_KEY_PATH or
ios/Config/AppStoreConnect.local.plist; the Apple Distribution cert in the local
keychain for the re-sign).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-upload) NO_UPLOAD=1; shift ;;
    --lane) LANE="${2:-}"; shift 2 ;;
    --marketing-version) MARKETING_VERSION_OVERRIDE="${2:-}"; shift 2 ;;
    --external) EXTERNAL=1; shift ;;
    --skip-notes) SKIP_NOTES=1; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --host) HOST_FILTER="${2:-}"; shift 2 ;;
    --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
    --local) FORCE_LOCAL=1; shift ;;
    --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# Resolve the archive bundle id + on-device display name per lane. The fleet
# build (reload-cloud-ios.sh --mode beta-archive) bakes DISPLAY_NAME="cmux" for
# either lane already; LANE_DISPLAY_NAME only feeds the LOCAL fallback archive,
# which otherwise inherits Release.xcconfig's "cmux BETA".
LANE_DISPLAY_NAME=""
case "$LANE" in
  beta)
    : "${BETA_BUNDLE_ID:=dev.cmux.app.beta}"
    ;;
  appstore|prod)
    BETA_BUNDLE_ID="${IOS_PROD_BUNDLE_ID:-com.cmux.app}"
    LANE_DISPLAY_NAME="cmux"
    [[ "$TAG" == "beta" ]] && TAG="appstore"
    ;;
  *)
    die "unsupported lane: $LANE (expected beta or appstore)"
    ;;
esac
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid tag: $TAG"
# Validate the override eagerly: a malformed value (or a flag swallowed by
# `--marketing-version --external`) must fail here, not as a silent no-op or
# a rejected archive 25 minutes into a fleet build.
[[ -z "$MARKETING_VERSION_OVERRIDE" || "$MARKETING_VERSION_OVERRIDE" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
  || die "invalid --marketing-version (want X.Y or X.Y.Z): $MARKETING_VERSION_OVERRIDE"
[[ -d "$IOS_DIR/cmux.xcworkspace" ]] || die "run from a cmux checkout containing ios/cmux.xcworkspace"

# --- locate the hq cloud build script (mirrors ios/scripts/reload-cloud.sh) ---
# scripts/reload-cloud-ios.sh lives in the cmuxterm-hq checkout, two levels up
# from the worktree's git common dir (.../cmuxterm-hq/repo/.git -> cmuxterm-hq).
# A standalone cmux clone has no such file; we fall back to a local build.
find_hq_cloud_ios() {
  local git_common_dir hq_root real
  git_common_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$git_common_dir" ]] || return 1
  case "$git_common_dir" in
    /*) ;;
    *) git_common_dir="$(cd "$REPO_ROOT/$git_common_dir" 2>/dev/null && pwd || true)" ;;
  esac
  [[ -n "$git_common_dir" ]] || return 1
  hq_root="$(cd "$git_common_dir/../.." 2>/dev/null && pwd || true)"
  [[ -n "$hq_root" ]] || return 1
  real="$hq_root/scripts/reload-cloud-ios.sh"
  [[ -x "$real" ]] || return 1
  printf '%s\n' "$real"
}

ARTIFACT_ROOT="${CLOUD_TESTFLIGHT_ARTIFACT_ROOT:-$REPO_ROOT/artifacts/cloud-testflight}"
mkdir -p "$ARTIFACT_ROOT"

ARCHIVE_PATH=""

build_archive_cloud() {
  local hq_cloud="$1" log line
  # BSD mktemp only expands trailing Xs, so the template must END with XXXXXX.
  log="$(mktemp "${TMPDIR:-/tmp}/cloud-testflight-cloud.XXXXXX")"
  err "building UNSIGNED Release beta archive on the fleet via $hq_cloud"
  local args=( --mode beta-archive --tag "$TAG" --keep-artifacts --beta-bundle-id "$BETA_BUNDLE_ID" )
  # Pin BETA_MARKETING_VERSION to exactly the requested override; explicitly
  # unset otherwise so a stray value already in the caller's environment can
  # not leak into the cloud build and desync it from a local cut.
  if [[ -n "$MARKETING_VERSION_OVERRIDE" ]]; then
    export BETA_MARKETING_VERSION="$MARKETING_VERSION_OVERRIDE"
  else
    unset BETA_MARKETING_VERSION
  fi
  [[ -n "$HOST_FILTER" ]] && args+=( --host "$HOST_FILTER" )
  [[ "$WAIT_SECONDS" =~ ^[0-9]+$ && "$WAIT_SECONDS" -gt 0 ]] && args+=( --wait "$WAIT_SECONDS" )
  # Run from the repo root so the hq script's "run from a cmux checkout" check and
  # its dirty-tree rsync pick up THIS worktree.
  #
  # RELOAD_CLOUD_IOS_FALLBACK_LOCAL=0 pins the hq script's no-cloud-slot behavior
  # to FAIL CLOSED. Its beta-archive mode already refuses its own device fallback
  # by design (`ios/scripts/reload.sh --device-only` would do a Debug DEVICE
  # build+install, exit 0, and never print BETA_ARCHIVE_PATH, i.e. silently the
  # wrong thing), but that guard lives in the hq checkout, whose version this
  # wrapper does not control. Exporting the kill switch makes the contract
  # self-enforcing against any hq version: the subprocess either prints
  # BETA_ARCHIVE_PATH or fails, and THIS script owns the only legitimate
  # fallback (build_archive_local).
  if ! ( cd "$REPO_ROOT" && RELOAD_CLOUD_IOS_FALLBACK_LOCAL=0 "$hq_cloud" "${args[@]}" ) 2>&1 | tee "$log"; then
    err "cloud beta-archive build failed (see $log)"
    return 1
  fi
  line="$(grep -E '^BETA_ARCHIVE_PATH=' "$log" | tail -n 1 || true)"
  ARCHIVE_PATH="${line#BETA_ARCHIVE_PATH=}"
  [[ -n "$ARCHIVE_PATH" && -d "$ARCHIVE_PATH" ]] || { err "cloud build did not report a usable BETA_ARCHIVE_PATH"; return 1; }
  return 0
}

build_archive_local() {
  err "building UNSIGNED Release beta archive LOCALLY on this Mac (uses local CPU)"
  local out build_number
  out="$ARTIFACT_ROOT/$TAG-$(date -u +%Y%m%d%H%M%S)"
  mkdir -p "$out"
  build_number="$(date -u +%Y%m%d%H%M%S)"
  ARCHIVE_PATH="$out/cmux-ios-beta.xcarchive"
  [[ -x "$REPO_ROOT/scripts/ensure-ghosttykit.sh" ]] && ( cd "$REPO_ROOT" && ./scripts/ensure-ghosttykit.sh ) || true
  # Same UNSIGNED Release archive the fleet builds, so the downstream export/
  # re-sign/upload path is identical. CODE_SIGNING_ALLOWED=NO keeps signing out of
  # the archive; upload-testflight.sh does all signing.
  ( cd "$REPO_ROOT" && xcodebuild archive \
      -workspace ios/cmux.xcworkspace \
      -scheme cmux-ios \
      -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath "$ARCHIVE_PATH" \
      -derivedDataPath "$out/DerivedData" \
      PRODUCT_BUNDLE_IDENTIFIER="$BETA_BUNDLE_ID" \
      ${LANE_DISPLAY_NAME:+PRODUCT_DISPLAY_NAME="$LANE_DISPLAY_NAME"} \
      CURRENT_PROJECT_VERSION="$build_number" \
      ${MARKETING_VERSION_OVERRIDE:+MARKETING_VERSION="$MARKETING_VERSION_OVERRIDE"} \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      | tee "$out/archive.log" )
  [[ -d "$ARCHIVE_PATH" ]] || die "local archive not produced: $ARCHIVE_PATH"
}

# --- build the archive (cloud preferred, local fallback) --------------------
if [[ "$FORCE_LOCAL" == "1" ]]; then
  build_archive_local
else
  if hq_cloud="$(find_hq_cloud_ios)"; then
    build_archive_cloud "$hq_cloud" || {
      err "falling back to a LOCAL Release archive"
      build_archive_local
    }
  else
    err "no cmuxterm-hq cloud build script found; building locally"
    build_archive_local
  fi
fi

[[ -d "$ARCHIVE_PATH" ]] || die "no archive to hand off"
err "archive ready: $ARCHIVE_PATH"

# Verify an exported/re-signed IPA's single .app is strictly signed AND carries
# aps-environment == production in its ACTUAL signature. The dry run promises this
# check, so the LANE enforces it independently of upload-testflight.sh: even if
# that script's re-sign were ever lost or skipped (an unsigned archive's export
# carries NO aps-environment at all), this gate FAILS the dry run instead of
# silently "passing". On the real upload path upload-testflight.sh runs its own
# pre-altool gate, so this is the dry-run-only backstop.
verify_ipa_aps_environment_production() {
  local ipa="$1" workdir app ent aps rc
  [[ -f "$ipa" ]] || { err "verify: IPA not found: $ipa"; return 1; }
  workdir="$(mktemp -d)"
  if ! ( cd "$workdir" && unzip -q "$ipa" ); then err "verify: could not unzip $ipa"; rm -rf "$workdir"; return 1; fi
  app="$(find "$workdir/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then err "verify: IPA has no Payload/*.app: $ipa"; rm -rf "$workdir"; return 1; fi
  if ! codesign --verify --strict --verbose=2 "$app" >&2; then rm -rf "$workdir"; return 1; fi
  ent="$workdir/signed-entitlements.plist"
  if ! codesign -d --entitlements :- --xml "$app" > "$ent" 2>/dev/null; then
    err "verify: could not read entitlements from signed app: $app"; rm -rf "$workdir"; return 1
  fi
  aps="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$ent" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 || "$aps" != "production" ]]; then
    err "verify: signed app aps-environment is '${aps:-<absent>}', expected 'production' (push would silently fail): $app"
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"; return 1
  fi
  rm -rf "$workdir"
  return 0
}

# --- hand off to upload-testflight.sh (export + re-sign + verify + upload) ----
UPLOAD="$IOS_DIR/scripts/upload-testflight.sh"
[[ -x "$UPLOAD" ]] || die "missing $UPLOAD"

upload_args=( --lane "$LANE" --archive-path "$ARCHIVE_PATH" )
[[ "$EXTERNAL" -eq 1 ]] && upload_args+=( --external )
[[ "$SKIP_NOTES" -eq 1 ]] && upload_args+=( --skip-notes )
# --no-upload maps to --export-only: upload-testflight.sh exports the IPA,
# re-signs it with the full Release entitlements, and gates it on
# aps-environment=production before exiting ahead of altool. The re-sign +
# verify live in upload-testflight.sh, NOT here, so this lane does not
# duplicate them; the dry-run gate below independently confirms the result.
RESIGNED_IPA=""
if [[ "$NO_UPLOAD" -eq 1 ]]; then
  upload_args+=( --export-only )
  err "DRY RUN: export + re-sign then verify, no TestFlight upload"
  # BSD mktemp only expands trailing Xs, so the template must END with XXXXXX.
  upload_log="$(mktemp "${TMPDIR:-/tmp}/cloud-testflight-export.XXXXXX")"
  # `if !` so a failing upload-testflight.sh dies with a pointer to the log
  # instead of set -e/pipefail killing the script before any message.
  if ! ( cd "$REPO_ROOT" && "$UPLOAD" "${upload_args[@]}" ) 2>&1 | tee "$upload_log"; then
    die "upload-testflight.sh --export-only failed (see $upload_log)"
  fi
  # upload-testflight.sh prints IPA_PATH=<final ipa> (the re-signed IPA on the
  # manual signing path).
  RESIGNED_IPA="$(grep -E '^IPA_PATH=' "$upload_log" | tail -n 1 | sed 's/^IPA_PATH=//')"
  rm -f "$upload_log"
  [[ -n "$RESIGNED_IPA" ]] || die "dry run did not produce an IPA to verify"
  err "verifying exported IPA is strictly signed with aps-environment=production"
  verify_ipa_aps_environment_production "$RESIGNED_IPA" \
    || die "DRY RUN FAILED: exported IPA is not a valid production-push build (see above). If the upload-testflight.sh re-sign was skipped or lost, the unsigned archive's export carries no aps-environment at all; that is the gap this gate catches."
else
  ( cd "$REPO_ROOT" && "$UPLOAD" "${upload_args[@]}" )
fi

if [[ "$KEEP_ARTIFACTS" -ne 1 ]]; then
  # Prune the heavy archive + DerivedData unless --keep-artifacts. A local Release
  # archive + DerivedData is tens of GB, so leaking it on every --local dry run
  # would fill the disk. We only remove the .xcarchive's PARENT dir, and only when
  # it is recognisably one of our artifact dirs: this lane's own root
  # ($ARTIFACT_ROOT/<tag>-<ts>/) or the hq cloud download
  # (.../artifacts/reload-cloud-ios/<tag>-<ts>/, which we asked to --keep so we
  # own the cleanup). Belt-and-suspenders so a returned path can never rm an
  # unexpected directory.
  archive_dir="$(dirname "$ARCHIVE_PATH")"
  case "$archive_dir" in
    "$ARTIFACT_ROOT"/*-[0-9]*|*/artifacts/reload-cloud-ios/*-[0-9]*)
      rm -rf "$archive_dir" 2>/dev/null || true ;;
  esac
fi

if [[ "$NO_UPLOAD" -eq 1 ]]; then
  echo
  echo "==> Cloud TestFlight DRY RUN complete (no upload)"
  echo "Archive:      $ARCHIVE_PATH"
  echo "Verified IPA: $RESIGNED_IPA"
  echo "The exported IPA passed the lane's strict codesign verify and carries"
  echo "aps-environment=production in its signed entitlements. No TestFlight upload."
else
  echo
  echo "==> Cloud TestFlight upload complete"
  if [[ "$EXTERNAL" -eq 1 ]]; then
    echo "Lane:     $LANE (external-eligible; first external build of a version needs Apple Beta App Review)"
  else
    echo "Lane:     $LANE (internal-only)"
  fi
fi
