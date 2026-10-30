#!/usr/bin/env bash
# judge-action-exports.sh: a stale action export fails a change only when the change itself left it
# stale. The base's own drift (the base autofix's to regenerate) is a warning.
#
# A fake package: the "build" copies Sources/actions.txt into .build, and the generator writes
# plans/cmux-next/action-surfaces.json from the BUILT copy, so the base's export comes from a real
# rebuild at the base and the products are HEAD's again afterwards. Each case is a merge commit
# (HEAD^1 = the base tip), as a pull request's checkout is.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../judge-action-exports.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
src=Packages/macOS/CmuxNext/Sources/actions.txt
out=plans/cmux-next/action-surfaces.json
pkg=Packages/macOS/CmuxNext

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

# (e) A catalog failure that no regeneration fixes still fails.
repo '' no 's/^c$/BAD/' yes
if judge; then fail "(e) a catalog failure passed"; fi
grep -q "a catalog failure, not a stale file" "$tmp/out.txt" || fail "(e) wrong reason: $(cat "$tmp/out.txt")"

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
echo "judge-action-exports: ok"
