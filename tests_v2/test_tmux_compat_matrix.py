#!/usr/bin/env python3
"""Regression: tmux compatibility command matrix (implemented + explicit not-supported)."""

import glob
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, List, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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


def _run_cli(cli: str, args: List[str], *, expect_ok: bool = True) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if expect_ok and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc


def _pane_selected_surface(c: cmux, pane_id: str) -> str:
    rows = c.list_pane_surfaces(pane_id)
    for _idx, sid, _title, selected in rows:
        if selected:
            return sid
    if rows:
        return rows[0][1]
    raise cmuxError(f"pane {pane_id} has no surfaces")


def _pane_surface_ids(c: cmux, pane_id: str) -> List[str]:
    rows = c.list_pane_surfaces(pane_id)
    return [sid for _idx, sid, _title, _selected in rows]


def _surface_has(c: cmux, workspace_id: str, surface_id: str, token: str) -> bool:
    payload = c._call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True}) or {}
    return token in str(payload.get("text") or "")


def _layout_panes(c: cmux) -> List[dict]:
    layout_payload = c.layout_debug() or {}
    layout = layout_payload.get("layout") or {}
    panes = layout.get("panes") or []
    return list(panes)


def _pane_extent(c: cmux, pane_id: str, axis: str) -> float:
    panes = _layout_panes(c)
    for pane in panes:
        pid = str(pane.get("paneId") or pane.get("pane_id") or "")
        if pid != pane_id:
            continue
        frame = pane.get("frame") or {}
        return float(frame.get(axis) or 0.0)
    raise cmuxError(f"Pane {pane_id} missing from debug layout panes: {panes}")


def _pick_resize_target(c: cmux, pane_ids: List[str]) -> Tuple[str, str, str]:
    panes = [p for p in _layout_panes(c) if str(p.get("paneId") or p.get("pane_id") or "") in pane_ids]
    if len(panes) < 2:
        raise cmuxError(f"Need >=2 panes for resize test, got {panes}")

    def x_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("x") or 0.0)

    def y_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("y") or 0.0)

    x_span = max(x_of(p) for p in panes) - min(x_of(p) for p in panes)
    y_span = max(y_of(p) for p in panes) - min(y_of(p) for p in panes)

    if x_span >= y_span:
        target = min(panes, key=x_of)
        return str(target.get("paneId") or target.get("pane_id") or ""), "-R", "width"

    target = min(panes, key=y_of)
    return str(target.get("paneId") or target.get("pane_id") or ""), "-D", "height"


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        for method in [
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "surface.clear_history",
        ]:
            _must(method in methods, f"Missing capability {method!r}")

        ws = c.new_workspace()
        c.select_workspace(ws)
        _ = c.new_split("right")
        time.sleep(0.2)

        panes = [pid for _pidx, pid, _count, _focused in c.list_panes()]
        _must(len(panes) >= 2, f"Expected >=2 panes, got {panes}")
        p1, p2 = panes[0], panes[1]

        s1 = _pane_selected_surface(c, p1)
        s2 = _pane_selected_surface(c, p2)

        capture_token = f"TMUX_CAPTURE_{stamp}"
        c.send_surface(s1, f"echo {capture_token}\n")
        _wait_for(lambda: _surface_has(c, ws, s1, capture_token))

        cap = _run_cli(cli, ["capture-pane", "--workspace", ws, "--surface", s1, "--scrollback"])
        _must(capture_token in cap.stdout, f"capture-pane missing token: {cap.stdout!r}")

        pipe_file = Path(tempfile.gettempdir()) / f"cmux_pipe_pane_{stamp}.log"
        _run_cli(cli, ["pipe-pane", "--workspace", ws, "--surface", s1, "--command", f"cat > {pipe_file}"])
        piped = pipe_file.read_text() if pipe_file.exists() else ""
        _must(capture_token in piped, f"pipe-pane output missing token: {piped!r}")

        wait_name = f"tmux_wait_{stamp}"
        waiter = _run_cli(cli, ["wait-for", wait_name, "--timeout", "5"], expect_ok=False)
        _must(waiter.returncode != 0, "wait-for without signal should time out when run synchronously in test")
        signaler = subprocess.Popen(
            [cli, "--socket", SOCKET_PATH, "wait-for", wait_name, "--timeout", "5"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={k: v for k, v in os.environ.items() if k not in {"CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"}},
        )
        time.sleep(0.2)
        _run_cli(cli, ["wait-for", "-S", wait_name])
        out, err = signaler.communicate(timeout=5)
        _must(signaler.returncode == 0, f"wait-for signal/wait failed: out={out!r} err={err!r}")

        title = f"tmux-title-{stamp}"
        _run_cli(cli, ["rename-window", "--workspace", ws, title])
        find = _run_cli(cli, ["find-window", title])
        _must(title in find.stdout, f"find-window title search failed: {find.stdout!r}")

        ws2 = c.new_workspace()
        ws3 = c.new_workspace()
        c.select_workspace(ws)
        c.select_workspace(ws2)
        _run_cli(cli, ["last-window"])
        _must(c.current_workspace() == ws, f"last-window should navigate history back to ws={ws}")
        _run_cli(cli, ["next-window"])
        _must(c.current_workspace() == ws2, f"next-window should move to ws2={ws2}")
        _run_cli(cli, ["previous-window"])
        _must(c.current_workspace() == ws, f"previous-window should move back to ws={ws}")
        c.select_workspace(ws)

        pre_p1 = _pane_selected_surface(c, p1)
        pre_p2 = _pane_selected_surface(c, p2)
        _run_cli(cli, ["swap-pane", "--workspace", ws, "--pane", p1, "--target-pane", p2])
        post_p1_ids = set(_pane_surface_ids(c, p1))
        post_p2_ids = set(_pane_surface_ids(c, p2))
        _must(pre_p2 in post_p1_ids, f"swap-pane should move target surface into source pane (p1={post_p1_ids}, pre_p2={pre_p2})")
        _must(pre_p1 in post_p2_ids, f"swap-pane should move source surface into target pane (p2={post_p2_ids}, pre_p1={pre_p1})")

        s_break = _pane_selected_surface(c, p1)
        br = _run_cli(cli, ["--json", "--id-format", "both", "break-pane", "--workspace", ws, "--surface", s_break])
        br_payload = json.loads(br.stdout or "{}")
        ws_break = str(br_payload.get("workspace_id") or "")
        _must(bool(ws_break), f"break-pane returned invalid payload: {br_payload}")
        _must(ws_break in [wid for _idx, wid, _title, _sel in c.list_workspaces()], "break-pane workspace missing from list")
        _run_cli(cli, ["join-pane", "--workspace", ws, "--surface", s_break, "--target-pane", p2])
        _must(s_break in _pane_surface_ids(c, p2), f"join-pane should move broken surface into target pane {p2}")

        current_panes = [pid for _pidx, pid, _count, _focused in c.list_panes()]
        if len(current_panes) < 2:
            _ = c.new_split("right")
            time.sleep(0.2)
            current_panes = [pid for _pidx, pid, _count, _focused in c.list_panes()]
        _must(len(current_panes) >= 2, f"Expected >=2 panes after break/join, got {current_panes}")
        lp_source, lp_target = current_panes[0], current_panes[1]

        c.focus_pane(lp_source)
        c.focus_pane(lp_target)
        _run_cli(cli, ["last-pane", "--workspace", ws])
        ident = c.identify()
        focused = ident.get("focused") or {}
        _must(
            str(focused.get("pane_id") or "") == lp_source,
            f"last-pane should focus previous pane {lp_source}, focused={focused}",
        )

        _run_cli(cli, ["clear-history", "--workspace", ws, "--surface", s1])

        _run_cli(cli, ["set-hook", "workspace-created", "echo created"])
        hooks = _run_cli(cli, ["set-hook", "--list"])
        _must("workspace-created" in hooks.stdout, f"set-hook --list missing stored hook: {hooks.stdout!r}")
        _run_cli(cli, ["set-hook", "--unset", "workspace-created"])
        hooks2 = _run_cli(cli, ["set-hook", "--list"])
        _must("workspace-created" not in hooks2.stdout, f"set-hook --unset failed: {hooks2.stdout!r}")

        for cmd in (["popup"], ["bind-key", "C-b", "split-window"], ["unbind-key", "C-b"], ["copy-mode"]):
            proc = _run_cli(cli, cmd, expect_ok=False)
            merged = f"{proc.stdout}\n{proc.stderr}".lower()
            _must(proc.returncode != 0 and "not supported" in merged, f"Expected not_supported for {cmd}, got: {merged!r}")

        resize_target, resize_flag, resize_axis = _pick_resize_target(c, current_panes)
        pre_extent = _pane_extent(c, resize_target, resize_axis)
        _run_cli(cli, ["resize-pane", "--pane", resize_target, resize_flag, "--amount", "80"])
        _wait_for(
            lambda: _pane_extent(c, resize_target, resize_axis) > pre_extent + 1.0,
            timeout_s=3.0,
        )

        buffer_token = f"TMUX_BUFFER_{stamp}"
        _run_cli(cli, ["set-buffer", "--name", "tmuxbuf", f"echo {buffer_token}\\n"])
        buffers = _run_cli(cli, ["list-buffers"])
        _must("tmuxbuf" in buffers.stdout, f"list-buffers missing tmuxbuf: {buffers.stdout!r}")
        _run_cli(cli, ["paste-buffer", "--name", "tmuxbuf", "--workspace", ws, "--surface", s1])
        _wait_for(lambda: _surface_has(c, ws, s1, buffer_token))

        respawn_token = f"TMUX_RESPAWN_{stamp}"
        _run_cli(cli, ["respawn-pane", "--workspace", ws, "--surface", s1, "--command", f"echo {respawn_token}"])
        _wait_for(lambda: _surface_has(c, ws, s1, respawn_token))

        msg = f"tmux-message-{stamp}"
        shown = _run_cli(cli, ["display-message", "-p", msg])
        _must(msg in shown.stdout, f"display-message -p should print message: {shown.stdout!r}")

    print("PASS: tmux compatibility matrix commands are wired and tested")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
