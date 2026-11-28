#!/usr/bin/env python3
"""Keep the web OTA channel and publication contracts in sync.

This is deliberately a source test: a missing pointer writer is otherwise easy to
hide behind a valid setting enum, and a missing read-back check leaves a green
workflow with an unverified object.
"""
import ast
import json
import os
import re
import subprocess
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-web-bundle-publish.yml"
POINTER = ROOT / "scripts/cmux-next/web-ota-pointer.py"
UPDATER = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/WebUpdates/WebUpdater.swift"
WEB_SCHEMA = ROOT / "schemas/settings/source/updates.json"
KEY = ROOT / "scripts/cmux-next/web-bundle-key.py"
POINTER_STEP = "      - name: Sign and upload the pointer\n"


def pointer_step(workflow=None):
    """The publish job's pointer step, from its name to the next step."""
    text = (workflow or WORKFLOW.read_text()).split(POINTER_STEP, 1)[1]
    return text.split("\n      - ", 1)[0]


class WebOTAPublicationContractTests(unittest.TestCase):
    def test_every_supported_channel_has_a_writer_and_readback(self):
        pointer = POINTER.read_text()
        channels = ast.literal_eval(re.search(r"^CHANNELS = (\(.+?\))$", pointer, re.M).group(1))
        self.assertEqual(channels, ("every-merge", "nightly"))

        updater = UPDATER.read_text()
        enum = re.search(r"enum Channel:.*?\{(.*?)\n    \}", updater, re.S).group(1)
        app_channels = set(re.findall(r"^        case (\w+)(?: = \"([^\"]+)\")?", enum, re.M))
        app_values = {raw or name for name, raw in app_channels}
        self.assertEqual(app_values, {"off", "every-merge", "nightly"})
        self.assertEqual(set(channels), app_values - {"off"})

        workflow = WORKFLOW.read_text()
        pointer_job = pointer_step(workflow)
        self.assertIn("github.ref_name == 'nightly-next' && 'nightly' || 'every-merge'", pointer_job)
        for channel in channels:
            self.assertIn('--channel "$CHANNEL"', pointer_job)
            self.assertIn('"cmux-next-web/ota/$CHANNEL.json"', pointer_job)
            self.assertIn('/cmux-next-web/ota/$CHANNEL.json?check=', pointer_job)

    def test_nightly_channel_has_a_promoted_branch_writer(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("branches: [feat-cmux-next, nightly-next]", workflow)
        self.assertIn("github.ref_name == 'nightly-next' && 'nightly'", workflow)
        settings = json.loads(WEB_SCHEMA.read_text())
        web = next(row for group in settings["lists"] for row in group["rows"] if row.get("key") == "updates.web")
        self.assertIn("nightly", {choice["value"] for choice in web["choices"]})

    def test_missing_production_signing_key_fails(self):
        pointer_job = pointer_step()
        guard = re.search(r'if \[\[ -z "\$SIGNING_KEY" \]\]; then(.*?)\n          fi', pointer_job, re.S)
        self.assertIsNotNone(guard)
        body = guard.group(1)
        self.assertIn("::error::", body)
        self.assertRegex(body, r"exit 1")
        self.assertNotIn("no web update pointer", body)

    def test_missing_outputs_digest_cannot_make_production_green(self):
        pointer_job = pointer_step()
        self.assertIn('[[ $rc == 0 ]] || exit "$rc"', pointer_job)
        self.assertNotIn("has no outputs digest; no web update pointer", pointer_job)

    def test_toolchain_change_moves_source_identity(self):
        namespace = {}
        exec(compile(KEY.read_text(), str(KEY), "exec"), namespace)
        old = os.environ.get("CMUX_WEB_BUN_VERSION")
        try:
            os.environ["CMUX_WEB_BUN_VERSION"] = "1.4.4"
            first = namespace["source_key"](str(ROOT))
            os.environ["CMUX_WEB_BUN_VERSION"] = "9.9.9"
            second = namespace["source_key"](str(ROOT))
        finally:
            if old is None:
                os.environ.pop("CMUX_WEB_BUN_VERSION", None)
            else:
                os.environ["CMUX_WEB_BUN_VERSION"] = old
        self.assertNotEqual(first, second)

    def test_same_toolchain_manifest_is_reused_across_runtime_prefixes(self):
        namespace = {}
        exec(compile(KEY.read_text(), str(KEY), "exec"), namespace)
        matches = namespace["manifest_matches_toolchain"]
        self.assertTrue(matches({"bun": "1.4.4", "node": "v24.22.1"}, "1.4.4", "24.22.1"))
        self.assertFalse(matches({"bun": "1.4.3", "node": "v24.22.1"}, "1.4.4", "24.22.1"))

    def test_workflow_pins_identity_and_records_manifest_toolchain(self):
        workflow = WORKFLOW.read_text()
        self.assertNotIn("CMUX_WEB_NODE_VERSION:", workflow)
        self.assertIn('key["declared_node_version"](".") if "declared_node_version" in key else "24.22.1"', workflow)
        self.assertIn('bun-version: "1.4.4"', workflow)
        # setup-node runs the Node the key names: the built tree's .node-version, or
        # web-bundle-key.py's PRE_NODE_VERSION_FILE_NODE for a base from before that file.
        self.assertIn("node-version: ${{ steps.web-node-pin.outputs.node_version }}", workflow)
        self.assertIn("node_version=$(tr -d '[:space:]' < .node-version)", workflow)
        self.assertIn('echo "node_version=24.22.1" >> "$GITHUB_OUTPUT"  # web-bundle-key.py PRE_NODE_VERSION_FILE_NODE', workflow)
        self.assertIn('"bun": normalize(subprocess.run(["bun", "--version"]', workflow)
        self.assertIn('"node": normalize(subprocess.run(["node", "--version"]', workflow)
        self.assertIn('manifest_matches_toolchain"]', workflow)

    def test_published_manifest_check_runs_on_a_tree_from_before_the_node_pin(self):
        # The "already published" check runs the applied tree's web-bundle-key.py. A ref or base
        # from before .node-version has no declared_node_version there; the check must compare
        # against the Node that tree keyed on (PRE_NODE_VERSION_FILE_NODE), not raise KeyError
        # and refuse the publication (#44131 review).
        import tempfile

        workflow = WORKFLOW.read_text()
        script = textwrap.dedent(re.search(
            r"elif python3 - \"\$manifest\" <<'PY'\n(.*?)\n\s*PY\n", workflow, re.S).group(1))
        pre_node = re.search(r'^PRE_NODE_VERSION_FILE_NODE = "([^"]+)"$', KEY.read_text(), re.M).group(1)
        # A pre-pin web-bundle-key.py: the functions the check used before declared_node_version.
        old_key = textwrap.dedent("""\
            def normalize_toolchain_version(value):
                return str(value).strip().lstrip("v")
            def declared_bun_version(root):
                return "1.4.4"
            def manifest_matches_toolchain(manifest, bun, node):
                return all(normalize_toolchain_version(manifest.get(name, "")) == normalize_toolchain_version(expected)
                           for name, expected in (("bun", bun), ("node", node)))
        """)
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            (tree / "scripts/cmux-next").mkdir(parents=True)
            (tree / "scripts/cmux-next/web-bundle-key.py").write_text(old_key)
            (tree / "check.py").write_text(script)
            for node, expected in ((f"v{pre_node}", 0), ("v99.0.0", 1)):
                (tree / "manifest.json").write_text(json.dumps({"bun": "1.4.4", "node": node}))
                result = subprocess.run(["python3", "-I", "check.py", "manifest.json"], cwd=tree,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, (node, result.stderr))
        # This tree: the check reads .node-version through declared_node_version.
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "manifest.json"
            bun = json.loads((ROOT / "webviews/package.json").read_text())["devEngines"]["packageManager"]["version"]
            manifest.write_text(json.dumps({"bun": bun, "node": (ROOT / ".node-version").read_text().strip()}))
            check = Path(tmp) / "check.py"
            check.write_text(script)
            result = subprocess.run(["python3", "-I", str(check), str(manifest)], cwd=ROOT,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_toolchain_mismatch_fails_immutable_manifest_reuse(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('echo "::error::the existing manifest for $key has a different Bun/Node toolchain; refusing immutable-key publication"', workflow)
        self.assertIn('exit 1\n          fi', workflow)

    def test_a_layer_dispatch_never_moves_the_web_update_pointer(self):
        # A `pr` or `ref` dispatch builds code that is not on the channel's branch: it only
        # writes its layer pointer (cmux-next-web/pr|ref/...), never the signed update pointer,
        # and records no deployment.
        import yaml

        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertNotIn("pointer", jobs)
        step = next(s for s in jobs["publish"]["steps"] if s.get("name") == "Sign and upload the pointer")
        for name in ("inputs.pr", "inputs.ref"):
            self.assertIn(f"!{name}", step["if"], name)
        deployment = str(jobs["publish"]["environment"]["deployment"])
        for name in ("inputs.pr", "inputs.ref"):
            self.assertIn(f"!{name} &&", deployment, name)

    def test_the_signing_job_runs_no_bun_or_node(self):
        # Key safety: the job holding the R2 credentials and the signing key runs only this
        # checkout's scripts on the archive's bytes, never the build's toolchain.
        import yaml

        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        holders = [name for name, job in jobs.items() if "CMUX_WEB_OTA_SIGNING_KEY" in json.dumps(job)]
        self.assertEqual(holders, ["publish"])
        for step in jobs["publish"]["steps"]:
            uses = step.get("uses", "")
            self.assertFalse(uses.startswith(("oven-sh/setup-bun", "actions/setup-node")), uses)
            self.assertNotRegex(step.get("run", ""), r"(^|\s)(bun|bunx|node|npm|npx)\s", step.get("name"))
        signing = [s.get("name") for s in jobs["publish"]["steps"] if "CMUX_WEB_OTA_SIGNING_KEY" in json.dumps(s)]
        self.assertEqual(signing, ["Sign and upload the pointer"])

    def test_the_cas_job_holds_no_secret_and_never_holds_the_pointer_back(self):
        # cas/1 (RFD 0166) builds this checkout's Rust: no secret there, and its failure leaves
        # the archive and the pointer as they were.
        import yaml

        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertNotIn("secrets.", json.dumps(jobs["cas"]))
        self.assertIs(jobs["cas"]["continue-on-error"], True)
        self.assertIn("!cancelled()", jobs["publish"]["if"])
        self.assertIn("needs.build.result == 'success'", jobs["publish"]["if"])
        upload = next(s for s in jobs["publish"]["steps"] if s.get("name") == "Upload the cas/1 objects to R2")
        self.assertIs(upload["continue-on-error"], True)
        # The objects first, cas.json (which the pointer step reads) last.
        self.assertTrue(upload["run"].rstrip().splitlines()[-2].lstrip().startswith('up "$dir/cas.json"'))
        self.assertIn('--cas "$dir/cas.json"', pointer_step())

    def test_a_rate_limited_pr_api_falls_back_to_git_and_keeps_the_fork_rule(self):
        workflow = WORKFLOW.read_text()
        step = workflow.split("      - name: Apply the pull request or ref onto its base\n", 1)[1].split("\n      - ", 1)[0]
        fallback = step.split("the pull request API did not answer", 1)[1].split("\n            fi\n", 1)[0]
        self.assertIn("git ls-remote -q origin 'refs/heads/*'", fallback)
        self.assertIn('grep -qx "$head" <<<"$tips"', fallback)
        self.assertIn("exit 1", fallback)

    def test_pushes_do_not_queue_behind_each_other(self):
        # One concurrency group for every push made each merge wait for the run before it
        # (2026-11-22: up to 15 min behind a run whose runner hook stalled).
        import yaml

        group = yaml.safe_load(WORKFLOW.read_text())["concurrency"]["group"]
        self.assertIn("inputs.pr || inputs.ref || github.sha", group)

    def test_overlapping_runs_swap_the_pointer_and_never_move_it_back(self):
        loop = pointer_step().split("for attempt in", 1)[1]
        for needle in ('--download-to "$dir/current.json"', "--replace-sha256", "--write-once",
                       "--conflict-exit-code 9"):
            self.assertIn(needle, loop)
        newer = 'newer --pointer "$dir/$CHANNEL.json" --keys "$keys" --current "$dir/current.json"'
        self.assertLess(loop.index("--download-to"), loop.index(newer))
        self.assertLess(loop.index(newer), loop.index("--conflict-exit-code 9"))


if __name__ == "__main__":
    unittest.main()
