#!/usr/bin/env python3
"""The compile preflight (.github/workflows/cmux-next-compile-preflight.yml, scripts/ci/compile_preflight.py).

Leo, 2026-11-27: "surely we can just have legit build fail preflight checks" / "like the classes of failures before
we can analyze them".

cmux#57269 (a second `layoutGeometry` import in VirtualTranscript.tsx) and cmux#46930 (SetupCard importing
SignInButton from a path that does not exist) landed with every web build skipped by the land tier, and turned
feat-cmux-next's web bundle build and NIGHTLY red. This test keeps the gate that catches them:
  - both changes reach a web bundle, so the preflight builds them; a change that reaches none builds nothing;
  - the build's bundler errors (the exact lines NIGHTLY run 45907763450 printed) become annotations;
  - the gate has no tier rule: pr-router.yml calls it on every head its route job runs for, with no `start` gate
    and no label or tier condition; the callee's job has one job-level `if:`, `inputs.web != 'false' || inputs.force_web`, and the route
    sets web false only when every changed file is one pr_router.json's paths-ignore names (Rust, Swift, Python,
    workflows, docs) and none is a web bundle input (never-web-check keeps that list sound), so a head that can
    reach a bundle always builds. Leo, 2026-11-21: "whatever we need to cut, we cut. whatever we can reuse, we reuse.";
  - the build step runs build-web-bundles.sh, the build NIGHTLY runs.
The build itself (a merged tree with each break, red) is proven on a runner: the PR that added this test.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import unittest
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/compile_preflight.py"
CALLEE = ROOT / ".github/workflows/cmux-next-compile-preflight.yml"
ROUTER = ROOT / ".github/workflows/pr-router.yml"
MANIFEST = ROOT / "scripts/ci/pr_router.json"

spec = importlib.util.spec_from_file_location("compile_preflight", SCRIPT)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)
router_spec = importlib.util.spec_from_file_location("pr_router", ROOT / "scripts/ci/pr_router.py")
router = importlib.util.module_from_spec(router_spec)
router_spec.loader.exec_module(router)

# NIGHTLY run 45907763450 (feat-cmux-next 0b7f5de6, after cmux#57269), the web bundle build's own lines.
NIGHTLY_57269 = """\
✘ [ERROR] /Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/src/agent-session/acpmux/VirtualTranscript.tsx: Identifier 'layoutGeometry' has already been declared. (51:2)
  This error came from the "onLoad" callback registered here:
error: Build failed with 1 error:
src/agent-session/acpmux/App.tsx:408:53: ERROR: [plugin: react-compiler] /Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/src/agent-session/acpmux/VirtualTranscript.tsx: Identifier 'layoutGeometry' has already been declared. (51:2)
      at failureErrorWithLog (/Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/node_modules/esbuild/lib/main.js:1748:19)
"""
# esbuild's unresolved import, as cmux#46930's SetupCard path gave it.
UNRESOLVED_46930 = """\
✘ [ERROR] Could not resolve "../../components/SignInButton"

    src/pages/setup-card/SetupCard.tsx:12:29:
      12 │ import { SignInButton } from "../../components/SignInButton";
"""


def job_block(text: str, job: str) -> str:
    """The YAML of JOB under `jobs:` in TEXT (its lines up to the next two-space key)."""
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  \S|\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no job {job}")
    return match.group(1)


class WebTouched(unittest.TestCase):
    def setUp(self) -> None:
        if not (ROOT / "webviews").is_dir():
            self.skipTest("webviews/ is not checked out (sparse checkout)")
        self.key = cp.key_module(ROOT)
        self.routed = self.key.routed_inputs(str(ROOT))

    def touched(self, files: list[str]) -> list[str]:
        return cp.web_touched(files, self.routed, self.key.pathspec_matcher)

    def test_57269_and_46930_reach_a_web_bundle(self) -> None:
        self.assertEqual(self.touched(["webviews/src/agent-session/acpmux/VirtualTranscript.tsx"]),
                         ["webviews/src/agent-session/acpmux/VirtualTranscript.tsx"])
        self.assertEqual(self.touched(["webviews/src/pages/setup-card/SetupCard.tsx"]),
                         ["webviews/src/pages/setup-card/SetupCard.tsx"])

    def test_a_build_script_and_the_protocol_ir_reach_it(self) -> None:
        self.assertTrue(self.touched(["scripts/cmux-next/build-web-bundles.sh"]))
        self.assertTrue(self.touched(["cmux-tui/crates/acpmux/spec/acpmux-protocol.json"]))

    def test_a_change_that_reaches_no_bundle_builds_nothing(self) -> None:
        self.assertEqual(self.touched(["docs/ci/notes.md", "cmux-tui/crates/acpmux/src/lib.rs",
                                       "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"]), [])


class WebTouchedCommand(unittest.TestCase):
    def test_prints_one_output_line(self) -> None:
        if not (ROOT / "webviews").is_dir():
            self.skipTest("webviews/ is not checked out (sparse checkout)")
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "web-touched", str(ROOT), "HEAD", "HEAD"],
                             capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout, "web=false\n")


class BuildErrors(unittest.TestCase):
    def test_the_57269_duplicate_import_is_named(self) -> None:
        lines = cp.error_lines(NIGHTLY_57269)
        self.assertTrue(lines)
        self.assertTrue(all("layoutGeometry" in line or line.startswith("error:") for line in lines), lines)
        self.assertIn("Identifier 'layoutGeometry' has already been declared", lines[0])

    def test_the_46930_unresolved_path_is_named(self) -> None:
        lines = cp.error_lines(UNRESOLVED_46930)
        self.assertEqual(lines, ['✘ [ERROR] Could not resolve "../../components/SignInButton"'])

    def test_a_failed_build_exits_red_with_annotations(self) -> None:
        fake = ROOT / "scripts/cmux-next/build-web-bundles.sh"
        self.assertTrue(fake.is_file(), "the preflight builds with build-web-bundles.sh")
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/cmux-next").mkdir(parents=True)
            (root / "scripts/cmux-next/build-web-bundles.sh").write_text(
                "#!/bin/bash\ncat <<'EOF'\n" + NIGHTLY_57269 + "EOF\nexit 1\n")
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), "web-build", str(root), str(root / "out")],
                                 capture_output=True, text=True)
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("::error title=web bundle build::✘ [ERROR]", out.stdout)
        self.assertIn("NIGHTLY red", out.stdout)
        receipt = json.loads(next(line.removeprefix("CMUX_WEB_BUILD ") for line in out.stdout.splitlines()
                                  if line.startswith("CMUX_WEB_BUILD ")))
        self.assertEqual((receipt["builds"], receipt["exit_code"]), (1, 1))
        self.assertGreaterEqual(receipt["cpu_seconds"], 0)
        self.assertGreaterEqual(receipt["wall_seconds"], 0)
        self.assertIsNone(receipt["source_sha"])

    def test_receipt_binds_the_built_tree_instead_of_the_event_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/cmux-next").mkdir(parents=True)
            (root / "scripts/cmux-next/build-web-bundles.sh").write_text("#!/bin/bash\nexit 0\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                            "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "source tree"], check=True)
            source_sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), "web-build", str(root), str(root / "out")],
                                 capture_output=True, text=True, check=True,
                                 env={**os.environ, "GITHUB_SHA": "different-event-tree", "CMUX_WEB_SOURCE_KEY": "bundle-key"})
        receipt = json.loads(next(line.removeprefix("CMUX_WEB_BUILD ") for line in out.stdout.splitlines()
                                  if line.startswith("CMUX_WEB_BUILD ")))
        self.assertEqual(receipt["source_sha"], source_sha)
        self.assertEqual(receipt["event_sha"], "different-event-tree")
        self.assertEqual(receipt["source_key"], "bundle-key")


class LiveBase(unittest.TestCase):
    """cmux#51044: the preflight built GitHub's stale merge commit and passed; the base had moved."""

    def git(self, cwd, *args):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(cwd), *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def test_a_stale_merge_commit_is_rebuilt_on_the_live_tip(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            origin = Path(tmp) / "origin"
            origin.mkdir()
            self.git(origin, "init", "-q", "-b", "main")
            (origin / "a.tsx").write_text("import {\n  x,\n} from './m';\n")
            self.git(origin, "add", ".")
            self.git(origin, "commit", "-qm", "base")
            self.git(origin, "checkout", "-qb", "head")
            (origin / "a.tsx").write_text("import {\n  x,\n  layoutGeometry,\n} from './m';\n")
            self.git(origin, "commit", "-qam", "pr adds the import")
            head = self.git(origin, "rev-parse", "HEAD")
            self.git(origin, "update-ref", "refs/pull/7/head", head)
            self.git(origin, "checkout", "-q", "main")
            self.git(origin, "checkout", "-q", "-B", "stale", "main")
            self.git(origin, "merge", "--no-ff", "-qm", "stale merge", head)
            stale = self.git(origin, "rev-parse", "HEAD")
            self.git(origin, "checkout", "-q", "main")
            (origin / "b.txt").write_text("base moved\n")
            self.git(origin, "add", ".")
            self.git(origin, "commit", "-qm", "base moves")
            tip = self.git(origin, "rev-parse", "HEAD")
            work = Path(tmp) / "work"
            self.git(tmp, "clone", "-q", "--no-local", "--depth=2", "--branch", "stale", f"file://{origin}", str(work))
            self.assertEqual(self.git(work, "rev-parse", "HEAD"), stale)
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), "merge-live-base", str(work), "main", "7"],
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertEqual(self.git(work, "rev-parse", "HEAD^1"), tip)
            self.assertEqual(self.git(work, "rev-parse", "HEAD^2"), head)
            self.assertTrue((work / "b.txt").exists())
            again = subprocess.run([sys.executable, "-I", str(SCRIPT), "merge-live-base", str(work), "main", "7"],
                                   capture_output=True, text=True)
            self.assertEqual(again.returncode, 0)
            self.assertIn("live tip", again.stderr)

    def test_the_callee_merges_onto_the_live_base_then_fails_fast(self) -> None:
        block = job_block(CALLEE.read_text(), "web")
        merge = block.index("compile_preflight.py merge-live-base")
        # The check that reads the merged root (source_ref == '') runs after the merge; the early one runs only when
        # the bundle source is the checkout's own GitHub merge commit, whose answer the merge does not change.
        touched = block.index('compile_preflight.py web-touched "$WEB_SOURCE_ROOT"')
        self.assertIn("inputs.source_ref != '' && inputs.source_ref == github.sha", block)
        dup = block.index("tests/test_webviews_no_duplicate_import_names.py")
        install = block.index("name: Setup Bun")
        self.assertLess(merge, touched)
        self.assertLess(dup, install, "the parse check runs before any install")
        self.assertLess(block.index("name: Fast fail"), block.index("name: Source key"))

    def test_every_module_is_parsed_for_a_twice_bound_name_before_the_build(self) -> None:
        block = job_block(CALLEE.read_text(), "web")
        parse = block.index("node scripts/check-duplicate-bindings.mjs")
        self.assertLess(block.index("name: Setup Node"), parse)
        self.assertLess(block.index("name: Restore the webviews Bun package cache"), parse)
        self.assertLess(parse, block.index("compile_preflight.py web-build"), "the parse fails before the build")


class NeverSkipped(unittest.TestCase):
    def test_router_calls_it_on_every_tier(self) -> None:
        block = job_block(ROUTER.read_text(), "compile-preflight")
        self.assertIn("uses: ./.github/workflows/cmux-next-compile-preflight.yml", block)
        condition = re.search(r"^    if: (.*)$", block, re.M).group(1)
        self.assertEqual(condition, "${{ !cancelled() && needs.route.result == 'success' }}")
        for tier_word in ("start", "ready-to-land", "full-ci", "CI_LAND", "draft", "fast-gates"):
            self.assertNotIn(tier_word, condition)

    def test_router_affects_cover_the_resolved_bundle_inputs(self) -> None:
        config = json.loads(MANIFEST.read_text())["callees"]["cmux-next-compile-preflight.yml"]
        affects = config["affects"]
        self.assertIn("webviews/**", affects)
        self.assertIn("scripts/cmux-next/*web*", affects)
        self.assertIn("cmux-tui/crates/acpmux/spec/acpmux-protocol.json", affects)

        # The conservative superset must admit every input the full checkout's key currently resolves.
        key = cp.key_module(ROOT)
        # The key reports its directory root and `:(glob)` pathspecs as metadata; changed files are
        # descendants, so validate the concrete paths and exercise representative glob matches below.
        missing = [path for path in key.routed_inputs(str(ROOT))
                   if path != "webviews" and not path.startswith(":(glob)")
                   and not router.filters.admits("paths", affects, path)]
        self.assertEqual(missing, [], f"manifest under-routes web-bundle inputs: {missing}")

    def test_router_filter_keeps_docs_and_unrelated_tooling_out(self) -> None:
        config = json.loads(MANIFEST.read_text())["callees"]["cmux-next-compile-preflight.yml"]
        def admits(path: str) -> bool:
            return router.filters.admits("paths", config["affects"], path)
        self.assertTrue(admits("webviews/src/pages/setup-card/SetupCard.tsx"))
        self.assertTrue(admits("scripts/cmux-next/build-web-bundles.sh"))
        self.assertTrue(admits("cmux-tui/crates/acpmux/spec/acpmux-protocol.json"))
        self.assertTrue(admits("release-notes/next/highlights/example.md"))
        self.assertTrue(admits("examples/looks/quiet/cmux-setup.json"))
        self.assertFalse(admits("docs/ci/notes.md"))
        self.assertFalse(admits("cmux-tui/crates/acpmux/src/lib.rs"))
        self.assertFalse(admits("tools/format/check.py"))
        # Packages/macOS/** and scripts/cmux-next/** routed every Swift and cmux-next script head: 76 of 121 routed
        # merges in the 400 to 2026-11-27 20Z reached no web input. Their web inputs still route.
        self.assertTrue(admits("Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/Localizable.xcstrings"))
        self.assertTrue(admits("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings.d/a.key.json"))
        self.assertTrue(admits("Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageDescriptor.swift"))
        self.assertTrue(admits("Resources/markdown-viewer/viewer-navigation.js"))
        self.assertTrue(admits("scripts/cmux-next/build-agent-pane-web.sh"))
        self.assertTrue(admits("scripts/cmux-next/web-bundle-key.py"))
        self.assertFalse(admits("Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"))
        self.assertFalse(admits("scripts/cmux-next/sync-app-runtime.sh"))
        self.assertFalse(admits("Resources/Info.plist"))

    def test_never_web_check_fails_an_input_affects_does_not_route(self) -> None:
        # The fail-closed half of the narrow list: a webviews source importing a file outside `affects` fails the
        # head that adds the import. Before, the check read only `paths-ignore`, absent since #61854, and passed all.
        config = json.loads(MANIFEST.read_text())["callees"]["cmux-next-compile-preflight.yml"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            (root / "scripts/ci/workflow_paths_cover_inputs.py").write_text(
                (ROOT / "scripts/ci/workflow_paths_cover_inputs.py").read_text())
            narrow = dict(config, affects=[p for p in config["affects"] if p != "examples/**"])
            (root / "scripts/ci/pr_router.json").write_text(json.dumps({"callees": {
                "cmux-next-compile-preflight.yml": narrow}}))
            ignored = cp.router_ignores(root)
            self.assertTrue(ignored("examples/gallery/gallery.json"))
            self.assertFalse(ignored("webviews/src/pages/setup-card/SetupCard.tsx"))
            (root / "scripts/ci/pr_router.json").write_text(json.dumps({"callees": {
                "cmux-next-compile-preflight.yml": config}}))
            self.assertFalse(cp.router_ignores(root)("examples/gallery/gallery.json"))

    def test_route_skips_unaffected_files_and_fail_opens_unknown_diffs(self) -> None:
        event = {"action": "synchronize", "pull_request": {"draft": False, "head": {}, "base": {}, "labels": []}}
        callees = router.load_manifest()
        docs_start, _ = router.route(event, callees, ["docs/ci/notes.md"], decided=("full", "test"))
        web_start, _ = router.route(event, callees, ["webviews/src/pages/setup-card/SetupCard.tsx"], decided=("full", "test"))
        unknown_start, _ = router.route(event, callees, None, decided=("full", "test"))
        name = "cmux-next-compile-preflight.yml"
        self.assertNotIn(name, docs_start)
        self.assertIn(name, web_start)
        self.assertIn(name, unknown_start)

    def test_the_callee_job_skips_only_on_the_routes_no_web_verdict_and_builds_as_nightly(self) -> None:
        text = CALLEE.read_text()
        block = job_block(text, "web")
        conditions = re.findall(r"^    if: (.*)$", block, re.M)
        self.assertEqual(conditions, ["${{ inputs.web != 'false' || inputs.force_web }}"], "web=false skips unless a bundle consumer forces it")
        self.assertIn('compile_preflight.py never-web-check "$WEB_SOURCE_ROOT"', block)
        router = job_block(ROUTER.read_text(), "compile-preflight")
        self.assertIn("web: ${{ needs.route.outputs.preflight_web || 'true' }}", router)
        self.assertIn("preflight_web: ${{ steps.route.outputs.preflight_web }}", job_block(ROUTER.read_text(), "route"))
        self.assertIn("name: web bundle build", block)
        self.assertIn("compile_preflight.py web-build", block)
        self.assertIn('compile_preflight.py web-touched "$WEB_SOURCE_ROOT" HEAD^1 HEAD', block)
        self.assertIn("fetch-depth: 2", block)

    def test_a_warm_runner_skips_unpacking_the_bun_cache_archive(self) -> None:
        # A pool runner keeps its own Bun cache across jobs; the restore unpacked the 1.1 GB archive over it anyway,
        # a 30 s median of a 205 s build job (11-27 05:30-11:36Z). The check runs first, and the restore only when the
        # runner's cache is empty; CI_BUN_CACHE_RESTORE_WARM=1 restores everywhere again (fast gates' same rule).
        block = job_block(CALLEE.read_text(), "web")
        warm_at = block.index("name: Is this runner's own Bun package cache warm")
        restore_at = block.index("name: Restore the webviews Bun package cache")
        build_at = block.index("name: Build the web bundles")
        self.assertLess(warm_at, restore_at)
        self.assertLess(restore_at, build_at)
        self.assertIn("id: bun-warm", block[warm_at:restore_at])
        self.assertIn("vars.CI_BUN_CACHE_RESTORE_WARM", block[warm_at:restore_at])
        self.assertIn("steps.bun-warm.outputs.warm != 'true'", block[restore_at:build_at])
        # The build itself never depends on the warm check: a warm runner still builds.
        build_if = re.search(r"name: Build the web bundles.*\n\s+if: (.*)", block).group(1)
        self.assertNotIn("bun-warm", build_if)


class NeverWebCheck(unittest.TestCase):
    """compile_preflight.py never-web-check: no web bundle input is a path the router's paths-ignore skips."""

    def test_the_checkout_passes(self) -> None:
        if not (ROOT / "webviews").is_dir():
            self.skipTest("webviews/ is not checked out (sparse checkout)")
        run = subprocess.run([sys.executable, "-I", str(SCRIPT), "never-web-check", str(ROOT)],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_an_ignored_web_input_is_named(self) -> None:
        ignored = cp.router_ignores(ROOT)
        self.assertTrue(ignored("cmuxd/src/main.rs"))
        problems = cp.never_web_problems(ROOT, ["scripts/ci/compile_preflight.py", "webviews"],
                                         lambda path: path.endswith((".py", ".rs")))
        self.assertIn("scripts/ci/compile_preflight.py", problems)
        self.assertIn("webviews/probe.rs", problems)


class PreflightWeb(unittest.TestCase):
    """pr_router.preflight_web: the route's verdict the callee's `web` input carries."""

    @classmethod
    def setUpClass(cls) -> None:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import pr_router

        cls.router = pr_router
        cls.callees = pr_router.load_manifest()

    def web(self, files: list[str] | None, labels: tuple[str, ...] = ()) -> bool:
        event = {"pull_request": {"labels": [{"name": name} for name in labels]}}
        return self.router.preflight_web(event, self.callees, files)[0]

    def test_a_rust_swift_python_or_docs_only_change_skips(self) -> None:
        self.assertFalse(self.web(["cmuxd/src/main.rs", "Cargo.lock", "cmuxd/Cargo.toml"]))
        self.assertFalse(self.web(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift", "scripts/foo.py"]))
        self.assertFalse(self.web(["docs/handbook/x.md", ".github/workflows/rust-tests.yml"]))

    def test_a_change_that_may_reach_a_bundle_builds(self) -> None:
        for path in ("webviews/src/App.tsx", "webviews/README.md", "webviews/scripts/x.py",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageDescriptor.swift",
                     "scripts/cmux-next/web-bundle-key.py", ".github/workflows/pr-router.yml",
                     ".github/workflows/cmux-next-compile-preflight.yml", "schemas/x.json", "README.md"):
            self.assertTrue(self.web(["cmuxd/src/main.rs", path]), path)

    def test_tier_none_and_carried_heads_keep_web_coverage(self) -> None:
        event = {"action": "synchronize", "pull_request": {
            "draft": False, "head": {}, "base": {}, "labels": []}}
        name = "cmux-next-compile-preflight.yml"
        for decided, carried in ((("none", "test"), None), (("full", "test"), {name})):
            for files in (None, ["webviews/src/App.tsx"]):
                with self.subTest(decided=decided, files=files):
                    start, _ = self.router.route(event, self.callees, files,
                                                 decided=decided, carried=carried)
                    self.assertNotIn(name, start)
                    self.assertTrue(self.router.preflight_web(event, self.callees, files)[0])
        condition = re.search(r"^    if: (.*)$", job_block(ROUTER.read_text(), "compile-preflight"), re.M).group(1)
        self.assertEqual(condition, "${{ !cancelled() && needs.route.result == 'success' }}")

    def test_full_ci_unknown_or_empty_files_build(self) -> None:
        self.assertTrue(self.web(["cmuxd/src/main.rs"], labels=("full-ci",)))
        self.assertTrue(self.web(None))
        self.assertTrue(self.web([]))


class SharedWebArtifact(unittest.TestCase):
    def test_an_older_source_tree_keeps_current_transport_helpers(self) -> None:
        import yaml
        document = yaml.safe_load(CALLEE.read_text())
        steps = document["jobs"]["web"]["steps"]
        checkouts = [step for step in steps if step.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        self.assertNotIn("ref", checkouts[0]["with"])
        self.assertEqual(checkouts[1]["with"]["path"], "web-source")
        self.assertEqual(checkouts[1]["with"]["ref"], "${{ inputs.source_ref }}")
        build = next(step for step in steps if step.get("name") == "Build the web bundles (the build NIGHTLY runs)")
        self.assertIn('scripts/ci/compile_preflight.py web-build "$WEB_SOURCE_ROOT"', build["run"])

    def test_fixed_tree_artifact_and_live_base_validate_distinct_sources(self) -> None:
        import yaml
        jobs = yaml.safe_load(ROUTER.read_text())["jobs"]
        self.assertEqual(jobs["compile-preflight"]["with"]["source_ref"], "${{ github.sha }}")
        self.assertTrue(jobs["compile-preflight"]["with"]["validate_live_base"])
        workflow = yaml.safe_load(CALLEE.read_text())
        steps = workflow["jobs"]["web"]["steps"]
        routing = next(step for step in steps if step.get("name") == "No web bundle input is a path the router skips")
        self.assertIn('never-web-check "$WEB_SOURCE_ROOT"', routing["run"])
        merge = next(step for step in steps if step.get("name") == "Merge the head onto the live base")
        self.assertIn("inputs.source_ref == '' || inputs.validate_live_base", merge["if"])
        react = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text())["jobs"]
        self.assertEqual(react["react-apps-head-bundles"]["with"]["source_ref"], "${{ inputs.sha || github.sha }}")
        compare = next(step for step in steps if step.get("id") == "live-web")
        build = next(step for step in steps if step.get("name") == "Validate the different live-base web sources")
        self.assertEqual(build["if"], "steps.live-web.outputs.build == 'true'")
        # Execute the workflow's comparison and build command against a stand-in bundler. A
        # stale merge with distinct source inputs must build; an identical tree must not.
        for key, expected in (("consumer-key", 0), ("live-base-key", 1)):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                scripts = root / "scripts/cmux-next"
                scripts.mkdir(parents=True)
                (scripts / "web-bundle-key.py").write_text("print(" + repr(key) + ")")
                (scripts / "build-web-bundles.sh").write_text("#!/bin/bash\necho build >> builds\n")
                env = dict(os.environ, CONSUMER_KEY="consumer-key", GITHUB_OUTPUT=str(root / "out"),
                           RUNNER_TEMP=tmp, CMUX_WEB_SOURCE_KEY=key)
                subprocess.run(["bash", "-e", "-c", compare["run"]], cwd=root, env=env, check=True)
                if "build=true" in (root / "out").read_text().splitlines():
                    command = build["run"].replace("scripts/ci/compile_preflight.py", str(SCRIPT))
                    subprocess.run(["bash", "-e", "-c", command], cwd=root, env=env, check=True,
                                   capture_output=True, text=True)
                builds = (root / "builds").read_text().splitlines() if (root / "builds").exists() else []
                self.assertEqual(len(builds), expected)
        for name in ("Setup Bun", "Setup Node"):
            step = next(step for step in steps if step.get("name") == name)
            self.assertIn("steps.live-web.outputs.build == 'true'", step["if"])

    def test_manifest_accepts_copy_and_rejects_wrong_key_changed_missing_or_extra_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bundle.js").write_text("built output")
            cp.cmd_artifact("write", root, "source-and-toolchain-key")
            cp.cmd_artifact("verify", root, "source-and-toolchain-key")
            with self.assertRaises(ValueError):
                cp.cmd_artifact("verify", root, "another-source-key")
            (root / "bundle.js").write_text("changed output")
            with self.assertRaises(ValueError):
                cp.cmd_artifact("verify", root, "source-and-toolchain-key")
            (root / "bundle.js").write_text("built output")
            (root / "extra.js").write_text("unexpected")
            with self.assertRaises(ValueError):
                cp.cmd_artifact("verify", root, "source-and-toolchain-key")
            (root / "extra.js").unlink()
            (root / "bundle.js").unlink()
            with self.assertRaises(ValueError):
                cp.cmd_artifact("verify", root, "source-and-toolchain-key")

    def test_browser_install_replaces_a_second_build_and_keeps_no_producer_fallback(self) -> None:
        # Execute the actual fleet build function with lightweight bundler/source-check stand-ins. This
        # measures invocations, not production CPU savings: the five real PR receipts measure those.
        source = (ROOT / "scripts/ci/react-apps-check-fleet.sh").read_text()
        body = re.search(r"^build\(\) \{\n.*?^\}", source, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/cmux-next").mkdir(parents=True)
            (root / "webviews").mkdir()
            checker = root / "scripts/check-webviews-bun-version.sh"
            checker.write_text("#!/bin/bash\necho checked >> source-checks\n")
            checker.chmod(0o755)
            bun = root / "scripts/bun"
            bun.write_text('#!/bin/bash\ntest "$*" = "run verify:tanstack-router"\n')
            bun.chmod(0o755)
            builder = root / "scripts/cmux-next/build-web-bundles.sh"
            builder.write_text("#!/bin/bash\nif [ \"$1\" = --from ]; then echo install >> events; else echo build >> events; fi\n")
            builder.chmod(0o755)
            env = dict(os.environ, CMUX_WEB_BUNDLES_FROM="", PATH=str(root / "scripts") + os.pathsep + os.environ["PATH"])
            subprocess.run(["bash", "-c", body + "\nbuild\nbuild"], cwd=root, env=env, check=True)
            self.assertEqual((root / "events").read_text().splitlines().count("build"), 2)
            (root / "events").write_text("")
            subprocess.run(["bash", "-c", body + "\nbuild\nCMUX_WEB_BUNDLES_FROM=artifact build"], cwd=root, env=env, check=True)
            self.assertEqual((root / "events").read_text().splitlines(), ["build", "install"])
            self.assertEqual(len((root / "source-checks").read_text().splitlines()), 4)

    def test_only_web_consumers_wait_and_every_restored_output_has_a_manifest(self) -> None:
        import yaml
        router = yaml.safe_load(ROUTER.read_text())["jobs"]
        self.assertNotIn("compile-preflight", router["pipeline"]["needs"])
        self.assertTrue(router["pipeline"]["with"]["defer_web_browser"])
        web = router["web-pipeline"]
        self.assertIn("compile-preflight", web["needs"])
        self.assertEqual(json.loads(web["with"]["jobs"]), ["web-browser"])
        self.assertTrue(web["with"]["web_browser_only"])
        self.assertIn("compile-preflight", router["size-budget"]["needs"])
        pipeline = (ROOT / ".github/workflows/pr-pipeline.yml").read_text()
        self.assertIn("!inputs.web_browser_only", job_block(pipeline, "ios-fast-runner"))
        producer = job_block(CALLEE.read_text(), "web")
        self.assertIn("web-artifact write", producer)
        self.assertLess(producer.index("Build the web bundles"), producer.index("web-artifact write"))
        self.assertIn("artifact: ${{ steps.artifact-name.outputs.name }}", producer)
        self.assertIn("${{ github.run_attempt }}", producer)
        for filename, job in (("cmux-next-size-budget.yml", "web-head"), ("pr-pipeline.yml", "web-browser")):
            text = job_block((ROOT / ".github/workflows" / filename).read_text(), job)
            self.assertIn('test "$PRODUCER_KEY" = "$SOURCE_KEY"', text)
            self.assertIn("web-artifact verify", text)
            self.assertIn("inputs.web_bundle_transport == 'r2'", text)
            self.assertIn("inputs.web_bundle_transport == 'github'", text)
            self.assertIn("name: ${{ inputs.web_bundle_artifact }}", text)
            # The producer's attempt is authoritative. Reconstructing from the
            # consumer attempt breaks a partial rerun (producer attempt 1,
            # consumer attempt 2).
            self.assertNotIn("inputs.web_bundle_key }}-${{ github.run_attempt }}", text)
        ci_web = (ROOT / ".github/workflows/ci-web.yml").read_text()
        for job_name in ("react-apps-check-shard", "react-apps-base-early", "react-apps-base-check"):
            block = job_block(ci_web, job_name)
            self.assertIn("web_bundle_artifact", block)
            self.assertNotIn("web_bundle_key }}-${{ github.run_attempt }}", block)

    def test_partial_rerun_consumes_the_producer_attempt_artifact(self) -> None:
        """A retry of one consumer must keep reading the successful producer's name."""
        import yaml
        callee = yaml.safe_load(CALLEE.read_text())
        trigger = callee["on"] if "on" in callee else callee[True]
        outputs = trigger["workflow_call"]["outputs"]
        self.assertEqual(outputs["web_bundle_artifact"]["value"], "${{ jobs.web.outputs.artifact }}")
        for filename, job_name in (("cmux-next-size-budget.yml", "web-head"), ("pr-pipeline.yml", "web-browser")):
            workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            trigger = workflow["on"] if "on" in workflow else workflow[True]
            inputs = trigger["workflow_call"]["inputs"]
            self.assertIn("web_bundle_artifact", inputs)
            job = workflow["jobs"][job_name]
            downloads = [step for step in job["steps"] if "download-artifact" in step.get("uses", "")]
            self.assertTrue(downloads)
            self.assertTrue(all(step.get("with", {}).get("name") == "${{ inputs.web_bundle_artifact }}" for step in downloads))

    def test_cache_restore_uses_the_saved_output_path(self) -> None:
        """A cache hit must restore files, not only report that a key exists."""
        text = CALLEE.read_text()
        cache = job_block(text, "web")
        restore = cache[cache.index("id: web-bundle-cache") :]
        restore = restore[:restore.index("\n      - name: ", 1)]
        self.assertIn("path: ${{ runner.temp }}/web-bundles-out", restore)
        self.assertNotIn("lookup-only: true", restore)
        save = text[text.index("- name: Cache the web bundles under this source key") :]
        save = save[:save.index("\n      - name: ", 1)]
        self.assertIn("path: ${{ runner.temp }}/web-bundles-out", save)

    def test_github_cache_hit_skips_the_preflight_build(self) -> None:
        import yaml
        job = yaml.safe_load(CALLEE.read_text())['jobs']['web']
        gated = {
            step['name']: step['if']
            for step in job['steps']
            if step.get('name') in {
                'Restore pinned Bun 1.4.4 from the CI cache bucket',
                'Setup Bun', 'Give this job its own bun',
                'Restore pinned Node 24.22.1 from the CI cache bucket',
                'Setup Node', 'Restore the webviews Bun package cache',
                'Build the web bundles (the build NIGHTLY runs)',
            }
        }
        self.assertEqual(len(gated), 7)
        for condition in gated.values():
            self.assertIn("steps.web-bundle-cache.outputs.cache-hit != 'true'", condition)

    def test_outage_is_not_hidden_by_rebuilding_or_switching_transport(self) -> None:
        import yaml
        for filename, job_name in (("cmux-next-compile-preflight.yml", "web"),
                                   ("cmux-next-size-budget.yml", "web-head"),
                                   ("pr-pipeline.yml", "web-browser")):
            job = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())["jobs"][job_name]
            transfers = [step for step in job["steps"] if "/r2-artifact/" in step.get("uses", "")]
            self.assertTrue(transfers)
            for step in transfers:
                self.assertNotIn("continue-on-error", step)
                self.assertIn("== 'r2'", step["if"])
        size = job_block((ROOT / ".github/workflows/cmux-next-size-budget.yml").read_text(), "web-head")
        self.assertIn("steps.web-bundle-run.outputs.hit != 'true'", size)
        self.assertIn('if [[ "$WEB_BUNDLE_HIT" != true ]]; then', size)


class R2WebTransport(unittest.TestCase):
    """Exercise the real archive client with only the remote store replaced."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "r2_web_artifact", ROOT / ".github/actions/r2-artifact/artifact.py")
        self.client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.client)

    def test_directory_roundtrip_preserves_bundle_and_manifest_layout(self):
        import io
        from unittest import mock

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "bundles"
            (source / "webviews/assets").mkdir(parents=True)
            (source / "webviews/assets/app.js").write_text("bundle bytes")
            (source / "manifest.json").write_text('{"source_key":"source"}')
            uploaded = []
            requests = []

            def endpoint(token, body):
                self.assertEqual(token, "test-oidc")
                requests.append(body)
                return {"key": "same-run-product", "put_url": "https://store.invalid/product",
                        "get_url": "https://store.invalid/product"}

            def urlopen(request, timeout):
                self.assertEqual(timeout, 600)
                if request.get_method() == "PUT":
                    uploaded.append(request.data.read())
                    response = io.BytesIO()
                    response.status = 200
                    return response
                self.assertEqual(request.get_method(), "GET")
                return io.BytesIO(uploaded[0])

            inputs = {"INPUT_NAME": "pr-web-bundles-source-1", "INPUT_PATH": str(source),
                      "INPUT_RETENTION_DAYS": "1", "INPUT_IF_NO_FILES_FOUND": "error",
                      "RUNNER_TEMP": str(root), "GITHUB_RUN_ID": "101"}
            with mock.patch.dict(os.environ, inputs, clear=True), \
                    mock.patch.object(self.client, "oidc_token", return_value="test-oidc"), \
                    mock.patch.object(self.client, "endpoint", side_effect=endpoint), \
                    mock.patch.object(self.client.urllib.request, "urlopen", side_effect=urlopen), \
                    mock.patch.object(self.client, "note"):
                self.client.upload()
                os.environ["INPUT_PATH"] = str(root / "downloaded")
                self.client.download()
            self.assertEqual(len(uploaded), 1)
            self.assertEqual(requests, [
                {"op": "put", "name": "pr-web-bundles-source-1", "retention_days": 1},
                {"op": "get", "name": "pr-web-bundles-source-1", "run_id": 101}])
            dest = root / "downloaded"
            self.assertEqual((dest / "webviews/assets/app.js").read_text(), "bundle bytes")
            self.assertEqual((dest / "manifest.json").read_bytes(), (source / "manifest.json").read_bytes())
            self.assertFalse((dest / "bundles").exists())

    def test_archive_traversal_and_links_are_rejected(self):
        import io
        import tarfile
        from unittest import mock

        for kind in ("traversal", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = root / "unsafe.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    item = tarfile.TarInfo("../escape" if kind == "traversal" else "link")
                    if kind == "symlink":
                        item.type = tarfile.SYMTYPE
                        item.linkname = "../escape"
                        tar.addfile(item)
                    else:
                        item.size = 1
                        tar.addfile(item, io.BytesIO(b"x"))
                with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(root)}), \
                        mock.patch.object(self.client, "note"), self.assertRaises(SystemExit):
                    self.client.extract(archive.as_uri(), root / "dest", "unsafe")
                self.assertFalse((root / "escape").exists())
                self.assertFalse((root / "dest/link").is_symlink())


if __name__ == "__main__":
    unittest.main()
