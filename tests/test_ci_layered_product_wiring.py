"""Exercise the actual opt-in workflow gates and normalization/restore commands."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import app_host_layer_consumers as consumers
NAMES = ("app-cli", "runtime", "tests", "diagnostics")


class UniqueKeyLoader(yaml.SafeLoader):
    """Match GitHub's rejection of duplicate keys instead of silently winning."""
    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in result:
                raise yaml.constructor.ConstructorError(
                    "while constructing a mapping", node.start_mark,
                    f"duplicate mapping key: {key}", key_node.start_mark)
            result[key] = self.construct_object(value_node, deep=deep)
        return result


def load_workflow(source):
    return yaml.load(source, Loader=UniqueKeyLoader)


def condition(expression, values):
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    expression = re.sub(r"(?:steps|needs|github|inputs)(?:\.[\w*-]+)+",
                        lambda match: repr(values.get(match[0], "")), expression)
    return eval(expression.replace("&&", " and ").replace("||", " or "),
                {"__builtins__": {}, "contains": lambda values, value: value in values})


class LayeredWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load_workflow((ROOT / ".github/workflows/ci.yml").read_text())
        cls.job = cls.workflow["jobs"]["macos-compile-admission"]
        cls.steps = {s["id"]: s for s in cls.job["steps"] if "id" in s}

    def test_workflow_loader_rejects_duplicate_job_permissions(self):
        source = "jobs:\n  tests:\n    permissions: {contents: read, actions: read}\n    permissions: {contents: read, actions: read}\n"
        with self.assertRaisesRegex(yaml.constructor.ConstructorError, "duplicate mapping key: permissions"):
            load_workflow(source)

    def test_workflow_loader_rejects_duplicates_at_every_mapping_depth(self):
        for source in ("jobs: {}\njobs: {}\n", "jobs: {tests: {permissions: {actions: read, actions: read}}}\n"):
            with self.subTest(source=source), self.assertRaisesRegex(yaml.constructor.ConstructorError, "duplicate mapping key"):
                load_workflow(source)

    def test_actual_gate_requires_explicit_full_suite_opt_in_and_pr_origin(self):
        values = {"steps.upload-products.outcome": "success", "needs.changes.outputs.full_suite": "true",
                  "github.event_name": "pull_request", "github.repository": "org/repo",
                  "github.event.pull_request.head.repo.full_name": "org/repo",
                  "github.event.pull_request.labels.*.name": []}
        gate = self.steps["package-layers"]["if"]
        cases = [({}, False), ({"github.event.pull_request.labels.*.name": ["app-host-layers"]}, True),
                 ({"github.event.pull_request.labels.*.name": ["app-host-layers"], "github.event.pull_request.head.repo.full_name": "fork/repo"}, False),
                 ({"github.event.pull_request.labels.*.name": ["app-host-layers"], "needs.changes.outputs.full_suite": "false"}, False),
                 ({"github.event_name": "workflow_dispatch", "inputs.product_artifacts": "layered"}, True),
                 ({"github.event_name": "workflow_dispatch", "inputs.product_artifacts": "aggregate"}, False),
                 ({"github.event_name": "merge_group", "inputs.product_artifacts": "layered"}, False)]
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                self.assertEqual(condition(gate, values | overrides), expected)
        event = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(event["workflow_dispatch"]["inputs"]["product_artifacts"]["default"], "aggregate")

    def test_index_requires_every_layer_and_default_produces_no_extra_upload(self):
        values = {"steps.package-layers.outcome": "skipped"}
        for name in NAMES:
            step = self.steps["upload-layer-" + name]
            self.assertFalse(condition(step["if"], values))
            self.assertTrue(condition(step["if"], {"steps.package-layers.outcome": "success"}))
            self.assertEqual(step["with"]["path"], "${{ runner.temp }}/app-host-layers/" + name + ".aar")
        values = {"steps.upload-layer-" + name + ".outcome": "success" for name in NAMES}
        for name in NAMES:
            self.assertFalse(condition(self.steps["pin-layer-index"]["if"], values | {"steps.upload-layer-" + name + ".outcome": "failure"}))
        self.assertTrue(condition(self.steps["pin-layer-index"]["if"], values))
        self.assertTrue(condition(self.steps["upload-layer-index"]["if"], {"steps.pin-layer-index.outcome": "success"}))
        self.assertFalse(condition(self.steps["upload-layer-index"]["if"], {"steps.pin-layer-index.outcome": "failure"}))

    def test_consumer_policy_matches_actual_jobs_shards_and_focused_groups(self):
        policy = consumers.load_policy()
        app_host = self.workflow["jobs"]["app-host-unit-tests"]
        shards = app_host["strategy"]["matrix"]["shard"]
        expected = {f"app-host-unit-tests-shard-{shard}" for shard in shards} | {"tests-build-and-lag"}
        self.assertEqual(set(policy["consumers"]), expected)
        self.assertEqual(app_host["env"]["CMUX_APP_HOST_CONSUMER"], "app-host-unit-tests-shard-${{ matrix.shard }}")
        self.assertEqual(self.workflow["jobs"]["tests-build-and-lag"]["env"]["CMUX_APP_HOST_CONSUMER"], "tests-build-and-lag")
        for shard in shards:
            self.assertEqual(consumers.required_layers(f"app-host-unit-tests-shard-{shard}", policy),
                             ("app-cli", "runtime", "tests"))
        self.assertEqual(consumers.required_layers("tests-build-and-lag", policy),
                         ("app-cli", "runtime", "tests"))
        for key in ("CMUX_APP_HOST_GLOBAL_SEARCH_SHARD", "CMUX_APP_HOST_CLI_REGRESSION_SHARD",
                    "CMUX_APP_HOST_FOCUSED_REGRESSION_B_SHARD", "CMUX_APP_HOST_FOCUSED_REGRESSION_SHARD"):
            shard = int(app_host["env"][key])
            self.assertIn(shard, shards)
            self.assertIn(f"app-host-unit-tests-shard-{shard}", policy["consumers"])

    def test_both_consumers_keep_flat_fallback_and_common_restore_validation(self):
        for name in ("app-host-unit-tests", "tests-build-and-lag"):
            job = self.workflow["jobs"][name]
            self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
            steps = {step["name"]: step for step in job["steps"]}
            download = steps["Download compiled app-host test product"]
            r2 = steps["Try shared R2 artifact transport"]
            self.assertTrue(r2["continue-on-error"])
            self.assertEqual(r2["run"], "python3 scripts/ci/restore-r2-artifact.py")
            # Exercise the real three-route gates, including absent outputs
            # from skipped/failed optional steps. A layer hit skips BOTH flat
            # transports; an R2 hit skips only GitHub, never inner validation.
            for layer_hit in ("true", "false", ""):
                for r2_hit in ("true", "false", ""):
                    with self.subTest(job=name, layer_hit=layer_hit, r2_hit=r2_hit):
                        values = {"steps.restore-layers.outputs.hit": layer_hit,
                                  "steps.r2-products.outputs.hit": r2_hit}
                        self.assertEqual(condition(r2["if"], values), layer_hit != "true")
                        self.assertEqual(condition(download["if"], values),
                                         layer_hit != "true" and r2_hit != "true")
            sequence = list(steps)
            self.assertLess(sequence.index("Restore opt-in layered app-host test product"),
                            sequence.index("Try shared R2 artifact transport"))
            self.assertLess(sequence.index("Try shared R2 artifact transport"),
                            sequence.index("Download compiled app-host test product"))
            self.assertLess(sequence.index("Download compiled app-host test product"),
                            sequence.index("Restore compiled app-host test product"))
            restore = steps["Restore compiled app-host test product"]
            self.assertNotIn("if", restore)
            self.assertEqual(restore["run"], "scripts/ci/restore-app-host-test-product.sh")
            self.assertEqual(restore["env"]["CMUX_LAYER_RESTORED"], "${{ steps.restore-layers.outputs.hit }}")
            layered = steps["Restore opt-in layered app-host test product"]
            self.assertIn('${CMUX_DERIVED_DATA_PATH}-layers', layered["run"])
            self.assertIn('--consumer "$CMUX_APP_HOST_CONSUMER"', layered["run"])
            self.assertIn('outputs.layer_index_digest', layered["env"]["LAYER_INDEX_DIGEST"])
            self.assertEqual(download["uses"], "./.github/actions/download-test-product")
            self.assertIn("Declare app-host product consumer", steps)
            self.assertIn("Report app-host product consumer receipt", steps)

    def test_actual_producer_packages_normalized_aggregate_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts/ci").mkdir(parents=True)
            (root / "original/Build/Products").mkdir(parents=True)
            archive = root / "scripts/ci/app-host-products-archive.sh"
            archive.write_text('#!/bin/bash\nset -eu\ntest "$1" = unpack\nmkdir -p "$3/Build/Products"\nprintf normalized > "$3/Build/Products/marker"\n')
            archive.chmod(0o755)
            (root / "scripts/ci/app_host_layer_transport.py").write_text('import pathlib,sys\nassert sys.argv[1] == "identity"\npathlib.Path(sys.argv[2]).write_text("{}")\n')
            (root / "scripts/ci/app_host_layered_products.py").write_text('import pathlib,sys\nassert sys.argv[1] == "pack"\nassert (pathlib.Path(sys.argv[2])/"Build/Products/marker").read_text() == "normalized"\npathlib.Path(sys.argv[3]).mkdir()\n')
            result = subprocess.run(["bash", "-e", "-c", self.steps["package-layers"]["run"]], cwd=root,
                                    env=dict(os.environ, RUNNER_TEMP=str(root), CMUX_COMPILE_ADMISSION_DERIVED_DATA=str(root / "original")),
                                    text=True, capture_output=True, check=True)
            self.assertIn('CMUX_APP_HOST_LAYER_NORMALIZE {"result": "success"', result.stdout)
            self.assertTrue((root / "app-host-layers").is_dir())
            self.assertEqual(list((root / "original/Build/Products").iterdir()), [])
            self.assertEqual(list(root.glob("cmux-layer-normalized.*")), [])

    def test_layered_hit_enforces_real_warning_budget_before_runtime_restore(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "python3"
            executable.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\nif [[ "$1" == *swift_warning_budget.py ]]; then exit 71; fi\n')
            executable.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "scripts/ci/restore-app-host-test-product.sh")],
                                    env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], CALLS=str(root / "calls"),
                                             CMUX_LAYER_RESTORED="true", CMUX_DERIVED_DATA_PATH=str(root / "derived")), capture_output=True)
            self.assertEqual(result.returncode, 71)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 2)
            self.assertIn("restore-warning-log", calls[0])
            self.assertIn("swift_warning_budget.py --log", calls[1])


if __name__ == "__main__":
    unittest.main()
