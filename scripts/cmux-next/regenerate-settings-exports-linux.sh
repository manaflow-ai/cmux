#!/usr/bin/env bash
# regenerate-settings-exports.sh's contract (directory mode), off the Mac: rewrites every export
# settings-exports.txt (or CMUX_SETTINGS_EXPORTS_LIST) lists, from the settings sources, with
# export-settings-linux.sh, and copies the ones that changed (all of them with
# CMUX_SETTINGS_EXPORTS_ALL=1) into OUT at their repository paths, with "regenerated: PATH" lines.
# check-settings-exports.sh runs it as CMUX_SETTINGS_EXPORTS_REGEN and base-autofix-exports-pack.sh as
# CMUX_BASE_EXPORTS_REGENERATE_SETTINGS, in the Linux generated-files job (cmux-next.yml).
# Usage: scripts/cmux-next/regenerate-settings-exports-linux.sh OUT
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:?usage: $0 OUT}" != *.patch ]] || { echo "::error::the bundle mode is regenerate-settings-exports.sh's (a Mac)" >&2; exit 2; }
out="$(mkdir -p "$1" && cd "$1" && pwd)"
root="$(git rev-parse --show-toplevel)"
list="${CMUX_SETTINGS_EXPORTS_LIST:-$here/settings-exports.txt}"
exports=()
while IFS= read -r path; do exports+=("$path"); done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list")
(( ${#exports[@]} )) || { echo "::error::$list lists no export" >&2; exit 1; }
cd "$root"
marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT
# What was already changed before the export: check-settings-exports.sh checks the BASE parent's
# settings sources out in place (schemas/settings/source/*.json among them) before it exports from
# them, so those show in `git status` without the export writing them.
dirty_before="$(git status --porcelain --untracked-files=all -- docs/mdm schemas/settings)"
sleep 1 # sleep-ok: an mtime-granularity tick: the marker must be older than anything the export writes
CMUX_SETTINGS_EXPORTS_LIST="$list" "$here/export-settings-linux.sh"
listed="$(printf '%s\n' "${exports[@]}")"
# A path is the export's write when its status line is new, or the file is newer than the marker.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  path="${line:3}"
  grep -qxF -- "$path" <<<"$listed" && continue
  grep -qxF -- "$line" <<<"$dirty_before" && [[ ! "$path" -nt "$marker" ]] && continue
  echo "::error::the settings export wrote $path, which $list does not list" >&2; exit 1
done < <(git status --porcelain --untracked-files=all -- docs/mdm schemas/settings)
for file in "${exports[@]}"; do
  rm -f -- "$out/$file"
  [[ -f "$file" ]] || { echo "::error::$file was not written by the settings export" >&2; exit 1; }
  [[ "$file" -nt "$marker" ]] || touch "$file"  # an export written byte-identical may keep its mtime
  if [[ "${CMUX_SETTINGS_EXPORTS_ALL:-}" != 1 ]] && git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 \
    && git diff --quiet -- "$file"; then continue; fi
  mkdir -p "$out/$(dirname "$file")"
  cp "$file" "$out/$file"
  echo "regenerated: $file"
done
