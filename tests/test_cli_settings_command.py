#!/usr/bin/env python3
"""Behavior checks for the file-backed `cmux settings` CLI surface."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = [
        path
        for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"))
        if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run_cli(cli_path: str, args: list[str], home: Path) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_SOCKET_PATH"] = str(home / "missing.sock")
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_SOCKET_PASSWORD", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    return subprocess.run(
        [cli_path, *args],
        text=True,
        capture_output=True,
        env=env,
        timeout=5,
        check=False,
    )


def config_path(home: Path) -> Path:
    return home / ".config" / "cmux" / "cmux.json"


def read_config(home: Path) -> dict[str, Any]:
    path = config_path(home)
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    assert isinstance(payload, dict)
    return payload


def assert_ok(failures: list[str], label: str, result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode != 0:
        failures.append(f"{label} failed with {result.returncode}: stderr={result.stderr!r} stdout={result.stdout!r}")


def assert_fails(failures: list[str], label: str, result: subprocess.CompletedProcess[str], message: str) -> None:
    if result.returncode == 0:
        failures.append(f"{label} unexpectedly succeeded: {result.stdout!r}")
    elif message not in result.stderr:
        failures.append(f"{label} stderr did not contain {message!r}: {result.stderr!r}")


def parse_json(failures: list[str], label: str, result: subprocess.CompletedProcess[str]) -> Any:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        failures.append(f"{label} stdout was not JSON ({exc}): {result.stdout!r}")
        return None


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-settings-cli-") as temp:
        home = Path(temp)

        key_list = run_cli(cli_path, ["settings", "list", "--keys"], home)
        assert_ok(failures, "settings list --keys", key_list)
        keys = [line.strip() for line in key_list.stdout.splitlines() if line.strip()]
        if keys != sorted(keys):
            failures.append("settings list --keys was not sorted")
        for required in [
            "app.appearance",
            "app.fileDropDefaultBehavior",
            "browser.enabled",
            "globalHotkey.enabled",
            "rightSidebar.beta.feed.enabled",
        ]:
            if required not in keys:
                failures.append(f"settings list --keys omitted {required}")

        set_appearance = run_cli(cli_path, ["settings", "set", "app.appearance", "dark"], home)
        assert_ok(failures, "settings set app.appearance", set_appearance)
        get_appearance = run_cli(cli_path, ["settings", "get", "app.appearance"], home)
        assert_ok(failures, "settings get app.appearance", get_appearance)
        if get_appearance.stdout.strip() != "dark":
            failures.append(f"settings get app.appearance returned {get_appearance.stdout!r}")
        config = read_config(home)
        if config.get("app", {}).get("appearance") != "dark":
            failures.append(f"app.appearance was not written to cmux.json: {config}")

        list_json = run_cli(cli_path, ["settings", "list", "--json"], home)
        assert_ok(failures, "settings list --json", list_json)
        payload = parse_json(failures, "settings list --json", list_json)
        if isinstance(payload, dict):
            appearance = next(
                (
                    item
                    for item in payload.get("settings", [])
                    if isinstance(item, dict) and item.get("key") == "app.appearance"
                ),
                None,
            )
            if appearance is None:
                failures.append("settings list --json omitted app.appearance")
            elif appearance.get("value") != "dark" or appearance.get("default") != "system" or not appearance.get("source"):
                failures.append(f"settings list --json app.appearance payload was wrong: {appearance}")

        unknown = run_cli(cli_path, ["settings", "get", "app.nope"], home)
        assert_fails(failures, "unknown setting get", unknown, "Unknown setting key")

        out_of_range = run_cli(cli_path, ["settings", "set", "automation.portRange", "0"], home)
        assert_fails(failures, "out-of-range setting set", out_of_range, "automation.portRange")

        conflict = run_cli(cli_path, ["settings", "shortcuts", "set", "openSettings", "cmd+n"], home)
        assert_fails(failures, "shortcut conflict", conflict, "conflicts with")

        forced = run_cli(cli_path, ["settings", "shortcuts", "set", "openSettings", "cmd+n", "--force"], home)
        assert_ok(failures, "shortcut forced set", forced)
        shortcut = run_cli(cli_path, ["settings", "shortcuts", "get", "openSettings"], home)
        assert_ok(failures, "shortcut get", shortcut)
        if shortcut.stdout.strip() != "cmd+n":
            failures.append(f"shortcut get returned {shortcut.stdout!r}")
        config = read_config(home)
        bindings = config.get("shortcuts", {}).get("bindings", {})
        if bindings.get("openSettings") != "cmd+n":
            failures.append(f"shortcut binding was not written to cmux.json: {config}")

        before_import = read_config(home)
        bad_import_path = home / "bad-import.json"
        bad_import_path.write_text(
            json.dumps({"app": {"appearance": "light"}, "automation": {"portRange": 0}}),
            encoding="utf-8",
        )
        bad_import = run_cli(cli_path, ["settings", "import", str(bad_import_path)], home)
        assert_fails(failures, "atomic import failure", bad_import, "automation.portRange")
        after_import = read_config(home)
        if after_import != before_import:
            failures.append(f"failed import changed cmux.json: before={before_import} after={after_import}")

        export_path = home / "settings-export.toml"
        exported = run_cli(cli_path, ["settings", "export", "--format", "toml", "--out", str(export_path)], home)
        assert_ok(failures, "settings export toml", exported)
        if not export_path.exists() or 'app.appearance = "dark"' not in export_path.read_text(encoding="utf-8"):
            failures.append("settings export --format toml did not write app.appearance")

        unset = run_cli(cli_path, ["settings", "unset", "app.appearance"], home)
        assert_ok(failures, "settings unset app.appearance", unset)
        get_default = run_cli(cli_path, ["settings", "get", "app.appearance"], home)
        assert_ok(failures, "settings get app.appearance default", get_default)
        if get_default.stdout.strip() != "system":
            failures.append(f"settings get app.appearance after unset returned {get_default.stdout!r}")

        reset = run_cli(cli_path, ["settings", "reset", "--yes"], home)
        assert_ok(failures, "settings reset --yes", reset)
        config = read_config(home)
        if config.get("app") or config.get("shortcuts"):
            failures.append(f"settings reset --yes left managed settings behind: {config}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: cmux settings CLI manages settings and shortcuts through cmux.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
