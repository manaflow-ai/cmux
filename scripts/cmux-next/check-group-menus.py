#!/usr/bin/env python3
"""Fails when a right-click menu hides its group rows (Lawrence 2026-10-14: "my groups UI is lost").

Reads the exported right-click menus in plans/cmux-next/action-surfaces.json (`context_menus`),
which ActionSurfaceParityTests keeps equal to the menus the app builds, and checks that the
group rows sit at the TOP level of the workspace row and tab menus, not inside a folder such as
More:
  workspaceRow: Move to Group (a choices row that ends with New Group, so it shows with zero
                groups), Group Selected Workspaces, Remove from Group
  tab:          New Tab Group, Add to Group, Remove from Group
and that the group header menus keep their rows. PR #19754 (ec4962719b95) moved these rows into
More and nothing failed; this check is the guard. Moving a group row needs Lawrence's yes: change
REQUIRED below in the same commit and say so in the commit message.

Usage: scripts/cmux-next/check-group-menus.py [repo-root]
"""
import json
import os
import sys

REQUIRED = {
    "workspaceRow": ["moveWorkspaceToGroup", "groupSelectedWorkspaces", "removeWorkspaceFromGroup"],
    "tab": ["tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab"],
    "workspaceGroup": ["workspaceGroup.rename", "toggleFocusedWorkspaceGroupCollapsed"],
    "tabGroup": ["tabGroup.rename", "tabGroup.toggleCollapsed", "tabGroup.ungroup"],
}
# A choices row and the action its submenu must always end with.
TRAILERS = {("workspaceRow", "moveWorkspaceToGroup"): "workspace.moveToNewGroup"}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    path = os.path.join(root, "plans", "cmux-next", "action-surfaces.json")
    with open(path) as f:
        menus = json.load(f)["context_menus"]
    failures = []
    for menu, wanted in REQUIRED.items():
        top = {e.get("id"): e for e in (menus.get(menu) or {}).get("entries", []) if e.get("kind") in ("action", "choices")}
        for action in wanted:
            if action not in top:
                failures.append(f"{menu}: {action} is not a top-level row (inside a folder, or gone)")
            elif (menu, action) in TRAILERS:
                trailer = ((top[action].get("choices") or {}).get("trailer") or {}).get("id")
                if trailer != TRAILERS[(menu, action)]:
                    failures.append(f"{menu}: {action} does not end with {TRAILERS[(menu, action)]} (trailer {trailer!r})")
    for failure in failures:
        print("check-group-menus: FAIL " + failure, file=sys.stderr)
    if failures:
        print("check-group-menus: the group rows must stay at the top of these menus (scripts/cmux-next/check-group-menus.py)",
              file=sys.stderr)
        return 1
    print("check-group-menus: ok, the group rows are at the top of " + ", ".join(REQUIRED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
