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
python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" chromium-engine -- \
  bash -c 'set -e
    scripts/cmux-next/ensure-cef.sh --optional
    scripts/cmux-next/ensure-cef.sh --optional --arch x86_64
    if [[ -x scripts/cmux-next/ensure-remote-browser-host.sh ]]; then
      CMUX_RB_HOST_NO_STORE=1 scripts/cmux-next/ensure-remote-browser-host.sh --optional >/dev/null
    fi
    if [[ -f scripts/cmux-next/cmux-remote-dev.pin.json ]]; then
      CMUX_CUA_ASSET_NO_STORE=1 scripts/cmux-next/ensure-cua-pinned-asset.sh scripts/cmux-next/cmux-remote-dev.pin.json --optional >/dev/null
    fi'
