#!/usr/bin/env bash
# The action catalog checks (check-action-surfaces.sh) with the settings export check's rule for
# whose staleness a stale export is (check-settings-exports.sh): a pull request fails only for an
# action export its own change left stale, never for the base's lag, which the base autofix
# regenerates after the next push. cmux-next.yml's `actions` step runs this in every job that checks
# the generated files.
#
#   1. The checks pass: done.
#   2. Otherwise the exports are regenerated (regenerate-action-contracts.sh) and the checks run
#      again. Still red: a real catalog failure (a missing surface, a duplicate CLI name), not a
#      stale file. That fails, as before.
#   3. Red only for stale files: each stale export is judged against the base parent (HEAD^1, the
#      merge commit's base tip or a push's parent). The base's own drift is what a fresh export of
#      the base adds to the base's committed file. That drift is applied to this commit's committed
#      file (git merge-file). If the result is this commit's fresh export, the base's drift is all
#      that is stale: a warning, and the committed file is put back so nothing collects it. Any
#      other difference is this change's own: an error naming the file, with the fresh export left
#      in the checkout for the "Regenerate stale files" step.
#
# The base's fresh export needs the base's generator inputs. When this event changed none of them
# (GENERATOR_INPUTS), they are HEAD's, so HEAD's fresh export is the base's. Otherwise the changed
# inputs are checked out from HEAD^1 in place, the package is rebuilt and exported, and then HEAD's
# inputs are put back and rebuilt, so the suites that run with `--skip-build` after this step test
# HEAD's products. If that rebuild fails, the built products are removed, so those suites fail
# instead of testing the base's binaries. This mirrors check-settings-exports.sh.
#
# The commands are overridable for scripts/cmux-next/tests/judge-action-exports.test.sh:
#   CMUX_ACTION_EXPORTS_CHECK   the checks (default: check-action-surfaces.sh PACKAGE)
#   CMUX_ACTION_EXPORTS_REGEN   rewrites the exports (default: regenerate-action-contracts.sh PACKAGE)
#   CMUX_ACTION_EXPORTS_BUILD   rebuilds the package and its tests (default: swift build --build-tests)
# Usage: scripts/cmux-next/judge-action-exports.sh [package-root]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel)"
package="${1:-$root/Packages/macOS/CmuxNext}"
temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/action-exports.XXXXXX")"
# The exports the regenerate step writes (ActionSurfaceParityTests), and every input the generator
# reads: the local packages (the catalog and its tests) and plans/cmux-next (the inventory the
# catalog tests read).
EXPORTS=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md)
GENERATOR_INPUTS=(Packages plans/cmux-next scripts/cmux-next/regenerate-action-contracts.sh)

check() {
  if [[ -n "${CMUX_ACTION_EXPORTS_CHECK:-}" ]]; then bash -c "$CMUX_ACTION_EXPORTS_CHECK"
  else "$here/check-action-surfaces.sh" "$package"; fi
}
regen() {
  if [[ -n "${CMUX_ACTION_EXPORTS_REGEN:-}" ]]; then bash -c "$CMUX_ACTION_EXPORTS_REGEN"
  else "$here/regenerate-action-contracts.sh" "$package"; fi
}
build() {
  if [[ -n "${CMUX_ACTION_EXPORTS_BUILD:-}" ]]; then bash -c "$CMUX_ACTION_EXPORTS_BUILD"
  else (cd "$package" && swift build --build-tests); fi
}
# Changed (or new) export files in the checkout, repository-relative.
stale_exports() {
  git -C "$root" add -N -- "${EXPORTS[@]}" 2>/dev/null || true
  git -C "$root" diff --name-only -- "${EXPORTS[@]}"
}

if check; then exit 0; fi
regen > "$temp/regen.log" 2>&1 || { cat "$temp/regen.log" >&2; echo "::error::the action exports could not be regenerated" >&2; exit 1; }
if ! check > "$temp/recheck.log" 2>&1; then
  cat "$temp/recheck.log"
  echo "::error::the action catalog checks fail with fresh exports too: a catalog failure, not a stale file"
  exit 1
fi
stale=()
while IFS= read -r file; do [[ -n "$file" ]] && stale+=("$file"); done < <(stale_exports)
((${#stale[@]})) || { echo "::error::the action catalog checks failed, then passed with nothing regenerated"; exit 1; }
git -C "$root" cat-file -e 'HEAD^1^{commit}' 2>/dev/null || {
  echo "::error::stale action exports and no base parent to judge them against: ${stale[*]}"; exit 1; }

cd "$root"
mkdir -p "$temp/head" "$temp/base"
# HEAD's fresh exports, every one of them: a base regenerate may rewrite an export that is fresh
# here too, and the restore puts them all back.
present=()
for file in "${EXPORTS[@]}"; do
  [[ -f "$file" ]] || continue
  present+=("$file"); mkdir -p "$temp/head/${file%/*}" && cp "$file" "$temp/head/$file"
done

changed=()
while IFS= read -r path; do [[ -n "$path" ]] && changed+=("$path"); done < <(
  git diff --no-renames --name-only HEAD^1 HEAD -- "${GENERATOR_INPUTS[@]}")

# A path HEAD does not have: `git checkout HEAD^1 -- path` stages it, so the index goes back too.
restore_absent() { rm -f "$1"; git reset -q HEAD -- "$1" 2>/dev/null || true; }

if ((${#changed[@]})); then
  restored=0
  restore() {
    ((restored)) && return 0
    restored=1
    for path in "${changed[@]}" "${stale[@]}" "${EXPORTS[@]}"; do
      if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q HEAD -- "$path"; else restore_absent "$path"; fi
    done
    for file in ${present[@]+"${present[@]}"}; do cp "$temp/head/$file" "$file"; done
    if build > "$temp/head-build.log" 2>&1; then return 0; fi
    cat "$temp/head-build.log" >&2
    echo "::error::the package could not be rebuilt from HEAD's sources; removing its built products so that nothing runs against the base's binaries" >&2
    rm -rf "$package/.build"
    return 1
  }
  trap 'restore || true' EXIT
  # The stale files start from the base's committed bytes too, so a file the base's export does not
  # rewrite is never read back as HEAD's fresh one.
  for path in "${changed[@]}" "${stale[@]}"; do
    if git cat-file -e "HEAD^1:$path" 2>/dev/null; then git checkout -q HEAD^1 -- "$path"; else restore_absent "$path"; fi
  done
  build > "$temp/base-build.log" 2>&1 || { cat "$temp/base-build.log" >&2; echo "::error::the base parent's package does not build here; the stale exports count as this change's: ${stale[*]}"; restore || true; exit 1; }
  regen > "$temp/base-regen.log" 2>&1 || true
  for file in "${stale[@]}"; do
    mkdir -p "$temp/base/${file%/*}"
    if [[ -f "$file" ]]; then cp "$file" "$temp/base/$file"; else : > "$temp/base/$file"; fi
  done
  restore || exit 1
else
  # The generator's inputs are the base's: HEAD's fresh export is the base's fresh export.
  for file in "${stale[@]}"; do mkdir -p "$temp/base/${file%/*}" && cp "$temp/head/$file" "$temp/base/$file"; done
fi

own=()
for file in "${stale[@]}"; do
  committed="$temp/committed"; based="$temp/based"
  git show "HEAD:$file" > "$committed" 2>/dev/null || : > "$committed"
  git show "HEAD^1:$file" > "$based" 2>/dev/null || : > "$based"
  # This commit's committed file plus the base's drift (base committed -> base fresh). When the base
  # and this change make the same catalog edit, this commit's inputs equal the base's for it, so its
  # staleness is the base's too and the base autofix repairs it.
  if git merge-file -p "$committed" "$based" "$temp/base/$file" > "$temp/merged" 2>/dev/null \
      && cmp -s "$temp/merged" "$temp/head/$file"; then
    continue
  fi
  own+=("$file")
done

if ((${#own[@]})); then
  echo "::error::this change leaves action exports stale (regenerate with scripts/cmux-next/regenerate-action-contracts.sh): ${own[*]}"
  exit 1
fi
# Only the base's drift: put the committed files back, so nothing collects the base's repair here.
for file in "${stale[@]}"; do
  if git cat-file -e "HEAD:$file" 2>/dev/null; then git checkout -q HEAD -- "$file"; else restore_absent "$file"; fi
done
echo "::warning title=Action exports stale on the base::base drift: stale on the base $(git rev-parse --short=12 HEAD^1) too, for inputs not changed here (the base autofix regenerates them): ${stale[*]}"
