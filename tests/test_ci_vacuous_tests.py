#!/usr/bin/env python3
"""scripts/ci/vacuous_tests.py: tests that can't fail, per language and kind, with near misses."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from vacuous_tests import main, scan, strip_source  # noqa: E402

RUST = r'''
fn check_roundtrip(x: u8) { assert_eq!(x, x); }
fn run_case(x: u8) -> u8 { helper_assert(x); x }
fn helper_assert(x: u8) { assert!(x > 0); }

#[test]
fn empty_body() {}

#[test]
fn smoke_only() {
    let s = parse("a { b }");
    drop(s);
}

#[test]
fn asserts_eq() {
    assert_eq!(parse("x"), 1);
}

#[test]
fn unwraps() {
    parse_result("x").unwrap();
}

#[test]
fn question_mark() -> anyhow::Result<()> {
    parse_result("x")?;
    Ok(())
}

#[test]
fn question_mark_without_result() {
    let _ = maybe()?;
}

#[test]
fn calls_named_helper() {
    check_roundtrip(3);
}

#[test]
fn calls_transitive_helper() {
    run_case(3);
}

#[tokio::test]
async fn tokio_asserts() {
    assert!(go().await);
}

#[test]
#[ignore]
fn ignored_no_reason() {
    assert!(true);
}

#[test]
#[ignore = "needs the network"]
fn ignored_with_reason() {
    assert!(true);
}

#[test]
#[should_panic]
fn should_panic_counts() {
    parse("");
}

#[test]
fn byte_raw_string_with_braces() {
    let line = br#"{"a":{"text":"no"}"#;
    assert_eq!(find(line).unwrap(), 1);
}

#[test]
fn string_with_assert_is_not_an_assertion() {
    let s = "assert!(x) // not code";
    let c = '{';
    log(s, c);
}

#[test]
fn mock_times_only() {
    let mut m = MockStore::new();
    m.expect_save().times(1).return_const(());
}
'''

SWIFT = r'''
import XCTest
import Testing

final class FooTests: XCTestCase {
    func testEmpty() {}
    func testAsserts() { XCTAssertEqual(f(), 1) }
    func testThrowsTry() throws { try f() }
    func testSkipped() throws {
        throw XCTSkip("not yet")
    }
    func testSkipConditional() throws {
        if isCI { throw XCTSkip("ci") }
        XCTAssertTrue(true)
    }
    func testHelper() { verifyLayout(view) }
    func testSmoke() { let v = View(); v.layout() }
    func testInterpolation() { let s = "\(a("}")) x"; XCTAssertEqual(s, "") }
    func testMockCount() { sut.run(); XCTAssertEqual(spy.callCount, 1) }
    func helper(x: Int) {}
}

@Test func testingExpect() { #expect(f() == 1) }
@Test(.disabled) func testingDisabled() { #expect(true) }
@Test("named", .disabled("flaky on CI")) func testingDisabledReason() { #expect(true) }
@Test(.disabled(if: isCI)) func testingDisabledIf() { #expect(true) }
@Test func testingEmpty() {}
@Test(arguments: [Outcome.ok, .disabled]) func disabledIsAnArgument(_ o: Outcome) { #expect(o != nil) }
@Test func rawQuoteStrings() {
    for model in [#""""#, #""-p""#] { #expect(breaks(model)) }
}
@Test func cacheCountsItsOwnCalls() { _ = cache.text(); #expect(counting.calls == 1) }
@Test func usesInvocation() { #expect(Self.invocation(["x": 1]).name == "x") }

final class MoreTests: XCTestCase {
    private static func testBundle() -> URL? { return nil }
    func testReturnsHelper() -> Int { 1 }
}
'''

TS = r'''
import { expect, test, it } from "bun:test";

function assertShape(x) { expect(x).toBeTruthy(); }
const runIt = (x) => { assertShape(x); };
async function renderThen(read: () => Promise<unknown>, named = "x") { expect(await read()).toBe(named); }
test("arrow-typed helper", async () => { await renderThen(async () => "x"); });
test("host calls are output", () => { store.start(); expect(host.calls.length).toBe(1); });

test("asserts", () => { expect(add(1, 2)).toBe(3); });
test("empty", () => {});
it("smoke", async () => { await render(<App />); });
it("regex brace", () => { const r = /\{/; expect(r.test("{")).toBe(true); });
test.skip("skipped", () => { expect(1).toBe(1); });
xit("x skipped", () => { expect(1).toBe(1); });
test("helper", () => { runIt(3); });
test("query throws", () => { screen.getByText("hi"); });
test("mock only", () => { const fn = vi.fn(); run(fn); expect(fn).toHaveBeenCalledTimes(1); });
test.todo("later");
try { await launch(); } catch {
  describe.skip("browser lane", () => test("placeholder", () => {}));
}
describe.skip("top skip", () => { test("inside top skip", () => { expect(1).toBe(1); }); });
test("template ${x} literal", () => {
  test.skip(isCI, "conditional skip inside a body");
  expect(`a ${b} {`).toBe("a");
});
'''

PY = r'''
import unittest
from unittest import mock


def check_output_ok(x):
    assert x


def test_files(root=None):
    return sorted([])


class T(unittest.TestCase):
    def test_asserts(self):
        self.assertEqual(1, 1)

    def test_empty(self):
        pass

    def test_smoke(self):
        run_thing()

    def test_helper(self):
        check_output_ok(run_thing())

    def test_raise(self):
        if run_thing():
            raise AssertionError("bad")

    def test_calls_another_test(self):
        self.test_asserts()

    def test_require_helper(self):
        require_branch("o/r")

    def test_check_true(self):
        subprocess.run(["x"], check=True)

    @unittest.skip("later")
    def test_skipped(self):
        self.assertTrue(True)

    @unittest.skipIf(True, "cond")
    def test_skip_if(self):
        self.assertTrue(True)

    def test_skiptest_top(self):
        self.skipTest("nope")

    def test_skiptest_cond(self):
        if not HAS_X:
            self.skipTest("nope")
        self.assertTrue(True)

    def test_mock_only(self):
        m = mock.Mock()
        run_thing(m)
        m.save.assert_called_once_with(1)


@unittest.skip("whole class")
class Skipped(unittest.TestCase):
    def test_inside(self):
        self.assertTrue(True)
'''


class VacuousTestsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        files = {
            "cmux-tui/src/lib.rs": RUST,
            "Packages/Foo/Tests/FooTests.swift": SWIFT,
            "webviews/src/a.test.tsx": TS,
            "tests/test_fixture.py": PY,
            "webviews/src/not_a_test.ts": 'test("x", () => {});',
            # A helper used from a sibling file: `isolated` is defined in more files than the
            # global limit, but the one in this folder asserts.
            "cmux-tui/stress/mod.rs": "pub fn isolated(n: &str) { assert!(run(n)); }\n",
            "cmux-tui/stress/store.rs": "#[test]\nfn runs_alone() { isolated(\"x\"); }\n",
            **{f"cmux-tui/other{k}/lib.rs": "fn isolated() { go(); }\n" for k in range(7)},
        }
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(textwrap.dedent(text))
        cls.root = root
        cls.report = scan(root, ["cmux-tui", "Packages", "webviews", "tests"])
        cls.by = {(f["language"], f["name"]): f for f in cls.report["findings"]}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def flagged(self, lang, name, kind, confidence=None):
        f = self.by.get((lang, name))
        self.assertIsNotNone(f, f"{lang} {name} not flagged")
        self.assertEqual(f["kind"], kind, f)
        if confidence:
            self.assertEqual(f["confidence"], confidence, f)

    def clean(self, lang, *names):
        for name in names:
            self.assertNotIn((lang, name), self.by, f"{lang} {name} falsely flagged: {self.by.get((lang, name))}")

    def test_rust(self):
        self.flagged("rust", "empty_body", "no_assertion", "high")
        self.flagged("rust", "smoke_only", "no_assertion", "medium")
        self.flagged("rust", "string_with_assert_is_not_an_assertion", "no_assertion")
        self.flagged("rust", "question_mark_without_result", "no_assertion")
        self.flagged("rust", "ignored_no_reason", "skipped", "high")
        self.flagged("rust", "mock_times_only", "mocks_only", "low")
        self.clean("rust", "asserts_eq", "unwraps", "question_mark", "calls_named_helper",
                   "calls_transitive_helper", "tokio_asserts", "ignored_with_reason",
                   "should_panic_counts", "byte_raw_string_with_braces", "runs_alone")
        self.assertEqual(self.by[("rust", "empty_body")]["path"], "cmux-tui/src/lib.rs")

    def test_swift(self):
        self.flagged("swift", "testEmpty", "no_assertion", "high")
        self.flagged("swift", "testingEmpty", "no_assertion", "high")
        self.flagged("swift", "testSmoke", "no_assertion", "medium")
        self.flagged("swift", "testSkipped", "skipped", "high")
        self.flagged("swift", "testingDisabled", "skipped", "high")
        self.flagged("swift", "testingDisabledReason", "skipped", "medium")
        self.flagged("swift", "testMockCount", "mocks_only", "low")
        self.clean("swift", "testAsserts", "testThrowsTry", "testSkipConditional", "testHelper",
                   "testInterpolation", "testingExpect", "testingDisabledIf", "helper",
                   "disabledIsAnArgument", "usesInvocation", "rawQuoteStrings", "cacheCountsItsOwnCalls", "testBundle", "testReturnsHelper")

    def test_ts(self):
        self.flagged("ts", "empty", "no_assertion", "high")
        self.flagged("ts", "smoke", "no_assertion", "medium")
        self.flagged("ts", "skipped", "skipped", "high")
        self.flagged("ts", "x skipped", "skipped", "high")
        self.flagged("ts", "mock only", "mocks_only", "low")
        self.flagged("ts", "inside top skip", "skipped", "high")
        self.clean("ts", "placeholder", "arrow-typed helper", "host calls are output", "asserts", "regex brace", "helper", "query throws", "later",
                   "template ${x} literal", "conditional skip inside a body")
        self.assertFalse(any(f["path"].endswith("not_a_test.ts") for f in self.report["findings"]))

    def test_python(self):
        self.flagged("python", "test_empty", "no_assertion", "high")
        self.flagged("python", "test_smoke", "no_assertion", "medium")
        self.flagged("python", "test_skipped", "skipped", "high")
        self.flagged("python", "test_skiptest_top", "skipped", "high")
        self.flagged("python", "test_inside", "skipped", "high")
        self.flagged("python", "test_mock_only", "mocks_only", "low")
        self.clean("python", "test_asserts", "test_helper", "test_raise", "test_check_true",
                   "test_skip_if", "test_skiptest_cond", "test_files",
                   "test_calls_another_test", "test_require_helper")

    def test_summary_counts_match_findings(self):
        s = self.report["summary"]
        self.assertEqual(s["total"], len(self.report["findings"]))
        self.assertEqual(sum(s["by_kind"].values()), s["total"])
        self.assertEqual(sum(sum(k.values()) for k in s["by_language"].values()), s["total"])
        self.assertEqual(s["by_language"]["rust"]["skipped"], 1)
        for f in self.report["findings"]:
            self.assertEqual(set(f), {"path", "line", "name", "language", "kind", "confidence", "why"})

    def test_line_numbers_point_at_the_test(self):
        f = self.by[("rust", "empty_body")]
        line = (self.root / f["path"]).read_text().splitlines()[f["line"] - 1]
        self.assertIn("fn empty_body", line)
        f = self.by[("ts", "empty")]
        line = (self.root / f["path"]).read_text().splitlines()[f["line"] - 1]
        self.assertIn('test("empty"', line)

    def test_strip_keeps_offsets(self):
        src = 'let a = "x // y"; // assert!(z)\nlet b = r#"{"#;'
        out = strip_source(src, "rust")
        self.assertEqual(len(out), len(src))
        self.assertNotIn("assert", out)
        self.assertNotIn("{", out)
        self.assertEqual(out.count("\n"), 1)

    def test_diff_reports_only_changed_files(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            git = lambda *a: subprocess.run(["git", "-C", d, *a], check=True, capture_output=True)  # noqa: E731
            git("init", "-q", "-b", "main")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "t")
            (repo / "tests").mkdir()
            (repo / "tests" / "test_old.py").write_text("def test_old():\n    pass\n")
            git("add", ".")
            git("commit", "-qm", "base")
            (repo / "tests" / "test_new.py").write_text("def test_new():\n    pass\n")
            git("add", ".")
            git("commit", "-qm", "head")
            out = Path(d) / "report.json"
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                rc = main(["--repo", d, "--root", "tests", "--diff", "HEAD~1", "--output", str(out),
                           "--strict"])
            report = json.loads(out.read_text())
            self.assertEqual(rc, 1)
            self.assertEqual([f["name"] for f in report["findings"]], ["test_new"])
            self.assertEqual(report["diff"]["files"], 1)


if __name__ == "__main__":
    unittest.main()
