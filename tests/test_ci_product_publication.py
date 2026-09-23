"""Exercise the workflow's publication decision and all product consumers."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def condition(expression, *, full_suite, publish="true"):
    """Evaluate the small boolean subset used by these actual workflow gates."""
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    expression = expression.replace("!cancelled()", "True")
    def value(match):
        name = match.group(0)
        if name.endswith(".result"):
            return repr("success")
        if name.endswith(".outputs.full_suite") or name == "inputs.full_suite":
            return repr(full_suite)
        if name.endswith(".outputs.compile_admitted") or name == "inputs.compile_admitted":
            return repr("false")
        if name.endswith(".outputs.publish"):
            return repr(publish)
        if name.endswith((".outputs.macos", ".outputs.release_build")) or name in {
            "inputs.macos",
            "inputs.release_build",
        }:
            return repr("true")
        raise AssertionError(f"Unmodeled workflow input: {name}")
    expression = re.sub(
        r"(?:needs|steps)\.[\w-]+\.(?:result|outputs\.[\w-]+)|inputs\.[\w-]+",
        value,
        expression,
    )
    return eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}})


class ProductPublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/ci-macos.yml").read_text())
        cls.job = cls.workflow["jobs"]["macos-compile-admission"]

    def publication(self, *, full_suite, event="pull_request", head="contributor/cmux", repo="manaflow-ai/cmux"):
        step = next((s for s in self.job["steps"] if s.get("id") == "publish-products"), None)
        if step is None:
            return "true"  # The previous workflow always packaged and uploaded.
        self.assertEqual(step["env"], {
            "PRODUCT_FULL_SUITE": "${{ inputs.full_suite }}",
            "PRODUCT_EVENT": "${{ github.event_name }}",
            "PRODUCT_HEAD_REPOSITORY": "${{ github.event.pull_request.head.repo.full_name }}",
            "PRODUCT_REPOSITORY": "${{ github.repository }}",
        })
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = dict(os.environ, GITHUB_OUTPUT=str(output), PRODUCT_FULL_SUITE=full_suite,
                       PRODUCT_EVENT=event, PRODUCT_HEAD_REPOSITORY=head, PRODUCT_REPOSITORY=repo)
            subprocess.run(["bash", "-e", "-c", step["run"]], env=env,
                           text=True, capture_output=True, check=True)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())["publish"]

    def test_only_known_compile_only_forks_skip_packaging_and_upload(self):
        cases = [
            ({"full_suite": "false"}, "false"),
            ({"full_suite": "true"}, "true"),
            ({"full_suite": ""}, "true"),
            ({"full_suite": "unknown"}, "true"),
            ({"full_suite": "false", "head": "manaflow-ai/cmux"}, "true"),
            ({"full_suite": "false", "head": "Manaflow-AI/CMUX"}, "true"),
            ({"full_suite": "false", "head": ""}, "true"),
            ({"full_suite": "false", "repo": ""}, "true"),
            ({"full_suite": "false", "event": "merge_group"}, "true"),
            ({"full_suite": "false", "event": "workflow_dispatch"}, "true"),
        ]
        for inputs, expected in cases:
            with self.subTest(inputs=inputs):
                publish = self.publication(**inputs)
                self.assertEqual(publish, expected)
                for step_id in ("package-products", "upload-products"):
                    step = next(s for s in self.job["steps"] if s.get("id") == step_id)
                    self.assertEqual(condition(step.get("if", "True"), full_suite=inputs["full_suite"],
                                               publish=publish), expected == "true")

    def test_all_actual_artifact_consumers_are_excluded_from_compile_only(self):
        consumers = []
        for name, job in self.workflow["jobs"].items():
            if "needs.macos-compile-admission.outputs.artifact_id" in str(job):
                consumers.append(name)
                self.assertFalse(condition(job["if"], full_suite="false"), name)
                self.assertTrue(condition(job["if"], full_suite="true"), name)
        self.assertEqual(set(consumers), {"app-host-unit-tests", "tests-build-and-lag"})
        for name in consumers:
            self.assertNotIn("reuse-products", str(self.workflow["jobs"][name]["if"]))

    def test_reuse_hit_keeps_consumer_validation_and_reports_metrics(self):
        steps = {step["name"]: step for step in self.job["steps"]}
        reuse_step = steps["Reuse exact compatible compiled products"]
        self.assertNotIn("if", reuse_step)
        self.assertEqual(
            steps["Validate Swift warning budget"]["if"],
            "steps.reuse-products.outputs.hit != 'true'",
        )
        for name in ("Stage compiled package frameworks", "Run early CLI binary smoke checks"):
            self.assertNotIn("reuse-products", str(steps[name].get("if", "")))

        report = steps["Record compiled-product reuse metrics"]
        self.assertEqual(report["if"], "always()")
        self.assertEqual(
            set(report["env"]),
            {
                "REUSE_HIT",
                "REUSE_REASON",
                "REUSE_MISS_REASONS",
                "REUSE_COMPILE_SECONDS",
                "REUSE_LOOKUP_SECONDS",
                "REUSE_TRANSFER_SECONDS",
                "REUSE_RESTORE_SECONDS",
                "REUSE_TOTAL_SECONDS",
                "REUSE_MACOS_MINUTES_SAVED",
            },
        )


    def test_app_host_shards_only_consume_the_admission_product(self):
        job = self.workflow["jobs"]["app-host-unit-tests"]
        steps = job["steps"]
        names = [step["name"] for step in steps]

        self.assertIn("needs.macos-compile-admission.outputs.artifact_id", str(job))
        restore_index = names.index("Restore compiled app-host test product")
        app_host_indices = [
            index for index, step in enumerate(steps)
            if "scripts/ci/run-app-host-xcodebuild.sh" in step.get("run", "")
        ]
        self.assertTrue(app_host_indices)
        self.assertLess(restore_index, min(app_host_indices))

        run_text = "\n".join(step.get("run", "") for step in steps)
        self.assertNotIn("-project cmux.xcodeproj", run_text)
        self.assertNotIn("-resolvePackageDependencies", run_text)
        self.assertNotIn(".ci-source-packages", str(job))
        self.assertNotIn("Cache Swift packages", names)
        self.assertNotIn("Resolve Swift packages", names)
        for setup_name in (
            "Capture Ghostty revision",
            "Cache GhosttyKit.xcframework",
            "Download pre-built GhosttyKit.xcframework",
            "Install Rust",
        ):
            self.assertNotIn(setup_name, names)
        self.assertNotIn("GhosttyKit.xcframework", str(job))
        self.assertNotIn("install-rust-ci.sh", str(job))

        checkout_steps = [
            step
            for step in steps
            if str(step.get("uses", "")).startswith("actions/checkout@")
        ]
        self.assertEqual(len(checkout_steps), 2)
        for step in checkout_steps:
            self.assertNotIn("submodules", step.get("with", {}))

        for step in steps:
            run = step.get("run", "")
            if "scripts/ci/run-app-host-xcodebuild.sh" not in run:
                continue
            self.assertIn("-xctestrun", run, step["name"])
            self.assertIn("test-without-building", run, step["name"])


    def test_skipping_publication_keeps_admission_and_early_checks(self):
        self.assertTrue(condition(self.job["if"], full_suite="false", publish="false"))
        for name in ("Compile app-host test product", "Validate Swift warning budget",
                     "Stage compiled package frameworks", "Run early CLI binary smoke checks"):
            step = next(s for s in self.job["steps"] if s["name"] == name)
            # Existing reuse-hit conditions may skip compilation, but publication
            # must never become an input to compilation or these validation gates.
            self.assertNotIn("publish-products", str(step))
        index = {s["name"]: i for i, s in enumerate(self.job["steps"])}
        self.assertIn("Choose product artifact publication", index)
        self.assertLess(index["Run early CLI binary smoke checks"], index["Choose product artifact publication"])


    def macos_status(self, compile_admitted, *, full_suite="true", results="success"):
        step = next(
            s for s in self.workflow["jobs"]["macos-status"]["steps"]
            if s.get("name") == "Check routed macOS jobs"
        )
        needs = {name: {"result": results} for name in self.workflow["jobs"]["macos-status"]["needs"]}
        inputs = {"macos": "true", "full_suite": full_suite, "compile_admitted": compile_admitted, "release_build": "true"}
        env = {**os.environ, "MACOS_INPUTS": json.dumps(inputs), "MACOS_NEEDS": json.dumps(needs)}
        return subprocess.run(["bash", "-c", step["run"]], env=env, text=True, capture_output=True)

    def test_macos_status_reads_unset_compile_admitted_as_compile(self):
        # ci.yml leaves compile_admitted unset on full-suite runs, which skip
        # both build-input reuse steps. That must not fail an all-green run.
        passed = self.macos_status("")
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertNotIn("invalid route", passed.stderr)
        failed = self.macos_status("", results="failure")
        self.assertNotEqual(failed.returncode, 0)
        garbage = self.macos_status("maybe")
        self.assertIn("invalid route compile_admitted='maybe'", garbage.stderr)


if __name__ == "__main__":
    unittest.main()
