#!/usr/bin/env python3
"""Chief Home uses an ordinary workspace, preserving the local workspace list.

Run against an explicitly named tagged app socket:
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_chief_native_home.py
"""

import os
import time

from cmux import cmux, cmuxError


def wait_for_surfaces(client, workspace_id, predicate):
    """Topology reads are published asynchronously after a pane mutation."""
    deadline = time.monotonic() + 5
    while True:
        rows = client._call("surface.list", {"workspace_id": workspace_id})["surfaces"]
        if predicate(rows):
            return rows
        if time.monotonic() >= deadline:
            raise AssertionError(f"Surface topology did not settle: {rows}")
        time.sleep(0.15)


def main():
    path = os.environ.get("CMUX_SOCKET_PATH", "")
    if not path or "cmux-debug-" not in path:
        raise RuntimeError("Set CMUX_SOCKET_PATH to an isolated tagged development socket")
    with cmux(path) as client:
        before = client._call("workspace.list")["workspaces"]
        groups = client._call("workspace.group.list")["groups"]
        chief_members = {
            member
            for group in groups if group.get("external_id") == "cmux.chief.home"
            for member in group["member_workspace_ids"]
        }
        local = next((row for row in before if row["id"] not in chief_members and row["title"] != "Home"), None)
        assert local is not None, "Keep a local workspace for the Home navigation regression"
        client._call("workspace.select", {"workspace_id": local["id"]})
        client._call("chief.open")
        after = client._call("workspace.list")["workspaces"]
        home = next((row for row in after if row["selected"] and row["title"] == "Home"), None)
        assert home is not None, "chief.open must select a native Home workspace, not an overlay"
        assert {row["id"] for row in before} <= {row["id"] for row in after}, "Home removed local workspaces"
        groups = client._call("workspace.group.list")["groups"]
        group = next((row for row in groups if row.get("external_id") == "cmux.chief.home"), None)
        assert group is not None, "Home must belong to the ordinary sidebar group list"
        assert group["name"] == "Home", "The parent must be named Home, not Chief"
        assert group["is_pinned"], "Home must stay pinned above local workspaces"
        assert group["anchor_workspace_id"] == home["id"]
        members = set(group["member_workspace_ids"])
        assert local["id"] not in members, "Local workspaces must stay outside Home"
        for method, collapsed in [("collapse", True), ("expand", False)]:
            client._call(f"workspace.group.{method}", {"group_id": group["id"]})
            updated = client._call("workspace.group.list")["groups"]
            updated = next(row for row in updated if row["id"] == group["id"])
            assert updated["is_collapsed"] == collapsed
            assert set(updated["member_workspace_ids"]) == members, "Disclosure must preserve Chief panes"
        surfaces = client._call("surface.list", {"workspace_id": home["id"]})["surfaces"]
        chiefs = [row for row in surfaces if row["type"] == "chief"]
        assert len(chiefs) == 1, "Home needs its canonical Chief pane"
        split = client._call("surface.split", {"workspace_id": home["id"], "direction": "right", "type": "terminal"})
        split_id = split["surface_id"]
        try:
            split_surfaces = wait_for_surfaces(client, home["id"], lambda rows: any(
                row["id"] == split_id and row["type"] == "terminal" for row in rows
            ))
            assert any(row["id"] == chiefs[0]["id"] for row in split_surfaces), "Splitting Home removed its Chief"
            selected = next(row for row in client._call("workspace.list")["workspaces"] if row["selected"])
            assert selected["id"] == home["id"], "A split must stay in Home's native pane layout"
        finally:
            client._call("surface.close", {"workspace_id": home["id"], "surface_id": split_id, "force": True})
            wait_for_surfaces(client, home["id"], lambda rows: all(row["id"] != split_id for row in rows))
        for method, params in [
            ("surface.close", {"workspace_id": home["id"], "surface_id": chiefs[0]["id"], "force": True}),
            ("workspace.close", {"workspace_id": home["id"]}),
        ]:
            try:
                client._call(method, params)
            except cmuxError:
                pass
            remaining = client._call("workspace.list")["workspaces"]
            assert any(row["id"] == home["id"] for row in remaining), "Canonical Home was closed"
            remaining_surfaces = client._call("surface.list", {"workspace_id": home["id"]})["surfaces"]
            assert any(row["id"] == chiefs[0]["id"] for row in remaining_surfaces), "Canonical Chief was closed"
        print("PASS: Chief is a protected native Home workspace; local workspaces remain in the list")


if __name__ == "__main__":
    main()
