#!/usr/bin/env python3
"""web-bundle-key.py's named_paths: the paths outside webviews/ a webviews file names as a quoted literal, which
route the web checks (checked_inputs) and pick the tests naming them (webviews_pr_shards.py touched).

#64614 deleted a Swift file heldMessage.test.tsx read by path: no web check picked the test, and it sat red on
feat-cmux-next. A named path counts whether or not it exists, so the deletion still routes.

    python3 tests/test_web_bundle_key_named_paths.py
"""
from __future__ import annotations

import importlib.util
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("web_bundle_key_named", ROOT / "scripts/cmux-next/web-bundle-key.py")
key = importlib.util.module_from_spec(spec)
spec.loader.exec_module(key)
TOPS = {"Packages", "schemas", "cmux-tui"}


class NamedPathsTest(unittest.TestCase):
    def named(self, text: str, rel: str = "webviews/src/a/b.test.ts") -> set[str]:
        return key.named_paths(rel, text, TOPS)

    def test_a_repo_path_and_a_relative_one_resolve_to_the_repo_path(self) -> None:
        self.assertEqual(self.named('read(join(root, "Packages/App/Rules.swift"))'), {"Packages/App/Rules.swift"})
        self.assertEqual(self.named("new URL('../../../schemas/x/y.json', import.meta.url)"), {"schemas/x/y.json"})
        self.assertEqual(self.named("`cmux-tui/crates/p/policy.json`"), {"cmux-tui/crates/p/policy.json"})

    def test_webviews_paths_unknown_roots_and_bare_names_are_not_reads(self) -> None:
        self.assertEqual(self.named('import x from "../c.ts"; "webviews/src/d.ts"; "react/jsx.js"; "Rules.swift"'), set())
        self.assertEqual(self.named('"../../../../outside/x.json"'), set())

    def test_checked_inputs_add_reads_to_the_routed_inputs(self) -> None:
        routed = key.routed_inputs(str(ROOT))
        started = time.monotonic()
        checked = key.checked_inputs(str(ROOT))
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(checked[: len(routed)], routed)
        self.assertTrue(all(not p.startswith("webviews/") for p in checked[len(routed):]))


if __name__ == "__main__":
    unittest.main()
