#!/usr/bin/env bash
# The base autofix's Swift exports, made on a package build that already happened: cmux-next.yml's
# generated-files job runs this on a feat-cmux-next push after its checks, and uploads OUT as the
# artifact named after the commit's tree (base_autofix_pushed_exports.py key), so the base autofix
# takes them instead of building the package again on another Mac (cmuxterm-hq#5424).
#
# It regenerates every action export (regenerate-action-exports.sh) and every settings export
# (regenerate-settings-exports.sh) on the checkout's built package, copies all of them into OUT at
# their repository paths and writes OUT/manifest.json (each file's SHA-256, the commit and its tree).
# Every export must be rewritten by its test run: one that a failing test left old makes no pack.
# The checkout's export files are put back as they were before it ran (the job's "Regenerate stale
# files" step reads them after this), on every exit path.
#
# Usage: scripts/cmux-next/base-autofix-exports-pack.sh OUT
# CMUX_BASE_EXPORTS_REGENERATE_ACTIONS / _SETTINGS: the regenerations, run as `CMD DIR` (default the
#   repository's scripts; tests replace them).
set -euo pipefail

out="${1:?usage: $0 OUT}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel)"
cd "$root"
helper="$here/base_autofix_pushed_exports.py"
regen_actions="${CMUX_BASE_EXPORTS_REGENERATE_ACTIONS:-$here/regenerate-action-exports.sh}"
regen_settings="${CMUX_BASE_EXPORTS_REGENERATE_SETTINGS:-$here/regenerate-settings-exports.sh}"

exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json)
while IFS= read -r path; do exports+=("$path"); done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$here/settings-exports.txt")

sha="$(git rev-parse HEAD)"
name="$(python3 -I "$helper" key "$sha")"

work="$(mktemp -d)"
saved="$work/saved"
mkdir -p "$saved"
for rel in "${exports[@]}"; do
  if [[ -f "$rel" ]]; then mkdir -p "$saved/$(dirname "$rel")" && cp -p "$rel" "$saved/$rel"; fi
done
restore() {
  for rel in "${exports[@]}"; do
    if [[ -f "$saved/$rel" ]]; then cp -p "$saved/$rel" "$rel"; else rm -f "$rel"; fi
  done
  rm -rf "$work"
}
trap restore EXIT

marker="$work/marker"
: > "$marker"
sleep 1 # anything the regenerations write is newer than the marker
"$regen_actions" "$work/actions" >&2
CMUX_SETTINGS_EXPORTS_ALL=1 "$regen_settings" "$work/settings" >&2

rm -rf "$out"
mkdir -p "$out"
for rel in "${exports[@]}"; do
  [[ -f "$rel" ]] || { echo "::error::the regeneration left no $rel; no pack" >&2; exit 1; }
  # A test that failed before it wrote leaves the old copy: not a fresh export.
  [[ "$rel" -nt "$marker" ]] || { echo "::error::the regeneration did not rewrite $rel; no pack" >&2; exit 1; }
  mkdir -p "$out/$(dirname "$rel")"
  cp "$rel" "$out/$rel"
done
python3 -I "$helper" manifest --pack "$out" --sha "$sha" >&2
echo "name=$name"
