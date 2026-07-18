#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import threading
from typing import Any, Sequence

import pytest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-terminal-backend-perf-workload.py"
SPEC = importlib.util.spec_from_file_location("terminal_backend_perf_workload", SCRIPT)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def monotonic(self) -> float:
        return self.now

    def wait(self, event: threading.Event, timeout: float) -> bool:
        if event.is_set():
            return True
        self.now += max(0.0, timeout)
        return event.is_set()


class FakeCLI:
    def __init__(self, cancel_event: threading.Event | None = None, cancel_after: int | None = None):
        self.socket_path = pathlib.Path("/tmp/cmux-debug-perf-test.sock")
        self.helper_path = pathlib.Path("/repo/scripts/cmux-debug-cli.sh")
        self.exact_cli_path = pathlib.Path("/tagged/cmux.app/Contents/Resources/bin/cmux")
        self.cancel_event = cancel_event
        self.cancel_after = cancel_after
        self.validated = False
        self.commands: list[list[str]] = []
        self.workspaces: list[dict[str, Any]] = [
            {
                "id": "original-workspace-id",
                "ref": "workspace:1",
                "title": "original",
                "selected": True,
            }
        ]
        self.screens: dict[str, str] = {}
        self.select_count = 0

    def validate(self) -> None:
        self.validated = True

    def add_stale_fixture(self, workload_id: str) -> None:
        for index, name in enumerate(MODULE.expected_workspace_names(workload_id), start=2):
            self.workspaces.append(
                {
                    "id": f"stale-workspace-id-{index:03d}",
                    "ref": f"workspace:{index}",
                    "title": name,
                    "selected": False,
                }
            )

    def json(self, args: Sequence[str], timeout: float | None = None) -> dict[str, Any]:
        del timeout
        command = list(args)
        self.commands.append(command)
        if command[0] == "identify":
            return {
                "focused": {
                    "window_id": "window-id",
                    "window_ref": "window:1",
                    "workspace_id": "original-workspace-id",
                    "workspace_ref": "workspace:1",
                }
            }
        if command[:2] == ["workspace", "list"]:
            return {"workspaces": [dict(item) for item in self.workspaces]}
        if command[:2] == ["workspace", "create"]:
            name = command[command.index("--name") + 1]
            index = len(self.workspaces) + 1
            item = {
                "id": f"workspace-id-{index:03d}",
                "ref": f"workspace:{index}",
                "title": name,
                "selected": False,
            }
            self.workspaces.append(item)
            return {
                "workspace_id": item["id"],
                "workspace_ref": item["ref"],
            }
        if command[0] == "list-pane-surfaces":
            workspace = command[command.index("--workspace") + 1]
            workspace_number = workspace.split(":")[-1]
            return {
                "surfaces": [
                    {
                        "id": f"surface-id-{workspace_number}",
                        "ref": f"surface:{workspace_number}",
                        "type": "terminal",
                    }
                ]
            }
        if command[0] == "send":
            workspace = command[command.index("--workspace") + 1]
            sent = command[-1]
            token = next(part for part in sent.split() if part.startswith("CMUX_PERF1_"))
            self.screens[workspace] = (
                f"{token} STARTED\n"
                f"{token} 00000001 {'x' * 64}\n"
                f"{token} 00000123 {'x' * 64}\n"
            )
            return {"ok": True}
        if command[0] == "read-screen":
            workspace = command[command.index("--workspace") + 1]
            return {"text": self.screens.get(workspace, "")}
        if command[:2] == ["workspace", "select"]:
            self.select_count += 1
            if (
                self.cancel_event is not None
                and self.cancel_after is not None
                and self.select_count >= self.cancel_after
            ):
                self.cancel_event.set()
            return {"ok": True}
        if command[:2] == ["workspace", "close"]:
            workspace = command[command.index("--workspace") + 1]
            self.workspaces = [
                item
                for item in self.workspaces
                if item["id"] != workspace and item["ref"] != workspace
            ]
            return {"ok": True}
        raise AssertionError(f"unexpected fake CLI command: {command!r}")


def make_config(tmp_path: pathlib.Path, *, cleanup_only: bool = False) -> Any:
    return MODULE.WorkloadConfig(
        tag="perf-test",
        workload_id=MODULE.DEFAULT_WORKLOAD_ID,
        duration_seconds=60.0,
        selection_interval_seconds=0.1,
        output_lines_per_second=40.0,
        metadata_path=tmp_path / "metadata.json",
        state_dir=tmp_path / "state",
        cwd=tmp_path,
        cli_helper=ROOT / "scripts" / "cmux-debug-cli.sh",
        command_timeout_seconds=30.0,
        startup_timeout_seconds=30.0,
        workload_seed=17,
        source_commit="a" * 40,
        current_main_commit="b" * 40,
        hardware_model="MacTest1,1",
        host_identity_sha256="c" * 64,
        os_build="25A1",
        display_configuration_sha256="d" * 64,
        workload_sha256="e" * 64,
        cleanup_only=cleanup_only,
    )


def load_metadata(config: Any) -> dict[str, Any]:
    return json.loads(config.metadata_path.read_text(encoding="utf-8"))


def commands_matching(cli: FakeCLI, prefix: list[str]) -> list[list[str]]:
    return [command for command in cli.commands if command[: len(prefix)] == prefix]


def test_complete_workload_has_fixed_topology_output_selection_and_cleanup(
    tmp_path: pathlib.Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = make_config(tmp_path)
    cli = FakeCLI()
    clock = FakeClock()
    runner = MODULE.PerfWorkloadRunner(config, cli=cli, clock=clock)

    assert runner.run() == 0
    stdout_payload = json.loads(capsys.readouterr().out)
    metadata = load_metadata(config)
    assert stdout_payload == metadata
    assert cli.validated is True
    assert metadata["status"] == "completed"
    assert metadata["configuration"]["workspace_count"] == 100
    assert metadata["configuration"]["continuous_output_terminal_count"] == 8
    assert metadata["acceptance_context"] == {
        "workload_id": MODULE.DEFAULT_WORKLOAD_ID,
        "workload_sha256": "e" * 64,
        "workload_seed": 17,
        "duration_seconds": 60.0,
        "workspace_count": 100,
        "continuous_output_terminal_count": 8,
        "source_commit": "a" * 40,
        "current_main_commit": "b" * 40,
        "hardware_model": "MacTest1,1",
        "host_identity_sha256": "c" * 64,
        "os_build": "25A1",
        "display_configuration_sha256": "d" * 64,
    }
    assert len(set(metadata["configuration"]["workspace_names"])) == 100
    assert len(commands_matching(cli, ["workspace", "create"])) == 100
    assert len(commands_matching(cli, ["send"])) == 8
    assert len(metadata["runtime"]["output_terminals"]) == 8
    assert all(
        terminal["start_marker_observed"]
        and terminal["last_sequence_observed"] == 123
        for terminal in metadata["runtime"]["output_terminals"]
    )
    assert metadata["runtime"]["measured_duration_seconds"] >= 60.0
    assert metadata["runtime"]["selection_count"] >= 600
    assert len(metadata["runtime"]["selection_sequence_sha256"]) == 64
    assert metadata["cleanup"]["stop_file_created"] is True
    assert metadata["cleanup"]["closed_workspace_count"] == 100
    assert metadata["cleanup"]["restored_original_workspace"] is True
    assert config.stop_path.exists()
    assert [item["title"] for item in cli.workspaces] == ["original"]

    create_commands = commands_matching(cli, ["workspace", "create"])
    assert all("--window" in command and "window:1" in command for command in create_commands)
    selection_commands = commands_matching(cli, ["workspace", "select"])
    selected_fixture_handles = [
        command[command.index("--workspace") + 1]
        for command in selection_commands[:-1]
    ]
    expected_handles = [f"workspace:{index}" for index in range(2, 102)]
    seed_offset = config.workload_seed % 100
    assert selected_fixture_handles[:100] == (
        expected_handles[seed_offset:] + expected_handles[:seed_offset]
    )


def test_cancellation_stops_output_and_closes_every_created_workspace(
    tmp_path: pathlib.Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = make_config(tmp_path)
    cancel_event = threading.Event()
    cli = FakeCLI(cancel_event=cancel_event, cancel_after=7)
    runner = MODULE.PerfWorkloadRunner(
        config,
        cli=cli,
        clock=FakeClock(),
        cancel_event=cancel_event,
    )

    assert runner.run() == 130
    capsys.readouterr()
    metadata = load_metadata(config)
    assert metadata["status"] == "cancelled"
    assert metadata["runtime"]["selection_count"] == 7
    assert metadata["cleanup"]["closed_workspace_count"] == 100
    assert metadata["cleanup"]["errors"] == []
    assert config.stop_path.exists()
    assert [item["title"] for item in cli.workspaces] == ["original"]


def test_cleanup_only_recovers_all_named_leftovers_without_starting_output(
    tmp_path: pathlib.Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = make_config(tmp_path, cleanup_only=True)
    cli = FakeCLI()
    cli.add_stale_fixture(config.workload_id)
    runner = MODULE.PerfWorkloadRunner(config, cli=cli, clock=FakeClock())

    assert runner.run() == 0
    capsys.readouterr()
    metadata = load_metadata(config)
    assert metadata["status"] == "cleanup-completed"
    assert metadata["cleanup"]["closed_workspace_count"] == 100
    assert commands_matching(cli, ["send"]) == []
    assert [item["title"] for item in cli.workspaces] == ["original"]


def test_normal_run_refuses_stale_fixture_and_does_not_close_unowned_leftovers(
    tmp_path: pathlib.Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config = make_config(tmp_path)
    cli = FakeCLI()
    cli.add_stale_fixture(config.workload_id)
    runner = MODULE.PerfWorkloadRunner(config, cli=cli, clock=FakeClock())

    assert runner.run() == 1
    capsys.readouterr()
    metadata = load_metadata(config)
    assert metadata["status"] == "failed"
    assert "--cleanup-only" in metadata["errors"][0]
    assert metadata["cleanup"]["closed_workspace_count"] == 0
    assert len(cli.workspaces) == 101


def test_tagged_cli_environment_scrubs_every_ambient_target(tmp_path: pathlib.Path, monkeypatch: Any) -> None:
    config = make_config(tmp_path)
    for key in MODULE.AMBIENT_CMUX_ENV_KEYS:
        monkeypatch.setenv(key, f"ambient-{key.lower()}")
    cli = MODULE.TaggedDebugCLI(config)

    environment = cli.environment()
    assert all(key not in environment for key in MODULE.AMBIENT_CMUX_ENV_KEYS)
    assert environment["CMUX_TAG"] == config.tag
    assert cli.socket_path == pathlib.Path("/tmp/cmux-debug-perf-test.sock")
    assert "cmux-perf-test" in str(cli.exact_cli_path)


def test_tagged_cli_invocation_uses_only_helper_tag_and_machine_json(
    tmp_path: pathlib.Path,
    monkeypatch: Any,
) -> None:
    config = make_config(tmp_path)
    cli = MODULE.TaggedDebugCLI(config)
    observed: dict[str, Any] = {}

    def fake_run(command: list[str], **kwargs: Any) -> Any:
        observed["command"] = command
        observed["environment"] = kwargs["env"]
        return subprocess.CompletedProcess(command, 0, '{"focused": {}}\n', "")

    monkeypatch.setattr(MODULE.subprocess, "run", fake_run)
    assert cli.json(["identify", "--no-caller"]) == {"focused": {}}
    assert observed["command"] == [
        str(config.cli_helper.resolve()),
        "--json",
        "--id-format",
        "both",
        "identify",
        "--no-caller",
    ]
    environment = observed["environment"]
    assert environment["CMUX_TAG"] == config.tag
    assert all(key not in environment for key in MODULE.AMBIENT_CMUX_ENV_KEYS)


def test_output_producer_is_rate_and_line_bounded(tmp_path: pathlib.Path) -> None:
    config = MODULE.WorkloadConfig(
        **{
            **make_config(tmp_path).__dict__,
            "duration_seconds": -119.99,
        }
    )
    assert config.output_max_lines == 1
    runner = MODULE.PerfWorkloadRunner(config, cli=FakeCLI(), clock=FakeClock())
    token = runner.output_token(1)
    completed = subprocess.run(
        ["/bin/zsh", "-c", runner.output_command(token) + " wait"],
        text=True,
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert completed.stdout.splitlines() == [
        f"{token} STARTED",
        f"{token} 00000001 {'x' * 64}",
        f"{token} DONE limit 00000001",
    ]


def test_cli_rejects_short_duration_and_invalid_tag(tmp_path: pathlib.Path) -> None:
    with pytest.raises(SystemExit):
        MODULE.parse_args(
            [
                "--tag",
                "perf-test",
                "--metadata",
                str(tmp_path / "metadata.json"),
                "--duration-seconds",
                "59.999",
            ]
        )
    with pytest.raises(SystemExit):
        MODULE.parse_args(
            [
                "--tag",
                "../../ambient",
                "--metadata",
                str(tmp_path / "metadata.json"),
            ]
        )
