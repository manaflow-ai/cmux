#!/usr/bin/env python3
"""check-release-switch-paths.py: a feature a Release build offers (Labs, a kill switch, on in Release) must reach
code a Release build compiles, followed from its switch read through what the read sets; and prepush-gate.py's
local tier runs it on a push's own commits.

The fixtures are small Swift trees in the shapes the app uses: a feature read in Release that sets a property, the
property passed on as an argument label, and the deciding use under `#if DEBUG || CMUX_BENCH_HOOKS` (the
chromiumHostInputRing shape), next to the same tree with the use compiled in every configuration.

Not a CI job (Lawrence 2026-10-23: no new CI tests): run it yourself after changing the check:
  python3 -I scripts/cmux-next/tests/test_check_release_switch_paths.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
SOURCES = "Packages/macOS/CmuxNext/Sources"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


check = load("check_release_switch_paths_under_test", "check-release-switch-paths.py")


def feature(name: str, kind: str = "labs", release: bool = False, process: str = "app", **extra) -> str:
    return json.dumps({"name": name, "owner": "PL-test", "description": "d", "kind": kind, "process": process,
                       "defaults": {"dev": True, "nightly": True, "release": release}, "params": [], "stories": [],
                       "sticky": False, "runtimeMutable": False, **extra})


# The App reads the switch in Release and stores it on the runtime source.
APP = """\
final class AppServices {
    func makeSlot() {
        chromiumRuntime.source.routesHostInput = features.isEnabled(.chromiumHostInputRing)
        // features.isEnabled(.chromiumHostInputRing) in a comment is no read
        engine.start(hostInput: chromiumRuntime.source.routesHostInput)
    }
}
"""
SOURCE = """\
public final class CEFRuntimeSource {
    public var routesHostInput = false
}
"""
ENGINE = """\
final class CEFRuntime {
    func start(hostInput: Bool) {
        hostStart = CEFHostStart(routesInput: hostInput)
    }
}
"""


def host_start(guard: str | None) -> str:
    """CEFHostStart, its one deciding use of routesInput under GUARD (None: compiled in every configuration)."""
    body = """\
    func startInputRoute() {
        guard routesInput, inputRoute == nil else { return }
        inputRoute = ChromiumHostInputRoute()
    }
"""
    if guard is not None:
        body = f"    #if {guard}\n{body}    #endif\n"
    return f"""\
final class CEFHostStart {{
    let routesInput: Bool
    init(routesInput: Bool) {{
        self.routesInput = routesInput
    }}
{body}}}
"""


class Fixture:
    """A tree on disk: features.d files and Swift sources."""

    def __init__(self, test: unittest.TestCase):
        self.root = Path(tempfile.mkdtemp(prefix="release-switch-paths-"))
        test.addCleanup(shutil.rmtree, self.root, True)

    def feature(self, name: str, text: str) -> None:
        self.write(f"schemas/features/features.d/{name}.json", text)

    def swift(self, path: str, text: str) -> None:
        self.write(f"{SOURCES}/{path}", text)

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def verdicts(self) -> dict[str, object]:
        return {v.feature.name: v for v in check.Checker(check.DirTree(self.root)).run()}

    def main(self, *argv: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = check.main(["--root", str(self.root), *argv])
        return code, out.getvalue()


def input_ring_tree(test: unittest.TestCase, guard: str | None) -> Fixture:
    tree = Fixture(test)
    tree.feature("chromiumHostInputRing", feature("chromiumHostInputRing"))
    tree.swift("CmuxNextApp/AppServices+Chromium.swift", APP)
    tree.swift("CmuxNextBrowser/CEF/CEFRuntimeSource.swift", SOURCE)
    tree.swift("CmuxNextBrowser/CEF/CEFRuntime.swift", ENGINE)
    tree.swift("CmuxNextBrowser/CEF/CEFHostStart.swift", host_start(guard))
    return tree


class InputRingShapeTests(unittest.TestCase):
    """The chromiumHostInputRing shape: a Labs switch read in Release whose path is compiled only for DEBUG/bench."""

    def test_a_path_only_under_debug_or_bench_hooks_is_refused(self):
        for guard in ("DEBUG || CMUX_BENCH_HOOKS", "DEBUG", "CMUX_BENCH_HOOKS", "(DEBUG || CMUX_BENCH_HOOKS) && os(macOS)"):
            with self.subTest(guard=guard):
                tree = input_ring_tree(self, guard)
                verdict = tree.verdicts()["chromiumHostInputRing"]
                self.assertEqual(verdict.status, "offender")
                self.assertIn("CEFHostStart.swift:8", verdict.detail, "names the use Release does not compile")
                code, out = tree.main()
                self.assertEqual(code, 1)
                self.assertIn(check.HEADER, out)
                self.assertIn("chromiumHostInputRing (kind labs)", out)

    def test_the_same_path_compiled_in_every_configuration_passes(self):
        tree = input_ring_tree(self, None)
        verdict = tree.verdicts()["chromiumHostInputRing"]
        self.assertEqual(verdict.status, "ok", verdict.detail)
        self.assertIn("routesInput decides at", verdict.detail)
        self.assertEqual(tree.main(), (0, ""))

    def test_a_path_under_a_condition_release_may_set_passes(self):
        for guard in ("os(macOS)", "canImport(AppKit)", "DEBUG || GHOSTTY_TRACE_HOOK", "!DEBUG"):
            with self.subTest(guard=guard):
                self.assertEqual(input_ring_tree(self, guard).verdicts()["chromiumHostInputRing"].status, "ok")

    def test_the_else_of_a_debug_branch_is_release_code(self):
        tree = input_ring_tree(self, None)
        tree.swift("CmuxNextBrowser/CEF/CEFHostStart.swift", host_start(None).replace(
            "        guard routesInput, inputRoute == nil else { return }\n",
            "        #if DEBUG\n        recordDebugOnly()\n        #else\n"
            "        guard routesInput, inputRoute == nil else { return }\n        #endif\n"))
        self.assertEqual(tree.verdicts()["chromiumHostInputRing"].status, "ok")

    def test_uses_in_comments_and_strings_are_not_release_code(self):
        tree = input_ring_tree(self, "DEBUG || CMUX_BENCH_HOOKS")
        tree.swift("CmuxNextBrowser/CEF/Notes.swift", 'let note = "if routesInput { start }"\n'
                                                     "// guard routesInput else { return }\n"
                                                     "/* if routesInput { } */\n")
        self.assertEqual(tree.verdicts()["chromiumHostInputRing"].status, "offender")


class ReadSiteTests(unittest.TestCase):
    """Where the switch is read."""

    def tree(self, app: str, **feature_fields) -> Fixture:
        tree = Fixture(self)
        tree.feature("labsThing", feature("labsThing", **feature_fields))
        tree.swift("CmuxNextApp/App.swift", app)
        return tree

    def test_a_read_only_under_debug_is_refused(self):
        tree = self.tree("func f() {\n    #if DEBUG\n    if features.isEnabled(.labsThing) { go() }\n    #endif\n}\n")
        verdict = tree.verdicts()["labsThing"]
        self.assertEqual(verdict.status, "offender")
        self.assertIn("every switch read is under a #if", verdict.detail)

    def test_a_read_that_decides_in_release_passes(self):
        for app in ("func f() {\n    if features.isEnabled(.labsThing) { go() }\n}\n",
                    "func f() {\n    guard services.features.isEnabled(.labsThing) else { return }\n}\n",
                    "func f() -> Bool {\n    return features.resolution(of: .labsThing).isEnabled\n}\n",
                    "func f() {\n    let ok = a && features.isEnabled(Feature.labsThing)\n    if ok { go() }\n}\n"):
            with self.subTest(app=app):
                self.assertEqual(self.tree(app).verdicts()["labsThing"].status, "ok")

    def test_a_feature_with_no_read_is_refused(self):
        verdict = self.tree("func f() {}\n").verdicts()["labsThing"]
        self.assertEqual(verdict.status, "offender")
        self.assertIn("no switch read", verdict.detail)

    def test_a_use_the_walk_cannot_follow_is_not_judged_never_refused(self):
        """Review of 488ebd9f349: shapes with a working Release use that the text walk does not model must not refuse a
        push (no --no-verify way past it): a memberwise init read in another file, `.init(...)` shorthand, a `didSet`
        that does the work."""
        shapes = {
            "memberwise": ("struct Config { let enabled: Bool }\nfunc f() {\n    let c = Config(enabled: features.isEnabled(.labsThing))\n    use(c)\n}\n",
                           "func use(_ c: Config) {\n    if c.enabled { go() }\n}\n"),
            "shorthand": ("func f() {\n    store.mode = .init(on: features.isEnabled(.labsThing))\n}\n", ""),
            "didSet": ("final class Store {\n    var labsOn = false { didSet { apply() } }\n}\nfunc f() {\n    store.labsOn = features.isEnabled(.labsThing)\n}\n", ""),
        }
        for name, (app, other) in shapes.items():
            with self.subTest(shape=name):
                tree = self.tree(app)
                if other:
                    tree.swift("CmuxNextApp/Other.swift", other)
                verdict = tree.verdicts()["labsThing"]
                self.assertNotEqual(verdict.status, "offender", f"{name}: {verdict.detail}")
                code, _ = tree.main()
                self.assertEqual(code, 0, f"{name} refused a push")

    def test_a_broken_feature_file_gives_no_verdict_not_a_refusal(self):
        tree = self.tree("func f() {\n    if features.isEnabled(.labsThing) { go() }\n}\n")
        tree.feature("broken", '{"name": 5, "kind": "labs", "process": "app", "defaults": {"release": true}}')
        code, out = tree.main()
        self.assertEqual(code, 2, out)
        self.assertNotIn(check.HEADER, out)

    def test_a_local_is_followed_in_its_own_file_only(self):
        app = ("func f() {\n    let on = features.isEnabled(.labsThing) ? work : nil\n"
               "    #if DEBUG || CMUX_BENCH_HOOKS\n    if let on { on.go() }\n    #endif\n}\n")
        tree = self.tree(app)
        # Another file's `on` decides in Release, but it is not this local.
        tree.swift("CmuxNextApp/Other.swift", "func g(on: Bool) {\n    if on { go() }\n}\n")
        self.assertEqual(tree.verdicts()["labsThing"].status, "offender")
        tree.swift("CmuxNextApp/App.swift", app.replace("    #if DEBUG || CMUX_BENCH_HOOKS\n", "").replace(
            "    #endif\n", ""))
        self.assertEqual(tree.verdicts()["labsThing"].status, "ok")


class WhichFeaturesTests(unittest.TestCase):
    """Only features a Release build offers are judged."""

    DEBUG_ONLY_READ = "func f() {{\n    #if DEBUG\n    if features.isEnabled(.{name}) {{ go() }}\n    #endif\n}}\n"

    def judged(self, **fields) -> dict[str, object]:
        tree = Fixture(self)
        tree.feature("thing", feature("thing", **fields))
        tree.swift("CmuxNextApp/App.swift", self.DEBUG_ONLY_READ.format(name="thing"))
        return tree.verdicts()

    def test_labs_kill_switch_and_on_in_release_are_judged(self):
        for fields in ({"kind": "labs"}, {"kind": "killSwitch"}, {"kind": "perfPath", "release": True}):
            with self.subTest(fields=fields):
                self.assertEqual(self.judged(**fields)["thing"].status, "offender")

    def test_a_perf_path_off_in_release_bench_only_and_other_processes_are_not(self):
        for fields in ({"kind": "perfPath", "release": False}, {"kind": "labs", "benchOnly": True},
                       {"kind": "labs", "process": "daemon"}, {"kind": "labs", "process": "chromium"}):
            with self.subTest(fields=fields):
                self.assertEqual(self.judged(**fields), {})

    def test_a_both_feature_the_app_never_reads_is_not_judged(self):
        tree = Fixture(self)
        tree.feature("thing", feature("thing", kind="perfPath", release=True, process="both"))
        tree.swift("CmuxNextApp/App.swift", "func f() {}\n")
        self.assertEqual(tree.verdicts()["thing"].status, "not judged")


class ConditionTests(unittest.TestCase):
    def test_evaluate(self):
        cases = {"DEBUG": False, "CMUX_BENCH_HOOKS": False, "DEBUG || CMUX_BENCH_HOOKS": False,
                 "DEBUG || CMUX_BLOCKING_CHECKS || CMUX_BENCH_HOOKS": False, "!DEBUG": True,
                 "os(macOS)": None, "DEBUG || os(macOS)": None, "DEBUG && os(macOS)": False,
                 "(DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES": False, "canImport(UIKit) && DEBUG": False}
        for condition, expected in cases.items():
            with self.subTest(condition=condition):
                self.assertIs(check.evaluate(condition), expected)

    def test_release_lines_follow_elseif_and_else(self):
        text = "a\n#if DEBUG\nb\n#elseif os(macOS)\nc\n#else\nd\n#endif\ne\n"
        live = check.release_lines(check.mask(text))
        self.assertEqual([live[i] for i in (0, 2, 4, 6, 8)], [True, False, True, True, True])


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                           "-c", "commit.gpgsign=false", *args], check=True, capture_output=True,
                          text=True).stdout.strip()


class RepositoryFixture(unittest.TestCase):
    """A git repository: GOOD has the input-ring tree with its Release path, BAD (its child) has the path only
    under `#if DEBUG || CMUX_BENCH_HOOKS`."""

    def setUp(self):
        self.tree = input_ring_tree(self, None)
        self.repo = self.tree.root
        git(self.repo, "init", "--quiet")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "release path")
        self.good = git(self.repo, "rev-parse", "HEAD")
        self.tree.swift("CmuxNextBrowser/CEF/CEFHostStart.swift", host_start("DEBUG || CMUX_BENCH_HOOKS"))
        git(self.repo, "commit", "--quiet", "-am", "path only in debug and bench builds")
        self.bad = git(self.repo, "rev-parse", "HEAD")


class RevisionTests(RepositoryFixture):
    """--rev/--base: a revision's tree, and only offenders the base does not have."""

    def run_main(self, *argv: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = check.main(["--repo", str(self.repo), *argv])
        return code, out.getvalue()

    def test_a_revision_that_loses_the_release_path_is_refused_over_its_base(self):
        code, out = self.run_main("--rev", self.bad, "--base", self.good)
        self.assertEqual(code, 1)
        self.assertIn("chromiumHostInputRing", out)

    def test_an_offender_the_base_already_has_passes(self):
        self.assertEqual(self.run_main("--rev", self.bad, "--base", self.bad), (0, ""))

    def test_the_fixed_revision_passes(self):
        self.assertEqual(self.run_main("--rev", self.good), (0, ""))


class FakeRange:
    def __init__(self, base: str, head: str):
        self.base, self.head, self.before = base, head, []


class PrepushRuleTests(RepositoryFixture):
    """prepush-gate.py's local-tier rule runs the check on each pushed head over its base."""

    def setUp(self):
        super().setUp()
        self.gate = load("cmux_next_prepush_gate_release_paths", "prepush-gate.py")
        # The rule runs the script from the checks folder it is given: this checkout's.
        self.scripts = SCRIPTS

    def refuses(self, base: str, head: str) -> tuple[bool, str]:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            refused = self.gate.release_switch_paths(self.repo, [FakeRange(base, head)], self.scripts)
        return refused, err.getvalue()

    def test_the_rule_is_in_the_local_tier(self):
        self.assertIn("Release-offered features have a Release code path", [r.name for r in self.gate.LOCAL_TIER])

    def test_a_push_that_loses_the_release_path_is_refused(self):
        refused, err = self.refuses(self.good, self.bad)
        self.assertTrue(refused, err)
        self.assertIn("chromiumHostInputRing", err)

    def test_a_push_that_keeps_the_release_path_passes(self):
        self.tree.swift("CmuxNextBrowser/CEF/CEFHostStart.swift", host_start(None))
        git(self.repo, "commit", "--quiet", "-am", "fix")
        fixed = git(self.repo, "rev-parse", "HEAD")
        self.assertEqual(self.refuses(self.bad, fixed)[0], False)

    def test_a_push_that_touches_no_source_or_feature_is_not_checked(self):
        (self.repo / "README.md").write_text("x\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "docs")
        docs = git(self.repo, "rev-parse", "HEAD")
        # The head still has the offender, but the push's own commit changes neither input.
        self.assertEqual(self.refuses(self.bad, docs)[0], False)


if __name__ == "__main__":
    unittest.main()
