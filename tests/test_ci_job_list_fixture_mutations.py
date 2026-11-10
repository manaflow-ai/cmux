#!/usr/bin/env python3
"""Every job-list fixture goes red under the pre-fix matcher and stays green under tests/workflow_jobs.py.

A hand-kept CI job list is either derived from the workflows or guarded by a test that fails on any job with the
list's trait that the list doesn't classify; each guard carries a fixture that adds such a job to the whole
workflow tree and expects to be named. A fixture only proves something if it would have caught the miss the
shared reader fixed. This test swaps the pre-fix reader into workflow_jobs (PreFixReader) and runs each fixture
twice: with the current reader it must pass, with the pre-fix one it must fail.

The pre-fix reader:
- secrets: the `"secrets." in text` substring check, as names: `secrets.NAME` only, case-sensitive; no
  `secrets['X']`, `secrets["X"]`, `SECRETS.x`, `toJSON(secrets)` or `secrets: inherit`.
- jobs: the header regex `\\n  ([A-Za-z0-9_-]+):\\n`, which misses `  name: # comment` and folds that job into the
  one before it.
- documents: yaml.safe_load, which keeps the last of two jobs with one id.
- environments: the literal `environment:` (or its `name:`); a matrix value or an expression counts as no release
  environment.

The 15 fixtures: 11 from the nightly, signing and routing groups (tests/test_nightly_trusted_routing.py,
tests/test_nightly_sign_runner.py, tests/test_seed_derived_data.py, tests/test_ci_signing_owned_mac.py,
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py's GATED_SECRET_JOBS,
tests/test_ci_fork_runner_routing.py, tests/test_publish_app_token_workflow.py) and the four keychain lists
(KeychainListFixtures below). This branch merges the three list branches, so every module is importable here.
"""

from __future__ import annotations

import importlib
import re
import sys
import unittest
from collections.abc import Mapping
from contextlib import ExitStack
from pathlib import Path
from typing import Any
from unittest import mock

import yaml

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(TESTS))

import workflow_jobs  # noqa: E402

KEYCHAIN = "test_ci_signing_keychain_is_deleted_before_bundle_code"


class PreFixReader:
    """The readers the guards used before tests/workflow_jobs.py, patched into that module."""

    SECRET = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")
    HEADER = re.compile(r"\n  ([A-Za-z0-9_-]+):\n")

    @classmethod
    def secret_names(cls, value: Any) -> set[str]:
        return {name for text in workflow_jobs.strings(value) for name in cls.SECRET.findall(text)}

    @staticmethod
    def document(source: str | Path) -> dict[str, Any]:
        text = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
        return yaml.safe_load(text)

    @classmethod
    def jobs(cls, source: str | Path | Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        if isinstance(source, Mapping):
            return dict(source.get("jobs") or {})
        text = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
        start = text.find("\njobs:\n")
        body = text[start + len("\njobs:"):] if start >= 0 else text
        heads = list(cls.HEADER.finditer(body))
        found: dict[str, dict[str, Any]] = {}
        for index, head in enumerate(heads):
            end = heads[index + 1].start() if index + 1 < len(heads) else len(body)
            # A line indented less than a job's keys (a header the regex missed) is dropped, so that job's keys
            # land in the job before it, as they did.
            lines = [line[4:] if line.startswith("    ") else "" for line in body[head.end() - 1:end].splitlines()]
            try:
                parsed = yaml.safe_load("\n".join(lines))
            except yaml.YAMLError:
                parsed = {}
            found[head.group(1)] = parsed if isinstance(parsed, dict) else {}
        return found

    @staticmethod
    def environment_values(job: Mapping[str, Any]) -> tuple[set[str], set[str]]:
        env = job.get("environment")
        if isinstance(env, Mapping):
            env = env.get("name")
        if not isinstance(env, str) or not env or "${{" in env:
            return set(), set()
        return {env.strip()}, set()

    @classmethod
    def patched(cls) -> ExitStack:
        stack = ExitStack()
        for name in ("secret_names", "document", "jobs", "environment_values"):
            stack.enter_context(mock.patch.object(workflow_jobs, name, getattr(cls, name)))
        return stack


def _documents() -> dict[str, dict]:
    return {path.name: workflow_jobs.document(path) for path in sorted((ROOT / ".github/workflows").glob("*.y*ml"))}


class KeychainListFixtures(unittest.TestCase):
    """The four keychain lists' fixtures (tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py), and
    GATED_SECRET_JOBS', which that file runs only from main()."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.guard = importlib.import_module(KEYCHAIN)
        cls.documents = _documents()

    def test_step_level_only(self) -> None:
        self.assertEqual(self.guard.step_level_fixture_failures(self.documents), [])

    def test_inline_developer_id_keychains(self) -> None:
        self.assertEqual(self.guard.inline_keychain_fixture_failures(self.documents), [])

    def test_script_made_keychains(self) -> None:
        self.assertEqual(self.guard.script_made_fixture_failures(self.documents), [])

    def test_release_pool_signers(self) -> None:
        self.assertEqual(self.guard.release_pool_signer_fixture_failures(self.documents), [])

    def test_gated_secret_jobs(self) -> None:
        self.assertEqual(self.guard.gated_secret_fixture_failures(self.documents), [])

    def test_the_lists_hold_against_the_workflows(self) -> None:
        failures: list[str] = []
        self.guard.check_keychain_lists(self.documents, failures)
        self.assertEqual(failures, [])


HERE = __name__
# (list, module, class, the fixture that must name an unlisted job, its listed-and-green twin or None)
FIXTURES = (
    ("HOSTED_SECRET_JOBS", "test_nightly_trusted_routing", "NightlyTrustedRouting",
     "test_a_new_secret_job_is_named_until_classified", "test_a_new_secret_job_named_owned_stays_green"),
    ("CREDENTIALED_CONTROL_JOBS", "test_nightly_trusted_routing", "CredentialedControls",
     "test_a_new_credentialed_control_on_a_pool_route_fails",
     "test_a_new_credentialed_control_on_the_nightly_pool_stays_green"),
    ("SIGNING_JOBS, OWNED_ONLY_JOBS, SECRET_JOBS (nightly)", "test_nightly_sign_runner", "Workflow",
     "test_a_new_signing_job_is_checked_without_being_listed",
     "test_a_new_signing_job_on_the_signer_route_stays_green"),
    ("SIGNING_MATERIAL_UNPICKED", "test_nightly_sign_runner", "Workflow",
     "test_every_mac_job_with_signing_material_is_placed_by_a_sign_picker_or_named", None),
    ("SIGNING_NIGHTLY_JOBS", "test_seed_derived_data", "Wiring",
     "test_secret_nightly_jobs_are_derived_and_checked_on_the_owned_lane", None),
    ("GLAEDA_EXCLUSIVE_JOBS", "test_ci_signing_owned_mac", "ClassificationTests",
     "test_a_new_job_with_the_trait_and_no_entry_is_named", "test_a_listed_job_added_to_the_whole_tree_stays_green"),
    ("SIGNING_JOBS (signing_runner)", "test_ci_signing_owned_mac", "ClassificationTests",
     "test_an_unlisted_job_reading_its_secret_by_index_or_in_lowercase_is_named", None),
    ("GATED_SECRET_JOBS", HERE, "KeychainListFixtures", "test_gated_secret_jobs", None),
    ("TRUSTED_RUNNER_JOBS", "test_ci_fork_runner_routing", "ForkRunnerRoutingTests",
     "test_a_merge_gating_job_whose_header_carries_a_comment_is_checked",
     "test_a_listed_merge_gating_job_on_the_trusted_route_stays_green"),
    ("RELEASE_PUBLICATION_JOBS", "test_ci_fork_runner_routing", "ForkRunnerRoutingTests",
     "test_a_release_environment_from_a_matrix_or_an_unknown_expression_is_unclassified",
     "test_a_listed_release_job_with_a_matrix_environment_stays_green"),
    ("APP_JOBS", "test_publish_app_token_workflow", "WorkflowTests",
     "test_a_new_release_app_job_must_be_classified",
     "test_a_listed_release_app_job_reading_the_key_by_bracket_stays_green"),
    ("STEP_LEVEL_ONLY", HERE, "KeychainListFixtures", "test_step_level_only", None),
    ("INLINE_DEVELOPER_ID_KEYCHAINS", HERE, "KeychainListFixtures", "test_inline_developer_id_keychains", None),
    ("SCRIPT_MADE_KEYCHAINS (derived)", HERE, "KeychainListFixtures", "test_script_made_keychains", None),
    ("RELEASE_POOL_SIGNERS (derived)", HERE, "KeychainListFixtures", "test_release_pool_signers", None),
)


def run_fixture(module: str, cls: str, method: str) -> unittest.TestResult:
    case = getattr(sys.modules[module] if module == HERE else importlib.import_module(module), cls)(method)
    result = unittest.TestResult()
    unittest.TestSuite([case]).run(result)
    return result


def outcome(result: unittest.TestResult) -> str:
    problems = result.errors + result.failures
    if not problems:
        return "green"
    return "red: " + problems[0][1].strip().splitlines()[-1][:300]


class PreFixMutation(unittest.TestCase):
    def test_there_are_fifteen_fixtures(self) -> None:
        self.assertEqual(len({row[3] for row in FIXTURES}), 15)

    def test_each_fixture_is_green_with_the_shared_reader(self) -> None:
        for label, module, cls, red, green in FIXTURES:
            for method in filter(None, (red, green)):
                with self.subTest(list=label, fixture=method):
                    self.assertEqual(outcome(run_fixture(module, cls, method)), "green")

    def test_each_fixture_is_red_with_the_pre_fix_reader(self) -> None:
        for label, module, cls, red, _ in FIXTURES:
            with self.subTest(list=label, fixture=red):
                with PreFixReader.patched():
                    found = outcome(run_fixture(module, cls, red))
                print(f"pre-fix reader: {label}: {red}: {found}", file=sys.stderr)
                self.assertTrue(found.startswith("red"), f"{label}: {red} stays green with the pre-fix reader")

    def test_the_pre_fix_reader_is_the_one_described(self) -> None:
        self.assertEqual(PreFixReader.secret_names({"a": "${{ secrets.X }}", "b": "${{ secrets['Y'] }}"}), {"X"})
        self.assertEqual(PreFixReader.secret_names({"uses": "./x.yml", "secrets": "inherit"}), set())
        text = "on: push\njobs:\n  a:\n    runs-on: x\n  b: # note\n    runs-on: y\n  c:\n    runs-on: z\n"
        self.assertEqual(set(PreFixReader.jobs(text)), {"a", "c"})
        self.assertEqual(set(workflow_jobs.jobs(text)), {"a", "b", "c"})
        self.assertEqual(PreFixReader.environment_values({"environment": "${{ matrix.env }}"}), (set(), set()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
