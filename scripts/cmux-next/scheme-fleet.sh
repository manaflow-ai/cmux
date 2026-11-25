#!/usr/bin/env bash
# The cmux app scheme compile's build-fleet steps (docs/ci/cmux-next-workflow-notes.md#note-scheme-fleet).
#   scheme-fleet.sh read     the fleet job: wait for compile-checks phase scheme-debug; verdict= and job_id= outputs
#   scheme-fleet.sh take     the Mac job: take the fleet app (ok=true) or log the Mac fallback; parity_app= on a sample
#   scheme-fleet.sh compare  the Mac job's parity sample: the fleet app against this Mac's compile
# None of them fails the job: a missing or bad fleet app is the Mac compile, as before.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  read)
    reader=scripts/ci/fleet_compile_result.py
    word=none
    if [[ -f "$reader" ]] && grep -q '"scheme-debug"' "$reader"; then
      word="$(python3 -I "$reader" --sha "$REF" --repo "$GITHUB_REPOSITORY" --pr "${PR:-}" --phase scheme-debug \
        --job-out "$RUNNER_TEMP/job" --wait 2400 --no-record 300 2>"$RUNNER_TEMP/read.err")" || word=none
      cat "$RUNNER_TEMP/read.err" >&2
    fi
    job="$(head -n1 "$RUNNER_TEMP/job" 2>/dev/null || true)"
    [[ "$word" == pass && -z "$job" ]] && word=none
    echo "verdict=$word" >> "$GITHUB_OUTPUT"
    echo "job_id=$job" >> "$GITHUB_OUTPUT"
    case "$word" in
      pass) echo "### Build fleet app build: pass"$'\n\n'"Job \`$job\` built the cmux DEV app at \`$REF\`; the Mac job takes it." >> "$GITHUB_STEP_SUMMARY" ;;
      *) echo "::warning title=fleet fallback::no passing build fleet app build for $REF (reader: $word); the cmux app scheme compile runs on a Mac"
         echo "### Build fleet app build: $word"$'\n\n'"The Mac compiles this head (logged fallback)." >> "$GITHUB_STEP_SUMMARY" ;;
    esac
    ;;
  take)
    derived_data="$RUNNER_TEMP/cmux-scheme-fleet"
    if [[ -z "${CMUX_SCHEME_FLEET_JOB:-}" ]]; then
      # No passing fleet build: say why, so every Mac compile of this scheme is a logged fallback.
      echo "ok=false" >> "$GITHUB_OUTPUT"
      echo "::warning title=fleet fallback::no build fleet app for this head (fleet job: ${FLEET_RESULT:-none}, verdict: ${FLEET_VERDICT:-none}, CI_SCHEME_COMPILE_FLEET: ${FLEET_SWITCH:-unset}); compiling the cmux scheme on this Mac"
      exit 0
    fi
    if [[ "$PARITY" == true ]]; then
      # The parity sample: keep the fleet app aside and compile here too (Compare step below).
      if "$here/fleet-scheme-app.sh" "$CMUX_SCHEME_FLEET_JOB" "$RUNNER_TEMP/cmux-scheme-parity"; then
        echo "parity_app=$(find "$RUNNER_TEMP/cmux-scheme-parity/Build/Products/Debug" -maxdepth 1 -type d -name 'cmux DEV*.app' -print -quit)" >> "$GITHUB_OUTPUT"
      fi
      echo "ok=false" >> "$GITHUB_OUTPUT"
      echo "parity sample: the fleet built this head (job $CMUX_SCHEME_FLEET_JOB); compiling here too to compare"
      exit 0
    fi
    if "$here/fleet-scheme-app.sh" "$CMUX_SCHEME_FLEET_JOB" "$derived_data" \
      && "$here/check-app-personalities.sh" "$(find "$derived_data/Build/Products/Debug" -maxdepth 1 -name 'cmux DEV*.app' -print -quit)"; then
      echo "CMUX_NEXT_DERIVED_DATA=$derived_data" >> "$GITHUB_ENV"
      echo "ok=true" >> "$GITHUB_OUTPUT"
      echo "### cmux app scheme compile: build fleet"$'\n\n'"Built on the build fleet (job \`$CMUX_SCHEME_FLEET_JOB\`); this Mac compiled nothing." >> "$GITHUB_STEP_SUMMARY"
    else
      echo "ok=false" >> "$GITHUB_OUTPUT"
      echo "::warning title=fleet fallback::the build fleet's app (job $CMUX_SCHEME_FLEET_JOB) could not be taken; compiling the cmux scheme on this Mac"
    fi
    ;;
  compare)
    mac_app="$(find "$CMUX_NEXT_DERIVED_DATA/Build/Products/Debug" -maxdepth 1 -type d -name 'cmux DEV*.app' -print -quit)"
    rc=0
    python3 -I scripts/ci/app_bundle_parity.py "$FLEET_APP" "$mac_app" > "$RUNNER_TEMP/parity.md" || rc=$?
    cat "$RUNNER_TEMP/parity.md" | tee -a "$GITHUB_STEP_SUMMARY"
    if (( rc == 1 )); then
      echo "::warning title=fleet parity::the build fleet's app and this Mac's differ (step summary)"
    fi
    ;;
  *) echo "usage: scheme-fleet.sh read|take|compare" >&2; exit 2 ;;
esac
