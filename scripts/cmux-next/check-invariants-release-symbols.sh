#!/usr/bin/env bash
# The Release half of plans/cmux-next/invariants-DESIGN.md section 6: a Release (or Nightly) cmux-next binary has
# no invariant checker code. Only the ids, keys, subjects and the empty inlined probe compile in Release (and
# CmuxNextControl's InvariantsControl, which answers debug.invariants with {"armed": false, "mode": "release"}), so
# the binary must hold no type of the registry, the ledger, the turn observer, a rule or a pass.
#
# Usage: scripts/cmux-next/check-invariants-release-symbols.sh RELEASE_APP_OR_BINARY [--control DEBUG_APP_OR_BINARY]
#   RELEASE_APP_OR_BINARY  a .app bundle (its Contents/MacOS executable is read) or a Mach-O binary.
#   --control DEBUG_APP    a Debug or bench build of the same commit: the same read must FIND the checker there, so
#                          the check is shown able to see what it looks for.
# Exit 0: the Release binary is a cmux-next binary (its Release invariant types are found) with no checker type.
# Exit 1: a checker type is in the Release binary (listed). Exit 2: usage error, or nothing was proved (a read
# failed, the binary is not a cmux-next binary, or the control build shows no checker).
#
# It reads two sources, so a stripped binary cannot pass on nothing: the symbol table (`nm`, demangled when
# swift-demangle is there) and every string in the file (`strings -a`). Swift keeps each type's name as a plain
# string in its type descriptor and its mangled name in the reflection metadata (__swift5_typeref, __swift5_reflstr),
# which stripping does not remove. Run it on the fleet against a Release build (cmux-ci build cmux --release); it is
# not a CI gate.
set -euo pipefail
usage="usage: check-invariants-release-symbols.sh RELEASE_APP_OR_BINARY [--control DEBUG_APP_OR_BINARY]"
release="${1:?$usage}"
shift
control=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --control) control="${2:?$usage}"; shift 2 ;;
    *) echo "check-invariants-release-symbols: unknown argument $1" >&2; echo "$usage" >&2; exit 2 ;;
  esac
done

binary_of() {
  local target="$1"
  if [[ -d "$target" ]]; then
    local name
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")" || return 2
    target="$target/Contents/MacOS/$name"
  fi
  [[ -f "$target" ]] || { echo "check-invariants-release-symbols: $target is not a file" >&2; return 2; }
  printf '%s\n' "$target"
}

# The names a checker type leaves: its descriptor's plain name, or a word of a mangled name ("17InvariantRegistryC").
checker='Invariant(Registry|TurnObserver|Ledger|RuleRecord|RuleStats|Rule|Pass|Timing|Mode|Violation|Trigger|ReportStore|Coverage|ActionRing|ActionCause|Finding|Pending|CheckPoints|Cost)'
# Release types that must be there: the binary is a cmux-next app that links CmuxNextInvariants and serves the method.
release_types=(InvariantsControl InvariantProbe debug.invariants)

# Every name in `binary`: its symbols (demangled when possible) and its strings. Fails when a read fails.
names_of() {
  local binary="$1" symbols
  symbols="$(nm -a "$binary")" || { echo "check-invariants-release-symbols: nm failed on $binary" >&2; return 2; }
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    printf '%s\n' "$symbols" | xcrun swift-demangle --simplified || return 2
  fi
  printf '%s\n' "$symbols"
  strings -a "$binary" || { echo "check-invariants-release-symbols: strings failed on $binary" >&2; return 2; }
}

# A checker name as a whole word: after a non-letter (a NUL, a mangled length, a '.'), and not followed by a lowercase
# letter (a mangled name ends with its kind, `C`, `V` or `O`).
hits_in() {
  grep -oE "(^|[^A-Za-z])${checker}($|[^a-z])" <<<"$1" | grep -oE "$checker" | sort | uniq -c || true
}

release_binary="$(binary_of "$release")" || exit 2
release_names="$(names_of "$release_binary")" || exit 2
for name in "${release_types[@]}"; do
  if ! grep -qF -- "$name" <<<"$release_names"; then
    echo "check-invariants-release-symbols: $release_binary has no '$name': not a cmux-next build with the" \
      "invariant framework, or the read saw nothing; nothing is proved" >&2
    exit 2
  fi
done

if [[ -n "$control" ]]; then
  control_binary="$(binary_of "$control")" || exit 2
  control_names="$(names_of "$control_binary")" || exit 2
  control_hits="$(hits_in "$control_names")"
  if ! grep -q 'InvariantRegistry' <<<"$control_hits"; then
    echo "check-invariants-release-symbols: the control build $control_binary shows no InvariantRegistry: this read" \
      "cannot see a checker, so the Release result proves nothing" >&2
    exit 2
  fi
  echo "check-invariants-release-symbols: control ok, the read finds the checker in $control_binary:"
  printf '%s\n' "$control_hits" | head -20
fi

found="$(hits_in "$release_names")"
if [[ -n "$found" ]]; then
  echo "check-invariants-release-symbols: $release_binary has invariant checker types (a Release build must have none):"
  printf '%s\n' "$found"
  grep -E "(^|[^A-Za-z])${checker}($|[^a-z])" <<<"$release_names" | sort -u | head -40
  exit 1
fi
echo "check-invariants-release-symbols: ok, $release_binary has ${release_types[*]} and no invariant checker type"
