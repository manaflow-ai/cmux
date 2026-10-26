#!/usr/bin/env python3
"""linux-tier.py writes the `generated` part of linux-tier.json (p15-oracle-002).

Each case builds a small package in a temp dir with its own dump-package JSON, so the cases do not depend on
the live tree; the last case checks that the committed linux-tier.json is fresh against a given dump.

  python3 -m pytest scripts/cmux-next/tests/test_linux_tier.py
  LINUX_TIER_DUMP=/path/dump.json python3 -m pytest ...   (also checks the committed file against that dump)
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "linux" / "linux-tier.py"


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_linux_tier", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


lt = load()
graph = lt.graph_module()

TIER = {
    "waves": [["Core", "CCmuxAppFFILinux"], ["Uses", "Blocked"]],
    "new": ["Later"],
    "excludedPackages": ["Sparkle"],
    "ffi": {"replaces": "CCmuxAppFFI", "target": "CCmuxAppFFILinux", "library": "cmux_app_ffi",
            "libraryDirectory": ".build-linux/ffi/lib"},
}


def target(name, kind="regular", deps=()):
    return {"name": name, "type": kind, "dependencies": list(deps)}


def by_name(name):
    return {"byName": [name, None]}


def product(name, package):
    return {"product": [name, package, None, None]}


DUMP = {
    "dependencies": [
        {"fileSystem": [{"identity": "cmuxtheme", "path": "/repo/Packages/Shared/CmuxTheme"}]},
        {"sourceControl": [{"identity": "swift-atomics"}]},
        {"sourceControl": [{"identity": "sparkle"}]},
    ],
    "products": [
        {"name": "CoreKit", "targets": ["Core"]},
        {"name": "App", "targets": ["App"]},
    ],
    "targets": [
        target("Core", deps=[product("Atomics", "swift-atomics")]),
        target("Uses", deps=[by_name("Core"), by_name("CCmuxAppFFI"), product("CmuxTheme", "CmuxTheme")]),
        target("Blocked", deps=[by_name("Core"), by_name("AppUI"), product("Sparkle", "Sparkle")]),
        target("AppUI"),
        target("App", deps=[by_name("AppUI")]),
        target("CCmuxAppFFI", kind="binary"),
        target("CoreTests", kind="test", deps=[by_name("Core")]),
        target("AppUITests", kind="test", deps=[by_name("AppUI")]),
    ],
}

SOURCES = {
    "Core/Hash.swift": "internal import CryptoKit\n",
    "Uses/Zip.swift": "@preconcurrency import Compression\n",
    "Blocked/B.swift": "import Foundation\n",
    "AppUI/V.swift": "import SwiftUI\n",
    "App/A.swift": "import AppUI\n",
}


class LinuxTierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        package = Path(self.temp.name) / "Packages/macOS/CmuxNext"
        for relative, text in SOURCES.items():
            path = package / "Sources" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        (package / "Tests/CoreTests").mkdir(parents=True)
        (package / "Tests/AppUITests").mkdir(parents=True)
        (package / "Sources/CZlib").mkdir(parents=True)
        self.saved = (lt.ROOT, lt.PACKAGE, lt.TIER)
        lt.ROOT, lt.PACKAGE, lt.TIER = Path(self.temp.name), package, package / "linux-tier.json"
        self.original_local = graph.local_packages
        graph.local_packages = lambda manifest: {"cmuxtheme": "Packages/Shared/CmuxTheme"}

    def tearDown(self):
        lt.ROOT, lt.PACKAGE, lt.TIER = self.saved
        graph.local_packages = self.original_local
        self.temp.cleanup()

    def generated(self, tier=TIER, dump=DUMP):
        return lt.build(json.loads(json.dumps(tier)), dump, graph)

    def test_keeps_tier_targets_in_wave_order_with_ffi_and_zlib(self):
        self.assertEqual(self.generated()["targets"], ["Core", "CCmuxAppFFILinux", "Uses", "Blocked", "CZlib"])

    def test_test_target_kept_only_when_all_its_targets_are_in_the_tier(self):
        self.assertEqual(self.generated()["testTargets"], ["CoreTests"])

    def test_products_only_when_every_target_is_in_the_tier(self):
        self.assertEqual(self.generated()["products"], ["CoreKit"])

    def test_packages_are_the_used_ones_without_excluded(self):
        generated = self.generated()
        self.assertEqual(generated["pathDependencies"], ["Packages/Shared/CmuxTheme"])
        self.assertEqual(generated["remoteDependencies"], ["swift-atomics", "swift-crypto"])

    def test_stand_ins_follow_imports(self):
        self.assertEqual(self.generated()["linuxDependencies"], {"Core": ["Crypto"], "Uses": ["CZlib"]})

    def test_dropped_edges_are_listed_and_ffi_is_not_one(self):
        self.assertEqual(self.generated()["blockedEdges"], {"Blocked": ["AppUI", "Sparkle (Sparkle)"]})

    def test_new_targets_stay_absent_until_declared(self):
        self.assertEqual(self.generated()["absent"], ["Later"])

    def test_ffi_target_absent_without_the_binary_target(self):
        uses = target("Uses", deps=[by_name("Core")])
        dump = dict(DUMP, targets=[uses if t["name"] == "Uses" else t for t in DUMP["targets"]
                                   if t["name"] != "CCmuxAppFFI"])
        self.assertIn("CCmuxAppFFILinux", self.generated(dump=dump)["absent"])

    def test_listing_a_test_target_is_refused(self):
        tier = dict(TIER, waves=[["Core", "CoreTests"]])
        with self.assertRaises(SystemExit):
            self.generated(tier=tier)

    def test_listing_a_target_twice_is_refused(self):
        tier = dict(TIER, waves=[["Core"], ["Core"]])
        with self.assertRaises(SystemExit):
            self.generated(tier=tier)

    def test_output_is_stable(self):
        self.assertEqual(lt.render({"generated": self.generated()}), lt.render({"generated": self.generated()}))


@unittest.skipUnless(os.environ.get("LINUX_TIER_DUMP"), "set LINUX_TIER_DUMP to a dump-package JSON")
class CommittedTierTests(unittest.TestCase):
    def test_committed_file_is_fresh(self):
        self.assertEqual(lt.main(["--check", "--dump", os.environ["LINUX_TIER_DUMP"]]), 0)


if __name__ == "__main__":
    unittest.main()
