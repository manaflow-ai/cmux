#!/usr/bin/env python3
"""Trap classes (p10-stability-205, Q21): rust_panic_ratchet.py --classify on a Rust fixture, the reader under the
classifier, trap-classes.json's checks, and the local-only refusal of a lowered notFatalUntil build.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the classifier:
  python3 -I scripts/cmux-next/tests/test_trap_classes.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the tools below must not write __pycache__ beside them

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ratchet = load("crash_ratchet_p10_205", "crash_ratchet.py")
panic = load("rust_panic_ratchet_p10_205", "rust_panic_ratchet.py")
guardrails = load("guardrails_p10_205", "guardrails.py")

RUST_FIXTURE = r'''//! A frame codec.
pub struct Header<'a> { name: &'a str }

pub fn decode_header<'a>(bytes: &'a [u8]) -> Header<'a> {
    let name = std::str::from_utf8(&bytes[1..]).unwrap();
    let tag = b'"';
    let _ = tag;
    Header { name: lookup(name) }
}

fn lookup(name: &str) -> &str {
    name.split(':').next().expect("a name")
}

/* fn decode_fake() {
   /* nested */ table() } */
pub fn table() -> u32 {
    let s = r#"fn parse_fake() { table() }"#;
    TABLE.get(0).copied().unwrap()
}

pub fn checked() -> u32 {
    // INVARIANT: TABLE is a non-empty const
    TABLE.first().copied().expect("non-empty")
}

pub fn read_config(path: &std::path::Path) -> String {
    let text = std::fs::read_to_string(path).unwrap();
    text
}

pub fn marked(n: u32) -> u32 {
    // trap-class: input n is a peer's frame count
    n.checked_sub(1).unwrap()
}

trait Codec {
    fn decode_trait(&self);
}

pub fn after_trait() -> u32 {
    TABLE.last().copied().unwrap()
}
'''
# (line, lint, class, rule prefix) of the fixture's hits.
RUST_HITS = [
    (5, "unwrap_used", "input", "entry:decode_header"),
    (5, "indexing_slicing", "input", "entry:decode_header"),
    (12, "expect_used", "input", "callee:lookup"),
    (19, "unwrap_used", "invariant", "default"),
    (24, "expect_used", "invariant", "invariant-reason"),
    (28, "unwrap_used", "input", "bytes:read_config"),
    (34, "unwrap_used", "input", "annotation"),
    (42, "unwrap_used", "invariant", "default"),
]


def clippy_hit(file_name, line, lint, column=9):
    return {"reason": "compiler-message", "package_id": "path+file:///w/cmux-tui/crates/codec#0.1.0",
            "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"},
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": column}]}}


class RustClassifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        src = self.repo / "cmux-tui/crates/codec/src"
        src.mkdir(parents=True)
        (src / "lib.rs").write_text(RUST_FIXTURE)
        items = [{"reason": "compiler-artifact", "package_id": "path+file:///w/cmux-tui/crates/codec#0.1.0",
                  "target": {"kind": ["lib"]}}]
        items += [clippy_hit("crates/codec/src/lib.rs", line, lint) for line, lint, _, _ in RUST_HITS]
        # The same line seen by a second run (an absolute path from another checkout) counts once.
        items.append(clippy_hit("/Users/fleet/w/cmux-tui/crates/codec/src/lib.rs", 19, "unwrap_used"))
        items.append({"reason": "build-finished", "success": True})
        self.jsonl = self.repo / "clippy.jsonl"
        self.jsonl.write_text("".join(json.dumps(item) + "\n" for item in items))

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["rust_panic_ratchet.py", "--repo", str(self.repo), *argv]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = panic.main()
                except SystemExit as exit_:
                    rc = exit_.code
        finally:
            sys.argv = old
        return rc, out.getvalue(), err.getvalue()

    def test_every_hit_has_exactly_one_class_and_its_rule(self):
        rc, out, err = self.run_main("--clippy-json", str(self.jsonl), "--classify")
        self.assertEqual(rc, 0, err)
        document = json.loads(out)
        got = sorted((h["line"], h["kind"], h["class"], h["rule"].split(" ")[0]) for h in document["hits"])
        self.assertEqual(got, sorted(RUST_HITS))
        self.assertEqual(document["classes"], {"input": 5, "invariant": 3})
        self.assertEqual(sum(document["classes"].values()), len(document["hits"]))
        self.assertEqual(document["kinds"]["rust.unwrap_used"], {"input": 3, "invariant": 2})
        self.assertTrue(all(h["module"] == "codec" and h["path"] == "cmux-tui/crates/codec/src/lib.rs"
                            and h["column"] == 9 for h in document["hits"]))
        self.assertEqual(document["errors"], [])

    def test_a_path_entry_decides_before_the_proxy(self):
        data = json.loads((SCRIPTS / "trap-classes.json").read_text())
        data["paths"] = [{"glob": "cmux-tui/crates/codec/*", "class": "input", "reason": "a wire crate"}]
        classes = self.repo / "classes.json"
        classes.write_text(json.dumps(data))
        run = panic.read_run(str(self.jsonl))
        document = panic.classify(str(self.repo), [run], ratchet.TrapClassifier(str(self.repo), str(classes)))
        rules = {(h["line"], h["kind"]): h["rule"] for h in document["hits"]}
        self.assertEqual(rules[(19, "unwrap_used")], "path:cmux-tui/crates/codec/*")
        self.assertEqual(rules[(24, "expect_used")], "invariant-reason")  # a mark in the window still goes first
        self.assertEqual(document["classes"], {"input": 7, "invariant": 1})

    def test_a_bad_mark_fails_and_classify_compares_nothing(self):
        source = self.repo / "cmux-tui/crates/codec/src/lib.rs"
        source.write_text(RUST_FIXTURE.replace("// trap-class: input n is a peer's frame count", "// trap-class: peer"))
        rc, out, err = self.run_main("--clippy-json", str(self.jsonl), "--classify")
        self.assertEqual(rc, 1)
        self.assertIn("cmux-tui/crates/codec/src/lib.rs:33: a `// trap-class:` mark needs input or invariant", err)
        rc, _, err = self.run_main("--clippy-json", str(self.jsonl), "--classify", "--update-baseline")
        self.assertEqual(rc, 2)
        self.assertIn("--classify only reports", err)

    def test_a_paths_entry_without_a_reason_is_refused(self):
        classes = self.repo / "classes.json"
        classes.write_text(json.dumps({"paths": [{"glob": "*", "class": "input"}]}))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            ratchet.TrapClassifier(str(self.repo), str(classes))
        self.assertEqual(raised.exception.code, 2)


class ReaderTests(unittest.TestCase):
    def test_source_code_blanks_comments_strings_and_char_literals_but_keeps_lifetimes_and_lines(self):
        text = "fn a<'a>(x: &'a str) { let c = '{'; let s = r#\"{ fn b() }\"#; /* { /* } */ */ }\n"
        code = ratchet.source_code(text, "rust")
        self.assertEqual(len(code), len(text))
        self.assertEqual(code.count("{"), 1)
        self.assertEqual(code.count("}"), 1)
        self.assertIn("<'a>", code)
        self.assertNotIn("fn b", code)

    def test_swift_multiline_raw_and_interpolated_strings(self):
        text = 'let a = """\n  func fake() {\n  """\nlet b = #"}"#\nlet c = "\\(f("}"))"\nfunc real() {\n}\n'
        functions = ratchet.function_spans(ratchet.source_code(text, "swift"), "swift")
        self.assertEqual([(f.name, f.start, f.end) for f in functions], [("real", 6, 7)])

    def test_a_requirement_without_a_body_is_no_function(self):
        text = "protocol P {\n    func parse(_ d: Data) -> Int\n    var x: Int { get }\n}\nfunc g() {\n}\n"
        functions = ratchet.function_spans(ratchet.source_code(text, "swift"), "swift")
        self.assertEqual([f.name for f in functions], ["g"])

    def test_decodable_init_is_an_entry(self):
        text = "struct S: Decodable {\n    init(from decoder: Decoder) throws {\n        x = try f()\n    }\n}\n"
        classifier = ratchet.TrapClassifier(".")
        model = ratchet.SourceModel("swift", text, classifier.entries["swift"], classifier.byte_reads["swift"])
        self.assertEqual(model.input_rule(3), "entry:init (decodable_init)")
        self.assertIsNone(model.input_rule(1))


def invariant(build, ident='"frame.size"', api="notFatalUntil"):
    args = f"ok, {ident}" + (f", build: {build}" if build is not None else "")
    return f"    Invariant.{api}({args})"


class NotFatalUntilTests(unittest.TestCase):
    def lowered(self, base, head, base_path="A.swift", head_path="A.swift"):
        return ratchet.lowered_not_fatal_until({base_path: base.split("\n")}, {head_path: head.split("\n")})

    def test_lowered_removed_and_dropped_builds_are_refused(self):
        self.assertEqual(self.lowered(invariant(120), invariant(110)),
                         [("A.swift", 1, 'Invariant.notFatalUntil "frame.size": build 120 -> 110 (lowered)')])
        self.assertIn("removed (now Invariant.check)", self.lowered(invariant(120), invariant(None, api="check"))[0][2])
        self.assertIn("without build:", self.lowered(invariant(120), invariant(None))[0][2])
        self.assertIn("not an integer literal", self.lowered(invariant(120), invariant("Build.next"))[0][2])

    def test_raised_new_gone_and_allowed_pass(self):
        self.assertEqual(self.lowered(invariant(120), invariant("1_300")), [])
        self.assertEqual(self.lowered("", invariant(5)), [])
        self.assertEqual(self.lowered(invariant(120), "let x = 1"), [])
        allowed = "    // not-fatal-until-lowered-allow: the fix shipped in 110\n" + invariant(110)
        self.assertEqual(self.lowered(invariant(120), allowed), [])

    def test_an_id_that_moves_files_keeps_its_build_and_a_multiline_call_reads(self):
        head = "Invariant.notFatalUntil(\n    count > 0,\n    id: .frameSize,\n    build: 90\n)"
        self.assertEqual(self.lowered(invariant(120, ".frameSize"), head, "A.swift", "B.swift"),
                         [("B.swift", 1, "Invariant.notFatalUntil .frameSize: build 120 -> 90 (lowered)")])

    def test_an_unchanged_check_beside_a_same_id_not_fatal_until_passes(self):
        base = '\n'.join([invariant(None, '"x"', "check"), invariant(100, '"x"'), "let y = 1"])
        head = '\n'.join([invariant(None, '"x"', "check"), invariant(100, '"x"'), "let y = 2"])
        self.assertEqual(self.lowered(base, head), [])

    def test_one_of_two_same_id_sites_lowered_is_refused(self):
        base = '\n'.join([invariant(100, '"x"'), "let y = 1", invariant(200, '"x"')])
        head = '\n'.join([invariant(100, '"x"'), "let y = 1", invariant(101, '"x"')])
        self.assertEqual(self.lowered(base, head), [("A.swift", 3, 'Invariant.notFatalUntil "x": build 200 -> 101 (lowered)')])

    def test_a_renamed_id_with_a_lower_build_is_refused(self):
        found = self.lowered(invariant(140), invariant(100, '"frame.size.v2"'))
        self.assertEqual(found, [("A.swift", 1, 'Invariant.notFatalUntil "frame.size.v2": build 140 -> 100 '
                                               '(renamed from "frame.size") (lowered)')])
        self.assertEqual(self.lowered(invariant(140), invariant(150, '"frame.size.v2"')), [])

    def test_a_lowered_constant_behind_an_unchanged_call_is_refused(self):
        # CrashGuard's shape: the call reads `build: fatalFromBuild`, and only the constant's line changes.
        def guard(value):
            return "\n".join(["enum CrashGuard {", f"    static let fatalFromBuild{value}",
                              "    static func fault() {",
                              '        _ = Invariant.notFatalUntil(false, invariantID, build: fatalFromBuild)',
                              "    }", "}"])
        found = self.lowered(guard(" = UInt64.max"), guard(": UInt64 = 1"))
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][:2], ("A.swift", 4))
        self.assertIn("build fatalFromBuild (18446744073709551615) -> fatalFromBuild (1) (lowered); set at A.swift:2",
                      found[0][2])
        self.assertEqual(self.lowered(guard(" = 1_000"), guard(" = UInt64.max")), [])
        allowed = guard(": UInt64 = 1 // not-fatal-until-lowered-allow: zero reports for a release cycle")
        self.assertEqual(self.lowered(guard(" = UInt64.max"), allowed), [])

    def test_the_guardrail_refuses_only_a_lowered_build(self):
        path = "Packages/Shared/CmuxSafeConcurrency/Sources/X/A.swift"
        rule = next(r for r in guardrails.RULES if r.id == "not-fatal-until-lowered")
        head = ["func f() {", invariant(100), "}"]
        change = guardrails.FileChange(path, head, [guardrails.Added(path, 2, head[1])],
                                       base_lines=["func f() {", invariant(140), "}"])
        hits = rule.find([change], guardrails.collections.Counter())
        self.assertEqual([(h.path, h.number) for h in hits], [(path, 2)])
        self.assertIn("build 140 -> 100 (lowered)", hits[0].text)
        raised = guardrails.FileChange(path, head, [guardrails.Added(path, 2, head[1])],
                                       base_lines=["func f() {", invariant(90), "}"])
        self.assertEqual(rule.find([raised], guardrails.collections.Counter()), [])
        # An edit next to an unchanged check that shares a notFatalUntil's id refuses nothing.
        shared = [invariant(None, '"x"', "check"), invariant(100, '"x"'), "let y = 2"]
        edit = guardrails.FileChange(path, shared, [guardrails.Added(path, 3, shared[2])],
                                     base_lines=shared[:2] + ["let y = 1"])
        self.assertEqual(rule.find([edit], guardrails.collections.Counter()), [])
        # CrashGuard's shape: lowering the constant behind an unchanged call is refused at the call.
        call = "    _ = Invariant.notFatalUntil(false, invariantID, build: fatalFromBuild)"
        lowered = ["    static let fatalFromBuild: UInt64 = 1", call]
        constant = guardrails.FileChange(path, lowered, [guardrails.Added(path, 1, lowered[0])],
                                         base_lines=["    static let fatalFromBuild = UInt64.max", call])
        hits = rule.find([constant], guardrails.collections.Counter())
        self.assertEqual([(h.path, h.number) for h in hits], [(path, 2)])
        self.assertIn("(lowered); set at " + path + ":1", hits[0].text)


if __name__ == "__main__":
    unittest.main()
