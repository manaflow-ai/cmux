#!/usr/bin/env python3
"""Regression tests for the CLI/socket stress harness."""

from __future__ import annotations

import atexit
import importlib.util
import pathlib
import shutil
import sys
import tempfile

# The fake context's files go in a private folder, never a fixed name in the shared /tmp.
_TEMP_DIR = pathlib.Path(tempfile.mkdtemp(prefix="stress-cli-test-"))
atexit.register(shutil.rmtree, _TEMP_DIR, True)


def load_stress_module():
    script_path = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "stress-cli-socket-api.py"
    spec = importlib.util.spec_from_file_location("stress_cli_socket_api", script_path)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeContext:
    def __init__(self) -> None:
        self.workspace_id = "workspace-current"
        self.pane_id = "pane-stale"
        self.second_pane_id = "pane-second"
        self.surface_id = "surface-current"
        self.second_surface_id = "surface-second"
        self.browser_surface_id = None
        self.markdown_path = _TEMP_DIR / "stress.md"
        self.text_path = _TEMP_DIR / "stress.txt"
        self.temp_dir = _TEMP_DIR
        self.run_id = "test-run"
        self.browser_url = "data:text/html,ok"
        self.ensure_calls = 0

    def ensure_core_surfaces(self) -> None:
        self.ensure_calls += 1
        self.pane_id = "pane-fresh"


def test_focus_pane_cli_case_refreshes_handles_before_building_arguments() -> None:
    stress = load_stress_module()
    ctx = FakeContext()

    cases = stress.build_cli_cases(ctx)
    focus_case = next(case for case in cases if case.name == "focus-pane")

    argv = focus_case.argv_factory(ctx)

    assert ctx.ensure_calls == 1
    assert argv == [
        "focus-pane",
        "--workspace",
        "workspace-current",
        "--pane",
        "pane-fresh",
    ]


def main() -> int:
    try:
        test_focus_pane_cli_case_refreshes_handles_before_building_arguments()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
