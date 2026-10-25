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
#
# Whose staleness a stale export is takes a second export from the base parent's settings sources
# (the stamp's inputs, all the export reads), checked out in place so only CmuxNextSettings
# rebuilds. In place means this script MUST put the checkout back on every exit path, because both
# callers keep using it afterwards (all three found by the review of #23915):
#   - the "Regenerate stale files" step collects `git diff` of the export paths, and the base
#     export rewrites EVERY export, not just the ones that were stale to begin with, so a
#     base-version export left on disk is pushed as if it were the repair;
#   - the daemon-test job runs its suites with `swift test --skip-build` AFTER this step, so the
#     base export's own `swift build` would leave them testing base settings binaries;
#   - a base export that fails must not skip the restore either.
# So the restore re-exports from HEAD's sources, which rewrites every export and rebuilds the
# package, it runs from a trap as well as in line, and if it cannot run it falls back to the
# committed exports: collecting nothing is right, collecting the base's bytes is not. When even a
# plain build cannot put HEAD's products back, it removes the built products, so a later
# `--skip-build` suite fails instead of passing against the base export's binaries.
set -euo pipefail
temp="${RUNNER_TEMP:-$(mktemp -d)}"
root="$(git rev-parse --show-toplevel)"
list="$(dirname "${BASH_SOURCE[0]}")/settings-exports.txt"
exports=()
while IFS= read -r path; do exports+=("$path"); done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list")
(( ${#exports[@]} )) || { echo "::error::scripts/cmux-next/settings-exports.txt lists no export" >&2; exit 1; }

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
# Nothing stale: the exports are HEAD's own fresh export and the build is HEAD's. Nothing to put back.
((${#stale[@]})) || exit 0

# The settings sources the export reads, from either stamp (a source added or removed between the
# two appears in only one of them).
inputs=()
while IFS= read -r path; do inputs+=("$path"); done < <(
  printf '%s\n%s\n' "$base_stamp" "$head_stamp" | awk 'NF == 2 { print $2 }' | sort -u)

# An export the base parent still wrote and HEAD does not: HEAD^1's settings sources include the
# export tests, so the base export writes it back even though HEAD dropped it from the list. HEAD's
# re-export never touches it and the committed-exports fallback does not list it, so it would sit in
# the checkout for the "Regenerate stale files" step's `docs/mdm/*` glob to collect and push back --
# the removal undone by the repair (review of #23915). HEAD's copy if it still tracks one (a file
# that stopped being an export but stayed committed), otherwise gone.
base_list="$temp/settings-exports-base.txt"
git show "HEAD^1:$(git ls-files --full-name -- "$list")" > "$base_list" 2>/dev/null || cp "$list" "$base_list"
gone=()
while IFS= read -r path; do
  printf '%s\n' "${exports[@]}" | grep -qxF "$path" || gone+=("$path")
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$base_list")

# A path HEAD does not have. `git checkout HEAD^1 -- path` below STAGES it, so deleting the file
# alone leaves the index holding it (`AD` in git status), which is a staged addition for anything
# that commits with `git add -A` afterwards. The index entry goes back to HEAD's too: absent.
restore_absent() {
  rm -f "$1"
  git reset -q HEAD -- "$1" 2>/dev/null || true
}

restored=0
restore() {
  (( restored )) && return 0
  restored=1
  for path in ${gone[@]+"${gone[@]}"}; do
    if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q HEAD -- "$path"; else restore_absent "$path"; fi
  done
  for path in "${inputs[@]}"; do
    if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q HEAD -- "$path"; else restore_absent "$path"; fi
  done
  # From HEAD's sources again: this rewrites every export and rebuilds the package's test
  # products, so both the checkout and the built binaries are HEAD's.
  if scripts/cmux-next/regenerate-settings-exports.sh "$temp/settings-head-exports" > "$temp/settings-head-exported.txt" 2>&1; then
    return 0
  fi
  cat "$temp/settings-head-exported.txt" >&2
  echo "::error::the settings export could not be redone from HEAD's sources; restoring the committed exports instead" >&2
  git checkout -q HEAD -- "${exports[@]}"
  # The exports are HEAD's committed bytes, so nothing base-derived is collected. The BUILT products
  # are still the base export's, though: the sources above are HEAD's again, so a plain build of the
  # package puts them back. The export failing does not mean the build does (it also fails on an
  # export test, or on the freshness marker).
  if (cd "$root/Packages/macOS/CmuxNext" && swift build --build-tests) >> "$temp/settings-head-exported.txt" 2>&1; then
    echo "::warning::the package was rebuilt from HEAD's sources, so what runs after this is HEAD's" >&2
    return 1
  fi
  # Neither path got HEAD's products back, so the built binaries are the base export's. This step is
  # continue-on-error, and the daemon-test job's suites run `swift test --skip-build` after it, so
  # leaving them there is how base settings binaries pass as this commit's. Taking them away is what
  # stops that: `--skip-build` with nothing built fails, and this says why (review of #23915).
  echo "::error::the package could not be rebuilt from HEAD's sources; removing its built products so that nothing runs against the base export's binaries" >&2
  rm -rf "$root/Packages/macOS/CmuxNext/.build"
  return 1
}
trap 'restore || true' EXIT

for path in "${inputs[@]}"; do
  if git cat-file -e "HEAD^1:$path" 2>/dev/null; then git checkout -q HEAD^1 -- "$path"; else rm -f "$path"; fi
done
# The base parent's own list: these sources write what the base listed, and HEAD's list would refuse
# an export the pull request removed as unlisted, failing the check on the removal (review of #23915).
CMUX_SETTINGS_EXPORTS_LIST="$base_list" \
  scripts/cmux-next/regenerate-settings-exports.sh "$temp/settings-base-exports" > "$temp/settings-base-exported.txt"
based="$temp/settings-based"
for file in "${stale[@]}"; do mkdir -p "$based/${file%/*}" && cp "$file" "$based/$file"; done

restore || exit 1

# A file this event did not edit whose fresh export is the same from either side's sources is the
# base's lag (the base autofix regenerates it): a warning. Anything else is this event's.
own=()
for file in "${stale[@]}"; do
  if ! git diff --quiet HEAD^1 HEAD -- "$file" || ! cmp -s "$file" "$based/$file"; then own+=("$file"); fi
done
if ((${#own[@]})); then
  echo "::error::the committed settings exports differ from a fresh export: ${own[*]}"
  exit 1
fi
echo "::warning title=Settings exports stale on the base::stale on the base $(git rev-parse --short=12 HEAD^1) too, for sources not changed here (the base autofix regenerates them): ${stale[*]}"
