#!/usr/bin/env python3
"""gen-features.py: the feature schema's rules, the registry checks the schema cannot state, the generated
Swift and Rust registries (header, drift, daemon subset) and the MQ6/MQ16 queues. Each case builds a temp
repo root with the real schema and runs the script on it.

  python3 -m unittest scripts/cmux-next/tests/test_gen_features.py
"""
from __future__ import annotations

import contextlib
import copy
import datetime
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "gen-features.py"
REPO = SCRIPT.parent.parent.parent
TODAY = datetime.date(2026, 10, 25)


def load_script():
    spec = importlib.util.spec_from_file_location("cmux_next_gen_features_for_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


gen = load_script()

PERF = {
    "name": "cefLayerHosting",
    "owner": "PL-cef-layer",
    "description": "Host Chromium pages in the window's layers.",
    "defaults": {"dev": True, "nightly": True, "release": False},
    "kind": "perfPath",
    "expires": "2026-12-01",
    "process": "app",
    "params": [
        {"name": "syncDeadline", "type": "duration", "default": 0.05, "min": 0, "max": 1,
         "description": "Longest wait for the page's resized frame.", "replaces": "browserResize.syncDeadline"},
        {"name": "maxPages", "type": "int", "default": 4, "min": 1, "max": 32, "description": "Hosted pages per window."},
        {"name": "clip", "type": "bool", "default": True, "description": "Clip to the pane."},
    ],
    "stories": ["browse-heavy"],
    "sticky": False,
    "runtimeMutable": False,
    "replaces": ["browserResize.layerHosting"],
}
HOLDER = {
    "name": "terminalHolder",
    "owner": "PL-daemon holder",
    "description": "Terminals live in the PTY holder process.",
    "defaults": {"dev": True, "nightly": False, "release": False},
    "kind": "perfPath",
    "expires": "2026-11-30",
    "process": "both",
    "params": [{"name": "ringBytes", "type": "double", "default": 1, "min": 0.5, "max": 64,
                "description": "Ring size in MiB."}],
    "stories": ["dev-loop", "agent-swarm"],
    "sticky": True,
    "runtimeMutable": False,
    "replaces": ["CMUX_TUI_TERMINAL_HOST_MODEL"],
}
KILL = {
    "name": "flagsFetch",
    "owner": "Performance Lead",
    "description": "Fetch the signed flags document next to release notes.",
    "defaults": {"dev": True, "nightly": True, "release": True},
    "kind": "killSwitch",
    "process": "daemon",
    "params": [],
    "stories": [],
    "sticky": True,
    "runtimeMutable": False,
}
CHROMIUM = {
    "name": "backForwardCache",
    "owner": "PL-cef-tab",
    "description": "Keep pages in Chromium's back-forward cache.",
    "defaults": {"dev": False, "nightly": False, "release": False},
    "kind": "labs",
    "process": "chromium",
    "chromium_feature": "BackForwardCache",
    "params": [],
    "stories": [],
    "sticky": False,
    "runtimeMutable": False,
}

DROP_TUNABLES = '''import Foundation
public nonisolated enum DropOverlayTunables {
    // Tunable<Bool>.toggle("motion.commented.out", .springs, "x", help: "", default: false)
    public static let holdContent = Tunable<Bool>.toggle(
        "motion.pane.holdContent", .springs, "Hold content size in pane motion",
        help: "...", default: false)
    public static let other = Tunable<Bool>.toggle("drop.overlay.unrelated", .dropOverlay, "x", help: "", default: true)
    public static let spring = Tunable<Double>.number(
        "motion.pane.response", .springs, "Response", help: "", default: 0.3, range: 0...1, step: 0.01, unit: .seconds)
    public static let unread = Tunable<CGFloat>.number("drop.overlay.inset", .dropOverlay, "Inset", help: "",
        default: 4, range: 0...20, step: 1, unit: .points)
}
'''
RESIZE_TUNABLES = '''public nonisolated struct BrowserResizeTunables {
    public static let layerHosting = Tunable<Bool>.toggle(
        "browserResize.layerHosting", section, "Host Chromium pages in the window's layers", help: "", default: true)
    public static let syncDeadline = Tunable<Double>.number(
        "browserResize.syncDeadline", section, "Wait", help: "", default: 0.05, range: 0...1, step: 0.01, unit: .seconds)
}
'''
OWNED_READER = '''struct PaneHostView {
    var response: Double { DropOverlayTunables.spring.value }
    var deadline: Double { BrowserResizeTunables.syncDeadline.value }
}
'''
# The owners of the fixture features; their paths are none the queue fixtures use.
FEATURE_OWNERS = '''| Area | Paths | Owner | Read first |
|---|---|---|---|
| Chromium hosting | `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFHostView*.swift` | PL-cef-layer (memo: Leo) | x |
| New Chromium tab path | `Packages/macOS/CmuxNext/Sources/CmuxNextChromiumWarmup/` | PL-cef-tab | x |
| PTY holder | `cmux-tui/crates/cmux-holder/` | PL-daemon holder (session cmux-4f) | x |
| Wakeups | `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/` | Performance Lead | x |
'''
OWNERS = FEATURE_OWNERS + '''| Sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/` | a590 | x |
| Layout motion | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift` | PL-motion-core | x |
'''
PACKAGE_SWIFT = '''let package = Package(name: "CmuxNext", targets: [
    .target(
        name: "CmuxNextFeatures",
        dependencies: []
    ),
])
'''
HOLDER_RS = '''pub fn holder_enabled() -> bool {
    std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL").is_ok_and(|model| model == "holder")
}
'''
# The crate the generated Rust is written against: its lib.rs, warnings denied.
RUST_LIB = REPO / "cmux-tui/crates/cmux-features/src/lib.rs"


class Repo:
    """A temp repo root: the real schema, features.d and the sources the queues scan."""

    def __init__(self, features=(), files=None, targets=True):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        schema = self.root / gen.SCHEMA
        schema.parent.mkdir(parents=True)
        shutil.copy(REPO / gen.SCHEMA, schema)
        (self.root / "cmux-tui").mkdir()
        shutil.copy(REPO / "cmux-tui/rustfmt.toml", self.root / "cmux-tui/rustfmt.toml")
        self.write(gen.OWNERS, FEATURE_OWNERS)
        if targets:
            self.add_targets()
        for feature in features:
            self.write_feature(feature)
        for rel, text in (files or {}).items():
            self.write(rel, text)

    def add_targets(self, swift=True, rust=True):
        """The targets the generated files compile in (tasks 091 and 095)."""
        if swift:
            self.write(gen.SWIFT_PACKAGE, PACKAGE_SWIFT)
        if rust:
            self.write(gen.RUST_MANIFEST, '[package]\nname = "cmux-features"\n')

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def write_feature(self, feature, file_name=None):
        self.write("%s/%s" % (gen.FEATURES_DIR, file_name or feature["name"] + ".json"), json.dumps(feature, indent=2))

    def run(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gen.main(["--root", str(self.root), "--today", TODAY.isoformat(), *args])
        return code, out.getvalue(), err.getvalue()

    def read(self, rel):
        return (self.root / rel).read_text()

    def close(self):
        self.dir.cleanup()


def with_(feature, **changes):
    result = copy.deepcopy(feature)
    for key, value in changes.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = value
    return result


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads((REPO / gen.SCHEMA).read_text())

    def errors(self, feature):
        return gen.schema_errors(feature, self.schema, self.schema)

    def test_valid_features_pass(self):
        for feature in (PERF, HOLDER, KILL, CHROMIUM):
            self.assertEqual(self.errors(feature), [], feature["name"])

    def test_perf_path_needs_stories(self):
        missing = self.errors(with_(PERF, stories=None))
        self.assertTrue(any("perfPath" in error and "'stories'" in error for error in missing), missing)
        empty = self.errors(with_(PERF, stories=[]))
        self.assertTrue(any("perfPath" in error and "/stories" in error for error in empty), empty)

    def test_perf_path_needs_expiry(self):
        errors = self.errors(with_(PERF, expires=None))
        self.assertTrue(any("perfPath" in error and "'expires'" in error for error in errors), errors)

    def test_kill_switch_needs_no_expiry_or_story(self):
        self.assertEqual(self.errors(with_(KILL, expires=None, stories=[])), [])

    def test_runtime_mutable_needs_teardown_test(self):
        errors = self.errors(with_(KILL, runtimeMutable=True))
        self.assertTrue(any("runtimeMutable" in error and "'teardownTest'" in error for error in errors), errors)
        self.assertEqual(self.errors(with_(KILL, runtimeMutable=True, teardownTest="CmuxNextFeaturesTests.T/testTeardown")), [])

    def test_bench_only_is_for_app_features(self):
        self.assertEqual(self.errors(with_(PERF, benchOnly=True)), [])
        for feature in (KILL, HOLDER):  # process daemon, both
            with self.subTest(process=feature["process"]):
                self.assertTrue(self.errors(with_(feature, benchOnly=True)))
        self.assertTrue(self.errors(with_(PERF, benchOnly="yes")))

    def test_chromium_feature_only_with_process_chromium(self):
        self.assertTrue(self.errors(with_(CHROMIUM, chromium_feature=None)))
        errors = self.errors(with_(KILL, chromium_feature="BackForwardCache"))
        self.assertTrue(any("'chromium_feature' is not allowed" in error for error in errors), errors)

    def test_params_are_typed(self):
        bool_range = with_(PERF, params=[{"name": "clip", "type": "bool", "default": True, "min": 0,
                                          "description": "Clip to the pane."}])
        self.assertTrue(self.errors(bool_range))
        int_fraction = with_(PERF, params=[{"name": "pages", "type": "int", "default": 1.5, "min": 0, "max": 4,
                                            "description": "Hosted pages."}])
        self.assertTrue(self.errors(int_fraction))
        no_range = with_(PERF, params=[{"name": "wait", "type": "double", "default": 1, "description": "Wait."}])
        self.assertTrue(any("'min'" in error for error in self.errors(no_range)))
        bool_number = with_(PERF, params=[{"name": "clip", "type": "bool", "default": 1, "description": "Clip it."}])
        self.assertTrue(self.errors(bool_number))

    def test_rejects_unknown_fields_and_bad_values(self):
        self.assertTrue(any("unknown property" in error for error in self.errors(with_(KILL, extra=1))))
        self.assertTrue(self.errors(with_(KILL, kind="experiment")))
        self.assertTrue(self.errors(with_(KILL, name="Flags_fetch")))
        self.assertTrue(self.errors(with_(KILL, description='say "hi" here')))
        self.assertTrue(self.errors(with_(KILL, defaults={"dev": True, "nightly": True})))

    def test_a_trailing_newline_does_not_match_a_pattern(self):
        """JSON Schema patterns are ECMA-262: `$` is the end of the string, not the spot before a final newline
        (Python's `$`). A newline would split the generated single-line string literals."""
        self.assertTrue(self.errors(with_(KILL, description="Does a thing here.\n")))
        self.assertTrue(self.errors(with_(PERF, params=[{"name": "clip\n", "type": "bool", "default": True,
                                                         "description": "Clip to the pane."}])))
        for field, value in (("owner", "PL-cef-tab\n"), ("stories", ["dev-loop\n"]), ("replaces", ["a.b\n"])):
            self.assertTrue(self.errors(with_(KILL, **{field: value})), field)
        self.assertTrue(self.errors(with_(CHROMIUM, chromium_feature="BackForwardCache\n")))
        self.assertTrue(self.errors(with_(KILL, runtimeMutable=True, teardownTest="A.B/testC\n")))
        self.assertEqual(gen._ecma_pattern("^a[$]b$").pattern, r"^a[$]b\Z")
        self.assertEqual(gen._ecma_pattern(r"^a\$$").pattern, r"^a\$\Z")

    def test_teardown_test_names_one_of_the_two_forms(self):
        for name in ("CmuxNextFeaturesTests.FlagsTests/testTeardown", "cmux_holder::ring::tests::drops",
                     "cmux_holder::drops"):
            self.assertEqual(self.errors(with_(KILL, runtimeMutable=True, teardownTest=name)), [], name)
        for name in ("testTeardown", "A.B.C/testD", "A/testD", "cmux_holder", "Crate::x::y", "a::b/c",
                     "cmux-holder::drops"):
            self.assertTrue(self.errors(with_(KILL, runtimeMutable=True, teardownTest=name)), name)

    @unittest.skipUnless(importlib.util.find_spec("jsonschema"), "jsonschema is not installed")
    def test_the_built_in_validator_agrees_with_jsonschema(self):
        import jsonschema
        validator = jsonschema.Draft202012Validator(self.schema)
        cases = [PERF, HOLDER, KILL, CHROMIUM, with_(PERF, stories=None), with_(PERF, stories=[]),
                 with_(PERF, expires=None), with_(KILL, runtimeMutable=True), with_(CHROMIUM, chromium_feature=None),
                 with_(KILL, chromium_feature="BackForwardCache"), with_(KILL, extra=1), with_(KILL, kind="x"),
                 with_(PERF, params=[{"name": "pages", "type": "int", "default": 1.5, "min": 0, "max": 4,
                                      "description": "Hosted pages."}]),
                 with_(PERF, params=[{"name": "pages", "type": "int", "default": 2.0, "min": 0, "max": 4,
                                      "description": "Hosted pages."}]),
                 with_(PERF, params=[{"name": "clip", "type": "bool", "default": True, "max": 1,
                                      "description": "Clip it."}]),
                 with_(KILL, stories=["a", "a"]), with_(KILL, sticky="yes"),
                 # Not the trailing-newline cases: Python's jsonschema matches with re.search, so it shares
                 # the `$` deviation that test_a_trailing_newline_does_not_match_a_pattern covers.
                 with_(KILL, runtimeMutable=True, teardownTest="cmux_holder::ring::tests::drops"),
                 with_(KILL, runtimeMutable=True, teardownTest="A.B.C/testD")]
        for case in cases:
            self.assertEqual(bool(self.errors(case)), not validator.is_valid(case), json.dumps(case))


class RegistryTests(unittest.TestCase):
    def check(self, *features, files=None):
        repo = Repo(features, files)
        self.addCleanup(repo.close)
        return repo, repo.run("--check")

    def test_perf_path_expires_within_60_days(self):
        limit = (TODAY + datetime.timedelta(days=60)).isoformat()
        _, (code, _, err) = self.check(with_(PERF, expires=(TODAY + datetime.timedelta(days=61)).isoformat()))
        self.assertEqual(code, 1)
        self.assertIn("within 60 days (by %s)" % limit, err)
        repo, (code, _, err) = self.check(with_(PERF, expires=limit))
        self.assertNotIn("within 60 days", err)
        repo.run()
        self.assertEqual(repo.run("--check")[0], 0)

    def test_expired_feature_warns(self):
        repo, _ = self.check(with_(KILL, expires="2026-10-01"))
        code, _, err = repo.run()
        self.assertEqual(code, 0)
        self.assertIn("expired on 2026-10-01", err)

    def test_file_name_is_the_feature_name(self):
        repo = Repo()
        self.addCleanup(repo.close)
        repo.write_feature(KILL, "other.json")
        code, _, err = repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("must be named flagsFetch.json", err)

    def test_param_default_inside_range(self):
        bad = with_(PERF, params=[{"name": "maxPages", "type": "int", "default": 40, "min": 1, "max": 32,
                                   "description": "Hosted pages per window."}])
        _, (code, _, err) = self.check(bad)
        self.assertEqual(code, 1)
        self.assertIn("outside [1, 32]", err)

    def test_teardown_test_must_exist(self):
        mutable = with_(KILL, runtimeMutable=True, teardownTest="CmuxNextFeaturesTests.FlagsFetchTests/testLiveTeardown")
        _, (code, _, err) = self.check(mutable)
        self.assertEqual(code, 1)
        self.assertIn("no test function named", err)
        test = "Packages/macOS/CmuxNext/Tests/CmuxNextFeaturesTests/FlagsFetchTests.swift"
        repo, _ = self.check(mutable, files={test: "final class FlagsFetchTests { func testLiveTeardown() {} }\n"})
        repo.run()
        self.assertEqual(repo.run("--check")[0], 0)

    def resolves(self, name, files):
        repo = Repo(files=files)
        self.addCleanup(repo.close)
        return gen._test_exists(str(repo.root), name)

    def test_swift_teardown_test_resolves_target_suite_and_test(self):
        tests = "Packages/macOS/CmuxNext/Tests/CmuxNextFeaturesTests/"
        files = {
            tests + "FlagsTests.swift": '''import XCTest
final class FlagsTests: XCTestCase {
    let brace = "{ not a block"
    // func testInAComment() {}
    func helper() {}
    struct Nested { func testNested() {} }
    func testLiveTeardown() async throws {}
}
extension FlagsTests {
    @MainActor func testFromExtension() {}
}
''',
            tests + "SwiftTesting.swift": '''import Testing
@Suite("Flags") struct FlagTeardown {
    @Test("drops the live path", .tags(.teardown))
    func dropsLivePath() async {}
    func notATest() {}
}
''',
            "Packages/macOS/CmuxNext/Tests/OtherTests/Other.swift": "final class Other { func testElsewhere() {} }\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextFeatures/Lib.swift": "struct FlagsTests { func testInSource() {} }\n",
        }
        for name in ("CmuxNextFeaturesTests.FlagsTests/testLiveTeardown",
                     "CmuxNextFeaturesTests.FlagsTests/testFromExtension",
                     "CmuxNextFeaturesTests.FlagTeardown/dropsLivePath", "OtherTests.Other/testElsewhere"):
            self.assertTrue(self.resolves(name, files), name)
        for name, why in (("CmuxNextFeaturesTests.FlagsTests/helper", "a helper is not a test"),
                          ("CmuxNextFeaturesTests.FlagTeardown/notATest", "no @Test and no test prefix"),
                          ("CmuxNextFeaturesTests.FlagsTests/testNested", "a member of a nested type"),
                          ("CmuxNextFeaturesTests.FlagsTests/testInAComment", "commented out"),
                          ("CmuxNextFeaturesTests.Wrong/testLiveTeardown", "wrong suite"),
                          ("OtherTests.FlagsTests/testLiveTeardown", "wrong target"),
                          ("CmuxNextFeatures.FlagsTests/testInSource", "not a test target"),
                          ("Nonexistent.Suite/new", "nothing")):
            self.assertFalse(self.resolves(name, files), why)

    def test_rust_teardown_test_resolves_crate_module_and_test_attribute(self):
        crate = "cmux-tui/crates/cmux-holder/"
        files = {
            crate + "Cargo.toml": '[package]\nname = "cmux-holder"\n',
            crate + "src/lib.rs": '''pub mod ring;
pub fn new() {}
#[test]
fn at_the_root() {}
''',
            crate + "src/ring.rs": '''pub fn drop_ring() { let _ = "}"; let _ = '{'; }
#[cfg(test)]
mod tests {
    #[test]
    fn teardown_drops() {}
    #[tokio::test(flavor = "multi_thread")]
    #[should_panic(expected = "]")]
    async fn teardown_async() {}
    fn helper() {}
    mod deeper { #[test] fn nested_only() {} }
}
''',
            crate + "src/ring/wire.rs": "#[test]\nfn in_a_child_file() {}\n",
            crate + "tests/attach.rs": "#[test]\nfn integration_teardown() {}\n",
        }
        for name in ("cmux_holder::ring::tests::teardown_drops", "cmux_holder::ring::tests::teardown_async",
                     "cmux_holder::at_the_root",
                     "cmux_holder::ring::wire::in_a_child_file", "cmux_holder::attach::integration_teardown",
                     "cmux_holder::ring::tests::deeper::nested_only"):
            self.assertTrue(self.resolves(name, files), name)
        for name, why in (("cmux_holder::new", "a plain fn in src is not a test"),
                          ("crate::x::new", "no such crate"),
                          ("cmux_holder::ring::tests::helper", "no #[test]"),
                          ("cmux_holder::ring::drop_ring", "no #[test]"),
                          ("cmux_holder::ring::tests::nested_only", "the test is in a nested module"),
                          ("cmux_holder::wire::in_a_child_file", "wrong module path"),
                          ("cmux_holder::tests::teardown_drops", "wrong module path"),
                          ("cmux_other::ring::tests::teardown_drops", "wrong crate")):
            self.assertFalse(self.resolves(name, files), why)

    def test_a_common_non_test_name_does_not_pass_as_a_teardown_test(self):
        files = {"cmux-tui/crates/cmux-x/Cargo.toml": '[package]\nname = "cmux-x"\n',
                 "cmux-tui/crates/cmux-x/src/lib.rs": "pub fn new() {}\n",
                 "Packages/macOS/CmuxNext/Tests/CmuxNextFeaturesTests/Helpers.swift": "func new() {}\n"}
        for name in ("Nonexistent.Suite/new", "cmux_x::new", "crate::x::new"):
            _, (code, _, err) = self.check(with_(KILL, runtimeMutable=True, teardownTest=name), files=files)
            self.assertEqual(code, 1, name)
            self.assertIn("no test function named", err)

    def test_stories_must_exist_once_the_story_catalog_does(self):
        files = {gen.STORIES_DIR + "/dev-loop.json": "{}"}
        _, (code, _, err) = self.check(HOLDER, files=files)
        self.assertEqual(code, 1)
        self.assertIn("no story %s/agent-swarm.json" % gen.STORIES_DIR, err)

    def test_one_feature_per_replaced_key(self):
        _, (code, _, err) = self.check(PERF, with_(KILL, replaces=["browserResize.layerHosting"]))
        self.assertEqual(code, 1)
        self.assertIn("browserResize.layerHosting is used by more than one feature", err)

    def test_reserved_swift_names(self):
        _, (code, _, err) = self.check(with_(KILL, name="registered"))
        self.assertEqual(code, 1)
        self.assertIn("reserved", err)

    def test_non_finite_numbers_are_rejected(self):
        """json.load reads 1e400 as inf without parse_constant; neither Swift nor Rust has an `inf` literal."""
        for old, new in (('"default": 0.05', '"default": Infinity'), ('"max": 1,', '"max": 1e400,'),
                         ('"default": 0.05', '"default": -1e400'), ('"max": 1,', '"max": 1%s,' % ("0" * 400))):
            repo = Repo()
            self.addCleanup(repo.close)
            text = json.dumps(PERF)
            self.assertIn(old, text)
            repo.write(gen.FEATURES_DIR + "/cefLayerHosting.json", text.replace(old, new))
            code, _, err = repo.run()
            self.assertEqual(code, 1, new)
            self.assertIn("cefLayerHosting.json", err)
            self.assertFalse((repo.root / gen.SWIFT_OUT).exists(), new)

    def test_int_params_fit_in_64_bits(self):
        def pages(**values):
            return with_(PERF, params=[dict({"name": "maxPages", "type": "int", "default": 4, "min": 1, "max": 32,
                                              "description": "Hosted pages per window."}, **values)])
        for values in ({"max": 1e20}, {"default": 2 ** 63, "max": 2 ** 64}, {"min": -(2 ** 63) - 1},
                       {"max": 1e30, "default": 1e30}):
            _, (code, _, err) = self.check(pages(**values))
            self.assertEqual(code, 1, values)
            self.assertIn("64-bit Int range", err)
        _, (_, _, err) = self.check(pages(min=-(2 ** 63), max=2 ** 63 - 1))
        self.assertNotIn("64-bit", err)

    def test_owner_is_in_owners_md(self):
        _, (code, _, err) = self.check(with_(KILL, owner="Somebody Else"))
        self.assertEqual(code, 1)
        self.assertIn("'Somebody Else' is not an owner in %s" % gen.OWNERS, err)
        _, (_, _, err) = self.check(with_(KILL, owner="PL-cef"))
        self.assertIn("'PL-cef' is not an owner", err, "a prefix of PL-cef-layer is not an owner")
        _, (_, _, err) = self.check(with_(KILL, owner="PL-memory"), files={gen.PERF_LEAD: "- **PL-memory**: hidden pages.\n"})
        self.assertNotIn("not an owner", err, "a PL-* workstream of perf-lead.md")
        _, (_, _, err) = self.check(with_(KILL, owner="Aziz"), files={gen.PERF_LEAD: "Aziz\n"})
        self.assertIn("'Aziz' is not an owner", err, "perf-lead.md counts only for PL-* names")
        repo = Repo([KILL])
        self.addCleanup(repo.close)
        (repo.root / gen.OWNERS).unlink()
        code, _, err = repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("%s is missing" % gen.OWNERS, err)


class GeneratedFileTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo([PERF, HOLDER, KILL, CHROMIUM])
        self.addCleanup(self.repo.close)

    def test_check_exits_1_on_drift(self):
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1, "missing generated files are drift")
        self.assertIn(gen.SWIFT_OUT, err)
        self.assertEqual(self.repo.run()[0], 0)
        self.assertEqual(self.repo.run("--check"), (0, "", ""))
        self.repo.write_feature(with_(KILL, defaults={"dev": True, "nightly": True, "release": False}))
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1, "a changed default is drift")
        self.assertIn(gen.SWIFT_OUT, err)
        self.assertIn(gen.RUST_OUT, err)
        self.repo.run()
        self.repo.write(gen.SWIFT_OUT, self.repo.read(gen.SWIFT_OUT).replace("sticky: true", "sticky: false"))
        self.assertEqual(self.repo.run("--check")[0], 1, "a hand edit is drift")

    def test_rust_drift_ignores_layout(self):
        """rustfmt (the pre-commit hook) owns the Rust layout; content changes are still drift."""
        self.repo.run()
        raw = gen.rust([KILL, HOLDER])
        self.repo.write(gen.RUST_OUT, raw.replace("\n    ", "\n        ").replace("},\n];", "}];"))
        self.assertEqual(self.repo.run("--check")[0], 0)
        self.repo.write(gen.RUST_OUT, raw.replace("nightly: false", "nightly: true"))
        self.assertEqual(self.repo.run("--check")[0], 1)
        self.repo.write(gen.RUST_OUT, raw.replace('"flagsFetch",\n    ', '"flags Fetch",\n    ', 1))
        self.assertEqual(self.repo.run("--check")[0], 1, "string contents keep their spaces")

    def test_invalid_feature_fails_check_and_writes_nothing(self):
        self.repo.write_feature(with_(PERF, stories=[]))
        code, _, err = self.repo.run()
        self.assertEqual(code, 1)
        self.assertIn("perfPath", err)
        self.assertFalse((self.repo.root / gen.SWIFT_OUT).exists())

    def test_generated_files_have_a_do_not_edit_header(self):
        self.repo.run()
        for rel in (gen.SWIFT_OUT, gen.RUST_OUT):
            first = self.repo.read(rel).splitlines()[:2]
            self.assertTrue(first[0].startswith("// GENERATED by scripts/cmux-next/gen-features.py"), first)
            self.assertIn("Do not edit", first[0])

    def test_swift_has_every_feature_in_index_order(self):
        self.repo.run()
        swift = self.repo.read(gen.SWIFT_OUT)
        names = sorted(feature["name"] for feature in (PERF, HOLDER, KILL, CHROMIUM))
        for index, name in enumerate(names):
            self.assertIn("public static let %s = Feature(\n        index: %d," % (name, index), swift)
        self.assertIn("public static let registered: [Feature] = [\n%s\n    ]"
                      % "\n".join("        .%s," % name for name in names), swift)
        self.assertIn('chromiumFeature: "BackForwardCache"', swift)
        self.assertIn(".duration(default: 0.05, min: 0.0, max: 1.0)", swift)
        self.assertIn(".int(default: 4, min: 1, max: 32)", swift)
        self.assertIn(".bool(default: true)", swift)
        self.assertIn("expires: nil", swift)

    def test_swift_carries_replaced_keys_for_the_local_override(self):
        """The App reads each replaced tunable at launch as the feature's local override (p12-perf-process-100), so the
        Swift handle names its `replaces`; a feature without them keeps the label off."""
        self.repo.run()
        swift = self.repo.read(gen.SWIFT_OUT)
        perf = swift[swift.index("public static let cefLayerHosting = Feature("):]
        self.assertIn('        runtimeMutable: false,\n        replaces: ["browserResize.layerHosting"]\n    )\n',
                      perf[:perf.index("\n    )\n") + 7])
        kill = swift[swift.index("public static let flagsFetch = Feature("):]
        self.assertNotIn("replaces:", kill[:kill.index("\n    )\n")])

    def test_bench_only_features_are_compiled_out_of_shipped_builds(self):
        """A benchOnly handle and its registry slot exist only under DEBUG || CMUX_BENCH_HOOKS, after every
        shipped feature, so a Release registry is dense and keeps the shipped features' indices."""
        probe = with_(PERF, name="aaBenchProbe", benchOnly=True, replaces=None,
                      params=[{"name": "spin", "type": "bool", "default": True, "description": "Spin."}])
        self.repo.write_feature(probe)
        self.repo.run()
        swift = self.repo.read(gen.SWIFT_OUT)
        shipped = sorted(feature["name"] for feature in (PERF, HOLDER, KILL, CHROMIUM))
        for index, name in enumerate(shipped):
            self.assertIn("public static let %s = Feature(\n        index: %d," % (name, index), swift)
        guarded = "    #if DEBUG || CMUX_BENCH_HOOKS\n    /// %s\n    public static let aaBenchProbe = Feature(\n" \
                  "        index: %d," % (probe["description"], len(shipped))
        self.assertIn(guarded, swift)
        handle = swift[swift.index("public static let aaBenchProbe"):]
        self.assertLess(handle.index("    #endif\n"), handle.index("public static let registered"))
        registry = lambda names: ("    /// Every feature, by index: `registered[feature.index] == feature`.\n"
                                  "    public static let registered: [Feature] = [\n%s\n    ]\n"
                                  % "\n".join("        .%s," % name for name in names))
        self.assertIn("    #if DEBUG || CMUX_BENCH_HOOKS\n%s    #else\n%s    #endif\n}\n"
                      % (registry(shipped + ["aaBenchProbe"]), registry(shipped)), swift)
        self.assertNotIn("AA_BENCH_PROBE", self.repo.read(gen.RUST_OUT))
        self.assertEqual(self.repo.run("--check")[0], 0)

    def test_only_bench_features(self):
        repo = Repo([with_(PERF, benchOnly=True)])
        self.addCleanup(repo.close)
        self.assertEqual(repo.run()[0], 0)
        swift = repo.read(gen.SWIFT_OUT)
        self.assertIn("    #else\n    /// Every feature, by index: `registered[feature.index] == feature`.\n"
                      "    public static let registered: [Feature] = []\n    #endif\n", swift)
        self.assertIn("index: 0,", swift)

    def test_rust_has_only_daemon_side_features(self):
        self.repo.run()
        rust = self.repo.read(gen.RUST_OUT)
        self.assertIn('        FLAGS_FETCH = "flagsFetch",\n', rust)
        self.assertIn('        TERMINAL_HOLDER = "terminalHolder",\n', rust)
        self.assertNotIn("CEF_LAYER_HOSTING", rust)
        self.assertNotIn("BACK_FORWARD_CACHE", rust)
        table = rust[rust.index("pub(crate) const TABLE"):rust.index("pub mod feature")]
        self.assertLess(table.index('name: "flagsFetch"'), table.index('name: "terminalHolder"'))
        self.assertIn("process: crate::Process::Both,", table)
        self.assertIn("kind: crate::Kind::KillSwitch,", table)
        self.assertIn("kind: crate::Kind::PerfPath,", table)
        self.assertIn("defaults: crate::Defaults { dev: true, nightly: false, release: false },", table)

    def test_empty_registry(self):
        repo = Repo()
        self.addCleanup(repo.close)
        self.assertEqual(repo.run()[0], 0)
        self.assertIn("public static let registered: [Feature] = []", repo.read(gen.SWIFT_OUT))
        rust = repo.read(gen.RUST_OUT)
        self.assertIn("pub(crate) const TABLE: &[crate::FeatureDef] = &[];", rust)
        self.assertIn("    feature_handles!(super::TABLE;);\n", rust)

    def test_files_are_written_and_checked_only_once_their_target_exists(self):
        repo = Repo([PERF, HOLDER, KILL, CHROMIUM], targets=False)
        self.addCleanup(repo.close)
        code, out, err = repo.run("--check")
        self.assertEqual((code, err), (0, ""), "--check is green before tasks 091 and 095 add the targets")
        self.assertIn("skipped %s: %s declares no CmuxNextFeatures target yet" % (gen.SWIFT_OUT, gen.SWIFT_PACKAGE), out)
        self.assertIn("skipped %s: no %s yet" % (gen.RUST_OUT, gen.RUST_MANIFEST), out)
        self.assertEqual(repo.run()[0], 0)
        self.assertFalse((repo.root / gen.SWIFT_OUT).parent.exists(), "no orphan Swift target directory")
        self.assertFalse((repo.root / gen.RUST_OUT).exists(), "no crate without a Cargo.toml")
        repo.write(gen.SWIFT_PACKAGE, '.target(name: "CmuxNextFeaturesTests")\n')
        self.assertIn("skipped " + gen.SWIFT_OUT, repo.run()[1], "a target with a longer name is not the target")
        repo.add_targets(swift=False)
        code, out, _ = repo.run("--check")
        self.assertEqual(code, 1, "the Rust file is checked once its crate exists")
        self.assertIn("skipped " + gen.SWIFT_OUT, out)
        self.assertEqual(repo.run()[0], 0)
        self.assertTrue((repo.root / gen.RUST_OUT).exists())
        self.assertFalse((repo.root / gen.SWIFT_OUT).exists())
        self.assertEqual(repo.run("--check")[0], 0)
        repo.add_targets(rust=False)
        self.assertEqual(repo.run("--check")[0], 1, "the Swift file is checked once its target exists")
        self.assertEqual(repo.run()[0], 0)
        self.assertEqual(repo.run("--check"), (0, "", ""))

    @unittest.skipUnless(shutil.which("rustc") and shutil.which("rustfmt"), "no Rust toolchain")
    def test_generated_rust_compiles_and_is_rustfmt_clean(self):
        for features in ([PERF, HOLDER, KILL, CHROMIUM], []):
            repo = Repo(features)
            self.addCleanup(repo.close)
            repo.run()
            crate = repo.root / "crate"
            crate.mkdir()
            shutil.copy(repo.root / gen.RUST_OUT, crate / "generated.rs")
            shutil.copy(RUST_LIB, crate / "lib.rs")
            shutil.copy(RUST_LIB.with_name("hello.rs"), crate / "hello.rs")
            shutil.copy(repo.root / "cmux-tui/rustfmt.toml", crate / "rustfmt.toml")
            fmt = subprocess.run(["rustfmt", "--edition", gen.RUST_EDITION, "--check", "generated.rs"], cwd=crate,
                                 capture_output=True, text=True)
            self.assertEqual(fmt.returncode, 0, fmt.stdout + fmt.stderr)
            build = subprocess.run(["rustc", "--edition", gen.RUST_EDITION, "--crate-type", "lib", "--emit", "metadata",
                                    "-D", "warnings", "-o", str(crate / "out.rmeta"), "lib.rs"], cwd=crate,
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)


class QueueTests(unittest.TestCase):
    FILES = {
        "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DropOverlay/DropOverlayTunables.swift": DROP_TUNABLES,
        "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/Core/BrowserResizeTunables.swift": RESIZE_TUNABLES,
        "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift": OWNED_READER,
        "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/SidebarTunables.swift":
            'enum SidebarTunables {\n    static let slideHoldsContent = Tunable<Bool>.toggle(\n'
            '        "sidebar.slideHoldsContent", .sidebar, "x", help: "", default: true)\n}\n',
        "cmux-tui/crates/cmux-tui-core/src/holder_runtime.rs": HOLDER_RS,
        "cmux-tui/crates/cmux-tui/tests/holder.rs": 'fn t() { std::env::set_var("CMUX_TUI_TERMINAL_HOST_MODEL", "holder"); }\n',
        gen.OWNERS: OWNERS,
    }

    def repo(self, *features):
        repo = Repo(features, self.FILES)
        self.addCleanup(repo.close)
        return repo

    def test_unmigrated_lists_seed_switches_until_a_feature_replaces_them(self):
        code, out, _ = self.repo().run("--unmigrated")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [
            "CMUX_TUI_TERMINAL_HOST_MODEL\tcmux-tui/crates/cmux-tui-core/src/holder_runtime.rs:2",
            "browserResize.layerHosting\tPackages/macOS/CmuxNext/Sources/CmuxNextBrowser/Core/BrowserResizeTunables.swift:3",
            "motion.pane.holdContent\tPackages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DropOverlay/DropOverlayTunables.swift:5",
            "sidebar.slideHoldsContent\tPackages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/SidebarTunables.swift:3",
            "4 unmigrated",
        ])
        code, out, _ = self.repo(PERF, HOLDER).run("--unmigrated", "--count")
        self.assertEqual((code, out), (0, "2\n"))

    def test_unmigrated_lists_bool_tunables_of_perf_owned_files(self):
        """A Bool tunable added after the seed list still enters MQ6 when a perf-owned file declares or reads it."""
        repo = self.repo()
        repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift", OWNED_READER + '''
extension PaneHostView {
    static let snapshot = Tunable<Bool>.toggle("motion.pane.snapshot", .springs, "x", help: "", default: true)
    var other: Bool { DropOverlayTunables.other.value }
}
''')
        code, out, _ = repo.run("--unmigrated")
        self.assertEqual(code, 0)
        rows = out.splitlines()
        self.assertIn("motion.pane.snapshot\tPackages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift:7",
                      rows)
        self.assertIn("drop.overlay.unrelated\tPackages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DropOverlay/"
                      "DropOverlayTunables.swift:7", rows, "read from a perf-owned file")
        self.assertEqual(rows[-1], "6 unmigrated")
        repo.write_feature(with_(KILL, replaces=["motion.pane.snapshot", "drop.overlay.unrelated"]))
        self.assertEqual(repo.run("--unmigrated", "--count")[1], "4\n")

    def test_unmigrated_warns_about_stale_seeds(self):
        code, _, err = self.repo().run("--unmigrated")
        self.assertEqual(code, 0)
        stale = [line for line in err.splitlines() if "matches no declared tunable" in line]
        self.assertEqual(stale, ["warning: the MQ6 seed %s matches no declared tunable or env read; update the seed list"
                                 % seed for seed in ("browserHost.helper", "hibernation.compressedSnapshots",
                                                     "hostPressure.enabled", "agent.chromium")])
        _, _, err = self.repo(PERF, with_(KILL, replaces=["agent.chromium"])).run("--unmigrated")
        self.assertNotIn("seed agent.chromium ", err, "a replaced seed is migrated, not stale")

    def test_unmigrated_params_follow_perf_owned_files(self):
        code, out, _ = self.repo().run("--unmigrated-params")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [
            "browserResize.syncDeadline\tPackages/macOS/CmuxNext/Sources/CmuxNextBrowser/Core/BrowserResizeTunables.swift:5",
            "motion.pane.response\tPackages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/DropOverlay/DropOverlayTunables.swift:9",
            "2 unmigrated",
        ])
        self.assertEqual(self.repo(PERF).run("--unmigrated-params", "--count")[1], "1\n")

    def test_count_needs_a_queue(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            gen.main(["--count"])

    def test_unmigrated_lists_motion_pane_hold_content_today(self):
        """The acceptance check on the real tree, until the feature that replaces the key lands (task 102)."""
        features, errors, _ = gen.load_features(str(REPO), datetime.date.today())
        self.assertEqual(errors, [])
        if any("motion.pane.holdContent" in feature.get("replaces", []) for feature in features):
            self.skipTest("motion.pane.holdContent is a feature now")
        rows, stale = gen.unmigrated(str(REPO), features)
        self.assertEqual(stale, [], "every MQ6 seed still names a declared tunable or env read")
        keys = [key for key, _ in rows]
        self.assertIn("motion.pane.holdContent", keys)
        self.assertNotIn("CMUX_TUI_TERMINAL_HOST_MODEL", keys, "terminalHolder replaces the env switch")


if __name__ == "__main__":
    unittest.main()
