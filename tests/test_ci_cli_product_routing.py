"""Execute the actual gates for targeted CLI tests, including prior admission."""
import importlib.util
from itertools import product
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def gate(expression, *, macos, cli, full_suite, compile_admitted, swift_packages="false", unit_suite="false",
         unit_in_admission="false"):
    routes = dict(macos=macos, cli=cli, full_suite=full_suite, unit_suite=unit_suite,
                  compile_admitted=compile_admitted, release_build="false", swift_packages=swift_packages,
                  unit_in_admission=unit_in_admission)
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    expression = expression.replace("!cancelled()", "True")
    expression = expression.replace("github.event_name", repr("pull_request"))
    def resolve(match):
        key = match.group()
        if key.endswith(".result"):
            return repr("success")
        return repr(routes[key.rsplit(".", 1)[-1]])
    expression = re.sub(r"needs\.[\w-]+\.(?:result|outputs\.\w+)|inputs\.\w+", resolve, expression)
    return eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}})


def run_step(job, name, env):
    step = next(step for step in job["steps"] if step.get("name") == name)
    return subprocess.run(["bash", "-c", step["run"]], cwd=ROOT,
                          env={**os.environ, **env}, capture_output=True, text=True)


class CLIProductRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.caller = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())["jobs"]
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/ci-macos.yml").read_text())
        cls.jobs = cls.workflow["jobs"]

    def test_actual_conditions_keep_targeted_route_alive_after_prior_admission(self):
        for macos, cli, full_suite, unit_suite, admitted, packages, in_admission in product(("false", "true"), repeat=7):
            if unit_suite == "true" and admitted == "true":
                continue  # changes never admits a prior build for a unit-ci run
            if in_admission == "true" and unit_suite != "true":
                continue  # choose_ci_suite only runs suites in admission for a unit run
            routes = dict(macos=macos, cli=cli, full_suite=full_suite, unit_suite=unit_suite,
                          compile_admitted=admitted, swift_packages=packages, unit_in_admission=in_admission)
            compile_needed = (macos == "true" or cli == "true") and (
                full_suite == "true" or cli == "true" or admitted != "true")
            cli_needed = cli == "true" or (macos == "true" and full_suite == "true")
            with self.subTest(**routes):
                self.assertEqual(gate(self.caller["macos"]["if"], **routes), compile_needed or packages == "true")
                self.assertEqual(gate(self.caller["macos-admission-gate"]["if"], **routes), compile_needed)
                self.assertEqual(gate(self.jobs["macos-compile-admission"]["if"], **routes), compile_needed)
                self.assertEqual(gate(self.jobs["cli-product-tests"]["if"], **routes), cli_needed)
                self.assertEqual(gate(self.jobs["swift-package-tests"]["if"], **routes),
                                 (macos == "true" and full_suite == "true") or packages == "true")
                self.assertEqual(gate(self.jobs["app-host-unit-tests"]["if"], **routes),
                                 macos == "true" and (full_suite == "true" or unit_suite == "true")
                                 and in_admission != "true")
                self.assertEqual(gate(self.jobs["tests-build-and-lag"]["if"], **routes),
                                 macos == "true" and full_suite == "true")
                # A cli-profile product has no app or app-host bundles, so no
                # job that consumes them may run beside it.
                profile = gate(self.workflow["env"]["CMUX_PRODUCT_PROFILE"], **routes)
                app_host_consumer = any(
                    gate(self.jobs[name]["if"], **routes)
                    for name in ("app-host-unit-tests", "tests-build-and-lag"))
                self.assertEqual(profile, "app-host" if app_host_consumer or (
                    macos == "true" and admitted != "true") else "cli")

    def test_required_status_rejects_missing_targeted_cli_work(self):
        job = self.jobs["macos-status"]
        for macos in ("false", "true"):
            inputs = dict(macos=macos, cli="true", full_suite="false", compile_admitted="true", release_build="false")
            needs = {name: {"result": "skipped"} for name in job["needs"]}
            for name in ("macos-compile-admission", "cli-product-tests"):
                needs[name]["result"] = "success"
            env = dict(MACOS_INPUTS=json.dumps(inputs), MACOS_NEEDS=json.dumps(needs))
            result = run_step(job, "Check routed macOS jobs", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ("macos-compile-admission", "cli-product-tests"):
                for outcome in ("skipped", "failure", "cancelled"):
                    broken = {key: dict(value) for key, value in needs.items()}
                    broken[name]["result"] = outcome
                    env["MACOS_NEEDS"] = json.dumps(broken)
                    result = run_step(job, "Check routed macOS jobs", env)
                    self.assertNotEqual(result.returncode, 0, (macos, name, outcome))

    def test_outer_tests_gate_requires_targeted_workflow(self):
        job = self.caller["tests"]
        step = next(step for step in job["steps"] if "macos_work_required" in step.get("run", ""))
        for macos in ("false", "true"):
            for outcome in ("success", "skipped", "failure", "cancelled"):
                needs = {
                    "changes": {"result": "success", "outputs": dict(macos=macos, cli="true", full_suite="false", compile_admitted="true")},
                    "linux-preflight": {"result": "success"},
                    "macos": {"result": outcome}, "web": {"result": "skipped"},
                }
                env_key = next(key for key, value in step["env"].items() if "toJSON(needs)" in value)
                result = run_step(job, step["name"], {env_key: json.dumps(needs)})
                self.assertEqual(result.returncode == 0, outcome == "success", result.stderr)

    def test_test_sources_route_cli_without_widening_unrelated_tests(self):
        spec = importlib.util.spec_from_file_location("cli_route_detector", ROOT / "scripts/ci/detect_ci_change_areas.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        for path in ("cmuxCLITests/CLISSHPTYResizeInputTests.swift", "cmuxCLITestSupport/AgentHookTestNotificationPipeline.swift"):
            self.assertTrue(module.classify_files([path]).cli, path)
        self.assertFalse(module.classify_files(["cmuxTests/AgentNotificationGateTests.swift"]).cli)


if __name__ == "__main__":
    unittest.main()
