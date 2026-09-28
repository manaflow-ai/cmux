"""Pointer, keyboard and window actions through cua-driver.

cua-driver holds the Accessibility and Screen Recording grants, so the fuzzer
itself needs none. Every call is `cua-driver call <tool> <json>` against the
daemon already running in the mini's GUI session.

This is deliberately thin: the dogfood runner owns the shared action layer,
and this module only adapts the few calls the fuzzer needs. When that layer
lands, `CuaDriver` should delegate to it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

_DEFAULT = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"


class CuaError(RuntimeError):
    pass


class CuaDriver:
    def __init__(self, binary: str | None = None, *, timeout: float = 20.0) -> None:
        self.binary = binary or os.environ.get("CMUX_FUZZ_CUA_DRIVER") or shutil.which("cua-driver") or _DEFAULT
        self.timeout = timeout

    def available(self) -> bool:
        return Path(self.binary).exists()

    def call(self, tool: str, args: dict | None = None, *, timeout: float | None = None) -> dict:
        proc = subprocess.run(
            [self.binary, "call", tool, json.dumps(args or {})],
            capture_output=True,
            text=True,
            timeout=timeout or self.timeout,
        )
        if proc.returncode != 0:
            raise CuaError(f"{tool}: exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:400]}")
        text = proc.stdout.strip()
        try:
            return json.loads(text) if text else {}
        except json.JSONDecodeError:
            return {"text": text}

    def ensure_daemon(self) -> None:
        status = subprocess.run([self.binary, "status"], capture_output=True, text=True, timeout=10)
        if "is running" in status.stdout:
            return
        # LaunchServices start keeps the daemon's own TCC identity (com.trycua.driver).
        bundle = Path(self.binary).resolve().parents[2]  # the binary on PATH is often a symlink into the .app
        subprocess.run(["open", "-g", "-a", str(bundle), "--args", "serve"], check=False, timeout=30)
        for _ in range(20):
            status = subprocess.run([self.binary, "status"], capture_output=True, text=True, timeout=10)
            if "is running" in status.stdout:
                return
            subprocess.run(["sleep", "0.5"])
        raise CuaError("cua-driver daemon did not start")

    def permissions(self) -> dict:
        proc = subprocess.run(
            [self.binary, "permissions", "status", "--json"], capture_output=True, text=True, timeout=15
        )
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            return {}

    # Window-scoped helpers. Coordinates are window-local points, top-left origin.

    def windows_for(self, pid: int) -> list[dict]:
        wins = self.call("list_windows").get("windows", [])
        return [w for w in wins if w.get("pid") == pid and w.get("layer", 0) == 0]

    def main_window(self, pid: int) -> dict | None:
        wins = [w for w in self.windows_for(pid) if w.get("is_on_screen", True)]
        if not wins:
            wins = self.windows_for(pid)
        if not wins:
            return None
        return max(wins, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"])

    def drag(self, pid: int, window_id: int, start: tuple[float, float], end: tuple[float, float], *,
             duration_ms: int = 400, steps: int = 20, modifiers: list[str] | None = None) -> dict:
        args = {
            "pid": pid, "window_id": window_id,
            "from_x": start[0], "from_y": start[1], "to_x": end[0], "to_y": end[1],
            "duration_ms": duration_ms, "steps": steps,
        }
        if modifiers:
            args["modifier"] = modifiers
        return self.call("drag", args)

    def click(self, pid: int, window_id: int, point: tuple[float, float], *, count: int = 1,
              button: str = "left") -> dict:
        tool = {"left": "click", "right": "right_click"}[button]
        if count == 2 and button == "left":
            tool = "double_click"
        return self.call(tool, {"pid": pid, "window_id": window_id, "x": point[0], "y": point[1]})

    def hotkey(self, pid: int, window_id: int, keys: list[str], *, foreground: bool = True) -> dict:
        # Menu key equivalents (Cmd+D, Cmd+W) only dispatch through the foreground rung.
        args = {"pid": pid, "window_id": window_id, "keys": keys}
        if foreground:
            args["delivery_mode"] = "foreground"
        return self.call("hotkey", args)

    def press_key(self, pid: int, window_id: int, key: str) -> dict:
        return self.call("press_key", {"pid": pid, "window_id": window_id, "key": key})

    def invoke_menu(self, pid: int, path: list[str]) -> dict:
        return self.call("invoke_menu", {"pid": pid, "path": path})

    def set_window_frame(self, pid: int, window_id: int, x: float, y: float, w: float, h: float) -> dict:
        return self.call("set_window_frame", {"pid": pid, "window_id": window_id, "x": x, "y": y, "width": w, "height": h})

    def screen_size(self) -> tuple[float, float]:
        size = self.call("get_screen_size")
        return float(size.get("width", 1920)), float(size.get("height", 1080))

    def window_state(self, pid: int, window_id: int) -> dict:
        return self.call("get_window_state", {"pid": pid, "window_id": window_id, "include_screenshot": False},
                         timeout=40)

    def window_shot(self, pid: int, window_id: int, path: Path, *, max_dimension: int = 1280) -> dict:
        """Screenshot only (no AX walk), written to `path` as PNG."""
        return self.call("get_window_state", {
            "pid": pid, "window_id": window_id, "include_accessibility_tree": False,
            "screenshot_out_file": str(path), "max_dimension": max_dimension,
        })

    def desktop_shot(self, path: Path) -> dict:
        return self.call("get_desktop_state", {"screenshot_out_file": str(path)})
