#!/usr/bin/env python3
"""env_audit.py: the build each site compiles into (Swift #if, Rust cfg), constants that take the
build of their uses, and --check / --write / --unclassified on a temp repo root.

  python3 -m unittest scripts/features/tests/test_env_audit.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "env_audit.py"
REPO = SCRIPT.parent.parent.parent


def load_script():
    spec = importlib.util.spec_from_file_location("cmux_env_audit_for_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


audit = load_script()


class TempRoot:
    def __init__(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")

    def swift(self, rel, text):
        self.write("%s/%s" % (audit.APP_ROOT, rel), text)

    def rust(self, rel, text):
        self.write("%s/%s" % (audit.DAEMON_ROOT, rel), text)

    def run(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = audit.main(list(argv), root=str(self.root))
        return code, out.getvalue(), err.getvalue()

    def entries(self):
        return json.loads((self.root / audit.AUDIT).read_text(encoding="utf-8"))["names"]

    def classify(self, key, klass, effect="changes something", followup=None):
        path = self.root / audit.AUDIT
        document = json.loads(path.read_text(encoding="utf-8"))
        document["names"][key]["class"] = klass
        document["names"][key]["effect"] = effect
        if followup:
            document["names"][key]["followup"] = followup
        path.write_text(json.dumps(document), encoding="utf-8")

    def close(self):
        self._dir.cleanup()


def builds(sites):
    return {site.name: site.build for site in sites}


class SwiftBuildTests(unittest.TestCase):
    def setUp(self):
        self.repo = TempRoot()
        self.addCleanup(self.repo.close)

    def test_if_branches(self):
        self.repo.swift("A/A.swift", '''
            let a = env["CMUX_PLAIN"]
            #if DEBUG
            let b = env["CMUX_IN_DEBUG"]
            #else
            let c = env["CMUX_IN_ELSE"]
            #endif
            #if DEBUG || CMUX_BENCH_HOOKS
            let d = env["CMUX_IN_BENCH"]
            #endif
            #if DEBUG || CMUX_BLOCKING_CHECKS
            let e = env["CMUX_IN_NIGHTLY"]
            #endif
            #if !DEBUG
            let f = env["CMUX_NOT_DEBUG"]
            #else
            let g = env["CMUX_ELSE_OF_NOT_DEBUG"]
            #endif
            #if arch(arm64)
            #if DEBUG
            let h = env["CMUX_NESTED_DEBUG"]
            #endif
            #endif
            // env["CMUX_IN_COMMENT"]
            let i = "// not a comment"; let j = env["CMUX_AFTER_STRING"]
        ''')
        self.assertEqual(builds(audit.scan_swift(str(self.repo.root))), {
            "CMUX_PLAIN": "release", "CMUX_IN_DEBUG": "debug", "CMUX_IN_ELSE": "release",
            "CMUX_IN_BENCH": "bench", "CMUX_IN_NIGHTLY": "nightly", "CMUX_NOT_DEBUG": "release",
            "CMUX_ELSE_OF_NOT_DEBUG": "debug", "CMUX_NESTED_DEBUG": "debug", "CMUX_IN_COMMENT": "comment",
            "CMUX_AFTER_STRING": "release"})

    def test_constant_takes_the_build_of_its_uses(self):
        self.repo.swift("A/Key.swift", '''
            struct Policy {
                static let key = "CMUX_KEY_USED_IN_DEBUG"
                static let other = "CMUX_KEY_USED_IN_RELEASE"
                static let unused = "CMUX_KEY_UNUSED"
            }
        ''')
        self.repo.swift("B/Reader.swift", '''
            #if DEBUG
            let a = env[Policy.key]
            #endif
            let b = env[Policy.other]
            let c = env[Unrelated.key]
        ''')
        sites = {site.name: site for site in audit.scan_swift(str(self.repo.root))}
        self.assertEqual(sites["CMUX_KEY_USED_IN_DEBUG"].build, "debug")
        self.assertEqual(sites["CMUX_KEY_USED_IN_DEBUG"].kind, "decl")
        self.assertIn("via key at %s/B/Reader.swift:2" % audit.APP_ROOT, sites["CMUX_KEY_USED_IN_DEBUG"].condition)
        self.assertEqual(sites["CMUX_KEY_USED_IN_RELEASE"].build, "release")
        self.assertEqual(sites["CMUX_KEY_UNUSED"].build, "release")

    def test_kinds(self):
        self.repo.swift("A/A.swift", '''
            let r = ProcessInfo.processInfo.environment["CMUX_READ"]
            env["CMUX_WRITE"] = "1"
            let child = ["CMUX_CHILD": value]
        ''')
        kinds = {site.name: site.kind for site in audit.scan_swift(str(self.repo.root))}
        self.assertEqual(kinds, {"CMUX_READ": "read", "CMUX_WRITE": "write", "CMUX_CHILD": "write"})


class RustBuildTests(unittest.TestCase):
    def setUp(self):
        self.repo = TempRoot()
        self.addCleanup(self.repo.close)

    def test_cfg_items(self):
        self.repo.rust("core/src/lib.rs", '''
            fn plain() { std::env::var("CMUX_TUI_PLAIN"); }
            #[cfg(debug_assertions)]
            fn debug_only() {
                let s = "}"; // a brace in a string does not close the item
                std::env::var("CMUX_TUI_DEBUG_FN");
            }
            fn after() { std::env::var("CMUX_TUI_AFTER_DEBUG_FN"); }
            fn fields() -> Thing {
                Thing {
                    #[cfg(debug_assertions)]
                    a: read(std::env::var("CMUX_TUI_DEBUG_FIELD")),
                    b: read(std::env::var("CMUX_TUI_RELEASE_FIELD")),
                }
            }
            #[cfg(all(unix, debug_assertions))]
            const DEBUG_ENV: &str = "CMUX_TUI_DEBUG_CONST";
            fn uses() { if cfg!(debug_assertions) { std::env::var("CMUX_TUI_CFG_MACRO"); } }
            #[cfg(test)]
            mod tests {
                #[test]
                fn t() { std::env::set_var("CMUX_TUI_IN_TESTS", "1"); }
            }
            #[cfg(not(debug_assertions))]
            fn release_only() { std::env::var("CMUX_TUI_NOT_DEBUG"); }
            /// Reads `"CMUX_TUI_IN_DOC"`.
            fn documented() {}
            const RAW: &str = r#"CMUX_TUI_RAW "quoted""#;
        ''')
        self.repo.rust("core/tests/it.rs", '''
            fn t() { std::env::var("CMUX_TUI_INTEGRATION_TEST"); }
        ''')
        self.assertEqual(builds(audit.scan_rust(str(self.repo.root))), {
            "CMUX_TUI_PLAIN": "release", "CMUX_TUI_DEBUG_FN": "debug", "CMUX_TUI_AFTER_DEBUG_FN": "release",
            "CMUX_TUI_DEBUG_FIELD": "debug", "CMUX_TUI_RELEASE_FIELD": "release", "CMUX_TUI_DEBUG_CONST": "debug",
            "CMUX_TUI_CFG_MACRO": "debug", "CMUX_TUI_IN_TESTS": "test", "CMUX_TUI_NOT_DEBUG": "release",
            "CMUX_TUI_IN_DOC": "comment", "CMUX_TUI_INTEGRATION_TEST": "test"})

    def test_test_module_file_and_inner_cfg(self):
        self.repo.rust("core/src/lib.rs", '''
            #[cfg(test)]
            mod unit;
        ''')
        self.repo.rust("core/src/unit.rs", 'fn t() { std::env::var("CMUX_TUI_UNIT_FILE"); }\n')
        self.repo.rust("core/src/debug_file.rs", '''
            #![cfg(debug_assertions)]
            fn t() { std::env::var("CMUX_TUI_INNER_CFG"); }
        ''')
        self.assertEqual(builds(audit.scan_rust(str(self.repo.root))),
                         {"CMUX_TUI_UNIT_FILE": "test", "CMUX_TUI_INNER_CFG": "debug"})

    def test_constant_takes_the_build_of_its_uses(self):
        self.repo.rust("core/src/lib.rs", '''
            pub const SHARED_ENV: &str = "CMUX_TUI_SHARED";
            const LOCAL_ENV: &str = "CMUX_TUI_LOCAL";
            #[cfg(debug_assertions)]
            fn read() { std::env::var(LOCAL_ENV); }
        ''')
        self.repo.rust("other/src/lib.rs", '''
            fn release_read() { std::env::var(core::SHARED_ENV); }
        ''')
        sites = {site.name: site for site in audit.scan_rust(str(self.repo.root))}
        self.assertEqual(sites["CMUX_TUI_LOCAL"].build, "debug")
        self.assertEqual(sites["CMUX_TUI_SHARED"].build, "release")
        self.assertIn("other/src/lib.rs:1", sites["CMUX_TUI_SHARED"].condition)

    def test_daemon_query_ignores_other_names(self):
        self.repo.rust("core/src/lib.rs", 'fn f() { std::env::var("CMUX_SOCKET_PATH"); }\n')
        self.assertEqual(audit.scan_rust(str(self.repo.root)), [])


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.repo = TempRoot()
        self.addCleanup(self.repo.close)
        self.repo.swift("A/A.swift", '''
            let a = env["CMUX_NEXT_RELEASE_KNOB"]
            #if DEBUG
            let b = env["CMUX_NEXT_DEBUG_KNOB"]
            #endif
        ''')
        self.repo.rust("core/src/lib.rs", 'fn f() { std::env::var("CMUX_TUI_HOT_PATH"); }\n')

    def classify_all(self):
        self.assertEqual(self.repo.run("--write")[0], 0)
        self.repo.classify("app CMUX_NEXT_RELEASE_KNOB", "releaseConfig")
        self.repo.classify("app CMUX_NEXT_DEBUG_KNOB", "debugOnly")
        self.repo.classify("daemon CMUX_TUI_HOT_PATH", "releasePerf", followup="make it a feature")

    def test_check_fails_without_an_audit_file(self):
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("app CMUX_NEXT_RELEASE_KNOB: new name", err)

    def test_write_adds_names_unclassified_and_check_fails_on_them(self):
        self.assertEqual(self.repo.run("--write")[0], 0)
        entries = self.repo.entries()
        self.assertEqual(sorted(entries), ["app CMUX_NEXT_DEBUG_KNOB", "app CMUX_NEXT_RELEASE_KNOB",
                                           "daemon CMUX_TUI_HOT_PATH"])
        self.assertEqual(entries["app CMUX_NEXT_DEBUG_KNOB"]["builds"], ["debug"])
        self.assertEqual(entries["app CMUX_NEXT_DEBUG_KNOB"]["sites"],
                         ["%s/A/A.swift:3 debug read [#if DEBUG]" % audit.APP_ROOT])
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(err.count("unclassified"), 3)

    def test_check_passes_when_classified_and_fails_on_a_new_name(self):
        self.classify_all()
        self.assertEqual(self.repo.run("--check")[0], 0)
        self.repo.rust("core/src/new.rs", 'fn g() { std::env::var("CMUX_TUI_BRAND_NEW"); }\n')
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("daemon CMUX_TUI_BRAND_NEW: new name", err)

    def test_write_keeps_classes(self):
        self.classify_all()
        self.assertEqual(self.repo.run("--write")[0], 0)
        self.assertEqual(self.repo.entries()["daemon CMUX_TUI_HOT_PATH"]["followup"], "make it a feature")
        self.assertEqual(self.repo.run("--check")[0], 0)

    def test_check_fails_on_a_stale_name(self):
        self.classify_all()
        self.repo.rust("core/src/lib.rs", "fn f() {}\n")
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("daemon CMUX_TUI_HOT_PATH: stale", err)

    def test_debug_only_name_read_in_release_fails(self):
        self.classify_all()
        self.repo.swift("A/B.swift", 'let c = env["CMUX_NEXT_DEBUG_KNOB"]\n')
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("builds changed from ['debug'] to ['release', 'debug']", err)
        self.assertEqual(self.repo.run("--write")[0], 0)
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("class debugOnly but read in release, debug", err)

    def test_release_perf_needs_a_followup_and_a_release_read(self):
        self.classify_all()
        self.repo.classify("app CMUX_NEXT_RELEASE_KNOB", "releasePerf")
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("app CMUX_NEXT_RELEASE_KNOB: class releasePerf needs a followup", err)
        self.repo.classify("app CMUX_NEXT_DEBUG_KNOB", "releaseConfig")
        code, _, err = self.repo.run("--check")
        self.assertIn("app CMUX_NEXT_DEBUG_KNOB: class releaseConfig but no shipped build reads it", err)

    def test_unclassified_lists_unclassified_names_and_followups(self):
        self.assertEqual(self.repo.run("--write")[0], 0)
        self.repo.classify("app CMUX_NEXT_RELEASE_KNOB", "releaseConfig")
        self.repo.classify("daemon CMUX_TUI_HOT_PATH", "releasePerf", followup="make it a feature")
        code, out, _ = self.repo.run("--unclassified")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [
            "unclassified app CMUX_NEXT_DEBUG_KNOB %s/A/A.swift:3 debug read [#if DEBUG]" % audit.APP_ROOT,
            "followup daemon CMUX_TUI_HOT_PATH %s/core/src/lib.rs:1 release read: make it a feature"
            % audit.DAEMON_ROOT])
        self.assertEqual(self.repo.run("--unclassified", "--count")[1].strip(), "2")

    def test_malformed_audit_file_is_an_error(self):
        (self.repo.root / audit.AUDIT).parent.mkdir(parents=True, exist_ok=True)
        (self.repo.root / audit.AUDIT).write_text("[", encoding="utf-8")
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("env audit: %s" % audit.AUDIT, err)


class RepoTests(unittest.TestCase):
    def test_repo_audit_is_complete(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = audit.main(["--check"], root=str(REPO))
        self.assertEqual(code, 0, err.getvalue())


if __name__ == "__main__":
    unittest.main()
