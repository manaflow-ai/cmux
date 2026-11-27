#!/usr/bin/env python3
"""
Regression test: unified config settings resolves the right files and renders
the synced preview with cmux overrides on top of Ghostty base values.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path(__file__).resolve().parents[1]


def compile_probe(repo_root: Path, output_path: Path) -> None:
    probe_sources = [
        repo_root / "Sources" / "Settings" / "ConfigSource.swift",
        repo_root / "tests_v2" / "config_source_probe.swift",
    ]
    command = ["xcrun", "swiftc", *map(str, probe_sources), "-o", str(output_path)]
    subprocess.run(
        command,
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )


def write_text(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")


def run_probe(
    executable: Path,
    home_directory: Path,
    bundle_identifier: str = "com.cmuxterm.app",
) -> dict:
    result = subprocess.run(
        [str(executable), str(home_directory), bundle_identifier],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_uses_cmux_config_ghostty_and_removes_standalone_tab(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        cmux_legacy_config = home / "Library" / "Application Support" / "com.cmuxterm.app" / "config"
        cmux_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )
        ghostty_config = home / ".config" / "ghostty" / "config"

        write_text(
            ghostty_config,
            "theme = Solarized Light\nbackground = #111111\nfont-size = 13\n",
        )
        write_text(cmux_legacy_config, "background = #000000\n")
        write_text(
            cmux_config,
            "background = #222222\ncopy-on-select = clipboard\n",
        )

        payload = run_probe(executable, home)

        expect(payload["sources"] == ["cmux", "synced"], f"unexpected config sources: {payload}")
        expect(payload["cmux"]["path"] == str(cmux_config), f"unexpected cmux path: {payload}")

        synced_path = Path(payload["synced"]["path"])
        expect(synced_path.exists(), f"synced preview path should exist: {payload}")

        synced_contents = str(payload["synced"]["contents"])
        expect(
            "theme = Solarized Light  # from: ~/.config/ghostty/config:1" in synced_contents,
            f"synced preview should keep Ghostty-only keys with provenance: {synced_contents}",
        )
        expect(
            "background = #222222  # from: ~/Library/Application Support/com.cmuxterm.app/config.ghostty:1"
            in synced_contents,
            f"synced preview should use cmux override for duplicate keys: {synced_contents}",
        )
        expect(
            "copy-on-select = clipboard  # from: ~/Library/Application Support/com.cmuxterm.app/config.ghostty:2"
            in synced_contents,
            f"synced preview should include cmux-only keys: {synced_contents}",
        )
        expect(
            "background = #111111" not in synced_contents,
            f"overridden Ghostty value should not survive in synced preview: {synced_contents}",
        )


def test_uses_legacy_cmux_config_when_config_ghostty_is_empty(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        cmux_legacy_config = home / "Library" / "Application Support" / "com.cmuxterm.app" / "config"
        cmux_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )

        write_text(cmux_legacy_config, "background = #000000\n")
        write_text(cmux_config, "")

        payload = run_probe(executable, home)

        expect(payload["cmux"]["path"] == str(cmux_legacy_config), f"unexpected cmux path: {payload}")
        expect(payload["loadPaths"] == [str(cmux_legacy_config)], f"unexpected load paths: {payload}")
        expect("background = #000000" in payload["cmux"]["contents"], f"wrong cmux contents: {payload}")


def test_falls_back_to_app_support_ghostty_when_dotconfig_missing(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        cmux_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )
        ghostty_app_support = (
            home
            / "Library"
            / "Application Support"
            / "com.mitchellh.ghostty"
            / "config"
        )

        write_text(ghostty_app_support, "font-size = 14\nselection-background = #333333\n")
        write_text(cmux_config, "font-size = 17\n")

        payload = run_probe(executable, home)

        synced_contents = str(payload["synced"]["contents"])
        expect(
            "font-size = 17  # from: ~/Library/Application Support/com.cmuxterm.app/config.ghostty:1"
            in synced_contents,
            f"cmux override should win over Ghostty base font-size: {synced_contents}",
        )
        expect(
            "selection-background = #333333  # from: ~/Library/Application Support/com.mitchellh.ghostty/config:2"
            in synced_contents,
            f"Ghostty-only key should remain in synced preview: {synced_contents}",
        )


def test_debug_bundle_edits_variant_config_and_loads_variant_when_present(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        release_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )
        nightly_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app.debug.nightly.123"
            / "config.ghostty"
        )

        write_text(release_config, "font-size = 13\n")
        write_text(nightly_config, "font-size = 15\n")

        payload = run_probe(executable, home, "com.cmuxterm.app.debug.nightly.123")

        expect(payload["cmux"]["path"] == str(nightly_config), f"unexpected nightly path: {payload}")
        expect("font-size = 15" in payload["cmux"]["contents"], f"wrong nightly contents: {payload}")
        expect(payload["loadPaths"] == [str(nightly_config)], f"unexpected nightly load paths: {payload}")


def test_debug_bundle_uses_release_fallback_when_variant_missing(
    executable: Path,
) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        release_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )

        write_text(release_config, "font-size = 13\n")

        payload = run_probe(executable, home, "com.cmuxterm.app.debug.nightly.123")

        expect(payload["cmux"]["path"] == str(release_config), f"unexpected fallback edit path: {payload}")
        expect("font-size = 13" in payload["cmux"]["contents"], f"wrong fallback contents: {payload}")
        expect(payload["loadPaths"] == [str(release_config)], f"unexpected fallback load paths: {payload}")
        expect("font-size = 13" in payload["synced"]["contents"], f"synced preview should show fallback: {payload}")


def test_debug_bundle_targets_variant_config_when_no_current_or_fallback_config(
    executable: Path,
) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        variant_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app.debug.nightly.123"
            / "config.ghostty"
        )

        payload = run_probe(executable, home, "com.cmuxterm.app.debug.nightly.123")

        expect(payload["cmux"]["path"] == str(variant_config), f"unexpected empty edit path: {payload}")
        expect(payload["cmux"]["contents"] == "", f"empty variant target should have no contents: {payload}")
        expect(payload["loadPaths"] == [], f"unexpected empty load paths: {payload}")


def test_nightly_app_edits_nightly_config_and_falls_back_to_release_when_missing(
    executable: Path,
) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        release_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app"
            / "config.ghostty"
        )
        nightly_config = (
            home
            / "Library"
            / "Application Support"
            / "com.cmuxterm.app.nightly"
            / "config.ghostty"
        )

        write_text(release_config, "font-size = 13\n")

        payload = run_probe(executable, home, "com.cmuxterm.app.nightly")

        expect(payload["cmux"]["path"] == str(release_config), f"unexpected nightly fallback path: {payload}")
        expect(payload["loadPaths"] == [str(release_config)], f"unexpected nightly fallback paths: {payload}")

        write_text(nightly_config, "font-size = 16\n")

        payload = run_probe(executable, home, "com.cmuxterm.app.nightly")

        expect(payload["cmux"]["path"] == str(nightly_config), f"unexpected nightly edit path: {payload}")
        expect(payload["loadPaths"] == [str(nightly_config)], f"unexpected nightly load paths: {payload}")


def main() -> int:
    repo_root = get_repo_root()
    with tempfile.TemporaryDirectory(prefix="cmux-config-source-probe-") as tmp:
        executable = Path(tmp) / "config_source_probe"
        compile_probe(repo_root, executable)
        test_uses_cmux_config_ghostty_and_removes_standalone_tab(executable)
        test_uses_legacy_cmux_config_when_config_ghostty_is_empty(executable)
        test_falls_back_to_app_support_ghostty_when_dotconfig_missing(executable)
        test_debug_bundle_edits_variant_config_and_loads_variant_when_present(executable)
        test_debug_bundle_uses_release_fallback_when_variant_missing(executable)
        test_debug_bundle_targets_variant_config_when_no_current_or_fallback_config(executable)
        test_nightly_app_edits_nightly_config_and_falls_back_to_release_when_missing(executable)

    print("PASS: config settings resolves active cmux Ghostty paths and synced preview precedence correctly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
