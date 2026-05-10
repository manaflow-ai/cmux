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

        shortcut_keys = run_cli(cli_path, ["settings", "shortcuts", "list", "--keys"], home)
        assert_ok(failures, "settings shortcuts list --keys", shortcut_keys)
        shortcut_key_lines = [line.strip() for line in shortcut_keys.stdout.splitlines() if line.strip()]
        if "openSettings" not in shortcut_key_lines or "showHideAllWindows" not in shortcut_key_lines:
            failures.append(f"settings shortcuts list --keys omitted expected actions: {shortcut_keys.stdout!r}")

        set_appearance = run_cli(cli_path, ["settings", "set", "app.appearance", "dark"], home)
        assert_ok(failures, "settings set app.appearance", set_appearance)
        get_appearance = run_cli(cli_path, ["settings", "get", "app.appearance"], home)
        assert_ok(failures, "settings get app.appearance", get_appearance)
        if get_appearance.stdout.strip() != "dark":
            failures.append(f"settings get app.appearance returned {get_appearance.stdout!r}")
        config = read_config(home)
        if config.get("app", {}).get("appearance") != "dark":
            failures.append(f"app.appearance was not written to cmux.json: {config}")

        set_placement = run_cli(
            cli_path,
            ["settings", "set", "app.newWorkspacePlacement", "after_current"],
            home,
        )
        assert_ok(failures, "settings set enum alias with underscore", set_placement)
        get_placement = run_cli(cli_path, ["settings", "get", "app.newWorkspacePlacement"], home)
        assert_ok(failures, "settings get normalized enum", get_placement)
        if get_placement.stdout.strip() != "afterCurrent":
            failures.append(f"enum value was not canonicalized: {get_placement.stdout!r}")

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

        primitive_string = run_cli(cli_path, ["settings", "set", "notifications.command", "true"], home)
        assert_ok(failures, "settings set string-looking bool", primitive_string)
        get_primitive_string = run_cli(cli_path, ["settings", "get", "notifications.command"], home)
        assert_ok(failures, "settings get string-looking bool", get_primitive_string)
        if get_primitive_string.stdout.strip() != "true":
            failures.append(f"string setting that looks like a bool was not preserved: {get_primitive_string.stdout!r}")

        set_password = run_cli(cli_path, ["settings", "set", "automation.socketPassword", "secret-token"], home)
        assert_ok(failures, "settings set socket password", set_password)
        redacted_password = run_cli(cli_path, ["settings", "get", "automation.socketPassword"], home)
        assert_ok(failures, "settings get socket password redacted", redacted_password)
        if redacted_password.stdout.strip() != "<redacted>":
            failures.append(f"socket password was not redacted by default: {redacted_password.stdout!r}")
        revealed_password = run_cli(cli_path, ["settings", "get", "automation.socketPassword", "--reveal"], home)
        assert_ok(failures, "settings get socket password reveal", revealed_password)
        if revealed_password.stdout.strip() != "secret-token":
            failures.append(f"socket password reveal returned {revealed_password.stdout!r}")
        redacted_list = run_cli(cli_path, ["settings", "list", "--json"], home)
        assert_ok(failures, "settings list redacts socket password", redacted_list)
        redacted_payload = parse_json(failures, "settings list redacts socket password", redacted_list)
        if isinstance(redacted_payload, dict):
            password_item = next(
                (
                    item
                    for item in redacted_payload.get("settings", [])
                    if isinstance(item, dict) and item.get("key") == "automation.socketPassword"
                ),
                None,
            )
            if password_item is None:
                failures.append("settings list --json omitted automation.socketPassword")
            elif password_item.get("value") != "<redacted>" or password_item.get("redacted") is not True:
                failures.append(f"settings list --json did not redact automation.socketPassword: {password_item}")

        backslash_n_command = r"\nfoo"
        set_backslash_n = run_cli(cli_path, ["settings", "set", "notifications.command", backslash_n_command], home)
        assert_ok(failures, "settings set literal backslash-n command", set_backslash_n)
        roundtrip_path = home / "settings-roundtrip.toml"
        export_roundtrip = run_cli(cli_path, ["settings", "export", "--format", "toml", "--out", str(roundtrip_path)], home)
        assert_ok(failures, "settings export literal backslash-n command", export_roundtrip)
        unset_command = run_cli(cli_path, ["settings", "unset", "notifications.command"], home)
        assert_ok(failures, "settings unset notifications.command before roundtrip import", unset_command)
        import_roundtrip = run_cli(cli_path, ["settings", "import", str(roundtrip_path)], home)
        assert_ok(failures, "settings import literal backslash-n command", import_roundtrip)
        get_backslash_n = run_cli(cli_path, ["settings", "get", "notifications.command"], home)
        assert_ok(failures, "settings get literal backslash-n command", get_backslash_n)
        if get_backslash_n.stdout.strip() != backslash_n_command:
            failures.append(f"TOML roundtrip corrupted literal backslash-n: {get_backslash_n.stdout!r}")

        bad_escape_path = home / "bad-escape.toml"
        bad_escape_path.write_text('notifications.command = "bad\\t"\n', encoding="utf-8")
        bad_escape = run_cli(cli_path, ["settings", "import", str(bad_escape_path)], home)
        assert_fails(failures, "settings import unsupported TOML escape", bad_escape, r"Unsupported TOML string escape: \t")

        sectioned_toml_path = home / "sectioned-settings.toml"
        sectioned_toml_path.write_text(
            """
[app]
appearance = "dark"

[notifications]
command = "section import"

[rightSidebar.beta.feed]
enabled = true

[shortcuts.bindings]
openSettings = "cmd+option+,"
""".lstrip(),
            encoding="utf-8",
        )
        sectioned_import = run_cli(cli_path, ["settings", "import", str(sectioned_toml_path)], home)
        assert_ok(failures, "settings import sectioned TOML", sectioned_import)
        sectioned_config = read_config(home)
        if sectioned_config.get("app", {}).get("appearance") != "dark":
            failures.append(f"sectioned TOML did not import app.appearance: {sectioned_config}")
        if sectioned_config.get("rightSidebar", {}).get("beta", {}).get("feed", {}).get("enabled") is not True:
            failures.append(f"sectioned TOML did not import rightSidebar.beta.feed.enabled: {sectioned_config}")
        if sectioned_config.get("shortcuts", {}).get("bindings", {}).get("openSettings") != "cmd+option+,":
            failures.append(f"sectioned TOML did not import shortcut binding: {sectioned_config}")

        chord = run_cli(cli_path, ["settings", "shortcuts", "set", "openSettings", "cmd+k, cmd+c"], home)
        assert_ok(failures, "shortcut two-stroke set", chord)
        chord_get = run_cli(cli_path, ["settings", "shortcuts", "get", "openSettings"], home)
        assert_ok(failures, "shortcut two-stroke get", chord_get)
        if chord_get.stdout.strip() != "cmd+k, cmd+c":
            failures.append(f"two-stroke shortcut did not roundtrip: {chord_get.stdout!r}")

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
        exported_text = export_path.read_text(encoding="utf-8") if export_path.exists() else ""
        if 'app.appearance = "dark"' not in exported_text:
            failures.append("settings export --format toml did not write app.appearance")
        if 'shortcuts.bindings.openSettings = "cmd+n"' not in exported_text:
            failures.append("settings export --format toml did not write configured shortcut override")
        if "browser.enabled = true" in exported_text:
            failures.append("settings export --format toml pinned an unmodified default setting")
        if 'shortcuts.bindings.newWindow = "cmd+shift+n"' in exported_text:
            failures.append("settings export --format toml pinned an unmodified default shortcut")
        if "automation.socketPassword" in exported_text or "secret-token" in exported_text:
            failures.append("settings export --format toml leaked a sensitive setting without --reveal")

        reveal_export_path = home / "settings-export-reveal.toml"
        revealed_export = run_cli(
            cli_path,
            ["settings", "export", "--format", "toml", "--reveal", "--out", str(reveal_export_path)],
            home,
        )
        assert_ok(failures, "settings export toml reveal", revealed_export)
        revealed_export_text = reveal_export_path.read_text(encoding="utf-8") if reveal_export_path.exists() else ""
        if 'automation.socketPassword = "secret-token"' not in revealed_export_text:
            failures.append("settings export --format toml --reveal did not include the configured sensitive setting")

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
