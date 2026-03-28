#!/usr/bin/env python3
"""
Regression test for cmux droid install-hooks/uninstall-hooks.

Validates:
1) install-hooks merges into ~/.factory/settings.json without clobbering unrelated settings
2) uninstall-hooks removes only cmux-managed Droid hooks
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from claude_teams_test_utils import resolve_cmux_cli


EXPECTED_EVENTS = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def group_contains_command(groups: list[dict], needle: str) -> bool:
    for group in groups:
        for hook in group.get("hooks") or []:
            if needle in str(hook.get("command") or ""):
                return True
    return False


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    with tempfile.TemporaryDirectory(prefix="cmux-droid-hooks-") as td:
        home = Path(td) / "home"
        factory_dir = home / ".factory"
        factory_dir.mkdir(parents=True, exist_ok=True)
        settings_path = factory_dir / "settings.json"

        seed = {
            "model": "droid-latest",
            "hooks": {
                "Notification": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "echo keep-notification",
                                "timeout": 3,
                            }
                        ]
                    }
                ],
                "Stop": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "echo keep-stop",
                                "timeout": 4,
                            }
                        ]
                    }
                ],
            },
        }
        settings_path.write_text(json.dumps(seed, indent=2, sort_keys=True), encoding="utf-8")

        env = os.environ.copy()
        env["HOME"] = str(home)
        env.pop("FACTORY_HOME", None)

        install = subprocess.run(
            [cli_path, "droid", "install-hooks", "--yes"],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        if install.returncode != 0:
            return fail(
                "cmux droid install-hooks failed:\n"
                f"exit={install.returncode}\nstdout={install.stdout}\nstderr={install.stderr}"
            )

        installed = load_json(settings_path)
        if installed.get("model") != seed["model"]:
            return fail("install-hooks changed unrelated settings")

        hooks = installed.get("hooks") or {}
        for event in EXPECTED_EVENTS:
            groups = hooks.get(event) or []
            if not groups:
                return fail(f"Expected {event} hooks after install")
            if not group_contains_command(groups, f"cmux droid-hook {event.lower().replace('_', '-')}"):
                command_map = {
                    "SessionStart": "cmux droid-hook session-start",
                    "UserPromptSubmit": "cmux droid-hook prompt-submit",
                    "Notification": "cmux droid-hook notification",
                    "Stop": "cmux droid-hook stop",
                    "SessionEnd": "cmux droid-hook session-end",
                }
                if not group_contains_command(groups, command_map[event]):
                    return fail(f"Expected cmux-managed hook command for {event}")

        if not group_contains_command(hooks.get("Notification") or [], "echo keep-notification"):
            return fail("install-hooks removed existing Notification hooks")
        if not group_contains_command(hooks.get("Stop") or [], "echo keep-stop"):
            return fail("install-hooks removed existing Stop hooks")

        uninstall = subprocess.run(
            [cli_path, "droid", "uninstall-hooks", "--yes"],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        if uninstall.returncode != 0:
            return fail(
                "cmux droid uninstall-hooks failed:\n"
                f"exit={uninstall.returncode}\nstdout={uninstall.stdout}\nstderr={uninstall.stderr}"
            )

        removed = load_json(settings_path)
        if removed.get("model") != seed["model"]:
            return fail("uninstall-hooks changed unrelated settings")

        removed_hooks = removed.get("hooks") or {}
        for event, groups in removed_hooks.items():
            if group_contains_command(groups or [], "cmux droid-hook"):
                return fail(f"uninstall-hooks left a cmux-managed Droid hook in {event}")

        if not group_contains_command(removed_hooks.get("Notification") or [], "echo keep-notification"):
            return fail("uninstall-hooks removed non-cmux Notification hooks")
        if not group_contains_command(removed_hooks.get("Stop") or [], "echo keep-stop"):
            return fail("uninstall-hooks removed non-cmux Stop hooks")

        if "SessionStart" in removed_hooks or "UserPromptSubmit" in removed_hooks or "SessionEnd" in removed_hooks:
            return fail("uninstall-hooks left empty Droid-only hook events behind")

        print("PASS: droid install-hooks/uninstall-hooks merges and removes only cmux-managed hooks")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
