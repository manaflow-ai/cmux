from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_TREE_READER = ROOT / "Sources" / "Workspace+WorkspaceSurfaceTreeReading.swift"


def test_workspace_pane_owner_lookup_uses_bonsplit_index() -> None:
    source = WORKSPACE_TREE_READER.read_text(encoding="utf-8")
    function = source.split("func paneId(forPanelId panelId: UUID) -> PaneID? {", 1)[1]
    function = function.split("\n    }", 1)[0]

    assert "bonsplitController.paneId(containing: tabId)" in function
    assert "bonsplitController.allPaneIds" not in function
    assert "bonsplitController.tabs(inPane:" not in function
