#!/usr/bin/env python3
"""env_audit.py on fixture trees: Swift #if and Rust cfg gates, constants used in other files, the
automatic classes, --check on a new name and on a Debug-only name that became Release code, follow-ups,
and the checked-in audit against an independent `git grep -o` of the two queries.

  python3 -m unittest scripts/features/tests/test_env_audit.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "env_audit.py"
REPO = SCRIPT.parent.parent.parent
APP = "Packages/macOS/CmuxNext/Sources"
CRATES = "cmux-tui/crates"


def load_script():
    spec = importlib.util.spec_from_file_location("cmux_env_audit_for_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


audit = load_script()


class Tree:
    """A fixture checkout (no git: the script walks it)."""

    def __init__(self, test: unittest.TestCase):
        self._dir = tempfile.TemporaryDirectory()
        test.addCleanup(self._dir.cleanup)
        self.root = self._dir.name

    def write(self, rel: str, text: str) -> None:
        path = Path(self.root, rel)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")

    def run(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = audit.main([*argv, "--root", self.root])
        return code, out.getvalue(), err.getvalue()

    def document(self) -> dict:
        return json.loads(Path(self.root, audit.AUDIT).read_text(encoding="utf-8"))

    def save(self, document: dict) -> None:
        Path(self.root, audit.AUDIT).write_text(json.dumps(document), encoding="utf-8")

    def classify(self, scope: str, name: str, klass: str, note: str = "a note", followup: str | None = None) -> None:
        document = self.document()
        entry = {"class": klass, "note": note, **({"followup": followup} if followup else {})}
        document[scope][name] = {**entry, "sites": document[scope][name]["sites"]}
        self.save(document)


def site_values(sites, name):
    return [(site.kind, site.gate.release) for site in sites[name]]


class SwiftGateTests(unittest.TestCase):
    def test_if_elseif_else_values_in_release_and_bench(self):
        lines = textwrap.dedent("""
            a
            #if DEBUG
            b
            #elseif CMUX_BENCH_HOOKS
            c
            #else
            d
            #endif
            #if DEBUG || CMUX_BENCH_HOOKS
            e
            #if os(macOS)
            f
            #endif
            #endif
            #if CMUX_NO_COOKIE_IMPORT
            g
            #endif
            #if !DEBUG
            h
            #endif
        """).strip("\n")
        gates = audit.swift_gates(lines)
        by_text = {line: gates[index] for index, line in enumerate(lines.splitlines()) if len(line) == 1}
        self.assertEqual((by_text["a"].release, by_text["a"].bench), (True, True))
        self.assertEqual((by_text["b"].release, by_text["b"].bench), (False, False))
        self.assertEqual((by_text["c"].release, by_text["c"].bench), (False, True))
        self.assertEqual((by_text["d"].release, by_text["d"].bench), (True, False))
        self.assertEqual((by_text["e"].release, by_text["e"].bench), (False, True))
        self.assertEqual((by_text["f"].release, by_text["f"].bench), (False, True))
        self.assertIsNone(by_text["g"].release)  # a build variant: maybe compiled
        self.assertEqual(by_text["h"].release, True)

    def test_blocking_checks_is_not_debug_only(self):
        # nightly.yml builds the nightly-next Release app with -DCMUX_BLOCKING_CHECKS.
        gate = audit.swift_gates("#if DEBUG || CMUX_BLOCKING_CHECKS\nx\n#endif\n")[1]
        self.assertIsNot(gate.release, False)
        tree = Tree(self)
        tree.write(f"{APP}/Checks.swift", """
            #if DEBUG || CMUX_BLOCKING_CHECKS
            let strict = ProcessInfo.processInfo.environment["CMUX_NEXT_STRICT_KNOB"]
            #endif
        """)
        scanned = audit.scan(tree.root)["app"]
        self.assertIsNone(audit.automatic_class("app", scanned["CMUX_NEXT_STRICT_KNOB"]))

    def test_unreadable_condition_is_an_error(self):
        with self.assertRaises(audit.AuditError):
            audit.swift_gates("#if DEBUG &&& X\n#endif\n")


class RustGateTests(unittest.TestCase):
    def gate_of(self, source: str, needle: str) -> object:
        source = textwrap.dedent(source)
        parsed = audit.analyze_rust(source)
        for number, line in enumerate(source.splitlines(), 1):
            column = line.find(needle)
            if column >= 0:
                return parsed.at(number, column)[1]
        raise AssertionError(needle)

    def test_cfg_on_a_statement_ends_at_its_semicolon(self):
        source = """
            fn f() {
                #[cfg(debug_assertions)]
                let a = std::env::var("ONE");
                let b = std::env::var("TWO");
            }
        """
        self.assertIs(self.gate_of(source, '"ONE"').release, False)
        self.assertIs(self.gate_of(source, '"TWO"').release, True)

    def test_cfg_on_an_if_let_gates_its_block(self):
        source = """
            fn f() {
                #[cfg(debug_assertions)]
                if let Some(ms) = std::env::var("ONE").ok() {
                    sleep("INSIDE");
                }
                after("TWO");
            }
        """
        self.assertIs(self.gate_of(source, '"ONE"').release, False)
        self.assertIs(self.gate_of(source, '"INSIDE"').release, False)
        self.assertIs(self.gate_of(source, '"TWO"').release, True)

    def test_test_module_generic_function_and_const_fn(self):
        source = """
            #[cfg(test)]
            mod tests {
                fn helper() { var("IN_TESTS"); }
            }
            #[cfg(test)]
            fn generic<A, B>(a: A, b: B) { var("GENERIC"); }
            #[cfg(not(test))]
            const fn shipped() -> &'static str { "SHIPPED" }
            #[test]
            fn case() { var("CASE"); }
            fn plain() { var("PLAIN"); }
            fn runtime() { if cfg!(debug_assertions) { var("RUNTIME_DEBUG"); } }
        """
        for needle in ('"IN_TESTS"', '"GENERIC"', '"CASE"', '"RUNTIME_DEBUG"'):
            self.assertIs(self.gate_of(source, needle).release, False, needle)
        self.assertIs(self.gate_of(source, '"SHIPPED"').release, True)
        self.assertIs(self.gate_of(source, '"PLAIN"').release, True)

    def test_targets_and_features_are_unknown(self):
        source = """
            #[cfg(target_os = "macos")]
            fn mac() { var("MAC"); }
            #[cfg(all(unix, not(debug_assertions)))]
            fn shipping_unix() { var("UNIX"); }
        """
        self.assertIsNone(self.gate_of(source, '"MAC"').release)
        self.assertIsNone(self.gate_of(source, '"UNIX"').release)

    def test_strings_comments_and_lifetimes_do_not_confuse_the_brackets(self):
        source = """
            #[cfg(test)]
            fn f<'a>(x: &'a str) {
                let s = "{ not a brace";
                let r = r#"} "quoted" {"#;
                let c = '}';
                /* } nested /* } */ } */
                var("STILL_TEST");
            }
            fn g() { var("AFTER"); }
        """
        self.assertIs(self.gate_of(source, '"STILL_TEST"').release, False)
        self.assertIs(self.gate_of(source, '"AFTER"').release, True)


class ScanTests(unittest.TestCase):
    def test_a_test_file_included_by_path_attribute_is_test_code(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", """
            pub fn read() -> Option<String> { std::env::var("CMUX_TUI_SHIPPED").ok() }
            #[cfg(test)]
            #[path = "lib_tests.rs"]
            mod tests;
        """)
        tree.write(f"{CRATES}/core/src/lib_tests.rs", 'fn t() { std::env::var("CMUX_TUI_ONLY_TESTS"); }\n')
        tree.write(f"{CRATES}/core/tests/journey.rs", 'fn t() { std::env::var("CMUX_TUI_JOURNEY"); }\n')
        scanned = audit.scan(tree.root)["daemon"]
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_ONLY_TESTS"]), "testOnly")
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_JOURNEY"]), "testOnly")
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_SHIPPED"]))

    def test_a_module_under_cfg_debug_assertions_is_debug_only(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", "#[cfg(debug_assertions)]\nmod seams;\n")
        tree.write(f"{CRATES}/core/src/seams.rs", 'pub fn delay() { std::env::var("CMUX_TUI_TEST_DELAY_MS"); }\n')
        scanned = audit.scan(tree.root)["daemon"]
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_TEST_DELAY_MS"]), "debugOnly")

    def test_rust_constant_is_judged_where_it_is_used(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", """
            const DEBUG_ENV: &str = "CMUX_TUI_DEBUG_THING";
            const SHIPPED_ENV: &str = "CMUX_TUI_SHIPPED_THING";
            fn f() {
                #[cfg(debug_assertions)]
                let a = std::env::var(DEBUG_ENV);
                let b = std::env::var(SHIPPED_ENV);
            }
        """)
        scanned = audit.scan(tree.root)["daemon"]
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_DEBUG_THING"]), "debugOnly")
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_SHIPPED_THING"]))
        self.assertIn(("via SHIPPED_ENV", True), site_values(scanned, "CMUX_TUI_SHIPPED_THING"))

    def test_a_nested_mod_line_does_not_gate_the_sibling_file(self):
        # `mod foo;` in src/a.rs is src/a/foo.rs (Rust 2018), never src/foo.rs.
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/main.rs", "mod a;\nmod foo;\nfn main() {}\n")
        tree.write(f"{CRATES}/core/src/a.rs", "#[cfg(test)]\nmod foo;\n")
        tree.write(f"{CRATES}/core/src/a/foo.rs", 'fn t() { std::env::var("CMUX_TUI_NESTED_TEST_KNOB"); }\n')
        tree.write(f"{CRATES}/core/src/foo.rs", 'pub fn knob() { std::env::var("CMUX_TUI_PERF_KNOB"); }\n')
        scanned = audit.scan(tree.root)["daemon"]
        self.assertEqual(site_values(scanned, "CMUX_TUI_PERF_KNOB"), [("use", True)])
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_PERF_KNOB"]))
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_NESTED_TEST_KNOB"]), "testOnly")

    def test_a_file_included_twice_takes_either_gate(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", """
            #[cfg(test)]
            #[path = "shared.rs"]
            mod shared_for_tests;
            #[path = "shared.rs"]
            mod shared;
            #[cfg(test)]
            #[path = "fixtures.rs"]
            mod fixtures;
            #[cfg(debug_assertions)]
            #[path = "fixtures.rs"]
            mod fixtures_debug;
        """)
        tree.write(f"{CRATES}/core/src/shared.rs", 'pub fn knob() { std::env::var("CMUX_TUI_SHARED_KNOB"); }\n')
        tree.write(f"{CRATES}/core/src/fixtures.rs", 'pub fn knob() { std::env::var("CMUX_TUI_FIXTURE_KNOB"); }\n')
        scanned = audit.scan(tree.root)["daemon"]
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_SHARED_KNOB"]))
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_FIXTURE_KNOB"]), "debugOnly")

    def test_rust_constant_declared_twice_counts_its_qualified_uses(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", "mod a;\nmod b;\nmod c;\nmod d;\nmod e;\nmod f;\n")
        tree.write(f"{CRATES}/core/src/a.rs", """
            pub(crate) const ENV: &str = "CMUX_TUI_KNOB";
            #[cfg(test)]
            mod tests {
                #[test]
                fn reads() { std::env::var(super::ENV); }
            }
        """)
        tree.write(f"{CRATES}/core/src/b.rs", """
            const ENV: &str = "CMUX_TUI_OTHER";
            #[cfg(test)]
            fn t() { std::env::var(ENV); }
        """)
        tree.write(f"{CRATES}/core/src/c.rs", "pub fn knob() { std::env::var(crate::a::ENV); }\n")
        tree.write(f"{CRATES}/core/src/d.rs", "use crate::{a::ENV, b};\npub fn knob() { std::env::var(ENV); }\n")
        tree.write(f"{CRATES}/core/src/e.rs", "use crate::a;\npub fn knob() { std::env::var(a::ENV); }\n")
        tree.write(f"{CRATES}/core/src/f.rs", "use super::b::*;\npub fn knob() { std::env::var(ENV); }\n")
        scanned = audit.scan(tree.root)["daemon"]
        knob = [site.at.split("/src/")[1] for site in scanned["CMUX_TUI_KNOB"] if site.kind == "via ENV"]
        self.assertEqual(knob, ["a.rs:5", "c.rs:1", "d.rs:1", "d.rs:2", "e.rs:2"])
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_KNOB"]))
        other = [site.at.split("/src/")[1] for site in scanned["CMUX_TUI_OTHER"] if site.kind == "via ENV"]
        self.assertEqual(other, ["b.rs:3", "f.rs:2"])

    def test_rust_use_trees_and_inline_modules(self):
        parsed = audit.analyze_rust(textwrap.dedent("""
            use crate::{a::{self, ENV as E}, b::*};
            mod tests {
                pub(crate) use super::c::D;
                fn t() { D; }
            }
            fn f() { D; }
        """))
        self.assertEqual(parsed.imports, [
            ((), ("crate", "a"), "self", "self"), ((), ("crate", "a"), "ENV", "E"), ((), ("crate", "b"), "*", "*"),
            (("tests",), ("super", "c"), "D", "D")])
        self.assertEqual(parsed.scope(5, 14), ("tests",))
        self.assertEqual(parsed.scope(7, 9), ())

    def test_a_use_in_an_inline_module_applies_only_there(self):
        tree = Tree(self)
        tree.write(f"{CRATES}/core/src/lib.rs", "mod a;\nmod b;\nmod c;\n")
        tree.write(f"{CRATES}/core/src/a.rs", 'pub(crate) const ENV: &str = "CMUX_TUI_SCOPED_KNOB";\n')
        tree.write(f"{CRATES}/core/src/b.rs", 'pub(crate) const ENV: &str = "CMUX_TUI_SCOPED_OTHER";\n')
        tree.write(f"{CRATES}/core/src/c.rs", """
            #[cfg(test)]
            mod tests {
                use crate::a::ENV;
                fn t() { std::env::var(ENV); }
            }
            use crate::b::ENV;
            pub fn knob() { std::env::var(ENV); }
        """)
        scanned = audit.scan(tree.root)["daemon"]
        self.assertEqual(audit.automatic_class("daemon", scanned["CMUX_TUI_SCOPED_KNOB"]), "testOnly")
        self.assertIsNone(audit.automatic_class("daemon", scanned["CMUX_TUI_SCOPED_OTHER"]))

    def test_swift_constant_used_in_another_file(self):
        tree = Tree(self)
        tree.write(f"{APP}/Settings/Policy.swift", """
            public enum PolicyFile {
                public static let fileOverrideKey = "CMUX_NEXT_POLICY_FILE"
            }
            public enum Other {
                public static let fileOverrideKey = "CMUX_NEXT_OTHER_FILE"
            }
        """)
        tree.write(f"{APP}/Settings/Reader.swift", """
            func read(_ environment: [String: String]) {
                #if DEBUG
                let path = environment[PolicyFile.fileOverrideKey]
                #endif
                let other = environment[Other.fileOverrideKey]
            }
        """)
        scanned = audit.scan(tree.root)["app"]
        self.assertEqual(audit.automatic_class("app", scanned["CMUX_NEXT_POLICY_FILE"]), "debugOnly")
        self.assertIsNone(audit.automatic_class("app", scanned["CMUX_NEXT_OTHER_FILE"]))

    def test_swift_kinds_comments_writes_and_bench_only(self):
        tree = Tree(self)
        tree.write(f"{APP}/Launch.swift", """
            /// Reads `"CMUX_NEXT_DOC_ONLY"`.
            func launch(_ environment: [String: String]) -> [String: String] {
                var child = ["CMUX_CHILD_SOCKET": "/tmp/s"]
                child["CMUX_CHILD_TAG"] = "t"
                #if DEBUG || CMUX_BENCH_HOOKS
                let bench = environment["CMUX_NEXT_BENCH_ONLY"]
                #endif
                return child
            }
        """)
        scanned = audit.scan(tree.root)["app"]
        self.assertEqual(audit.automatic_class("app", scanned["CMUX_NEXT_DOC_ONLY"]), "docOnly")
        self.assertEqual(audit.automatic_class("app", scanned["CMUX_NEXT_BENCH_ONLY"]), "benchOnly")
        self.assertEqual(site_values(scanned, "CMUX_CHILD_SOCKET"), [("write", True)])
        self.assertEqual(site_values(scanned, "CMUX_CHILD_TAG"), [("write", True)])


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree(self)
        self.tree.write(f"{APP}/Knobs.swift", """
            func knobs(_ environment: [String: String]) {
                #if DEBUG
                let a = environment["CMUX_NEXT_DEBUG_KNOB"]
                #endif
                let b = environment["CMUX_NEXT_SHIPPED_KNOB"]
            }
        """)
        self.tree.write(f"{CRATES}/core/src/lib.rs", 'pub fn mode() { std::env::var("CMUX_TUI_HOST_MODE"); }\n')

    def test_a_new_name_fails_until_it_is_written_and_classified(self):
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("CMUX_NEXT_SHIPPED_KNOB: new name", err)
        self.assertEqual(self.tree.run("--write")[0], 0)
        document = self.tree.document()
        self.assertEqual(document["app"]["CMUX_NEXT_DEBUG_KNOB"]["class"], "debugOnly")
        self.assertEqual(document["app"]["CMUX_NEXT_SHIPPED_KNOB"]["class"], "unclassified")
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("CMUX_NEXT_SHIPPED_KNOB: unclassified", err)
        code, out, _ = self.tree.run("--unclassified")
        self.assertEqual(code, 0)
        self.assertIn("CMUX_NEXT_SHIPPED_KNOB", out)
        self.assertNotIn("CMUX_NEXT_DEBUG_KNOB", out)

        self.tree.classify("app", "CMUX_NEXT_SHIPPED_KNOB", "releaseConfig", "a path override")
        self.tree.classify("daemon", "CMUX_TUI_HOST_MODE", "releaseConfig", "a mode")
        self.assertEqual(self.tree.run("--check")[0], 0)

        self.tree.write(f"{APP}/More.swift", 'let added = ProcessInfo.processInfo.environment["CMUX_NEXT_ADDED"]\n')
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("CMUX_NEXT_ADDED: new name", err)

    def test_a_debug_only_name_that_becomes_release_code_fails(self):
        self.tree.run("--write")
        self.tree.classify("app", "CMUX_NEXT_SHIPPED_KNOB", "releaseConfig")
        self.tree.classify("daemon", "CMUX_TUI_HOST_MODE", "releaseConfig")
        self.assertEqual(self.tree.run("--check")[0], 0)
        self.tree.write(f"{APP}/Knobs.swift", 'let a = ProcessInfo.processInfo.environment["CMUX_NEXT_DEBUG_KNOB"]\n'
                                              'let b = ProcessInfo.processInfo.environment["CMUX_NEXT_SHIPPED_KNOB"]\n')
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("CMUX_NEXT_DEBUG_KNOB: recorded debugOnly, now compiled into Release", err)

    def test_manual_classes_need_a_note_and_perf_paths_a_known_follow_up(self):
        self.tree.run("--write")
        self.tree.classify("app", "CMUX_NEXT_SHIPPED_KNOB", "releaseConfig", note="")
        self.tree.classify("daemon", "CMUX_TUI_HOST_MODE", "releasePerfPath", followup="T-1")
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("releaseConfig needs a note", err)
        self.assertIn("follow-up 'T-1' is not in `followups`", err)

    def test_follow_ups_leave_the_queue_when_resolved(self):
        self.tree.run("--write")
        self.tree.classify("app", "CMUX_NEXT_SHIPPED_KNOB", "releasePerfPath", followup="T-out")
        self.tree.classify("daemon", "CMUX_TUI_HOST_MODE", "releasePerfPath", followup="T-feature")
        document = self.tree.document()
        document["followups"] = {"T-out": {"title": "compile it out", "resolution": "compileOut"},
                                 "T-feature": {"title": "a feature", "resolution": "feature:hostMode"}}
        self.tree.save(document)
        code, out, _ = self.tree.run("--check")
        self.assertEqual(code, 0)
        self.assertIn("2 perf-path follow-ups open", out)
        _, queue, _ = self.tree.run("--unclassified")
        self.assertIn("perf path: T-out, compile it out of Release", queue)
        self.assertIn("perf path: T-feature, feature:hostMode", queue)

        self.tree.write("schemas/features/features.d/hostMode.json",
                        json.dumps({"name": "hostMode", "replaces": ["CMUX_TUI_HOST_MODE"]}))
        self.tree.write(f"{APP}/Knobs.swift", """
            func knobs(_ environment: [String: String]) {
                #if DEBUG
                let a = environment["CMUX_NEXT_DEBUG_KNOB"]
                let b = environment["CMUX_NEXT_SHIPPED_KNOB"]
                #endif
            }
        """)
        _, queue, _ = self.tree.run("--unclassified")
        self.assertNotIn("CMUX_TUI_HOST_MODE", queue)
        self.assertIn("CMUX_NEXT_SHIPPED_KNOB", queue)
        self.assertIn("resolved (now debugOnly)", queue)
        self.tree.run("--write")
        self.assertEqual(self.tree.document()["app"]["CMUX_NEXT_SHIPPED_KNOB"]["class"], "debugOnly")
        self.assertIn("0 perf-path follow-ups open", self.tree.run("--check")[1])

    def test_bad_follow_up_resolution_fails(self):
        self.tree.run("--write")
        document = self.tree.document()
        document["followups"] = {"T-1": {"title": "x", "resolution": "later"}}
        self.tree.save(document)
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("resolution must be", err)


class CheckedInAuditTests(unittest.TestCase):
    """The repository's audit lists every name an independent `git grep -o` of the two queries returns."""

    def grep_names(self, pattern: str, pathspec: str) -> set[str]:
        command = ["git", "-C", str(REPO), "grep", "--untracked", "-h", "-o", "-E", pattern, "--", pathspec]
        done = subprocess.run(command, capture_output=True, text=True, check=False)
        if done.returncode not in (0, 1):
            self.skipTest("not a git checkout")
        return {match[1:] for match in done.stdout.split()}

    def test_every_queried_name_is_in_the_audit(self):
        document = json.loads((REPO / audit.AUDIT).read_text(encoding="utf-8"))
        app = self.grep_names(r'"CMUX_[A-Z0-9_]+', f"{APP}/*.swift")
        daemon = self.grep_names(r'"CMUX_TUI_[A-Z0-9_]+', f"{CRATES}/*.rs")
        self.assertTrue(app and daemon)
        self.assertEqual(sorted(app - set(document["app"])), [])
        self.assertEqual(sorted(daemon - set(document["daemon"])), [])
        for scope in ("app", "daemon"):
            for name, entry in document[scope].items():
                self.assertIn(entry["class"], audit.CLASSES + (audit.UNCLASSIFIED,), name)
                self.assertTrue(re.fullmatch(r"CMUX_[A-Z0-9_]+", name), name)


if __name__ == "__main__":
    unittest.main()
