#!/usr/bin/env bash
# The settings exports (schemas/settings/settings-schema.json, docs/mdm) compared with a fresh
# export, never with a committed stamp of their sources (Leo 2026-10-21: "just generate and don't
# commit"). cmux-next.yml's `settings` step runs this, in the generated-files job and in the
# daemon-test job that folds the generated checks into itself (CMUX_NEXT_FOLD_GENERATED); one
# script so the two copies cannot drift. A stale export is left written into the checkout, for
# the "Regenerate stale files" step to collect.
#
# It exports only when this event changed the settings sources (their derived stamp, at HEAD^1 --
# the merge commit's base tip or a push's parent -- and at HEAD, differs) or an export itself. The
# fresh export of a merge commit also holds the base's own unexported changes, so any other event
# would go red for the base's staleness; that is the base autofix's, which regenerates the exports
# after the merge. The defaults snapshot and the CI target graph are bot-only (#21946): they are
# stale on every event between a merge and the base autofix's commit, so no event checks them here.
set -euo pipefail
temp="${RUNNER_TEMP:-$(mktemp -d)}"
base_stamp="$(python3 scripts/ci/defaults_guard.py source-stamp --ref "$(git rev-parse HEAD^1)")"
head_stamp="$(python3 scripts/ci/defaults_guard.py source-stamp --ref HEAD)"
# An event that changes an export itself is checked even with the sources unchanged (a merge
# can keep older exports while taking the base's sources).
if [[ "$base_stamp" == "$head_stamp" ]] && git diff --quiet HEAD^1 HEAD -- docs/mdm schemas/settings; then
  echo "The settings sources and exports did not change; any stale export is the base's (the base autofix regenerates it)."
  exit 0
fi
scripts/cmux-next/regenerate-settings-exports.sh "$temp/settings-exports" | tee "$temp/settings-exported.txt"
stale=()
while IFS= read -r file; do stale+=("$file"); done < <(sed -n 's/^regenerated: //p' "$temp/settings-exported.txt")
((${#stale[@]})) || exit 0
# Whose staleness is it? Export again from the base parent's settings sources (the stamp's
# inputs, all the export reads), checked out in place so only CmuxNextSettings rebuilds. A
# file this event did not edit whose fresh export is the same both ways is the base's lag
# (the base autofix regenerates it): a warning. Anything else is this event's.
merged="$temp/settings-merged"
based="$temp/settings-based"
for file in "${stale[@]}"; do mkdir -p "$merged/${file%/*}" && cp "$file" "$merged/$file"; done
inputs=()
while IFS= read -r path; do inputs+=("$path"); done < <(printf '%s\n%s\n' "$base_stamp" "$head_stamp" | awk 'NF == 2 { print $2 }' | sort -u)
for path in "${inputs[@]}"; do
  if git cat-file -e "HEAD^1:$path" 2>/dev/null; then git checkout -q HEAD^1 -- "$path"; else rm -f "$path"; fi
done
scripts/cmux-next/regenerate-settings-exports.sh "$temp/settings-base-exports" > "$temp/settings-base-exported.txt"
for file in "${stale[@]}"; do mkdir -p "$based/${file%/*}" && { cp "$file" "$based/$file" 2>/dev/null || true; }; done
for path in "${inputs[@]}"; do
  if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q HEAD -- "$path"; else rm -f "$path"; fi
done
git checkout -q HEAD -- "${stale[@]}"
for file in "${stale[@]}"; do cp "$merged/$file" "$file"; done
own=()
for file in "${stale[@]}"; do
  if ! git diff --quiet HEAD^1 HEAD -- "$file" || ! cmp -s "$merged/$file" "$based/$file"; then own+=("$file"); fi
done
if ((${#own[@]})); then
  echo "::error::the committed settings exports differ from a fresh export: ${own[*]}"
  exit 1
fi
echo "::warning title=Settings exports stale on the base::stale on the base $(git rev-parse --short=12 HEAD^1) too, for sources not changed here (the base autofix regenerates them): ${stale[*]}"
