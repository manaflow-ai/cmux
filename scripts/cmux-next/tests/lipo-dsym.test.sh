#!/usr/bin/env bash
# lipo-dsym.sh keeps the dSYM of a lipo-merged binary:
# one slice dSYM is copied (also through cargo's symlink); two are merged by lipo -create of their DWARF
# files; a missing slice is skipped; with no slice left, or when lipo fails,
# the output (also a stale one) is removed and the exit status stays 0, so
# symbolication never fails a build. lipo is a stand-in.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# lipo-dsym.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/cmux-next/lipo-dsym.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lipo-dsym-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
# lipo -create IN... -output OUT: OUT holds every IN, in order.
cat > "$TMP/bin/lipo" <<'STUB'
#!/usr/bin/env bash
[[ -f "${LIPO_FAILS:-/nonexistent}" ]] && exit 1
inputs=(); out=""
shift
while [[ $# -gt 0 ]]; do
  case "$1" in -output) out="$2"; shift ;; *) inputs+=("$1") ;; esac
  shift
done
cat "${inputs[@]}" > "$out"
STUB
chmod +x "$TMP/bin/lipo"

dsym() { # <path> <dwarf contents>
  mkdir -p "$1/Contents/Resources/DWARF"
  printf 'plist of %s\n' "$2" > "$1/Contents/Info.plist"
  printf '%s\n' "$2" > "$1/Contents/Resources/DWARF/tool"
}
run() { env PATH="$TMP/bin:/usr/bin:/bin" LIPO_FAILS="$TMP/lipo-fails" bash "$SCRIPT" "$@" 2> "$TMP/err"; }
out="$TMP/products/tool.dSYM"
dwarf="$out/Contents/Resources/DWARF/tool"

dsym "$TMP/arm64/tool.dSYM" arm64
dsym "$TMP/x86_64/tool.dSYM" x86_64

# 1. One slice: copied, into a folder that did not exist.
run "$out" "$TMP/arm64/tool.dSYM" || fail "one slice failed: $(cat "$TMP/err")"
[[ "$(cat "$dwarf")" == arm64 ]] || fail "one slice was not copied"

# 2. Two slices: one DWARF file, lipo -create of both, with the first slice's Info.plist.
run "$out" "$TMP/arm64/tool.dSYM" "$TMP/x86_64/tool.dSYM" || fail "two slices failed: $(cat "$TMP/err")"
[[ "$(cat "$dwarf")" == $'arm64\nx86_64' ]] || fail "the two DWARF files were not merged: $(cat "$dwarf")"
[[ "$(cat "$out/Contents/Info.plist")" == "plist of arm64" ]] || fail "the merged dSYM lost its Info.plist"
[[ "$(ls "$out/Contents/Resources/DWARF")" == tool ]] || fail "the merged dSYM has more than its one DWARF file"
[[ -z "$(ls -d "$out".tmp.* 2>/dev/null)" ]] || fail "a temporary dSYM was left behind"

# 2b. Slices that are cargo's relative symlinks (release/<bin>.dSYM -> deps/<bin>-<hash>.dSYM):
# the output is a real folder that holds the DWARF file, never a copied link.
cargo_dsym() { # <release dir> <dwarf contents>
  dsym "$1/deps/tool-abc.dSYM" "$2"
  ln -s deps/tool-abc.dSYM "$1/tool.dSYM"
}
cargo_dsym "$TMP/arm64-link/release" arm64
cargo_dsym "$TMP/x86_64-link/release" x86_64
run "$out" "$TMP/arm64-link/release/tool.dSYM" || fail "one linked slice failed: $(cat "$TMP/err")"
[[ -d "$out" && ! -L "$out" ]] || fail "one linked slice was copied as a link"
[[ -f "$dwarf" && "$(cat "$dwarf")" == arm64 ]] || fail "one linked slice has no DWARF file"
run "$out" "$TMP/arm64-link/release/tool.dSYM" "$TMP/x86_64-link/release/tool.dSYM" ||
  fail "two linked slices failed: $(cat "$TMP/err")"
[[ -d "$out" && ! -L "$out" ]] || fail "two linked slices were copied as a link"
[[ -f "$dwarf" && "$(cat "$dwarf")" == $'arm64\nx86_64' ]] || fail "two linked slices were not merged: $(cat "$dwarf" 2>&1)"
[[ "$(cat "$TMP/arm64-link/release/deps/tool-abc.dSYM/Contents/Resources/DWARF/tool")" == arm64 ]] ||
  fail "the merge wrote into the first slice's dSYM"

# 3. A missing slice is skipped with a note; the other is kept.
run "$out" "$TMP/arm64/tool.dSYM" "$TMP/missing/tool.dSYM" || fail "a missing slice failed the build"
[[ "$(cat "$dwarf")" == arm64 ]] || fail "the remaining slice was not kept"
grep -q "no dSYM at $TMP/missing/tool.dSYM" "$TMP/err" || fail "the skipped slice was not named: $(cat "$TMP/err")"

# 4. No slice left: the earlier dSYM goes, so none outlives its binary.
run "$out" "$TMP/missing/tool.dSYM" || fail "no slices failed the build"
[[ ! -e "$out" ]] || fail "a stale dSYM stayed when no slice had one"
run "$out" || fail "no arguments failed the build"

# 5. lipo fails: a warning, exit 0, no partial dSYM.
dsym "$out" stale
: > "$TMP/lipo-fails"
run "$out" "$TMP/arm64/tool.dSYM" "$TMP/x86_64/tool.dSYM" || fail "a lipo failure failed the build"
grep -q '^warning: lipo-dsym:' "$TMP/err" || fail "a lipo failure left no warning: $(cat "$TMP/err")"
[[ ! -e "$out" ]] || fail "a failed merge left a dSYM"
[[ -z "$(ls -d "$out".tmp.* 2>/dev/null)" ]] || fail "a failed merge left its temporary dSYM"

echo "lipo-dsym tests: ok"
