#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Fetch the Chromium engine". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Fills the ensure-cef cache with the pinned Chromium engine (cef-manifest.json) from private R2 with the
# read-only key (CMUX_CEF_READ_TOKEN's release as fallback); only this background fetch gets the key. No
# source: the app builds without the engine ("Report the embedded Chromium engine" flags it). "Finish
# fetching the Chromium engine" joins it before the Release build and fails where it failed.
# x86_64: a universal build embeds both engine slices (none: arm64 only). The remote browser host
# (Contents/Helpers, phone tabs) comes from R2 too; missing, the phase warns; a digest mismatch fails.
# The pinned cmux Remote (cmux-remote-dev.pin.json) is required in Release (embed-cmux-remote-dev.sh, #43516),
# but the Release build step has no R2 key and its copy in the controller store is readable only by the lane
# that staged it, so every nightly failed with "cmux-remote-dev.pin.json unavailable: no CMUX_CEF_R2_* read
# credentials" (2026-11-16, runs 43836933442 and 43846986617). This fetch puts it in the same cache
# (cef-cache-root.sh/cua-helper-v2) the build reads first; a failure here still fails the build there.
#
# The cache root is this job's own folder (RUNNER_TEMP/cef-cache), not the host's: glaeda-disk --pressure
# reclaims ~/Library/Caches/cmux/cef/<version> on a full mini, and on 2026-11-28 it did so between this
# fetch (12:04) and the Release build's embed phase (12:09) of run 46142021653. That phase has no R2 key
# or token, so it built without the engine and "Verify third-party notices" failed the nightly (WebRTC
# needs CEF's CREDITS.html.gz). The host cache seeds the job's folder as APFS clones (no extra disk), so
# nothing is fetched twice; GITHUB_ENV hands the root to every later step (app-build-release.sh keeps a
# set CMUX_CEF_CACHE_DIR) and the folder goes with the job.
host_root="$(env -u CMUX_CEF_CACHE_DIR scripts/cmux-next/cef-cache-root.sh)"
job_root="${RUNNER_TEMP:?}/cef-cache"
mkdir -p "$job_root"
if [[ -d "$host_root" ]]; then
  for entry in "$host_root"/*; do
    [[ -e "$entry" && ! -e "$job_root/${entry##*/}" ]] || continue
    cp -cRp "$entry" "$job_root/" 2>/dev/null || cp -Rp "$entry" "$job_root/" ||
      { rm -rf "${job_root:?}/${entry##*/}"; echo "warning: could not seed $entry; fetching it again" >&2; }
  done
fi
export CMUX_CEF_CACHE_DIR="$job_root"
echo "CMUX_CEF_CACHE_DIR=$job_root" >> "${GITHUB_ENV:?}"
echo "CEF cache for this job: $job_root (seeded from $host_root)"
python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" chromium-engine -- \
  bash -c 'set -e
    scripts/cmux-next/ensure-cef.sh --optional
    scripts/cmux-next/ensure-cef.sh --optional --arch x86_64
    if [[ -x scripts/cmux-next/ensure-remote-browser-host.sh ]]; then
      CMUX_RB_HOST_NO_STORE=1 scripts/cmux-next/ensure-remote-browser-host.sh --optional >/dev/null
    fi
    if [[ -f scripts/cmux-next/cmux-remote-dev.pin.json ]]; then
      CMUX_CUA_ASSET_NO_STORE=1 scripts/cmux-next/ensure-signed-pinned-asset.sh scripts/cmux-next/cmux-remote-dev.pin.json --optional >/dev/null
    fi'
