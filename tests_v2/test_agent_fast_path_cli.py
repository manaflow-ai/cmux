#!/usr/bin/env python3
"""Behavior: agent fast-path CLI reads, sends, lists, and batches over one command surface."""

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred: Callable[[], bool], timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


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


def _run_agent(cli: str, args: List[str]) -> str:
    proc = _run_agent_process(cli, args)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"agent CLI failed ({' '.join(proc.args)}): {merged}")
    return proc.stdout


def _run_agent_process(cli: str, args: List[str]) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    cmd = [cli, "--socket", SOCKET_PATH, "agent"] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def _surface_has(c: cmux, workspace_id: str, surface_id: str, token: str) -> bool:
    payload = c._call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True}) or {}
    return token in str(payload.get("text") or "")


def _start_raw_byte_probe(c: cmux, workspace_id: str, surface_id: str, byte_count: int, label: str) -> None:
    raw_probe = (
        "python3 -c 'import sys,tty,termios; "
        "fd=sys.stdin.fileno(); "
        "old=termios.tcgetattr(fd); "
        f"print(\"{label}_READY\", flush=True); "
        "tty.setraw(fd); "
        f"data=sys.stdin.buffer.read({byte_count}); "
        "termios.tcsetattr(fd, termios.TCSADRAIN, old); "
        f"print(\"\\\\r\\\\n{label}_BYTES_\" + data.hex(), flush=True)'"
    )
    c._call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface_id, "text": raw_probe + "\r"})
    _wait_for(lambda: _surface_has(c, workspace_id, surface_id, f"{label}_READY"), timeout_s=5.0)


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        for method in ["pane.list", "surface.list", "surface.read_text", "surface.send_text"]:
            _must(method in methods, f"Missing capability {method!r}")

        created = c._call("workspace.create") or {}
        workspace_id = str(created.get("workspace_id") or "")
        _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": workspace_id})

        surfaces_payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
        surfaces = surfaces_payload.get("surfaces") or []
        _must(bool(surfaces), f"Expected at least one surface in workspace: {surfaces_payload}")
        surface_id = str(surfaces[0].get("id") or "")
        _must(bool(surface_id), f"surface.list returned surface without id: {surfaces_payload}")

        token = f"CMUX_AGENT_FAST_PATH_{stamp}"
        send_payload = json.loads(_run_agent(cli, [
            "send",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--enter",
            "--",
            f"echo {token}",
        ]) or "{}")
        _must(send_payload.get("ok") is True, f"agent send returned unexpected payload: {send_payload}")
        _wait_for(lambda: _surface_has(c, workspace_id, surface_id, token), timeout_s=5.0)

        capture_payload = json.loads(_run_agent(cli, [
            "capture",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--scrollback",
            "--lines",
            "80",
        ]) or "{}")
        _must(token in str(capture_payload.get("text") or ""), f"agent capture missing token: {capture_payload}")

        capture_with_terminator = json.loads(_run_agent(cli, [
            "capture",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--scrollback",
            "--lines",
            "80",
            "--",
        ]) or "{}")
        _must(token in str(capture_with_terminator.get("text") or ""), f"agent capture with -- missing token: {capture_with_terminator}")

        scrollback_after_terminator = _run_agent_process(cli, [
            "capture",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--lines",
            "80",
            "--",
            "--scrollback",
        ])
        scrollback_after_terminator_output = f"{scrollback_after_terminator.stdout}\n{scrollback_after_terminator.stderr}"
        _must(scrollback_after_terminator.returncode != 0, "agent capture should reject --scrollback after --")
        _must(
            "unexpected arguments: --scrollback" in scrollback_after_terminator_output,
            f"agent capture treated --scrollback after -- as a flag: {scrollback_after_terminator_output!r}",
        )

        raw_capture = _run_agent(cli, [
            "capture",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--scrollback",
            "--lines",
            "80",
            "--raw",
        ])
        _must(token in raw_capture, f"agent capture --raw missing token: {raw_capture!r}")
        bad_lines_flag_value = _run_agent_process(cli, [
            "capture",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--lines",
            "--raw",
        ])
        bad_lines_output = f"{bad_lines_flag_value.stdout}\n{bad_lines_flag_value.stderr}"
        _must(bad_lines_flag_value.returncode != 0, "agent capture should reject flag-looking --lines values")
        _must(
            "--lines must be an integer" in bad_lines_output,
            f"agent capture consumed --raw as a flag instead of --lines value: {bad_lines_output!r}",
        )

        panes_payload = json.loads(_run_agent(cli, ["list-panes", "--workspace", workspace_id]) or "{}")
        panes = panes_payload.get("panes") or []
        _must(bool(panes), f"agent list-panes returned no panes: {panes_payload}")
        panes_with_terminator = json.loads(_run_agent(cli, ["list-panes", "--workspace", workspace_id, "--"]) or "{}")
        _must(bool(panes_with_terminator.get("panes") or []), f"agent list-panes with -- returned no panes: {panes_with_terminator}")
        bad_key_proc = _run_agent_process(cli, ["send-key", "--workspace", workspace_id, "--surface", surface_id, "--", "a", "b"])
        _must(bad_key_proc.returncode != 0, "agent send-key should reject extra positional args")

        list_surfaces_payload = json.loads(_run_agent(cli, ["list-surfaces", "--workspace", workspace_id]) or "{}")
        listed_surfaces = list_surfaces_payload.get("surfaces") or []
        _must(any(str(item.get("id") or item.get("ref") or "") for item in listed_surfaces), f"agent list-surfaces returned no handles: {list_surfaces_payload}")
        list_surfaces_with_terminator = json.loads(_run_agent(cli, ["list-surfaces", "--workspace", workspace_id, "--"]) or "{}")
        listed_surfaces_with_terminator = list_surfaces_with_terminator.get("surfaces") or []
        _must(any(str(item.get("id") or item.get("ref") or "") for item in listed_surfaces_with_terminator), f"agent list-surfaces with -- returned no handles: {list_surfaces_with_terminator}")

        batch = json.dumps([
            {"op": "list-panes", "workspace": workspace_id},
            {"op": "capture", "workspace": workspace_id, "surface": surface_id, "scrollback": True, "lines": 80},
        ])
        batch_payload = json.loads(_run_agent(cli, ["batch", batch]) or "{}")
        results = batch_payload.get("results") or []
        _must(batch_payload.get("ok") is True and len(results) == 2, f"agent batch returned invalid payload: {batch_payload}")
        _must(token in str(results[1].get("result", {}).get("text") or ""), f"agent batch capture missing token: {batch_payload}")

        partial_batch = json.dumps([
            {"op": "list-panes", "workspace": workspace_id},
            {"op": "send", "workspace": workspace_id, "surface": surface_id},
        ])
        partial_proc = _run_agent_process(cli, ["batch", partial_batch])
        _must(partial_proc.returncode != 0, "agent batch with a bad operation should exit non-zero")
        partial_payload = json.loads(partial_proc.stdout or "{}")
        partial_results = partial_payload.get("results") or []
        _must(partial_payload.get("ok") is False and len(partial_results) == 2, f"agent partial batch returned invalid payload: {partial_payload}")
        _must(partial_results[0].get("ok") is True, f"agent partial batch should preserve prior successful result: {partial_payload}")
        _must(partial_results[1].get("ok") is False and partial_results[1].get("error"), f"agent partial batch should include per-op error: {partial_payload}")

        _start_raw_byte_probe(c, workspace_id, surface_id, 1, "RAW_LF")
        escaped_newline_payload = json.loads(_run_agent(cli, [
            "send",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--",
            "\\n",
        ]) or "{}")
        _must(escaped_newline_payload.get("ok") is True, f"agent escaped newline send returned unexpected payload: {escaped_newline_payload}")
        _wait_for(lambda: _surface_has(c, workspace_id, surface_id, "RAW_LF_BYTES_0a"), timeout_s=5.0)

        _start_raw_byte_probe(c, workspace_id, surface_id, 2, "RAW_DIRECT_LITERAL")
        direct_literal_payload = json.loads(_run_agent(cli, [
            "send",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--",
            "\\\\n",
        ]) or "{}")
        _must(direct_literal_payload.get("ok") is True, f"agent direct literal escape send returned unexpected payload: {direct_literal_payload}")
        _wait_for(lambda: _surface_has(c, workspace_id, surface_id, "RAW_DIRECT_LITERAL_BYTES_5c6e"), timeout_s=5.0)

        _start_raw_byte_probe(c, workspace_id, surface_id, 2, "RAW_BATCH_LITERAL")
        batch_literal = json.dumps([
            {"op": "send", "workspace": workspace_id, "surface": surface_id, "text": "\\n"},
        ])
        batch_literal_payload = json.loads(_run_agent(cli, ["batch", batch_literal]) or "{}")
        _must(batch_literal_payload.get("ok") is True, f"agent batch literal escape send returned unexpected payload: {batch_literal_payload}")
        _wait_for(lambda: _surface_has(c, workspace_id, surface_id, "RAW_BATCH_LITERAL_BYTES_5c6e"), timeout_s=5.0)

        _start_raw_byte_probe(c, workspace_id, surface_id, 1, "RAW_SPACE")
        space_payload = json.loads(_run_agent(cli, [
            "send",
            "--workspace",
            workspace_id,
            "--surface",
            surface_id,
            "--",
            " ",
        ]) or "{}")
        _must(space_payload.get("ok") is True, f"agent space send returned unexpected payload: {space_payload}")
        _wait_for(lambda: _surface_has(c, workspace_id, surface_id, "RAW_SPACE_BYTES_20"), timeout_s=5.0)

    print("PASS: agent fast-path CLI reads, sends, lists, and batches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
