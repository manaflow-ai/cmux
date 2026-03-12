#!/usr/bin/env python3
"""Docker integration: prove cmux ssh applies Ghostty ssh-env/ssh-terminfo niceties."""

from __future__ import annotations

import glob
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
DOCKER_SSH_HOST = os.environ.get("CMUX_SSH_TEST_DOCKER_HOST", "127.0.0.1")
DOCKER_PUBLISH_ADDR = os.environ.get("CMUX_SSH_TEST_DOCKER_BIND_ADDR", "127.0.0.1")
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_ESCAPE_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    probe = _run(["docker", "info"], check=False)
    return probe.returncode == 0


def _parse_host_port(docker_port_output: str) -> int:
    text = docker_port_output.strip()
    if not text:
        raise cmuxError("docker port output was empty")
    return int(text.split(":")[-1])


def _shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _ssh_run(host: str, host_port: int, key_path: Path, script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return _run(
        [
            "ssh",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=5",
            "-p",
            str(host_port),
            "-i",
            str(key_path),
            host,
            f"sh -lc {_shell_single_quote(script)}",
        ],
        check=check,
    )


def _wait_for_ssh(host: str, host_port: int, key_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = _ssh_run(host, host_port, key_path, "echo ready", check=False)
        if probe.returncode == 0 and "ready" in probe.stdout:
            return
        time.sleep(0.5)
    raise cmuxError("Timed out waiting for SSH server in docker fixture to become ready")


def _wait_remote_connected(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return last_status
        time.sleep(0.4)
    raise cmuxError(f"Remote did not reach connected+ready state: {last_status}")


def _is_terminal_surface_not_found(exc: Exception) -> bool:
    return "terminal surface not found" in str(exc).lower()


def _read_probe_value(client: cmux, surface_id: str, command: str, timeout: float = 20.0) -> str:
    token = f"__CMUX_PROBE_{secrets.token_hex(6)}__"
    client.send_surface(surface_id, f"{command}; printf '{token}%s\\n' $?\\n")

    pattern = re.compile(re.escape(token) + r"([^\r\n]*)")
    deadline = time.time() + timeout
    saw_missing_surface = False
    while time.time() < deadline:
        try:
            text = client.read_terminal_text(surface_id)
        except cmuxError as exc:
            if _is_terminal_surface_not_found(exc):
                saw_missing_surface = True
                time.sleep(0.2)
                continue
            raise
        matches = pattern.findall(text)
        for raw in reversed(matches):
            value = raw.strip()
            if value and value != "%s" and "$(" not in value and "printf" not in value:
                return value
        time.sleep(0.2)

    if saw_missing_surface:
        raise cmuxError("terminal surface not found")
    raise cmuxError(f"Timed out waiting for probe token for command: {command}")


def _read_probe_payload(client: cmux, surface_id: str, payload_command: str, timeout: float = 20.0) -> str:
    token = f"__CMUX_PAYLOAD_{secrets.token_hex(6)}__"
    client.send_surface(surface_id, f"printf '{token}%s\\n' \"$({payload_command})\"\\n")

    pattern = re.compile(re.escape(token) + r"([^\r\n]*)")
    deadline = time.time() + timeout
    saw_missing_surface = False
    while time.time() < deadline:
        try:
            text = client.read_terminal_text(surface_id)
        except cmuxError as exc:
            if _is_terminal_surface_not_found(exc):
                saw_missing_surface = True
                time.sleep(0.2)
                continue
            raise
        matches = pattern.findall(text)
        for raw in reversed(matches):
            value = raw.strip()
            if value and value != "%s" and "$(" not in value and "printf" not in value:
                return value
        time.sleep(0.2)

    if saw_missing_surface:
        raise cmuxError("terminal surface not found")
    raise cmuxError(f"Timed out waiting for payload token for command: {payload_command}")


def _wait_for(pred, timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_for_pane_count(client: cmux, minimum_count: int, timeout: float = 8.0) -> list[str]:
    deadline = time.time() + timeout
    last: list[str] = []
    while time.time() < deadline:
        last = [pid for _idx, pid, _count, _focused in client.list_panes()]
        if len(last) >= minimum_count:
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for pane count >= {minimum_count}; saw {len(last)} panes: {last}")


def _surface_text_scrollback(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return str(payload.get("text") or "")


def _clean_line(raw: str) -> str:
    line = OSC_ESCAPE_RE.sub("", raw)
    line = ANSI_ESCAPE_RE.sub("", line)
    line = line.replace("\r", "")
    return line.strip()


def _surface_text_scrollback_lines(client: cmux, workspace_id: str, surface_id: str) -> list[str]:
    return [_clean_line(raw) for raw in _surface_text_scrollback(client, workspace_id, surface_id).splitlines()]


def _scrollback_has_all_lines(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    lines: list[str],
) -> bool:
    available = set(_surface_text_scrollback_lines(client, workspace_id, surface_id))
    return all(line in available for line in lines)


def _wait_surface_contains(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    token: str,
    *,
    timeout: float = 20.0,
) -> None:
    deadline = time.time() + timeout
    saw_missing_surface = False
    while time.time() < deadline:
        try:
            if token in _surface_text_scrollback(client, workspace_id, surface_id):
                return
        except cmuxError as exc:
            if _is_terminal_surface_not_found(exc):
                saw_missing_surface = True
                time.sleep(0.2)
                continue
            raise
        time.sleep(0.2)

    if saw_missing_surface:
        raise cmuxError("terminal surface not found")
    raise cmuxError(f"Timed out waiting for terminal token: {token}")


def _layout_panes(client: cmux) -> list[dict]:
    layout_payload = client.layout_debug() or {}
    layout = layout_payload.get("layout") or {}
    return list(layout.get("panes") or [])


def _pane_extent(client: cmux, pane_id: str, axis: str) -> float:
    panes = _layout_panes(client)
    for pane in panes:
        pid = str(pane.get("paneId") or pane.get("pane_id") or "")
        if pid != pane_id:
            continue
        frame = pane.get("frame") or {}
        return float(frame.get(axis) or 0.0)
    raise cmuxError(f"Pane {pane_id} missing from debug layout panes: {panes}")


def _pane_for_surface(client: cmux, surface_id: str) -> str:
    target_id = str(client._resolve_surface_id(surface_id))
    for _idx, pane_id, _count, _focused in client.list_panes():
        rows = client.list_pane_surfaces(pane_id)
        for _row_idx, sid, _title, _selected in rows:
            try:
                candidate_id = str(client._resolve_surface_id(sid))
            except cmuxError:
                continue
            if candidate_id == target_id:
                return pane_id
    raise cmuxError(f"Surface {surface_id} is not present in current workspace panes")


def _pick_resize_direction_for_pane(client: cmux, pane_ids: list[str], target_pane: str) -> tuple[str, str]:
    panes = [p for p in _layout_panes(client) if str(p.get("paneId") or p.get("pane_id") or "") in pane_ids]
    if len(panes) < 2:
        raise cmuxError(f"Need >=2 panes for resize test, got {panes}")

    def x_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("x") or 0.0)

    def y_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("y") or 0.0)

    x_span = max(x_of(p) for p in panes) - min(x_of(p) for p in panes)
    y_span = max(y_of(p) for p in panes) - min(y_of(p) for p in panes)

    if x_span >= y_span:
        left_pane = min(panes, key=x_of)
        left_id = str(left_pane.get("paneId") or left_pane.get("pane_id") or "")
        return ("right" if target_pane == left_id else "left"), "width"

    top_pane = min(panes, key=y_of)
    top_id = str(top_pane.get("paneId") or top_pane.get("pane_id") or "")
    return ("down" if target_pane == top_id else "up"), "height"


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0
    if shutil.which("infocmp") is None:
        print("SKIP: local infocmp is not available (required for ssh-terminfo)")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-shell-integration-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-shell-{secrets.token_hex(4)}"
    workspace_id = ""

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            container_name,
            "-e",
            f"AUTHORIZED_KEY={pubkey}",
            "-p",
            f"{DOCKER_PUBLISH_ADDR}::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = f"root@{DOCKER_SSH_HOST}"
        if shutil.which("ghostty") is not None:
            _run(["ghostty", "+ssh-cache", f"--remove={host}"], check=False)
        _wait_for_ssh(host, host_ssh_port, key_path)

        pre = _ssh_run(host, host_ssh_port, key_path, "if infocmp xterm-ghostty >/dev/null 2>&1; then echo present; else echo missing; fi")
        _must("missing" in pre.stdout, f"Fresh container should not have xterm-ghostty terminfo preinstalled: {pre.stdout!r}")

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name",
                    "docker-ssh-shell-integration",
                    "--port",
                    str(host_ssh_port),
                    "--identity",
                    str(key_path),
                    "--ssh-option",
                    "UserKnownHostsFile=/dev/null",
                    "--ssh-option",
                    "StrictHostKeyChecking=no",
                ],
            )
            workspace_id = str(payload.get("workspace_id") or "")
            workspace_ref = str(payload.get("workspace_ref") or "")
            if not workspace_id and workspace_ref.startswith("workspace:"):
                listed = client._call("workspace.list", {}) or {}
                for row in listed.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref:
                        workspace_id = str(row.get("id") or "")
                        break
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")

            _wait_remote_connected(client, workspace_id, timeout=45.0)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]
            terminal_text = client.read_terminal_text(surface_id)
            _must(
                "Reconstructed via infocmp" not in terminal_text,
                "ssh-terminfo bootstrap should not leak raw infocmp output into the interactive shell",
            )
            _must(
                "Warning: Failed to install terminfo." not in terminal_text,
                "ssh shell bootstrap should not show a false terminfo failure warning",
            )

            try:
                term_value = _read_probe_payload(client, surface_id, "printf '%s' \"$TERM\"")
                terminfo_state = _read_probe_value(client, surface_id, "infocmp xterm-ghostty >/dev/null 2>&1")
            except cmuxError as exc:
                if _is_terminal_surface_not_found(exc):
                    print("SKIP: terminal surface unavailable for shell integration probes")
                    return 0
                raise
            _must(terminfo_state in {"0", "1"}, f"unexpected terminfo probe exit status: {terminfo_state!r}")
            if terminfo_state == "0":
                _must(
                    term_value == "xterm-ghostty",
                    f"when terminfo install succeeds, TERM should remain xterm-ghostty (got {term_value!r})",
                )
            else:
                _must(
                    term_value == "xterm-256color",
                    f"when terminfo is unavailable, ssh-env fallback should use TERM=xterm-256color (got {term_value!r})",
                )

            colorterm_value = _read_probe_payload(client, surface_id, "printf '%s' \"${COLORTERM:-}\"")
            _must(
                colorterm_value == "truecolor",
                f"ssh-env should propagate COLORTERM=truecolor, got: {colorterm_value!r}",
            )

            term_program = _read_probe_payload(client, surface_id, "printf '%s' \"${TERM_PROGRAM:-}\"")
            _must(
                term_program == "ghostty",
                f"ssh-env should propagate TERM_PROGRAM=ghostty when AcceptEnv allows it, got: {term_program!r}",
            )

            term_program_version = _read_probe_payload(client, surface_id, "printf '%s' \"${TERM_PROGRAM_VERSION:-}\"")
            _must(bool(term_program_version), "ssh-env should propagate non-empty TERM_PROGRAM_VERSION")

            ls_stamp = secrets.token_hex(4)
            ls_entries = [f"CMUX_RESIZE_LS_{ls_stamp}_{index:02d}" for index in range(1, 17)]
            ls_start = f"CMUX_RESIZE_LS_START_{ls_stamp}"
            ls_end = f"CMUX_RESIZE_LS_END_{ls_stamp}"
            names = " ".join(ls_entries)
            ls_script = (
                "tmpdir=$(mktemp -d); "
                f"echo {ls_start}; "
                f"for name in {names}; do touch \"$tmpdir/$name\"; done; "
                "ls -1 \"$tmpdir\"; "
                f"echo {ls_end}; "
                "rm -rf \"$tmpdir\""
            )
            client.send_surface(surface_id, f"{ls_script}\n")
            _wait_surface_contains(client, workspace_id, surface_id, ls_end)
            pre_resize_scrollback_lines = _surface_text_scrollback_lines(client, workspace_id, surface_id)
            _must(
                all(line in pre_resize_scrollback_lines for line in ls_entries),
                "pre-resize scrollback missing ls output fixture lines",
            )
            pre_resize_anchors = [ls_entries[0], ls_entries[len(ls_entries) // 2], ls_entries[-1]]
            _must(
                len(pre_resize_anchors) == 3,
                f"pre-resize scrollback missing anchor lines: {pre_resize_anchors}",
            )
            pre_resize_visible = client.read_terminal_text(surface_id)
            pre_visible_lines = [line for line in ls_entries if line in pre_resize_visible]
            _must(
                len(pre_visible_lines) >= 2,
                "pre-resize viewport did not contain enough reference lines for continuity checks",
            )

            client.select_workspace(workspace_id)
            client.activate_app()
            pane_count_before_split = len(client.list_panes())
            client.simulate_shortcut("cmd+d")
            pane_ids = _wait_for_pane_count(client, pane_count_before_split + 1, timeout=8.0)

            pane_id = _pane_for_surface(client, surface_id)
            resize_direction, resize_axis = _pick_resize_direction_for_pane(client, pane_ids, pane_id)
            opposite_direction = {
                "left": "right",
                "right": "left",
                "up": "down",
                "down": "up",
            }[resize_direction]
            expected_sign_by_direction = {
                resize_direction: +1,
                opposite_direction: -1,
            }

            resize_sequence = [resize_direction, opposite_direction] * 8
            current_extent = _pane_extent(client, pane_id, resize_axis)
            for index, direction in enumerate(resize_sequence, start=1):
                resize_result = client._call(
                    "pane.resize",
                    {
                        "workspace_id": workspace_id,
                        "pane_id": pane_id,
                        "direction": direction,
                        "amount": 80,
                    },
                ) or {}
                _must(
                    str(resize_result.get("pane_id") or "") == pane_id,
                    f"pane.resize response missing expected pane_id: {resize_result}",
                )
                if expected_sign_by_direction[direction] > 0:
                    _wait_for(lambda: _pane_extent(client, pane_id, resize_axis) > current_extent + 1.0, timeout_s=5.0)
                else:
                    _wait_for(lambda: _pane_extent(client, pane_id, resize_axis) < current_extent - 1.0, timeout_s=5.0)
                current_extent = _pane_extent(client, pane_id, resize_axis)
                _must(
                    _scrollback_has_all_lines(client, workspace_id, surface_id, pre_resize_anchors),
                    f"resize iteration {index} lost pre-resize scrollback anchors",
                )

            post_resize_visible = client.read_terminal_text(surface_id)
            visible_overlap = [line for line in pre_visible_lines if line in post_resize_visible]
            _must(
                bool(visible_overlap),
                f"resize lost all pre-resize visible lines from viewport: {pre_visible_lines}",
            )

            resize_post_token = f"CMUX_RESIZE_POST_{secrets.token_hex(6)}"
            client.send_surface(surface_id, f"echo {resize_post_token}\n")
            _wait_surface_contains(client, workspace_id, surface_id, resize_post_token)

            scrollback_lines = _surface_text_scrollback_lines(client, workspace_id, surface_id)
            _must(
                all(anchor in scrollback_lines for anchor in pre_resize_anchors),
                "terminal scrollback lost pre-resize lines after pane resize",
            )
            _must(
                resize_post_token in scrollback_lines,
                f"terminal scrollback missing post-resize token after pane resize: {resize_post_token}",
            )

            try:
                client.close_workspace(workspace_id)
                workspace_id = ""
            except Exception:
                pass

        print(
            "PASS: cmux ssh enables Ghostty shell integration niceties and preserves pre-resize terminal content "
            f"(TERM={term_value}, COLORTERM={colorterm_value}, TERM_PROGRAM={term_program})"
        )
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
