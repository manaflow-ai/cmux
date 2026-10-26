#!/usr/bin/env python3
"""tier-imports.py lists what keeps each CmuxNext target off Linux (p15-oracle task 005).

The scanner cases feed Swift text straight to `scan_swift`; the report cases build a small repository in a temp
dir (graph, sources, local packages, a Linux workflow) so they do not depend on the live tree. The last case
runs the real tree, at the working tree and at HEAD.

  python3 -m pytest scripts/cmux-next/tests/test_tier_imports.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import random
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "linux" / "tier-imports.py"
REPO = SCRIPT.parents[3]


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_tier_imports", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ti = load()


def scan(text: str):
    result = ti.scan_swift(textwrap.dedent(text))
    return [f.name for f in result.imports], [f.name for f in result.symbols]


class ImportForms(unittest.TestCase):
    def test_every_import_form_is_caught(self):
        imports, _ = scan("""\
            import AppKit
            public import os
            package import Carbon.HIToolbox
            internal import OSLog
            @preconcurrency import XPC
            @_exported public import CmuxNextDesign
            @testable import CmuxNextIcons
            import struct CmuxNextDesign.LaunchReveal
            import class os.OSLog
            import func Darwin.sysconf
            import os.log
            import os.signpost
            import CoreFoundation;
            import IOKit.ps // battery state
            @_implementationOnly import Security
        """)
        self.assertEqual(imports, [
            "AppKit", "os", "Carbon.HIToolbox", "OSLog", "XPC", "CmuxNextDesign", "CmuxNextIcons",
            "CmuxNextDesign.LaunchReveal", "os.OSLog", "Darwin.sysconf", "os.log", "os.signpost", "CoreFoundation", "IOKit.ps", "Security",
        ])

    def test_linux_modules_are_not_findings(self):
        imports, _ = scan("""\
            import Foundation
            public import Observation
            import FoundationNetworking
            @testable import CmuxNextDaemon
            import struct CmuxNextLayout.DockColumn
            import Testing
        """)
        self.assertEqual(imports, [])

    def test_a_module_whose_name_starts_like_a_blocked_one_is_not_blocked(self):
        imports, _ = scan("import osmium\nimport AppKitShim\nimport CmuxNextDesignTokens\n")
        self.assertEqual(imports, [])

    def test_comments_and_strings_are_not_code(self):
        imports, symbols = scan('''\
            // import AppKit
            /* import SwiftUI
               /* nested */ import WebKit
            */
            let doc = """
            import QuartzCore
            URLSession.shared
            """
            let raw = #"import Darwin "quoted" sysctl"#
            let s = "OSAllocatedUnfairLock" // URLSession
        ''')
        self.assertEqual((imports, symbols), ([], []))


class Conditions(unittest.TestCase):
    def test_branches_false_on_linux_are_skipped(self):
        imports, symbols = scan("""\
            #if os(macOS)
            import AppKit
            let lock = OSAllocatedUnfairLock(initialState: 0)
            #elseif os(Linux)
            import Glibc
            #else
            import UIKit
            #endif
            #if canImport(AppKit)
            import AppKit
            #else
            import Foundation
            #endif
            #if !os(Linux)
            import Darwin
            #endif
            #if targetEnvironment(macCatalyst) || os(iOS)
            import UIKit
            #endif
            #if canImport(os.log)
            import os.log
            #endif
        """)
        self.assertEqual((imports, symbols), ([], []))

    def test_branches_true_or_unknown_on_linux_are_scanned(self):
        imports, _ = scan("""\
            #if DEBUG
            import AppKit
            #endif
            #if os(Linux)
            import Darwin
            #endif
            #if !canImport(AppKit)
            import Security
            #endif
            #if os(macOS) || DEBUG
            import QuartzCore
            #endif
            #if canImport(Glibc) && arch(arm64)
            import CoreGraphics
            #endif
            #if os(Linux)
            #elseif os(macOS)
            import WebKit
            #else
            import SwiftUI
            #endif
        """)
        self.assertEqual(imports, ["AppKit", "Darwin", "Security", "QuartzCore", "CoreGraphics"])

    def test_nested_branches_follow_their_parent(self):
        imports, _ = scan("""\
            #if os(macOS)
            #if DEBUG
            import AppKit
            #else
            import SwiftUI
            #endif
            #endif
            #if DEBUG
            #if os(macOS)
            import WebKit
            #endif
            import Carbon
            #endif
        """)
        self.assertEqual(imports, ["Carbon"])

    def test_condition_values(self):
        evaluate = ti.Condition.evaluate
        self.assertIs(evaluate("os(macOS)"), False)
        self.assertIs(evaluate("os(Linux)"), True)
        self.assertIs(evaluate("!os(macOS)"), True)
        self.assertIs(evaluate("os(macOS) && DEBUG"), False)
        self.assertIs(evaluate("os(Linux) || DEBUG"), True)
        self.assertIsNone(evaluate("DEBUG"))
        self.assertIsNone(evaluate("swift(>=6.0)"))
        self.assertIsNone(evaluate("canImport(SomethingNew)"))
        self.assertIs(evaluate("canImport(FoundationNetworking)"), True)
        self.assertIs(evaluate("(os(macOS) || os(iOS)) && !DEBUG"), False)
        self.assertIsNone(evaluate("os(macOS"))


class Symbols(unittest.TestCase):
    def test_each_symbol_is_caught(self):
        _, symbols = scan("""\
            import Foundation
            let task: URLSessionWebSocketTask
            let config = URLSessionConfiguration.default
            var stream: FSEventStreamRef?
            sysctlbyname("hw.ncpu", nil, nil, nil, 0)
            _ = sysctl(&mib, 4, &info, &size, nil, 0)
            os_unfair_lock_lock(&lock)
            let state = OSAllocatedUnfairLock(initialState: 0)
            DistributedNotificationCenter.default()
        """)
        self.assertEqual(symbols, [
            "URLSession", "URLSession", "FSEvent", "sysctl", "sysctl", "os_unfair_lock", "OSAllocatedUnfairLock",
            "DistributedNotificationCenter",
        ])

    def test_foundation_networking_provides_url_session(self):
        _, symbols = scan("""\
            import Foundation
            #if canImport(FoundationNetworking)
            import FoundationNetworking
            #endif
            let session = URLSession.shared
            os_unfair_lock_lock(&lock)
        """)
        self.assertEqual(symbols, ["os_unfair_lock"])

    def test_other_foundation_networking_types_need_foundation_networking(self):
        text = """\
            import Foundation
            func send(_ request: URLRequest) -> HTTPURLResponse? { nil }
            let cookie = HTTPCookie(properties: [:])
            let key = HTTPCookiePropertyKey.name
            let cache: URLCache? = nil
            let credential = URLCredential(user: "", password: "", persistence: .none)
            class Stub: URLProtocol {}
            let response: URLResponse? = nil
        """
        _, symbols = scan(text)
        self.assertEqual(symbols, ["FoundationNetworking"] * 7)
        _, symbols = scan("import FoundationNetworking\n" + textwrap.dedent(text))
        self.assertEqual(symbols, [])

    def test_a_file_that_only_builds_a_url_request_is_caught(self):
        _, symbols = scan("""\
            import Foundation
            var request = URLRequest(url: URL(string: "https://cmux.dev")!)
        """)
        self.assertEqual(symbols, ["FoundationNetworking"])

    def test_project_types_named_after_url_session_are_not_findings(self):
        _, symbols = scan("""\
            import Foundation
            struct URLSessionHangReportTransport {}
            let fetcher = URLSessionSuggestFetcher()
            let builder = URLRequestBuilder()
            struct HTTPCookieJar {}
            func sysctlString() {}
            let fsEvents = FolderWatcher()
        """)
        self.assertEqual(symbols, [])


class CSources(unittest.TestCase):
    def test_darwin_headers_and_branches(self):
        result = ti.scan_c(textwrap.dedent("""\
            #include "local.h"
            #include <string.h>
            #include <mach/mach.h>
            # import <QuartzCore/QuartzCore.h>
            #include <crt_externs.h>
            #ifdef __APPLE__
            #include <malloc/malloc.h>
            #elif defined(__linux__)
            #include <malloc.h>
            #endif
            #if !defined(__APPLE__) && defined(DEBUG)
            #include <sys/sysctl.h>
            #endif
            #ifndef __linux__
            #include <libproc.h>
            #endif
            // #include <os/log.h>
            void f(void) { os_unfair_lock_lock(&lock); }
        """))
        self.assertEqual([f.name for f in result.imports], [
            "<mach/mach.h>", "<QuartzCore/QuartzCore.h>", "<crt_externs.h>", "<sys/sysctl.h>",
        ])
        self.assertEqual([f.name for f in result.symbols], ["os_unfair_lock"])

    def test_objective_c_files_count_whole(self):
        self.assertEqual([f.name for f in ti.scan_file("A/B.m", "int x;").imports], ["Objective-C source"])
        self.assertEqual(ti.scan_file("A/B.c", "#include <stdio.h>\n").imports, [])


class Manifest(unittest.TestCase):
    PACKAGE = "Packages/macOS/CmuxNext"

    def test_declarations_paths_and_dependency_forms(self):
        targets = ti.manifest_targets(textwrap.dedent('''\
            // .target(name: "Commented", dependencies: ["AppKitThing"])
            let ffi: Target = .binaryTarget(name: "CFFI", url: "https://example.invalid/x.zip", checksum: "0")
            let package = Package(
                products: [.library(name: "Lib", targets: ["CmuxNextA"])],
                dependencies: [.package(path: "../../Shared/CmuxTheme")],
                targets: [
                    .target(
                        name: "CmuxNextA",
                        dependencies: [
                            "CmuxNextB", /* "Hidden", */
                            .target(name: "CmuxNextC"),
                            .byName(name: "CmuxNextD"),
                            .product(name: "CmuxTheme", package: "CmuxTheme"),
                            .product(name: "Atomics", package: "swift-atomics"),
                            .target(name: "CmuxNextMacOnly", condition: .when(platforms: [.macOS])),
                            .target(name: "CmuxNextEverywhere", condition: .when(platforms: [.macOS, .linux])),
                        ],
                        swiftSettings: [.define("X", .when(configuration: .debug))]
                    ),
                    .target(name: "CmuxNextB", path: "Sources/Shared/B"),
                    .testTarget(name: "CmuxNextATests", dependencies: ["CmuxNextA"]),
                    .executableTarget(name: "cmux-tool", dependencies: commonDeps + ["CmuxNextA"]),
                ] + [ffi]
            )
        '''), self.PACKAGE)
        self.assertEqual(sorted(targets), ["CFFI", "CmuxNextA", "CmuxNextATests", "CmuxNextB", "cmux-tool"])
        a = targets["CmuxNextA"]
        self.assertEqual((a.kind, a.path), ("regular", f"{self.PACKAGE}/Sources/CmuxNextA"))
        self.assertEqual(a.targets, ("CmuxNextB", "CmuxNextC", "CmuxNextD", "CmuxNextEverywhere"))
        self.assertEqual(a.packages, ("CmuxTheme", "swift-atomics"))
        self.assertTrue(a.edges_known)
        self.assertEqual(targets["CmuxNextB"].path, f"{self.PACKAGE}/Sources/Shared/B")
        self.assertEqual(targets["CmuxNextATests"].path, f"{self.PACKAGE}/Tests/CmuxNextATests")
        self.assertEqual((targets["CFFI"].kind, targets["CFFI"].path), ("binary", None))
        self.assertFalse(targets["cmux-tool"].edges_known)

    def test_local_packages(self):
        text = '.package(path: "../../Shared/CmuxTheme"),\n.package(url: "https://x.invalid/a", from: "1.0.0"),\n'
        self.assertEqual(ti.manifest_packages(text, self.PACKAGE), {"CmuxTheme": "Packages/Shared/CmuxTheme"})


class Fixture:
    """A small repository: a graph, target sources, local packages and a Linux workflow."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(textwrap.dedent(text))

    def graph(self, targets: dict, packages: dict) -> None:
        self.write(ti.GRAPH_PATH, json.dumps({"_comment": "fixture", "packages": packages, "targets": targets}))

    def report(self, rev: str | None = None) -> dict:
        source = ti.GitTree(self.root, rev) if rev else ti.WorkingTree(self.root)
        return ti.build_report(source)


def target(path: str | None, deps=(), packages=(), kind="regular") -> dict:
    return {"kind": kind, "path": path, "targets": list(deps), "packages": list(packages)}


SOURCES = "Packages/macOS/CmuxNext/Sources"
MANIFEST = "Packages/macOS/CmuxNext/Package.swift"


def standard_fixture(root: Path) -> Fixture:
    fx = Fixture(root)
    fx.graph(
        targets={
            "CCmuxAppFFI": target(None, kind="binary"),
            "CmuxNextCompat": target(f"{SOURCES}/CmuxNextCompat"),
            "CmuxNextGeometry": target(f"{SOURCES}/CmuxNextGeometry", deps=["CCmuxAppFFI"]),
            "CmuxNextDaemon": target(f"{SOURCES}/CmuxNextDaemon", deps=["CmuxNextGeometry"]),
            "CmuxNextSettings": target(f"{SOURCES}/CmuxNextSettings", deps=["CmuxNextDaemon", "CmuxNextCompat"]),
            "CmuxNextNaming": target(f"{SOURCES}/CmuxNextNaming", deps=["CmuxNextSettings"]),
            "CmuxNextAuth": target(f"{SOURCES}/CmuxNextAuth", packages=["CmuxAuthCore"]),
            "CmuxNextTerminal": target(f"{SOURCES}/CmuxNextTerminal", packages=["CmuxGhosttyKit"]),
            "CmuxNextHome": target(f"{SOURCES}/CmuxNextHome", packages=["CmuxHomeRender"]),
            "CmuxNextDaemonTests": target(
                "Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests", deps=["CmuxNextDaemon"], kind="test"
            ),
        },
        packages={
            "CmuxAuthCore": "Packages/Shared/CmuxAuthCore",
            "CmuxGhosttyKit": "Packages/Shared/CmuxGhosttyKit",
            "CmuxHomeRender": "Packages/Shared/CmuxHomeRender",
        },
    )
    fx.write(f"{SOURCES}/CmuxNextCompat/Threads.swift", """\
        import Foundation
        #if os(macOS)
        import Darwin
        #endif
        public let lock = OSAllocatedUnfairLock(initialState: 0)
    """)
    fx.write(f"{SOURCES}/CmuxNextCompat/Log.swift", "import os.log\n")
    fx.write(f"{SOURCES}/CmuxNextGeometry/Rect.swift", "import Foundation\nimport CCmuxLayoutReducerFFI\n")
    fx.write(f"{SOURCES}/CmuxNextDaemon/Store.swift", "public import Foundation\n")
    fx.write(f"{SOURCES}/CmuxNextSettings/Row.swift", "import CmuxNextDaemon\n")
    fx.write(f"{SOURCES}/CmuxNextNaming/Name.swift", "import Foundation\n")
    fx.write(f"{SOURCES}/CmuxNextAuth/Auth.swift", "import CmuxAuthCore\n")
    fx.write(f"{SOURCES}/CmuxNextTerminal/Term.swift", "import Foundation\n")
    fx.write(f"{SOURCES}/CmuxNextHome/Home.swift", "import Foundation\n")
    fx.write("Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/StoreTests.swift", "import Testing\n")
    fx.write("Packages/Shared/CmuxAuthCore/Package.swift", "// swift-tools-version: 6.2\n")
    fx.write("Packages/Shared/CmuxAuthCore/Sources/CmuxAuthCore/Keychain.swift", "import Security\n")
    fx.write("Packages/Shared/CmuxGhosttyKit/Package.swift", """\
        let package = Package(targets: [
            .binaryTarget(
                name: "GhosttyNextKit",
                url: "https://example.invalid/GhosttyNextKit.xcframework.zip",
                checksum: "00"
            ),
        ])
    """)
    fx.write("Packages/Shared/CmuxHomeCore/Package.swift", "// no deps\n")
    fx.write("Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Feed.swift", "import CoreGraphics\n")
    fx.write("Packages/Shared/CmuxHomeRender/Package.swift", """\
        let package = Package(dependencies: [
            .package(path: "../CmuxHomeCore"),
        ])
    """)
    fx.write("Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Draw.swift", "import Foundation\n")
    fx.write(".github/workflows/swift-packages-linux.yml", "packages: >-\n  Packages/Shared/CmuxAuthCore\n")
    return fx


class Report(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fx = standard_fixture(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_direct_transitive_and_ok(self):
        targets = self.fx.report()["targets"]
        compat = targets["CmuxNextCompat"]
        self.assertEqual(compat["status"], "direct")
        self.assertEqual([(f["file"].rsplit("/", 1)[-1], f["module"]) for f in compat["imports"]], [("Log.swift", "os.log")])
        self.assertEqual([f["symbol"] for f in compat["symbols"]], ["OSAllocatedUnfairLock"])
        self.assertEqual(targets["CmuxNextGeometry"]["status"], "ok")  # CCmuxAppFFI maps to CCmuxAppFFILinux
        self.assertEqual(targets["CmuxNextDaemon"]["status"], "ok")
        self.assertEqual(targets["CmuxNextDaemonTests"]["status"], "ok")
        self.assertEqual(targets["CmuxNextSettings"]["status"], "transitive")
        self.assertEqual(targets["CmuxNextSettings"]["blocked_deps"], ["CmuxNextCompat"])
        naming = targets["CmuxNextNaming"]
        self.assertEqual((naming["status"], naming["roots"]), ("transitive", ["CmuxNextCompat"]))
        self.assertEqual(naming["chain"], ["CmuxNextNaming", "CmuxNextSettings", "CmuxNextCompat"])

    def test_package_blockers(self):
        report = self.fx.report()
        targets, packages = report["targets"], report["packages"]
        # A package the Linux workflow builds is ready, whatever its sources import.
        self.assertEqual((packages["CmuxAuthCore"]["status"], packages["CmuxAuthCore"]["reason"]), ("ok", "linux ci"))
        self.assertEqual(targets["CmuxNextAuth"]["status"], "ok")
        self.assertEqual(packages["CmuxGhosttyKit"]["reason"], "xcframework binary target")
        self.assertEqual(targets["CmuxNextTerminal"]["roots"], ["package:CmuxGhosttyKit"])
        # A path dependency of a package carries its blocker up.
        self.assertEqual(packages["CmuxHomeRender"]["status"], "transitive")
        self.assertEqual(packages["CmuxHomeRender"]["blocked_deps"], ["CmuxHomeCore"])
        self.assertEqual(targets["CmuxNextHome"]["chain"], ["CmuxNextHome", "package:CmuxHomeRender", "package:CmuxHomeCore"])

    def test_output_does_not_depend_on_graph_or_file_order(self):
        first = self.fx.report()
        graph = json.loads((self.root / ti.GRAPH_PATH).read_text())
        rng = random.Random(5)
        for _ in range(3):
            names = list(graph["targets"])
            rng.shuffle(names)
            shuffled = {}
            for name in names:
                entry = dict(graph["targets"][name])
                entry["targets"] = rng.sample(entry["targets"], len(entry["targets"]))
                shuffled[name] = entry
            packages = list(graph["packages"].items())
            rng.shuffle(packages)
            self.fx.graph(shuffled, dict(packages))
            self.assertEqual(self.fx.report(), first)

    def test_git_revision_matches_working_tree(self):
        git = ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "fixture"], check=True)
        at_head = self.fx.report("HEAD")
        in_tree = self.fx.report()
        self.assertTrue(at_head.pop("source").startswith("HEAD ("))
        in_tree.pop("source")
        self.assertEqual(at_head, in_tree)
        # A later working-tree edit does not change the revision's report.
        self.fx.write(f"{SOURCES}/CmuxNextDaemon/Store.swift", "import AppKit\n")
        self.assertEqual(self.fx.report("HEAD")["targets"]["CmuxNextDaemon"]["status"], "ok")
        self.assertEqual(self.fx.report()["targets"]["CmuxNextDaemon"]["status"], "direct")

    def run_main(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ti.main(["--root", str(self.root), *args])
        return code, out.getvalue(), err.getvalue()

    def test_check_names_the_blocking_edge_of_each_tier_target(self):
        self.fx.write(ti.TIER_PATH, json.dumps({"waves": [["Geometry", "Daemon"], ["Naming", "Missing"]]}))
        code, out, err = self.run_main("--check", "--summary")
        self.assertEqual(code, 1)
        self.assertIn("tier 2 ok, 0 direct, 1 transitive, 0 unknown, 1 not a target", out)
        self.assertIn(
            "CmuxNextNaming (wave 1) is blocked by CmuxNextNaming -> CmuxNextSettings -> CmuxNextCompat", err
        )
        self.assertIn("tier target Missing is not a target in", err)
        self.fx.write(ti.TIER_PATH, json.dumps({"waves": {"0": ["CmuxNextGeometry"], "1": ["Daemon"]}}))
        self.assertEqual(self.run_main("--check", "--summary")[0], 0)

    def test_check_needs_a_tier_file(self):
        self.assertEqual(self.run_main("--check")[0], 2)

    def test_files_and_target_filters(self):
        code, out, _ = self.run_main("--files", "--target", "Compat")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [
            f"{SOURCES}/CmuxNextCompat/Log.swift:1\tCmuxNextCompat\tos.log",
            f"{SOURCES}/CmuxNextCompat/Threads.swift:5\tCmuxNextCompat\tOSAllocatedUnfairLock",
        ])
        code, out, _ = self.run_main("--blocked")
        rows = [line.split("\t")[0] for line in out.splitlines() if not line.startswith("#")]
        self.assertEqual(rows, ["CmuxNextCompat", "CmuxNextHome", "CmuxNextNaming", "CmuxNextSettings", "CmuxNextTerminal"])
        self.assertEqual(self.run_main("--target", "Nope")[0], 2)

    def test_package_swift_adds_the_targets_and_edges_a_stale_graph_lacks(self):
        self.fx.write(MANIFEST, """\
            let package = Package(
                dependencies: [.package(path: "../../Shared/CmuxHomeCore")],
                targets: [
                    .target(name: "CmuxNextDaemon", dependencies: ["CmuxNextGeometry", "CmuxNextFresh"]),
                    // Clean files, but it depends on a blocked target: never "ok".
                    .target(name: "CmuxNextFresh", dependencies: ["CmuxNextCompat"]),
                    .target(name: "CmuxNextHomeKit", dependencies: [.product(name: "CmuxHomeCore", package: "CmuxHomeCore")]),
                    .testTarget(name: "CmuxNextFreshTests", dependencies: ["CmuxNextFresh"]),
                    .target(name: "CmuxNextComputed", dependencies: sharedDeps),
                ]
            )
        """)
        self.fx.write(f"{SOURCES}/CmuxNextFresh/Fresh.swift", "import Foundation\n")
        self.fx.write(f"{SOURCES}/CmuxNextHomeKit/Kit.swift", "import CmuxHomeCore\n")
        self.fx.write("Packages/macOS/CmuxNext/Tests/CmuxNextFreshTests/FreshTests.swift", "import Testing\n")
        self.fx.write(f"{SOURCES}/CmuxNextComputed/Computed.swift", "import Foundation\n")
        self.fx.write(f"{SOURCES}/CmuxNextUser/User.swift", "import CmuxNextComputed\n")
        targets = self.fx.report()["targets"]
        fresh = targets["CmuxNextFresh"]
        self.assertEqual((fresh["in_graph"], fresh["status"], fresh["roots"]), (False, "transitive", ["CmuxNextCompat"]))
        self.assertEqual(targets["CmuxNextFreshTests"]["chain"], ["CmuxNextFreshTests", "CmuxNextFresh", "CmuxNextCompat"])
        # A package only Package.swift names is still read and walked.
        self.assertEqual(targets["CmuxNextHomeKit"]["roots"], ["package:CmuxHomeCore"])
        # The graph's CmuxNextDaemon lacks the edge to CmuxNextFresh; the manifest adds it.
        daemon = targets["CmuxNextDaemon"]
        self.assertEqual((daemon["in_graph"], daemon["status"], daemon["blocked_deps"]), (True, "transitive", ["CmuxNextFresh"]))
        self.assertEqual(targets["CmuxNextDaemonTests"]["chain"][-1], "CmuxNextCompat")
        # Edges the scanner cannot read are unknown, not clean.
        self.assertEqual(targets["CmuxNextComputed"]["status"], "unknown")
        code, out, err = self.run_main("--blocked")
        self.assertIn("CmuxNextFresh\tregular\t-\ttransitive", out)
        self.assertIn(f"CmuxNextComputed\tregular\t-\tunknown ({ti.UNKNOWN_EDGES})", out)
        self.assertIn("4 targets not in the graph (edges from Package.swift)", out)
        # A directory no target declares is unknown: kept by --blocked and failing --check.
        self.assertIn("# no target declares Sources/CmuxNextUser: unknown", out)
        self.fx.write(ti.TIER_PATH, json.dumps({"waves": [["Geometry", "Fresh", "Computed"]]}))
        code, _, err = self.run_main("--check", "--summary")
        self.assertEqual(code, 1)
        self.assertIn("CmuxNextFresh (wave 0) is blocked by CmuxNextFresh -> CmuxNextCompat", err)
        self.assertIn(f"CmuxNextComputed (wave 0) is blocked by {ti.UNKNOWN_EDGES}", err)
        self.assertIn("warning: CmuxNextFresh is not in", err)
        self.assertIn("declares Sources/CmuxNextUser", err)

    def test_a_directory_no_target_declares_is_still_scanned(self):
        self.fx.write("Packages/macOS/CmuxNext/Tests/CmuxNextNewTests/NewTests.swift", "import Testing\nimport Darwin\n")
        self.fx.write(f"{SOURCES}/CmuxNextFresh/Fresh.swift", "import Foundation\n")
        self.fx.write(f"{SOURCES}/Loose.swift", "import AppKit\n")  # not a target directory
        self.fx.write(f"{SOURCES}/CmuxNextFresh/README.md", "import AppKit\n")  # not a source file
        report = self.fx.report()
        self.assertEqual(sorted(report["unmapped"]), ["Sources/CmuxNextFresh", "Tests/CmuxNextNewTests"])
        # Nothing says what clean files depend on, so they are unknown, never ok.
        self.assertEqual(report["unmapped"]["Sources/CmuxNextFresh"]["status"], "unknown")
        new = report["unmapped"]["Tests/CmuxNextNewTests"]
        self.assertEqual((new["status"], [f["module"] for f in new["imports"]]), ("direct", ["Darwin"]))
        self.assertEqual((report["summary"]["unmapped"], report["summary"]["unmapped_direct"]), (2, 1))
        code, out, _ = self.run_main("--files")
        self.assertIn(
            "Packages/macOS/CmuxNext/Tests/CmuxNextNewTests/NewTests.swift:2\tunmapped:Tests/CmuxNextNewTests\tDarwin",
            out.splitlines(),
        )
        self.assertIn("2 directories no target declares (1 with findings)", self.run_main("--summary")[1])
        code, out, _ = self.run_main("--blocked")
        self.assertIn("# no target declares Tests/CmuxNextNewTests: direct Darwin(1)", out)
        self.assertIn("# no target declares Sources/CmuxNextFresh: unknown", out)
        # A target filter names targets only.
        self.assertNotIn("unmapped:", self.run_main("--files", "--target", "Compat")[1])
        # Once the graph covers it, the directory is a target again.
        graph = json.loads((self.root / ti.GRAPH_PATH).read_text())
        graph["targets"]["CmuxNextFresh"] = target(f"{SOURCES}/CmuxNextFresh")
        self.fx.graph(graph["targets"], graph["packages"])
        self.assertEqual(sorted(self.fx.report()["unmapped"]), ["Tests/CmuxNextNewTests"])

    def test_missing_graph_is_an_input_error(self):
        (self.root / ti.GRAPH_PATH).unlink()
        code, _, err = self.run_main()
        self.assertEqual(code, 2)
        self.assertIn("ci-target-graph.json is missing", err)


class LiveTree(unittest.TestCase):
    """The real tree. A match the scanner did not report must be on a line Linux does not compile, exactly."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = ti.WorkingTree(REPO)
        cls.report = ti.build_report(cls.source)
        entries = list(cls.report["targets"].values()) + list(cls.report["unmapped"].values())
        cls.caught = {(f["file"], f["line"]) for e in entries for f in e["imports"]}

    def missed(self, pattern: re.Pattern[str]) -> tuple[int, list[str]]:
        """(lines matched, `path:line` of each match on a compiled line that the report does not list)."""
        paths = [
            path for top in ti.TARGET_ROOTS for path in self.source.files(top) if path.endswith(ti.SWIFT_EXTENSIONS)
        ]
        matched, missed = 0, []
        for path, text in sorted(self.source.read_many(paths).items()):
            lines = [number for number, line in enumerate(text.splitlines(), 1) if pattern.search(line)]
            if not lines:
                continue
            compiled = {number for number, _ in ti.compiled_swift_lines(text)}
            matched += len(lines)
            missed += [f"{path}:{n}" for n in lines if n in compiled and (path, n) not in self.caught]
        return matched, missed

    def test_the_real_graph_scans_and_catches_every_os_import(self):
        self.assertGreater(len(self.report["targets"]), 100)
        matched, missed = self.missed(re.compile(
            r"^\s*(@\w+ +)*((public|package|internal) +)?import +((struct|class|enum|func|typealias) +)?(os|OSLog)\b"
        ))
        self.assertGreater(matched, 0)
        self.assertEqual(missed, [])
        self.assertEqual(self.report["targets"]["CmuxNextSignposts"]["status"], "direct")

    def test_every_file_the_queue_regex_matches_is_caught(self):
        # The MQ-linux-imports regex as plans/cmux-next/chrome-parity/p15-oracle.md writes it.
        matched, missed = self.missed(re.compile(
            r"^\s*(@[A-Za-z_]+ )*(public |package |internal )?import (struct |class |enum |func |typealias "
            r"|protocol |var |let )?(" + "|".join(ti.QUEUE_MODULES) + r")(\.[A-Za-z]+)*\s*$"
        ))
        self.assertGreater(matched, 100)
        self.assertEqual(missed, [])

    def test_every_imported_module_is_classified(self):
        """Each module the scanned trees import is blocked, on Linux, a target, an FFI module or a package product.

        A new Apple-only module (dnssd, VisionKit) then fails here instead of passing the scan unflagged.
        """
        packages = [entry["path"] for entry in self.report["packages"].values()]
        trees = list(ti.TARGET_ROOTS) + [f"{path}/Sources" for path in packages]
        known = set(ti.BLOCKED_MODULES) | set(ti.LINUX_MODULES) | set(self.report["targets"])
        # The C modules of the CCmuxAppFFI xcframework, which the Linux mode builds from the same headers.
        ffi_script = (REPO / "scripts/cmux-next/build-app-ffi.sh").read_text()
        known |= set(re.findall(r'\.h:(\w+)"', ffi_script))
        local = {path.rsplit("/", 1)[-1].lower() for path in packages}
        for path in [ti.PACKAGE_DIR, *packages]:
            manifest = self.source.read(f"{path}/Package.swift") or ""
            declared = ti.manifest_targets(manifest, path)
            known |= set(declared)
            # Products of external packages (swift-atomics, swift-crypto, swift-nio): their module names.
            known |= {
                name
                for name, package in re.findall(
                    r'\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"', ti.manifest_code(manifest)
                )
                if package.lower() not in local
            }
        # Files no target declares are not compiled (the report lists them as `unmapped`); their imports may name
        # a target that is gone.
        undeclared = tuple(entry["path"] + "/" for entry in self.report["unmapped"].values())
        unclassified: dict[str, str] = {}
        for tree in trees:
            paths = [
                p for p in self.source.files(tree) if p.endswith(ti.SWIFT_EXTENSIONS) and not p.startswith(undeclared)
            ]
            for path, text in sorted(self.source.read_many(paths).items()):
                for number, code in ti.code_lines(text):
                    match = ti.IMPORT.match(code)
                    if match and match.group(1) not in known:
                        unclassified.setdefault(match.group(1), f"{path}:{number}")
        self.assertGreater(len(known), 200)
        self.assertEqual(unclassified, {})

    def test_the_manifest_agrees_with_the_graph(self):
        # The manifest reader adds edges to a stale graph; where both name a target they must agree.
        graph = json.loads(self.source.read(ti.GRAPH_PATH))["targets"]
        manifest = ti.manifest_targets(self.source.read(f"{ti.PACKAGE_DIR}/Package.swift"), ti.PACKAGE_DIR)
        self.assertEqual(sorted(set(graph) - set(manifest)), [])
        for name, info in graph.items():
            declared = manifest[name]
            self.assertEqual((declared.kind, declared.path), (info["kind"], info["path"]), name)
            self.assertLessEqual(set(info["targets"]), set(declared.targets), name)
            self.assertLessEqual(set(info["packages"]), set(declared.packages), name)


if __name__ == "__main__":
    unittest.main()
