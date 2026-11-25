#!/usr/bin/env python3
"""ci-oops fault isolation (scripts/ci/oops/isolate.py, optional-units.json): a pull request build leaves out an
optional unit that alone fails to compile, reports it as a CI_OOPS soft fail, and keeps everything else strict.

    python3 tests/test_ci_oops_isolate.py
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci/oops"))
import isolate  # noqa: E402

PR = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request", "GITHUB_WORKFLOW": "CI web",
      "GITHUB_BASE_REF": "feat-cmux-next", "GITHUB_HEAD_REF": "lane/x", "GITHUB_WORKFLOW_REF":
      "manaflow-ai/cmux/.github/workflows/cmux-next-web.yml@refs/pull/1/merge"}

ESBUILD_OPTIONAL = """\
▲ [WARNING] Unused import [unused-import]

    src/pages/settings/main.tsx:3:7:
      3 │ import "./x";

✘ [ERROR] Could not resolve "./nope"

    src/pages/glass-parity/main.tsx:2:7:
      2 │ import "./nope";
        ╵        ~~~~~~~~

error: Build failed with 1 error
"""
ESBUILD_CORE = ESBUILD_OPTIONAL.replace("src/pages/glass-parity/main.tsx:2", "src/pages/settings/App.tsx:2")
CARGO_OPTIONAL = """\
error[E0308]: mismatched types
 --> crates/cmux-palette-eval/src/lib.rs:3:30
error: could not compile `cmux-palette-eval` (lib) due to 1 previous error
"""
CARGO_CORE = CARGO_OPTIONAL + "error: could not compile `acpmux` (lib test) due to 2 previous errors\n"


def load_fast_gate():
    spec = importlib.util.spec_from_file_location("fast_gate", ROOT / "scripts/ci/fast_gate_webviews_checks.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Allowlist(unittest.TestCase):
    def test_every_unit_is_well_formed(self) -> None:
        self.assertEqual(isolate.problems(isolate.load()), [])

    def test_every_page_unit_is_a_page_the_builder_bundles(self) -> None:
        script = (ROOT / "scripts/cmux-next/build-pages-web.sh").read_text()
        for unit in isolate.load():
            if unit["kind"] == "webview-page":
                self.assertRegex(script, rf"(?m)^{re.escape(unit['name'])}$|PAGES=\"\$PAGES .*\b{unit['name']}\b",
                                 f"{unit['id']} is not in build-pages-web.sh's PAGES")

    def test_every_cargo_unit_is_a_workspace_member_nothing_depends_on(self) -> None:
        manifest = ROOT / "cmux-tui/Cargo.toml"
        if not manifest.is_file():
            self.skipTest("sparse checkout without cmux-tui")
        text = manifest.read_text()
        for unit in isolate.load():
            if unit["kind"] != "cargo-member":
                continue
            self.assertIn(f'"crates/{unit["name"]}"', text)
            users = [p for p in (ROOT / "cmux-tui/crates").glob("*/Cargo.toml")
                     if p.parent.name != unit["name"] and re.search(rf"(?m)^{re.escape(unit['name'])}\s*=", p.read_text())]
            self.assertEqual(users, [], f"{unit['id']} is a dependency of {users}: it is core")

    def test_no_core_source_imports_an_optional_page(self) -> None:
        src = ROOT / "webviews/src"
        if not (src / "pages/settings").is_dir():
            self.skipTest("sparse checkout without webviews")
        for unit in isolate.load():
            if unit["kind"] != "webview-page":
                continue
            needle = re.compile(rf"""from\s+["'][./]*(?:pages/)?{re.escape(unit['name'])}/|import\s*\(\s*["'][./]*(?:pages/)?{re.escape(unit['name'])}/""")
            for path in src.rglob("*.ts*"):
                rel = path.relative_to(ROOT).as_posix()
                if isolate.unit_of_path(rel) is not None or ".test." in path.name:
                    continue
                if needle.search(path.read_text(errors="replace")):
                    self.fail(f"{rel} (core) imports {unit['id']}: it is not optional")


class Allowed(unittest.TestCase):
    def test_a_pull_request_build_may_drop(self) -> None:
        self.assertTrue(isolate.allowed(PR)[0])

    def test_ship_paths_and_other_events_stay_strict(self) -> None:
        for change in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_EVENT_NAME": "schedule"},
                       {"GITHUB_EVENT_NAME": "workflow_dispatch"}, {"GITHUB_WORKFLOW": "nightly-next train"},
                       {"GITHUB_WORKFLOW": "Release"}, {"GITHUB_BASE_REF": "release/1.2"},
                       {"GITHUB_WORKFLOW_REF": "x/.github/workflows/stable-next.yml@refs/heads/x"},
                       {"GITHUB_HEAD_REF": "promote-1"}, {"CMUX_OOPS_STRICT": "1"}, {"GITHUB_ACTIONS": ""}):
            self.assertFalse(isolate.allowed({**PR, **change})[0], change)


class Attribute(unittest.TestCase):
    def test_an_esbuild_error_in_an_optional_page_names_it(self) -> None:
        self.assertEqual(isolate.attribute("webview-page", ESBUILD_OPTIONAL), ({"glass-parity"}, []))

    def test_an_esbuild_error_in_a_core_page_is_core(self) -> None:
        names, core = isolate.attribute("webview-page", ESBUILD_CORE)
        self.assertTrue(core)

    def test_output_with_no_error_block_is_core(self) -> None:
        self.assertTrue(isolate.attribute("webview-page", "Killed\n")[1])

    def test_cargo_names_the_optional_member(self) -> None:
        self.assertEqual(isolate.attribute("cargo-member", CARGO_OPTIONAL), ({"cmux-palette-eval"}, []))
        self.assertTrue(isolate.attribute("cargo-member", CARGO_CORE)[1])
        self.assertTrue(isolate.attribute("cargo-member", "error: linker `cc` not found\n")[1])

    def test_a_gallery_file_inside_a_page_is_the_gallerys(self) -> None:
        self.assertEqual(isolate.unit_of_path("webviews/src/pages/stats/stats.gallery.tsx")["id"], "gallery")
        self.assertEqual(isolate.unit_of_path("webviews/src/ui/Switch.gallery.tsx")["id"], "gallery")
        self.assertEqual(isolate.unit_of_path("webviews/src/pages/stats/main.tsx")["id"], "webview-page:stats")
        self.assertIsNone(isolate.unit_of_path("webviews/src/pages/settings/main.tsx"))
        self.assertIsNone(isolate.unit_of_path("webviews/src/ui/Switch.tsx"))


class Without(unittest.TestCase):
    def test_pages_lose_their_argument(self) -> None:
        self.assertEqual(isolate.without("webview-page", ["bun", "b.mjs", "/w", "settings", "stats"], ["stats"]),
                         ["bun", "b.mjs", "/w", "settings"])

    def test_cargo_packages_lose_their_p_and_a_workspace_gets_an_exclude_before_dashdash(self) -> None:
        self.assertEqual(isolate.without("cargo-member", ["cargo", "clippy", "-p", "a", "-p", "cmux-palette-eval",
                                                          "--", "-D", "warnings"], ["cmux-palette-eval"]),
                         ["cargo", "clippy", "-p", "a", "--", "-D", "warnings"])
        self.assertIsNone(isolate.without("cargo-member", ["cargo", "clippy", "-p", "cmux-palette-eval"],
                                          ["cmux-palette-eval"]))
        self.assertEqual(isolate.without("cargo-member", ["cargo", "clippy", "--workspace", "--", "-D", "warnings"],
                                         ["cmux-palette-eval"]),
                         ["cargo", "clippy", "--workspace", "--exclude", "cmux-palette-eval", "--", "-D", "warnings"])


class IsolatedRun(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.env = {**PR, "GITHUB_STEP_SUMMARY": str(self.tmp / "summary"), "GITHUB_ENV": str(self.tmp / "env")}

    def fake(self, outcomes):
        calls = []

        def runner(argv):
            calls.append(argv)
            return outcomes[len(calls) - 1]
        return runner, calls

    def test_an_optional_red_is_dropped_reported_and_the_rest_runs(self) -> None:
        runner, calls = self.fake([(1, ESBUILD_OPTIONAL), (0, "")])
        argv = ["bun", "b.mjs", "/w", "settings", "glass-parity"]
        code, dropped = isolate.isolated_run("webview-page", argv, env=self.env, runner=runner)
        self.assertEqual((code, dropped), (0, ["glass-parity"]))
        self.assertEqual(calls[1], ["bun", "b.mjs", "/w", "settings"])
        self.assertIn("CMUX_OOPS_DROPPED_WEBVIEW_PAGE=glass-parity", (self.tmp / "env").read_text())
        self.assertIn("webview-page:glass-parity", (self.tmp / "summary").read_text())

    def test_the_ci_oops_line_is_the_contracts_shape(self) -> None:
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            isolate.report("cargo-member", {"cmux-palette-eval": "error: could not compile"}, env=self.env)
        line = next(l for l in out.getvalue().splitlines() if l.startswith("CI_OOPS="))
        verdict = json.loads(line[len("CI_OOPS="):])
        self.assertEqual((verdict["class"], verdict["outcome"], verdict["unit"], verdict["swallow"]),
                         ("soft", "soft_failed", "cargo-member:cmux-palette-eval", True))

    def test_a_core_red_is_never_dropped(self) -> None:
        runner, calls = self.fake([(1, ESBUILD_CORE)])
        self.assertEqual(isolate.isolated_run("webview-page", ["bun", "x"], env=self.env, runner=runner), (1, []))
        self.assertEqual(len(calls), 1)

    def test_a_strict_run_never_drops(self) -> None:
        runner, calls = self.fake([(1, ESBUILD_OPTIONAL)])
        env = {**self.env, "GITHUB_EVENT_NAME": "push"}
        self.assertEqual(isolate.isolated_run("webview-page", ["bun", "glass-parity"], env=env, runner=runner), (1, []))
        self.assertEqual(len(calls), 1)

    def test_a_rerun_that_stays_red_stays_red_and_reports_nothing(self) -> None:
        runner, _ = self.fake([(1, ESBUILD_OPTIONAL), (1, ESBUILD_CORE)])
        self.assertEqual(isolate.isolated_run("webview-page", ["bun", "glass-parity"], env=self.env, runner=runner),
                         (1, []))
        self.assertFalse((self.tmp / "env").exists())

    def test_env_drops_are_honoured_only_for_optional_units_on_a_pull_request(self) -> None:
        env = {**self.env, "CMUX_OOPS_DROPPED_CARGO_MEMBER": "cmux-palette-eval"}
        self.assertEqual(isolate.dropped_from_env("cargo-member", env), ["cmux-palette-eval"])
        self.assertEqual(isolate.dropped_from_env("cargo-member", {**env, "CMUX_OOPS_DROPPED_CARGO_MEMBER": "acpmux"}), [])
        self.assertEqual(isolate.dropped_from_env("cargo-member", {**env, "GITHUB_EVENT_NAME": "push"}), [])


class TypeCheck(unittest.TestCase):
    def test_type_errors_only_in_optional_units_are_soft_on_a_pull_request(self) -> None:
        gate = load_fast_gate()
        new = ["src/ui/Switch.gallery.tsx: typescript(TS2322): Type 'string' is not assignable to type 'number'.",
               "src/pages/glass-parity/main.tsx: typescript(TS2307): Cannot find module './nope'."]
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sorted(gate.optional_only(new, PR)), ["gallery", "webview-page:glass-parity"])
            self.assertEqual(gate.optional_only(new + ["src/ui/Switch.tsx: typescript(TS2322): x"], PR), [])
            self.assertEqual(gate.optional_only(["typescript(TS2322): no path"], PR), [])
            self.assertEqual(gate.optional_only(new, {**PR, "GITHUB_EVENT_NAME": "push"}), [])


if __name__ == "__main__":
    unittest.main()
