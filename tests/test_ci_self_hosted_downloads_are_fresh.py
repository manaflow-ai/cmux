#!/usr/bin/env python3
"""A job on a self-hosted selector downloads into a directory nothing earlier left behind.

The self-hosted Linux selectors (vars.LINUX_RUNNER, the RUNNER_POOLS pools, self-hosted) hand a job a
persistent worker: its workspace survives from one job to the next. A job that downloads an artifact into a
relative directory (`path: dist`) and never checks out first finds whatever an earlier job left there, so an
exact-files check fails on a stale file, or a publish step ships it. Only these places are fresh:

- the runner's temp directory (`${{ runner.temp }}/...`, emptied by the runner before each job);
- a directory a step created for the job (`${{ steps.<id>.outputs.<name> }}`);
- a workspace directory an earlier `actions/checkout` of the job cleaned (its default clean removes untracked
  files under its `path`, the workspace when it has none), unless `clean: false`. Only a checkout that runs
  whenever the download does counts: one with no `if:`, or the download's own `if:`, and no `continue-on-error`.
  A checkout into `path: tooling` cleans `tooling`, not `dist`.

Every download-artifact step of a job on a self-hosted selector must write to one of them. Hosted and Blacksmith
runners are one-shot VMs and are not held to this.

The other side of that move (#40846 F2): a container action (`uses: docker://...`, a local action whose action.yml
says `runs.using: docker`, or a remote one in KNOWN_CONTAINER_ACTIONS) mounts the workspace but not the runner's
temp directory, so no container action reads a runner.temp path in its `with:` or `env:`. Stage what it reads in a
workspace directory the job empties first. Run: python3 tests/test_ci_self_hosted_downloads_are_fresh.py
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path
from typing import Any, Mapping
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
SELF_HOSTED = re.compile(r"vars\.|RUNNER_POOLS|self-hosted", re.IGNORECASE)
FRESH_PATH = re.compile(r"^\$\{\{\s*(runner\.temp|steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+)\s*\}\}")


def on_self_hosted_selector(job: Mapping[str, Any]) -> bool:
    return bool(SELF_HOSTED.search(workflow_jobs.runs_on(job)))


def stale_downloads(job: Mapping[str, Any]) -> list[str]:
    """The download-artifact steps of one job whose output directory can hold an earlier job's files."""
    found = []
    cleaned = False
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        uses = str(step.get("uses", ""))
        options = step.get("with") if isinstance(step.get("with"), dict) else {}
        if uses.startswith("actions/checkout"):
            cleaned = str(options.get("clean", "true")).lower() != "false"
        elif uses.startswith("actions/download-artifact"):
            path = str(options.get("path", "")).strip()
            if not FRESH_PATH.match(path) and not cleaned:
                found.append(f"{step.get('name') or uses}: path {path or '(the workspace)'!r}")
    return found


def problems(documents: Mapping[str, Mapping[str, Any]]) -> list[str]:
    found = []
    for workflow, document in documents.items():
        for name, job in workflow_jobs.jobs(document).items():
            if on_self_hosted_selector(job):
                found += [f"{workflow} {name}: {why}" for why in stale_downloads(job)]
    return found


# Remote actions that run in a container, which this test cannot read. Add one when a workflow starts using it.
# pypa/gh-action-pypi-publish is a composite action whose one real step is a generated Docker action.
KNOWN_CONTAINER_ACTIONS = frozenset({"pypa/gh-action-pypi-publish"})
RUNNER_TEMP = re.compile(r"runner\.temp|RUNNER_TEMP")
ACTIONS = ROOT / ".github/actions"


def local_action_runs_in_a_container(uses: str) -> bool:
    directory = (ROOT / uses).resolve()
    for name in ("action.yml", "action.yaml"):
        manifest = directory / name
        if manifest.is_file():
            runs = (workflow_jobs.document(manifest) or {}).get("runs") or {}
            return str(runs.get("using", "")).strip().lower() == "docker"
    return False


def container_action(uses: str) -> bool:
    uses = uses.strip()
    if uses.startswith("docker://"):
        return True
    if uses.startswith("./"):
        return local_action_runs_in_a_container(uses)
    return uses.split("@", 1)[0].lower() in KNOWN_CONTAINER_ACTIONS


def strings(value: Any) -> list[str]:
    if isinstance(value, Mapping):
        return [text for item in value.values() for text in strings(item)]
    if isinstance(value, list):
        return [text for item in value for text in strings(item)]
    return [str(value)]


def container_temp_reads(steps: Any) -> list[str]:
    """The container-action steps whose `with:` or `env:` names a runner.temp path."""
    found = []
    for step in steps or []:
        if not isinstance(step, dict) or not container_action(str(step.get("uses", ""))):
            continue
        for field in ("with", "env"):
            for text in strings(step.get(field) or {}):
                if RUNNER_TEMP.search(text):
                    found.append(f"{step.get('name') or step.get('uses')}: {field} reads {text.strip()!r}")
    return found


def container_problems(documents: Mapping[str, Mapping[str, Any]],
                       actions: Mapping[str, Mapping[str, Any]] | None = None) -> list[str]:
    found = []
    for workflow, document in documents.items():
        for name, job in workflow_jobs.jobs(document).items():
            found += [f"{workflow} {name}: {why}" for why in container_temp_reads(job.get("steps"))]
    for action, document in (actions or {}).items():
        found += [f"{action}: {why}" for why in container_temp_reads((document.get("runs") or {}).get("steps"))]
    return found


def load_actions() -> dict[str, dict]:
    return {str(path.relative_to(ROOT)): workflow_jobs.document(path)
            for path in sorted([*ACTIONS.glob("*/action.yml"), *ACTIONS.glob("*/action.yaml")])}


def load_all() -> dict[str, dict]:
    return {path.name: workflow_jobs.document(path) for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def fixture(runs_on: str, steps: list[dict]) -> dict:
    return {"jobs": {"j": {"runs-on": runs_on, "steps": steps}}}


POOL = "${{ vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_4 }}"
DOWNLOAD = "actions/download-artifact@v4"
CHECKOUT = "actions/checkout@v6"


class SelfHostedDownloads(unittest.TestCase):
    def test_the_checked_in_workflows_download_into_fresh_directories(self) -> None:
        found = problems(load_all())
        self.assertEqual(found, [], "a self-hosted job downloads into a directory an earlier job may have used; "
                         "use ${{ runner.temp }}/<name> (see this file's docstring):\n  " + "\n  ".join(found))

    def test_a_relative_download_on_a_pool_runner_is_named(self) -> None:
        for path in ("dist", "./dist", "${{ github.workspace }}/dist", ""):
            with self.subTest(path=path):
                document = fixture(POOL, [{"uses": DOWNLOAD, "with": {"name": "a", "path": path}}])
                self.assertEqual(len(problems({"w.yml": document})), 1)

    def test_a_download_under_the_runner_temp_or_a_step_made_directory_passes(self) -> None:
        for path in ("${{ runner.temp }}/linux-build", "${{ steps.fresh.outputs.dir }}"):
            with self.subTest(path=path):
                document = fixture(POOL, [{"uses": DOWNLOAD, "with": {"name": "a", "path": path}}])
                self.assertEqual(problems({"w.yml": document}), [])

    def test_a_checkout_before_the_download_cleans_the_workspace(self) -> None:
        steps = [{"uses": CHECKOUT}, {"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}]
        self.assertEqual(problems({"w.yml": fixture(POOL, steps)}), [])
        after = [steps[1], steps[0]]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, after)})), 1)
        kept = [{"uses": CHECKOUT, "with": {"clean": False}}, steps[1]]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, kept)})), 1)

    def test_only_the_directory_a_checkout_cleaned_is_fresh(self) -> None:
        # #40846 F3: a checkout into `tooling` leaves the workspace's `dist` as an earlier job left it.
        download = {"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}
        tooling = {"uses": CHECKOUT, "with": {"path": "tooling"}}
        self.assertEqual(len(problems({"w.yml": fixture(POOL, [tooling, download])})), 1)
        inside = {"uses": DOWNLOAD, "with": {"name": "a", "path": "tooling/dist"}}
        self.assertEqual(problems({"w.yml": fixture(POOL, [tooling, inside])}), [])
        for root in ("", ".", "./", "${{ github.workspace }}"):
            with self.subTest(root=root):
                checkout = {"uses": CHECKOUT, "with": {"path": root}}
                self.assertEqual(problems({"w.yml": fixture(POOL, [checkout, download])}), [])
        prefixed = {"uses": DOWNLOAD, "with": {"name": "a", "path": "${{ github.workspace }}/dist"}}
        self.assertEqual(problems({"w.yml": fixture(POOL, [{"uses": CHECKOUT}, prefixed])}), [])
        escaped = {"uses": DOWNLOAD, "with": {"name": "a", "path": "tooling/../dist"}}
        self.assertEqual(len(problems({"w.yml": fixture(POOL, [tooling, escaped])})), 1)

    def test_only_a_checkout_that_runs_with_the_download_cleans(self) -> None:
        download = {"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}
        skipped = {"uses": CHECKOUT, "if": "github.event_name == 'push'"}
        self.assertEqual(len(problems({"w.yml": fixture(POOL, [skipped, download])})), 1)
        same = dict(download, **{"if": "github.event_name  ==  'push'"})
        self.assertEqual(problems({"w.yml": fixture(POOL, [skipped, same])}), [])
        may_fail = {"uses": CHECKOUT, "continue-on-error": True}
        self.assertEqual(len(problems({"w.yml": fixture(POOL, [may_fail, download])})), 1)
        maybe_clean = {"uses": CHECKOUT, "with": {"clean": "${{ inputs.clean }}"}}
        self.assertEqual(len(problems({"w.yml": fixture(POOL, [maybe_clean, download])})), 1)

    def test_a_one_shot_runner_is_not_held_to_it(self) -> None:
        for runs_on in ("ubuntu-24.04", "blacksmith-4vcpu-ubuntu-2404"):
            document = fixture(runs_on, [{"uses": DOWNLOAD, "with": {"name": "a", "path": "dist"}}])
            self.assertEqual(problems({"w.yml": document}), [])

    def test_every_download_of_a_job_is_checked(self) -> None:
        steps = [{"uses": DOWNLOAD, "with": {"name": "a", "path": "${{ runner.temp }}/a"}},
                 {"uses": DOWNLOAD, "with": {"name": "b", "path": "b"}}]
        self.assertEqual(len(problems({"w.yml": fixture(POOL, steps)})), 1)



class ContainerActions(unittest.TestCase):
    def test_no_container_action_reads_the_runner_temp_directory(self) -> None:
        found = container_problems(load_all(), load_actions())
        self.assertEqual(found, [], "a container action cannot see ${{ runner.temp }} (only the workspace is "
                         "mounted); stage its input in a cleaned workspace directory:\n  " + "\n  ".join(found))

    def test_a_known_or_docker_url_action_reading_runner_temp_is_named(self) -> None:
        for uses in ("pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b",
                     "docker://alpine:3.20"):
            for field, value in (("with", {"packages-dir": "${{ runner.temp }}/dist"}),
                                 ("env", {"DIST": "${{runner.temp}}/dist"}),
                                 ("with", {"args": "ls $RUNNER_TEMP/dist"})):
                with self.subTest(uses=uses, field=field):
                    document = fixture(POOL, [{"uses": uses, field: value}])
                    self.assertEqual(len(container_problems({"w.yml": document})), 1)

    def test_a_workspace_path_or_a_host_action_passes(self) -> None:
        document = fixture(POOL, [{"uses": "pypa/gh-action-pypi-publish@v1", "with": {"packages-dir": "dist"}},
                                  {"uses": "actions/attest-build-provenance@v4",
                                   "with": {"subject-path": "${{ runner.temp }}/dist/*.tar.gz"}}])
        self.assertEqual(container_problems({"w.yml": document}), [])

    def test_a_local_docker_action_is_read_from_its_manifest(self) -> None:
        with mock.patch.object(sys.modules[__name__], "local_action_runs_in_a_container",
                               side_effect=lambda uses: uses == "./.github/actions/in-docker"):
            for uses, count in (("./.github/actions/in-docker", 1), ("./.github/actions/composite", 0)):
                with self.subTest(uses=uses):
                    document = fixture(POOL, [{"uses": uses, "with": {"dir": "${{ runner.temp }}/x"}}])
                    self.assertEqual(len(container_problems({"w.yml": document})), count)
        self.assertFalse(local_action_runs_in_a_container("./.github/actions/runner-cargo-home"))

    def test_a_composite_action_step_is_checked(self) -> None:
        action = {"runs": {"using": "composite", "steps": [
            {"uses": "docker://alpine:3.20", "env": {"D": "${{ runner.temp }}"}}]}}
        self.assertEqual(len(container_problems({}, {".github/actions/x/action.yml": action})), 1)


if __name__ == "__main__":
    unittest.main()
