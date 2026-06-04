#!/usr/bin/env python3
"""Regression tests for activation-session fixture workspace identity."""

from __future__ import annotations

import importlib.util
import pathlib
import types
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "perf-activation-session.py"

spec = importlib.util.spec_from_file_location("perf_activation_session", SCRIPT_PATH)
perf_activation_session = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(perf_activation_session)


class RefChurnFixtureRunner(perf_activation_session.CmuxPerfRunner):
    def __init__(self, fixture_root: pathlib.Path):
        self.args = types.SimpleNamespace(
            workspace_count=1,
            heavy_workspace_panes=1,
            other_workspace_panes=1,
            heavy_tabbed_panes=0,
            other_tabbed_panes=0,
        )
        self.fixture_root = fixture_root
        self.heavy_scrollback_surfaces = set()
        self.result = {"fixture": {}}
        self.workspaces = [{"id": "initial-workspace"}]
        self.closed_workspaces: list[str] = []
        self.selected_workspaces: list[str] = []
        self.created_count = 0

    def _workspace_payloads(self) -> list[dict[str, object]]:
        return [
            {"id": workspace["id"], "ref": f"workspace:{index + 1}"}
            for index, workspace in enumerate(self.workspaces)
        ]

    def make_repo(self, index: int) -> pathlib.Path:
        repo = self.fixture_root / f"project-{index:02d}"
        repo.mkdir(parents=True, exist_ok=True)
        return repo

    def rpc(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        del timeout
        params = params or {}
        if method == "workspace.list":
            return {"workspaces": self._workspace_payloads()}
        if method == "workspace.create":
            self.created_count += 1
            title = str(params.get("title", ""))
            workspace_id = "guard-workspace" if title == "perf-guard" else f"perf-workspace-{self.created_count}"
            self.workspaces.append({"id": workspace_id})
            return {
                "workspace_id": workspace_id,
                "workspace_ref": f"workspace:{len(self.workspaces)}",
                "surface_id": f"surface-{self.created_count}",
            }
        raise AssertionError(f"unexpected rpc method: {method}")

    def json_cli(self, args: list[str], timeout: float = 60) -> dict:
        del timeout
        if args == ["list-workspaces"]:
            return {"workspaces": self._workspace_payloads()}
        if args[:1] == ["list-panes"]:
            return {"panes": [{"ref": "pane:1", "surface_refs": ["surface:1"]}]}
        raise AssertionError(f"unexpected json_cli args: {args}")

    def run_cli(
        self,
        args: list[str],
        input_text: str | None = None,
        timeout: float = 60,
        check: bool = True,
        socket_retries: int = 0,
    ) -> str:
        del input_text, timeout, check, socket_retries
        if args[:1] == ["new-workspace"]:
            title = args[args.index("--name") + 1] if "--name" in args else ""
            return f"OK {self.rpc('workspace.create', {'title': title})['workspace_ref']}"
        if args[:1] == ["close-workspace"]:
            handle = args[args.index("--workspace") + 1]
            self.closed_workspaces.append(handle)
            self._remove_workspace(handle)
            return "OK"
        if args[:1] == ["select-workspace"]:
            self.selected_workspaces.append(args[args.index("--workspace") + 1])
            return "OK"
        if args[:1] == ["codex-hook"]:
            return "OK"
        raise AssertionError(f"unexpected run_cli args: {args}")

    def _remove_workspace(self, handle: str) -> None:
        for index, workspace in enumerate(self.workspaces):
            if workspace["id"] == handle:
                del self.workspaces[index]
                return
        if handle.startswith("workspace:"):
            index = int(handle.split(":", 1)[1]) - 1
            if 0 <= index < len(self.workspaces):
                del self.workspaces[index]


def test_activation_fixture_cleanup_uses_stable_workspace_ids(tmp_path: pathlib.Path) -> None:
    runner = RefChurnFixtureRunner(tmp_path)

    runner.create_fixture()

    assert runner.closed_workspaces == ["initial-workspace", "guard-workspace"]
    assert runner.selected_workspaces == ["perf-workspace-2", "perf-workspace-2"]


def test_activation_socket_readiness_uses_worker_ping(tmp_path: pathlib.Path) -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.socket_path = tmp_path / "cmux.sock"
    runner.socket_path.touch()
    runner.proc = types.SimpleNamespace(poll=lambda: None)
    calls: list[list[str]] = []

    def run_cli(
        args: list[str],
        input_text: str | None = None,
        timeout: float = 60,
        check: bool = True,
        socket_retries: int = 0,
    ) -> str:
        del input_text, timeout, check, socket_retries
        calls.append(args)
        if args == ["ping"]:
            return "PONG"
        raise AssertionError(f"unexpected readiness probe: {args!r}")

    runner.run_cli = run_cli

    with mock.patch.object(perf_activation_session.time, "sleep") as sleep:
        assert runner.wait_for_socket(timeout_s=1)

    assert calls == [["ping"]]
    sleep.assert_not_called()
