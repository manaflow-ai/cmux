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
- runs-on: the raw string, one cell; `${{ matrix.runner }}` is not expanded.
- environment names: compared as written (`Release` is not `release`).
- check names: the `name:` as written (`${{ 'X' }}` is not `X`).
- a reusable workflow's `inputs.X`: unread; no caller's `with:` is traced.
- a job's secrets: its own mapping only; the workflow-level `env:` it inherits is not read.

One list's fix changed no reader: signing_runner.SIGNING_JOBS' cap classification (tests/test_ci_signing_owned_mac.py)
reads the owned pick with the same dotted() and NEEDS_OUTPUT it had before; what was missing was the classification
itself. Its pre-fix is that guard switched off (PRE_FIX_GUARDS: owned_pick_reads finds nothing), and its fixture must
go red with it, so the fixture is shown to need the guard.

The first 22 fixtures: 11 from the nightly, signing and routing groups (tests/test_nightly_trusted_routing.py,
tests/test_nightly_sign_runner.py, tests/test_seed_derived_data.py, tests/test_ci_signing_owned_mac.py,
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py's GATED_SECRET_JOBS,
tests/test_ci_fork_runner_routing.py, tests/test_publish_app_token_workflow.py) and the four keychain lists
(KeychainListFixtures below), and six for the readers' last gaps, one or more per field the resolve step reads: runs-on
(a matrix Linux control with issues: write, a matrix Mac job calling notarytool), env (a secret in the workflow-level
env), environment (a release environment in another case, for the release and App-token lists) and name (a required
check named by an expression, and a runner passed to a reusable workflow's input from the caller's matrix, in
bracket form). Secrets are the bracket, case and toJSON fixtures above. This branch merges the three list branches, so every module is importable here.

Six more (ResolverGaps) close the fail-opens review found after that: a guard that read runs-on raw (the keychain
rule on a signing matrix's Linux leg), a fromJSON matrix (a literal one read cell by cell, in the expression or in
the output a sibling step echoes; a computed one fails unless workflow_jobs.UNRESOLVED_MATRICES names why, where
guards used to fall back to the raw string), a job copy that dropped the workflow env (copy_job), and a
`secrets: inherit` call followed into the workflow it calls (or named when it cannot be). Where the fix is one new
reader, PRE_FIX_ONLY swaps back only that reader, so the fixture is shown to need exactly that fix. One more: a
keychain-making script only named as text (a step name, a comment, an env value) makes no keychain: 29 fixtures.
Two more (Codex, #40846 F2): a release-signer script, or `signing-keychain.sh create`, only named as text (a comment,
an echo or printf, a quoted string, a heredoc body) is no invocation; both read through the keychain guard's one
invocation detector (invocations()): 31 fixtures.

The SIGNING_JOBS cap fixture has no pre-fix reader to swap in: its fix added the classification and changed no
reader (the owned pick is read with the same dotted() and NEEDS_OUTPUT as before), so its only pre-fix is the guard
switched off. tests/test_ci_guards_read_through_workflow_jobs.py keeps every guard on these readers.
"""

from __future__ import annotations

import copy
import importlib
import json
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
    def runs_on_cells(job: Mapping[str, Any], *_: Any) -> list[str] | None:
        raw = job.get("runs-on")
        return [raw if isinstance(raw, str) else str(raw)] if raw else []

    @staticmethod
    def runs_on_values(job: Mapping[str, Any], *_: Any) -> tuple[set[str], set[str]]:
        raw = job.get("runs-on")
        return set(), ({raw if isinstance(raw, str) else str(raw)} if raw else set())

    @staticmethod
    def inheriting(document: Mapping[str, Any]) -> dict[str, Any]:
        return dict(document)

    @staticmethod
    def name_values(job: Mapping[str, Any], job_id: str, *_: Any) -> tuple[set[str], set[str]]:
        return {str(job.get("name", job_id))}, set()

    @staticmethod
    def environment_values(job: Mapping[str, Any], *_: Any) -> tuple[set[str], set[str]]:
        env = job.get("environment")
        if isinstance(env, Mapping):
            env = env.get("name")
        if not isinstance(env, str) or not env or "${{" in env:
            return set(), set()
        return {env.strip()}, set()

    @classmethod
    def patched(cls) -> ExitStack:
        stack = ExitStack()
        for name in ("secret_names", "document", "jobs", "environment_values", "runs_on_cells", "inheriting",
                     "name_values", "runs_on_values"):
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

    def test_script_made_keychains_need_an_invocation(self) -> None:
        """The same fixtures, for the text-only mentions: the pre-fix trait searched the whole job's text."""
        self.assertEqual(self.guard.script_made_fixture_failures(self.documents), [])

    def test_release_pool_signers(self) -> None:
        self.assertEqual(self.guard.release_pool_signer_fixture_failures(self.documents), [])

    def test_release_pool_signers_need_an_invocation(self) -> None:
        """A release-signer path in a comment, echo, printf, quoted string or heredoc body signs nothing."""
        self.assertEqual(self.guard.release_pool_signer_mention_fixture_failures(self.documents), [])

    def test_managed_keychains_need_an_invocation(self) -> None:
        """`signing-keychain.sh create` in a comment, echo or heredoc body makes no keychain."""
        self.assertEqual(self.guard.managed_keychain_mention_fixture_failures(self.documents), [])

    def test_gated_secret_jobs(self) -> None:
        self.assertEqual(self.guard.gated_secret_fixture_failures(self.documents), [])

    def test_the_lists_hold_against_the_workflows(self) -> None:
        failures: list[str] = []
        self.guard.check_keychain_lists(self.documents, failures)
        self.assertEqual(failures, [])


class ReusableInputTracing(unittest.TestCase):
    """A reusable workflow's `inputs.X` is its callers' `with: X:` values (workflow_jobs.Workflows), read in the
    caller job with its own matrix expanded per cell, at any call depth; bracket and dot forms are one reference.
    Built on every workflow document plus the fixture workflows. Codex's two repros on #40799 are the first two."""

    CALLEE = {"on": {"workflow_call": {"inputs": {"runner": {"type": "string"}}}},
              "jobs": {"build": {"runs-on": "${{ inputs.runner }}", "steps": [{"run": "true"}]}}}

    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = _documents()

    def _tree(self, caller_job: dict, callee: dict | None = None, **more: dict) -> workflow_jobs.Workflows:
        caller = {"on": "push", "jobs": {"call": workflow_jobs.copy_job({"uses": "./.github/workflows/callee-fixture.yml"}, caller_job)}}
        return workflow_jobs.Workflows({**self.documents, "caller-fixture.yml": caller,
                                        "callee-fixture.yml": callee or self.CALLEE, **more})

    def _callee_runs_on(self, tree: workflow_jobs.Workflows, callee: dict | None = None) -> tuple[set[str], set[str]]:
        job = (callee or self.CALLEE)["jobs"]["build"]
        return workflow_jobs.runs_on_values(job, "callee-fixture.yml", tree)

    def test_a_caller_matrix_runner_passed_as_an_input_resolves_to_what_it_reads(self) -> None:
        tree = self._tree({"strategy": {"matrix": {"runner": ["${{ vars.NEW_X }}"]}},
                           "with": {"runner": "${{ matrix.runner }}"}})
        self.assertEqual(self._callee_runs_on(tree), (set(), {"vars.NEW_X"}))
        self.assertEqual(workflow_jobs.runs_on_cells(self.CALLEE["jobs"]["build"], "callee-fixture.yml", tree),
                         ["${{ vars.NEW_X }}"])

    def test_the_bracket_forms_of_matrix_and_inputs_resolve_the_same(self) -> None:
        callee = {**self.CALLEE, "jobs": {"build": {"runs-on": "${{ inputs['runner'] }}", "steps": [{"run": "true"}]}}}
        tree = self._tree({"strategy": {"matrix": {"runner": ["${{ vars['NEW_X'] }}", "ubuntu-24.04"]}},
                           "with": {"runner": "${{ matrix['runner'] }}"}}, callee)
        self.assertEqual(self._callee_runs_on(tree, callee), ({"ubuntu-24.04"}, {"vars.NEW_X"}))

    def test_an_input_passed_on_through_a_second_call_resolves_at_the_first_caller(self) -> None:
        middle = {"on": {"workflow_call": {"inputs": {"runner": {"type": "string"}}}},
                  "jobs": {"call": {"uses": "./.github/workflows/callee-fixture.yml",
                                    "with": {"runner": "${{ inputs.runner }}"}}}}
        top = {"on": "push", "jobs": {"call": {"uses": "./.github/workflows/middle-fixture.yml",
                                               "with": {"runner": "${{ github.ref == 'refs/heads/main' && 'macos-26' || vars.Y }}"}}}}
        tree = workflow_jobs.Workflows({**self.documents, "callee-fixture.yml": self.CALLEE,
                                        "middle-fixture.yml": middle, "top-fixture.yml": top})
        self.assertEqual(self._callee_runs_on(tree), ({"macos-26"}, {"vars.Y"}))

    def test_an_input_nothing_passes_stays_unresolved(self) -> None:
        tree = workflow_jobs.Workflows({**self.documents, "callee-fixture.yml": self.CALLEE})
        self.assertEqual(self._callee_runs_on(tree), (set(), {"inputs.runner"}))
        cycle = {"on": {"workflow_call": {"inputs": {"runner": {"type": "string"}}}},
                 "jobs": {"build": {"runs-on": "${{ inputs.runner }}"},
                          "call": {"uses": "./.github/workflows/cycle-fixture.yml", "with": {"runner": "${{ inputs.runner }}"}}}}
        tree = workflow_jobs.Workflows({**self.documents, "cycle-fixture.yml": cycle})
        self.assertEqual(workflow_jobs.runs_on_values(cycle["jobs"]["build"], "cycle-fixture.yml", tree),
                         (set(), {"inputs.runner"}))


class EffectiveEnv(unittest.TestCase):
    """effective_env merges as #40829's copy does (workflow, then job, then step, inner wins); repo_path reads
    the workspace forms as the repo root."""

    def test_the_inner_env_wins_a_key(self) -> None:
        doc, job, step = {"env": {"A": "1", "P": "w"}}, {"env": {"P": "${{ github.workspace }}/scripts/ci"}}, {"env": {"A": "2"}}
        self.assertEqual(workflow_jobs.effective_env(doc, job, step),
                         {"A": "2", "P": "${{ github.workspace }}/scripts/ci"})
        self.assertEqual(workflow_jobs.effective_env(doc, job), {"A": "1", "P": "${{ github.workspace }}/scripts/ci"})

    def test_the_workspace_forms_are_the_repo_root(self) -> None:
        for value in ("${{ github.workspace }}", "$GITHUB_WORKSPACE", "${GITHUB_WORKSPACE}/"):
            self.assertEqual(workflow_jobs.repo_path(value), ".", value)
        self.assertEqual(workflow_jobs.repo_path("${{ github.workspace }}/scripts/ci"), "scripts/ci")
        for value in ("/opt/x", "$HOME/x", "${{ env.X }}", "$GITHUB_WORKSPACEX"):
            self.assertIsNone(workflow_jobs.repo_path(value), value)


class ResolverGaps(unittest.TestCase):
    """The four fail-opens the resolve step closed after review, one guard fixture each (rows in FIXTURES):
    a raw runs-on read (the keychain guard read `${{ matrix.runner }}` as one string), a fromJSON matrix (read as the
    raw string, or skipped), a job copy that dropped the workflow env, and a `secrets: inherit` nothing followed."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = _documents()
        cls.keychain = importlib.import_module(KEYCHAIN)
        cls.routing = importlib.import_module("test_nightly_trusted_routing")
        cls.overflow = importlib.import_module("test_ci_overflow_pick_reads_pool")

    def test_a_signing_job_whose_matrix_linux_leg_reads_a_runner_variable_first_is_named(self) -> None:
        """Rule 4 per matrix cell: the Linux leg of a signing matrix may not pick its runner from vars.LINUX_RUNNER
        before an ephemeral label. Read as the raw `${{ matrix.runner }}`, the leg had no variable to check."""
        job = {"runs-on": "${{ matrix.runner }}",
               "strategy": {"matrix": {"runner": [
                   "macos-26", "${{ vars.LINUX_RUNNER && vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"]}},
               "steps": [{"run": "sign", "env": {"K": "${{ secrets['APPLE_CERTIFICATE_PASSWORD'] }}"}}]}
        failures: list[str] = []
        self.keychain.check_job("matrix-fixture.yml sign", job, failures)
        self.assertIn("matrix-fixture.yml sign: holds a signing secret and reads vars.LINUX_RUNNER other than as the "
                      "expression's last choice `vars.NAME || '<blacksmith-* or ubuntu-* label>' }}`", failures)

    def _control_doc(self, matrix: str, producer: dict | None = None) -> dict:
        doc = copy.deepcopy(self.routing.DOC)
        if producer is not None:
            doc["jobs"]["json-plan-fixture"] = producer
        doc["jobs"]["json-control-fixture-nightly"] = {
            "runs-on": "${{ matrix.runner }}", "strategy": {"matrix": matrix},
            "needs": ["json-plan-fixture"] if producer is not None else [],
            "permissions": {"issues": "write"}, "steps": [{"run": "true"}]}
        return doc

    @staticmethod
    def _literal(runners: list[str]) -> str:
        return "${{ fromJSON('" + json.dumps({"runner": runners}).replace("'", "''") + "') }}"

    @staticmethod
    def _producer(runners: list[str]) -> dict:
        text = json.dumps({"runner": runners})
        return {"runs-on": "macos-26", "outputs": {"matrix": "${{ steps.plan.outputs.matrix }}"},
                "steps": [{"id": "plan", "run": f"echo 'matrix={text}' >> \"$GITHUB_OUTPUT\""}]}

    def test_a_control_whose_matrix_is_literal_json_is_checked_per_cell(self) -> None:
        """A `fromJSON` matrix of a literal, in the expression or in the output a sibling step echoes, is read cell
        by cell: a Blacksmith leg of a credentialed control fails on its route, not as a matrix nothing resolves."""
        for form, doc in (
                ("literal", self._control_doc(self._literal(["blacksmith-4vcpu-ubuntu-2404"]))),
                ("needs output", self._control_doc("${{ fromJSON(needs.json-plan-fixture.outputs.matrix) }}",
                                                   self._producer(["blacksmith-4vcpu-ubuntu-2404"])))):
            with self.subTest(form=form):
                self.assertEqual(self.routing.control_route_failures(doc).get("json-control-fixture-nightly"),
                                 "runs-on reads blacksmith")

    def test_a_literal_json_matrix_control_on_the_nightly_pool_stays_green(self) -> None:
        pool = self.routing.runs_on_text(self.routing.DOC["jobs"]["published-in"], "published-in")
        doc = self._control_doc(self._literal([pool]))
        self.assertIn("json-control-fixture-nightly", self.routing.credentialed_control_jobs(doc))
        self.assertEqual(self.routing.control_route_failures(doc), {})

    def test_an_unaudited_matrix_nothing_resolves_fails_the_size_guard(self) -> None:
        """A computed fromJSON matrix fails an all-workflow guard unless UNRESOLVED_MATRICES names why; the guard
        read the runs-on as written before, where `${{ matrix.runner }}` picks no size and passed."""
        job = {"runs-on": "${{ matrix.runner }}", "needs": "plan",
               "strategy": {"matrix": "${{ fromJSON(needs.plan.outputs.matrix) }}"}, "steps": [{"run": "true"}]}
        with self.assertRaisesRegex(AssertionError, "UNRESOLVED_MATRICES"):
            self.overflow.job_picks_one_size(job, "matrix-fixture.yml", "build")
        self.assertFalse(self.overflow.job_picks_one_size(job, "seed-derived-data.yml", "seed"))

    def test_a_copied_job_keeps_its_workflow_env_secret(self) -> None:
        """Rule 6 reads each job through inline_step_scripts, a copy: the copy keeps the workflow env the job
        inherits (copy_job), so a release secret set there still makes the job's bundle code a failure."""
        workflow = workflow_jobs.inheriting({
            "on": "push", "env": {"CERT": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"},
            "jobs": {"copy-env-fixture": {"runs-on": "ubuntu-24.04",
                                          "steps": [{"name": "Smoke", "run": "scripts/ci/smoke-dmg.sh build/x.dmg"}]}}})
        found = self.keychain.step_level_classification({**self.documents, "copy-env-fixture.yml": workflow})
        named = [why for why in found if why.startswith("copy-env-fixture.yml copy-env-fixture:")]
        self.assertTrue(named and all("runs bundle code in a job that holds secrets" in why for why in named), found)

    def test_a_nested_secrets_inherit_is_followed_or_unresolved(self) -> None:
        """`secrets: inherit` hands a called workflow every secret; the resolve step follows the call (and the
        called workflow's own inherited calls) to what is read there, and names a call it cannot follow."""
        callee = {"on": {"workflow_call": {}}, "jobs": {"sign": {"runs-on": "macos-26", "steps": [
            {"run": "sign", "env": {"K": "${{ secrets['NIGHTLY_SPARKLE_PRIVATE_KEY'] }}"}}]}}}
        middle = {"on": {"workflow_call": {}}, "jobs": {"call": {"uses": "./.github/workflows/callee.yml",
                                                                 "secrets": "inherit"}}}
        cycle = {"on": {"workflow_call": {}}, "jobs": {"again": {"uses": "./.github/workflows/cycle.yml",
                                                                 "secrets": "inherit"}}}
        tree = workflow_jobs.Workflows({"middle.yml": middle, "callee.yml": callee, "cycle.yml": cycle})
        top = {"uses": "./.github/workflows/middle.yml", "secrets": "inherit"}
        resolved = workflow_jobs.resolve(top, "call", "top.yml", tree)
        self.assertEqual(resolved.secrets, {workflow_jobs.ALL_SECRETS, "NIGHTLY_SPARKLE_PRIVATE_KEY"})
        self.assertEqual(resolved.secrets_unresolved, set())
        for job, unresolved in (({"uses": "other/repo/.github/workflows/x.yml@v1", "secrets": "inherit"},
                                 {"other/repo/.github/workflows/x.yml@v1"}),
                                ({"uses": "./.github/workflows/cycle.yml", "secrets": "inherit"},
                                 {"./.github/workflows/cycle.yml"})):
            with self.subTest(uses=job["uses"]):
                found = workflow_jobs.resolve(job, "call", "top.yml", tree)
                self.assertEqual(found.secrets_unresolved, unresolved)
                self.assertTrue(found.unresolved)


HERE = __name__
# Fixtures whose fix added a guard rather than changed a reader: the guard as it was before (absent), per list.
PRE_FIX_GUARDS = {
    "SIGNING_JOBS (signing_runner)": (("test_ci_signing_owned_mac", "owned_pick_reads", lambda jobs, runs_on: []),),
}


def _matrix_as_written(job: Mapping[str, Any]) -> Mapping[str, Any] | None:
    """The matrix reader before fromJSON literals were read: a mapping as written, else nothing."""
    strategy = job.get("strategy")
    matrix = strategy.get("matrix") if isinstance(strategy, Mapping) else None
    return matrix if isinstance(matrix, Mapping) else None


def _plain_copy(job: Mapping[str, Any], changes: Mapping[str, Any] | None = None) -> dict:
    """A job copy before copy_job: `{**job, **changes}`, a plain dict without the workflow env the job inherits."""
    out = {**job}
    for key, value in (changes or {}).items():
        if value is workflow_jobs.DROP:
            out.pop(key, None)
        else:
            out[key] = value
    return out


# Fixtures whose fix is one reader among the new ones: only that reader is swapped back (the rest stay current), so
# the fixture is shown to need exactly that fix.
PRE_FIX_ONLY = {
    "copy_job (a copied job keeps the workflow env)": (("workflow_jobs", "copy_job", _plain_copy),),
    "fromJSON literal matrix (a control on the nightly pool)": (("workflow_jobs", "_matrix", _matrix_as_written),),
    "SCRIPT_MADE_KEYCHAINS (a mention is no invocation)": (
        (KEYCHAIN, "script_made_keychain", lambda job: next(
            (script for script in importlib.import_module(KEYCHAIN).KEYCHAIN_MAKING_SCRIPTS if script in json.dumps(job)),
            None)),),
    # Codex, #40846 F2: the pre-fix readers matched the script path anywhere in the step's or the job's text.
    "RELEASE_POOL_SIGNERS (a mention is no invocation)": (
        (KEYCHAIN, "release_pool_signer", lambda job: min(
            {path for step in job.get("steps") or [] if isinstance(step, dict)
             and workflow_jobs.reads_secret(step, "APPLE_CERTIFICATE_BASE64")
             for path in importlib.import_module(KEYCHAIN).RELEASE_SIGNER_SCRIPT.findall(str(step.get("run", "")))},
            default=None)),),
    "MANAGED_KEYCHAINS (a mention is no invocation)": (
        (KEYCHAIN, "makes_managed_keychain", lambda job: "signing-keychain.sh create" in json.dumps(job)),),
    "secrets: inherit (followed into the called workflow)": (
        ("workflow_jobs", "effective_secrets", lambda job, workflows=None, _seen=frozenset(): (
            workflow_jobs.secret_names(job), set())),),
}
# (list, module, class, the fixture that must name an unlisted job, its listed-and-green twin or None). Where a list
# has a dot-form fixture too (test_a_new_job_with_the_trait_and_no_entry_is_named), the one here is its bracket,
# case or index twin: the dot form is caught by both readers, so it cannot tell them apart.
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
     "test_an_unlisted_job_reading_its_secret_by_index_or_in_lowercase_is_named",
     "test_a_listed_job_added_to_the_whole_tree_stays_green"),
    ("SIGNING_JOBS (signing_runner)", "test_ci_signing_owned_mac", "ClassificationTests",
     "test_an_unlisted_job_reading_the_owned_pick_and_its_secrets_by_index_is_named", None),
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
    ("CREDENTIALED_CONTROL_JOBS (matrix runner)", "test_nightly_trusted_routing", "CredentialedControls",
     "test_a_credentialed_control_whose_runner_comes_from_its_matrix_fails",
     "test_a_matrix_control_on_the_nightly_pool_stays_green"),
    ("SIGNING_MATERIAL_UNPICKED (matrix runner)", "test_nightly_sign_runner", "Workflow",
     "test_a_mac_job_whose_runner_comes_from_its_matrix_is_named", "test_a_named_matrix_mac_job_stays_green"),
    ("GLAEDA_EXCLUSIVE_JOBS (workflow env)", "test_ci_signing_owned_mac", "ClassificationTests",
     "test_an_unlisted_job_inheriting_a_workflow_env_secret_is_named",
     "test_a_listed_job_inheriting_a_workflow_env_secret_stays_green"),
    ("TRUSTED_RUNNER_JOBS (name expression)", "test_ci_fork_runner_routing", "ForkRunnerRoutingTests",
     "test_a_merge_gating_job_whose_name_is_an_expression_is_checked",
     "test_a_merge_gating_job_named_by_an_expression_on_the_trusted_route_stays_green"),
    ("RELEASE_PUBLICATION_JOBS (environment case)", "test_ci_fork_runner_routing", "ForkRunnerRoutingTests",
     "test_a_release_environment_in_another_case_is_unclassified",
     "test_a_listed_release_job_in_another_case_stays_green"),
    ("APP_JOBS (environment case)", "test_publish_app_token_workflow", "WorkflowTests",
     "test_a_release_app_job_whose_environment_differs_in_case_must_be_classified",
     "test_a_listed_release_app_job_in_another_case_stays_green"),
    ("runs-on through a reusable workflow's input (bracket forms)", HERE, "ReusableInputTracing",
     "test_the_bracket_forms_of_matrix_and_inputs_resolve_the_same",
     "test_a_caller_matrix_runner_passed_as_an_input_resolves_to_what_it_reads"),
    ("STEP_LEVEL_ONLY", HERE, "KeychainListFixtures", "test_step_level_only", None),
    ("INLINE_DEVELOPER_ID_KEYCHAINS", HERE, "KeychainListFixtures", "test_inline_developer_id_keychains", None),
    ("SCRIPT_MADE_KEYCHAINS (derived)", HERE, "KeychainListFixtures", "test_script_made_keychains", None),
    ("RELEASE_POOL_SIGNERS (derived)", HERE, "KeychainListFixtures", "test_release_pool_signers", None),
    ("SCRIPT_MADE_KEYCHAINS (a mention is no invocation)", HERE, "KeychainListFixtures",
     "test_script_made_keychains_need_an_invocation", None),
    ("RELEASE_POOL_SIGNERS (a mention is no invocation)", HERE, "KeychainListFixtures",
     "test_release_pool_signers_need_an_invocation", None),
    ("MANAGED_KEYCHAINS (a mention is no invocation)", HERE, "KeychainListFixtures",
     "test_managed_keychains_need_an_invocation", None),
    ("runs-on per matrix cell (keychain rule 4)", HERE, "ResolverGaps",
     "test_a_signing_job_whose_matrix_linux_leg_reads_a_runner_variable_first_is_named", None),
    ("fromJSON literal matrix (a credentialed control)", HERE, "ResolverGaps",
     "test_a_control_whose_matrix_is_literal_json_is_checked_per_cell", None),
    ("fromJSON literal matrix (a control on the nightly pool)", HERE, "ResolverGaps",
     "test_a_literal_json_matrix_control_on_the_nightly_pool_stays_green", None),
    ("fromJSON matrix nothing resolves (no raw fallback)", HERE, "ResolverGaps",
     "test_an_unaudited_matrix_nothing_resolves_fails_the_size_guard", None),
    ("copy_job (a copied job keeps the workflow env)", HERE, "ResolverGaps",
     "test_a_copied_job_keeps_its_workflow_env_secret", None),
    ("secrets: inherit (followed into the called workflow)", HERE, "ResolverGaps",
     "test_a_nested_secrets_inherit_is_followed_or_unresolved", None),
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
    def test_there_are_thirty_one_fixtures(self) -> None:
        self.assertEqual(len({row[3] for row in FIXTURES}), 31)
        self.assertLessEqual(set(PRE_FIX_ONLY), {row[0] for row in FIXTURES})

    def test_each_fixture_is_green_with_the_shared_reader(self) -> None:
        for label, module, cls, red, green in FIXTURES:
            for method in filter(None, (red, green)):
                with self.subTest(list=label, fixture=method):
                    self.assertEqual(outcome(run_fixture(module, cls, method)), "green")

    def test_each_fixture_is_red_with_the_pre_fix_reader(self) -> None:
        for label, module, cls, red, _ in FIXTURES:
            with self.subTest(list=label, fixture=red):
                with (ExitStack() if label in PRE_FIX_ONLY else PreFixReader.patched()) as stack:
                    for owner, name, old in (*PRE_FIX_GUARDS.get(label, ()), *PRE_FIX_ONLY.get(label, ())):
                        stack.enter_context(mock.patch.object(importlib.import_module(owner), name, old))
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
        matrix = {"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"runner": ["macos-26", "ubuntu-24.04"]}}}
        self.assertEqual(PreFixReader.runs_on_cells(matrix), ["${{ matrix.runner }}"])
        self.assertEqual(workflow_jobs.runs_on_cells(matrix), ["macos-26", "ubuntu-24.04"])
        self.assertIsNone(workflow_jobs.runs_on_cells({**matrix, "strategy": {"matrix": "${{ fromJSON(x) }}"}}))
        inherited = workflow_jobs.inheriting({"env": {"K": "${{ secrets.S }}"}, "jobs": {"a": {"steps": []}}})
        self.assertEqual(workflow_jobs.secret_names(inherited["jobs"]["a"]), {"S"})
        self.assertEqual(PreFixReader.secret_names(inherited["jobs"]["a"]), set())


if __name__ == "__main__":
    unittest.main(verbosity=2)
