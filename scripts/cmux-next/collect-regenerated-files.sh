#!/usr/bin/env bash
# cmux-next.yml's "Regenerate stale files" step, in every job that checks the generated files
# (generated-files, and the swift-test, daemon-test or fast-tier job that folds them in): one script
# so the copies cannot drift. Run from the checkout the checks ran in, after the `actions` and
# `settings` steps (judge-action-exports.sh, check-settings-exports.sh).
# Usage: scripts/cmux-next/collect-regenerated-files.sh ACTIONS_OUTCOME
# ACTIONS_OUTCOME is the `actions` step's outcome: `failure` regenerates the action exports. Writes
# `patch=true` to GITHUB_OUTPUT when a file was regenerated.
set -euo pipefail
if [[ "${1:-}" == failure ]]; then
  scripts/cmux-next/regenerate-action-contracts.sh
fi
# A stale settings export was already written into the checkout by the
# check above.
# The defaults snapshot reads the action and settings exports, so it
# follows whichever of them was regenerated.
python3 scripts/ci/defaults_guard.py snapshot
# The regenerated files themselves, at their repository paths, so
# they copy onto the PR head. A diff would be against the merge
# commit, whose context the head may not have.
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
