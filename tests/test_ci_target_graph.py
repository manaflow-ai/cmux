#!/usr/bin/env python3
"""ci-target-graph.py records a test target's literal reads in their on-disk case.

On macOS the default filesystem ignores case, so a fixture string such as
"app/README.md" exists there because the repository tracks App/README.md. The
Mac regeneration then wrote "app/" into ci-target-graph.json while the Linux
autofix removed it again, and each run of either one flipped the committed
graph. A literal counts as a read only when every path segment matches an
entry on disk exactly.

The case-insensitive filesystem is simulated, so the test bites on Linux too.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "ci-target-graph.py"


def load_graph_module():
    spec = importlib.util.spec_from_file_location("ci_target_graph", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def case_insensitive(real):
    """Path.exists/is_dir as APFS answers them: any spelling of a real entry."""

    def lookup(path: Path) -> Path | None:
        path = Path(os.path.abspath(path))
        current = Path(path.anchor)
        for part in path.parts[1:]:
            try:
                names = os.listdir(current)
            except OSError:
                return None
            match = next((name for name in names if name.lower() == part.lower()), None)
            if match is None:
                return None
            current = current / match
        return current

    def patched(self, *args, **kwargs):
        found = lookup(self)
        return found is not None and real(found, *args, **kwargs)

    return patched


class LiteralReadsCase(unittest.TestCase):
    def setUp(self):
        self.graph = load_graph_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        (root / "App").mkdir()
        (root / "App" / "README.md").write_text("app\n", encoding="utf-8")
        (root / ".git").mkdir()
        (root / ".git" / "config").write_text("[core]\n", encoding="utf-8")
        (root / ".claude").mkdir()
        (root / ".claude" / "settings.json").write_text("{}\n", encoding="utf-8")
        (root / ".codex").mkdir()
        (root / ".codex" / "hooks.json").write_text("{}\n", encoding="utf-8")
        (root / "schemas" / "settings").mkdir(parents=True)
        (root / "schemas" / "settings" / "schema.json").write_text("{}\n", encoding="utf-8")
        package = root / "Packages" / "macOS" / "CmuxNext"
        self.tests = package / "Tests" / "SomeTests"
        self.tests.mkdir(parents=True)
        (self.tests / "SomeTests.swift").write_text(
            'let fixture = "app/README.md"\n'
            'let schema = "schemas/settings/schema.json"\n'
            'let checkoutState = ".git/config"\n'
            'let home = ".claude/settings.json"\n'
            'let codexHome = ".codex/hooks.json"\n'
            'let real = "App/README.md"\n',
            encoding="utf-8",
        )
        for name, value in (("ROOT", root), ("PACKAGE", package)):
            patcher = mock.patch.object(self.graph, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for method in ("exists", "is_dir"):
            patcher = mock.patch.object(Path, method, case_insensitive(getattr(Path, method)))
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_a_literal_in_another_case_is_not_a_read(self):
        self.assertEqual(
            self.graph.literal_reads(self.tests),
            ["App/README.md", "schemas/settings/schema.json"],
        )


class GlobReadsCase(unittest.TestCase):
    """A literal with `*` (PageDevServerTests' "webviews/src/pages/*/main.tsx") is recorded as that
    pattern when it matches a file in its exact case, and dropped when it matches none."""

    def setUp(self):
        self.graph = load_graph_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        for page in ("settings", "files"):
            (root / "webviews" / "src" / "pages" / page).mkdir(parents=True)
            (root / "webviews" / "src" / "pages" / page / "main.tsx").write_text("x\n", encoding="utf-8")
        package = root / "Packages" / "macOS" / "CmuxNext"
        self.tests = package / "Tests" / "PagesTests"
        self.tests.mkdir(parents=True)
        (self.tests / "PagesTests.swift").write_text(
            'let entries = "webviews/src/pages/*/main.tsx"\n'
            'let none = "webviews/src/pages/*/missing.tsx"\n'
            'let wrongCase = "Webviews/src/pages/*/main.tsx"\n'
            'let git = ".git/*/config"\n',
            encoding="utf-8",
        )
        for name, value in (("ROOT", root), ("PACKAGE", package)):
            patcher = mock.patch.object(self.graph, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_a_pattern_literal_is_a_pattern_read(self):
        self.assertEqual(self.graph.literal_reads(self.tests), ["webviews/src/pages/*/main.tsx"])


if __name__ == "__main__":
    sys.exit(unittest.main())
