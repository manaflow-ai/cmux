#!/usr/bin/env python3
"""Chief Home uses an ordinary workspace, preserving the local workspace list.

Run against an explicitly named tagged app socket:
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_chief_native_home.py
"""

import os

from cmux import cmux, cmuxError


def main():
    path = os.environ.get("CMUX_SOCKET_PATH", "")
    if not path or "cmux-debug-" not in path:
        raise RuntimeError("Set CMUX_SOCKET_PATH to an isolated tagged development socket")
    with cmux(path) as client:
        before = client._call("workspace.list")["workspaces"]
        local = next((row for row in before if row["title"] != "Home"), None)
        assert local is not None, "Keep a local workspace for the Home navigation regression"
        client._call("workspace.select", {"workspace_id": local["id"]})
        client._call("chief.open")
        after = client._call("workspace.list")["workspaces"]
        home = next((row for row in after if row["selected"] and row["title"] == "Home"), None)
        assert home is not None, "chief.open must select a native Home workspace, not an overlay"
        assert {row["id"] for row in before} <= {row["id"] for row in after}, "Home removed local workspaces"
        surfaces = client._call("surface.list", {"workspace_id": home["id"]})["surfaces"]
        chiefs = [row for row in surfaces if row["type"] == "chief"]
        assert len(chiefs) == 1, "Home needs its canonical Chief pane"
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
