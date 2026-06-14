#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


def sanitize_bundle(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", ".", raw.lower()).strip(".")
    cleaned = re.sub(r"\.+", ".", cleaned)
    return cleaned or "perf"


def sanitize_path(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "perf"


def now_ms() -> float:
    return time.perf_counter() * 1000.0


def rounded_ms(value: float) -> float:
    return round(value, 2)


def file_tail(path: pathlib.Path, max_bytes: int = 80_000) -> str:
    if not path.exists():
        return ""
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > max_bytes:
                handle.seek(size - max_bytes)
            data = handle.read(max_bytes)
        return data.decode("utf-8", errors="replace")
    except OSError as exc:
        return f"<failed to read {path}: {exc}>"


class PerfFailure(RuntimeError):
    pass


SOCKET_UNAVAILABLE_ERRORS = (
    "Connection refused",
    "Failed to connect to socket",
)

TRANSIENT_SOCKET_ERRORS = SOCKET_UNAVAILABLE_ERRORS + (
    "Socket closed before reply",
    "Socket closed before complete reply",
)
AUTO_RESUME_AGENT_SESSIONS_KEY = "terminal.autoResumeAgentSessions"


def has_socket_error(stderr: str, needles: tuple[str, ...]) -> bool:
    return any(needle in stderr for needle in needles)


class CmuxPerfRunner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.tag = args.tag
        self.tag_slug = sanitize_path(args.tag)
        self.tag_id = sanitize_bundle(args.tag)
        self.bundle_id = f"com.cmuxterm.app.debug.{self.tag_id}"
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.sock")
        self.cmuxd_socket_path = pathlib.Path(
            os.path.expanduser(f"~/Library/Application Support/cmux/cmuxd-dev-{self.tag_slug}.sock")
        )
        self.debug_log_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.log")
        self.stdout_path = pathlib.Path(f"/tmp/cmux-perf-{self.tag_slug}-stdout.log")
        self.app_path = pathlib.Path(args.app_path).expanduser() if args.app_path else self.default_app_path()
        self.binary_path = self.app_path / "Contents/MacOS/cmux DEV"
        self.cli_path = self.app_path / "Contents/Resources/bin/cmux"
        self.session_snapshot_path = self.default_session_snapshot_path()
        self.fixture_root = self.make_fixture_root(args.fixture_root)
        self.proc: subprocess.Popen | None = None
        self.app_returncode: int | None = None
        self.last_launch_debug_log_offset = 0
        self.heavy_scrollback_surfaces: set[str] = set()
        self.result: dict = {
            "tag": self.tag,
            "app_path": str(self.app_path),
            "socket_path": str(self.socket_path),
            "session_snapshot_path": str(self.session_snapshot_path),
            "fixture_root": str(self.fixture_root),
            "measurements": {},
            "fixture": {},
            "budgets": {},
            "failures": [],
        }

    def make_fixture_root(self, fixture_root_arg: str) -> pathlib.Path:
        if fixture_root_arg:
            fixture_parent = pathlib.Path(fixture_root_arg).expanduser()
            fixture_parent.mkdir(parents=True, exist_ok=True)
            return pathlib.Path(tempfile.mkdtemp(prefix=f"cmux-perf-{self.tag_slug}-", dir=str(fixture_parent)))
        return pathlib.Path(tempfile.mkdtemp(prefix=f"cmux-perf-{self.tag_slug}-"))

    def default_app_path(self) -> pathlib.Path:
        return pathlib.Path.home() / (
            f"Library/Developer/Xcode/DerivedData/cmux-{self.tag_slug}/"
            f"Build/Products/Debug/cmux DEV {self.tag_slug}.app"
        )

    def default_session_snapshot_path(self) -> pathlib.Path:
        safe_bundle_id = re.sub(r"[^A-Za-z0-9._-]", "_", self.bundle_id)
        return (
            pathlib.Path.home()
            / "Library/Application Support/cmux"
            / f"session-{safe_bundle_id}.json"
        )

    def check_paths(self) -> None:
        if not self.binary_path.exists():
            raise PerfFailure(f"app binary not found: {self.binary_path}")
        if not self.cli_path.exists():
            raise PerfFailure(f"cmux CLI not found: {self.cli_path}")

    def clean_persisted_state(self) -> None:
        for suffix in ("", "-previous"):
            path = self.session_snapshot_path.with_name(
                f"{self.session_snapshot_path.stem}{suffix}{self.session_snapshot_path.suffix}"
            )
            path.unlink(missing_ok=True)
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)
        self.debug_log_path.unlink(missing_ok=True)
        self.stdout_path.unlink(missing_ok=True)
        self.clear_benchmark_defaults()
        if self.fixture_root.exists():
            shutil.rmtree(self.fixture_root)
        self.fixture_root.mkdir(parents=True, exist_ok=True)

    def run_defaults(self, args: list[str]) -> None:
        subprocess.run(
            ["defaults", *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    def clear_benchmark_defaults(self) -> None:
        self.run_defaults(["delete", self.bundle_id, AUTO_RESUME_AGENT_SESSIONS_KEY])

    def configure_benchmark_defaults(self) -> None:
        self.run_defaults(["write", self.bundle_id, AUTO_RESUME_AGENT_SESSIONS_KEY, "-bool", "false"])
        self.result["fixture"]["auto_resume_agent_sessions"] = False

    def app_env(self) -> dict[str, str]:
        env = os.environ.copy()
        for key in (
            "CMUX_SOCKET",
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET_MODE",
            "CMUX_TAB_ID",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            "CMUXD_UNIX_PATH",
            "CMUX_TAG",
            "CMUX_PORT",
            "CMUX_PORT_END",
            "CMUX_PORT_RANGE",
            "CMUX_DEBUG_LOG",
            "CMUX_BUNDLE_ID",
            "CMUX_UI_TEST_MODE",
            "CMUX_SHELL_INTEGRATION",
            "CMUX_SHELL_INTEGRATION_DIR",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION",
            "GHOSTTY_BIN_DIR",
            "GHOSTTY_RESOURCES_DIR",
            "GHOSTTY_SHELL_FEATURES",
        ):
            env.pop(key, None)
        env.update(
            {
                "CMUX_SOCKET": str(self.socket_path),
                "CMUX_SOCKET_MODE": "automation",
                "CMUX_SOCKET_PATH": str(self.socket_path),
                "CMUXD_UNIX_PATH": str(self.cmuxd_socket_path),
                "CMUX_DEBUG_LOG": str(self.debug_log_path),
                "CMUX_TAG": self.tag,
                "CMUX_BUNDLE_ID": self.bundle_id,
            }
        )
        return env

    def cli_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["CMUX_SOCKET"] = str(self.socket_path)
        env["CMUX_SOCKET_PATH"] = str(self.socket_path)
        env["CMUX_TAG"] = self.tag
        env["CMUX_BUNDLE_ID"] = self.bundle_id
        env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = str(max(15, int(self.args.snapshot_timeout)))
        return env

    def launch(self, label: str) -> float:
        self.socket_path.unlink(missing_ok=True)
        self.last_launch_debug_log_offset = self.debug_log_size()
        stdout = open(self.stdout_path, "ab", buffering=0)
        start = now_ms()
        self.proc = subprocess.Popen(
            [str(self.binary_path)],
            env=self.app_env(),
            stdout=stdout,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        stdout.close()
        ready = self.wait_for_socket(timeout_s=self.args.launch_timeout)
        elapsed = rounded_ms(now_ms() - start)
        if not ready:
            raise PerfFailure(f"{label}: socket not ready after {self.args.launch_timeout}s")
        self.result["measurements"][f"{label}_socket_ready_ms"] = elapsed
        return elapsed

    def wait_for_socket(self, timeout_s: float) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if self.proc and self.proc.poll() is not None:
                return False
            if self.socket_path.exists():
                try:
                    self.run_cli(["ping"], timeout=2, socket_retries=0)
                    return True
                except Exception:
                    pass
            if not self.wait_before_retry(deadline, 0.1, "wait_for_socket", fail_on_exit=False):
                return False
        return False

    def wait_before_retry(
        self,
        deadline: float,
        max_wait_s: float,
        label: str,
        fail_on_exit: bool = True,
    ) -> bool:
        remaining_s = deadline - time.monotonic()
        if remaining_s <= 0:
            return False

        proc = self.proc
        if proc is None:
            if fail_on_exit:
                raise PerfFailure(f"{label}: app process is not running")
            return False

        # Wait on the app process so an early crash wakes retries immediately.
        try:
            proc.wait(timeout=min(max_wait_s, remaining_s))
        except subprocess.TimeoutExpired:
            return True

        self.app_returncode = proc.poll()
        if fail_on_exit:
            raise PerfFailure(f"{label}: app exited with code {self.app_returncode}")
        return False

    def debug_log_size(self) -> int:
        try:
            return self.debug_log_path.stat().st_size
        except OSError:
            return 0

    def wait_for_debug_log_marker(
        self,
        label: str,
        markers: tuple[str, ...],
        timeout_s: float,
    ) -> float:
        start = now_ms()
        start_offset = self.last_launch_debug_log_offset
        deadline = time.monotonic() + timeout_s
        last_tail = ""
        last_error = ""
        while time.monotonic() < deadline:
            self.ensure_app_running(f"wait_for_{label}")
            try:
                if self.debug_log_path.exists():
                    size = self.debug_log_size()
                    offset = start_offset if start_offset <= size else 0
                    with self.debug_log_path.open("rb") as handle:
                        handle.seek(offset)
                        text = handle.read().decode("utf-8", errors="replace")
                    if any(marker in text for marker in markers):
                        return rounded_ms(now_ms() - start)
                    last_tail = text[-4000:]
            except OSError as exc:
                last_error = str(exc)
            if not self.wait_before_retry(deadline, 0.1, f"wait_for_{label}"):
                break

        failures = self.result["fixture"].setdefault("debug_log_wait_failures", [])
        if len(failures) < 10:
            failures.append(
                {
                    "label": label,
                    "markers": list(markers),
                    "timeout_s": timeout_s,
                    "last_error": last_error,
                    "tail": last_tail,
                }
            )
        raise PerfFailure(f"{label}: debug log marker not found after {timeout_s}s")

    def session_snapshot_mtime_ns(self) -> int | None:
        try:
            return self.session_snapshot_path.stat().st_mtime_ns
        except OSError:
            return None

    def read_session_snapshot(self) -> dict:
        with self.session_snapshot_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    def restored_session_snapshot_is_complete(self, snapshot: dict) -> tuple[bool, dict[str, int]]:
        shape = self.session_snapshot_shape(snapshot)
        return (
            shape["workspaces"] >= self.args.workspace_count
            and shape["terminals"] >= self.args.budget_min_terminal_surfaces,
            shape,
        )

    def wait_for_restored_session_snapshot(
        self,
        previous_mtime_ns: int | None,
        timeout_s: float,
    ) -> dict:
        start = now_ms()
        deadline = time.monotonic() + timeout_s
        last_error = ""
        last_shape: dict[str, int] | None = None

        while time.monotonic() < deadline:
            current_mtime_ns = self.session_snapshot_mtime_ns()
            if current_mtime_ns is not None:
                try:
                    snapshot = self.read_session_snapshot()
                    shape_satisfied, last_shape = self.restored_session_snapshot_is_complete(snapshot)
                    mtime_changed = current_mtime_ns != previous_mtime_ns
                    if mtime_changed or shape_satisfied:
                        self.result["measurements"]["restore_snapshot_file_wait_ms"] = rounded_ms(
                            now_ms() - start
                        )
                        self.result["fixture"]["restore_snapshot_file_reason"] = (
                            "mtime_changed" if mtime_changed else "shape_satisfied"
                        )
                        return snapshot
                except (OSError, json.JSONDecodeError) as exc:
                    last_error = str(exc)
            if not self.wait_before_retry(deadline, 0.1, "restore_session_snapshot_file"):
                break

        self.result["fixture"]["restore_snapshot_file_failure"] = {
            "path": str(self.session_snapshot_path),
            "previous_mtime_ns": previous_mtime_ns,
            "current_mtime_ns": self.session_snapshot_mtime_ns(),
            "last_error": last_error,
            "last_shape": last_shape,
            "timeout_s": timeout_s,
        }
        raise PerfFailure(f"restore_session_snapshot_file: not updated after {timeout_s}s")

    @staticmethod
    def session_snapshot_shape(snapshot: dict) -> dict[str, int]:
        shape = {
            "windows": 0,
            "workspaces": 0,
            "panels": 0,
            "terminals": 0,
            "browsers": 0,
            "markdown": 0,
            "scrollback_chars": 0,
            "status_entries": 0,
            "log_entries": 0,
            "progress_entries": 0,
            "git_entries": 0,
        }

        windows = snapshot.get("windows")
        if not isinstance(windows, list):
            return shape

        shape["windows"] = len(windows)
        for window in windows:
            if not isinstance(window, dict):
                continue
            tab_manager = window.get("tabManager")
            if not isinstance(tab_manager, dict):
                continue
            workspaces = tab_manager.get("workspaces")
            if not isinstance(workspaces, list):
                continue

            shape["workspaces"] += len(workspaces)
            for workspace in workspaces:
                if not isinstance(workspace, dict):
                    continue
                status_entries = workspace.get("statusEntries")
                if isinstance(status_entries, list):
                    shape["status_entries"] += len(status_entries)
                log_entries = workspace.get("logEntries")
                if isinstance(log_entries, list):
                    shape["log_entries"] += len(log_entries)
                if workspace.get("progress") is not None:
                    shape["progress_entries"] += 1
                if workspace.get("gitBranch") is not None:
                    shape["git_entries"] += 1

                panels = workspace.get("panels")
                if not isinstance(panels, list):
                    continue
                shape["panels"] += len(panels)
                for panel in panels:
                    if not isinstance(panel, dict):
                        continue
                    terminal = panel.get("terminal")
                    if terminal is not None:
                        shape["terminals"] += 1
                        if isinstance(terminal, dict):
                            scrollback = terminal.get("scrollback")
                            if isinstance(scrollback, str):
                                shape["scrollback_chars"] += len(scrollback)
                    if panel.get("browser") is not None:
                        shape["browsers"] += 1
                    if panel.get("markdown") is not None:
                        shape["markdown"] += 1
                    if panel.get("gitBranch") is not None:
                        shape["git_entries"] += 1

        return shape

    def stop_app(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is not None:
            self.app_returncode = proc.poll()
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        if proc is not None:
            self.app_returncode = proc.poll()
        subprocess.run(
            ["pkill", "-f", re.escape(f"cmux DEV {self.tag_slug}.app/Contents/MacOS/cmux DEV")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)

    def ensure_app_running(self, label: str) -> None:
        if self.proc is None:
            raise PerfFailure(f"{label}: app process is not running")
        returncode = self.proc.poll()
        if returncode is not None:
            self.app_returncode = returncode
            raise PerfFailure(f"{label}: app exited with code {returncode}")

    def record_unchecked_cli_failure(self, args: list[str], proc: subprocess.CompletedProcess[str]) -> None:
        failures = self.result["fixture"].setdefault("unchecked_cli_failures", [])
        if len(failures) >= 20:
            return
        failures.append(
            {
                "args": args,
                "returncode": proc.returncode,
                "stdout_tail": proc.stdout[-2000:],
                "stderr_tail": proc.stderr[-2000:],
            }
        )

    def attach_failure_diagnostics(self) -> None:
        diagnostics = self.result.setdefault("diagnostics", {})
        if self.proc is not None:
            self.app_returncode = self.proc.poll()
        diagnostics["app_returncode"] = self.app_returncode
        diagnostics["stdout_log_path"] = str(self.stdout_path)
        diagnostics["debug_log_path"] = str(self.debug_log_path)
        diagnostics["stdout_tail"] = file_tail(self.stdout_path)
        diagnostics["debug_log_tail"] = file_tail(self.debug_log_path)

    def write_diagnostic_files(self, output_dir: pathlib.Path) -> None:
        output_dir.mkdir(parents=True, exist_ok=True)
        run_output_dir = output_dir / f"{self.tag_slug}-{time.time_ns()}"
        run_output_dir.mkdir(parents=True, exist_ok=True)
        copied_log_paths = {}
        for source, key, name in (
            (self.stdout_path, "stdout", "cmux-perf-stdout.log"),
            (self.debug_log_path, "debug", "cmux-debug.log"),
        ):
            if source.exists():
                target = run_output_dir / name
                shutil.copyfile(source, target)
                copied_log_paths[key] = str(target)
        if copied_log_paths:
            self.result.setdefault("diagnostics", {})["copied_log_paths"] = copied_log_paths

    def record_socket_retry(self, args: list[str], proc: subprocess.CompletedProcess[str], attempt: int) -> None:
        retries = self.result["fixture"].setdefault("socket_retry_attempts", [])
        if len(retries) >= 20:
            return
        retries.append(
            {
                "args": args,
                "attempt": attempt,
                "returncode": proc.returncode,
                "stdout_tail": proc.stdout[-1000:],
                "stderr_tail": proc.stderr[-1000:],
            }
        )

    def record_socket_retry_error(self, args: list[str], error: Exception, attempt: int) -> None:
        retries = self.result["fixture"].setdefault("socket_retry_attempts", [])
        if len(retries) >= 20:
            return
        retries.append(
            {
                "args": args,
                "attempt": attempt,
                "error_tail": str(error)[-1000:],
            }
        )

    def run_cli(
        self,
        args: list[str],
        input_text: str | None = None,
        timeout: float = 60,
        check: bool = True,
        socket_retries: int = 0,
    ) -> str:
        last_proc: subprocess.CompletedProcess[str] | None = None
        for attempt in range(socket_retries + 1):
            proc = subprocess.run(
                [str(self.cli_path), *args],
                input=input_text,
                text=True,
                capture_output=True,
                env=self.cli_env(),
                timeout=timeout,
                check=False,
            )
            if proc.returncode == 0:
                return proc.stdout.strip()

            last_proc = proc
            if not check:
                self.record_unchecked_cli_failure(args, proc)
                if has_socket_error(proc.stderr, SOCKET_UNAVAILABLE_ERRORS):
                    raise PerfFailure(
                        "cmux command failed while socket was unavailable: "
                        + " ".join(args)
                        + f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
                    )
                return proc.stdout.strip()

            if attempt < socket_retries and has_socket_error(proc.stderr, TRANSIENT_SOCKET_ERRORS):
                self.record_socket_retry(args, proc, attempt + 1)
                self.ensure_app_running("socket retry " + " ".join(args))
                if self.wait_for_socket(timeout_s=10):
                    continue
                break

        if last_proc is not None:
            raise PerfFailure(
                "cmux command failed: "
                + " ".join(args)
                + f"\nstdout:\n{last_proc.stdout}\nstderr:\n{last_proc.stderr}"
            )
        raise PerfFailure("cmux command was not attempted: " + " ".join(args))

    def json_cli(self, args: list[str], timeout: float = 60) -> dict:
        out = self.run_cli(["--json"] + args, timeout=timeout)
        return json.loads(out)

    def rpc(
        self,
        method: str,
        params: dict | None = None,
        timeout: float = 60,
        socket_retries: int = 0,
    ) -> dict:
        raw_params = json.dumps(params or {})
        out = self.run_cli(["rpc", method, raw_params], timeout=timeout, socket_retries=socket_retries)
        return json.loads(out)

    def require_string_field(self, payload: dict, key: str, context: str) -> str:
        value = payload.get(key)
        if not isinstance(value, str) or not value.strip():
            raise PerfFailure(f"{context} missing {key}: {payload!r}")
        return value

    def workspace_ids(self) -> list[str]:
        payload = self.rpc("workspace.list")
        workspaces = payload.get("workspaces")
        if not isinstance(workspaces, list):
            raise PerfFailure(f"workspace.list returned invalid workspaces: {payload!r}")

        ids: list[str] = []
        for index, workspace in enumerate(workspaces):
            if not isinstance(workspace, dict):
                raise PerfFailure(f"workspace.list item {index} is invalid: {workspace!r}")
            ids.append(self.require_string_field(workspace, "id", f"workspace.list item {index}"))
        return ids

    def create_workspace(self, title: str, cwd: pathlib.Path, description: str | None = None) -> str:
        params: dict[str, object] = {
            "title": title,
            "cwd": str(cwd),
        }
        if description is not None:
            params["description"] = description
        payload = self.rpc("workspace.create", params, timeout=90)
        return self.require_string_field(payload, "workspace_id", f"workspace.create {title!r}")

    def pane_snapshots(self, workspace: str) -> list[dict]:
        panes = self.json_cli(["list-panes", "--workspace", workspace], timeout=90).get("panes", [])
        if not isinstance(panes, list):
            raise PerfFailure(f"list-panes returned invalid panes for {workspace}: {panes!r}")
        return panes

    def wait_for_pane_count(self, workspace: str, minimum_count: int, timeout_s: float = 30) -> list[dict]:
        deadline = time.monotonic() + timeout_s
        last_count: int | None = None
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            self.ensure_app_running(f"wait_for_pane_count {workspace}")
            try:
                panes = self.pane_snapshots(workspace)
            except Exception as exc:
                last_error = exc
            else:
                last_count = len(panes)
                if last_count >= minimum_count:
                    return panes
            if not self.wait_before_retry(deadline, 0.1, f"wait_for_pane_count {workspace}"):
                break
        detail = f"last_count={last_count}"
        if last_error is not None:
            detail += f" last_error={last_error}"
        raise PerfFailure(f"workspace {workspace} did not reach {minimum_count} panes ({detail})")

    def create_pane_and_wait(self, workspace: str, direction: str, expected_pane_count: int) -> list[dict]:
        args = [
            "new-pane",
            "--workspace",
            workspace,
            "--type",
            "terminal",
            "--direction",
            direction,
        ]
        for attempt in range(3):
            try:
                self.run_cli(args, timeout=90)
            except PerfFailure as exc:
                if not has_socket_error(str(exc), TRANSIENT_SOCKET_ERRORS) or attempt == 2:
                    raise
                self.record_socket_retry_error(args, exc, attempt + 1)
                self.ensure_app_running("socket retry " + " ".join(args))
                try:
                    return self.wait_for_pane_count(workspace, expected_pane_count, timeout_s=10)
                except PerfFailure:
                    if not self.wait_for_socket(timeout_s=10):
                        raise
                    continue
            return self.wait_for_pane_count(workspace, expected_pane_count)
        raise PerfFailure(f"workspace {workspace} did not create pane {expected_pane_count}")

    def report_shell_prompt(self, workspace: str, surface: str) -> bool:
        try:
            self.rpc(
                "surface.report_shell_state",
                {
                    "workspace_id": workspace,
                    "surface_id": surface,
                    "state": "prompt",
                },
                timeout=20,
            )
            return True
        except Exception as exc:
            failures = self.result["fixture"].setdefault("scrollback_prompt_report_failures", [])
            if len(failures) < 10:
                failures.append({"surface": surface, "error": str(exc)})
            return False

    def ref(self, text: str, kind: str) -> str:
        found = re.findall(rf"\b{kind}:\d+\b", text)
        if not found:
            raise PerfFailure(f"missing {kind} ref in {text!r}")
        return found[0]

    def make_repo(self, index: int) -> pathlib.Path:
        repo = self.fixture_root / f"project-{index:02d}"
        repo.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        (repo / "README.md").write_text(f"# Project {index}\n\ncmux perf fixture\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=repo, stdout=subprocess.DEVNULL, check=True)
        subprocess.run(
            ["git", "-c", "user.name=cmux", "-c", "user.email=cmux@example.invalid", "commit", "-m", "seed"],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        (repo / "README.md").write_text(f"# Project {index}\n\nmodified\n", encoding="utf-8")
        (repo / f"untracked-{index:02d}.txt").write_text("scratch\n" * 20, encoding="utf-8")
        return repo

    def create_fixture(self) -> list[tuple[str, str, pathlib.Path]]:
        existing = self.workspace_ids()
        guard_ws = self.create_workspace("perf-guard", self.fixture_root)

        terminals: list[tuple[str, str, pathlib.Path]] = []
        workspaces: list[str] = []
        selected_fixture_workspace = False
        for i in range(1, self.args.workspace_count + 1):
            cwd = self.make_repo(i)
            ws = self.create_workspace(
                f"perf-{i:02d}-dirty-agent",
                cwd,
                description=f"activation perf fixture {i:02d}",
            )
            workspaces.append(ws)
            if not selected_fixture_workspace:
                # Keep teardown of bootstrap workspaces out of the measured activation path.
                self.run_cli(["select-workspace", "--workspace", ws], timeout=60)
                selected_fixture_workspace = True
            pane_target = self.args.heavy_workspace_panes if i == 1 else self.args.other_workspace_panes
            directions = ["right", "down", "left", "up"]
            panes = self.pane_snapshots(ws)
            for n in range(max(0, pane_target - 1)):
                expected_pane_count = len(panes) + 1
                panes = self.create_pane_and_wait(ws, directions[n % len(directions)], expected_pane_count)

            tabbed_panes = panes[: self.args.heavy_tabbed_panes if i == 1 else self.args.other_tabbed_panes]
            for pane in tabbed_panes:
                self.run_cli(
                    ["new-surface", "--workspace", ws, "--pane", pane["ref"], "--type", "terminal"],
                    timeout=90,
                )

            panes = self.pane_snapshots(ws)
            surfaces: list[str] = []
            for pane in panes:
                surfaces.extend(pane.get("surface_refs", []))
            if i == 1:
                self.heavy_scrollback_surfaces = set(surfaces)
            terminals.extend((ws, surface, cwd) for surface in surfaces)

            if surfaces:
                hook_input = json.dumps({"session_id": f"codex-perf-{i:02d}", "cwd": str(cwd)})
                self.run_cli(
                    ["codex-hook", "session-start", "--workspace", ws, "--surface", surfaces[0]],
                    input_text=hook_input,
                    timeout=30,
                    check=False,
                )
                self.run_cli(
                    ["codex-hook", "prompt-submit", "--workspace", ws, "--surface", surfaces[0]],
                    input_text=hook_input,
                    timeout=30,
                    check=False,
                )

        for ws in existing + [guard_ws]:
            self.run_cli(["close-workspace", "--workspace", ws], timeout=30, check=False)
        if workspaces:
            self.run_cli(["select-workspace", "--workspace", workspaces[0]], timeout=60, check=False)

        self.result["fixture"].update(
            {
                "workspaces": len(workspaces),
                "terminal_surfaces": len(terminals),
                "heavy_workspace_panes": self.args.heavy_workspace_panes,
                "other_workspace_panes": self.args.other_workspace_panes,
            }
        )
        return terminals

    def seed_scrollback(self, terminals: list[tuple[str, str, pathlib.Path]]) -> None:
        pending: dict[str, tuple[str, str]] = {}
        for idx, (ws, surface, _cwd) in enumerate(terminals, 1):
            self.ensure_app_running("seed_scrollback.send")
            lines = (
                self.args.heavy_scrollback_lines
                if surface in self.heavy_scrollback_surfaces
                else self.args.other_scrollback_lines
            )
            token = f"PERF_{idx:03d}"
            payload = "x" * self.args.line_payload_chars
            command = (
                f"i=1; while [ $i -le {lines} ]; do "
                f"printf '{token} %04d {payload}\\n' \"$i\"; "
                "i=$((i+1)); done; "
                f"echo DONE_{token}\n"
            )
            self.run_cli(["send", "--workspace", ws, "--surface", surface, command], timeout=30, check=False)
            pending[surface] = (ws, f"DONE_{token}")

        prompt_reports = 0
        poll_failures: list[dict[str, str]] = []
        deadline = time.monotonic() + self.args.scrollback_timeout
        while pending and time.monotonic() < deadline:
            self.ensure_app_running("seed_scrollback.poll")
            done: list[tuple[str, str]] = []
            for surface, (ws, token) in list(pending.items()):
                try:
                    out = self.run_cli(
                        ["read-screen", "--workspace", ws, "--surface", surface, "--lines", "25"],
                        timeout=20,
                        check=False,
                    )
                except subprocess.TimeoutExpired as exc:
                    if len(poll_failures) < 20:
                        poll_failures.append(
                            {
                                "surface": surface,
                                "workspace": ws,
                                "error": f"read-screen timed out after {exc.timeout}s",
                            }
                        )
                    continue
                if token in out:
                    done.append((ws, surface))
            for ws, surface in done:
                if self.report_shell_prompt(ws, surface):
                    prompt_reports += 1
                pending.pop(surface, None)
            if pending:
                self.wait_before_retry(deadline, 1.0, "seed_scrollback.poll")

        self.result["fixture"]["scrollback_done"] = len(terminals) - len(pending)
        self.result["fixture"]["scrollback_pending"] = len(pending)
        self.result["fixture"]["scrollback_prompt_reports"] = prompt_reports
        if poll_failures:
            self.result["fixture"]["scrollback_poll_failures"] = poll_failures
        if pending:
            self.result["fixture"]["scrollback_pending_sample"] = list(pending)[:10]

    def benchmark_snapshot(
        self,
        name: str,
        include_scrollback: bool,
        persist: bool = True,
        socket_retries: int = 0,
    ) -> dict:
        payload = self.rpc(
            "debug.session_snapshot_benchmark",
            {"include_scrollback": include_scrollback, "persist": persist},
            timeout=max(60, self.args.snapshot_timeout),
            socket_retries=socket_retries,
        )
        self.result["measurements"][name] = payload
        return payload

    def benchmark_real_scrollback_snapshot(self) -> dict:
        start = now_ms()
        deadline = time.monotonic() + self.args.real_scrollback_capture_timeout
        attempts: list[dict[str, float | int]] = []
        first_attempt_wall_ms = 0.0
        snapshot: dict = {}

        while True:
            attempt_start = now_ms()
            snapshot = self.benchmark_snapshot("snapshot_with_real_scrollback", include_scrollback=True)
            attempt_wall_ms = rounded_ms(now_ms() - attempt_start)
            chars = snapshot.get("shape", {}).get("scrollback_chars") or 0
            elapsed = snapshot.get("elapsed_ms") or 0.0
            if not attempts:
                first_attempt_wall_ms = attempt_wall_ms
            attempts.append(
                {
                    "attempt": len(attempts) + 1,
                    "elapsed_ms": float(elapsed),
                    "wall_ms": attempt_wall_ms,
                    "scrollback_chars": int(chars),
                }
            )
            if chars >= self.args.budget_min_scrollback_chars:
                break
            if self.args.real_scrollback_capture_timeout <= 0 or time.monotonic() >= deadline:
                break
            self.wait_before_retry(
                deadline,
                max(0.05, self.args.real_scrollback_refresh_interval),
                "benchmark_real_scrollback_snapshot",
            )

        wait_ms = rounded_ms(now_ms() - start)
        refresh_interval = max(0.05, self.args.real_scrollback_refresh_interval)
        self.result["fixture"]["real_scrollback_capture"] = {
            "attempts": len(attempts),
            "attempt_samples": attempts[:10],
            "wait_ms": wait_ms,
            "retry_overhead_ms": rounded_ms(max(0.0, wait_ms - first_attempt_wall_ms)),
            "refresh_interval_s": refresh_interval,
            "refresh_rate_hz": round(1.0 / refresh_interval, 2),
            "timeout_s": self.args.real_scrollback_capture_timeout,
        }
        return snapshot

    def seed_synthetic_scrollback_fallback(self, real_snapshot: dict) -> bool:
        if not self.args.synthetic_scrollback_fallback:
            return False
        real_chars = real_snapshot.get("shape", {}).get("scrollback_chars") or 0
        if real_chars >= self.args.budget_min_scrollback_chars:
            return False
        payload = self.rpc(
            "debug.session_snapshot_seed_scrollback",
            {"characters_per_terminal": self.args.synthetic_scrollback_chars_per_terminal},
            timeout=max(60, self.args.snapshot_timeout),
        )
        self.result["fixture"]["synthetic_scrollback_fallback"] = payload
        self.result["fixture"]["synthetic_scrollback_fallback_reason"] = "captured_scrollback_below_budget"
        return True

    def benchmark_restore(self) -> None:
        self.stop_app()
        previous_snapshot_mtime_ns = self.session_snapshot_mtime_ns()
        self.launch("restore")
        ready_ms = self.wait_for_debug_log_marker(
            "restore_main_window_ready",
            ("mainWindow.visibility.focus reason=createMainWindow",),
            timeout_s=self.args.restore_ready_timeout,
        )
        self.result["measurements"]["restore_main_window_ready_ms"] = ready_ms
        restored_snapshot = self.wait_for_restored_session_snapshot(
            previous_mtime_ns=previous_snapshot_mtime_ns,
            timeout_s=self.args.restore_ready_timeout,
        )
        self.result["fixture"]["post_restore_snapshot_source"] = "session_persistence_store"
        self.result["fixture"]["post_restore_shape"] = self.session_snapshot_shape(restored_snapshot)

    def apply_budgets(self) -> None:
        measurements = self.result["measurements"]
        fixture = self.result["fixture"]
        budgets = {
            "launch_socket_ready_ms": self.args.budget_launch_socket_ready_ms,
            "restore_socket_ready_ms": self.args.budget_restore_socket_ready_ms,
            "snapshot_no_scrollback_elapsed_ms": self.args.budget_no_scrollback_snapshot_ms,
            "snapshot_with_scrollback_elapsed_ms": self.args.budget_scrollback_snapshot_ms,
            "snapshot_with_scrollback_min_chars": self.args.budget_min_scrollback_chars,
            "min_terminal_surfaces": self.args.budget_min_terminal_surfaces,
            "post_restore_min_workspaces": self.args.workspace_count,
            "post_restore_min_terminal_surfaces": self.args.budget_min_terminal_surfaces,
        }
        failures: list[str] = []

        def max_budget(label: str, actual: float | int | None, budget: float | int) -> None:
            if actual is None:
                failures.append(f"{label}: missing measurement")
            elif actual > budget:
                failures.append(f"{label}: {actual} > {budget}")

        def min_budget(label: str, actual: float | int | None, budget: float | int) -> None:
            if actual is None:
                failures.append(f"{label}: missing measurement")
            elif actual < budget:
                failures.append(f"{label}: {actual} < {budget}")

        max_budget("launch_socket_ready_ms", measurements.get("launch_socket_ready_ms"), budgets["launch_socket_ready_ms"])
        max_budget("restore_socket_ready_ms", measurements.get("restore_socket_ready_ms"), budgets["restore_socket_ready_ms"])
        max_budget(
            "snapshot_no_scrollback.elapsed_ms",
            measurements.get("snapshot_no_scrollback", {}).get("elapsed_ms"),
            budgets["snapshot_no_scrollback_elapsed_ms"],
        )
        max_budget(
            "snapshot_with_scrollback.elapsed_ms",
            measurements.get("snapshot_with_scrollback", {}).get("elapsed_ms"),
            budgets["snapshot_with_scrollback_elapsed_ms"],
        )
        min_budget(
            "snapshot_with_scrollback.shape.scrollback_chars",
            measurements.get("snapshot_with_scrollback", {}).get("shape", {}).get("scrollback_chars"),
            budgets["snapshot_with_scrollback_min_chars"],
        )
        min_budget("fixture.terminal_surfaces", fixture.get("terminal_surfaces"), budgets["min_terminal_surfaces"])
        min_budget(
            "fixture.post_restore_shape.workspaces",
            fixture.get("post_restore_shape", {}).get("workspaces"),
            budgets["post_restore_min_workspaces"],
        )
        min_budget(
            "fixture.post_restore_shape.terminals",
            fixture.get("post_restore_shape", {}).get("terminals"),
            budgets["post_restore_min_terminal_surfaces"],
        )

        self.result["budgets"] = budgets
        self.result["failures"] = failures

    def run(self) -> dict:
        self.check_paths()
        self.stop_app()
        self.clean_persisted_state()
        self.configure_benchmark_defaults()
        try:
            self.launch("launch")
            terminals = self.create_fixture()
            self.ensure_app_running("after_fixture")
            self.seed_scrollback(terminals)
            self.ensure_app_running("after_scrollback")
            self.benchmark_snapshot("snapshot_no_scrollback", include_scrollback=False)
            real_scrollback = self.benchmark_real_scrollback_snapshot()
            if self.seed_synthetic_scrollback_fallback(real_scrollback):
                self.benchmark_snapshot("snapshot_with_scrollback", include_scrollback=True)
            else:
                self.result["measurements"]["snapshot_with_scrollback"] = real_scrollback
            self.benchmark_restore()
            self.apply_budgets()
            return self.result
        finally:
            self.stop_app()
            self.clear_benchmark_defaults()
            if not self.args.keep_fixture and self.fixture_root.exists():
                shutil.rmtree(self.fixture_root, ignore_errors=True)


def write_junit(result: dict, path: pathlib.Path) -> None:
    failures = result.get("failures", [])
    suite = ET.Element(
        "testsuite",
        {
            "name": "ActivationSessionPerformance",
            "tests": "1",
            "failures": "1" if failures else "0",
        },
    )
    case = ET.SubElement(suite, "testcase", {"name": "activation_session_performance"})
    if failures:
        failure = ET.SubElement(case, "failure", {"message": "; ".join(failures)})
        failure.text = json.dumps(result, indent=2, sort_keys=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def print_summary(result: dict) -> None:
    measurements = result["measurements"]
    fixture = result["fixture"]
    print("activation session performance")
    print(f"  fixture: workspaces={fixture.get('workspaces')} terminals={fixture.get('terminal_surfaces')} scrollback_done={fixture.get('scrollback_done')}")
    print(f"  launch_socket_ready_ms={measurements.get('launch_socket_ready_ms')}")
    synthetic_seed = fixture.get("synthetic_scrollback_fallback")
    real_capture = fixture.get("real_scrollback_capture") or {}
    if synthetic_seed:
        print(
            "  synthetic_scrollback_fallback="
            f"{synthetic_seed} reason={fixture.get('synthetic_scrollback_fallback_reason')}"
        )
    if real_capture:
        print(
            "  real_scrollback_capture="
            f"attempts={real_capture.get('attempts')} wait_ms={real_capture.get('wait_ms')} "
            f"retry_overhead_ms={real_capture.get('retry_overhead_ms')} "
            f"refresh_rate_hz={real_capture.get('refresh_rate_hz')}"
        )
    no_scroll = measurements.get("snapshot_no_scrollback", {})
    real_scroll = measurements.get("snapshot_with_real_scrollback", {})
    with_scroll = measurements.get("snapshot_with_scrollback", {})
    print(f"  snapshot_no_scrollback_ms={no_scroll.get('elapsed_ms')} shape={no_scroll.get('shape')}")
    if real_scroll:
        print(f"  snapshot_with_real_scrollback_ms={real_scroll.get('elapsed_ms')} shape={real_scroll.get('shape')}")
    print(f"  snapshot_with_scrollback_ms={with_scroll.get('elapsed_ms')} shape={with_scroll.get('shape')}")
    print(f"  restore_socket_ready_ms={measurements.get('restore_socket_ready_ms')}")
    print(f"  restore_main_window_ready_ms={measurements.get('restore_main_window_ready_ms')}")
    print(f"  restore_snapshot_file_wait_ms={measurements.get('restore_snapshot_file_wait_ms')}")
    failures = result.get("failures", [])
    if failures:
        print("  budget_failures:")
        for failure in failures:
            print(f"    - {failure}")
    else:
        print("  budgets: pass")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run cmux activation/session snapshot performance benchmark.")
    parser.add_argument("--tag", default="perfci", help="Tagged debug app name built by scripts/reload.sh.")
    parser.add_argument("--app-path", default="", help="Override app bundle path.")
    parser.add_argument("--fixture-root", default="", help="Directory for temporary dirty git repos.")
    parser.add_argument("--output", default="", help="Write JSON results to this path.")
    parser.add_argument("--junit", default="", help="Write JUnit XML results to this path.")
    parser.add_argument("--keep-fixture", action="store_true", help="Keep fixture directory after the run.")
    parser.add_argument("--no-fail-budget", action="store_true", help="Print budget failures without exiting non-zero.")

    parser.add_argument("--workspace-count", type=int, default=12)
    parser.add_argument("--heavy-workspace-panes", type=int, default=8)
    parser.add_argument("--other-workspace-panes", type=int, default=4)
    parser.add_argument("--heavy-tabbed-panes", type=int, default=3)
    parser.add_argument("--other-tabbed-panes", type=int, default=1)
    parser.add_argument("--heavy-scrollback-lines", type=int, default=2400)
    parser.add_argument("--other-scrollback-lines", type=int, default=1400)
    parser.add_argument("--line-payload-chars", type=int, default=96)
    parser.add_argument("--synthetic-scrollback-fallback", action="store_true", help="Seed DEBUG-only fallback scrollback for headless CI runners.")
    parser.add_argument("--synthetic-scrollback-chars-per-terminal", type=int, default=165_000)
    parser.add_argument("--real-scrollback-capture-timeout", type=float, default=20)
    parser.add_argument("--real-scrollback-refresh-interval", type=float, default=0.5)

    parser.add_argument("--launch-timeout", type=float, default=45)
    parser.add_argument("--scrollback-timeout", type=float, default=180)
    parser.add_argument("--snapshot-timeout", type=float, default=120)
    parser.add_argument("--restore-ready-timeout", type=float, default=20)

    parser.add_argument("--budget-launch-socket-ready-ms", type=float, default=15000)
    parser.add_argument("--budget-restore-socket-ready-ms", type=float, default=15000)
    parser.add_argument("--budget-no-scrollback-snapshot-ms", type=float, default=250)
    parser.add_argument("--budget-scrollback-snapshot-ms", type=float, default=1500)
    parser.add_argument("--budget-min-scrollback-chars", type=int, default=1_000_000)
    parser.add_argument("--budget-min-terminal-surfaces", type=int, default=40)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runner = CmuxPerfRunner(args)
    try:
        result = runner.run()
    except Exception as exc:
        result = runner.result
        runner.attach_failure_diagnostics()
        result["failures"] = result.get("failures", []) + [str(exc)]
        if args.output:
            output = pathlib.Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            runner.write_diagnostic_files(output.parent)
            output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if args.junit:
            write_junit(result, pathlib.Path(args.junit))
        print_summary(result)
        raise

    if args.output:
        output = pathlib.Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.junit:
        write_junit(result, pathlib.Path(args.junit))
    print_summary(result)
    if result.get("failures") and not args.no_fail_budget:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        raise
