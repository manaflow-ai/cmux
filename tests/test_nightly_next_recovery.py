#!/usr/bin/env python3
"""The next nightly-next run continues a pending notarization from an earlier run.

nightly.yml hands a submission that is still in Apple's queue to later runs as
a recovery artifact. find-nightly-next-recovery.py lists the newer pending
ones, recover-nightly-next-notarization polls them and staples the newest
Accepted one, and publish-nightly publishes it only when this run's own build
was not Accepted. A recovered build must stay above every build on both feeds,
as every nightly-next publication must.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
FINDER = ROOT / "scripts/ci/find-nightly-next-recovery.py"
REPO = "manaflow-ai/cmux"


def feed(path: Path, *builds: int) -> str:
    items = "".join(
        f'<item><enclosure sparkle:version="{b}" url="https://example.invalid/{b}.dmg"/></item>' for b in builds
    )
    path.write_text(
        '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f"<channel>{items}</channel></rss>"
    )
    return str(path)


def run(run_id: int, **overrides) -> dict:
    value = {
        "id": run_id,
        "run_attempt": 1,
        "head_branch": "nightly-next",
        "head_sha": f"{run_id:040x}",
        "event": "push",
        "status": "completed",
        "path": ".github/workflows/nightly.yml",
        "head_repository": {"full_name": REPO},
    }
    value.update(overrides)
    return value


def artifacts(*names_expired: tuple[str, bool]) -> dict:
    return {"artifacts": [{"name": n, "expired": e} for n, e in names_expired]}


def find(runs: list[dict], run_artifacts: dict[int, dict], feeds: list[str], current: int = 500, limit: int = 3):
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        responses = {f"repos/{REPO}/actions/workflows/nightly.yml/runs": {"workflow_runs": runs}}
        for run_id, value in run_artifacts.items():
            responses[f"repos/{REPO}/actions/runs/{run_id}/artifacts"] = value
        (temp_path / "responses.json").write_text(json.dumps(responses))
        bin_dir = temp_path / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            f"responses = json.load(open({str(temp_path / 'responses.json')!r}))\n"
            "assert sys.argv[1] == 'api', sys.argv\n"
            "path = sys.argv[2].split('?')[0]\n"
            "if path not in responses:\n"
            "    sys.exit(f'unexpected gh api {sys.argv[2]}')\n"
            "print(json.dumps(responses[path]))\n"
        )
        gh.chmod(0o755)
        args = [sys.executable, str(FINDER), "--repo", REPO, "--current-run-id", str(current), "--limit", str(limit)]
        for source in feeds:
            args += ["--feed", source]
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
        return subprocess.run(args, env=env, capture_output=True, text=True)


RECOVERY = "cmux-nightly-notarization-recovery-arm64-"


class FinderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_lists_newer_live_pending_runs_newest_first(self):
        feeds = [feed(self.dir / "next.xml", 49401), feed(self.dir / "main.xml", 49601)]
        runs = [
            run(501),  # newer than this run
            run(499),  # published in-job: no recovery artifact
            run(498),
            run(497),  # its recovery artifact expired
            run(496),  # not above main's feed: neither it nor anything older
            run(495),
            run(493, head_branch="feat-cmux-next"),
            run(492, event="pull_request"),
            run(491, head_repository={"full_name": "fork/cmux"}),
        ]
        run_artifacts = {
            499: artifacts(("cmux-nightly-remote-daemon", False)),
            498: artifacts((RECOVERY + "aaaaaaa", False)),
            497: artifacts((RECOVERY + "bbbbbbb", True)),
            496: artifacts((RECOVERY + "ccccccc", False)),
            495: artifacts((RECOVERY + "ddddddd", False)),
        }
        result = find(runs, run_artifacts, feeds)
        self.assertEqual(result.returncode, 0, result.stderr)
        found = json.loads(result.stdout)
        self.assertEqual(
            found,
            [{"run_id": 498, "run_attempt": 1, "build": "49801", "head_sha": f"{498:040x}", "artifact": RECOVERY + "aaaaaaa"}],
        )

    def test_limit_keeps_the_newest(self):
        feeds = [feed(self.dir / "next.xml", 1)]
        runs = [run(499), run(498), run(497)]
        run_artifacts = {n: artifacts((RECOVERY + f"{n:07d}", False)) for n in (499, 498, 497)}
        result = find(runs, run_artifacts, feeds, limit=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["run_id"] for c in json.loads(result.stdout)], [499, 498])

    def test_attempt_is_part_of_the_build(self):
        feeds = [feed(self.dir / "next.xml", 1)]
        result = find([run(499, run_attempt=2)], {499: artifacts((RECOVERY + "a", False))}, feeds)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["build"], "49902")

    def test_unreadable_feed_fails_closed(self):
        result = find([run(499)], {499: artifacts((RECOVERY + "a", False))}, [str(self.dir / "missing.xml")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read feed", result.stderr)

    def test_nothing_pending_is_an_empty_list(self):
        result = find([run(499)], {499: artifacts()}, [feed(self.dir / "next.xml", 1)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


def run_select(**env: str) -> dict[str, str]:
    job = workflow()["jobs"]["publish-nightly"]
    script = step(job, "Select the build to publish")["run"]
    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / "output"
        output.touch()
        full_env = dict(os.environ, GITHUB_OUTPUT=str(output), GITHUB_ENV=str(Path(temp) / "env"), **env)
        result = subprocess.run(["bash", "-c", script], env=full_env, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)


OWN = dict(
    OWN_RESULT="success",
    OWN_PENDING="",
    OWN_BUILD="50001",
    OWN_BUILD_SHA="a" * 40,
    OWN_TIP_SHA="b" * 40,
    OWN_BEHIND="0",
    OWN_BEHIND_HOURS="0",
    OWN_NOTES_HEAD="b" * 40,
    RECOVERED="",
    RECOVERED_RUN_ID="",
    RECOVERED_BUILD="",
    RECOVERED_BUILD_SHA="",
    RECOVERED_TIP_SHA="",
    RECOVERED_BEHIND="",
    RECOVERED_BEHIND_HOURS="",
    RECOVERED_HEAD_SHA="",
)
RECOVERED = dict(
    RECOVERED="true",
    RECOVERED_RUN_ID="498",
    RECOVERED_BUILD="49801",
    RECOVERED_BUILD_SHA="c" * 40,
    RECOVERED_TIP_SHA="d" * 40,
    RECOVERED_BEHIND="1",
    RECOVERED_BEHIND_HOURS="2",
    RECOVERED_HEAD_SHA="d" * 40,
)


class WorkflowTests(unittest.TestCase):
    def test_recovery_jobs_run_only_for_published_nightly_next(self):
        jobs = workflow()["jobs"]
        for name in ("find-nightly-next-recovery", "recover-nightly-next-notarization"):
            self.assertIn(name, jobs)
            condition = jobs[name]["if"]
            self.assertIn("needs.decide.outputs.track == 'nightly-next'", condition, name)
            self.assertIn("needs.decide.outputs.should_publish == 'true'", condition, name)
            self.assertIn("needs.decide.outputs.no_publish != 'true'", condition, name)
        self.assertIn("needs.find-nightly-next-recovery.outputs.found == 'true'", jobs["recover-nightly-next-notarization"]["if"])
        # The Sparkle and notary secrets come from release-next on nightly-next.
        self.assertEqual(jobs["recover-nightly-next-notarization"]["environment"], "${{ needs.decide.outputs.environment }}")
        self.assertNotIn("environment", jobs["find-nightly-next-recovery"])
        recover_text = json.dumps(jobs["recover-nightly-next-notarization"])
        for secret in ("CF_R2_", "secrets.SPARKLE_PRIVATE_KEY", "secrets.NIGHTLY_SPARKLE_PRIVATE_KEY"):
            self.assertNotIn(secret, recover_text)
        self.assertIn("nightly-next-guard.py appcast", recover_text)
        self.assertIn("CMUX_NOTARY_CONTINUE_STATE", recover_text)

    def test_publish_takes_every_build_detail_from_the_selected_source(self):
        job = workflow()["jobs"]["publish-nightly"]
        self.assertIn("recover-nightly-next-notarization", job["needs"])
        self.assertEqual(job["steps"][0]["name"], "Select the build to publish")
        text = yaml.safe_dump(job)
        for stale in (
            "needs.resolve-nightly-cmux-tui-client.outputs.build_sha",
            "needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha",
            "needs.resolve-nightly-cmux-tui-client.outputs.tip_sha",
            "needs.resolve-nightly-cmux-tui-client.outputs.behind",
            "needs.build-nightly-app.outputs.daemon_build",
            "NOTES_HEAD: ${{ needs.decide.outputs.head_sha }}",
        ):
            occurrences = [line for line in text.splitlines() if stale in line and "OWN_" not in line]
            self.assertEqual(occurrences, [], stale)
        self.assertNotIn("NIGHTLY_BUILD", job["env"])
        self.assertEqual(job["outputs"]["source"], "${{ steps.source.outputs.source }}")

    def test_publish_runs_for_an_accepted_own_or_recovered_build(self):
        condition = workflow()["jobs"]["publish-nightly"]["if"]
        self.assertTrue(condition.startswith("!cancelled() && needs.decide.result == 'success' && "), condition)
        self.assertIn(
            "((needs.build-sign-notarize-nightly.result == 'success' && needs.build-sign-notarize-nightly.outputs.notary_pending != 'true') || needs.recover-nightly-next-notarization.outputs.accepted == 'true')",
            condition,
        )

    def test_select_prefers_this_run_s_accepted_build(self):
        self.assertEqual(run_select(**OWN)["source"], "own")
        both = dict(OWN, **RECOVERED)
        selected = run_select(**both)
        self.assertEqual(selected["source"], "own")
        self.assertEqual(selected["build_sha"], "a" * 40)

    def test_select_publishes_the_recovered_build_when_this_one_is_pending_or_failed(self):
        for own in (dict(OWN, OWN_PENDING="true"), dict(OWN, OWN_RESULT="failure"), dict(OWN, OWN_RESULT="skipped")):
            selected = run_select(**dict(own, **RECOVERED))
            self.assertEqual(selected["source"], "recovered")
            self.assertEqual(selected["build"], "49801")
            self.assertEqual(selected["build_sha"], "c" * 40)
            self.assertEqual(selected["build_short_sha"], "c" * 7)
            self.assertEqual(selected["tip_sha"], "d" * 40)
            self.assertEqual(selected["behind"], "1")
            self.assertEqual(selected["behind_hours"], "2")
            self.assertEqual(selected["notes_head"], "d" * 40)
            self.assertEqual(selected["variant_pattern"], "cmux-nightly-recovered-variant-*")

    def test_select_refuses_with_nothing_accepted(self):
        with self.assertRaises(AssertionError):
            run_select(**dict(OWN, OWN_PENDING="true"))

    def test_recovered_publication_skips_deltas_and_note_signing(self):
        jobs = workflow()["jobs"]
        for name in ("generate-nightly-deltas", "sign-release-notes"):
            self.assertIn("needs.publish-nightly.outputs.source != 'recovered'", jobs[name]["if"], name)

    def test_recovery_artifact_carries_what_publication_needs(self):
        job = workflow()["jobs"]["build-sign-notarize-nightly"]
        prepare = step(job, "Prepare pending notarization recovery artifact")["run"]
        for key in ("build_sha", "tip_sha", "behind", "behind_hours"):
            self.assertRegex(prepare, rf'"{key}":')
        upload = step(job, "Upload pending notarization recovery artifact")["with"]["path"]
        self.assertIn("remote-daemon-assets/cmuxd-remote-*", upload)
        self.assertIn("recovery-source-archive", upload)


if __name__ == "__main__":
    unittest.main()
