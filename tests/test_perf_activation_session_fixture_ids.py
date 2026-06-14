#!/usr/bin/env python3
"""Regression tests for activation-session fixture workspace identity."""

from __future__ import annotations

import importlib.util
import json
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


def test_activation_fixture_leaves_light_workspace_selected(tmp_path: pathlib.Path) -> None:
    runner = RefChurnFixtureRunner(tmp_path)
    runner.args.workspace_count = 2

    runner.create_fixture()

    assert runner.closed_workspaces == ["initial-workspace", "guard-workspace"]
    assert runner.selected_workspaces == ["perf-workspace-2", "perf-workspace-3"]


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


def test_fixture_pane_creation_focuses_new_panes() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
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
        return "OK"

    def wait_for_pane_count(workspace: str, minimum_count: int, timeout_s: float = 30) -> list[dict]:
        assert workspace == "workspace:7"
        assert minimum_count == 3
        assert timeout_s == 30
        return [{"ref": "pane:1"}, {"ref": "pane:2"}, {"ref": "pane:3"}]

    runner.run_cli = run_cli
    runner.wait_for_pane_count = wait_for_pane_count

    panes = runner.create_pane_and_wait("workspace:7", "up", 3)

    assert calls == [
        [
            "new-pane",
            "--workspace",
            "workspace:7",
            "--type",
            "terminal",
            "--direction",
            "up",
            "--focus",
            "true",
        ]
    ]
    assert panes == [{"ref": "pane:1"}, {"ref": "pane:2"}, {"ref": "pane:3"}]


def test_synthetic_scrollback_only_skips_real_terminal_seed() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.args = types.SimpleNamespace(synthetic_scrollback_only=True)
    runner.result = {"fixture": {}, "measurements": {}}
    calls: list[str] = []

    def record(name: str) -> None:
        calls.append(name)

    def benchmark_snapshot(name: str, include_scrollback: bool) -> dict:
        calls.append(f"snapshot:{name}:{include_scrollback}")
        payload = {"elapsed_ms": 1.0, "shape": {"scrollback_chars": 0}}
        runner.result["measurements"][name] = payload
        return payload

    runner.check_paths = lambda: record("check_paths")
    runner.stop_app = lambda: record("stop_app")
    runner.clean_persisted_state = lambda: record("clean_persisted_state")
    runner.configure_benchmark_defaults = lambda: record("configure_benchmark_defaults")
    runner.clear_benchmark_defaults = lambda: record("clear_benchmark_defaults")
    runner.launch = lambda label: record(f"launch:{label}")
    runner.create_fixture = lambda: [("workspace-1", "surface-1", pathlib.Path("/tmp"))]
    runner.ensure_app_running = lambda label: record(f"ensure:{label}")
    runner.seed_scrollback = lambda terminals: record("seed_scrollback")
    runner.benchmark_snapshot = benchmark_snapshot
    runner.seed_synthetic_scrollback_fallback = lambda real_snapshot: True
    runner.benchmark_restore = lambda: record("benchmark_restore")
    runner.apply_budgets = lambda: record("apply_budgets")
    runner.fixture_root = pathlib.Path("/nonexistent/cmux-perf-fixture")

    runner.run()

    assert "seed_scrollback" not in calls
    assert runner.result["fixture"]["real_scrollback_seed"] == "skipped_synthetic_scrollback_only"
    assert "snapshot:snapshot_no_scrollback:False" in calls
    assert "snapshot:snapshot_with_real_scrollback:True" in calls


def test_post_restore_shape_uses_persisted_session_snapshot() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.args = types.SimpleNamespace(snapshot_timeout=120, restore_ready_timeout=20)
    runner.result = {"measurements": {}, "fixture": {}}
    readiness_waits: list[tuple[str, tuple[str, ...], float]] = []
    observed_snapshot_mtimes: list[int | None] = []

    def stop_app() -> None:
        pass

    def launch(label: str) -> float:
        assert label == "restore"
        return 1.0

    def session_snapshot_mtime_ns() -> int | None:
        return 123

    def wait_for_debug_log_marker(label: str, markers: tuple[str, ...], timeout_s: float) -> float:
        readiness_waits.append((label, markers, timeout_s))
        return 42.0

    def wait_for_restored_session_snapshot(
        previous_mtime_ns: int | None,
        timeout_s: float,
    ) -> dict:
        observed_snapshot_mtimes.append(previous_mtime_ns)
        assert timeout_s == 20
        return {
            "windows": [
                {
                    "tabManager": {
                        "workspaces": [
                            {
                                "panels": [{"terminal": {}}, {"browser": {}}],
                                "statusEntries": [{}, {}],
                                "logEntries": [{}],
                                "progress": {},
                                "gitBranch": {},
                            },
                            {
                                "panels": [{"terminal": {"scrollback": "abc"}, "gitBranch": {}}],
                                "statusEntries": [],
                                "logEntries": [],
                            },
                        ]
                    }
                }
            ]
        }

    runner.stop_app = stop_app
    runner.launch = launch
    runner.session_snapshot_mtime_ns = session_snapshot_mtime_ns
    runner.wait_for_debug_log_marker = wait_for_debug_log_marker
    runner.wait_for_restored_session_snapshot = wait_for_restored_session_snapshot

    runner.benchmark_restore()

    assert readiness_waits == [
        ("restore_main_window_ready", ("mainWindow.visibility.focus reason=createMainWindow",), 20)
    ]
    assert runner.result["measurements"]["restore_main_window_ready_ms"] == 42.0
    assert observed_snapshot_mtimes == [123]
    assert runner.result["fixture"]["post_restore_snapshot_source"] == "session_persistence_store"
    assert runner.result["fixture"]["post_restore_shape"] == {
        "windows": 1,
        "workspaces": 2,
        "panels": 3,
        "terminals": 2,
        "browsers": 1,
        "markdown": 0,
        "scrollback_chars": 3,
        "status_entries": 2,
        "log_entries": 1,
        "progress_entries": 1,
        "git_entries": 2,
    }


def test_restored_session_snapshot_accepts_complete_idempotent_save(tmp_path: pathlib.Path) -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.args = types.SimpleNamespace(workspace_count=2, budget_min_terminal_surfaces=2)
    runner.result = {"measurements": {}, "fixture": {}}
    runner.session_snapshot_path = tmp_path / "session.json"
    snapshot = {
        "windows": [
            {
                "tabManager": {
                    "workspaces": [
                        {"panels": [{"terminal": {}}, {"browser": {}}]},
                        {"panels": [{"terminal": {}}]},
                    ]
                }
            }
        ]
    }
    runner.session_snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
    previous_mtime_ns = runner.session_snapshot_mtime_ns()

    with mock.patch.object(perf_activation_session.time, "sleep") as sleep:
        restored_snapshot = runner.wait_for_restored_session_snapshot(
            previous_mtime_ns=previous_mtime_ns,
            timeout_s=5,
        )

    assert restored_snapshot == snapshot
    assert runner.result["fixture"]["restore_snapshot_file_reason"] == "shape_satisfied"
    assert runner.result["measurements"]["restore_snapshot_file_wait_ms"] >= 0
    sleep.assert_not_called()


def test_session_snapshot_path_uses_swift_safe_bundle_id() -> None:
    runner = object.__new__(perf_activation_session.CmuxPerfRunner)
    runner.bundle_id = "com.cmuxterm.app.debug.perf ci!"

    assert runner.default_session_snapshot_path().name == "session-com.cmuxterm.app.debug.perf_ci_.json"


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
