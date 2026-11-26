#!/usr/bin/env python3
"""Pin the CLA metadata route before interpreting its dynamic required name."""
import contextlib
import hashlib
import io
import json
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CHECK = "CLA policy guard"
METADATA_IF = "${{ !(github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)) }}"
METADATA_NAME = "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title) && 'CLA policy guard metadata (ignored)' || 'CLA policy guard' }}"


def validate_metadata_routing(workflow):
    trigger = workflow.get("on", workflow.get(True))
    assert trigger == {"pull_request_target": {
        "branches": ["main"],
        "types": ["opened", "edited", "reopened", "synchronize", "ready_for_review"],
    }}, "CLA guard trigger contract changed"
    assert "concurrency" not in workflow, "metadata events must not cancel required verdicts"
    job = workflow["jobs"]["validate"]
    assert "concurrency" not in job, "metadata events must not cancel required verdicts"
    assert job["if"] == METADATA_IF, "CLA guard metadata predicate changed"
    assert job["name"] == METADATA_NAME, "CLA guard metadata name changed"


def candidate():
    workflow = yaml.safe_load((ROOT / ".github/workflows/cla-policy-guard.yml").read_text())
    workflow["jobs"]["validate"]["if"] = METADATA_IF
    workflow["jobs"]["validate"]["name"] = METADATA_NAME
    return workflow


class CLAMetadataRoutingTests(unittest.TestCase):
    def test_actual_workflow_contract(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/cla-policy-guard.yml").read_text())
        job = workflow["jobs"]["validate"]
        # GitHub can make the newest skipped suite authoritative for required
        # checks even when an older suite passed. Always publish this context.
        self.assertEqual(job["name"], REQUIRED_CHECK)
        self.assertNotIn("if", job)
        trigger = workflow.get("on", workflow.get(True))
        self.assertIn("edited", trigger["pull_request_target"]["types"])
        self.assertNotIn("concurrency", workflow)
        self.assertNotIn("concurrency", job)

    def test_rejects_incomplete_or_weakened_contract(self):
        for field, value in (("name", REQUIRED_CHECK), ("name", "${{ github.actor }}"),
                             ("if", "${{ false }}"),
                             ("if", METADATA_IF.replace("!github.event.changes.base", "true"))):
            with self.subTest(field=field, value=value):
                workflow = candidate()
                workflow["jobs"]["validate"][field] = value
                with self.assertRaises(AssertionError):
                    validate_metadata_routing(workflow)
        for level in ("workflow", "job"):
            workflow = candidate()
            target = workflow if level == "workflow" else workflow["jobs"]["validate"]
            target["concurrency"] = {"group": "pr", "cancel-in-progress": True}
            with self.assertRaises(AssertionError):
                validate_metadata_routing(workflow)

    def test_bounded_guard_follows_dynamic_owner_and_fails_closed(self):
        import test_ci_required_checks_are_bounded as bounded
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            path = workflows / "cla-policy-guard.yml"
            import test_ci_merge_queue_required_checks as queue
            (workflows / "merge-group-policy-checks.yml").write_text(yaml.safe_dump(queue.expected_bridge()))
            def run(document):
                path.write_text(yaml.safe_dump(document))
                with patch.object(bounded, "ROOT", root), patch.object(bounded, "WORKFLOWS", workflows), \
                     patch.object(bounded, "REQUIRED_CONTEXTS", (REQUIRED_CHECK,)), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return bounded.main()
            workflow = candidate()
            self.assertEqual(run(workflow), 0)
            del workflow["jobs"]["validate"]["timeout-minutes"]
            self.assertEqual(run(workflow), 1)
            workflow = candidate()
            workflow["jobs"]["validate"]["if"] = "${{ false }}"
            self.assertEqual(run(workflow), 1)
            workflow["jobs"]["validate"]["name"] = REQUIRED_CHECK
            self.assertEqual(run(workflow), 1)
            del workflow["jobs"]["validate"]["if"]
            self.assertEqual(run(workflow), 0)

    def test_merge_queue_retains_static_policy_bridge(self):
        import test_ci_merge_queue_required_checks as queue
        with tempfile.TemporaryDirectory() as directory:
            workflows = Path(directory)
            (workflows / "cla-policy-guard.yml").write_text(yaml.safe_dump(candidate()))
            (workflows / "merge-group-policy-checks.yml").write_text(yaml.safe_dump(queue.expected_bridge()))
            with patch.object(queue, "WORKFLOWS", workflows):
                names = queue.merge_group_check_names()
            self.assertEqual(names[REQUIRED_CHECK], ["merge-group-policy-checks.yml"])
            self.assertNotIn(METADATA_NAME, names)


# ------------------------------------------------- glaeda-route App read token

VALIDATOR = ROOT / "scripts/ci/validate-cla-policy.rb"
GUARD = ROOT / ".github/workflows/cla-policy-guard.yml"
# The reviewed App-token guard (2026-10-26): the validator reads on the
# manaflow-glaeda-route App's budget, read-only, with GITHUB_TOKEN as fallback.
APP_TOKEN_STEPS = """\
      # The validator's reads (the pull request, its files and, for a policy
      # change, the reviews) go on the manaflow-glaeda-route App's own budget:
      # GITHUB_TOKEN's core budget, shared by every workflow, ran out hourly on
      # 2026-10-26 and the guard then rejected every pull request. The token is
      # read-only and scoped to this repository. The key reaches only this
      # pinned action, never the validation step, and a skipped or failed mint
      # leaves GITHUB_TOKEN, so the guard is never worse off than before.
      - name: Mint the glaeda-route read token
        id: glaeda-token
        if: vars.GLAEDA_ROUTE_APP_ID != ''
        continue-on-error: true
        timeout-minutes: 1
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          app-id: ${{ vars.GLAEDA_ROUTE_APP_ID }}
          private-key: ${{ secrets.GLAEDA_ROUTE_APP_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ github.event.repository.name }}
          permission-contents: read
          permission-pull-requests: read

      - name: Run trusted CLA regression matrix and validate policy as data
        env:
          GH_TOKEN: ${{ steps.glaeda-token.outputs.token || secrets.GITHUB_TOKEN }}
"""
# Loads the validator's definitions (not its main block) and checks the given
# workflow files' structure, printing one JSON object.
RUBY_DRIVER = r"""
require "json"
path = ARGV.shift
src = File.read(path)
cut = src.rindex("\nbegin\n  run_yaml_regression_matrix!")
abort "validator main block not found" unless cut
eval(src[0...cut], TOPLEVEL_BINDING, path)
run_guard_contract_regression_matrix!
result = { "pin" => EXPECTED_GUARD_WORKFLOW_DIGEST, "script_pin" => EXPECTED_GUARD_SCRIPT_DIGEST,
           "script_digest" => guard_script_digest(src), "files" => {} }
ARGV.each do |file|
  raw = File.binread(file)
  begin
    validate_guard_workflow(raw, authorize: false)
    result["files"][file] = "ok"
  rescue PolicyError => error
    result["files"][file] = error.message
  end
end
puts JSON.generate(result)
"""


@unittest.skipUnless(shutil.which("ruby"), "ruby is required for the guard validator")
class CLAGuardAppTokenTests(unittest.TestCase):
    """The guard's reads may move to the glaeda-route App's token, read-only, with a GITHUB_TOKEN fallback."""

    def validate(self, *documents: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, document in enumerate(documents):
                path = Path(directory) / f"guard-{index}.yml"
                path.write_bytes(document.encode())
                paths.append(str(path))
            result = subprocess.run(["ruby", "-e", RUBY_DRIVER, str(VALIDATOR), *paths],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = json.loads(result.stdout.strip().splitlines()[-1])
            output["results"] = [output["files"][path] for path in paths]
            return output

    def test_the_guard_is_the_pinned_app_token_layout(self):
        # The guard carries the reviewed App-token steps byte for byte, passes
        # the validator's structure checks, and is the digest the validator
        # pins, so the next guard-only pull request starts from a reviewed base.
        raw = GUARD.read_text()
        self.assertIn(APP_TOKEN_STEPS, raw)
        output = self.validate(raw)
        self.assertEqual(output["results"], ["ok"])
        self.assertEqual(output["pin"], hashlib.sha256(GUARD.read_bytes()).hexdigest())
        # The validator pins its own bytes too (with that constant blanked).
        self.assertEqual(output["script_pin"], output["script_digest"])

    def test_the_app_token_is_read_only_and_falls_back(self):
        workflow = yaml.safe_load(GUARD.read_text())
        steps = workflow["jobs"]["validate"]["steps"]
        mint = steps[3]
        self.assertEqual(mint["uses"], "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
        self.assertIs(mint["continue-on-error"], True)
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-contents": "read", "permission-pull-requests": "read"})
        self.assertEqual(steps[4]["env"]["GH_TOKEN"],
                         "${{ steps.glaeda-token.outputs.token || secrets.GITHUB_TOKEN }}")
        self.assertNotIn("GLAEDA_ROUTE_APP_KEY", json.dumps(steps[4]))
        self.assertEqual(workflow["jobs"]["validate"]["permissions"],
                         {"contents": "read", "pull-requests": "read"})

    def test_a_write_permission_or_another_action_is_rejected(self):
        candidate = GUARD.read_text()
        pinned = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
        variants = {
            "contents write": candidate.replace("permission-contents: read", "permission-contents: write"),
            "pull-requests write": candidate.replace("permission-pull-requests: read", "permission-pull-requests: write"),
            "added issues write": candidate.replace(
                "          permission-pull-requests: read\n",
                "          permission-pull-requests: read\n          permission-issues: write\n"),
            "no permission inputs": candidate.replace("          permission-contents: read\n", "").replace(
                "          permission-pull-requests: read\n", ""),
            "unpinned action": candidate.replace(pinned, "actions/create-github-app-token@v3"),
            "third-party action": candidate.replace(
                pinned, "tibdex/github-app-token@3beb63f4bd073e61482598c45c71c1019b59b73a"),
            "no fallback": candidate.replace(
                "${{ steps.glaeda-token.outputs.token || secrets.GITHUB_TOKEN }}",
                "${{ steps.glaeda-token.outputs.token }}"),
            "key in the validation step": candidate.replace(
                "          GH_REPO: ${{ github.repository }}\n",
                "          GH_REPO: ${{ github.repository }}\n          APP_KEY: ${{ secrets.GLAEDA_ROUTE_APP_KEY }}\n"),
            "mint failure fails the guard": candidate.replace("        continue-on-error: true\n", ""),
        }
        for name, document in variants.items():
            self.assertNotEqual(document, candidate, name)
        results = self.validate(*variants.values())["results"]
        for name, result in zip(variants, results):
            with self.subTest(variant=name):
                self.assertNotEqual(result, "ok")


if __name__ == "__main__":
    unittest.main()
