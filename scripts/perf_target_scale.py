#!/usr/bin/env python3
"""Run cmux's target-scale CPU, memory, GPU, and thread benchmark.

The command is intentionally a standalone macOS harness.  It launches only a
tagged Debug app, creates a disposable workspace containing idle terminal
surfaces, collects process-owned diagnostics, and writes one JSON artifact per
fixture size.  Budget decisions live in :mod:`perf_target_scale_metrics` so
they can be tested without a Mac or an app build.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Any, Mapping, Sequence

try:
    from perf_target_scale_metrics import (
        FIXTURE_SIZES,
        MIN_CPU_SECONDS,
        SCHEMA_VERSION,
        VISIBLE_SURFACE_LIMIT,
        BudgetConfig,
        balanced_layout,
        fixture_contract,
        make_artifact,
        parse_cpu_samples,
        parse_footprint_output,
        parse_thread_listing,
        parse_vmmap_summary,
        retained_gpu_bytes,
        self_test,
        summarize_cpu_samples,
        synthetic_run,
    )
except ImportError:  # pragma: no cover - supports direct module execution.
    from scripts.perf_target_scale_metrics import (  # type: ignore
        FIXTURE_SIZES,
        MIN_CPU_SECONDS,
        SCHEMA_VERSION,
        VISIBLE_SURFACE_LIMIT,
        BudgetConfig,
        balanced_layout,
        fixture_contract,
        make_artifact,
        parse_cpu_samples,
        parse_footprint_output,
        parse_thread_listing,
        parse_vmmap_summary,
        retained_gpu_bytes,
        self_test,
        summarize_cpu_samples,
        synthetic_run,
    )


class BenchmarkError(RuntimeError):
    """A deterministic setup or collection failure (never a fake pass)."""


def sanitize_tag(raw: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return re.sub(r"-+", "-", value) or "perf"


def sanitize_bundle(raw: str) -> str:
    value = re.sub(r"[^a-z0-9]+", ".", raw.lower()).strip(".")
    return re.sub(r"\.+", ".", value) or "perf"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _run(
    command: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    timeout: float = 30.0,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(
            list(command),
            capture_output=True,
            text=True,
            env=dict(env) if env is not None else None,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise BenchmarkError(f"command timed out after {timeout:.1f}s: {' '.join(command)}") from exc
    except OSError as exc:
        raise BenchmarkError(f"could not execute {' '.join(command)}: {exc}") from exc
    if check and completed.returncode != 0:
        detail = (completed.stdout + "\n" + completed.stderr).strip()
        raise BenchmarkError(f"command failed ({completed.returncode}): {' '.join(command)}\n{detail[:1200]}")
    return completed


def _text_value(command: Sequence[str], *, timeout: float = 10.0) -> str:
    completed = _run(command, timeout=timeout)
    return completed.stdout.strip()


def _safe_text(command: Sequence[str], *, timeout: float = 10.0) -> str | None:
    try:
        completed = _run(command, timeout=timeout, check=False)
    except (BenchmarkError, OSError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def _parse_int(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _read_plist_version(app_path: pathlib.Path) -> str:
    plist_path = app_path / "Contents" / "Info.plist"
    try:
        with plist_path.open("rb") as stream:
            payload = plistlib.load(stream)
        short = str(payload.get("CFBundleShortVersionString") or "").strip()
        build = str(payload.get("CFBundleVersion") or "").strip()
        if short and build:
            return f"{short} ({build})"
        return short or build or "unknown"
    except (OSError, plistlib.InvalidFileException, ValueError):
        return "unknown"


def _hardware_metadata() -> dict[str, Any]:
    def first(*commands: Sequence[str]) -> str | None:
        for command in commands:
            value = _safe_text(command)
            if value:
                return value
        return None

    ncpu = _parse_int(first(["sysctl", "-n", "hw.ncpu"]))
    memsize = _parse_int(first(["sysctl", "-n", "hw.memsize"]))
    return {
        "model": first(["sysctl", "-n", "hw.model"]),
        "os_version": first(["sw_vers", "-productVersion"], ["sysctl", "-n", "kern.osproductversion"]),
        "logical_cores": ncpu,
        "memory_bytes": memsize,
    }


def _descendant_rows(root_pid: int) -> tuple[list[dict[str, Any]], int]:
    output = _text_value(["ps", "-axo", "pid=,ppid=,rss=,command="], timeout=15)
    rows: dict[int, dict[str, Any]] = {}
    for raw in output.splitlines():
        fields = raw.strip().split(None, 3)
        if len(fields) < 3:
            continue
        pid = _parse_int(fields[0])
        ppid = _parse_int(fields[1])
        rss_kib = _parse_int(fields[2])
        if pid is None or ppid is None or rss_kib is None:
            continue
        rows[pid] = {"pid": pid, "ppid": ppid, "rss_bytes": rss_kib * 1024, "command": fields[3] if len(fields) > 3 else ""}

    children: dict[int, list[dict[str, Any]]] = {}
    for row in rows.values():
        children.setdefault(int(row["ppid"]), []).append(row)
    queue = list(children.get(root_pid, []))
    descendants: list[dict[str, Any]] = []
    while queue:
        row = queue.pop(0)
        descendants.append(row)
        queue.extend(children.get(int(row["pid"]), []))
    return descendants, sum(int(row["rss_bytes"]) for row in descendants)


def _read_surface_text(payload: Mapping[str, Any]) -> str:
    if isinstance(payload.get("text"), str):
        return str(payload["text"])
    encoded = payload.get("base64")
    if not encoded:
        return ""
    import base64

    try:
        return base64.b64decode(str(encoded)).decode("utf-8", errors="replace")
    except (ValueError, TypeError):
        return ""


class TargetScaleRunner:
    """Own one tagged app process and one fixture size at a time."""

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.tag = str(args.tag)
        self.tag_slug = sanitize_tag(self.tag)
        self.tag_id = sanitize_bundle(self.tag)
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.sock")
        self.cmuxd_socket_path = pathlib.Path.home() / "Library" / "Application Support" / "cmux" / f"cmuxd-dev-{self.tag_slug}.sock"
        self.app_path = pathlib.Path(args.app_path).expanduser() if args.app_path else self.default_app_path()
        self.binary_path = self.app_path / "Contents" / "MacOS" / f"cmux DEV"
        self.cli_path = self.app_path / "Contents" / "Resources" / "bin" / "cmux"
        self.proc: subprocess.Popen[str] | None = None
        self.pid: int | None = None
        self.collector_warnings: list[str] = []

    def default_app_path(self) -> pathlib.Path:
        return pathlib.Path.home() / (
            f"Library/Developer/Xcode/DerivedData/cmux-{self.tag_slug}/"
            f"Build/Products/Debug/cmux DEV {self.tag_slug}.app"
        )

    def app_environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        for key in (
            "CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET_MODE", "CMUX_TAG",
            "CMUX_BUNDLE_ID", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID",
            "CMUX_TAB_ID", "CMUXD_UNIX_PATH", "CMUX_DEBUG_LOG", "CMUX_PORT",
            "CMUX_PORT_END", "CMUX_PORT_RANGE", "GHOSTTY_BIN_DIR", "GHOSTTY_RESOURCES_DIR",
        ):
            environment.pop(key, None)
        environment.update({
            "CMUX_SOCKET": str(self.socket_path),
            "CMUX_SOCKET_PATH": str(self.socket_path),
            "CMUX_SOCKET_MODE": "automation",
            "CMUXD_UNIX_PATH": str(self.cmuxd_socket_path),
            "CMUX_DEBUG_LOG": f"/tmp/cmux-debug-{self.tag_slug}.log",
            "CMUX_TAG": self.tag,
            "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{self.tag_id}",
            "CMUX_BUNDLED_CLI_PATH": str(self.cli_path),
            "CMUX_TARGET_SCALE_FIXTURE": "1",
        })
        return environment

    def cli_environment(self) -> dict[str, str]:
        environment = self.app_environment()
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "120"
        return environment

    def clean_tag_state(self) -> None:
        support = pathlib.Path.home() / "Library" / "Application Support" / "cmux"
        bundle = f"com.cmuxterm.app.debug.{self.tag_id}"
        for suffix in ("", "-previous"):
            (support / f"session-{bundle}{suffix}.json").unlink(missing_ok=True)
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)

    def launch(self) -> None:
        if not self.binary_path.exists():
            raise BenchmarkError(f"tagged app binary not found: {self.binary_path}")
        if not self.cli_path.exists():
            raise BenchmarkError(f"tagged cmux CLI not found: {self.cli_path}")
        self.clean_tag_state()
        stdout_path = pathlib.Path(tempfile.gettempdir()) / f"cmux-target-scale-{self.tag_slug}.log"
        stdout = stdout_path.open("ab", buffering=0)
        self.proc = subprocess.Popen(
            [str(self.binary_path)],
            env=self.app_environment(),
            stdout=stdout,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        stdout.close()
        deadline = time.monotonic() + float(self.args.launch_timeout)
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise BenchmarkError(f"tagged app exited before socket became ready (code {self.proc.returncode})")
            if self.socket_path.exists():
                try:
                    self.rpc("system.ping", timeout=5)
                    self.pid = self.socket_owner_pid()
                    return
                except BenchmarkError:
                    pass
            time.sleep(0.1)
        raise BenchmarkError(f"tagged app socket did not become ready: {self.socket_path}")

    def stop(self) -> None:
        process = self.proc
        self.proc = None
        self.pid = None
        descendants: list[dict[str, Any]] = []
        if process is not None:
            try:
                descendants, _ = _descendant_rows(int(process.pid))
            except BenchmarkError:
                descendants = []
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        # cmuxd is a tagged child but can outlive the app's normal termination
        # path.  Kill only descendants of this run; never use an unscoped
        # pkill that could touch the user's main cmux instance.
        for row in descendants:
            child_pid = _parse_int(row.get("pid"))
            if child_pid is None or child_pid == os.getpid():
                continue
            try:
                os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                self.collector_warnings.append(f"could not stop tagged child PID {child_pid}")
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)

    def socket_owner_pid(self) -> int:
        output = _text_value(["lsof", "-t", str(self.socket_path)], timeout=10)
        candidates: list[int] = []
        for raw in output.splitlines():
            pid = _parse_int(raw)
            if pid:
                candidates.append(pid)
        # Prefer the process whose command is the tagged app.  A short-lived
        # bundled CLI can briefly appear in lsof while it performs the ping;
        # charging that process would make every resource measurement invalid.
        for pid in candidates:
            command = _safe_text(["ps", "-p", str(pid), "-o", "command="], timeout=5) or ""
            if "cmux DEV" in command and "/Contents/Resources/bin/cmux" not in command:
                return pid
        # The app's Popen PID is authoritative when it owns the socket.  Do
        # this before accepting an arbitrary lsof candidate: cmuxd can also
        # appear as a socket owner, and charging that helper would invalidate
        # the app-only measurements.
        if self.proc and self.proc.pid in candidates:
            return int(self.proc.pid)
        for pid in candidates:
            if self.proc is None or pid != self.proc.pid:
                return pid
        # In most tagged runs lsof reports the app itself.  Accept the child
        # Popen PID as a fallback when launchd briefly owns the socket.
        if self.proc and self.proc.pid:
            return int(self.proc.pid)
        raise BenchmarkError(f"could not resolve app PID from {self.socket_path}")

    def run_cli(self, arguments: Sequence[str], *, timeout: float = 120.0) -> str:
        completed = _run([str(self.cli_path), *arguments], env=self.cli_environment(), timeout=timeout)
        return completed.stdout.strip()

    def rpc(self, method: str, params: Mapping[str, Any] | None = None, *, timeout: float = 120.0) -> dict[str, Any]:
        raw = self.run_cli(["rpc", method, json.dumps(dict(params or {}), separators=(",", ":"))], timeout=timeout)
        try:
            payload = json.loads(raw or "{}")
        except json.JSONDecodeError as exc:
            raise BenchmarkError(f"{method} returned non-JSON output: {raw[:800]!r}") from exc
        if not isinstance(payload, dict):
            raise BenchmarkError(f"{method} returned a non-object payload: {payload!r}")
        return payload

    def _workspace_ids(self) -> list[str]:
        payload = self.rpc("workspace.list")
        result: list[str] = []
        for row in payload.get("workspaces") or []:
            if isinstance(row, Mapping):
                value = row.get("id") or row.get("workspace_id")
                if value:
                    result.append(str(value))
        return result

    def _pane_topology(self, workspace_id: str) -> list[dict[str, Any]]:
        pane_payload = self.rpc("pane.list", {"workspace_id": workspace_id})
        panes: list[dict[str, Any]] = []
        for row in pane_payload.get("panes") or []:
            if not isinstance(row, Mapping):
                continue
            pane_id = row.get("id") or row.get("pane_id") or row.get("ref")
            if not pane_id:
                continue
            raw_ids = row.get("surface_ids") or row.get("surfaces") or []
            surface_ids: list[str] = []
            if isinstance(raw_ids, Sequence) and not isinstance(raw_ids, (str, bytes)):
                for item in raw_ids:
                    if isinstance(item, Mapping):
                        value = item.get("id") or item.get("surface_id") or item.get("ref")
                    else:
                        value = item
                    if value:
                        surface_ids.append(str(value))
            selected = row.get("selected_surface_id") or row.get("selected_surface_ref")
            panes.append({"id": str(pane_id), "surface_ids": surface_ids, "selected": str(selected) if selected else None})

        # Older tagged CLIs expose surface IDs only in surface.list.  Fill the
        # same shape from that response rather than silently losing visibility.
        surface_payload = self.rpc("surface.list", {"workspace_id": workspace_id})
        by_pane: dict[str, list[tuple[str, bool]]] = {}
        for row in surface_payload.get("surfaces") or []:
            if not isinstance(row, Mapping):
                continue
            sid = row.get("id") or row.get("surface_id") or row.get("ref")
            pane = row.get("pane_id") or row.get("pane_ref")
            if not sid or not pane:
                continue
            by_pane.setdefault(str(pane), []).append((str(sid), bool(row.get("selected_in_pane") or row.get("selected"))))
        for pane in panes:
            entries = by_pane.get(pane["id"], [])
            if not pane["surface_ids"]:
                pane["surface_ids"] = [sid for sid, _selected in entries]
            if not pane["selected"]:
                selected = next((sid for sid, selected in entries if selected), None)
                pane["selected"] = selected
        return panes

    def _create_fixture(self, live: int) -> tuple[str, list[dict[str, Any]]]:
        visible = min(VISIBLE_SURFACE_LIMIT, live)
        old_workspaces = self._workspace_ids()
        payload = self.rpc(
            "workspace.create",
            {
                "title": f"target-scale-{live}",
                "focus": False,
                "layout": balanced_layout(visible),
            },
            timeout=180,
        )
        workspace_id = str(payload.get("workspace_id") or "")
        if not workspace_id:
            raise BenchmarkError(f"workspace.create did not return workspace_id: {payload!r}")
        for old in old_workspaces:
            if old != workspace_id:
                try:
                    self.rpc("workspace.close", {"workspace_id": old}, timeout=60)
                except BenchmarkError as exc:
                    raise BenchmarkError(
                        f"could not remove pre-existing workspace {old}; app-only fixture would be invalid: {exc}"
                    ) from exc
        self.rpc("workspace.select", {"workspace_id": workspace_id})
        panes = self._pane_topology(workspace_id)
        if len(panes) != visible:
            raise BenchmarkError(f"fixture requested {visible} visible panes, app reported {len(panes)}")
        for index in range(live - visible):
            pane = panes[index % visible]
            created = self.rpc(
                "surface.create",
                {"workspace_id": workspace_id, "pane_id": pane["id"], "type": "terminal", "focus": False},
                timeout=120,
            )
            sid = created.get("surface_id") or created.get("id")
            if not sid:
                raise BenchmarkError(f"surface.create did not return a surface ID: {created!r}")
        panes = self._pane_topology(workspace_id)
        # Establish the visible set explicitly after all hidden tabs exist.
        for pane in panes:
            if pane["surface_ids"]:
                self.rpc("surface.focus", {"surface_id": pane["surface_ids"][0]}, timeout=60)
        panes = self._pane_topology(workspace_id)
        actual_live = sum(len(pane["surface_ids"]) for pane in panes)
        actual_visible = sum(1 for pane in panes if pane.get("selected"))
        if actual_live != live or actual_visible != visible:
            raise BenchmarkError(f"fixture topology mismatch: live={actual_live}/{live}, visible={actual_visible}/{visible}")
        return workspace_id, panes

    def _scrollback_command(self, scrollback_bytes: int) -> tuple[str, int]:
        line = "CMUX_TARGET_SCALE_0123456789abcdef0123456789abcdef0123456789abcdef"
        line_bytes = len(line.encode("utf-8")) + 1
        lines = max(1, int(scrollback_bytes) // line_bytes)
        command = (
            f"i=0; while [ $i -lt {lines} ]; do printf '%s\\n' '{line}'; "
            f"i=$((i+1)); done; printf '%s\\n' 'CMUX_TARGET_SCALE_READY'\n"
        )
        return command, lines * line_bytes

    def _seed_scrollback(self, workspace_id: str, panes: Sequence[Mapping[str, Any]], scrollback_bytes: int) -> int:
        command, effective_bytes = self._scrollback_command(scrollback_bytes)
        surface_ids = [sid for pane in panes for sid in pane.get("surface_ids", [])]
        for sid in surface_ids:
            self.rpc("surface.send_text", {"workspace_id": workspace_id, "surface_id": sid, "text": command}, timeout=120)
        deadline = time.monotonic() + max(10.0, float(self.args.settle_seconds) + 8.0)
        pending = set(surface_ids)
        while pending and time.monotonic() < deadline:
            for sid in list(pending):
                try:
                    text = _read_surface_text(self.rpc("surface.read_text", {"workspace_id": workspace_id, "surface_id": sid}, timeout=30))
                except BenchmarkError:
                    continue
                if "CMUX_TARGET_SCALE_READY" in text:
                    pending.remove(sid)
            if pending:
                time.sleep(0.2)
        if pending:
            raise BenchmarkError(f"scrollback seed did not settle for {len(pending)} surfaces")
        return effective_bytes

    def _runtime_terminal_stats(self, workspace_id: str) -> dict[str, Any]:
        """Record the app's terminal runtime view separately from topology."""

        try:
            payload = self.rpc("debug.terminals", timeout=60)
        except BenchmarkError as exc:
            self.collector_warnings.append(f"debug.terminals unavailable: {exc}")
            return {"reported_count": None, "runtime_ready_count": None}
        rows = [row for row in (payload.get("terminals") or []) if isinstance(row, Mapping) and str(row.get("workspace_id")) == workspace_id]
        ready = sum(1 for row in rows if row.get("runtime_surface_ready") is True)
        return {"reported_count": len(rows), "runtime_ready_count": ready}

    def _settle(self) -> None:
        time.sleep(max(0.0, float(self.args.settle_seconds)))

    def _cycle_visibility(self, workspace_id: str, panes: Sequence[Mapping[str, Any]]) -> None:
        del workspace_id  # kept in the signature to make the fixture contract explicit.
        cycles = int(self.args.cycles)
        for _cycle in range(cycles):
            for pane in panes:
                ids = list(pane.get("surface_ids", []))
                if len(ids) < 2:
                    continue
                original = ids[0]
                for hidden in ids[1:]:
                    self.rpc("surface.focus", {"surface_id": hidden}, timeout=60)
                self.rpc("surface.focus", {"surface_id": original}, timeout=60)

    def _assert_visibility(self, workspace_id: str, expected_live: int) -> None:
        panes = self._pane_topology(workspace_id)
        live = sum(len(pane.get("surface_ids", [])) for pane in panes)
        visible = sum(1 for pane in panes if pane.get("selected"))
        expected_visible = min(VISIBLE_SURFACE_LIMIT, expected_live)
        if live != expected_live or visible != expected_visible:
            raise BenchmarkError(
                f"visibility cycle left an invalid topology: live={live}/{expected_live}, "
                f"visible={visible}/{expected_visible}"
            )

    def _capture_snapshot(self) -> dict[str, Any]:
        if self.pid is None:
            raise BenchmarkError("cannot collect metrics before app launch")
        pid = int(self.pid)
        footprint_output: str | None = None
        for command in (("footprint", "-summary", "-pid", str(pid)), ("footprint", "-p", str(pid), "-summary")):
            completed = _run(command, timeout=30, check=False)
            if completed.returncode == 0 and completed.stdout.strip():
                footprint_output = completed.stdout
                break
        if footprint_output is None:
            raise BenchmarkError(f"footprint could not inspect app PID {pid}")
        parsed = parse_footprint_output(footprint_output)
        if parsed["phys_footprint_bytes"] is None:
            vmmap = _run(["vmmap", "--summary", str(pid)], timeout=30, check=False)
            fallback = parse_vmmap_summary(vmmap.stdout)
            parsed = {
                key: (fallback[key] if parsed.get(key) is None and fallback.get(key) is not None else parsed.get(key))
                for key in parsed
            }
        if parsed["phys_footprint_bytes"] is None:
            raise BenchmarkError(f"could not parse app physical footprint for PID {pid}")

        thread_command = ["ps", "-M", "-p", str(pid), "-o", "tid=,thcomm="]
        thread_output = _safe_text(thread_command, timeout=20)
        if thread_output is None:
            thread_output = _text_value(["ps", "-M", "-p", str(pid)], timeout=20)
        threads = parse_thread_listing(thread_output)
        snapshot: dict[str, Any] = {
            "captured_at": utc_now(),
            "pid": pid,
            "phys_footprint_bytes": parsed["phys_footprint_bytes"],
            "phys_footprint_peak_bytes": parsed["phys_footprint_peak_bytes"],
            "gpu": {
                "dirty_graphics_bytes": parsed["dirty_graphics_bytes"],
                "iosurface_bytes": parsed["iosurface_bytes"],
                "ioaccelerator_bytes": parsed["ioaccelerator_bytes"],
            },
            "threads": threads,
        }
        retained = retained_gpu_bytes(snapshot)
        snapshot["gpu"]["retained_bytes"] = retained
        if retained is None:
            self.collector_warnings.append("footprint did not expose Dirty Graphics, IOSurface, or IOAccelerator categories")
        return snapshot

    def _sample_cpu(self, duration_seconds: float) -> dict[str, Any]:
        if self.pid is None:
            raise BenchmarkError("cannot sample CPU before app launch")
        if duration_seconds < MIN_CPU_SECONDS:
            raise BenchmarkError(f"CPU duration must be at least {MIN_CPU_SECONDS:.0f}s")
        values: list[float] = []
        start = time.monotonic()
        deadline = start + duration_seconds
        while time.monotonic() < deadline:
            completed = _run(["ps", "-p", str(self.pid), "-o", "%cpu="], timeout=15, check=False)
            values.extend(parse_cpu_samples(completed.stdout.splitlines()))
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(1.0, remaining))
        cores = _parse_int(_safe_text(["sysctl", "-n", "hw.ncpu"]) or "1") or 1
        summary = summarize_cpu_samples(values, time.monotonic() - start, cores)
        if not values:
            raise BenchmarkError("CPU sampler produced no numeric ps samples")
        return summary

    def run_size(self, live: int) -> dict[str, Any]:
        workspace_id = ""
        try:
            workspace_id, panes = self._create_fixture(live)
            effective_scrollback = self._seed_scrollback(workspace_id, panes, int(self.args.scrollback_bytes))
            runtime_stats = self._runtime_terminal_stats(workspace_id)
            self._assert_visibility(workspace_id, live)
            self._settle()
            first = self._capture_snapshot()
            self._cycle_visibility(workspace_id, panes)
            self._assert_visibility(workspace_id, live)
            self._settle()
            post = self._capture_snapshot()
            cpu = self._sample_cpu(float(self.args.cpu_seconds))
            descendants, child_rss = _descendant_rows(int(self.pid or 0))
            threads = post.get("threads") or {}
            return {
                "fixture": {
                    **fixture_contract(live, effective_scrollback, int(self.args.cycles)),
                    "workspace_id": workspace_id,
                    "pane_count": len(panes),
                    "runtime_terminals": runtime_stats,
                },
                "first_settled": first,
                "post_cycle_settled": post,
                "cpu": cpu,
                "threads": threads,
                "child_workload": {
                    "excluded_from_app_budgets": True,
                    "process_count": len(descendants),
                    "rss_bytes": child_rss,
                    "processes": descendants[:64],
                },
            }
        finally:
            if workspace_id:
                try:
                    self.rpc("workspace.close", {"workspace_id": workspace_id}, timeout=60)
                except BenchmarkError as exc:
                    self.collector_warnings.append(f"fixture cleanup failed for {workspace_id}: {exc}")

    def run(self) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        for live in self.args.sizes:
            try:
                self.launch()
                runs.append(self.run_size(int(live)))
            finally:
                self.stop()
        return runs


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_junit(path: pathlib.Path, artifact: Mapping[str, Any]) -> None:
    evaluation = artifact.get("evaluation") if isinstance(artifact.get("evaluation"), Mapping) else {}
    failures = evaluation.get("failures") if isinstance(evaluation.get("failures"), list) else []
    suite = ET.Element("testsuite", {"name": "cmux target-scale resource budgets", "tests": "1", "failures": str(len(failures))})
    case = ET.SubElement(suite, "testcase", {"classname": "perf_target_scale", "name": "target_scale_budgets"})
    for failure in failures:
        node = ET.SubElement(case, "failure", {"type": str(failure.get("code", "budget"))})
        node.text = str(failure.get("message", failure))
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def _metadata(args: argparse.Namespace) -> dict[str, Any]:
    app_path = pathlib.Path(args.app_path).expanduser() if args.app_path else None
    if app_path is None and args.tag:
        slug = sanitize_tag(str(args.tag))
        app_path = pathlib.Path.home() / (
            f"Library/Developer/Xcode/DerivedData/cmux-{slug}/"
            f"Build/Products/Debug/cmux DEV {slug}.app"
        )
    git_sha = _safe_text(["git", "rev-parse", "HEAD"], timeout=10)
    metadata: dict[str, Any] = {
        "benchmark": "cmux target-scale resource budgets",
        "issue": 9812,
        "tag": args.tag,
        "app_path": str(app_path) if app_path else None,
        "app_version": _read_plist_version(app_path) if app_path else "synthetic",
        "git_sha": git_sha,
        "hardware": _hardware_metadata() if not args.synthetic else {"synthetic": True},
        "platform": sys.platform,
    }
    return metadata


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="isolated cmux reload tag (required for a real run)")
    parser.add_argument("--app-path", help="tagged .app path; defaults to tagged DerivedData")
    parser.add_argument("--sizes", default=",".join(str(value) for value in FIXTURE_SIZES), help="comma-separated fixture sizes (subset of 1,10,100,200)")
    parser.add_argument("--scrollback-bytes", type=int, default=64 * 1024, help="identical bounded scrollback target per surface")
    parser.add_argument("--settle-seconds", type=float, default=5.0)
    parser.add_argument("--cpu-seconds", type=float, default=MIN_CPU_SECONDS, help="post-cycle CPU sample duration (minimum 30 seconds)")
    parser.add_argument("--cycles", type=int, default=20, help="reveal/hide cycles per fixture")
    parser.add_argument("--launch-timeout", type=float, default=90.0)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("perf-results/target-scale.json"))
    parser.add_argument("--junit", type=pathlib.Path, default=None)
    parser.add_argument("--enforce", action="store_true", help="return non-zero for budget failures; default is advisory")
    parser.add_argument("--synthetic", action="store_true", help="emit deterministic contract data without launching cmux")
    parser.add_argument("--self-test", action="store_true", help="run deliberate leak injections and require each to fail")
    return parser


def _parse_sizes(raw: str) -> list[int]:
    values: list[int] = []
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        try:
            value = int(token)
        except ValueError as exc:
            raise BenchmarkError(f"invalid fixture size {token!r}") from exc
        if value not in FIXTURE_SIZES:
            raise BenchmarkError(f"fixture size {value} is not one of {FIXTURE_SIZES}")
        if value not in values:
            values.append(value)
    if not values:
        raise BenchmarkError("--sizes must contain at least one fixture size")
    return values


def _print_summary(artifact: Mapping[str, Any]) -> None:
    evaluation = artifact.get("evaluation") if isinstance(artifact.get("evaluation"), Mapping) else {}
    failures = evaluation.get("failures") if isinstance(evaluation.get("failures"), list) else []
    print(f"target-scale status={artifact.get('status')} runs={len(artifact.get('runs') or [])} failures={len(failures)}")
    slopes = evaluation.get("slopes") if isinstance(evaluation.get("slopes"), Mapping) else {}
    for key, value in slopes.items():
        print(f"  {key}={value}")
    for failure in failures:
        print(f"  budget failure [{failure.get('code')}]: {failure.get('message')}", file=sys.stderr)


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        args.sizes = _parse_sizes(args.sizes)
        if args.scrollback_bytes <= 0:
            raise BenchmarkError("--scrollback-bytes must be positive")
        if args.cycles < 0:
            raise BenchmarkError("--cycles must be non-negative")
        if args.cpu_seconds < MIN_CPU_SECONDS and not args.synthetic and not args.self_test:
            raise BenchmarkError(f"--cpu-seconds must be at least {MIN_CPU_SECONDS:.0f}")

        if args.self_test:
            result = self_test()
            print(json.dumps(result, indent=2, sort_keys=True))
            if args.output:
                _write_json(args.output, result)
            return 0 if result.get("passed") else 1

        if not args.synthetic and not args.tag:
            raise BenchmarkError("--tag is required for a real run; use --synthetic for contract data")

        collector_warnings: list[str] = []
        if args.synthetic:
            runs = [synthetic_run(size) for size in args.sizes]
        else:
            target_runner = TargetScaleRunner(args)
            runs = target_runner.run()
            collector_warnings = target_runner.collector_warnings
        artifact = make_artifact(
            runs,
            metadata=_metadata(args),
            budgets=BudgetConfig(),
            advisory=not args.enforce,
            collector_warnings=collector_warnings,
            reveal_hide_cycles=int(args.cycles),
        )
        _write_json(args.output, artifact)
        if args.junit:
            _write_junit(args.junit, artifact)
        _print_summary(artifact)
        failures = artifact.get("evaluation", {}).get("failures", []) if isinstance(artifact.get("evaluation"), Mapping) else []
        return 1 if args.enforce and failures else 0
    except BenchmarkError as exc:
        # Preserve a machine-readable failure artifact for hosted runs even
        # when fixture setup or a required collector command fails before any
        # size can be evaluated.
        try:
            _write_json(
                args.output,
                {
                    "schema_version": SCHEMA_VERSION,
                    "generated_at": utc_now(),
                    "metadata": _metadata(args),
                    "status": "collector_error",
                    "error": str(exc),
                },
            )
        except Exception:
            pass
        print(f"target-scale: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
