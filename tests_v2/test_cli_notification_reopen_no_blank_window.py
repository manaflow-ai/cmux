#!/usr/bin/env python3
"""Regression: notify + app reopen must not create a blank extra window or blank the target terminal."""

from __future__ import annotations

import glob
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_for(
    predicate: Callable[[], bool],
    *,
    timeout_s: float,
    cadence_s: float = 0.05,
    label: str,
) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(cadence_s)
    raise cmuxError(f"Timed out waiting for {label}")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _find_app_bundle(cli: str) -> tuple[str, str]:
    cli_path = Path(cli).resolve()

    for parent in [cli_path.parent] + list(cli_path.parents):
        if parent.suffix != ".app":
            continue
        info_plist = parent / "Contents" / "Info.plist"
        if not info_plist.exists():
            continue
        with info_plist.open("rb") as fh:
            info = plistlib.load(fh)
        bundle_id = str(info.get("CFBundleIdentifier") or "").strip()
        if bundle_id:
            return str(parent), bundle_id

    product_dir = cli_path.parent
    candidates = sorted(
        {
            str(path)
            for pattern in ("cmux*.app", "*.app")
            for path in product_dir.glob(pattern)
            if path.is_dir()
        },
        key=os.path.getmtime,
        reverse=True,
    )
    for candidate in candidates:
        info_plist = Path(candidate) / "Contents" / "Info.plist"
        if not info_plist.exists():
            continue
        with info_plist.open("rb") as fh:
            info = plistlib.load(fh)
        bundle_id = str(info.get("CFBundleIdentifier") or "").strip()
        if bundle_id:
            return candidate, bundle_id

    raise cmuxError(f"Could not locate a cmux app bundle next to CLI: {cli}")


def _run_cli(cli: str, args: list[str], *, timeout_s: float = 10.0) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    try:
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, *args],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as exc:
        partial = f"stdout={exc.stdout or ''} stderr={exc.stderr or ''}".strip()
        raise cmuxError(
            f"CLI timed out after {timeout_s}s ({' '.join(args)}): {partial}"
        ) from exc
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    if proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return (proc.stdout or "").strip()


def _window_count(snapshot: dict) -> int:
    return int(snapshot.get("ns_window_count") or 0)


def _wait_for_notification(c: cmux, title: str, surface_id: str) -> None:
    surface_id = surface_id.lower()

    def seen() -> bool:
        for item in c.list_notifications():
            if str(item.get("title") or "") != title:
                continue
            if str(item.get("surface_id") or "").lower() == surface_id:
                return True
        return False

    _wait_for(seen, timeout_s=5.0, label=f"notification {title!r}")


def _debug_terminal_row(c: cmux, surface_id: str) -> dict:
    surface_id = surface_id.lower()
    payload = c._call("debug.terminals") or {}
    for row in payload.get("terminals") or []:
        if str(row.get("surface_id") or "").lower() == surface_id:
            return dict(row)
    raise cmuxError(f"debug.terminals missing surface {surface_id}")


def _assert_terminal_mounted(c: cmux, surface_id: str, *, context: str) -> None:
    row = _debug_terminal_row(c, surface_id)
    failures: list[str] = []

    for key in (
        "mapped",
        "tree_visible",
        "runtime_surface_ready",
        "hosted_view_in_window",
        "hosted_view_has_superview",
        "hosted_view_visible_in_ui",
    ):
        if row.get(key) is not True:
            failures.append(f"{key}={row.get(key)!r}")

    if str(row.get("portal_binding_state") or "") != "live":
        failures.append(f"portal_binding_state={row.get('portal_binding_state')!r}")

    if failures:
        raise cmuxError(
            f"{context}: target terminal is not visibly mounted after notify/reopen.\n"
            f"surface_id={surface_id}\n"
            f"failures={', '.join(failures)}\n"
            f"row={row}"
        )


def _wait_for_terminal_text(c: cmux, surface_id: str, text: str) -> None:
    _wait_for(
        lambda: text in c.read_terminal_text(surface_id),
        timeout_s=5.0,
        label=f"terminal text {text!r}",
    )


def _assert_renders_after_reopen(c: cmux, surface_id: str, marker: str) -> None:
    c.panel_snapshot_reset(surface_id)
    before = c.panel_snapshot(surface_id, "notify_reopen_before")
    baseline_present = int(c.render_stats(surface_id).get("presentCount") or 0)

    c.send_surface(surface_id, f"printf '{marker}\\n'\n")
    _wait_for_terminal_text(c, surface_id, marker)
    _wait_for(
        lambda: int(c.render_stats(surface_id).get("presentCount") or 0) > baseline_present,
        timeout_s=3.0,
        label="new layer presentation",
    )

    after = c.panel_snapshot(surface_id, "notify_reopen_after")
    changed_pixels = int(after.get("changed_pixels") or 0)
    if changed_pixels < 50:
        raise cmuxError(
            "Expected visible terminal pixels to change after notify/reopen.\n"
            f"changed_pixels={changed_pixels}\n"
            f"before={before}\n"
            f"after={after}"
        )


def main() -> int:
    cli = _find_cli_binary()
    _app_path, bundle_id = _find_app_bundle(cli)

    token = f"CMUX_NOTIFY_REOPEN_{int(time.time() * 1000)}"
    notify_title = f"{token}_TITLE"
    render_marker = f"{token}_RENDER"

    background_window: Optional[str] = None
    with cmux(SOCKET_PATH) as c:
        try:
            c.activate_app()
            # Replace a fixed activate-app sleep with a poll so slow CI runners
            # don't hit `current_window()`'s no-window error before the first
            # main terminal window has finished coming up.
            _wait_for(
                lambda: _window_count(c.window_snapshot()) >= 1,
                timeout_s=3.0,
                label="at least one app window after activate_app",
            )

            foreground_window = c.current_window()
            baseline_snapshot = c.window_snapshot()
            baseline_window_count = _window_count(baseline_snapshot)
            _must(baseline_window_count >= 1, f"Expected at least one app window, got {baseline_snapshot}")

            background_window = c.new_window()
            time.sleep(0.35)

            workspaces = c.list_workspaces(window_id=background_window)
            _must(bool(workspaces), f"Expected new window to expose a workspace: {workspaces}")
            target_workspace = workspaces[0][1]

            surfaces = c.list_surfaces(target_workspace)
            _must(bool(surfaces), f"Expected target workspace to contain a surface: {surfaces}")
            target_surface = surfaces[0][1]

            c.focus_window(foreground_window)
            time.sleep(0.25)

            c.set_app_focus(False)
            output = _run_cli(
                cli,
                [
                    "notify",
                    "--workspace",
                    target_workspace,
                    "--surface",
                    target_surface,
                    "--title",
                    notify_title,
                    "--subtitle",
                    "reopen-regression",
                    "--body",
                    "background-window",
                ],
            )
            _must(output.startswith("OK"), f"Expected notify OK output, got: {output!r}")
            _wait_for_notification(c, notify_title, target_surface)

            before_reopen = c.window_snapshot()
            expected_window_count = _window_count(before_reopen)

            try:
                reopen = subprocess.run(
                    ["/usr/bin/open", "-b", bundle_id],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10.0,
                )
            except subprocess.TimeoutExpired as exc:
                raise cmuxError(
                    f"Timed out reopening app bundle {bundle_id}: {exc}"
                ) from exc
            if reopen.returncode != 0:
                raise cmuxError(
                    "Failed to reopen app for notification regression.\n"
                    f"bundle_id={bundle_id}\nstdout={reopen.stdout}\nstderr={reopen.stderr}"
                )

            # The reopen path is async; poll for at least the minimum grace
            # window so a spurious window would have time to appear. If the
            # count ever exceeds expected, fail immediately — the regression
            # we're guarding against is an extra window, not a missing one.
            poll_deadline = time.time() + 2.5
            last_snapshot: dict = before_reopen
            while time.time() < poll_deadline:
                last_snapshot = c.window_snapshot()
                if _window_count(last_snapshot) > expected_window_count:
                    break
                time.sleep(0.1)
            after_reopen = last_snapshot
            actual_window_count = _window_count(after_reopen)
            _must(
                actual_window_count == expected_window_count,
                "Reopening the app during a background notification created an extra window.\n"
                f"before={before_reopen}\n"
                f"after={after_reopen}"
            )

            c.focus_window(background_window)
            time.sleep(0.3)
            _assert_terminal_mounted(c, target_surface, context="after reopen focus")
            _assert_renders_after_reopen(c, target_surface, render_marker)
        finally:
            if background_window:
                try:
                    c.close_window(background_window)
                except Exception as exc:
                    print(
                        f"WARN: failed to close test background window {background_window}: {exc}",
                        file=sys.stderr,
                    )
            try:
                c.set_app_focus(None)
            except Exception as exc:
                print(
                    f"WARN: failed to reset app focus override: {exc}",
                    file=sys.stderr,
                )

    print("PASS: notify + app reopen does not create a blank extra window or blank the target terminal")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
