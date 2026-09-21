"""Exercise the workflow's publication decision and all product consumers."""
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
        if name.endswith(".outputs.full_suite"):
            return repr(full_suite)
        if name.endswith(".outputs.compile_admitted"):
            return repr("false")
        if name.endswith(".outputs.publish"):
            return repr(publish)
        if name.endswith((".outputs.macos", ".outputs.release_build")):
            return repr("true")
        raise AssertionError(f"Unmodeled workflow input: {name}")
    expression = re.sub(r"(?:needs|steps)\.[\w-]+\.(?:result|outputs\.[\w-]+)", value, expression)
    return eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}})


class ProductPublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
        cls.job = cls.workflow["jobs"]["macos-compile-admission"]

    def publication(self, *, full_suite, event="pull_request", head="contributor/cmux", repo="manaflow-ai/cmux"):
        step = next((s for s in self.job["steps"] if s.get("id") == "publish-products"), None)
        if step is None:
            return "true"  # The previous workflow always packaged and uploaded.
        self.assertEqual(step["env"], {
            "PRODUCT_FULL_SUITE": "${{ needs.changes.outputs.full_suite }}",
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

    def test_app_host_shards_only_consume_the_admission_product(self):
        job = self.workflow["jobs"]["app-host-unit-tests"]
        steps = job["steps"]
        names = [step["name"] for step in steps]

        # Every physical shard takes the exact compile-admission artifact through
        # the shared restore path before launching any app-host XCTest process.
        self.assertIn("needs.macos-compile-admission.outputs.artifact_id", str(job))
        restore_index = names.index("Restore compiled app-host test product")
        app_host_indices = [
            index for index, step in enumerate(steps)
            if "scripts/ci/run-app-host-xcodebuild.sh" in step.get("run", "")
        ]
        self.assertTrue(app_host_indices)
        self.assertLess(restore_index, min(app_host_indices))

        # Consumers own execution only. Project/package resolution belongs to the
        # compile producer; bringing the project back into a shard can silently
        # duplicate work or mutate the restored DerivedData.
        run_text = "\n".join(step.get("run", "") for step in steps)
        self.assertNotIn("-project cmux.xcodeproj", run_text)
        self.assertNotIn("-resolvePackageDependencies", run_text)
        self.assertNotIn(".ci-source-packages", str(job))
        self.assertNotIn("Cache Swift packages", names)
        self.assertNotIn("Resolve Swift packages", names)

        # Focused and broad app-host invocations must execute the restored
        # xctestrun without compiling an equivalent app/test product.
        for step in steps:
            run = step.get("run", "")
            if "scripts/ci/run-app-host-xcodebuild.sh" not in run:
                continue
            self.assertIn("-xctestrun", run, step["name"])
            self.assertIn("test-without-building", run, step["name"])

    def test_terminal_core_full_suite_lives_in_package_lane(self):
        app_job = self.workflow["jobs"]["app-host-unit-tests"]
        app_text = str(app_job)
        app_names = [step["name"] for step in app_job["steps"]]

        self.assertNotIn("CmuxTerminalCore-Package", app_text)
        self.assertNotIn("GhosttyKit.xcframework", app_text)
        self.assertNotIn("Install Rust", app_names)
        app_run = "\n".join(step.get("run", "") for step in app_job["steps"])
        self.assertNotIn("scripts/install-rust-ci.sh", app_run)
        self.assertIsNone(re.search(r"(?m)^\s*(?:sudo\s+)?rustup(?:\s|$)", app_run))
        self.assertIsNone(re.search(r"(?m)^\s*(?:sudo\s+)?cargo(?:\s|$)", app_run))
        self.assertNotIn("test_bundled_ghostty_theme_picker_helper.sh", app_text)

        package_job = self.workflow["jobs"]["swift-package-tests"]
        package_step = next(
            step for step in package_job["steps"]
            if step["name"] == "Run Swift package unit tests"
        )
        package_run = package_step["run"]
        append_command = 'grep -qxF CmuxTerminalCore "$selected" || echo CmuxTerminalCore >> "$selected"'
        active_lines = {
            line.strip()
            for line in package_run.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn(append_command, active_lines)

        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "changed.txt"
            selected = Path(directory) / "selected.txt"
            changed.write_text("docs/ci.md\n", encoding="utf-8")
            with selected.open("w", encoding="utf-8") as output:
                subprocess.run(
                    [
                        "python3",
                        "scripts/ci/select_package_tests.py",
                        "--changed-files",
                        str(changed),
                        "CmuxTerminalCore",
                        "CmuxSettings",
                    ],
                    cwd=ROOT,
                    stdout=output,
                    check=True,
                    text=True,
                )
            self.assertNotIn("CmuxTerminalCore", selected.read_text(encoding="utf-8").splitlines())
            subprocess.run(
                ["bash", "-euc", 'selected="$1"; ' + append_command, "_", str(selected)],
                cwd=ROOT,
                check=True,
                text=True,
            )
            self.assertIn("CmuxTerminalCore", selected.read_text(encoding="utf-8").splitlines())

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


if __name__ == "__main__":
    unittest.main()
