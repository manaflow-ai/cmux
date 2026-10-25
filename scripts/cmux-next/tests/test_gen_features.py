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
OWNERS = '''| Area | Paths | Owner | Read first |
|---|---|---|---|
| Sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/` | a590 | x |
| Layout motion | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/PaneHostView.swift` | PL-motion-core | x |
'''
HOLDER_RS = '''pub fn holder_enabled() -> bool {
    std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL").is_ok_and(|model| model == "holder")
}
'''
# The interface the generated Rust is written against (task p12-perf-process-095's lib.rs).
RUST_INTERFACE = '''#![deny(warnings)]
#![allow(dead_code)]
pub struct Feature {
    pub index: usize,
    pub name: &'static str,
    pub owner: &'static str,
    pub description: &'static str,
    pub kind: FeatureKind,
    pub process: FeatureProcess,
    pub defaults: FeatureDefaults,
    pub expires: Option<&'static str>,
    pub params: &'static [FeatureParamSpec],
    pub stories: &'static [&'static str],
    pub sticky: bool,
    pub runtime_mutable: bool,
}
pub enum FeatureKind { PerfPath, KillSwitch, Labs }
pub enum FeatureProcess { App, Daemon, Both, Chromium }
pub struct FeatureDefaults { pub dev: bool, pub nightly: bool, pub release: bool }
pub struct FeatureParamSpec { pub name: &'static str, pub description: &'static str, pub value: FeatureParamValue }
pub enum FeatureParamValue {
    Int { default: i64, min: i64, max: i64 },
    Double { default: f64, min: f64, max: f64 },
    Duration { default: f64, min: f64, max: f64 },
    Bool { default: bool },
}
pub mod generated;
pub fn count() -> usize { generated::REGISTERED.len() }
'''


class Repo:
    """A temp repo root: the real schema, features.d and the sources the queues scan."""

    def __init__(self, features=(), files=None):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        schema = self.root / gen.SCHEMA
        schema.parent.mkdir(parents=True)
        shutil.copy(REPO / gen.SCHEMA, schema)
        (self.root / "cmux-tui").mkdir()
        shutil.copy(REPO / "cmux-tui/rustfmt.toml", self.root / "cmux-tui/rustfmt.toml")
        for feature in features:
            self.write_feature(feature)
        for rel, text in (files or {}).items():
            self.write(rel, text)

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
                 with_(KILL, stories=["a", "a"]), with_(KILL, sticky="yes")]
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
        repo = Repo()
        self.addCleanup(repo.close)
        repo.write(gen.FEATURES_DIR + "/cefLayerHosting.json",
                   json.dumps(PERF).replace('"default": 0.05', '"default": Infinity'))
        self.assertEqual(repo.run("--check")[0], 1)


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
        self.repo.write(gen.RUST_OUT, raw.replace("\n    ", "\n        ").replace("},\n    ],", "}],"))
        self.assertEqual(self.repo.run("--check")[0], 0)
        self.repo.write(gen.RUST_OUT, raw.replace("sticky: true", "sticky: false"))
        self.assertEqual(self.repo.run("--check")[0], 1)
        self.repo.write(gen.RUST_OUT, raw.replace("Ring size in MiB.", "Ring size in  MiB."))
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

    def test_rust_has_only_daemon_side_features(self):
        self.repo.run()
        rust = self.repo.read(gen.RUST_OUT)
        self.assertIn("pub const FLAGS_FETCH: crate::Feature", rust)
        self.assertIn("pub const TERMINAL_HOLDER: crate::Feature", rust)
        self.assertNotIn("CEF_LAYER_HOSTING", rust)
        self.assertNotIn("BACK_FORWARD_CACHE", rust)
        self.assertIn("pub static REGISTERED: &[crate::Feature] = &[FLAGS_FETCH, TERMINAL_HOLDER];", rust)

    def test_empty_registry(self):
        repo = Repo()
        self.addCleanup(repo.close)
        self.assertEqual(repo.run()[0], 0)
        self.assertIn("public static let registered: [Feature] = []", repo.read(gen.SWIFT_OUT))
        self.assertIn("pub static REGISTERED: &[crate::Feature] = &[];", repo.read(gen.RUST_OUT))

    @unittest.skipUnless(shutil.which("rustc") and shutil.which("rustfmt"), "no Rust toolchain")
    def test_generated_rust_compiles_and_is_rustfmt_clean(self):
        for features in ([PERF, HOLDER, KILL, CHROMIUM], []):
            repo = Repo(features)
            self.addCleanup(repo.close)
            repo.run()
            crate = repo.root / "crate"
            crate.mkdir()
            shutil.copy(repo.root / gen.RUST_OUT, crate / "generated.rs")
            (crate / "lib.rs").write_text(RUST_INTERFACE)
            shutil.copy(repo.root / "cmux-tui/rustfmt.toml", crate / "rustfmt.toml")
            fmt = subprocess.run(["rustfmt", "--edition", gen.RUST_EDITION, "--check", "generated.rs"], cwd=crate,
                                 capture_output=True, text=True)
            self.assertEqual(fmt.returncode, 0, fmt.stdout + fmt.stderr)
            build = subprocess.run(["rustc", "--edition", gen.RUST_EDITION, "--crate-type", "lib", "--emit", "metadata",
                                    "-o", str(crate / "out.rmeta"), "lib.rs"], cwd=crate, capture_output=True, text=True)
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
        keys = [key for key, _ in gen.unmigrated(str(REPO), features)]
        self.assertIn("motion.pane.holdContent", keys)
        self.assertIn("CMUX_TUI_TERMINAL_HOST_MODEL", keys)


if __name__ == "__main__":
    unittest.main()
