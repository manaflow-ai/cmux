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

    def rpc(
        self,
        method: str,
        params: dict | None = None,
        timeout: float = 60,
        socket_retries: int = 0,
    ) -> dict:
        del timeout, socket_retries
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


def test_post_restore_snapshot_uses_transient_socket_retries() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.args = types.SimpleNamespace(snapshot_timeout=120, restore_ready_timeout=20)
    runner.result = {"measurements": {}, "fixture": {}}
    observed_socket_retries: list[int] = []
    readiness_waits: list[tuple[str, tuple[str, ...], float]] = []

    def stop_app() -> None:
        pass

    def launch(label: str) -> float:
        assert label == "restore"
        return 1.0

    def wait_for_debug_log_marker(label: str, markers: tuple[str, ...], timeout_s: float) -> float:
        readiness_waits.append((label, markers, timeout_s))
        return 42.0

    def rpc(
        method: str,
        params: dict | None = None,
        timeout: float = 60,
        socket_retries: int = 0,
    ) -> dict:
        observed_socket_retries.append(socket_retries)
        assert method == "debug.session_snapshot_benchmark"
        assert params == {"include_scrollback": False, "persist": False}
        assert timeout == 120
        return {"shape": {"workspaces": 12, "terminals": 66}}

    runner.stop_app = stop_app
    runner.launch = launch
    runner.wait_for_debug_log_marker = wait_for_debug_log_marker
    runner.rpc = rpc

    runner.benchmark_restore()

    assert readiness_waits == [
        ("restore_main_window_ready", ("mainWindow.visibility.focus reason=createMainWindow",), 20)
    ]
    assert runner.result["measurements"]["restore_main_window_ready_ms"] == 42.0
    assert observed_socket_retries == [3]
    assert runner.result["fixture"]["post_restore_shape"] == {"workspaces": 12, "terminals": 66}


def test_benchmark_defaults_disable_agent_auto_resume() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.bundle_id = "com.cmuxterm.app.debug.perfci"
    runner.result = {"fixture": {}}
    calls: list[list[str]] = []

    def fake_run(args: list[str], **kwargs: object) -> object:
        assert kwargs["stdout"] is perf_activation_session.subprocess.DEVNULL
        assert kwargs["stderr"] is perf_activation_session.subprocess.DEVNULL
        assert kwargs["check"] is False
        calls.append(args)
        return perf_activation_session.subprocess.CompletedProcess(args, 0)

    with mock.patch.object(perf_activation_session.subprocess, "run", side_effect=fake_run):
        runner.configure_benchmark_defaults()
        runner.clear_benchmark_defaults()

    assert calls == [
        [
            "defaults",
            "write",
            "com.cmuxterm.app.debug.perfci",
            "terminal.autoResumeAgentSessions",
            "-bool",
            "false",
        ],
        [
            "defaults",
            "delete",
            "com.cmuxterm.app.debug.perfci",
            "terminal.autoResumeAgentSessions",
        ],
    ]
    assert runner.result["fixture"]["auto_resume_agent_sessions"] is False
