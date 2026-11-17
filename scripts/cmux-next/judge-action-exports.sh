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
# inputs are put back, so the suites that run with `--skip-build` after this step test HEAD's
# products. When the calling job built HEAD's package itself (CMUX_NEXT_JOB_BUILT=plain, the three
# CI jobs that run this), a copy-on-write clone of HEAD's .build is kept before the base build and
# put back after it, so nothing is rebuilt (one CmuxNext rebuild was 14.8 min of daemon-test job
# 132397275531). Without it, or when the clone cannot be made or put back, HEAD's inputs are
# rebuilt. If that rebuild fails, the built products are removed, so those suites fail instead of
# testing the base's binaries. This mirrors check-settings-exports.sh.
#
# A fresh export is a function of the generator inputs alone (the rule above), so it is kept by their
# key (`--inputs-key REV`: the git trees of GENERATOR_INPUTS at REV, less the exports) in a local
# directory, CACHE/KEY/<repository path> plus CACHE/KEY/.complete (CMUX_ACTION_EXPORTS_CACHE, default a
# temporary one), backed by R2: in CI a key the directory lacks is read from the public bucket
# (CMUX_ACTION_EXPORTS_R2_URL; empty turns R2 off). The base autofix's Mac exports job, a feat-cmux-next
# push job in the next-cache-writer environment, uploads each export it makes (`--publish`); a run that
# has the bucket's credentials on a feat-cmux-next ref that is not a pull request also uploads the keys
# it learns (HEAD's fresh export, and the base's when it built it). When the base parent's key is there, the base's
# fresh export is read from it and nothing is built: that build was 16 to 32 min of the daemon-test
# job in 28 of the 68 pull request runs that checked the generated files there (2026-11-16..17), and
# with the job's cold build it ran the job past its 60 min timeout in 12 of them. A pull request never
# writes the bucket. $GITHUB_OUTPUT names the keys (head_key, base_key) and base_built / base_cached.
#
# The commands are overridable for scripts/cmux-next/tests/judge-action-exports.test.sh:
#   CMUX_ACTION_EXPORTS_CHECK   the checks (default: check-action-surfaces.sh PACKAGE)
#   CMUX_ACTION_EXPORTS_REGEN   rewrites the exports (default: regenerate-action-contracts.sh PACKAGE)
#   CMUX_ACTION_EXPORTS_BUILD   rebuilds the package and its tests (default: swift build --build-tests)
# Usage: scripts/cmux-next/judge-action-exports.sh [package-root]
#        scripts/cmux-next/judge-action-exports.sh --inputs-key REV
#        scripts/cmux-next/judge-action-exports.sh --publish REV DIR FALLBACK (the base autofix)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel)"
# The exports the regenerate step writes (ActionSurfaceParityTests), and every input the generator
# reads: the local packages (the catalog and its tests) and plans/cmux-next (the inventory the
# catalog tests read).
EXPORTS=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md)
GENERATOR_INPUTS=(Packages plans/cmux-next scripts/cmux-next/regenerate-action-contracts.sh)

# The key of REV's fresh export: its generator inputs' object ids ("-" for one REV lacks), hashed.
# The exports themselves are left out (plans/cmux-next holds them): the base autofix's commit that
# lands fresh exports keeps the key of the commit they were made at, so a pull request on either
# reads the same entry.
inputs_key() {
  local rev="$1" path ids="" output_path inside
  git -C "$root" cat-file -e "$rev^{commit}" 2>/dev/null || return 1
  for path in "${GENERATOR_INPUTS[@]}"; do
    inside=()
    for output_path in "${EXPORTS[@]}"; do [[ "$output_path" != "$path"/* ]] || inside+=("$output_path"); done
    if ((${#inside[@]})); then
      ids+="$path $(git -C "$root" ls-tree -r --full-tree "$rev" -- "$path" \
        | awk -F '\t' -v skip="${inside[*]}" 'BEGIN { n = split(skip, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 } !($2 in s)' \
        | git hash-object --stdin)"$'\n'
    else
      ids+="$path $(git -C "$root" rev-parse -q --verify "$rev:$path" 2>/dev/null || echo -)"$'\n'
    fi
  done
  printf 'v2\n%s' "$ids" | git hash-object --stdin
}
if [[ "${1:-}" == --inputs-key ]]; then inputs_key "${2:?--inputs-key REV}"; exit; fi

package="${1:-$root/Packages/macOS/CmuxNext}"
temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/action-exports.XXXXXX")"
cache="${CMUX_ACTION_EXPORTS_CACHE:-$temp/cache}"
r2_url="${CMUX_ACTION_EXPORTS_R2_URL-https://ci-cache-next.cmux.com}"
[[ "${GITHUB_ACTIONS:-}" == true ]] || r2_url=""
output() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "$GITHUB_OUTPUT"; }
# r2 restore|save KEY: CACHE/KEY to or from the bucket (its own namespace; a key without "-" publishes
# no prefix pointer). Best effort: any failure is a miss or nothing saved.
r2() {
  [[ -n "$r2_url" && -n "$2" ]] || return 0
  [[ "$1" == restore || ( -n "${AWS_ACCESS_KEY_ID:-}" && "${GITHUB_EVENT_NAME:-}" != pull_request \
    && "${GITHUB_REF:-}" == refs/heads/feat-cmux-next ) ]] || return 0
  CI_CACHE_R2_PUBLIC_URL="$r2_url" CI_CACHE_R2_NAMESPACE=cmux-next-action-exports \
    CI_CACHE_R2_BUCKET="${CI_CACHE_R2_BUCKET:-cmux-ci-cache-next}" GITHUB_OUTPUT="" \
    "$here/../ci/r2-cache.sh" "$1" "$cache/$2" "v1.$2" > "$temp/r2-$1.log" 2>&1 || true
}
# cache_put KEY DIR: DIR's exports (repository paths under it) become CACHE/KEY. Best effort.
cache_put() {
  [[ -n "$1" ]] || return 0
  local dest="$cache/$1" file
  [[ -f "$dest/.complete" ]] && return 0
  rm -rf "$dest" && mkdir -p "$dest" || return 0
  for file in "${EXPORTS[@]}"; do
    [[ -f "$2/$file" ]] || continue
    if ! { mkdir -p "$dest/${file%/*}" && cp "$2/$file" "$dest/$file"; }; then rm -rf "$dest"; return 0; fi
  done
  : > "$dest/.complete"
  r2 save "$1"
}
# cache_has KEY: CACHE/KEY is complete, from the directory or the bucket.
cache_has() {
  [[ -n "$1" ]] || return 1
  [[ -f "$cache/$1/.complete" ]] || r2 restore "$1"
  [[ -f "$cache/$1/.complete" ]]
}
# --publish REV DIR FALLBACK: the base autofix's action-exports job regenerated REV's exports into DIR, which
# holds each one that differs from FALLBACK's committed file (base-autofix-action-exports.sh): keep them under
# REV's key, for the pull requests on REV.
if [[ "${1:-}" == --publish ]]; then
  rev="${2:?--publish REV DIR FALLBACK}" dir="${3:?--publish REV DIR FALLBACK}" fallback="${4:?--publish REV DIR FALLBACK}"
  key="$(inputs_key "$rev")" || { echo "::warning::no commit $rev here: nothing kept"; exit 0; }
  mkdir -p "$temp/made"
  for file in "${EXPORTS[@]}"; do
    mkdir -p "$temp/made/${file%/*}"
    if [[ -f "$dir/$file" ]]; then cp "$dir/$file" "$temp/made/$file"
    elif git -C "$root" cat-file -e "$fallback:$file" 2>/dev/null; then git -C "$root" show "$fallback:$file" > "$temp/made/$file"
    else rm -f "$temp/made/$file"; fi
  done
  cache_put "$key" "$temp/made"
  echo "kept the fresh action exports of ${rev:0:12} (inputs key ${key:0:12})"
  exit 0
fi
head_key="$(inputs_key HEAD || true)"
output "head_key=$head_key"

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

# Fresh as committed: the committed exports are HEAD's fresh export.
if check; then cache_put "$head_key" "$root"; exit 0; fi
regen > "$temp/regen.log" 2>&1 || { cat "$temp/regen.log" >&2; echo "::error::the action exports could not be regenerated" >&2; exit 1; }
if ! check > "$temp/recheck.log" 2>&1; then
  cat "$temp/recheck.log"
  echo "::error::the action catalog checks fail with fresh exports too: a catalog failure, not a stale file"
  # The workflow's verdict reads this (steps.actions.outputs.catalog), so its summary says "catalog failure",
  # never "stale": regenerating changes nothing here (2026-10-29: #27632's "stale" label sent a fix the wrong way).
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "catalog=failure" >> "$GITHUB_OUTPUT"
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
cache_put "$head_key" "$temp/head"
base_key="$(inputs_key HEAD^1 || true)"
output "base_key=$base_key"

changed=()
while IFS= read -r path; do [[ -n "$path" ]] && changed+=("$path"); done < <(
  git diff --no-renames --name-only HEAD^1 HEAD -- "${GENERATOR_INPUTS[@]}")

# A path HEAD does not have: `git checkout HEAD^1 -- path` stages it, so the index goes back too.
restore_absent() { rm -f "$1"; git reset -q HEAD -- "$1" 2>/dev/null || true; }

if ((${#changed[@]})) && cache_has "$base_key"; then
  output "base_cached=true"
  # The base's fresh export, kept by a run that had it: nothing to build. An export it lacks is
  # one the base's regenerate does not write, as below.
  for file in "${stale[@]}"; do
    mkdir -p "$temp/base/${file%/*}"
    if [[ -f "$cache/$base_key/$file" ]]; then cp "$cache/$base_key/$file" "$temp/base/$file"; else : > "$temp/base/$file"; fi
  done
  echo "::notice title=Base action exports from the cache::the base parent's fresh action exports (inputs key ${base_key:0:12}) came from the cache: no base build"
elif ((${#changed[@]})); then
  pkg_build="$package/.build"
  head_build="$package/.build-action-exports-head"
  kept=0
  restored=0
  restore() {
    ((restored)) && return 0
    restored=1
    for path in "${changed[@]}" "${stale[@]}" "${EXPORTS[@]}"; do
      if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q HEAD -- "$path"; else restore_absent "$path"; fi
    done
    for file in ${present[@]+"${present[@]}"}; do cp "$temp/head/$file" "$file"; done
    # HEAD's own build, kept before the base build: nothing to rebuild. The sources' new mtimes only
    # make a later build recompile what they feed, which is correct.
    if ((kept)); then
      if rm -rf "$pkg_build" && mv "$head_build" "$pkg_build"; then return 0; fi
      echo "::warning::HEAD's kept build could not be put back; rebuilding from HEAD's sources instead" >&2
      rm -rf "$head_build"
    fi
    if build > "$temp/head-build.log" 2>&1; then return 0; fi
    cat "$temp/head-build.log" >&2
    echo "::error::the package could not be rebuilt from HEAD's sources; removing its built products so that nothing runs against the base's binaries" >&2
    rm -rf "$package/.build"
    return 1
  }
  trap 'restore || true' EXIT
  rm -rf "$head_build"
  if [[ "${CMUX_NEXT_JOB_BUILT:-}" == plain && -d "$pkg_build" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then clone=(cp -c -R -p); else clone=(cp -a --reflink=auto); fi
    if "${clone[@]}" "$pkg_build" "$head_build" 2>"$temp/head-clone.txt"; then
      kept=1
    else
      echo "::notice::HEAD's package build could not be cloned ($(head -c 300 "$temp/head-clone.txt" 2>/dev/null)); the restore rebuilds from HEAD's sources"
      rm -rf "$head_build"
    fi
  fi
  # Every export starts from the base's committed bytes too, so a file the base's export does not
  # rewrite is never read back as HEAD's fresh one, and what the cache keeps for the base's key is
  # the base's alone.
  for path in "${changed[@]}" "${EXPORTS[@]}"; do
    if git cat-file -e "HEAD^1:$path" 2>/dev/null; then git checkout -q HEAD^1 -- "$path"; else restore_absent "$path"; fi
  done
  build > "$temp/base-build.log" 2>&1 || { cat "$temp/base-build.log" >&2; echo "::error::the base parent's package does not build here; the stale exports count as this change's: ${stale[*]}"; restore || true; exit 1; }
  # Only a regenerate that ran is the base's fresh export to keep.
  if regen > "$temp/base-regen.log" 2>&1; then cache_put "$base_key" "$root"; output "base_built=true"; fi
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
