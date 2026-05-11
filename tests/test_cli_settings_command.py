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


SETTING_SAMPLE_VALUES: dict[str, tuple[str, Any]] = {
    "app.appIcon": ("dark", "dark"),
    "app.appearance": ("light", "light"),
    "app.commandPaletteSearchesAllSurfaces": ("true", True),
    "app.fileDropDefaultBehavior": ("preview", "preview"),
    "app.focusPaneOnFirstClick": ("true", True),
    "app.iMessageMode": ("true", True),
    "app.keepWorkspaceOpenWhenClosingLastSurface": ("true", True),
    "app.language": ("ja", "ja"),
    "app.menuBarOnly": ("true", True),
    "app.minimalMode": ("true", True),
    "app.newWorkspacePlacement": ("top", "top"),
    "app.openMarkdownInCmuxViewer": ("true", True),
    "app.preferredEditor": ("zed", "zed"),
    "app.renameSelectsExistingName": ("false", False),
    "app.reorderOnNotification": ("false", False),
    "app.sendAnonymousTelemetry": ("false", False),
    "app.warnBeforeQuit": ("false", False),
    "automation.claudeBinaryPath": ("/opt/cmux/bin/claude", "/opt/cmux/bin/claude"),
    "automation.claudeCodeIntegration": ("false", False),
    "automation.cursorIntegration": ("false", False),
    "automation.geminiIntegration": ("false", False),
    "automation.portBase": ("9234", 9234),
    "automation.portRange": ("64", 64),
    "automation.socketControlMode": ("allow_all", "allowAll"),
    "automation.socketPassword": ("span-secret", "span-secret"),
    "browser.defaultSearchEngine": ("duckduckgo", "duckduckgo"),
    "browser.enabled": ("false", False),
    "browser.hostsToOpenInEmbeddedBrowser": ("example.com,*.internal", ["example.com", "*.internal"]),
    "browser.insecureHttpHostsAllowedInEmbeddedBrowser": (
        '["localhost","127.0.0.1","dev.local"]',
        ["localhost", "127.0.0.1", "dev.local"],
    ),
    "browser.interceptTerminalOpenCommandInCmuxBrowser": ("false", False),
    "browser.openTerminalLinksInCmuxBrowser": ("false", False),
    "browser.reactGrabVersion": ("0.1.29", "0.1.29"),
    "browser.showImportHintOnBlankTabs": ("false", False),
    "browser.showSearchSuggestions": ("false", False),
    "browser.theme": ("dark", "dark"),
    "browser.urlsToAlwaysOpenExternally": ('["https://example.com/.*"]', ["https://example.com/.*"]),
    "globalHotkey.enabled": ("true", True),
    "notifications.command": ("printf true", "printf true"),
    "notifications.customSoundFilePath": ("/tmp/cmux-sound.aiff", "/tmp/cmux-sound.aiff"),
    "notifications.dockBadge": ("false", False),
    "notifications.paneFlash": ("false", False),
    "notifications.showInMenuBar": ("false", False),
    "notifications.sound": ("Ping", "Ping"),
    "notifications.unreadPaneRing": ("false", False),
    "rightSidebar.beta.dock.enabled": ("true", True),
    "rightSidebar.beta.feed.enabled": ("true", True),
    "sidebar.branchLayout": ("inline", "inline"),
    "sidebar.hideAllDetails": ("true", True),
    "sidebar.makePullRequestsClickable": ("false", False),
    "sidebar.openPortLinksInCmuxBrowser": ("false", False),
    "sidebar.openPullRequestLinksInCmuxBrowser": ("false", False),
    "sidebar.showBranchDirectory": ("false", False),
    "sidebar.showCustomMetadata": ("false", False),
    "sidebar.showLog": ("false", False),
    "sidebar.showNotificationMessage": ("false", False),
    "sidebar.showPorts": ("false", False),
    "sidebar.showProgress": ("false", False),
    "sidebar.showPullRequests": ("false", False),
    "sidebar.showSSH": ("false", False),
    "sidebarAppearance.darkModeTintColor": ("#aabbcc", "#AABBCC"),
    "sidebarAppearance.lightModeTintColor": ("778899", "#778899"),
    "sidebarAppearance.matchTerminalBackground": ("true", True),
    "sidebarAppearance.tintColor": ("abc123", "#ABC123"),
    "sidebarAppearance.tintOpacity": ("0.42", 0.42),
    "terminal.autoResumeAgentSessions": ("false", False),
    "terminal.showScrollBar": ("false", False),
    "workspaceColors.colors": ('{"Ruby":"#aa0000","Ocean":"336699"}', {"Ocean": "#336699", "Ruby": "#AA0000"}),
    "workspaceColors.customColors": ('["#111111","#222222"]', ["#111111", "#222222"]),
    "workspaceColors.indicatorStyle": ("solid-fill", "solidFill"),
    "workspaceColors.notificationBadgeColor": ("null", None),
    "workspaceColors.paletteOverrides": ('{"Focus":"#010203"}', {"Focus": "#010203"}),
    "workspaceColors.selectionColor": ("445566", "#445566"),
}

SENSITIVE_SETTING_KEYS = {"automation.socketPassword"}
MISSING = object()


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


def run_cli(
    cli_path: str,
    args: list[str],
    home: Path,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
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
        input=input_text,
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


def value_for_path(root: dict[str, Any], path: str) -> Any:
    current: Any = root
    for component in path.split("."):
        if not isinstance(current, dict) or component not in current:
            return MISSING
        current = current[component]
    return current


def assert_equal(failures: list[str], label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        failures.append(f"{label}: expected {expected!r}, got {actual!r}")


def setting_row(payload: dict[str, Any], key: str) -> dict[str, Any] | None:
    for item in payload.get("settings", []):
        if isinstance(item, dict) and item.get("key") == key:
            return item
    return None


def shortcut_row(payload: dict[str, Any], action: str) -> dict[str, Any] | None:
    for item in payload.get("shortcuts", []):
        if isinstance(item, dict) and item.get("action") == action:
            return item
    return None


def exercise_entire_settings_key_span(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-settings-cli-span-") as temp:
        home = Path(temp)

        key_result = run_cli(cli_path, ["settings", "list", "--keys"], home)
        assert_ok(failures, "settings span list --keys", key_result)
        cli_keys = [line.strip() for line in key_result.stdout.splitlines() if line.strip()]
        expected_keys = sorted(SETTING_SAMPLE_VALUES)
        if cli_keys != expected_keys:
            missing_samples = sorted(set(cli_keys) - set(expected_keys))
            stale_samples = sorted(set(expected_keys) - set(cli_keys))
            failures.append(
                "settings span sample map is out of sync: "
                f"missing_samples={missing_samples} stale_samples={stale_samples}"
            )

        for key in cli_keys:
            sample = SETTING_SAMPLE_VALUES.get(key)
            if sample is None:
                continue
            raw_value, expected = sample
            result = run_cli(cli_path, ["settings", "set", key, raw_value], home)
            assert_ok(failures, f"settings span set {key}", result)

            get_args = ["settings", "get", key, "--json"]
            if key in SENSITIVE_SETTING_KEYS:
                get_args.append("--reveal")
            get_result = run_cli(cli_path, get_args, home)
            assert_ok(failures, f"settings span get {key}", get_result)
            payload = parse_json(failures, f"settings span get {key}", get_result)
            if isinstance(payload, dict):
                assert_equal(failures, f"settings span get {key} key", payload.get("key"), key)
                assert_equal(failures, f"settings span get {key} source", payload.get("source"), "cmux.json")
                assert_equal(failures, f"settings span get {key} value", payload.get("value"), expected)
                assert_equal(failures, f"settings span get {key} redacted", payload.get("redacted"), False)

        list_result = run_cli(cli_path, ["settings", "list", "--json"], home)
        assert_ok(failures, "settings span list --json after setting every key", list_result)
        list_payload = parse_json(failures, "settings span list --json after setting every key", list_result)
        if isinstance(list_payload, dict):
            rows = list_payload.get("settings")
            if not isinstance(rows, list) or len(rows) != len(cli_keys):
                failures.append(f"settings span list --json returned wrong row count: {list_payload}")
            for key in cli_keys:
                sample = SETTING_SAMPLE_VALUES.get(key)
                if sample is None:
                    continue
                _, expected = sample
                row = setting_row(list_payload, key)
                if row is None:
                    failures.append(f"settings span list --json omitted {key}")
                    continue
                assert_equal(failures, f"settings span list {key} source", row.get("source"), "cmux.json")
                if key in SENSITIVE_SETTING_KEYS:
                    assert_equal(failures, f"settings span list {key} redacted value", row.get("value"), "<redacted>")
                    assert_equal(failures, f"settings span list {key} redacted flag", row.get("redacted"), True)
                else:
                    assert_equal(failures, f"settings span list {key} value", row.get("value"), expected)
                    assert_equal(failures, f"settings span list {key} redacted flag", row.get("redacted"), False)

        export_result = run_cli(cli_path, ["settings", "export", "--format", "json"], home)
        assert_ok(failures, "settings span export json", export_result)
        export_payload = parse_json(failures, "settings span export json", export_result)
        if isinstance(export_payload, dict):
            for key in cli_keys:
                sample = SETTING_SAMPLE_VALUES.get(key)
                if sample is None:
                    continue
                _, expected = sample
                exported = value_for_path(export_payload, key)
                if key in SENSITIVE_SETTING_KEYS:
                    if exported is not MISSING:
                        failures.append(f"settings span export leaked sensitive {key}: {export_payload}")
                else:
                    assert_equal(failures, f"settings span export {key}", exported, expected)

        reveal_export_result = run_cli(cli_path, ["settings", "export", "--format", "json", "--reveal"], home)
        assert_ok(failures, "settings span export json reveal", reveal_export_result)
        reveal_export_payload = parse_json(failures, "settings span export json reveal", reveal_export_result)
        if isinstance(reveal_export_payload, dict):
            exported_password = value_for_path(reveal_export_payload, "automation.socketPassword")
            assert_equal(
                failures,
                "settings span export reveal automation.socketPassword",
                exported_password,
                SETTING_SAMPLE_VALUES["automation.socketPassword"][1],
            )

        for key in reversed(cli_keys):
            if key not in SETTING_SAMPLE_VALUES:
                continue
            unset_result = run_cli(cli_path, ["settings", "unset", key], home)
            assert_ok(failures, f"settings span unset {key}", unset_result)

        empty_config = read_config(home)
        if empty_config:
            failures.append(f"settings span unset every key left config behind: {empty_config}")


def exercise_entire_shortcut_action_span(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-shortcuts-cli-span-") as temp:
        home = Path(temp)

        keys_result = run_cli(cli_path, ["settings", "shortcuts", "list", "--keys"], home)
        assert_ok(failures, "shortcut span list --keys", keys_result)
        actions = [line.strip() for line in keys_result.stdout.splitlines() if line.strip()]
        if actions != sorted(actions):
            failures.append("shortcut span list --keys was not sorted")
        if len(actions) < 50:
            failures.append(f"shortcut span unexpectedly small action set: {actions}")

        list_result = run_cli(cli_path, ["settings", "shortcuts", "list", "--json"], home)
        assert_ok(failures, "shortcut span list --json defaults", list_result)
        list_payload = parse_json(failures, "shortcut span list --json defaults", list_result)
        default_values: dict[str, str] = {}
        if isinstance(list_payload, dict):
            rows = list_payload.get("shortcuts")
            if not isinstance(rows, list) or len(rows) != len(actions):
                failures.append(f"shortcut span list --json returned wrong row count: {list_payload}")
            for action in actions:
                row = shortcut_row(list_payload, action)
                if row is None:
                    failures.append(f"shortcut span list --json omitted {action}")
                    continue
                if not row.get("label") or row.get("context") not in {
                    "application",
                    "nonBrowserPanel",
                    "browserPanel",
                    "rightSidebarFocus",
                }:
                    failures.append(f"shortcut span row missing label/context for {action}: {row}")
                assert_equal(failures, f"shortcut span default source {action}", row.get("source"), "default")
                value = row.get("value")
                default = row.get("default")
                if not isinstance(value, str) or not isinstance(default, str) or value != default:
                    failures.append(f"shortcut span default value mismatch for {action}: {row}")
                else:
                    default_values[action] = default

        for action in actions:
            set_result = run_cli(cli_path, ["settings", "shortcuts", "set", action, "none"], home)
            assert_ok(failures, f"shortcut span set {action} none", set_result)
            get_result = run_cli(cli_path, ["settings", "shortcuts", "get", action, "--json"], home)
            assert_ok(failures, f"shortcut span get {action} none", get_result)
            payload = parse_json(failures, f"shortcut span get {action} none", get_result)
            if isinstance(payload, dict):
                assert_equal(failures, f"shortcut span get {action} action", payload.get("action"), action)
                assert_equal(failures, f"shortcut span get {action} source", payload.get("source"), "cmux.json")
                assert_equal(failures, f"shortcut span get {action} value", payload.get("value"), "none")

        all_none = run_cli(cli_path, ["settings", "shortcuts", "list", "--json"], home)
        assert_ok(failures, "shortcut span list --json after clearing every action", all_none)
        all_none_payload = parse_json(failures, "shortcut span list --json after clearing every action", all_none)
        if isinstance(all_none_payload, dict):
            for action in actions:
                row = shortcut_row(all_none_payload, action)
                if row is None:
                    failures.append(f"shortcut span all-none list omitted {action}")
                    continue
                assert_equal(failures, f"shortcut span all-none {action} source", row.get("source"), "cmux.json")
                assert_equal(failures, f"shortcut span all-none {action} value", row.get("value"), "none")

        for action in reversed(actions):
            unset_result = run_cli(cli_path, ["settings", "shortcuts", "unset", action], home)
            assert_ok(failures, f"shortcut span unset {action}", unset_result)
            default_result = run_cli(cli_path, ["settings", "shortcuts", "get", action, "--json"], home)
            assert_ok(failures, f"shortcut span get {action} default", default_result)
            payload = parse_json(failures, f"shortcut span get {action} default", default_result)
            if isinstance(payload, dict) and action in default_values:
                assert_equal(failures, f"shortcut span default source {action}", payload.get("source"), "default")
                assert_equal(failures, f"shortcut span default value {action}", payload.get("value"), default_values[action])

        if read_config(home):
            failures.append(f"shortcut span unset every action left config behind: {read_config(home)}")

        alias_set = run_cli(cli_path, ["settings", "shortcuts", "set", "toggleRightSidebar", "cmd+option+j"], home)
        assert_ok(failures, "shortcut alias set toggleRightSidebar", alias_set)
        alias_get = run_cli(cli_path, ["settings", "shortcuts", "get", "toggleFileExplorer", "--json"], home)
        assert_ok(failures, "shortcut alias get canonical toggleFileExplorer", alias_get)
        alias_payload = parse_json(failures, "shortcut alias get canonical toggleFileExplorer", alias_get)
        if isinstance(alias_payload, dict):
            assert_equal(failures, "shortcut alias canonical action", alias_payload.get("action"), "toggleFileExplorer")
            assert_equal(failures, "shortcut alias canonical value", alias_payload.get("value"), "cmd+option+j")

        case_set = run_cli(cli_path, ["settings", "shortcuts", "set", "OPENSETTINGS", "cmd+option+,"], home)
        assert_ok(failures, "shortcut action set is case-insensitive", case_set)
        case_get = run_cli(cli_path, ["settings", "shortcuts", "get", "openSettings"], home)
        assert_ok(failures, "shortcut action get after case-insensitive set", case_get)
        assert_equal(failures, "shortcut action case-insensitive value", case_get.stdout.strip(), "cmd+option+,")

        numbered_surface = run_cli(cli_path, ["settings", "shortcuts", "set", "selectSurfaceByNumber", "ctrl+9"], home)
        assert_ok(failures, "shortcut numbered surface set", numbered_surface)
        numbered_surface_get = run_cli(cli_path, ["settings", "shortcuts", "get", "selectSurfaceByNumber"], home)
        assert_ok(failures, "shortcut numbered surface get", numbered_surface_get)
        assert_equal(failures, "shortcut numbered surface normalizes digit", numbered_surface_get.stdout.strip(), "ctrl+1")

        numbered_workspace = run_cli(cli_path, ["settings", "shortcuts", "set", "selectWorkspaceByNumber", "cmd+9"], home)
        assert_ok(failures, "shortcut numbered workspace set", numbered_workspace)
        numbered_workspace_get = run_cli(cli_path, ["settings", "shortcuts", "get", "selectWorkspaceByNumber"], home)
        assert_ok(failures, "shortcut numbered workspace get", numbered_workspace_get)
        assert_equal(
            failures,
            "shortcut numbered workspace normalizes digit",
            numbered_workspace_get.stdout.strip(),
            "cmd+1",
        )

        bad_global_chord = run_cli(
            cli_path,
            ["settings", "shortcuts", "set", "showHideAllWindows", "cmd+k, cmd+c"],
            home,
        )
        assert_fails(
            failures,
            "shortcut global hotkey rejects chords",
            bad_global_chord,
            "Global hotkey shortcut cannot be a chord",
        )
        bad_global_modifier = run_cli(cli_path, ["settings", "shortcuts", "set", "showHideAllWindows", "f"], home)
        assert_fails(
            failures,
            "shortcut global hotkey requires modifier",
            bad_global_modifier,
            "must include a modifier",
        )

        reset_result = run_cli(cli_path, ["settings", "shortcuts", "reset"], home)
        assert_ok(failures, "shortcut span reset", reset_result)
        config_after_reset = read_config(home)
        if config_after_reset.get("shortcuts"):
            failures.append(f"settings shortcuts reset left bindings behind: {config_after_reset}")


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []

    exercise_entire_settings_key_span(cli_path, failures)
    exercise_entire_shortcut_action_span(cli_path, failures)

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

        set_auto_alias = run_cli(cli_path, ["settings", "set", "app.appearance", "auto"], home)
        assert_ok(failures, "settings set app.appearance legacy auto alias", set_auto_alias)
        get_auto_alias = run_cli(cli_path, ["settings", "get", "app.appearance"], home)
        assert_ok(failures, "settings get app.appearance legacy auto alias", get_auto_alias)
        if get_auto_alias.stdout.strip() != "system":
            failures.append(f"app.appearance auto alias was not canonicalized to system: {get_auto_alias.stdout!r}")

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

        alpha_color = run_cli(cli_path, ["settings", "set", "sidebarAppearance.tintColor", "#11223344"], home)
        assert_fails(failures, "settings reject 8-digit hex color", alpha_color, "sidebarAppearance.tintColor")

        set_null_color = run_cli(cli_path, ["settings", "set", "workspaceColors.selectionColor", "null"], home)
        assert_ok(failures, "settings set nullable color null", set_null_color)
        null_toml_export = run_cli(cli_path, ["settings", "export", "--format", "toml"], home)
        assert_fails(
            failures,
            "settings export toml rejects null",
            null_toml_export,
            "TOML format does not support null values",
        )
        null_json_export = run_cli(cli_path, ["settings", "export", "--format", "json"], home)
        assert_ok(failures, "settings export json allows null", null_json_export)
        null_json_payload = parse_json(failures, "settings export json allows null", null_json_export)
        if isinstance(null_json_payload, dict):
            workspace_colors = null_json_payload.get("workspaceColors")
            if not isinstance(workspace_colors, dict) or workspace_colors.get("selectionColor") is not None:
                failures.append(f"settings export json did not preserve null selectionColor: {null_json_payload}")
        unset_null_color = run_cli(cli_path, ["settings", "unset", "workspaceColors.selectionColor"], home)
        assert_ok(failures, "settings unset nullable color null before TOML exports", unset_null_color)

        object_import_path = home / "object-settings.json"
        object_import_path.write_text(
            json.dumps({"workspaceColors": {"paletteOverrides": {"Work": "#123456"}}}),
            encoding="utf-8",
        )
        object_import = run_cli(cli_path, ["settings", "import", str(object_import_path)], home)
        assert_ok(failures, "settings import object setting", object_import)
        object_toml_export = run_cli(cli_path, ["settings", "export", "--format", "toml"], home)
        assert_fails(
            failures,
            "settings export toml rejects object values",
            object_toml_export,
            "TOML format does not support object values",
        )
        object_json_export = run_cli(cli_path, ["settings", "export", "--format", "json"], home)
        assert_ok(failures, "settings export json allows object values", object_json_export)
        object_json_payload = parse_json(failures, "settings export json allows object values", object_json_export)
        if isinstance(object_json_payload, dict):
            palette = object_json_payload.get("workspaceColors", {}).get("paletteOverrides")
            if not isinstance(palette, dict) or palette.get("Work") != "#123456":
                failures.append(f"settings export json did not preserve paletteOverrides: {object_json_payload}")
        unset_object = run_cli(cli_path, ["settings", "unset", "workspaceColors.paletteOverrides"], home)
        assert_ok(failures, "settings unset object setting before TOML exports", unset_object)

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

        before_bad_intermediate_import = read_config(home)
        bad_intermediate_toml_path = home / "bad-intermediate.toml"
        bad_intermediate_toml_path.write_text('app = "foo"\n', encoding="utf-8")
        bad_intermediate_toml = run_cli(cli_path, ["settings", "import", str(bad_intermediate_toml_path)], home)
        assert_fails(
            failures,
            "settings import rejects scalar intermediate TOML key",
            bad_intermediate_toml,
            "Invalid value for intermediate key 'app': expected an object",
        )
        bad_intermediate_json_path = home / "bad-intermediate.json"
        bad_intermediate_json_path.write_text(json.dumps({"shortcuts": "none"}), encoding="utf-8")
        bad_intermediate_json = run_cli(cli_path, ["settings", "import", str(bad_intermediate_json_path)], home)
        assert_fails(
            failures,
            "settings import rejects scalar intermediate JSON key",
            bad_intermediate_json,
            "Invalid value for intermediate key 'shortcuts': expected an object",
        )
        after_bad_intermediate_import = read_config(home)
        if after_bad_intermediate_import != before_bad_intermediate_import:
            failures.append(
                "failed intermediate-key import changed cmux.json: "
                f"before={before_bad_intermediate_import} after={after_bad_intermediate_import}"
            )

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

        escape_shortcut = run_cli(cli_path, ["settings", "shortcuts", "set", "find", "cmd+escape"], home)
        assert_ok(failures, "shortcut escape set", escape_shortcut)
        escape_get = run_cli(cli_path, ["settings", "shortcuts", "get", "find"], home)
        assert_ok(failures, "shortcut escape get", escape_get)
        if escape_get.stdout.strip() != "cmd+escape":
            failures.append(f"escape shortcut did not use printable config string: {escape_get.stdout!r}")

        conflict = run_cli(cli_path, ["settings", "shortcuts", "set", "openSettings", "cmd+n"], home)
        assert_fails(failures, "shortcut conflict", conflict, "conflicts with")

        browser_context_shortcut = run_cli(cli_path, ["settings", "shortcuts", "set", "browserReload", "cmd+option+r"], home)
        assert_ok(failures, "browser-context shortcut set", browser_context_shortcut)
        rename_context_shortcut = run_cli(cli_path, ["settings", "shortcuts", "set", "renameTab", "cmd+option+r"], home)
        assert_ok(failures, "non-browser shortcut may share browser-context chord", rename_context_shortcut)
        same_context_conflict = run_cli(cli_path, ["settings", "shortcuts", "set", "renameWorkspace", "cmd+option+r"], home)
        assert_fails(
            failures,
            "same-context shortcut conflict",
            same_context_conflict,
            "conflicts with renameTab",
        )

        swap_source = run_cli(cli_path, ["settings", "shortcuts", "set", "focusRight", "cmd+option+l"], home)
        assert_ok(failures, "shortcut swap source setup", swap_source)
        shortcut_swap_import_path = home / "shortcut-swap-import.json"
        shortcut_swap_import_path.write_text(
            json.dumps({"shortcuts": {"bindings": {"focusLeft": "cmd+option+l", "focusRight": "cmd+option+h"}}}),
            encoding="utf-8",
        )
        shortcut_swap_import = run_cli(cli_path, ["settings", "import", str(shortcut_swap_import_path)], home)
        assert_ok(failures, "shortcut import accepts final-state swap", shortcut_swap_import)
        swap_config = read_config(home)
        swap_bindings = swap_config.get("shortcuts", {}).get("bindings", {})
        if swap_bindings.get("focusLeft") != "cmd+option+l" or swap_bindings.get("focusRight") != "cmd+option+h":
            failures.append(f"shortcut import swap did not persist the final bindings: {swap_config}")

        before_shortcut_import = read_config(home)
        shortcut_conflict_import_path = home / "bad-shortcut-import.json"
        shortcut_conflict_import_path.write_text(
            json.dumps({"shortcuts": {"bindings": {"openSettings": "cmd+n"}}}),
            encoding="utf-8",
        )
        shortcut_conflict_import = run_cli(cli_path, ["settings", "import", str(shortcut_conflict_import_path)], home)
        assert_fails(failures, "atomic shortcut import conflict", shortcut_conflict_import, "conflicts with newTab")
        after_shortcut_import = read_config(home)
        if after_shortcut_import != before_shortcut_import:
            failures.append(
                f"failed shortcut import changed cmux.json: before={before_shortcut_import} after={after_shortcut_import}"
            )

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
        if bindings.get("newTab") != "none":
            failures.append(f"shortcut --force did not clear the previous conflicting binding: {config}")

        config.setdefault("shortcuts", {}).setdefault("bindings", {})["legacyAction"] = "cmd+option+y"
        config_path(home).write_text(json.dumps(config), encoding="utf-8")

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
        if "shortcuts.bindings.legacyAction" in exported_text:
            failures.append("settings export --format toml exported an unrecognized legacy shortcut action")
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

        before_cancelled_reset = read_config(home)
        cancelled_reset = run_cli(cli_path, ["settings", "reset"], home, input_text="no\n")
        assert_fails(failures, "settings reset cancellation", cancelled_reset, "settings reset cancelled")
        after_cancelled_reset = read_config(home)
        if after_cancelled_reset != before_cancelled_reset:
            failures.append(
                f"cancelled settings reset changed cmux.json: before={before_cancelled_reset} after={after_cancelled_reset}"
            )

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
