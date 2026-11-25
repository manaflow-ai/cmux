#!/usr/bin/env bash
# cmux-next.yml generated-files-linux ("cmux-next generated files" on the fleet's Linux pool) and its Mac fallback
# generated-files: the bodies of their longer steps, one subcommand per step. Moved out of the workflow to keep
# cmux-next.yml under GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py).
# Why: docs/ci/cmux-next-workflow-notes/2026-11-25-generated-files-linux.md
set -uo pipefail
step="${1:?usage: generated-files-linux.sh fallback|preflight|parity|actions|base-pack|pr-pack|regenerate|verdict}"
# The Linux exporters the judges and packs run off a Mac (each input still wins when a step sets it).
linux="$PWD/scripts/cmux-next"
export CMUX_BASE_EXPORTS_REGENERATE_ACTIONS="${CMUX_BASE_EXPORTS_REGENERATE_ACTIONS:-$linux/regenerate-action-exports-linux.sh}"
export CMUX_BASE_EXPORTS_REGENERATE_SETTINGS="${CMUX_BASE_EXPORTS_REGENERATE_SETTINGS:-$linux/regenerate-settings-exports-linux.sh}"

case "$step" in
  # The Mac job's first step: why the fleet job gave no verdict, as a warning.
  fallback)
    why="the fleet job ended $LINUX_RESULT with no verdict"
    [[ "$LINUX_RESULT" != skipped ]] || why="the fleet job is off (vars.CI_GENERATED_FILES_LINUX) or skipped"
    [[ "$PARITY" != mismatch ]] || why="the fleet export differs from the Swift export (parity)"
    echo "::warning title=cmux-next generated files: Mac fallback::$why"
    echo "Mac fallback: $why." >> "$GITHUB_STEP_SUMMARY"
    ;;

  # Exit 0 fresh, 1 stale, anything else: this pool cannot export, so the Mac job decides.
  preflight)
    ok=true
    scripts/cmux-next/check-generated-linux.sh; rc=$?
    (( rc <= 1 )) || { echo "::warning::the Linux action exporter failed (exit $rc)"; ok=false; }
    # The settings export runs when check-settings-exports.sh needs it (the settings sources or exports
    # changed), and hands over to the Mac there if it cannot decide.
    git checkout -q HEAD -- plans/cmux-next
    echo "ok=$ok" >> "$GITHUB_OUTPUT"
    ;;

  # parity=match|mismatch|unknown, and go=true unless the Linux export differs from the Swift one kept for
  # these inputs (then the Mac job decides).
  parity)
    out="$(scripts/cmux-next/generated-parity-linux.sh)" || exit
    echo "$out" | tee -a "$GITHUB_OUTPUT"
    [[ "$out" == *parity=mismatch* ]] || echo "go=true" >> "$GITHUB_OUTPUT"
    ;;

  actions)
    export CMUX_ACTION_EXPORTS_CHECK=scripts/cmux-next/check-generated-linux.sh
    export CMUX_ACTION_EXPORTS_REGEN="scripts/cmux-next/regenerate-action-exports-linux.sh $RUNNER_TEMP/action-exports-regen"
    export CMUX_ACTION_EXPORTS_BUILD=true
    exec scripts/cmux-next/judge-action-exports.sh "$PWD/Packages/macOS/CmuxNext"
    ;;


  base-pack)
    set -e
    if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] && [[ "$(python3 -I -c 'import json, os; print(str((json.load(open(os.environ["GITHUB_EVENT_PATH"])).get("inputs") or {}).get("base_tier", "")).lower())')" != true ]]; then
      echo "not a base tier dispatch: no pack"
      exit 0
    fi
    scripts/cmux-next/base-autofix-exports-pack.sh "$RUNNER_TEMP/base-exports" | tee -a "$GITHUB_OUTPUT"
    ;;

  # Why: docs/ci/cmux-next-workflow-notes.md#note-544
  pr-pack)
    set -e
    base="$RUNNER_TEMP/pr-autofix-base"
    rm -rf "$base" && mkdir -p "$base"
    git archive HEAD^1 scripts/cmux-next | tar -x -C "$base"
    pack="$base/scripts/cmux-next/base-autofix-exports-pack.sh"
    if ! grep -q -- '--pr' "$pack"; then echo "the base's pack script makes no PR pack yet"; exit 0; fi
    if git log -1 --format=%B HEAD^2 | grep -q '^Autofix-Run: '; then echo "an autofix head: the PR autofix wants no exports"; exit 0; fi
    areas="$(git diff --no-renames --name-only HEAD^1 HEAD | "$base/scripts/cmux-next/autofix-areas.sh")"
    if ! grep -qE '^(actions|settings)=true$' <<<"$areas"; then
      echo "no action or settings inputs changed: the PR autofix wants no exports"
      exit 0
    fi
    "$pack" "$RUNNER_TEMP/pr-exports" --pr | tee -a "$GITHUB_OUTPUT"
    ;;

  # Why: docs/ci/cmux-next-workflow-notes.md#note-277
  regenerate)
    set -e
    if [[ "${ACTIONS:-}" == failure && "$(uname)" == Darwin ]]; then
      scripts/cmux-next/regenerate-action-contracts.sh
    elif [[ "${ACTIONS:-}" == failure ]]; then
      scripts/cmux-next/regenerate-action-exports-linux.sh "$RUNNER_TEMP/action-exports-stale"
    fi
    # Why: docs/ci/cmux-next-workflow-notes.md#note-454
    python3 scripts/ci/defaults_guard.py snapshot
    out="$RUNNER_TEMP/generated/files"
    mkdir -p "$out"
    generated=('plans/cmux-next/*.json' 'plans/cmux-next/*.md'
      schemas/settings/settings-schema.json 'docs/mdm/*' schemas/defaults/cmux-next.json)
    git add -N -- "${generated[@]}"
    git diff --name-only -- "${generated[@]}" > "$RUNNER_TEMP/generated/paths.txt"
    git diff --stat
    while IFS= read -r path; do
      mkdir -p "$out/$(dirname "$path")"
      cp "$path" "$out/$path"
    done < "$RUNNER_TEMP/generated/paths.txt"
    cp "$RUNNER_TEMP/generated/paths.txt" "$out/.paths"
    if [[ -s "$RUNNER_TEMP/generated/paths.txt" ]]; then
      echo "patch=true" >> "$GITHUB_OUTPUT"
    fi
    ;;

  # verdict=fresh|catalog|autofixed|stale, which the Mac job reads (empty: this pool decided nothing, the Mac job
  # runs instead). The Mac job's "Fail on stale generated files" runs it too, and reads autofixed=true.
  # Why: docs/ci/cmux-next-workflow-notes.md#note-481
  verdict)
    ACTIONS="${ACTIONS:-}" CATALOG="${CATALOG:-}" SETTINGS="${SETTINGS:-}" AUTOFIXED_OK="${AUTOFIXED_OK:-}"
    if [[ "$ACTIONS" != failure && "$SETTINGS" != failure ]]; then
      echo "verdict=fresh" >> "$GITHUB_OUTPUT"
      echo "Generated cmux-next files are fresh (checked on the fleet's Linux pool)." | tee -a "$GITHUB_STEP_SUMMARY"
      exit 0
    fi
    if [[ "$ACTIONS" == failure && "$CATALOG" == failure ]]; then
      echo "verdict=catalog" >> "$GITHUB_OUTPUT"
      {
        echo "### The action catalog checks fail: a catalog failure, not stale files"
        echo
        echo "Fresh exports fail the same checks, so regenerating changes nothing. The step \"Check generated action catalog, surfaces and inventory\" names the failing check."
        [[ "$SETTINGS" != failure ]] || echo "- settings exports are also stale: scripts/cmux-next/regenerate-settings-exports.sh"
      } | tee -a "$GITHUB_STEP_SUMMARY"
      echo "::error::The action catalog checks fail with fresh exports too: a catalog failure, not stale files."
      exit 1
    fi
    if [[ "$AUTOFIXED_OK" == true ]] && why="$(scripts/cmux-next/generated-autofixable.sh)"; then
      printf 'verdict=autofixed\nautofixed=true\n' >> "$GITHUB_OUTPUT"
      echo "### Generated cmux-next files are stale: autofixed ($why)" | tee -a "$GITHUB_STEP_SUMMARY"
      echo "::notice title=cmux-next generated files (autofixed)::Generated cmux-next files are stale only from this pull request's own changes: $why"
      exit 0
    fi
    echo "verdict=stale" >> "$GITHUB_OUTPUT"
    {
      echo "### Generated cmux-next files are stale"
      echo
      [[ "$ACTIONS" != failure ]] || echo "- action catalog, surfaces or inventory: scripts/cmux-next/regenerate-action-contracts.sh (or scripts/cmux-next/regenerate-action-exports-linux.sh OUT, off a Mac)"
      [[ "$SETTINGS" != failure ]] || echo "- settings exports: scripts/cmux-next/regenerate-settings-exports.sh (or scripts/cmux-next/regenerate-settings-exports-linux.sh OUT, off a Mac)"
      echo
      echo "The cmux-next-generated-patch artifact holds the regenerated files at their repository paths."
    } | tee -a "$GITHUB_STEP_SUMMARY"
    echo "::error::Generated cmux-next files are stale. Regenerate them as the step summary says."
    exit 1
    ;;

  *)
    echo "generated-files-linux.sh: unknown step '$step'" >&2
    exit 2
    ;;
esac
