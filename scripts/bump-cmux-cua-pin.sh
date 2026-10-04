#!/usr/bin/env bash
# Bump the cmux-cua pin and re-vendor CmuxAgentCursor from the same commit.
# Usage: scripts/bump-cmux-cua-pin.sh <40-char cmux-cua commit>
# Then build the app on the fleet at the bumped commit before pushing.
set -euo pipefail
sha="${1:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 <40-char cmux-cua commit>" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
sed -i.bak -E "s/^CMUX_CUA_PINNED_SHA=\"[0-9a-f]{40}\"$/CMUX_CUA_PINNED_SHA=\"$sha\"/" "$root/scripts/build-cmux-cua.sh"
rm -f "$root/scripts/build-cmux-cua.sh.bak"
grep -q "^CMUX_CUA_PINNED_SHA=\"$sha\"$" "$root/scripts/build-cmux-cua.sh" || { echo "pin edit failed" >&2; exit 1; }
python3 "$root/scripts/cmux_agent_cursor_vendor.py" sync
python3 "$root/scripts/cmux_agent_cursor_vendor.py" check
git -C "$root" add scripts/build-cmux-cua.sh Packages/Shared/CmuxAgentCursor
echo "staged the pin bump to $sha with the vendored CmuxAgentCursor; commit both together"
