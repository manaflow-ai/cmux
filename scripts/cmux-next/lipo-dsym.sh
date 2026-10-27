#!/usr/bin/env bash
# The dSYM of a binary that lipo -create merged from per-arch slices, so a crash
# in either slice symbolicates: Sentry and atos match a dSYM by the slice's
# LC_UUID, which lipo keeps.
#
#   lipo-dsym.sh <out.dSYM> <slice.dSYM>...
#
# One slice dSYM is copied; several are merged the way their binaries were, by
# lipo -create of their DWARF files (what Xcode's dsymutil writes for a
# universal binary). A slice without a dSYM is skipped with a note (a cache
# entry from before dSYMs, or a build without debug info). <out.dSYM> is
# replaced, and removed when no slice has one, so a dSYM of an earlier build
# never stays beside a newer binary.
#
# Symbolication never fails a build: a failure is a warning and the exit
# status is 0.
set -uo pipefail

out="${1:?usage: lipo-dsym.sh <out.dSYM> <slice.dSYM>...}"
shift

warn() {
  echo "warning: lipo-dsym: $*; $(basename "$out") is not kept" >&2
  rm -rf "$tmp" "$out"
  exit 0
}

# The DWARF file of a dSYM bundle (dsymutil writes exactly one).
dwarf_of() {
  local files=("$1"/Contents/Resources/DWARF/*)
  [[ ${#files[@]} -eq 1 && -f "${files[0]}" ]] || return 1
  printf '%s\n' "${files[0]}"
}

# cargo leaves release/<bin>.dSYM as a relative symlink into deps/, and cp -R
# copies a symlink operand as a link, so each slice is taken at its real path.
slices=()
for dsym in "$@"; do
  if [[ -d "$dsym/Contents/Resources/DWARF" ]]; then
    slices+=("$(cd "$dsym" && pwd -P)")
  else
    echo "note: lipo-dsym: no dSYM at $dsym; skipped" >&2
  fi
done

tmp="$out.tmp.$$"
rm -rf "$out" "$tmp"
[[ ${#slices[@]} -gt 0 ]] || exit 0
mkdir -p "$(dirname "$out")" || warn "cannot create $(dirname "$out")"
cp -R "${slices[0]}" "$tmp" || warn "cannot copy ${slices[0]}"
if [[ ${#slices[@]} -gt 1 ]]; then
  dwarfs=()
  for dsym in "${slices[@]}"; do
    dwarf="$(dwarf_of "$dsym")" || warn "$dsym has no single DWARF file"
    dwarfs+=("$dwarf")
  done
  merged="$tmp/Contents/Resources/DWARF/$(basename "${dwarfs[0]}")"
  lipo -create "${dwarfs[@]}" -output "$merged.lipo" || warn "lipo -create of ${dwarfs[*]} failed"
  mv -f "$merged.lipo" "$merged" || warn "cannot replace $merged"
fi
mv "$tmp" "$out" || warn "cannot move the dSYM to $out"
