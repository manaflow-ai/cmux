#!/usr/bin/env python3
"""Regression tests for the generated PyPI launcher."""

from __future__ import annotations

import unittest

from package_pypi import wheel_bytes


def launcher_command(version: str, argv0: str) -> str:
    files = wheel_bytes(version, "test-platform", b"binary")
    source = next(data for name, data, _ in files if name == "cmux_tui/_main.py")
    namespace: dict[str, object] = {}
    exec(compile(source, "cmux_tui/_main.py", "exec"), namespace)
    return namespace["_launcher_command"](argv0)  # type: ignore[operator]


class LauncherCommandTests(unittest.TestCase):
    def test_uv_cache_restarts_the_same_version(self) -> None:
        self.assertEqual(
            launcher_command(
                "1.2.3",
                "/Users/test/Library/Caches/uv/archive-v0/abcdefgh/bin/cmux",
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

    def test_stable_install_path_is_reused_directly(self) -> None:
        self.assertEqual(
            launcher_command("1.2.3", "/Users/test/.local/bin/cmux"),
            "/Users/test/.local/bin/cmux",
        )


if __name__ == "__main__":
    unittest.main()
