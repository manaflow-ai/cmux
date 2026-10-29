#!/usr/bin/env bash
# The Release half of plans/cmux-next/invariants-DESIGN.md section 6: a Release (or Nightly) cmux-next binary has
# no invariant checker code. Only the ids, keys, subjects and the empty inlined probe compile in Release, so the
# binary must hold no symbol of the registry, the ledger, the turn observer, a rule or a pass.
#
# Usage: scripts/cmux-next/check-invariants-release-symbols.sh APP_OR_BINARY
#   APP_OR_BINARY  a .app bundle (its Contents/MacOS executable is read) or a Mach-O binary.
# Exit 0 when no checker symbol is found, 1 when one is (they are listed), 2 on a usage error.
# Run it on the fleet against a Release build (cmux-ci build cmux --release); it is not a CI gate.
set -euo pipefail
target="${1:?usage: check-invariants-release-symbols.sh APP_OR_BINARY}"
if [[ -d "$target" ]]; then
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")"
  target="$target/Contents/MacOS/$name"
fi
[[ -f "$target" ]] || { echo "check-invariants-release-symbols: $target is not a file" >&2; exit 2; }
pattern='Invariant(Registry|TurnObserver|Ledger|Rule|RuleRecord|Pass|Timing|Mode|Violation|Trigger)'
found="$(nm -a "$target" 2>/dev/null | grep -E "CmuxNextInvariants.*$pattern" || true)"
if [[ -n "$found" ]]; then
  echo "check-invariants-release-symbols: $target has invariant checker symbols (a Release build must have none):"
  printf '%s\n' "$found" | head -40
  exit 1
fi
echo "check-invariants-release-symbols: ok, no invariant checker symbol in $target"
