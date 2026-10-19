#!/usr/bin/env python3
"""Live catalog identity regression using only uniquely owned scratch workspaces."""
import json
import os
import sys
from pathlib import Path
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def require(condition, message):
    if not condition:
        raise cmuxError(message)


def rows(client, workspace):
    payload = client._call("surface.catalog", {"machine": "local", "refresh": False})
    return [row for row in payload["projections"] if row["workspace_id"] == workspace]


def check_identity(row):
    for key in ("stable_surface_id", "stable_workspace_id", "surface_id", "workspace_id"):
        require(isinstance(row.get(key), str), f"missing identity field {key}")
        uuid.UUID(row[key])
    require(row["surface_id"] == row["panel_id"], "legacy surface/panel selectors changed")
    require(row["resource"] == f"local/terminal/{row['panel_id']}", "legacy resource key changed")


def main():
    socket_path = os.environ.get("CMUX_SOCKET_PATH", "")
    require(bool(socket_path), "CMUX_SOCKET_PATH must explicitly select a tagged test app")
    token = "identity-regression-" + uuid.uuid4().hex
    created = []
    cleanup_errors = []
    with cmux(socket_path) as client:
        try:
            for index, count in enumerate((2, 1)):
                result = client._call("workspace.create", {
                    "title": f"{token}-{index}", "focus": False,
                    "layout": {"pane": {"surfaces": [
                        {"type": "terminal", "name": "same label"} for _ in range(count)
                    ]}},
                })
                created.append(result["workspace_id"])
            source, target = created
            before = rows(client, source)
            target_before = rows(client, target)
            require(len(before) == 2 and len(target_before) == 1, "scratch projections not captured")
            for row in before + target_before:
                check_identity(row)
            require(len({row["stable_surface_id"] for row in before + target_before}) == 3,
                    "same-labelled surfaces share stable identity")
            require(len({row["stable_workspace_id"] for row in before}) == 1,
                    "one workspace published inconsistent stable identity")
            moved = before[0]
            client._call("surface.move", {
                "surface_id": moved["surface_id"], "workspace_id": target, "focus": False,
            })
            target_after = rows(client, target)
            after = next((row for row in target_after if row["surface_id"] == moved["surface_id"]), None)
            require(after is not None, "moved surface missing from destination catalog")
            check_identity(after)
            require(after["stable_surface_id"] == moved["stable_surface_id"], "move changed stable surface")
            require(after["stable_workspace_id"] == target_before[0]["stable_workspace_id"],
                    "move did not capture destination stable workspace")
            require(after["stable_workspace_id"] != moved["stable_workspace_id"],
                    "move retained former workspace identity")
            require(after["resource"] == moved["resource"], "move renamed the resource")
            require(all(row["surface_id"] != moved["surface_id"] for row in rows(client, source)),
                    "source still publishes moved projection")
        finally:
            for workspace in reversed(created):
                try:
                    client._call("workspace.close", {"workspace_id": workspace})
                except Exception as error:
                    cleanup_errors.append(f"{workspace}: {error}")
            require(not cleanup_errors, "scratch cleanup failed: " + "; ".join(cleanup_errors))
    print(json.dumps({"status": "pass", "scratch_workspaces": 2, "surfaces": 3,
                      "owner_ids_present": True, "same_label_identity_distinct": True,
                      "move_preserves_surface_and_resource": True,
                      "move_updates_stable_workspace": True, "scratch_cleanup": "complete"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
