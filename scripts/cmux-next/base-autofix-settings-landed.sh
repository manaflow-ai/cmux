#!/usr/bin/env bash
# After base autofix lands (cmux-next-base-autofix.yml, a run with the settings area on): fails when the
# settings exports at the newest BRANCH tip are not the ones this run's Mac job made, while the tip's
# settings sources are still the ones it made them from. A green run moves the next run's "since"
# (base-autofix-since.sh) past its changes, so a run that left those exports stale would hand them to no
# run (#22740's export, 2026-10-21). When a newer commit changed the sources, the exports are the next
# run's work: a warning only.
#
# The source stamp is derived from each tree (defaults_guard.py source-stamp), never committed, so the
# exports the run made are the evidence: EXPORTS_DIR holds, at their repository paths, the ones that
# differ from RUN_SHA's (base-autofix-settings-exports.sh), and the rest are RUN_SHA's own copies.
#
# Usage: scripts/cmux-next/base-autofix-settings-landed.sh REMOTE BRANCH RUN_SHA MADE_AT EXPORTS_DIR
#   (run in the checkout; MADE_AT is the commit the exports were made at, empty for RUN_SHA)
set -euo pipefail
usage="usage: $0 REMOTE BRANCH RUN_SHA MADE_AT EXPORTS_DIR"
remote="${1:?$usage}"
branch="${2:?$usage}"
run="${3:?$usage}"
made="${4:-}"
dir="${5:?$usage}"
[[ -n "$made" ]] || made="$run"
# Every file of the settings export: scripts/cmux-next/settings-exports.txt is the one list, which
# regenerate-settings-exports.sh exports and check-settings-exports.sh restores.
exports=()
while IFS= read -r cmux_next_export; do exports+=("$cmux_next_export"); done < <(
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$(dirname "${BASH_SOURCE[0]}")/settings-exports.txt")
(( ${#exports[@]} )) || { echo "::error::scripts/cmux-next/settings-exports.txt lists no export" >&2; exit 1; }
guard="$(git rev-parse --show-toplevel)/scripts/ci/defaults_guard.py"
git fetch --quiet --no-tags "$remote" "refs/heads/$branch"
tip="$(git rev-parse FETCH_HEAD)"
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git cat-file -e "$made^{commit}" 2>/dev/null || git fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} "$remote" "$made" || true
if ! made_stamp="$(python3 "$guard" source-stamp --ref "$made")" \
  || ! tip_stamp="$(python3 "$guard" source-stamp --ref "$tip")"; then
  echo "::error::cannot derive the settings source stamps of ${made:0:12} and ${tip:0:12}; the next run makes the exports again"
  exit 1
fi
if [[ "$made_stamp" != "$tip_stamp" ]]; then
  # Back at the run's own sources (the Mac job made them at MADE_AT, whose sources the tip has left):
  # nothing made exports for these sources, and the run's changes are the only thing that names them.
  if [[ "$made" != "$run" ]] && run_stamp="$(python3 "$guard" source-stamp --ref "$run")" \
    && [[ "$run_stamp" == "$tip_stamp" ]]; then
    echo "::error::the settings sources at ${tip:0:12} are the ones this run had at ${run:0:12}, but its exports were made for ${made:0:12}'s; the next run makes them again"
    exit 1
  fi
  echo "::warning::a commit after ${made:0:12} changed the settings sources; the exports at ${tip:0:12} are the next run's work"
  exit 0
fi
stale=()
for file in "${exports[@]}"; do
  if [[ -f "$dir/$file" ]]; then
    git cat-file -e "$tip:$file" 2>/dev/null && cmp -s "$dir/$file" <(git cat-file blob "$tip:$file") && continue
  else
    [[ "$(git rev-parse -q --verify "$run:$file" 2>/dev/null)" == "$(git rev-parse -q --verify "$tip:$file" 2>/dev/null)" ]] \
      && git cat-file -e "$tip:$file" 2>/dev/null && continue
  fi
  stale+=("$file")
done
if ((${#stale[@]})); then
  echo "::error::the settings exports at ${tip:0:12} are not the ones made for its settings sources at ${made:0:12}; the next run makes them again: ${stale[*]}"
  exit 1
fi
echo "The settings exports at ${tip:0:12} are the ones made for its settings sources at ${made:0:12}."
