from __future__ import annotations

import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "skills" / "cmux-settings" / "scripts" / "cmux-settings"
SCHEMA = ROOT / "web" / "data" / "cmux.schema.json"


def run_helper(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HELPER), *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def test_appearance_and_sidebar_glass_paths_are_supported() -> None:
    result = run_helper("list-supported")
    assert result.returncode == 0, result.stderr
    paths = set(result.stdout.splitlines())
    assert {
        "appearance.colors.accent",
        "appearance.colors.hover",
        "appearance.colors.dropTarget",
        "appearance.colors.notification",
        "appearance.colors.success",
        "appearance.colors.warning",
        "appearance.colors.error",
        "appearance.colors.toolbarIcon",
        "appearance.colors.tabIcon",
        "appearance.icons",
        "sidebarAppearance.material",
        "sidebarAppearance.blurOpacity",
        "sidebarAppearance.cornerRadius",
        "paneBorderColor",
        "activePaneBorderColor",
    } <= paths


def test_validator_accepts_appearance_maps_and_sidebar_liquid_glass(tmp_path: Path) -> None:
    config = tmp_path / "cmux.json"
    config.write_text(
        json.dumps(
            {
                "appearance": {
                    "colors": {"accent": "#7C3AED", "dropTarget": "#F59E0B"},
                    "icons": {"plus": "sparkles", "terminal": "apple.terminal"},
                },
                "sidebarAppearance": {
                    "material": "liquidGlass",
                    "blendMode": "withinWindow",
                    "state": "followWindow",
                    "blurOpacity": 0.9,
                    "cornerRadius": 12,
                },
                "paneBorderColor": "#6B7280",
                "activePaneBorderColor": "#3B82F6",
            }
        )
    )

    result = run_helper("--file", str(config), "validate")
    assert result.returncode == 0, result.stdout + result.stderr


def test_schema_exposes_every_semantic_color_and_sidebar_glass_control() -> None:
    schema = json.loads(SCHEMA.read_text())
    properties = schema["properties"]
    colors = properties["appearance"]["properties"]["colors"]["properties"]
    assert set(colors) == {
        "accent",
        "hover",
        "dropTarget",
        "notification",
        "success",
        "warning",
        "error",
        "toolbarIcon",
        "tabIcon",
    }
    sidebar = properties["sidebarAppearance"]["properties"]
    assert {"material", "blendMode", "state", "blurOpacity", "cornerRadius"} <= set(sidebar)
    assert "liquidGlass" in sidebar["material"]["enum"]
