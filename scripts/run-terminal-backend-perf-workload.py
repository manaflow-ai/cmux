#!/usr/bin/env python3
"""Run the deterministic PERF-1 terminal-backend workload against one tagged app."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import pathlib
import platform
import plistlib
import re
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Protocol, Sequence


SCHEMA_VERSION = 1
WORKSPACE_COUNT = 100
OUTPUT_TERMINAL_COUNT = 8
MIN_DURATION_SECONDS = 60.0
DEFAULT_WORKLOAD_ID = "terminal-backend-perf1-v1"
DEFAULT_SELECTION_INTERVAL_SECONDS = 0.1
DEFAULT_OUTPUT_LINES_PER_SECOND = 40.0
DEFAULT_WORKLOAD_SEED = 20260718
OUTPUT_LIMIT_GRACE_SECONDS = 120.0
AMBIENT_CMUX_ENV_KEYS = (
    "CMUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_SOCKET_PASSWORD",
    "CMUX_WORKSPACE_ID",
    "CMUX_SURFACE_ID",
    "CMUX_TAB_ID",
    "CMUX_PANEL_ID",
    "CMUXD_UNIX_PATH",
    "CMUX_DEBUG_LOG",
    "CMUX_BUNDLE_ID",
    "CMUX_BUNDLED_CLI_PATH",
)


class WorkloadError(RuntimeError):
    pass


class WorkloadCancelled(WorkloadError):
    pass


class Clock(Protocol):
    def monotonic(self) -> float: ...

    def wait(self, event: threading.Event, timeout: float) -> bool: ...


class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def wait(self, event: threading.Event, timeout: float) -> bool:
        return event.wait(max(0.0, timeout))


class WorkloadCLI(Protocol):
    socket_path: pathlib.Path
    helper_path: pathlib.Path
    exact_cli_path: pathlib.Path

    def validate(self) -> None: ...

    def json(self, args: Sequence[str], timeout: float | None = None) -> dict[str, Any]: ...


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sanitize_path(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "perf"


def sanitize_bundle(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", ".", raw.lower()).strip(".")
    cleaned = re.sub(r"\.+", ".", cleaned)
    return cleaned or "perf"


def workspace_prefix(workload_id: str) -> str:
    slug = sanitize_path(workload_id)
    return f"cmux-perf1-{slug[:40]}"


def expected_workspace_names(workload_id: str) -> list[str]:
    prefix = workspace_prefix(workload_id)
    names = [f"{prefix}-{index:03d}" for index in range(1, WORKSPACE_COUNT + 1)]
    if len(set(names)) != WORKSPACE_COUNT:
        raise WorkloadError("generated PERF-1 workspace names are not unique")
    return names


def json_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkloadError(f"{label} did not return a JSON object")
    return value


def item_handle(item: dict[str, Any], kind: str) -> str | None:
    for key in (f"{kind}_ref", "ref", f"{kind}_id", "id"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    nested = item.get(kind)
    if isinstance(nested, dict):
        return item_handle(nested, kind)
    return None


def item_id(item: dict[str, Any], kind: str) -> str | None:
    for key in (f"{kind}_id", "id"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    nested = item.get(kind)
    if isinstance(nested, dict):
        return item_id(nested, kind)
    return None


def atomic_write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()


def probe(command: Sequence[str], label: str, *, cwd: pathlib.Path | None = None) -> str:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0 or not completed.stdout.strip():
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise WorkloadError(f"could not derive {label}: {detail}")
    return completed.stdout.strip()


def tagged_app_path(tag: str) -> pathlib.Path:
    tag_slug = sanitize_path(tag)
    root = (
        pathlib.Path.home()
        / "Library/Developer/Xcode/DerivedData"
        / f"cmux-{tag_slug}/Build/Products/Debug"
    )
    matches = sorted(root.glob(f"cmux DEV {tag_slug}.app"))
    if len(matches) != 1:
        raise WorkloadError(
            f"expected one tagged app for provenance at {root}, found {len(matches)}"
        )
    return matches[0]


def collect_acceptance_provenance(tag: str, repo_root: pathlib.Path) -> dict[str, Any]:
    app = tagged_app_path(tag)
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise WorkloadError(f"could not read tagged app source identity: {error}") from error
    source_commit = info.get("CMUXSourceCommit")
    source_dirty = info.get("CMUXSourceDirty")
    if not isinstance(source_commit, str) or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        raise WorkloadError("tagged app has no valid CMUXSourceCommit")
    if source_dirty != "NO":
        raise WorkloadError("PERF-1 requires a tagged app built from clean source")
    current_main_commit = probe(
        ["git", "rev-parse", "refs/remotes/origin/main"],
        "current-main commit",
        cwd=repo_root,
    )
    if re.fullmatch(r"[0-9a-f]{40}", current_main_commit) is None:
        raise WorkloadError("origin/main did not resolve to a full commit")
    if platform.system() != "Darwin":
        raise WorkloadError("PERF-1 machine provenance is supported only on macOS")
    hardware_model = probe(["sysctl", "-n", "hw.model"], "hardware model")
    os_build = probe(["sw_vers", "-buildVersion"], "OS build")
    platform_identity = probe(
        ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
        "host identity",
    )
    uuid_match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', platform_identity)
    if uuid_match is None:
        raise WorkloadError("IOPlatformUUID is missing from host identity probe")
    display_raw = probe(
        ["system_profiler", "SPDisplaysDataType", "-json"],
        "display configuration",
    )
    try:
        display_configuration = json.loads(display_raw)
    except json.JSONDecodeError as error:
        raise WorkloadError(f"display configuration is not JSON: {error}") from error
    return {
        "source_commit": source_commit,
        "current_main_commit": current_main_commit,
        "hardware_model": hardware_model,
        "host_identity_sha256": hashlib.sha256(
            uuid_match.group(1).encode("utf-8")
        ).hexdigest(),
        "os_build": os_build,
        "display_configuration_sha256": sha256_json(display_configuration),
        "workload_sha256": sha256_file(pathlib.Path(__file__).resolve()),
    }


@dataclass(frozen=True)
class WorkloadConfig:
    tag: str
    workload_id: str
    duration_seconds: float
    selection_interval_seconds: float
    output_lines_per_second: float
    metadata_path: pathlib.Path
    state_dir: pathlib.Path
    cwd: pathlib.Path
    cli_helper: pathlib.Path
    command_timeout_seconds: float
    startup_timeout_seconds: float
    workload_seed: int
    source_commit: str
    current_main_commit: str
    hardware_model: str
    host_identity_sha256: str
    os_build: str
    display_configuration_sha256: str
    workload_sha256: str
    cleanup_only: bool = False

    @property
    def tag_slug(self) -> str:
        return sanitize_path(self.tag)

    @property
    def stop_path(self) -> pathlib.Path:
        return self.state_dir / "stop"

    @property
    def output_max_lines(self) -> int:
        return max(
            1,
            math.ceil(
                (self.duration_seconds + OUTPUT_LIMIT_GRACE_SECONDS)
                * self.output_lines_per_second
            ),
        )


class TaggedDebugCLI:
    def __init__(self, config: WorkloadConfig):
        self.config = config
        self.helper_path = config.cli_helper.resolve()
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{config.tag_slug}.sock")
        self.exact_cli_path = (
            pathlib.Path.home()
            / "Library"
            / "Developer"
            / "Xcode"
            / "DerivedData"
            / f"cmux-{config.tag_slug}"
            / "Build"
            / "Products"
            / "Debug"
            / f"cmux DEV {config.tag_slug}.app"
            / "Contents"
            / "Resources"
            / "bin"
            / "cmux"
        )

    def validate(self) -> None:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", self.config.tag):
            raise WorkloadError(f"invalid tagged build name: {self.config.tag!r}")
        if not self.helper_path.is_file() or not os.access(self.helper_path, os.X_OK):
            raise WorkloadError(f"tagged CLI helper is not executable: {self.helper_path}")
        try:
            socket_mode = self.socket_path.stat().st_mode
        except FileNotFoundError as error:
            raise WorkloadError(
                f"tagged debug socket is missing: {self.socket_path}; launch tag {self.config.tag!r} first"
            ) from error
        if not stat.S_ISSOCK(socket_mode):
            raise WorkloadError(f"tagged debug socket is not a Unix socket: {self.socket_path}")
        if not self.exact_cli_path.is_file() or not os.access(self.exact_cli_path, os.X_OK):
            raise WorkloadError(f"tagged bundled CLI is not executable: {self.exact_cli_path}")

    def environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        for key in AMBIENT_CMUX_ENV_KEYS:
            environment.pop(key, None)
        environment.update(
            {
                "CMUX_TAG": self.config.tag,
                "CMUX_QUIET": "1",
                "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC": str(
                    max(1, math.ceil(self.config.command_timeout_seconds))
                ),
            }
        )
        return environment

    def json(self, args: Sequence[str], timeout: float | None = None) -> dict[str, Any]:
        command = [
            str(self.helper_path),
            "--json",
            "--id-format",
            "both",
            *args,
        ]
        effective_timeout = timeout or self.config.command_timeout_seconds
        try:
            completed = subprocess.run(
                command,
                cwd=self.config.cwd,
                env=self.environment(),
                text=True,
                capture_output=True,
                timeout=effective_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise WorkloadError(
                f"tagged cmux command timed out after {effective_timeout:.1f}s: {shlex.join(command)}"
            ) from error
        if completed.returncode != 0:
            raise WorkloadError(
                "tagged cmux command failed: "
                f"{shlex.join(command)}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise WorkloadError(
                f"tagged cmux command returned invalid JSON: {shlex.join(command)}\n{completed.stdout}"
            ) from error
        return json_dict(payload, shlex.join(command))


class PerfWorkloadRunner:
    def __init__(
        self,
        config: WorkloadConfig,
        cli: WorkloadCLI | None = None,
        clock: Clock | None = None,
        cancel_event: threading.Event | None = None,
    ):
        self.config = config
        self.cli = cli or TaggedDebugCLI(config)
        self.clock = clock or SystemClock()
        self.cancel_event = cancel_event or threading.Event()
        self.names = expected_workspace_names(config.workload_id)
        self.created_workspaces: list[dict[str, str]] = []
        self.output_terminals: list[dict[str, Any]] = []
        self.window_handle = ""
        self.original_workspace_handle = ""
        self.result: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "status": "initializing",
            "phase": "initializing",
            "workload_id": config.workload_id,
            "tag": config.tag,
            "tag_slug": config.tag_slug,
            "socket_path": str(self.cli.socket_path),
            "cli_helper_path": str(self.cli.helper_path),
            "exact_cli_path": str(self.cli.exact_cli_path),
            "metadata_path": str(config.metadata_path),
            "state_dir": str(config.state_dir),
            "started_at": utc_now(),
            "finished_at": None,
            "configuration": {
                "duration_seconds": config.duration_seconds,
                "workspace_count": WORKSPACE_COUNT,
                "continuous_output_terminal_count": OUTPUT_TERMINAL_COUNT,
                "selection_interval_ms": round(config.selection_interval_seconds * 1000, 3),
                "output_lines_per_second_per_terminal": config.output_lines_per_second,
                "output_max_lines_per_terminal": config.output_max_lines,
                "output_producer_executable": str(pathlib.Path(sys.executable).resolve()),
                "cwd": str(config.cwd),
                "workspace_names": self.names,
            },
            "acceptance_context": {
                "workload_id": config.workload_id,
                "workload_sha256": config.workload_sha256,
                "workload_seed": config.workload_seed,
                "duration_seconds": config.duration_seconds,
                "workspace_count": WORKSPACE_COUNT,
                "continuous_output_terminal_count": OUTPUT_TERMINAL_COUNT,
                "source_commit": config.source_commit,
                "current_main_commit": config.current_main_commit,
                "hardware_model": config.hardware_model,
                "host_identity_sha256": config.host_identity_sha256,
                "os_build": config.os_build,
                "display_configuration_sha256": config.display_configuration_sha256,
            },
            "runtime": {
                "window": None,
                "original_workspace": None,
                "created_workspaces": [],
                "output_terminals": [],
                "selection_count": 0,
                "selection_sequence_sha256": None,
                "measured_duration_seconds": 0.0,
            },
            "cleanup": {
                "attempted": False,
                "stop_file_created": False,
                "closed_workspace_count": 0,
                "restored_original_workspace": False,
                "errors": [],
            },
            "errors": [],
        }
        self._selection_hasher = hashlib.sha256()

    def persist(self) -> None:
        atomic_write_json(self.config.metadata_path, self.result)

    def set_phase(self, phase: str) -> None:
        self.result["phase"] = phase
        self.persist()

    def check_cancelled(self) -> None:
        if self.cancel_event.is_set():
            raise WorkloadCancelled("PERF-1 workload was cancelled")

    def wait_until(self, deadline: float) -> None:
        self.check_cancelled()
        remaining = deadline - self.clock.monotonic()
        if remaining > 0 and self.clock.wait(self.cancel_event, remaining):
            raise WorkloadCancelled("PERF-1 workload was cancelled")
        self.check_cancelled()

    def prepare_target(self) -> None:
        self.cli.validate()
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        identify = self.cli.json(["identify", "--no-caller"])
        focused = json_dict(identify.get("focused"), "identify.focused")
        window = item_handle(focused, "window")
        workspace = item_handle(focused, "workspace")
        if not window or not workspace:
            raise WorkloadError("tagged app identify response has no focused window/workspace")
        self.window_handle = window
        self.original_workspace_handle = workspace
        self.result["runtime"]["window"] = window
        self.result["runtime"]["original_workspace"] = workspace

    def list_workspaces(self) -> list[dict[str, Any]]:
        payload = self.cli.json(
            ["workspace", "list", "--window", self.window_handle]
        )
        raw = payload.get("workspaces")
        if not isinstance(raw, list) or not all(isinstance(item, dict) for item in raw):
            raise WorkloadError("workspace list response has no workspace object array")
        return raw

    def matching_workspaces(self) -> list[dict[str, Any]]:
        expected = set(self.names)
        return [
            item
            for item in self.list_workspaces()
            if isinstance(item.get("title"), str) and item["title"] in expected
        ]

    def reject_stale_fixture(self) -> None:
        stale = self.matching_workspaces()
        if not stale:
            self.config.stop_path.unlink(missing_ok=True)
            return
        stale_names = sorted(str(item.get("title", "")) for item in stale)
        preview = ", ".join(stale_names[:3])
        suffix = "" if len(stale_names) <= 3 else f", and {len(stale_names) - 3} more"
        raise WorkloadError(
            f"tag {self.config.tag!r} already contains {len(stale)} PERF-1 workspaces "
            f"({preview}{suffix}); run this command with --cleanup-only first"
        )

    def create_workspaces(self) -> None:
        for index, name in enumerate(self.names, start=1):
            self.check_cancelled()
            payload = self.cli.json(
                [
                    "workspace",
                    "create",
                    "--window",
                    self.window_handle,
                    "--name",
                    name,
                    "--description",
                    f"{self.config.workload_id} deterministic workspace {index:03d}",
                    "--cwd",
                    str(self.config.cwd),
                    "--focus",
                    "false",
                ]
            )
            handle = item_handle(payload, "workspace")
            if not handle:
                raise WorkloadError(f"workspace create returned no handle for {name}")
            record = {
                "name": name,
                "handle": handle,
                "id": item_id(payload, "workspace") or handle,
            }
            self.created_workspaces.append(record)
            self.result["runtime"]["created_workspaces"] = list(self.created_workspaces)
            self.persist()

        matching = self.matching_workspaces()
        actual_names = [str(item.get("title", "")) for item in matching]
        if len(matching) != WORKSPACE_COUNT or set(actual_names) != set(self.names):
            raise WorkloadError(
                "PERF-1 fixture verification failed: expected exactly 100 uniquely named workspaces, "
                f"found {len(matching)}"
            )

    def surface_for_workspace(self, workspace: str) -> dict[str, str]:
        deadline = self.clock.monotonic() + self.config.startup_timeout_seconds
        while True:
            self.check_cancelled()
            payload = self.cli.json(
                [
                    "list-pane-surfaces",
                    "--window",
                    self.window_handle,
                    "--workspace",
                    workspace,
                ]
            )
            surfaces = payload.get("surfaces")
            if isinstance(surfaces, list):
                for raw in surfaces:
                    if not isinstance(raw, dict):
                        continue
                    surface_type = str(raw.get("type", "terminal")).lower()
                    handle = item_handle(raw, "surface")
                    if handle and surface_type in {"", "terminal"}:
                        return {
                            "handle": handle,
                            "id": item_id(raw, "surface") or handle,
                        }
            if self.clock.monotonic() >= deadline:
                raise WorkloadError(f"workspace {workspace} has no terminal surface")
            self.wait_until(min(deadline, self.clock.monotonic() + 0.05))

    def output_token(self, index: int) -> str:
        workload = sanitize_path(self.config.workload_id).upper().replace("-", "_")[:32]
        return f"CMUX_PERF1_{workload}_{index:02d}"

    def output_command(self, token: str) -> str:
        program = """import os
import sys
import time

stop_path = sys.argv[1]
token = sys.argv[2]
maximum = int(sys.argv[3])
interval = float(sys.argv[4])
payload = "x" * 64
last = 0
reason = "limit"
print(f"{token} STARTED", flush=True)
deadline = time.monotonic()
for sequence in range(1, maximum + 1):
    if os.path.exists(stop_path):
        reason = "stop"
        break
    last = sequence
    print(f"{token} {sequence:08d} {payload}", flush=True)
    deadline += interval
    remaining = deadline - time.monotonic()
    if remaining > 0:
        # This bounds output rate. App readiness is synchronized by CLI replies and markers.
        time.sleep(remaining)
print(f"{token} DONE {reason} {last:08d}", flush=True)
"""
        encoded = base64.b64encode(program.encode("utf-8")).decode("ascii")
        bootstrap = (
            "import base64;"
            f"exec(compile(base64.b64decode({encoded!r}),'<cmux-perf1-output>','exec'))"
        )
        interval = 1.0 / self.config.output_lines_per_second
        arguments = [
            str(pathlib.Path(sys.executable).resolve()),
            "-u",
            "-c",
            bootstrap,
            str(self.config.stop_path),
            token,
            str(self.config.output_max_lines),
            f"{interval:.9f}",
        ]
        return f"{shlex.join(arguments)} &"

    def read_screen(self, workspace: str, surface: str, lines: int = 200) -> str:
        payload = self.cli.json(
            [
                "read-screen",
                "--window",
                self.window_handle,
                "--workspace",
                workspace,
                "--surface",
                surface,
                "--lines",
                str(lines),
            ]
        )
        text = payload.get("text")
        if not isinstance(text, str):
            raise WorkloadError(f"read-screen returned no text for {workspace}/{surface}")
        return text

    def wait_for_output_start(self, record: dict[str, Any]) -> None:
        deadline = self.clock.monotonic() + self.config.startup_timeout_seconds
        marker = f"{record['token']} STARTED"
        while True:
            self.check_cancelled()
            text = self.read_screen(record["workspace"], record["surface"])
            if marker in text:
                record["start_marker_observed"] = True
                return
            if self.clock.monotonic() >= deadline:
                raise WorkloadError(f"output producer did not start: {record['token']}")
            self.wait_until(min(deadline, self.clock.monotonic() + 0.05))

    def start_output(self) -> None:
        if self.config.stop_path.exists():
            raise WorkloadError(f"output stop file unexpectedly exists: {self.config.stop_path}")
        targets = self.created_workspaces[:OUTPUT_TERMINAL_COUNT]
        if len(targets) != OUTPUT_TERMINAL_COUNT:
            raise WorkloadError("cannot start eight output terminals before 100 workspaces exist")
        for index, workspace_record in enumerate(targets, start=1):
            surface = self.surface_for_workspace(workspace_record["handle"])
            token = self.output_token(index)
            record: dict[str, Any] = {
                "index": index,
                "workspace": workspace_record["handle"],
                "workspace_name": workspace_record["name"],
                "surface": surface["handle"],
                "surface_id": surface["id"],
                "token": token,
                "start_marker_observed": False,
                "last_sequence_observed": 0,
            }
            self.cli.json(
                [
                    "send",
                    "--window",
                    self.window_handle,
                    "--workspace",
                    workspace_record["handle"],
                    "--surface",
                    surface["handle"],
                    self.output_command(token) + "\\n",
                ]
            )
            self.output_terminals.append(record)
            self.result["runtime"]["output_terminals"] = list(self.output_terminals)
            self.persist()

        for record in self.output_terminals:
            self.wait_for_output_start(record)
        if len(self.output_terminals) != OUTPUT_TERMINAL_COUNT:
            raise WorkloadError("PERF-1 did not start output in exactly eight terminals")
        self.result["runtime"]["output_terminals"] = list(self.output_terminals)
        self.persist()

    def drive_sidebar_selection(self) -> None:
        selection_start = self.clock.monotonic()
        deadline = selection_start + self.config.duration_seconds
        next_selection_at = selection_start
        selection_count = 0
        workspace_index = self.config.workload_seed % WORKSPACE_COUNT

        while self.clock.monotonic() < deadline or selection_count < WORKSPACE_COUNT:
            self.check_cancelled()
            target = self.created_workspaces[workspace_index]
            self.cli.json(
                [
                    "workspace",
                    "select",
                    "--window",
                    self.window_handle,
                    "--workspace",
                    target["handle"],
                ]
            )
            selection_count += 1
            workspace_index = (workspace_index + 1) % WORKSPACE_COUNT
            self._selection_hasher.update(
                f"{selection_count}:{target['name']}\n".encode("utf-8")
            )
            self.result["runtime"]["selection_count"] = selection_count
            next_selection_at += self.config.selection_interval_seconds
            if next_selection_at > deadline:
                next_selection_at = deadline
            if self.clock.monotonic() < next_selection_at:
                self.wait_until(next_selection_at)

        measured = self.clock.monotonic() - selection_start
        if measured < self.config.duration_seconds:
            raise WorkloadError(
                f"selection workload ran for {measured:.3f}s, shorter than requested "
                f"{self.config.duration_seconds:.3f}s"
            )
        self.result["runtime"]["selection_count"] = selection_count
        self.result["runtime"]["selection_sequence_sha256"] = self._selection_hasher.hexdigest()
        self.result["runtime"]["measured_duration_seconds"] = round(measured, 6)
        self.persist()

    def sample_output_sequences(self) -> None:
        for record in self.output_terminals:
            text = self.read_screen(record["workspace"], record["surface"])
            pattern = re.compile(rf"^{re.escape(record['token'])} (\d{{8}}) ", re.MULTILINE)
            sequences = [int(match.group(1)) for match in pattern.finditer(text)]
            if not sequences:
                raise WorkloadError(
                    f"output terminal produced no numbered lines during measurement: {record['token']}"
                )
            record["last_sequence_observed"] = max(sequences)
        self.result["runtime"]["output_terminals"] = list(self.output_terminals)
        self.persist()

    def stop_outputs(self) -> None:
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        self.config.stop_path.touch(exist_ok=True)
        self.result["cleanup"]["stop_file_created"] = True

    def close_workspace(self, handle: str) -> None:
        self.cli.json(
            [
                "workspace",
                "close",
                "--window",
                self.window_handle,
                "--workspace",
                handle,
            ]
        )

    def cleanup(self, workspaces: list[dict[str, Any]] | None = None) -> None:
        self.result["cleanup"]["attempted"] = True
        errors: list[str] = self.result["cleanup"]["errors"]
        try:
            self.stop_outputs()
        except Exception as error:  # cleanup must continue after one failed action
            errors.append(f"stop output: {error}")

        cleanup_records = workspaces if workspaces is not None else list(self.created_workspaces)
        closed = 0
        for record in reversed(cleanup_records):
            handle = item_handle(record, "workspace") or str(record.get("handle", ""))
            if not handle:
                errors.append(f"workspace cleanup record has no handle: {record!r}")
                continue
            try:
                self.close_workspace(handle)
                closed += 1
            except Exception as error:  # attempt every owned workspace
                errors.append(f"close {handle}: {error}")
        self.result["cleanup"]["closed_workspace_count"] = closed

        if self.original_workspace_handle:
            try:
                self.cli.json(
                    [
                        "workspace",
                        "select",
                        "--window",
                        self.window_handle,
                        "--workspace",
                        self.original_workspace_handle,
                    ]
                )
                self.result["cleanup"]["restored_original_workspace"] = True
            except Exception as error:
                errors.append(f"restore original workspace: {error}")
        self.persist()

    def cleanup_stale_fixture(self) -> int:
        self.set_phase("cleanup-only")
        matches = self.matching_workspaces()
        self.result["runtime"]["created_workspaces"] = [
            {
                "name": str(item.get("title", "")),
                "handle": item_handle(item, "workspace") or "",
                "id": item_id(item, "workspace") or "",
            }
            for item in matches
        ]
        self.cleanup(matches)
        if self.result["cleanup"]["errors"]:
            self.result["status"] = "failed"
            return 1
        self.result["status"] = "cleanup-completed"
        return 0

    def run(self) -> int:
        exit_code = 1
        try:
            self.persist()
            self.prepare_target()
            if self.config.cleanup_only:
                exit_code = self.cleanup_stale_fixture()
                return exit_code

            self.set_phase("preflight")
            self.reject_stale_fixture()
            self.set_phase("creating-workspaces")
            self.create_workspaces()
            self.set_phase("starting-output")
            self.start_output()
            self.result["status"] = "running"
            self.set_phase("selecting-workspaces")
            self.drive_sidebar_selection()
            self.set_phase("sampling-output")
            self.sample_output_sequences()
            self.result["status"] = "completed"
            exit_code = 0
        except WorkloadCancelled as error:
            self.result["status"] = "cancelled"
            self.result["errors"].append(str(error))
            exit_code = 130
        except Exception as error:
            self.result["status"] = "failed"
            self.result["errors"].append(str(error))
            exit_code = 1
        finally:
            if not self.config.cleanup_only:
                self.result["phase"] = "cleanup"
                self.cleanup()
            if self.result["cleanup"]["errors"]:
                self.result["status"] = "failed"
                exit_code = 1
            self.result["phase"] = "finished"
            self.result["finished_at"] = utc_now()
            self.persist()
            print(json.dumps(self.result, sort_keys=True))
        return exit_code


def positive_float(raw: str) -> float:
    value = float(raw)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("value must be a finite number greater than zero")
    return value


def duration_float(raw: str) -> float:
    value = positive_float(raw)
    if value < MIN_DURATION_SECONDS:
        raise argparse.ArgumentTypeError(
            f"PERF-1 duration must be at least {MIN_DURATION_SECONDS:.0f} seconds"
        )
    return value


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description=(
            "Create the fixed PERF-1 topology in one tagged cmux app, run eight bounded output "
            "producers, select its 100 workspaces for at least 60 seconds, and clean up."
        )
    )
    parser.add_argument("--tag", required=True, help="tagged Debug build name")
    parser.add_argument(
        "--workload-id",
        default=DEFAULT_WORKLOAD_ID,
        help="stable comparison identity shared by baseline and feature runs",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_WORKLOAD_SEED,
        help="deterministic selection-sequence seed shared by baseline and feature runs",
    )
    parser.add_argument(
        "--duration-seconds",
        type=duration_float,
        default=MIN_DURATION_SECONDS,
        help="selection duration, minimum 60 seconds",
    )
    parser.add_argument(
        "--selection-interval-ms",
        type=positive_float,
        default=DEFAULT_SELECTION_INTERVAL_SECONDS * 1000,
        help="target interval between sequential workspace selections",
    )
    parser.add_argument(
        "--output-lines-per-second",
        type=positive_float,
        default=DEFAULT_OUTPUT_LINES_PER_SECOND,
        help="bounded output rate for each of exactly eight terminals",
    )
    parser.add_argument(
        "--metadata",
        type=pathlib.Path,
        required=True,
        help="atomic JSON workload metadata path",
    )
    parser.add_argument(
        "--state-dir",
        type=pathlib.Path,
        help="stop-file directory (default: metadata directory plus tag/workload identity)",
    )
    parser.add_argument(
        "--cwd",
        type=pathlib.Path,
        default=pathlib.Path.cwd(),
        help="working directory for all fixture terminals",
    )
    parser.add_argument(
        "--cli-helper",
        type=pathlib.Path,
        default=root / "scripts" / "cmux-debug-cli.sh",
        help="repository tag-bound CLI helper",
    )
    parser.add_argument(
        "--command-timeout-seconds",
        type=positive_float,
        default=30.0,
    )
    parser.add_argument(
        "--startup-timeout-seconds",
        type=positive_float,
        default=30.0,
    )
    parser.add_argument(
        "--cleanup-only",
        action="store_true",
        help="stop and close matching leftovers from an interrupted run without creating a fixture",
    )
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag):
        parser.error("--tag may contain only letters, digits, dot, underscore, and hyphen")
    if not args.workload_id.strip():
        parser.error("--workload-id must not be empty")
    args.metadata = args.metadata.expanduser().resolve()
    args.cwd = args.cwd.expanduser().resolve()
    args.cli_helper = args.cli_helper.expanduser().resolve()
    if args.state_dir is None:
        identity = f"{sanitize_path(args.tag)}-{sanitize_path(args.workload_id)}"
        args.state_dir = args.metadata.parent / f".cmux-perf1-{identity}"
    else:
        args.state_dir = args.state_dir.expanduser().resolve()
    return args


def config_from_args(args: argparse.Namespace) -> WorkloadConfig:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    provenance = collect_acceptance_provenance(args.tag, repo_root)
    return WorkloadConfig(
        tag=args.tag,
        workload_id=args.workload_id,
        duration_seconds=args.duration_seconds,
        selection_interval_seconds=args.selection_interval_ms / 1000.0,
        output_lines_per_second=args.output_lines_per_second,
        metadata_path=args.metadata,
        state_dir=args.state_dir,
        cwd=args.cwd,
        cli_helper=args.cli_helper,
        command_timeout_seconds=args.command_timeout_seconds,
        startup_timeout_seconds=args.startup_timeout_seconds,
        workload_seed=args.seed,
        source_commit=provenance["source_commit"],
        current_main_commit=provenance["current_main_commit"],
        hardware_model=provenance["hardware_model"],
        host_identity_sha256=provenance["host_identity_sha256"],
        os_build=provenance["os_build"],
        display_configuration_sha256=provenance["display_configuration_sha256"],
        workload_sha256=provenance["workload_sha256"],
        cleanup_only=args.cleanup_only,
    )


def main(argv: Sequence[str] | None = None) -> int:
    config = config_from_args(parse_args(argv))
    cancel_event = threading.Event()

    def request_cancel(_signum: int, _frame: Any) -> None:
        cancel_event.set()

    signal.signal(signal.SIGINT, request_cancel)
    signal.signal(signal.SIGTERM, request_cancel)
    runner = PerfWorkloadRunner(config, cancel_event=cancel_event)
    return runner.run()


if __name__ == "__main__":
    sys.exit(main())
