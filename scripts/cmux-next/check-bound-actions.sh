#!/usr/bin/env bash
# Fails when a running tagged cmux-next build has unbound actions in the given
# categories. CmuxNextApp links GhosttyKit, which SwiftPM cannot link, so the
# App's handler coverage is checked against the live registry over the
# control socket (`action.list`) instead of in `swift test`.
#
# Usage: scripts/cmux-next/check-bound-actions.sh <tag> [category ...]
#   default categories: browser notifications agents cloud
# Prints unavailable actions with their reasons; exit 1 on any unbound one.
set -euo pipefail
tag="${1:?usage: $0 <tag> [category ...]}"
shift
categories=("$@")
(( ${#categories[@]} )) || categories=(browser notifications agents cloud)
root="$(cd "$(dirname "$0")/../.." && pwd)"
json="$(CMUX_TAG="$tag" "$root/scripts/cmux-debug-cli.sh" action list --json)"
CATEGORIES="${categories[*]}" python3 - "$json" <<'PY'
import json, os, sys
payload = json.loads(sys.argv[1])
actions = payload.get("actions", payload) if isinstance(payload, dict) else payload
wanted = set(os.environ["CATEGORIES"].split())
mine = [a for a in actions if a.get("category") in wanted]
unbound = [a["id"] for a in mine if not a.get("bound")]
unavailable = [(a["id"], a["unavailable_reason"]) for a in mine if a.get("unavailable_reason")]
print(f"{len(mine)} actions in {sorted(wanted)}: {len(mine) - len(unbound) - len(unavailable)} bound, "
      f"{len(unavailable)} unavailable, {len(unbound)} unbound")
for action_id, reason in unavailable:
    print(f"  unavailable {action_id}: {reason}")
for action_id in unbound:
    print(f"  UNBOUND {action_id}")
sys.exit(1 if unbound or not mine else 0)
PY
