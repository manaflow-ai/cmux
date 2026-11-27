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
    and no label or tier condition, and the callee's job has no job-level `if:`, so its check is never "skipped";
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

spec = importlib.util.spec_from_file_location("compile_preflight", SCRIPT)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

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


class NeverSkipped(unittest.TestCase):
    def test_router_calls_it_on_every_tier(self) -> None:
        block = job_block(ROUTER.read_text(), "compile-preflight")
        self.assertIn("uses: ./.github/workflows/cmux-next-compile-preflight.yml", block)
        condition = re.search(r"^    if: (.*)$", block, re.M).group(1)
        self.assertEqual(condition, "${{ !cancelled() && needs.route.result == 'success' }}")
        for tier_word in ("start", "ready-to-land", "full-ci", "CI_LAND", "draft", "fast-gates"):
            self.assertNotIn(tier_word, condition)

    def test_the_callee_job_has_no_job_level_if_and_builds_as_nightly(self) -> None:
        text = CALLEE.read_text()
        block = job_block(text, "web")
        self.assertNotRegex(block, r"^    if:", "a job-level if: would report the check skipped")
        self.assertIn("name: web bundle build", block)
        self.assertIn("compile_preflight.py web-build", block)
        self.assertIn('compile_preflight.py web-touched "$WEB_SOURCE_ROOT" HEAD^1 HEAD', block)
        self.assertIn("fetch-depth: 2", block)


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
        for filename, job in (("cmux-next-size-budget.yml", "web-head"), ("pr-pipeline.yml", "web-browser")):
            text = job_block((ROOT / ".github/workflows" / filename).read_text(), job)
            self.assertIn('test "$PRODUCER_KEY" = "$SOURCE_KEY"', text)
            self.assertIn("web-artifact verify", text)
            self.assertIn("inputs.web_bundle_transport == 'r2'", text)
            self.assertIn("inputs.web_bundle_transport == 'github'", text)
            self.assertIn("pr-web-bundles-${{ inputs.web_bundle_key }}-${{ github.run_attempt }}", text)

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
