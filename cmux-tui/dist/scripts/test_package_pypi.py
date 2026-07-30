#!/usr/bin/env python3
"""Regression tests for the generated PyPI launcher."""

from __future__ import annotations

import os
import unittest
from pathlib import Path
from unittest.mock import patch

from package_pypi import TARGETS, wheel_bytes


def launcher_command(version: str, argv0: str) -> str:
    files = wheel_bytes(version, "test-platform", b"binary")
    source = next(data for name, data, _ in files if name == "cmux_tui/_main.py")
    namespace: dict[str, object] = {}
    exec(compile(source, "cmux_tui/_main.py", "exec"), namespace)
    return namespace["_launcher_command"](argv0)  # type: ignore[operator]


class LauncherCommandTests(unittest.TestCase):
    def test_launcher_remains_compatible_with_python_3_8(self) -> None:
        files = wheel_bytes("1.2.3", "test-platform", b"binary")
        source = next(data for name, data, _ in files if name == "cmux_tui/_main.py")

        self.assertNotIn(b".removeprefix(", source)

    def test_uv_cache_restarts_the_same_version(self) -> None:
        self.assertEqual(
            launcher_command(
                "1.2.3",
                "/Users/test/Library/Caches/uv/archive-v0/abcdefgh/bin/cmux",
            ),
            "uvx cmux==1.2.3",
        )

    def test_custom_uv_cache_restarts_the_same_version(self) -> None:
        with patch.dict(os.environ, {"UV_CACHE_DIR": "/tmp/uv-cache"}):
            self.assertEqual(
                launcher_command(
                    "1.2.3",
                    "/tmp/uv-cache/archive-v0/abcdefgh/bin/cmux",
                ),
                "uvx cmux==1.2.3",
            )

    def test_pipx_run_cache_restarts_the_same_version(self) -> None:
        self.assertEqual(
            launcher_command(
                "1.2.3",
                "/Users/test/Library/Caches/pipx/0123456789abcde/bin/cmux",
            ),
            "pipx run --spec cmux==1.2.3 cmux",
        )

    def test_pipx_run_dot_cache_restarts_the_same_version(self) -> None:
        self.assertEqual(
            launcher_command(
                "1.2.3",
                "/Users/test/.local/pipx/.cache/0123456789abcde/bin/cmux",
            ),
            "pipx run --spec cmux==1.2.3 cmux",
        )

    def test_stable_install_path_is_reused_directly(self) -> None:
        self.assertEqual(
            launcher_command("1.2.3", "/Users/test/.local/bin/cmux"),
            "/Users/test/.local/bin/cmux",
        )


class DarwinCompatibilityTests(unittest.TestCase):
    def test_wheels_require_the_first_representable_safe_macos_floor(self) -> None:
        tags = {
            target.rust_target: target.platform_tags
            for target in TARGETS
            if target.rust_target.endswith("-apple-darwin")
        }

        self.assertEqual(
            tags,
            {
                "aarch64-apple-darwin": ("macosx_15_0_arm64",),
                "x86_64-apple-darwin": ("macosx_15_0_x86_64",),
            },
        )

    def test_release_build_and_wheels_share_one_macos_minimum(self) -> None:
        compatibility_file = Path(__file__).resolve().parents[1] / "macos-deployment-target.txt"
        self.assertEqual(compatibility_file.read_text().strip(), "15.0")

        workflow = (
            Path(__file__).resolve().parents[3]
            / ".github"
            / "workflows"
            / "cmux-tui-build-package.yml"
        ).read_text()
        self.assertGreaterEqual(workflow.count("dist/macos-deployment-target.txt"), 2)
        readme = Path(__file__).resolve().parents[2] / "README.md"
        self.assertIn("macOS 15 or newer", readme.read_text())

    def test_intel_release_uses_the_apple_linker_deployment_target(self) -> None:
        workflow = (
            Path(__file__).resolve().parents[3]
            / ".github"
            / "workflows"
            / "cmux-tui-build-package.yml"
        ).read_text()
        cross_build = workflow.split("- name: Build cmux-tui (cross)", 1)[1].split(
            "- name: Stage binary", 1
        )[0]

        self.assertIn('if [[ "$RUNNER_OS" == macOS ]]; then', cross_build)
        self.assertIn(
            "cargo build -p cmux-tui --bin cmux-tui --release --locked --target",
            cross_build,
        )


if __name__ == "__main__":
    unittest.main()
