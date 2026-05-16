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


def percentile(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    clamped = min(max(pct, 0.0), 1.0)
    index = int(((len(sorted_values) - 1) * clamped) + 0.999999)
    return sorted_values[min(len(sorted_values) - 1, max(0, index))]


def summary(values: list[float]) -> dict[str, float | int]:
    sorted_values = sorted(values)
    count = len(sorted_values)
    total = sum(sorted_values)
    return {
        "count": count,
        "avg_ms": rounded_ms(total / count) if count else 0.0,
        "p50_ms": rounded_ms(percentile(sorted_values, 0.50)),
        "p95_ms": rounded_ms(percentile(sorted_values, 0.95)),
        "max_ms": rounded_ms(sorted_values[-1] if sorted_values else 0.0),
    }


class PerfFailure(RuntimeError):
    pass


class WorkspaceSwitchPerfRunner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.tag = args.tag
        self.tag_slug = sanitize_path(args.tag)
        self.tag_id = sanitize_bundle(args.tag)
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.sock")
        self.cmuxd_socket_path = pathlib.Path(
            os.path.expanduser(f"~/Library/Application Support/cmux/cmuxd-dev-{self.tag_slug}.sock")
        )
        self.debug_log_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.log")
        self.stdout_path = pathlib.Path(f"/tmp/cmux-perf-switch-{self.tag_slug}-stdout.log")
        self.app_path = pathlib.Path(args.app_path).expanduser() if args.app_path else self.default_app_path()
        self.binary_path = self.app_path / "Contents/MacOS/cmux DEV"
        self.cli_path = self.app_path / "Contents/Resources/bin/cmux"
        self.fixture_root = self.make_fixture_root(args.fixture_root)
        self.proc: subprocess.Popen | None = None
        self.result: dict = {
            "tag": self.tag,
            "app_path": str(self.app_path),
            "socket_path": str(self.socket_path),
            "fixture_root": str(self.fixture_root),
            "fixture": {},
            "measurements": {},
            "budgets": {},
            "failures": [],
        }

    def default_app_path(self) -> pathlib.Path:
        return pathlib.Path.home() / (
            f"Library/Developer/Xcode/DerivedData/cmux-{self.tag_slug}/"
            f"Build/Products/Debug/cmux DEV {self.tag_slug}.app"
        )

    def make_fixture_root(self, fixture_root_arg: str) -> pathlib.Path:
        if fixture_root_arg:
            parent = pathlib.Path(fixture_root_arg).expanduser()
            parent.mkdir(parents=True, exist_ok=True)
            return pathlib.Path(tempfile.mkdtemp(prefix=f"cmux-switch-{self.tag_slug}-", dir=str(parent)))
        return pathlib.Path(tempfile.mkdtemp(prefix=f"cmux-switch-{self.tag_slug}-"))

    def check_paths(self) -> None:
        if not self.binary_path.exists():
            raise PerfFailure(f"app binary not found: {self.binary_path}")
        if not self.cli_path.exists():
            raise PerfFailure(f"cmux CLI not found: {self.cli_path}")

    def clean_persisted_state(self) -> None:
        app_support = pathlib.Path.home() / "Library/Application Support/cmux"
        bundle_id = f"com.cmuxterm.app.debug.{self.tag_id}"
        for suffix in ("", "-previous"):
            (app_support / f"session-{bundle_id}{suffix}.json").unlink(missing_ok=True)
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)
        self.debug_log_path.unlink(missing_ok=True)
        self.stdout_path.unlink(missing_ok=True)
        if self.fixture_root.exists():
            shutil.rmtree(self.fixture_root)
        self.fixture_root.mkdir(parents=True, exist_ok=True)

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
        ):
            env.pop(key, None)
        env.update(
            {
                "CMUX_SOCKET": str(self.socket_path),
                "CMUX_SOCKET_MODE": "automation",
                "CMUX_SOCKET_PATH": str(self.socket_path),
                "CMUXD_UNIX_PATH": str(self.cmuxd_socket_path),
                "CMUX_DEBUG_LOG": str(self.debug_log_path),
            }
        )
        return env

    def cli_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["CMUX_SOCKET"] = str(self.socket_path)
        env["CMUX_SOCKET_PATH"] = str(self.socket_path)
        env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "30"
        return env

    def launch(self) -> float:
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
        if not self.wait_for_socket(timeout_s=self.args.launch_timeout):
            raise PerfFailure(f"socket not ready after {self.args.launch_timeout}s")
        elapsed = rounded_ms(now_ms() - start)
        self.result["measurements"]["launch_socket_ready_ms"] = elapsed
        return elapsed

    def wait_for_socket(self, timeout_s: float) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if self.proc and self.proc.poll() is not None:
                return False
            if self.socket_path.exists():
                try:
                    self.run_cli(["--json", "list-workspaces"], timeout=5)
                    return True
                except Exception:
                    pass
            time.sleep(0.1)
        return False

    def stop_app(self) -> None:
        proc = self.proc
        self.proc = None
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        subprocess.run(
            ["pkill", "-f", re.escape(f"cmux DEV {self.tag_slug}.app/Contents/MacOS/cmux DEV")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)

    def run_cli(self, args: list[str], input_text: str | None = None, timeout: float = 60, check: bool = True) -> str:
        proc = subprocess.run(
            [str(self.cli_path)] + args,
            input=input_text,
            text=True,
            capture_output=True,
            env=self.cli_env(),
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            raise PerfFailure(
                "cmux command failed: "
                + " ".join(args)
                + f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )
        return proc.stdout.strip()

    def json_cli(self, args: list[str], timeout: float = 60) -> dict:
        return json.loads(self.run_cli(["--json"] + args, timeout=timeout))

    def ref(self, text: str, kind: str) -> str:
        found = re.findall(rf"\b{kind}:\d+\b", text)
        if not found:
            raise PerfFailure(f"missing {kind} ref in {text!r}")
        return found[0]

    def make_repo(self, index: int) -> pathlib.Path:
        repo = self.fixture_root / f"project-{index:02d}"
        repo.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        (repo / "README.md").write_text(f"# Project {index}\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=repo, stdout=subprocess.DEVNULL, check=True)
        subprocess.run(
            ["git", "-c", "user.name=cmux", "-c", "user.email=cmux@example.invalid", "commit", "-m", "seed"],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        (repo / "README.md").write_text(f"# Project {index}\n\nmodified\n", encoding="utf-8")
        return repo

    def make_browser_page(self, workspace_index: int, pane_index: int, surface_index: int) -> str:
        page_dir = self.fixture_root / "pages"
        page_dir.mkdir(parents=True, exist_ok=True)
        rows = "\n".join(
            f"<li>workspace {workspace_index:02d} pane {pane_index:02d} surface {surface_index:02d} row {i:03d}</li>"
            for i in range(self.args.browser_dom_rows)
        )
        script = """
<script>
let n = 0;
function tick() {
  document.body.dataset.tick = String(n++);
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
</script>
"""
        page = page_dir / f"workspace-{workspace_index:02d}-pane-{pane_index:02d}-surface-{surface_index:02d}.html"
        page.write_text(
            "<!doctype html><meta charset='utf-8'>"
            f"<title>cmux switch perf {workspace_index:02d}</title>"
            "<style>body{font-family:-apple-system;margin:18px}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}"
            "li{padding:4px;border:1px solid #ddd;list-style:none}</style>"
            f"<h1>Workspace {workspace_index:02d}</h1><ul class='grid'>{rows}</ul>{script}",
            encoding="utf-8",
        )
        return page.resolve().as_uri()

    def create_fixture(self) -> list[str]:
        existing = [w["ref"] for w in self.json_cli(["list-workspaces"]).get("workspaces", [])]
        guard_ws = self.ref(
            self.run_cli(["new-workspace", "--name", "switch-perf-guard", "--cwd", str(self.fixture_root)]),
            "workspace",
        )

        workspaces: list[str] = []
        terminal_surfaces = 0
        browser_surfaces = 0
        pane_directions = ["right", "down", "left", "up"]
        for workspace_index in range(1, self.args.workspace_count + 1):
            cwd = self.make_repo(workspace_index)
            ws = self.ref(
                self.run_cli(
                    [
                        "new-workspace",
                        "--name",
                        f"switch-perf-{workspace_index:02d}",
                        "--description",
                        f"workspace switch performance fixture {workspace_index:02d}",
                        "--cwd",
                        str(cwd),
                    ],
                    timeout=90,
                ),
                "workspace",
            )
            workspaces.append(ws)
            workspace_terminal_surfaces: list[str] = []

            for pane_index in range(1, self.args.panes_per_workspace):
                is_browser = pane_index <= self.args.browser_panes_per_workspace
                args = [
                    "new-pane",
                    "--workspace",
                    ws,
                    "--type",
                    "browser" if is_browser else "terminal",
                    "--direction",
                    pane_directions[pane_index % len(pane_directions)],
                ]
                if is_browser:
                    args += ["--url", self.make_browser_page(workspace_index, pane_index, 0)]
                self.run_cli(args, timeout=90)

            panes = self.json_cli(["list-panes", "--workspace", ws], timeout=90).get("panes", [])
            for pane_index, pane in enumerate(panes):
                pane_ref = pane["ref"]
                is_browser = 0 < pane_index <= self.args.browser_panes_per_workspace
                if is_browser:
                    browser_surfaces += len(pane.get("surface_refs", []))
                else:
                    terminal_surfaces += len(pane.get("surface_refs", []))
                    workspace_terminal_surfaces.extend(pane.get("surface_refs", []))
                for surface_index in range(1, self.args.surfaces_per_pane):
                    args = [
                        "new-surface",
                        "--workspace",
                        ws,
                        "--pane",
                        pane_ref,
                        "--type",
                        "browser" if is_browser else "terminal",
                    ]
                    if is_browser:
                        args += ["--url", self.make_browser_page(workspace_index, pane_index, surface_index)]
                    output = self.run_cli(args, timeout=90)
                    surface_ref = self.ref(output, "surface")
                    if is_browser:
                        browser_surfaces += 1
                    else:
                        terminal_surfaces += 1
                        workspace_terminal_surfaces.append(surface_ref)

            if self.args.terminal_scrollback_lines > 0:
                self.seed_terminal_scrollback(ws, workspace_terminal_surfaces)

        for ws in existing + [guard_ws]:
            self.run_cli(["close-workspace", "--workspace", ws], timeout=30, check=False)
        if workspaces:
            self.run_cli(["select-workspace", "--workspace", workspaces[0]], timeout=60, check=False)

        self.result["fixture"].update(
            {
                "workspaces": len(workspaces),
                "panes_per_workspace": self.args.panes_per_workspace,
                "surfaces_per_pane": self.args.surfaces_per_pane,
                "terminal_surfaces": terminal_surfaces,
                "browser_surfaces": browser_surfaces,
                "total_surfaces": terminal_surfaces + browser_surfaces,
            }
        )
        return workspaces

    def seed_terminal_scrollback(self, workspace: str, surfaces: list[str]) -> None:
        for surface in surfaces:
            command = (
                f"i=1; while [ $i -le {self.args.terminal_scrollback_lines} ]; do "
                "printf 'SWITCH_PERF %04d abcdefghijklmnopqrstuvwxyz\\n' \"$i\"; "
                "i=$((i+1)); done\n"
            )
            self.run_cli(["send", "--workspace", workspace, "--surface", surface, command], timeout=30, check=False)

    def read_debug_lines(self, offset: int, timeout_s: float) -> tuple[list[str], int]:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if self.debug_log_path.exists() and self.debug_log_path.stat().st_size > offset:
                data = self.debug_log_path.read_text(encoding="utf-8", errors="replace")
                return data[offset:].splitlines(), len(data)
            time.sleep(0.01)
        if self.debug_log_path.exists():
            data = self.debug_log_path.read_text(encoding="utf-8", errors="replace")
            return data[offset:].splitlines(), len(data)
        return [], offset

    def wait_for_switch_logs(self, offset: int, timeout_s: float) -> tuple[dict[str, float | int | str | None], int]:
        deadline = time.monotonic() + timeout_s
        cursor = offset
        switch_id: str | None = None
        handoff_ms: float | None = None
        handoff_reason = "missing"
        async_done_ms: float | None = None
        terminal_swiftui_visible_ms: float | None = None
        terminal_hosted_visible_ms: float | None = None
        terminal_portal_visible_ms: float | None = None
        browser_portal_visible_ms: float | None = None
        portal_priority_ms: float | None = None
        terminal_swiftui_visible_by_surface: dict[str, float] = {}
        terminal_hosted_visible_by_surface: dict[str, float] = {}
        terminal_portal_visible_by_hosted: dict[str, float] = {}
        browser_portal_visible_by_web: dict[str, float] = {}
        terminal_swiftui_visible_updates = 0
        terminal_hosted_visible_updates = 0
        terminal_portal_visible_updates = 0
        browser_portal_visible_updates = 0
        portal_priority_updates = 0
        last_interesting_at: float | None = None
        settle_s = self.args.visible_settle_ms / 1000.0

        def note_first_visible(seen: dict[str, float], token: str, value: float) -> None:
            seen.setdefault(token, value)

        def visible_max(seen: dict[str, float]) -> float | None:
            return max(seen.values()) if seen else None

        def visible_ready_value() -> float | None:
            if portal_priority_ms is not None:
                return portal_priority_ms
            values = [
                value for value in (
                    terminal_hosted_visible_ms,
                    terminal_portal_visible_ms,
                    browser_portal_visible_ms,
                )
                if value is not None
            ]
            if values:
                return max(values)
            return terminal_swiftui_visible_ms

        while time.monotonic() < deadline:
            chunk, cursor = self.read_debug_lines(cursor, timeout_s=0.05)
            if chunk:
                last_interesting_at = last_interesting_at or time.monotonic()
            for line in chunk:
                begin = re.search(r"ws\.switch\.begin id=(\d+)", line)
                if begin:
                    switch_id = begin.group(1)
                if switch_id:
                    complete = re.search(rf"ws\.handoff\.complete id={switch_id} dt=([0-9.]+)ms reason=([^ ]+)", line)
                    if complete:
                        handoff_ms = float(complete.group(1))
                        handoff_reason = complete.group(2)
                        last_interesting_at = time.monotonic()
                    async_done = re.search(rf"ws\.select\.asyncDone id={switch_id} dt=([0-9.]+)ms", line)
                    if async_done:
                        async_done_ms = float(async_done.group(1))
                        last_interesting_at = time.monotonic()
                    priority_ready = re.search(
                        rf"ws\.portal\.priority id={switch_id} dt=([0-9.]+)ms .* z=2 ",
                        line,
                    )
                    if priority_ready:
                        portal_priority_ms = float(priority_ready.group(1))
                        portal_priority_updates += 1
                        last_interesting_at = time.monotonic()
                    swiftui_visible = re.search(
                        rf"ws\.swiftui\.update id={switch_id} dt=([0-9.]+)ms surface=([^ ]+) .* visible=1",
                        line,
                    )
                    if swiftui_visible:
                        note_first_visible(
                            terminal_swiftui_visible_by_surface,
                            swiftui_visible.group(2),
                            float(swiftui_visible.group(1)),
                        )
                        terminal_swiftui_visible_ms = visible_max(terminal_swiftui_visible_by_surface)
                        terminal_swiftui_visible_updates += 1
                        last_interesting_at = time.monotonic()
                    hosted_visible = re.search(
                        rf"ws\.term\.visible id={switch_id} dt=([0-9.]+)ms surface=([^ ]+) transition=0->1",
                        line,
                    )
                    if hosted_visible:
                        note_first_visible(
                            terminal_hosted_visible_by_surface,
                            hosted_visible.group(2),
                            float(hosted_visible.group(1)),
                        )
                        terminal_hosted_visible_ms = visible_max(terminal_hosted_visible_by_surface)
                        terminal_hosted_visible_updates += 1
                        last_interesting_at = time.monotonic()
                    portal_visible = re.search(
                        rf"^\d{{2}}:\d{{2}}:\d{{2}}\.\d{{3}} portal\.sync\.result hosted=([^ ]+) "
                        rf".*switchId={switch_id} switchDt=([0-9.]+)ms .* hide=0 entryVisible=1",
                        line,
                    )
                    if portal_visible:
                        note_first_visible(
                            terminal_portal_visible_by_hosted,
                            portal_visible.group(1),
                            float(portal_visible.group(2)),
                        )
                        terminal_portal_visible_ms = visible_max(terminal_portal_visible_by_hosted)
                        terminal_portal_visible_updates += 1
                        last_interesting_at = time.monotonic()
                    browser_visible = re.search(
                        rf"^\d{{2}}:\d{{2}}:\d{{2}}\.\d{{3}} browser\.portal\.sync\.result web=([^ ]+) "
                        rf".*switchId={switch_id} switchDt=([0-9.]+)ms .* hide=0 entryVisible=1",
                        line,
                    )
                    if browser_visible:
                        note_first_visible(
                            browser_portal_visible_by_web,
                            browser_visible.group(1),
                            float(browser_visible.group(2)),
                        )
                        browser_portal_visible_ms = visible_max(browser_portal_visible_by_web)
                        browser_portal_visible_updates += 1
                        last_interesting_at = time.monotonic()
            if handoff_ms is not None and last_interesting_at is not None:
                if time.monotonic() - last_interesting_at >= settle_s:
                    return {
                        "switch_id": int(switch_id) if switch_id else None,
                        "handoff_ms": handoff_ms,
                        "handoff_reason": handoff_reason,
                        "async_done_ms": async_done_ms,
                        "visible_ready_ms": visible_ready_value(),
                        "terminal_swiftui_visible_ms": terminal_swiftui_visible_ms,
                        "terminal_hosted_visible_ms": terminal_hosted_visible_ms,
                        "terminal_portal_visible_ms": terminal_portal_visible_ms,
                        "browser_portal_visible_ms": browser_portal_visible_ms,
                        "portal_priority_ms": portal_priority_ms,
                        "terminal_swiftui_visible_updates": terminal_swiftui_visible_updates,
                        "terminal_hosted_visible_updates": terminal_hosted_visible_updates,
                        "terminal_portal_visible_updates": terminal_portal_visible_updates,
                        "browser_portal_visible_updates": browser_portal_visible_updates,
                        "portal_priority_updates": portal_priority_updates,
                        "terminal_swiftui_visible_first_count": len(terminal_swiftui_visible_by_surface),
                        "terminal_hosted_visible_first_count": len(terminal_hosted_visible_by_surface),
                        "terminal_portal_visible_first_count": len(terminal_portal_visible_by_hosted),
                        "browser_portal_visible_first_count": len(browser_portal_visible_by_web),
                    }, cursor
            time.sleep(0.01)
        return {
            "switch_id": int(switch_id) if switch_id else None,
            "handoff_ms": handoff_ms,
            "handoff_reason": handoff_reason,
            "async_done_ms": async_done_ms,
            "visible_ready_ms": visible_ready_value(),
            "terminal_swiftui_visible_ms": terminal_swiftui_visible_ms,
            "terminal_hosted_visible_ms": terminal_hosted_visible_ms,
            "terminal_portal_visible_ms": terminal_portal_visible_ms,
            "browser_portal_visible_ms": browser_portal_visible_ms,
            "portal_priority_ms": portal_priority_ms,
            "terminal_swiftui_visible_updates": terminal_swiftui_visible_updates,
            "terminal_hosted_visible_updates": terminal_hosted_visible_updates,
            "terminal_portal_visible_updates": terminal_portal_visible_updates,
            "browser_portal_visible_updates": browser_portal_visible_updates,
            "portal_priority_updates": portal_priority_updates,
            "terminal_swiftui_visible_first_count": len(terminal_swiftui_visible_by_surface),
            "terminal_hosted_visible_first_count": len(terminal_hosted_visible_by_surface),
            "terminal_portal_visible_first_count": len(terminal_portal_visible_by_hosted),
            "browser_portal_visible_first_count": len(browser_portal_visible_by_web),
        }, cursor

    def benchmark_switches(self, workspaces: list[str]) -> None:
        if len(workspaces) < 2:
            raise PerfFailure("workspace switch benchmark requires at least two workspaces")

        samples: list[dict[str, float | int | str | None]] = []
        offset = self.debug_log_path.stat().st_size if self.debug_log_path.exists() else 0
        sequence = []
        for _ in range(self.args.warmup_passes):
            sequence.extend(workspaces[1:] + list(reversed(workspaces[:-1])))
        for _ in range(self.args.measure_passes):
            sequence.extend(workspaces[1:] + list(reversed(workspaces[:-1])))

        warmup_count = self.args.warmup_passes * ((len(workspaces) - 1) * 2)
        for index, workspace in enumerate(sequence):
            start = now_ms()
            self.run_cli(["select-workspace", "--workspace", workspace], timeout=30)
            cli_ms = rounded_ms(now_ms() - start)
            parsed, offset = self.wait_for_switch_logs(offset, timeout_s=self.args.switch_log_timeout)
            sample = {
                "index": index,
                "phase": "warmup" if index < warmup_count else "measure",
                "workspace": workspace,
                "cli_roundtrip_ms": cli_ms,
                **parsed,
            }
            samples.append(sample)

        measured = [s for s in samples if s["phase"] == "measure"]
        cli_values = [float(s["cli_roundtrip_ms"]) for s in measured]
        handoff_values = [float(s["handoff_ms"]) for s in measured if s["handoff_ms"] is not None]
        async_values = [float(s["async_done_ms"]) for s in measured if s["async_done_ms"] is not None]
        visible_values = [float(s["visible_ready_ms"]) for s in measured if s["visible_ready_ms"] is not None]
        terminal_swiftui_values = [
            float(s["terminal_swiftui_visible_ms"])
            for s in measured
            if s["terminal_swiftui_visible_ms"] is not None
        ]
        terminal_hosted_values = [
            float(s["terminal_hosted_visible_ms"])
            for s in measured
            if s["terminal_hosted_visible_ms"] is not None
        ]
        terminal_portal_values = [
            float(s["terminal_portal_visible_ms"])
            for s in measured
            if s["terminal_portal_visible_ms"] is not None
        ]
        browser_portal_values = [
            float(s["browser_portal_visible_ms"])
            for s in measured
            if s["browser_portal_visible_ms"] is not None
        ]
        portal_priority_values = [
            float(s["portal_priority_ms"])
            for s in measured
            if s["portal_priority_ms"] is not None
        ]
        self.result["measurements"]["workspace_switch"] = {
            "samples": measured,
            "cli_roundtrip": summary(cli_values),
            "handoff": summary(handoff_values),
            "visible_ready": summary(visible_values),
            "terminal_swiftui_visible": summary(terminal_swiftui_values),
            "terminal_hosted_visible": summary(terminal_hosted_values),
            "terminal_portal_visible": summary(terminal_portal_values),
            "browser_portal_visible": summary(browser_portal_values),
            "portal_priority": summary(portal_priority_values),
            "async_done": summary(async_values),
            "missing_handoff_samples": len(measured) - len(handoff_values),
            "missing_visible_ready_samples": len(measured) - len(visible_values),
        }

    def apply_budgets(self) -> None:
        switch = self.result["measurements"].get("workspace_switch", {})
        handoff = switch.get("handoff", {})
        visible_ready = switch.get("visible_ready", {})
        cli = switch.get("cli_roundtrip", {})
        budgets = {
            "handoff_p95_ms": self.args.budget_handoff_p95_ms,
            "visible_ready_p95_ms": self.args.budget_visible_ready_p95_ms,
            "cli_roundtrip_p95_ms": self.args.budget_cli_roundtrip_p95_ms,
            "missing_handoff_samples": 0,
            "missing_visible_ready_samples": 0,
        }
        failures: list[str] = []

        if switch.get("missing_handoff_samples", 0) > budgets["missing_handoff_samples"]:
            failures.append(f"missing_handoff_samples: {switch.get('missing_handoff_samples')} > 0")
        if switch.get("missing_visible_ready_samples", 0) > budgets["missing_visible_ready_samples"]:
            failures.append(f"missing_visible_ready_samples: {switch.get('missing_visible_ready_samples')} > 0")
        if handoff.get("p95_ms", 0) > budgets["handoff_p95_ms"]:
            failures.append(f"handoff.p95_ms: {handoff.get('p95_ms')} > {budgets['handoff_p95_ms']}")
        if visible_ready.get("p95_ms", 0) > budgets["visible_ready_p95_ms"]:
            failures.append(
                f"visible_ready.p95_ms: {visible_ready.get('p95_ms')} > {budgets['visible_ready_p95_ms']}"
            )
        if budgets["cli_roundtrip_p95_ms"] > 0 and cli.get("p95_ms", 0) > budgets["cli_roundtrip_p95_ms"]:
            failures.append(f"cli_roundtrip.p95_ms: {cli.get('p95_ms')} > {budgets['cli_roundtrip_p95_ms']}")

        self.result["budgets"] = budgets
        self.result["failures"] = failures

    def run(self) -> dict:
        self.check_paths()
        self.stop_app()
        self.clean_persisted_state()
        try:
            self.launch()
            workspaces = self.create_fixture()
            self.benchmark_switches(workspaces)
            self.apply_budgets()
            return self.result
        finally:
            self.stop_app()
            if not self.args.keep_fixture and self.fixture_root.exists():
                shutil.rmtree(self.fixture_root, ignore_errors=True)


def write_junit(result: dict, path: pathlib.Path) -> None:
    failures = result.get("failures", [])
    suite = ET.Element(
        "testsuite",
        {
            "name": "WorkspaceSwitchPerformance",
            "tests": "1",
            "failures": "1" if failures else "0",
        },
    )
    case = ET.SubElement(suite, "testcase", {"name": "workspace_switch_performance"})
    if failures:
        failure = ET.SubElement(case, "failure", {"message": "; ".join(failures)})
        failure.text = json.dumps(result, indent=2, sort_keys=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def print_summary(result: dict) -> None:
    fixture = result.get("fixture", {})
    switch = result.get("measurements", {}).get("workspace_switch", {})
    print("workspace switch performance")
    print(
        "  fixture: "
        f"workspaces={fixture.get('workspaces')} panes/workspace={fixture.get('panes_per_workspace')} "
        f"surfaces/pane={fixture.get('surfaces_per_pane')} browsers={fixture.get('browser_surfaces')} "
        f"terminals={fixture.get('terminal_surfaces')}"
    )
    print(f"  launch_socket_ready_ms={result.get('measurements', {}).get('launch_socket_ready_ms')}")
    print(f"  cli_roundtrip={switch.get('cli_roundtrip')}")
    print(f"  handoff={switch.get('handoff')}")
    print(f"  visible_ready={switch.get('visible_ready')}")
    print(f"  terminal_swiftui_visible={switch.get('terminal_swiftui_visible')}")
    print(f"  terminal_hosted_visible={switch.get('terminal_hosted_visible')}")
    print(f"  terminal_portal_visible={switch.get('terminal_portal_visible')}")
    print(f"  browser_portal_visible={switch.get('browser_portal_visible')}")
    print(f"  portal_priority={switch.get('portal_priority')}")
    print(f"  async_done={switch.get('async_done')}")
    if switch.get("missing_handoff_samples"):
        print(f"  missing_handoff_samples={switch.get('missing_handoff_samples')}")
    if switch.get("missing_visible_ready_samples"):
        print(f"  missing_visible_ready_samples={switch.get('missing_visible_ready_samples')}")
    failures = result.get("failures", [])
    if failures:
        print("  budget_failures:")
        for failure in failures:
            print(f"    - {failure}")
    else:
        print("  budgets: pass")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark switching between heavy cmux workspaces.")
    parser.add_argument("--tag", default="switchperf", help="Tagged debug app name built by scripts/reload.sh.")
    parser.add_argument("--app-path", default="", help="Override app bundle path.")
    parser.add_argument("--fixture-root", default="", help="Directory for temporary fixture files.")
    parser.add_argument("--output", default="", help="Write JSON results to this path.")
    parser.add_argument("--junit", default="", help="Write JUnit XML results to this path.")
    parser.add_argument("--keep-fixture", action="store_true", help="Keep fixture directory after the run.")
    parser.add_argument("--no-fail-budget", action="store_true", help="Print budget failures without exiting non-zero.")

    parser.add_argument("--workspace-count", type=int, default=8)
    parser.add_argument("--panes-per-workspace", type=int, default=6)
    parser.add_argument("--surfaces-per-pane", type=int, default=2)
    parser.add_argument("--browser-panes-per-workspace", type=int, default=3)
    parser.add_argument("--browser-dom-rows", type=int, default=360)
    parser.add_argument("--terminal-scrollback-lines", type=int, default=400)
    parser.add_argument("--warmup-passes", type=int, default=1)
    parser.add_argument("--measure-passes", type=int, default=3)

    parser.add_argument("--launch-timeout", type=float, default=45)
    parser.add_argument("--switch-log-timeout", type=float, default=5)
    parser.add_argument("--visible-settle-ms", type=float, default=120)
    parser.add_argument("--budget-handoff-p95-ms", type=float, default=100)
    parser.add_argument("--budget-visible-ready-p95-ms", type=float, default=100)
    parser.add_argument("--budget-cli-roundtrip-p95-ms", type=float, default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runner = WorkspaceSwitchPerfRunner(args)
    try:
        result = runner.run()
    except Exception as exc:
        result = runner.result
        result["failures"] = result.get("failures", []) + [str(exc)]
        if args.output:
            output = pathlib.Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
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
