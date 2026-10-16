"""Topology responses used by the tmux polling integration tests."""

from __future__ import annotations

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"
NEW_PANE_ID = "66666666-6666-4666-8666-666666666666"
NEW_SURFACE_ID = "77777777-7777-4777-8777-777777777777"


class FakeCmuxState:
    """Workspace topology for executable tmux command integration tests."""

    def __init__(self) -> None:
        self.split_created = False
        self.split_count = 0
        self.focus_new = False
        self.sent_text: list[str] = []

    def require_workspace(self, method: str, params: dict[str, object]) -> None:
        """Reject a call aimed at a workspace this fake does not host."""
        workspace_id = params.get("workspace_id")
        if workspace_id != WORKSPACE_ID:
            raise RuntimeError(
                f"{method} targeted workspace {workspace_id!r}, expected {WORKSPACE_ID}"
            )

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        if method in {
            "surface.current",
            "surface.list",
            "pane.list",
            "pane.surfaces",
            "surface.split",
            "surface.send_text",
            "workspace.equalize_splits",
        }:
            self.require_workspace(method, params)

        if method == "workspace.list":
            return {
                "window_id": "window-1",
                "window_ref": "window:1",
                "workspaces": [
                    {
                        "id": WORKSPACE_ID,
                        "ref": "workspace:1",
                        "index": 0,
                        "title": "cmux",
                    }
                ],
            }
        if method == "workspace.current":
            return {"workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1"}
        if method == "window.list":
            return {"windows": [{"id": "window-1", "ref": "window:1", "index": 0}]}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
            }
        if method == "surface.list":
            surfaces = [
                {
                    "id": SURFACE_ID,
                    "ref": "surface:1",
                    "focused": not self.focus_new,
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "title": "leader",
                }
            ]
            if self.split_created:
                surfaces.append(
                    {
                        "id": NEW_SURFACE_ID,
                        "ref": "surface:2",
                        "focused": self.focus_new,
                        "pane_id": NEW_PANE_ID,
                        "pane_ref": "pane:2",
                        "title": "teammate",
                    }
                )
            return {"surfaces": surfaces}
        if method == "pane.list":
            panes = [
                {
                    "id": PANE_ID,
                    "ref": "pane:1",
                    "index": 0,
                    "focused": not self.focus_new,
                    "columns": 94,
                    "rows": 37,
                    "selected_surface_id": SURFACE_ID,
                    "selected_surface_ref": "surface:1",
                    "surface_count": 1,
                    "surface_ids": [SURFACE_ID],
                    "surface_refs": ["surface:1"],
                }
            ]
            if self.split_created:
                panes.append(
                    {
                        "id": NEW_PANE_ID,
                        "ref": "pane:2",
                        "index": 1,
                        "focused": self.focus_new,
                        "columns": 47,
                        "rows": 37,
                        "selected_surface_id": NEW_SURFACE_ID,
                        "selected_surface_ref": "surface:2",
                        "surface_count": 1,
                        "surface_ids": [NEW_SURFACE_ID],
                        "surface_refs": ["surface:2"],
                    }
                )
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "container_frame": {"width": 760, "height": 672},
                "panes": panes,
            }
        if method == "surface.split":
            target_surface = params.get("surface_id")
            if target_surface != SURFACE_ID:
                raise RuntimeError(
                    f"surface.split targeted surface {target_surface!r}, "
                    f"expected {SURFACE_ID}"
                )
            self.split_created = True
            self.focus_new = params.get("focus") is True
            self.split_count += 1
            return {"surface_id": NEW_SURFACE_ID, "pane_id": NEW_PANE_ID}
        if method == "surface.send_text":
            self.sent_text.append(str(params.get("text", "")))
            known_surfaces = {SURFACE_ID} | (
                {NEW_SURFACE_ID} if self.split_created else set()
            )
            if params.get("surface_id") not in known_surfaces:
                raise RuntimeError(
                    f"surface.send_text targeted surface {params.get('surface_id')!r}, "
                    f"expected one of {sorted(known_surfaces)}"
                )
            return {"ok": True}
        if method in {"workspace.equalize_splits", "surface.select", "workspace.select"}:
            return {"ok": True}
        if method == "pane.surfaces":
            known_panes = {PANE_ID} | ({NEW_PANE_ID} if self.split_created else set())
            if params.get("pane_id") not in known_panes:
                raise RuntimeError(
                    f"pane.surfaces targeted pane {params.get('pane_id')!r}, "
                    f"expected one of {sorted(known_panes)}"
                )
            if self.split_created and params.get("pane_id") == NEW_PANE_ID:
                return {
                    "surfaces": [
                        {
                            "id": NEW_SURFACE_ID,
                            "ref": "surface:2",
                            "selected": True,
                            "title": "teammate",
                        }
                    ]
                }
            return {
                "surfaces": [
                    {
                        "id": SURFACE_ID,
                        "ref": "surface:1",
                        "selected": True,
                        "title": "leader",
                    }
                ]
            }
        raise RuntimeError(f"Unsupported fake cmux method: {method}")
