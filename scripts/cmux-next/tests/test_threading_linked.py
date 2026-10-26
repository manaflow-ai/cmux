#!/usr/bin/env python3
"""The linked Shared/iOS packages in guardrails.py and threading-inventory.py (p02-threads-130).

CmuxNext's Package.swift links Shared, macOS and iOS packages by path, transitively, and the library targets its
`.target`s reach run in the app. guardrails' linked_closure() follows `.product(name:package:)` dependencies of
`.target`s to those `.package(path:)` links (each path against its own manifest's folder; a path with no
Package.swift, CmuxNext itself and folders outside Packages/ are not packages), and each reached target's own
`.target` dependencies. A package only a `.testTarget` uses, a linked package no target uses and a linked package's
`.executableTarget` (a separate process) are not in it. On a push, the blocking
rules and task-priority judge a linked package's Sources by its targets' isolation (not main actor), a CmuxThreading
`blockingCall { }` closure is the seam there, and an unlinked package, a linked package's Tests and the CmuxThreading
leaf itself are not judged. The inventory reads the same closure: `--count` prints CmuxNext's counts as before and
then a `linked:<rule>` line per rule (`"linked"` in `--count --jsonl`), and `--paths` picks linked files.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to either tool:
  python3 -m pytest scripts/cmux-next/tests/test_threading_linked.py
  python3 -I scripts/cmux-next/tests/test_threading_linked.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the tools below must not write __pycache__ beside them

SCRIPTS = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("cmux_next_threading_inventory_linked", SCRIPTS / "threading-inventory.py")
inventory = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = inventory
_spec.loader.exec_module(inventory)
guardrails = inventory.g

SRC = "Packages/macOS/CmuxNext/Sources/"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let uiSwiftSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let daemonSwiftSettings: [SwiftSetting] = []

let package = Package(
    name: "CmuxNext",
    dependencies: [
        .package(path: "../../Shared/Linked"),
        .package(path: "../../iOS/MobileLinked"),
        .package(path: "../CmuxUpdaterLike"),
        .package(path: "../../Shared/NoManifest"),
        .package(path: "../../../vendor/Outside"),
        // .package(path: "../../Shared/Unlinked"),
        .package(path: "../../Shared/TestOnly"),
        .package(path: "../../Shared/Unused"),
        .package(url: "https://example.com/remote.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CmuxNextUI", dependencies: [.product(name: "MobileLinked", package: "MobileLinked")],
                swiftSettings: uiSwiftSettings),
        .target(name: "CmuxNextCore", dependencies: [
            "CmuxNextUI", .product(name: "Linked", package: "Linked"),
            .product(name: "CmuxUpdaterLike", package: "CmuxUpdaterLike"),
            .product(name: "NoManifest", package: "NoManifest"), .product(name: "Outside", package: "Outside"),
            .product(name: "Remote", package: "remote"),
        ], swiftSettings: daemonSwiftSettings),
        .testTarget(name: "CmuxNextCoreTests", dependencies: [
            "CmuxNextCore", .product(name: "TestOnly", package: "TestOnly"),
        ]),
    ]
)
"""
LINKED_MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Linked",
    products: [
        .library(name: "Linked", targets: ["Linked"]),
        .executable(name: "linked-host", targets: ["linked-host"]),
    ],
    dependencies: [
        .package(path: "../Transitive"), .package(path: "../../../Packages/macOS/CmuxNext"),
        // Test-only: LinkedTests' fuzz helpers.
        .package(path: "../TestOnly"),
    ],
    targets: [
        .target(name: "Linked", dependencies: [
            .product(name: "Transitive", package: "Transitive"), .product(name: "CmuxNextCore", package: "CmuxNext"),
        ]),
        .executableTarget(name: "linked-host", dependencies: ["Linked"]),
        .testTarget(name: "LinkedTests", dependencies: ["Linked", .product(name: "TestOnly", package: "TestOnly")]),
    ]
)
"""
PLAIN_MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "{name}", targets: [.target(name: "{name}")])
"""
DOC = "# Threading model\n\n## Registered threads and queues\n\n- `com.cmuxterm.next.listed`\n\n## Reviewed blocking allowances\n"
RAW_READ = """import Foundation

func load(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}
"""
SEAMED_READ = """import CmuxThreading
import Foundation

func load(_ url: URL) -> Data? {
    try? blockingCall(.fileIO) { try Data(contentsOf: url) }
}
"""
POOL_READ = """import Foundation

func load(_ url: URL) async -> Data? {
    await Task.detached(priority: .utility) {
        try? blockingCall(.fileIO) { try Data(contentsOf: url) }
    }.value
}
"""
MAIN_READ = """import Foundation

@MainActor
func load(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}
"""
FILES = {
    "Packages/macOS/CmuxNext/Package.swift": MANIFEST,
    "plans/cmux-next/threading-model.md": DOC,
    SRC + "CmuxNextCore/Reader.swift": RAW_READ,
    "Packages/Shared/Linked/Package.swift": LINKED_MANIFEST,
    "Packages/Shared/Linked/Sources/Linked/Raw.swift": RAW_READ,
    "Packages/Shared/Linked/Sources/Linked/Seamed.swift": SEAMED_READ,
    "Packages/Shared/Linked/Sources/Linked/Pool.swift": POOL_READ,
    "Packages/Shared/Linked/Sources/Linked/Main.swift": MAIN_READ,
    "Packages/Shared/Linked/Tests/LinkedTests/RawTests.swift": RAW_READ,
    "Packages/Shared/Linked/Sources/linked-host/Raw.swift": RAW_READ,
    "Packages/Shared/TestOnly/Package.swift": PLAIN_MANIFEST.format(name="TestOnly"),
    "Packages/Shared/TestOnly/Sources/TestOnly/Raw.swift": RAW_READ,
    "Packages/Shared/Unused/Package.swift": PLAIN_MANIFEST.format(name="Unused"),
    "Packages/Shared/Unused/Sources/Unused/Raw.swift": RAW_READ,
    "Packages/Shared/Transitive/Package.swift": PLAIN_MANIFEST.format(name="Transitive"),
    "Packages/Shared/Transitive/Sources/Transitive/Raw.swift": RAW_READ,
    "Packages/iOS/MobileLinked/Package.swift": PLAIN_MANIFEST.format(name="MobileLinked"),
    "Packages/iOS/MobileLinked/Sources/MobileLinked/Raw.swift": RAW_READ,
    "Packages/macOS/CmuxUpdaterLike/Package.swift": PLAIN_MANIFEST.format(name="CmuxUpdaterLike"),
    "Packages/macOS/CmuxUpdaterLike/Sources/CmuxUpdaterLike/Raw.swift": RAW_READ,
    "Packages/Shared/NoManifest/Sources/NoManifest/Raw.swift": RAW_READ,
    "Packages/Shared/Unlinked/Package.swift": PLAIN_MANIFEST.format(name="Unlinked"),
    "Packages/Shared/Unlinked/Sources/Unlinked/Raw.swift": RAW_READ,
    "Packages/Shared/CmuxThreading/Package.swift": PLAIN_MANIFEST.format(name="CmuxThreading"),
    "Packages/Shared/CmuxThreading/Sources/CmuxThreading/Raw.swift": RAW_READ,
}
LINKED = ["Packages/Shared/Linked", "Packages/Shared/Transitive", "Packages/iOS/MobileLinked",
          "Packages/macOS/CmuxUpdaterLike"]


class Repository:
    """A throwaway git repository with FILES committed (`base`), outside every user's git configuration."""

    def __init__(self, root: str) -> None:
        self.path = Path(root) / "repository"
        config = Path(root) / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                          "[gc]\n\tauto = 0\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=root)
        self.path.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.path), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout

    def commit(self, files: dict[str, str], message: str) -> str:
        for path, text in files.items():
            (self.path / path).parent.mkdir(parents=True, exist_ok=True)
            (self.path / path).write_text(text)
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)
        return self.git("rev-parse", "HEAD").strip()


@contextlib.contextmanager
def without_git_environment():
    saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
    try:
        yield
    finally:
        os.environ.update(saved)


class ClosureTests(unittest.TestCase):
    def test_the_closure_follows_path_links_transitively(self):
        manifests = {path: text for path, text in FILES.items() if path.endswith("/Package.swift")}

        def read(paths: list[str]) -> dict[str, str]:
            return {p: manifests[p] for p in paths if p in manifests}

        found = guardrails.linked_closure(MANIFEST, read)
        self.assertEqual(sorted(found), sorted(LINKED))
        self.assertEqual({folder: set(package.targets) for folder, package in found.items()},
                         {folder: {folder.rsplit("/", 1)[1]} for folder in LINKED})
        self.assertEqual(guardrails.linked_closure("", read), {})

    def test_test_only_unused_and_executable_code_is_not_linked(self):
        manifests = {path: text for path, text in FILES.items() if path.endswith("/Package.swift")}
        found = guardrails.linked_closure(MANIFEST, lambda paths: {p: manifests[p] for p in paths if p in manifests})
        self.assertNotIn("Packages/Shared/TestOnly", found)  # only CmuxNextCoreTests and LinkedTests use it
        self.assertNotIn("Packages/Shared/Unused", found)  # `.package(path:)` with no product dependency
        self.assertNotIn("linked-host", found["Packages/Shared/Linked"].targets)  # a separate process
        self.assertNotIn("LinkedTests", found["Packages/Shared/Linked"].targets)

    def test_the_app_manifest_links_no_test_only_package(self):
        repo = SCRIPTS.parents[1]
        found = guardrails.linked_closure((repo / guardrails.PACKAGE_MANIFEST).read_text(), lambda paths: {
            p: (repo / p).read_text() for p in paths if (repo / p).is_file()})
        self.assertNotIn("Packages/Shared/CmuxFuzzSupport", found)
        if "Packages/Shared/CmuxVNCWebRTC" in found:
            self.assertNotIn("cmux-vnc-host", found["Packages/Shared/CmuxVNCWebRTC"].targets)

    def test_the_app_manifest_links_the_threading_leaf(self):
        manifest = (SCRIPTS.parents[1] / guardrails.PACKAGE_MANIFEST).read_text()
        self.assertIn("Packages/Shared/CmuxThreading", guardrails.linked_closure(manifest, lambda paths: {
            p: (SCRIPTS.parents[1] / p).read_text() for p in paths if (SCRIPTS.parents[1] / p).is_file()}))


class PushTests(unittest.TestCase):
    """What check() refuses when a push adds the same read to each package."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="cmux-guardrails-linked-")
        repo = Repository(cls.tmp.name)
        base_files = {path: text for path, text in FILES.items() if not path.endswith(".swift")
                      or path.endswith("/Package.swift")}
        base = repo.commit(base_files, "base")
        repo.commit({path: text for path, text in FILES.items() if path not in base_files}, "adds")
        with without_git_environment():
            refusals, cls.warnings = guardrails.check(repo.path, base, "HEAD")
        cls.found: dict[str, set[str]] = {}
        for rule, hits in refusals:
            for hit in hits:
                cls.found.setdefault(rule.id, set()).add(hit.path)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_no_rule_failed_open(self):
        self.assertEqual([w for w in self.warnings if w[0] == "guardrails"], [])

    def test_a_raw_read_in_every_linked_package_is_refused(self):
        expected = {SRC + "CmuxNextCore/Reader.swift"} | {
            f"{folder}/Sources/{folder.rsplit('/', 1)[1]}/Raw.swift" for folder in LINKED}
        self.assertEqual(self.found.get("raw-blocking"), expected)

    def test_unlinked_packages_tests_and_the_leaf_are_not_judged(self):
        judged = set().union(*self.found.values())
        for path in ("Packages/Shared/Unlinked/Sources/Unlinked/Raw.swift",
                     "Packages/Shared/NoManifest/Sources/NoManifest/Raw.swift",
                     "Packages/Shared/Linked/Tests/LinkedTests/RawTests.swift",
                     "Packages/Shared/Linked/Sources/linked-host/Raw.swift",
                     "Packages/Shared/TestOnly/Sources/TestOnly/Raw.swift",
                     "Packages/Shared/Unused/Sources/Unused/Raw.swift",
                     "Packages/Shared/CmuxThreading/Sources/CmuxThreading/Raw.swift"):
            self.assertNotIn(path, judged)

    def test_the_shared_blocking_call_is_the_seam_in_a_linked_package(self):
        judged = set().union(*self.found.values())
        self.assertNotIn("Packages/Shared/Linked/Sources/Linked/Seamed.swift", judged)

    def test_a_seam_on_the_pool_and_a_main_actor_read_are_still_refused(self):
        self.assertIn("Packages/Shared/Linked/Sources/Linked/Pool.swift", self.found.get("pool-blocking", set()))
        self.assertIn("Packages/Shared/Linked/Sources/Linked/Main.swift", self.found.get("main-blocking", set()))

    def test_a_linked_package_is_not_main_actor_by_default(self):
        # The same raw read is raw-blocking (not main-blocking) in a linked file, as in CmuxNextCore.
        self.assertNotIn("Packages/Shared/Linked/Sources/Linked/Raw.swift", self.found.get("main-blocking", set()))


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="cmux-inventory-linked-")
        cls.repo = Repository(cls.tmp.name)
        cls.repo.commit(FILES, "fixture")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_main(self, *args: str) -> str:
        out = io.StringIO()
        with without_git_environment(), contextlib.redirect_stdout(out):
            self.assertEqual(inventory.main(["--repo", str(self.repo.path), *args]), 0)
        return out.getvalue()

    def test_count_reports_the_linked_section_after_cmux_next(self):
        lines = self.run_main("--rule", "raw-blocking,pool-blocking,main-blocking", "--count").splitlines()
        # The inventory's raw-blocking also lists the raw primitive main-blocking took (Main.swift): 4 Raw.swift + 1.
        self.assertEqual(lines, ["raw-blocking 1", "pool-blocking 0", "main-blocking 0",
                                 "linked:raw-blocking 5", "linked:pool-blocking 1", "linked:main-blocking 1"])

    def test_count_jsonl_has_the_linked_section(self):
        counts = json.loads(self.run_main("--rule", "raw-blocking", "--count", "--jsonl"))
        self.assertEqual(counts, {"rules": {"raw-blocking": 1}, "linked": {"raw-blocking": 5}})

    def test_paths_and_groups_take_linked_files(self):
        records = [json.loads(line) for line in self.run_main(
            "--rule", "raw-blocking", "--paths", "Packages/Shared", "Packages/iOS", "--group", "module",
            "--jsonl").splitlines()]
        self.assertEqual(sorted((r["path"].rsplit("/", 1)[1], r["module"], r["group"], r["ui_target"])
                                for r in records), [
            ("Main.swift", "Linked", "module:Linked", False), ("Raw.swift", "Linked", "module:Linked", False),
            ("Raw.swift", "MobileLinked", "module:MobileLinked", False),
            ("Raw.swift", "Transitive", "module:Transitive", False)])

    def test_main_actor_isolation_is_read_in_a_linked_file(self):
        records = [json.loads(line) for line in self.run_main("--rule", "main-blocking", "--jsonl").splitlines()]
        self.assertEqual([(r["path"].rsplit("/", 1)[1], r["isolation"]) for r in records], [("Main.swift", "main")])


if __name__ == "__main__":
    unittest.main()
