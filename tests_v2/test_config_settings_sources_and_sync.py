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


def run_probe(executable: Path, home_directory: Path) -> dict:
    result = subprocess.run(
        [str(executable), str(home_directory)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_prefers_dotconfig_ghostty_and_overlays_cmux(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        cmux_config = home / "Library" / "Application Support" / "com.cmuxterm.app" / "config"
        ghostty_config = home / ".config" / "ghostty" / "config"

        write_text(
            ghostty_config,
            "theme = Solarized Light\nbackground = #111111\nfont-size = 13\n",
        )
        write_text(
            cmux_config,
            "background = #222222\ncopy-on-select = clipboard\n",
        )

        payload = run_probe(executable, home)

        expect(payload["cmux"]["path"] == str(cmux_config), f"unexpected cmux path: {payload}")
        expect(payload["ghostty"]["path"] == str(ghostty_config), f"unexpected ghostty path: {payload}")

        synced_path = Path(payload["synced"]["path"])
        expect(synced_path.exists(), f"synced preview path should exist: {payload}")

        synced_contents = str(payload["synced"]["contents"])
        expect(
            "theme = Solarized Light  # from: ~/.config/ghostty/config:1" in synced_contents,
            f"synced preview should keep Ghostty-only keys with provenance: {synced_contents}",
        )
        expect(
            "background = #222222  # from: ~/Library/Application Support/com.cmuxterm.app/config:1"
            in synced_contents,
            f"synced preview should use cmux override for duplicate keys: {synced_contents}",
        )
        expect(
            "copy-on-select = clipboard  # from: ~/Library/Application Support/com.cmuxterm.app/config:2"
            in synced_contents,
            f"synced preview should include cmux-only keys: {synced_contents}",
        )
        expect(
            "background = #111111" not in synced_contents,
            f"overridden Ghostty value should not survive in synced preview: {synced_contents}",
        )


def test_falls_back_to_app_support_ghostty_when_dotconfig_missing(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-config-settings-") as tmp:
        home = Path(tmp)
        cmux_config = home / "Library" / "Application Support" / "com.cmuxterm.app" / "config"
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

        expect(
            payload["ghostty"]["path"] == str(ghostty_app_support),
            f"ghostty resolver should fall back to app support config: {payload}",
        )

        synced_contents = str(payload["synced"]["contents"])
        expect(
            "font-size = 17  # from: ~/Library/Application Support/com.cmuxterm.app/config:1"
            in synced_contents,
            f"cmux override should win over Ghostty base font-size: {synced_contents}",
        )
        expect(
            "selection-background = #333333  # from: ~/Library/Application Support/com.mitchellh.ghostty/config:2"
            in synced_contents,
            f"Ghostty-only key should remain in synced preview: {synced_contents}",
        )


def main() -> int:
    repo_root = get_repo_root()
    with tempfile.TemporaryDirectory(prefix="cmux-config-source-probe-") as tmp:
        executable = Path(tmp) / "config_source_probe"
        compile_probe(repo_root, executable)
        test_prefers_dotconfig_ghostty_and_overlays_cmux(executable)
        test_falls_back_to_app_support_ghostty_when_dotconfig_missing(executable)

    print("PASS: config settings resolves cmux/ghostty paths and synced preview precedence correctly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
