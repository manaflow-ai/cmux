#!/usr/bin/env bash
# judge-action-exports.sh: a stale action export fails a change only when the change itself left it
# stale. The base's own drift (the base autofix's to regenerate) is a warning.
#
# A fake package: the "build" copies Sources/actions.txt into .build, and the generator writes
# plans/cmux-next/action-surfaces.json from the BUILT copy, so the base's export comes from a real
# rebuild at the base and the products are HEAD's again afterwards. Each case is a merge commit
# (HEAD^1 = the base tip), as a pull request's checkout is.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../judge-action-exports.sh"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
src=Packages/macOS/CmuxNext/Sources/actions.txt
out=plans/cmux-next/action-surfaces.json
pkg=Packages/macOS/CmuxNext

# Hermetic: no bucket.
export CMUX_ACTION_EXPORTS_R2_URL="" CMUX_LAN_CACHE_SOCKET=/nonexistent
export CMUX_ACTION_EXPORTS_BUILD="mkdir -p $pkg/.build && cp $src $pkg/.build/actions.txt"
gen='sed "s/^/action: /" '"$pkg"'/.build/actions.txt'
export CMUX_ACTION_EXPORTS_REGEN="$gen > $out"
# The checks: the export is fresh, and no action is BAD (a catalog failure no export fixes).
export CMUX_ACTION_EXPORTS_CHECK="! grep -q BAD $src && diff -q <($gen) $out >/dev/null"

# repo BASE_SOURCE BASE_REGENERATES PR_SOURCE PR_REGENERATES: an old fresh commit, the base tip on top
# of it, a pull request branched from the old commit, and their merge checked out and built.
repo() {
  rm -rf "$tmp/r" && mkdir -p "$tmp/r" && cd "$tmp/r"
  git init -q -b feat && mkdir -p "${src%/*}" "${out%/*}"
  printf 'a\nb\nc\nd\ne\n' > "$src" && sed 's/^/action: /' "$src" > "$out" && echo readme > README.md
  echo md > plans/cmux-next/actions.md
  mkdir -p Packages/macOS/Other && echo other > Packages/macOS/Other/x.txt
  if [[ -n "${REPO_GRAPH:-}" ]]; then printf '%s\n' "$REPO_GRAPH" > "$pkg/ci-target-graph.json"; fi
  git add -A && git commit -q -m old
  edit "$1" "$2" && git commit -qam base
  git checkout -q -b pr HEAD~1
  edit "$3" "$4" && git commit -qam pr
  git checkout -q feat && git merge -q --no-ff -m merge pr > /dev/null
  bash -c "$CMUX_ACTION_EXPORTS_BUILD"
}
# edit SED_ON_SOURCE REGENERATES: change the source ('' changes the README instead).
edit() {
  if [[ -z "$1" ]]; then echo "$RANDOM" >> README.md; return; fi
  if [[ "$1" == other ]]; then echo "$RANDOM" >> Packages/macOS/Other/x.txt; return; fi
  sed -i.bak "$1" "$src" && rm -f "$src.bak"
  [[ "$2" == yes ]] && sed 's/^/action: /' "$src" > "$out"
  return 0
}
judge() { bash "$script" "$tmp/r/$pkg" > "$tmp/out.txt" 2>&1; }
products_are_heads() {
  cmp -s "$src" "$pkg/.build/actions.txt" || fail "$1: the built products are not HEAD's"
}

# (a) A stale base and a change that touches no action input: passes with a base drift warning, and
# the committed export stays in the checkout for nothing to collect.
repo 's/^a$/A/' no '' no
judge || fail "(a) a base-only drift failed: $(cat "$tmp/out.txt")"
grep -q 'base drift' "$tmp/out.txt" || fail "(a) no base drift warning: $(cat "$tmp/out.txt")"
git diff --quiet -- "$out" || fail "(a) the base's repair was left in the checkout"
products_are_heads "(a)"

# (b) A fresh base and a change to the catalog without regenerating: fails, naming the export.
repo '' no 's/^e$/E/' no
if judge; then fail "(b) a change's own stale export passed"; fi
grep -q "leaves action exports stale.*$out" "$tmp/out.txt" || fail "(b) no error naming $out: $(cat "$tmp/out.txt")"
grep -q "action: E" "$out" || fail "(b) the fresh export is not left for the regenerate step"
products_are_heads "(b)"

# (c) The base's drift plus the change's own stale export: fails on the change's part.
repo 's/^a$/A/' no 's/^e$/E/' no
if judge; then fail "(c) a change's own stale export passed beside the base's drift"; fi
grep -q "leaves action exports stale" "$tmp/out.txt" || fail "(c) no error: $(cat "$tmp/out.txt")"
products_are_heads "(c)"

# (d) The base's drift and a change that regenerated its own part: only the base's drift is stale.
repo 's/^a$/A/' no 's/^e$/E/' yes
judge || fail "(d) a regenerated change on a stale base failed: $(cat "$tmp/out.txt")"
grep -q 'base drift' "$tmp/out.txt" || fail "(d) no base drift warning"
products_are_heads "(d)"

# (e) A catalog failure that no regeneration fixes still fails, and tells the workflow so
# (catalog=failure), whose summary then says "catalog failure", never "stale".
repo '' no 's/^c$/BAD/' yes
: > "$tmp/gh-output"
if GITHUB_OUTPUT="$tmp/gh-output" judge; then fail "(e) a catalog failure passed"; fi
grep -q "a catalog failure, not a stale file" "$tmp/out.txt" || fail "(e) wrong reason: $(cat "$tmp/out.txt")"
grep -qx "catalog=failure" "$tmp/gh-output" || fail "(e) no catalog=failure output: $(cat "$tmp/gh-output")"
# A stale export of the change's own is not a catalog failure.
repo '' no 's/^c$/C/' no
: > "$tmp/gh-output"
if GITHUB_OUTPUT="$tmp/gh-output" judge; then fail "(e) a change's own stale export passed"; fi
if grep -q "catalog=" "$tmp/gh-output"; then fail "(e) a stale export reported a catalog failure"; fi

# (f) Fresh everywhere: passes with nothing to say.
repo '' no 's/^e$/E/' yes
judge || fail "(f) a fresh merge failed"
if grep -q 'base drift' "$tmp/out.txt"; then fail "(f) a fresh merge warned"; fi

# (g) A base parent whose package does not build: the stale export counts as the change's, and
# HEAD's products are put back.
repo 's/^a$/A/' no 's/^e$/E/' no
CMUX_ACTION_EXPORTS_BUILD="grep -q '^E$' $src || exit 1; $CMUX_ACTION_EXPORTS_BUILD" judge \
  && fail "(g) passed with an unbuildable base"
grep -q "does not build here" "$tmp/out.txt" || fail "(g) wrong reason: $(cat "$tmp/out.txt")"
products_are_heads "(g)"

# (i) A base regenerate that rewrites an export fresh at HEAD: HEAD's bytes are put back.
repo 's/^a$/A/' no 's/^e$/E/' yes
CMUX_ACTION_EXPORTS_REGEN="$CMUX_ACTION_EXPORTS_REGEN; grep -q '^E\$' $src || cp $src plans/cmux-next/actions.md" judge \
  || fail "(i) failed: $(cat "$tmp/out.txt")"
git diff --quiet -- plans/cmux-next/actions.md || fail "(i) the base's actions.md was left in the checkout"
products_are_heads "(i)"

# (j) The job built HEAD itself (CMUX_NEXT_JOB_BUILT=plain): HEAD's build is kept aside and put back,
# so the base is built once and HEAD never again, with the same verdicts and HEAD's products after.
counted="echo build >> $tmp/builds; $CMUX_ACTION_EXPORTS_BUILD"
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge || fail "(j) failed: $(cat "$tmp/out.txt")"
grep -q 'base drift' "$tmp/out.txt" || fail "(j) no base drift warning: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(j) built $(wc -l < "$tmp/builds") times, not once (the base's)"
products_are_heads "(j)"
[[ ! -e "$pkg/.build-action-exports-head" ]] || fail "(j) the kept build was left beside .build"
repo '' no 's/^e$/E/' no
: > "$tmp/builds"
if CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge; then fail "(j) a change's own stale export passed"; fi
grep -q "leaves action exports stale.*$out" "$tmp/out.txt" || fail "(j) no error naming $out: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(j) built $(wc -l < "$tmp/builds") times on a stale change"
products_are_heads "(j)"
# An unbuildable base still gets HEAD's kept products back, with no rebuild.
repo 's/^a$/A/' no 's/^e$/E/' no
: > "$tmp/builds"
CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="echo build >> $tmp/builds; grep -q '^E$' $src || exit 1; $CMUX_ACTION_EXPORTS_BUILD" judge \
  && fail "(j) passed with an unbuildable base"
grep -q "does not build here" "$tmp/out.txt" || fail "(j) wrong reason: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(j) rebuilt HEAD after an unbuildable base"
products_are_heads "(j)"
# Without the variable the restore still rebuilds HEAD (the base build, then HEAD's).
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
CMUX_ACTION_EXPORTS_BUILD="$counted" judge || fail "(j) failed without the variable: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 2 ]] || fail "(j) built $(wc -l < "$tmp/builds") times without a kept build, not twice"
products_are_heads "(j)"

# (k) CMUX_ACTION_EXPORTS_CACHE: a run that builds the base keeps its fresh export under the base's
# inputs key, and the next run on the same base inputs reads it instead of building, with the same
# verdicts (base drift passes, the change's own stale export fails) and HEAD's products after.
cache="$tmp/cache"
rm -rf "$cache"
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"; : > "$tmp/gh-output"
CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" GITHUB_OUTPUT="$tmp/gh-output" judge \
  || fail "(k) failed: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(k) built $(wc -l < "$tmp/builds") times, not once (the base's)"
base_key="$(bash "$script" --inputs-key HEAD^1)"
head_key="$(bash "$script" --inputs-key HEAD)"
[[ -n "$base_key" && "$base_key" != "$head_key" ]] || fail "(k) keys: base '$base_key' head '$head_key'"
grep -qx "base_key=$base_key" "$tmp/gh-output" || fail "(k) no base_key output: $(cat "$tmp/gh-output")"
grep -qx "head_key=$head_key" "$tmp/gh-output" || fail "(k) no head_key output: $(cat "$tmp/gh-output")"
grep -qx "base_built=true" "$tmp/gh-output" || fail "(k) no base_built output: $(cat "$tmp/gh-output")"
[[ -f "$cache/$base_key/.complete" && -f "$cache/$head_key/.complete" ]] || fail "(k) the cache lacks a key: $(ls -a "$cache")"
grep -q "action: A" "$cache/$base_key/$out" || fail "(k) the base key does not hold the base's fresh export"
if grep -q "action: E" "$cache/$base_key/$out"; then fail "(k) the base key holds HEAD's export"; fi
grep -q "action: E" "$cache/$head_key/$out" || fail "(k) the head key does not hold HEAD's fresh export"
products_are_heads "(k)"
# The same base again: no build, the same verdict.
repo 's/^a$/A/' no 's/^e$/E/' yes
[[ "$(bash "$script" --inputs-key HEAD^1)" == "$base_key" ]] || fail "(k) the same base inputs gave another key"
# The exports are no input: the base autofix's commit that lands them keeps the key they were made
# at, while any other change under plans/cmux-next moves it.
git checkout -q --detach HEAD^1
echo landed >> "$out" && git commit -qam "base autofix"
[[ "$(bash "$script" --inputs-key HEAD)" == "$base_key" ]] || fail "(k) a commit that changed only the exports moved the key"
echo note > plans/cmux-next/notes.md && git add plans/cmux-next/notes.md && git commit -qm "plan note"
[[ "$(bash "$script" --inputs-key HEAD)" != "$base_key" ]] || fail "(k) a plans/cmux-next change kept the key"
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge \
  || fail "(k) failed from the cache: $(cat "$tmp/out.txt")"
[[ ! -s "$tmp/builds" ]] || fail "(k) built $(wc -l < "$tmp/builds") times with the base's export in the cache"
grep -q 'came from the cache' "$tmp/out.txt" || fail "(k) no cache notice: $(cat "$tmp/out.txt")"
grep -q 'base drift' "$tmp/out.txt" || fail "(k) no base drift warning from the cache"
products_are_heads "(k)"
# A change's own stale export on that base still fails from the cache.
repo 's/^a$/A/' no 's/^e$/E/' no
: > "$tmp/builds"
if CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge; then
  fail "(k) a change's own stale export passed from the cache"
fi
grep -q "leaves action exports stale.*$out" "$tmp/out.txt" || fail "(k) no error naming $out: $(cat "$tmp/out.txt")"
[[ ! -s "$tmp/builds" ]] || fail "(k) built with the base's export in the cache"
# An incomplete entry (no .complete) is not read: the base is built.
rm -f "$cache/$base_key/.complete"
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge \
  || fail "(k) failed on an incomplete entry: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(k) an incomplete entry was read"
# In CI the base's key comes from the bucket (a file:// stand-in for its public URL) into a fresh
# directory: no build. Without CI (GITHUB_ACTIONS unset) the bucket is never read.
complete="$cache/$base_key/.complete"
: > "$complete"
bucket="$tmp/bucket/v1/cmux-next-action-exports/objects"
mkdir -p "$bucket" && tar -czf "$bucket/v1.$base_key.tar.gz" -C "$cache/$base_key" .
repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
GITHUB_ACTIONS=true CMUX_ACTION_EXPORTS_R2_URL="file://$tmp/bucket" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge \
  || fail "(k) failed from the bucket: $(cat "$tmp/out.txt")"
[[ ! -s "$tmp/builds" ]] || fail "(k) built with the base's export in the bucket: $(cat "$tmp/out.txt")"
grep -q 'came from the cache' "$tmp/out.txt" || fail "(k) no cache notice from the bucket: $(cat "$tmp/out.txt")"
: > "$tmp/builds"
GITHUB_ACTIONS='' CMUX_ACTION_EXPORTS_R2_URL="file://$tmp/bucket" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge \
  || fail "(k) failed outside CI: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(k) read the bucket outside CI"
# --publish: the base autofix's exports made at a commit (a directory holding those that differ from a
# fallback commit) become that commit's key, and a judge on that base reads them: no build.
rm -rf "$cache"
repo 's/^a$/A/' no 's/^e$/E/' yes
made="$tmp/made" && rm -rf "$made" && mkdir -p "$made/${out%/*}"
git show "HEAD^1:$src" | sed 's/^/action: /' > "$made/$out"
CMUX_ACTION_EXPORTS_CACHE="$cache" bash "$script" --publish HEAD^1 "$made" HEAD^1 > "$tmp/out.txt" 2>&1 \
  || fail "(k) --publish failed: $(cat "$tmp/out.txt")"
[[ -f "$cache/$base_key/.complete" ]] || fail "(k) --publish kept nothing under the base's key: $(cat "$tmp/out.txt")"
cmp -s "$cache/$base_key/plans/cmux-next/actions.md" <(git show HEAD^1:plans/cmux-next/actions.md) \
  || fail "(k) --publish did not take an unregenerated export from the fallback commit"
: > "$tmp/builds"
CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge \
  || fail "(k) failed from a --publish entry: $(cat "$tmp/out.txt")"
[[ ! -s "$tmp/builds" ]] || fail "(k) built with a --publish entry for the base"
grep -q 'base drift' "$tmp/out.txt" || fail "(k) no base drift warning from a --publish entry"
# A base whose regenerate fails keeps nothing.
rm -rf "$cache"
repo 's/^a$/A/' no 's/^e$/E/' no
CMUX_ACTION_EXPORTS_CACHE="$cache" CMUX_ACTION_EXPORTS_REGEN="grep -q '^E\$' $src || exit 1; $CMUX_ACTION_EXPORTS_REGEN" judge || true
[[ ! -e "$cache/$base_key" ]] || fail "(k) a failed base regenerate was kept"
# (l) The target graph names the exports' inputs (action_export_inputs.py): a change to a package
# outside the actions test target's closure builds nothing, as a README change does, while one inside
# it builds the base. Without a graph every Packages change counts, as before.
graph='{"packages": {}, "targets": {"CmuxNextActionsTests": {"kind": "test", "path": "Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests", "targets": ["CmuxNextActions"], "packages": [], "reads": ["plans/cmux-next/"]}, "CmuxNextActions": {"kind": "regular", "path": "Packages/macOS/CmuxNext/Sources", "targets": [], "packages": []}}}'
REPO_GRAPH="$graph" repo 's/^a$/A/' no other no
: > "$tmp/builds"
CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge || fail "(l) an outside change failed: $(cat "$tmp/out.txt")"
[[ ! -s "$tmp/builds" ]] || fail "(l) built the base for a change outside the exports' inputs: $(cat "$tmp/out.txt")"
grep -q 'base drift' "$tmp/out.txt" || fail "(l) no base drift warning: $(cat "$tmp/out.txt")"
products_are_heads "(l)"
REPO_GRAPH="$graph" repo 's/^a$/A/' no 's/^e$/E/' yes
: > "$tmp/builds"
CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge || fail "(l) an inside change failed: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(l) built $(wc -l < "$tmp/builds") times for a change inside the inputs, not once"
products_are_heads "(l)"
repo 's/^a$/A/' no other no
: > "$tmp/builds"
CMUX_NEXT_JOB_BUILT=plain CMUX_ACTION_EXPORTS_BUILD="$counted" judge || fail "(l) no graph failed: $(cat "$tmp/out.txt")"
[[ "$(wc -l < "$tmp/builds")" -eq 1 ]] || fail "(l) without a graph a Packages change did not build the base"
# The key moves with an input, not with an outside package or the generated block of actions.md.
REPO_GRAPH="$graph" repo '' no other no
key="$(bash "$script" --inputs-key HEAD)"
echo more >> Packages/macOS/Other/x.txt && git commit -qam outside
[[ "$(bash "$script" --inputs-key HEAD)" == "$key" ]] || fail "(l) an outside package moved the key"
printf 'md\n<!-- generated: action surfaces -->\nx\n<!-- /generated -->\n' > plans/cmux-next/actions.md && git commit -qam block
key="$(bash "$script" --inputs-key HEAD)"
printf 'md\n<!-- generated: action surfaces -->\ny\n<!-- /generated -->\n' > plans/cmux-next/actions.md && git commit -qam block2
[[ "$(bash "$script" --inputs-key HEAD)" == "$key" ]] || fail "(l) the generated block of actions.md moved the key"
printf 'md2\n<!-- generated: action surfaces -->\ny\n<!-- /generated -->\n' > plans/cmux-next/actions.md && git commit -qam hand
[[ "$(bash "$script" --inputs-key HEAD)" != "$key" ]] || fail "(l) the hand-written part of actions.md kept the key"
echo "judge-action-exports: ok"
