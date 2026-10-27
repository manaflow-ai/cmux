#!/usr/bin/env python3
"""linux-tier.py writes the `generated` part of linux-tier.json and the Linux mode literal of Package.swift
(p15-oracle-002).

LinuxTierTests build a small package in a temp dir with its own dump-package JSON, so they do not depend on the
live tree. The committed-tree cases read the real manifest. Where swift runs (PATH or $SWIFT), SwiftManifestTests
evaluate the real manifest with and without CMUX_SWIFTPM_TARGET_LINUX=1 and check the result against
linux-tier.json, and the committed files are checked fresh against that dump.

  python3 scripts/cmux-next/tests/test_linux_tier.py
  LINUX_TIER_DUMP=/path/dump.json python3 ...   (without swift: checks the committed files against that dump)
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
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
    "Core/Wait.swift": "#if canImport(Darwin)\nimport Darwin\n#elseif os(Linux)\nimport CCmuxNextLinux\n#endif\n",
    "Uses/Zip.swift": "@preconcurrency import Compression\n",
    "Blocked/B.swift": "import Foundation\n",
    "AppUI/V.swift": "import SwiftUI\n",
    "App/A.swift": "import AppUI\n",
}


MANIFEST = "// swift-tools-version: 6.2\nlet before = 1\n" + lt.BEGIN + "    stale\n" + lt.END + "let after = 2\n"


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
        (package / "Sources/CCmuxNextLinux").mkdir(parents=True)
        self.saved = (lt.ROOT, lt.PACKAGE, lt.TIER, lt.MANIFEST)
        lt.ROOT, lt.PACKAGE, lt.TIER, lt.MANIFEST = (Path(self.temp.name), package, package / "linux-tier.json",
                                                     package / "Package.swift")
        lt.TIER.write_text(json.dumps(TIER), encoding="utf-8")
        lt.MANIFEST.write_text(MANIFEST, encoding="utf-8")
        self.dump = Path(self.temp.name) / "dump.json"
        self.dump.write_text(json.dumps(DUMP), encoding="utf-8")
        self.original_local = graph.local_packages
        graph.local_packages = lambda manifest: {"cmuxtheme": "Packages/Shared/CmuxTheme"}

    def tearDown(self):
        lt.ROOT, lt.PACKAGE, lt.TIER, lt.MANIFEST = self.saved
        graph.local_packages = self.original_local
        self.temp.cleanup()

    def generated(self, tier=TIER, dump=DUMP):
        return lt.build(json.loads(json.dumps(tier)), dump, graph)

    def test_keeps_tier_targets_in_wave_order_with_ffi_and_the_system_stand_ins(self):
        self.assertEqual(self.generated()["targets"],
                         ["Core", "CCmuxAppFFILinux", "Uses", "Blocked", "CZlib", "CCmuxNextLinux"])

    def test_a_system_stand_in_nobody_imports_is_not_a_target(self):
        (lt.PACKAGE / "Sources/Core/Wait.swift").unlink()
        self.assertNotIn("CCmuxNextLinux", self.generated()["targets"])

    def test_a_missing_system_stand_in_folder_is_refused(self):
        (lt.PACKAGE / "Sources/CCmuxNextLinux").rmdir()
        with self.assertRaises(SystemExit):
            self.generated()

    def test_test_target_kept_only_when_all_its_targets_are_in_the_tier(self):
        self.assertEqual(self.generated()["testTargets"], ["CoreTests"])

    def test_products_only_when_every_target_is_in_the_tier(self):
        self.assertEqual(self.generated()["products"], ["CoreKit"])

    def test_packages_are_the_used_ones_without_excluded(self):
        generated = self.generated()
        self.assertEqual(generated["pathDependencies"], ["Packages/Shared/CmuxTheme"])
        self.assertEqual(generated["remoteDependencies"], ["swift-atomics", "swift-crypto"])

    def test_stand_ins_follow_imports(self):
        self.assertEqual(self.generated()["linuxDependencies"],
                         {"Core": ["CCmuxNextLinux", "Crypto"], "Uses": ["CZlib"]})

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

    def literal(self) -> str:
        text = lt.MANIFEST.read_text(encoding="utf-8")
        return text[text.index(lt.BEGIN) + len(lt.BEGIN):text.index(lt.END)]

    def test_the_manifest_literal_carries_ffi_and_the_lists_only(self):
        self.assertEqual(lt.main(["--dump", str(self.dump)], graph), 0)
        literal = self.literal()
        self.assertIn('            replaces: "CCmuxAppFFI",\n', literal)
        self.assertIn('            libraryDirectory: ".build-linux/ffi/lib",\n', literal)
        self.assertIn('        generated: LinuxTier.Generated(\n            targets: [\n                "Core",\n'
                      '                "CCmuxAppFFILinux",\n', literal)
        self.assertIn('            testTargets: ["CoreTests"],\n', literal)
        self.assertIn('            linuxDependencies: [\n                "Core": ["CCmuxNextLinux", "Crypto"],\n', literal)
        self.assertNotIn("blockedEdges", literal)
        text = lt.MANIFEST.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("// swift-tools-version: 6.2\nlet before = 1\n" + lt.BEGIN))
        self.assertTrue(text.endswith(lt.END + "let after = 2\n"))
        self.assertEqual(lt.main(["--check", "--dump", str(self.dump)], graph), 0)

    def test_a_tier_change_is_a_manifest_text_change(self):
        """SwiftPM keys its manifest cache on the manifest text, so a tier change must change Package.swift."""
        lt.main(["--dump", str(self.dump)], graph)
        before = lt.MANIFEST.read_text(encoding="utf-8")
        lt.TIER.write_text(json.dumps(dict(TIER, waves=[["Core", "CCmuxAppFFILinux"], ["Uses"]])), encoding="utf-8")
        self.assertEqual(lt.main(["--check", "--dump", str(self.dump)], graph), 1)
        lt.main(["--dump", str(self.dump)], graph)
        self.assertNotEqual(lt.MANIFEST.read_text(encoding="utf-8"), before)
        self.assertNotIn('"Blocked"', self.literal())

    def test_check_fails_on_a_hand_edited_literal(self):
        lt.main(["--dump", str(self.dump)], graph)
        text = lt.MANIFEST.read_text(encoding="utf-8")
        lt.MANIFEST.write_text(text.replace('                "Uses",\n', "", 1), encoding="utf-8")
        self.assertEqual(lt.main(["--check", "--dump", str(self.dump)], graph), 1)

    def test_a_manifest_without_the_markers_is_refused(self):
        lt.MANIFEST.write_text("// swift-tools-version: 6.2\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            lt.main(["--dump", str(self.dump)], graph)


def linux_mode_block(text: str) -> str:
    """The CMUX_SWIFTPM_TARGET_LINUX gate of the committed manifest, up to its closing brace."""
    start = text.index('if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {\n')
    return text[start:text.index("\n}\n", start)]


class CommittedManifestTests(unittest.TestCase):
    def test_the_linux_mode_reads_no_file(self):
        """SwiftPM's manifest cache key does not cover a file the manifest reads, so a change to it would be missed."""
        block = linux_mode_block(lt.MANIFEST.read_text(encoding="utf-8"))
        for read in ("contentsOf", "FileManager", "JSONDecoder", "fopen", "FileHandle"):
            self.assertNotIn(read, block)
        self.assertIn(lt.BEGIN, block)
        self.assertIn(lt.END, block)


def find_swift() -> str | None:
    return os.environ.get("SWIFT") or shutil.which("swift")


def identity_of(dependency: dict) -> str:
    ((_, specs),) = dependency.items()
    return specs[0]["identity"].lower()


def dependency_key(dependency: dict) -> tuple:
    """A dump-package target dependency: (name,) for a target, (product, package) for a product."""
    how, name = graph.dependency_name(dependency)
    return (name,) if how in ("target", "byName") else (dependency["product"][0], name.lower())


@unittest.skipUnless(find_swift(), "swift is not installed (scripts/cmux-next/linux/setup-swift.sh)")
class SwiftManifestTests(unittest.TestCase):
    """The real manifest evaluated by SwiftPM, without and with CMUX_SWIFTPM_TARGET_LINUX=1."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        temp = Path(cls.temp.name)
        env = {key: value for key, value in os.environ.items() if key != lt.LINUX_VARIABLE}
        cls.apple_text = cls.dump(lt.PACKAGE, env, temp / "scratch-apple")
        cls.apple = json.loads(cls.apple_text)
        cls.linux = json.loads(cls.dump(lt.PACKAGE, dict(env, **{lt.LINUX_VARIABLE: "1"}), temp / "scratch-linux"))
        base = cls.mirror_without_linux_mode(temp / "base")
        cls.base_text = cls.dump(base, env, temp / "scratch-base").replace(str(temp / "base"), str(lt.ROOT))
        cls.apple_file = temp / "apple.json"
        cls.apple_file.write_text(cls.apple_text, encoding="utf-8")
        cls.tier = json.loads(lt.TIER.read_text(encoding="utf-8"))
        cls.generated = cls.tier["generated"]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @staticmethod
    def dump(package: Path, env: dict, scratch: Path) -> str:
        command = [find_swift(), "package", "--scratch-path", str(scratch), "--manifest-cache", "none", "dump-package"]
        return subprocess.run(command, cwd=package, env=env, check=True, capture_output=True, text=True).stdout

    @staticmethod
    def mirror_without_linux_mode(root: Path) -> Path:
        """``root`` laid out like the checkout: the CmuxNext manifest without its `#if os(Linux)` block, every
        other entry a symlink, so the manifest's relative package paths resolve as they do in the checkout."""
        package = root / lt.PACKAGE.relative_to(lt.ROOT)
        package.mkdir(parents=True)
        real, copy = lt.PACKAGE, package
        while real != lt.ROOT:
            for entry in real.parent.iterdir():
                if entry != real:
                    (copy.parent / entry.name).symlink_to(entry)
            real, copy = real.parent, copy.parent
        for entry in lt.PACKAGE.iterdir():
            if entry.name not in ("Package.swift", ".build", ".swiftpm"):
                (package / entry.name).symlink_to(entry)
        text = lt.MANIFEST.read_text(encoding="utf-8")
        stripped, count = re.subn(r"\n#if os\(Linux\)\n.*?\n#endif\n", "\n", text, flags=re.S)
        if count != 1:
            raise AssertionError(f"{lt.MANIFEST}: expected one #if os(Linux) block, found {count}")
        (package / "Package.swift").write_text(stripped, encoding="utf-8")
        return package

    def test_without_the_variable_the_dump_is_the_apple_manifest(self):
        self.assertEqual(self.apple_text, self.base_text)

    def test_with_the_variable_only_the_tier_targets_and_products_remain(self):
        self.assertEqual(sorted(t["name"] for t in self.linux["targets"]),
                         sorted(self.generated["targets"] + self.generated["testTargets"]))
        self.assertEqual(sorted(p["name"] for p in self.linux["products"]), sorted(self.generated["products"]))

    def test_no_target_depends_on_the_xcframework(self):
        replaced = (self.tier["ffi"]["replaces"],)
        for target in self.linux["targets"]:
            self.assertNotIn(replaced, [dependency_key(d) for d in target["dependencies"]], target["name"])

    def test_the_packages_are_the_tier_packages(self):
        expected = {lt.identity(p) for p in self.generated["pathDependencies"]} | set(self.generated["remoteDependencies"])
        self.assertEqual({identity_of(d) for d in self.linux["dependencies"]}, expected)

    def test_each_target_keeps_what_linux_tier_py_keeps(self):
        """The Swift filter and linux-tier.py agree: the Apple dependencies minus blockedEdges, then the stand-ins."""
        apple = {target["name"]: target for target in self.apple["targets"]}
        ffi = self.tier["ffi"]
        for target in self.linux["targets"]:
            name = target["name"]
            if name not in apple:
                continue
            blocked = set(self.generated["blockedEdges"].get(name, []))
            expected = []
            for dependency in apple[name]["dependencies"]:
                key = dependency_key(dependency)
                if len(key) == 1:
                    key = (ffi["target"],) if key == (ffi["replaces"],) else key
                    shown = key[0]
                else:
                    shown = f"{key[0]} ({graph.dependency_name(dependency)[1]})"
                if shown not in blocked:
                    expected.append(key)
            expected += [(s,) if s in lt.SYSTEM_TARGETS else (s, lt.CRYPTO_PACKAGE)
                         for s in self.generated["linuxDependencies"].get(name, [])]
            self.assertEqual([dependency_key(d) for d in target["dependencies"]], expected, name)

    def test_the_committed_tier_and_manifest_literal_are_fresh(self):
        self.assertEqual(lt.main(["--check", "--dump", str(self.apple_file)]), 0)


@unittest.skipUnless(os.environ.get("LINUX_TIER_DUMP") and not find_swift(),
                     "without swift, set LINUX_TIER_DUMP to a dump-package JSON (SwiftManifestTests cover it with swift)")
class CommittedTierTests(unittest.TestCase):
    def test_committed_file_is_fresh(self):
        self.assertEqual(lt.main(["--check", "--dump", os.environ["LINUX_TIER_DUMP"]]), 0)


if __name__ == "__main__":
    unittest.main()
