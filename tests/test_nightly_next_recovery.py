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
from nightly_workflow_text import nightly_text


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


def find(runs: list[dict], run_artifacts: dict[int, dict], feeds: list[str], current: int = 500, limit: int = 3,
         optional: list[str] = ()):
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
        for source in optional:
            args += ["--feed-if-present", source]
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

    def test_a_new_feed_that_does_not_exist_yet_is_skipped(self):
        # cmux NEXT's feed before its first publication (cx-x7hwx).
        feeds = [feed(self.dir / "legacy.xml", 1)]
        result = find([run(499)], {499: artifacts((RECOVERY + "a", False))}, feeds, optional=[str(self.dir / "next" / "missing.xml")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["build"], "49901")
        result = find([run(499)], {499: artifacts((RECOVERY + "a", False))}, feeds, optional=[feed(self.dir / "next.xml", 49901)])
        self.assertEqual(json.loads(result.stdout), [])

    def test_nothing_pending_is_an_empty_list(self):
        result = find([run(499)], {499: artifacts()}, [feed(self.dir / "next.xml", 1)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])


def manifest_fixture(directory: Path, **overrides) -> Path:
    dmg = directory / "cmux-nightly-next-macos-arm64.dmg"
    dmg.write_bytes(b"signed dmg")
    import hashlib
    value = {
        "schema": 1,
        "source_run_id": "498",
        "should_publish": True,
        "channel": "nightly",
        "track": "nightly-next",
        "variant": "arm64",
        "release_tag": "nightly-next",
        "build": "49801",
        "build_sha": "c" * 40,
        "tip_sha": "d" * 40,
        "behind": "1",
        "behind_hours": "2",
        "dmg_path": dmg.name,
        "app_path": "cmux-nightly-notarization-recovery-app/cmux NEXT.app",
        "state_path": f"{dmg.name}.notarization.state",
        "immutable_path": "/Users/runner/work/cmux/cmux/cmux-nightly-next-macos-arm64-49801.dmg",
        "dmg_sha256": hashlib.sha256(b"signed dmg").hexdigest(),
        "submission_id": "fixture-id",
    }
    value.update(overrides)
    path = directory / "cmux-nightly-notarization-recovery.json"
    path.write_text(json.dumps(value))
    return path


def check_manifest(directory: Path, **overrides):
    path = manifest_fixture(directory, **overrides)
    return subprocess.run(
        [sys.executable, str(FINDER), "check-manifest", str(path), "--run-id", "498",
         "--channel", "nightly", "--release-tag", "nightly-next", "--dmg-dir", str(directory)],
        capture_output=True, text=True,
    )


class CheckManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_prints_sourceable_values(self):
        result = check_manifest(self.dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = subprocess.run(
            ["bash", "-c", result.stdout + '\nprintf "%s|" "$BUILD" "$BUILD_SHA" "$APP_NAME" "$IMMUTABLE_NAME" "$SUBMISSION_ID"'],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertEqual(
            values,
            f"49801|{'c' * 40}|cmux-nightly-notarization-recovery-app/cmux NEXT.app|cmux-nightly-next-macos-arm64-49801.dmg|fixture-id|",
        )

    def test_refuses_what_it_cannot_publish(self):
        cases = {
            "an older manifest without the build commit": {"build_sha": None},
            "another run's manifest": {"source_run_id": "497"},
            "main's track": {"track": "nightly", "release_tag": "nightly"},
            "a different DMG": {"dmg_sha256": "0" * 64},
            "an escaping path": {"app_path": "../../etc"},
            "a shell-unsafe submission id": {"submission_id": "x; rm -rf /"},
        }
        for case, overrides in cases.items():
            with self.subTest(case):
                self.assertNotEqual(check_manifest(self.dir, **overrides).returncode, 0)


def workflow() -> dict:
    return yaml.safe_load(nightly_text())


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
    OWN_VERIFIED="success",
    OWN_DMG_VERIFIED="success",
    OWN_BUILD="50001",
    OWN_BUILD_SHA="a" * 40,
    OWN_TIP_SHA="b" * 40,
    OWN_BEHIND="0",
    OWN_BEHIND_HOURS="0",
    RECOVERED="",
    RECOVERED_VERIFIED="",
    RECOVERED_RUN_ID="",
    RECOVERED_BUILD="",
    RECOVERED_BUILD_SHA="",
    RECOVERED_TIP_SHA="",
    RECOVERED_BEHIND="",
    RECOVERED_BEHIND_HOURS="",
)
RECOVERED = dict(
    RECOVERED="true",
    RECOVERED_VERIFIED="success",
    RECOVERED_RUN_ID="498",
    RECOVERED_BUILD="49801",
    RECOVERED_BUILD_SHA="c" * 40,
    RECOVERED_TIP_SHA="d" * 40,
    RECOVERED_BEHIND="1",
    RECOVERED_BEHIND_HOURS="2",
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
        self.assertIn("NOTES_HEAD: ${{ steps.source.outputs.build_sha }}", text)
        # A recovered build can predate this workflow's script arguments (run
        # 38855116561), so the tooling comes from the workflow's own commit.
        tooling = step(job, "Checkout publication tooling at the workflow commit")["with"]
        self.assertEqual(tooling["ref"], "${{ github.sha }}")
        self.assertIn('"$PUBLISH_TOOLING/ci/nightly_version.py"', step(job, "Recheck the recovered build against both feeds")["run"])
        for moved in ("scripts/ci/nightly_version.py", "scripts/ci/nightly_release_notes.py", "scripts/ci/nightly-next-guard.py",
                      "scripts/prune_nightly_release_assets.py", "scripts/ci/publish-release-assets.py",
                      "scripts/ci/finalize-release.py", "scripts/ci/upload-r2-object.py", "scripts/ci/update-release-tag.py"):
            self.assertNotIn(moved, text, f"publish-nightly must run {moved} from $PUBLISH_TOOLING")
        self.assertEqual(job["outputs"]["source"], "${{ steps.source.outputs.source }}")

    def test_publish_runs_for_an_accepted_own_or_recovered_build(self):
        condition = workflow()["jobs"]["publish-nightly"]["if"]
        self.assertTrue(condition.startswith("!cancelled() && needs.decide.result == 'success' && "), condition)
        self.assertIn(
            "((needs.build-sign-notarize-nightly.result == 'success' && needs.build-sign-notarize-nightly.outputs.notary_pending != 'true' && needs.verify-signed-nightly.result == 'success' && needs.verify-final-dmg-nightly.result == 'success') || (needs.recover-nightly-next-notarization.outputs.accepted == 'true' && needs.verify-recovered-nightly-next.result == 'success'))",
            condition,
        )

    def test_select_prefers_this_run_s_accepted_build(self):
        self.assertEqual(run_select(**OWN)["source"], "own")
        both = dict(OWN, **RECOVERED)
        selected = run_select(**both)
        self.assertEqual(selected["source"], "own")
        self.assertEqual(selected["build_sha"], "a" * 40)

    def test_select_publishes_the_recovered_build_when_this_one_is_pending_or_failed(self):
        # A build whose secret-free verify job failed is not published either.
        for own in (dict(OWN, OWN_PENDING="true"), dict(OWN, OWN_RESULT="failure"), dict(OWN, OWN_RESULT="skipped"),
                    dict(OWN, OWN_VERIFIED="failure"),
                    dict(OWN, OWN_DMG_VERIFIED="failure")):
            selected = run_select(**dict(own, **RECOVERED))
            self.assertEqual(selected["source"], "recovered")
            self.assertEqual(selected["build"], "49801")
            self.assertEqual(selected["build_sha"], "c" * 40)
            self.assertEqual(selected["build_short_sha"], "c" * 7)
            self.assertEqual(selected["tip_sha"], "d" * 40)
            self.assertEqual(selected["behind"], "1")
            self.assertEqual(selected["behind_hours"], "2")
            self.assertEqual(selected["variant_pattern"], "cmux-nightly-recovered-variant-*")
            self.assertEqual(selected["tested_pattern"], "cmux-nightly-recovered-tested-*")

    def test_select_refuses_with_nothing_accepted(self):
        with self.assertRaises(AssertionError):
            run_select(**dict(OWN, OWN_PENDING="true"))
        # A recovered build that its verify job did not launch is not published.
        with self.assertRaises(AssertionError):
            run_select(**dict(OWN, OWN_PENDING="true", **dict(RECOVERED, RECOVERED_VERIFIED="failure")))

    def test_recovered_publication_skips_deltas_and_note_signing(self):
        jobs = workflow()["jobs"]
        for name in ("generate-nightly-deltas", "sign-release-notes"):
            self.assertIn("needs.publish-nightly.outputs.source != 'recovered'", jobs[name]["if"], name)

    def test_an_ordinary_publication_publishes_its_release_notes(self):
        # Without a status function in its `if`, GitHub skips a job when any job
        # it needs, directly or through others, was skipped. An ordinary
        # publication skips the recovery job, so the notes jobs never ran and
        # every publish reopened the failure issue (cx-urd.28).
        jobs = workflow()["jobs"]

        def ancestors(name):
            needs = jobs[name].get("needs", [])
            found = set()
            for need in [needs] if isinstance(needs, str) else needs:
                found |= {need} | ancestors(need)
            return found

        for name in ("sign-release-notes", "publish-release-notes"):
            self.assertIn("recover-nightly-next-notarization", ancestors(name), name)
            self.assertTrue(jobs[name]["if"].startswith("!cancelled() && "), jobs[name]["if"])
            self.assertIn("needs.publish-nightly.result == 'success'", jobs[name]["if"], name)

    def test_recovery_artifact_carries_what_publication_needs(self):
        job = workflow()["jobs"]["build-sign-notarize-nightly"]
        prepare = step(job, "Prepare pending notarization recovery artifact")["run"]
        for key in ("build_sha", "tip_sha", "behind", "behind_hours"):
            self.assertRegex(prepare, rf'"{key}":')
        upload = step(job, "Upload pending notarization recovery artifact")["with"]["path"]
        self.assertIn("remote-daemon-assets/cmuxd-remote-*", upload)
        self.assertIn("recovery-source-archive", upload)


def job_runs(name: str, results: dict, outputs: dict) -> bool:
    """Whether GitHub would run job `name` after jobs that ended with `results`
    and set `outputs`, from its real `if` (the subset of the expression
    language nightly.yml uses: always/cancelled/contains, ==, !=, !, &&, ||)."""
    job = workflow()["jobs"][name]
    needs = job["needs"]
    expr = job["if"]
    expr = expr.replace("always()", "True").replace("cancelled()", "False")
    expr = re.sub(r"contains\(needs\.\*\.result, '(\w+)'\)", lambda m: repr(m.group(1) in [results[n] for n in needs]), expr)
    expr = re.sub(r"needs\.([\w-]+)\.outputs\.([\w-]+)", lambda m: repr(outputs.get(m.group(1), {}).get(m.group(2), "")), expr)
    expr = re.sub(r"needs\.([\w-]+)\.result", lambda m: repr(results[m.group(1)]), expr)
    expr = re.sub(r"!(?!=)", " not ", expr).replace("&&", " and ").replace("||", " or ")
    return eval(expr, {"__builtins__": {}}, {})


class FailureIssueTests(unittest.TestCase):
    """The nightly-next failure issue opens on a failed publication and closes
    on the next good one. A recovered publication skips its deltas and notes on
    purpose, so it must not open the issue or keep it open (cx-urd.69)."""

    OUTPUTS = {"decide": {"should_publish": "true", "track": "nightly-next"}, "publish-nightly": {"tag_status": "updated"}}

    def publication(self, source, **results):
        jobs = ("decide", "build-nightly-ghostty-cli-helper", "build-nightly-app", "resolve-nightly-cmux-tui-client",
                "prepare-nightly-variant", "build-sign-notarize-nightly", "verify-signed-nightly", "verify-final-dmg-nightly",
                "verify-recovered-nightly-next", "publish-nightly", "generate-nightly-deltas", "republish-nightly-deltas",
                "sign-release-notes", "publish-release-notes")
        outcome = dict.fromkeys(jobs, "success")
        if source == "own":
            outcome["verify-recovered-nightly-next"] = "skipped"
        if source == "recovered":
            outcome.update({"generate-nightly-deltas": "skipped", "sign-release-notes": "skipped", "publish-release-notes": "skipped"})
        outcome.update(results)
        outputs = dict(self.OUTPUTS, **{"publish-nightly": dict(self.OUTPUTS["publish-nightly"], source=source)})
        return job_runs("report-nightly-failure", outcome, outputs), job_runs("close-nightly-failure-issue", outcome, outputs)

    def test_a_recovered_publication_closes_the_issue(self):
        self.assertEqual(self.publication("recovered"), (False, True))

    def test_an_ordinary_publication_closes_the_issue(self):
        self.assertEqual(self.publication("own"), (False, True))

    def test_an_ordinary_publication_without_its_notes_reports(self):
        self.assertEqual(self.publication("own", **{"sign-release-notes": "failure", "publish-release-notes": "skipped"}), (True, False))
        self.assertEqual(self.publication("own", **{"sign-release-notes": "skipped", "publish-release-notes": "skipped"}), (True, False))

    def test_a_recovered_publication_after_this_run_s_build_failed_reports(self):
        # publish-nightly also publishes a recovered build when this run's own
        # build failed; closing then would race the report of that failure.
        self.assertEqual(self.publication("recovered", **{"build-sign-notarize-nightly": "failure"}), (True, False))
        self.assertEqual(self.publication("recovered", **{"build-nightly-app": "failure", "build-sign-notarize-nightly": "skipped"}), (True, False))

    def test_a_recovered_publication_that_failed_its_delta_republish_reports(self):
        self.assertEqual(self.publication("recovered", **{"republish-nightly-deltas": "failure"}), (True, False))

    def test_an_already_published_recovered_build_neither_reports_nor_closes(self):
        # Another run published this build and owns the issue; this run's
        # no-op moved no marker (tag_status empty) and republished nothing.
        outcome = {"republish-nightly-deltas": "skipped"}
        self.OUTPUTS = {"decide": self.OUTPUTS["decide"], "publish-nightly": {"tag_status": "", "already_published": "true"}}
        self.assertEqual(self.publication("recovered", **outcome), (False, False))

    def test_a_refused_publication_reports_and_never_closes(self):
        self.OUTPUTS = {"decide": self.OUTPUTS["decide"],
                        "publish-nightly": {"tag_status": "", "already_published": "true", "refused": "true",
                                            "refusal_reason": "NIGHTLY_NEXT_WRITER read live is unreadable: HTTP 403"}}
        outcome = {"republish-nightly-deltas": "skipped", "sign-release-notes": "skipped", "publish-release-notes": "skipped"}
        self.assertEqual(self.publication("own", **outcome), (True, False))

    def test_a_deliberate_stand_down_neither_reports_nor_closes(self):
        self.OUTPUTS = {"decide": self.OUTPUTS["decide"],
                        "publish-nightly": {"tag_status": "", "already_published": "true", "refused": "true"}}
        outcome = {"republish-nightly-deltas": "skipped", "sign-release-notes": "skipped", "publish-release-notes": "skipped"}
        self.assertEqual(self.publication("own", **outcome), (False, False))

    def test_an_already_published_own_build_neither_reports_nor_closes(self):
        outcome = {"republish-nightly-deltas": "skipped", "sign-release-notes": "skipped",
                   "publish-release-notes": "skipped"}
        self.OUTPUTS = {"decide": self.OUTPUTS["decide"],
                        "publish-nightly": {"tag_status": "", "already_published": "true"}}
        self.assertEqual(self.publication("own", **outcome), (False, False))
        for result in ("failure", "cancelled"):
            with self.subTest(result=result):
                self.assertEqual(self.publication("own", **dict(outcome, **{"build-nightly-app": result})),
                                 (True, False))
        self.OUTPUTS["publish-nightly"]["tag_status"] = "stale"
        self.assertEqual(self.publication("own", **outcome), (True, False))


def run_recheck(build: int, next_builds: tuple, legacy_builds: tuple = (), classic_builds: tuple = (),
                *, source: str = "recovered", track: str = "nightly-next"):
    """Apply the workflow gate, then run its real recheck against local feeds.

    A local publication marker stands in for the later mutable feed writes;
    it must remain absent when the locked recheck refuses an older build.
    """
    recheck = step(workflow()["jobs"]["publish-nightly"], "Recheck the recovered build against both feeds")
    condition = recheck["if"].replace("steps.source.outputs.source", repr(source))
    condition = condition.replace("needs.decide.outputs.track", repr(track)).replace("||", "or")
    script = recheck["run"] if eval(condition, {"__builtins__": {}}, {}) else ":"
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        for name, builds in (("next", next_builds), ("legacy", legacy_builds), ("classic", classic_builds)):
            (work / name).mkdir()
            for appcast in ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml"):
                feed(work / name / appcast, *builds)
        script = script.replace("https://files.cmux.com/nightly", str(work / "classic"))
        output = work / "output"
        output.touch()
        env = dict(
            os.environ,
            NIGHTLY_BUILD=str(build),
            NIGHTLY_NEXT_FEED_BASE=str(work / "next"),
            NIGHTLY_NEXT_LEGACY_FEED_BASE=str(work / "legacy"),
            GITHUB_OUTPUT=str(output),
            PUBLISH_TOOLING=str(ROOT / "scripts"),
        )
        result = subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, text=True)
        result.output = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)  # type: ignore[attr-defined]
        publication = work / "published-build"
        if result.returncode == 0 and result.output.get("already_published") != "true":
            publication.write_text(str(build))
        result.published_build = publication.read_text() if publication.exists() else None  # type: ignore[attr-defined]
        return result


class RecheckTests(unittest.TestCase):
    """Two runs can take the same recovered build (run 38689026338 and its
    continuation 38689412336). The second one finds its build already on the
    feed: that ends its publication as a no-op, not as a failure, while a build
    below the feed still fails."""

    def test_an_older_own_build_cannot_publish_after_a_newer_run(self):
        # Own build 49801 passed its early version check, then spent time in
        # signing/notarization while another run published build 49901.
        for feeds in (((49901,), (), ()), ((), (49901,), ()), ((), (), (49901,))):
            with self.subTest(feeds=feeds):
                result = run_recheck(49801, *feeds, source="own")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIsNone(result.published_build)

    def test_an_own_build_above_every_feed_can_publish(self):
        result = run_recheck(49801, (49701,), (49601,), (49501,), source="own")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.published_build, "49801")

    def test_an_own_build_already_published_by_another_run_writes_nothing(self):
        result = run_recheck(49801, (49801,), source="own")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.output.get("already_published"), "true")
        self.assertIsNone(result.published_build)

    def test_classic_own_publication_keeps_its_existing_routing(self):
        result = run_recheck(49801, (49901,), source="own", track="nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.published_build, "49801")

    def test_classic_recovered_publication_keeps_its_floor_check(self):
        result = run_recheck(49801, (49901,), track="nightly")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIsNone(result.published_build)

    def test_a_build_above_every_feed_publishes(self):
        result = run_recheck(49801, (49701,), (49601,), (49501,))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.output.get("already_published"), "true")

    def test_a_build_another_run_already_published_is_a_no_op(self):
        result = run_recheck(49801, (49701, 49801), (49601,), (49501,))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.output.get("already_published"), "true")
        self.assertIn("already published", result.stdout)

    def test_a_build_below_a_feed_still_fails(self):
        for feeds in (((49901,), (), ()), ((49801,), (49601,), (49901,)), ((49801, 49901), (), ())):
            result = run_recheck(49801, *feeds)
            self.assertNotEqual(result.returncode, 0, feeds)
            self.assertNotEqual(result.output.get("already_published"), "true", feeds)

    def test_an_already_published_build_skips_every_later_publication_step(self):
        steps = workflow()["jobs"]["publish-nightly"]["steps"]
        names = [s.get("name") for s in steps]
        recheck = names.index("Recheck the recovered build against both feeds")
        self.assertEqual(steps[recheck].get("id"), "recheck")
        for later in steps[recheck + 1:]:
            self.assertIn("steps.recheck.outputs.already_published != 'true'", later.get("if", ""), later.get("name"))

    def test_an_already_published_build_republishes_no_deltas(self):
        outcome = dict.fromkeys(workflow()["jobs"]["republish-nightly-deltas"]["needs"], "success")
        outcome["generate-nightly-deltas"] = "skipped"
        outputs = {"decide": {"should_publish": "true", "track": "nightly-next"},
                   "publish-nightly": {"source": "recovered", "already_published": "true"}}
        self.assertFalse(job_runs("republish-nightly-deltas", outcome, outputs))

    def test_an_already_published_own_build_publishes_no_release_notes(self):
        for name in ("sign-release-notes", "publish-release-notes"):
            with self.subTest(job=name):
                outcome = dict.fromkeys(workflow()["jobs"][name]["needs"], "success")
                outputs = {"decide": {"should_publish": "true", "track": "nightly-next"},
                           "publish-nightly": {"source": "own", "already_published": "true"}}
                self.assertFalse(job_runs(name, outcome, outputs))
                outputs["publish-nightly"]["already_published"] = ""
                self.assertTrue(job_runs(name, outcome, outputs))

    def test_the_recheck_holds_the_release_tag_publication_lock(self):
        lock = workflow()["jobs"]["publish-nightly"]["concurrency"]
        self.assertEqual(lock["group"], "release-publish-${{ needs.decide.outputs.release_tag }}")
        self.assertFalse(lock["cancel-in-progress"])


def run_continue_step(notary: str) -> subprocess.CompletedProcess[str]:
    """Run the real continuation step against one candidate, with gh, the
    manifest check, the feed check and notarize-nightly-dmg.sh stubbed. The
    stub notarizer reports Apple's verdict and exits as `notary` says."""
    script = step(workflow()["jobs"]["recover-nightly-next-notarization"], "Continue the newest accepted pending notarization")["run"]
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        app_tar = work / "app.tar.gz"
        (work / "app" / "cmux NEXT.app").mkdir(parents=True)
        subprocess.run(["tar", "-C", str(work / "app"), "-czf", str(app_tar), "."], check=True)
        bin_dir = work / "bin"
        ci = work / "scripts/ci"
        bin_dir.mkdir()
        ci.mkdir(parents=True)
        stubs = {
            bin_dir / "gh": f'dir="${{@: -1}}"; mkdir -p "$dir"; cp {str(app_tar)!r} "$dir/cmux-nightly-notarization-recovery-app.tar.gz"\n',
            ci / "find-nightly-next-recovery.py": (
                "printf '%s\\n' BUILD=49801 BUILD_SHA=c TIP_SHA=d BEHIND=1 BEHIND_HOURS=2 SUBMISSION_ID=fixture-id "
                "STATE_NAME=state 'APP_NAME=\"cmux-nightly-notarization-recovery-app/cmux NEXT.app\"' "
                "DMG_NAME=next.dmg IMMUTABLE_NAME=next-49801.dmg\n"
            ),
            ci / "nightly_version.py": "exit 0\n",
            ci / "nightly-next-recovery-lineage.sh": "echo ok\n",
            ci / "notarize-nightly-dmg.sh": (
                'case "$FIXTURE_NOTARY" in\n'
                '  accepted-then-failed) echo notary_status=Accepted >> "$GITHUB_OUTPUT"; exit 1 ;;\n'
                '  invalid) echo notary_status=Invalid >> "$GITHUB_OUTPUT"; exit 1 ;;\n'
                '  unreadable) exit 1 ;;\n'
                'esac\n'
            ),
        }
        for path, body in stubs.items():
            path.write_text("#!/usr/bin/env bash\n" + body)
            path.chmod(0o755)
        (bin_dir / "python3").write_text(f'#!/usr/bin/env bash\ncase "$1" in\n  scripts/ci/*) exec bash "$@" ;;\nesac\nexec {sys.executable} "$@"\n')
        (bin_dir / "python3").chmod(0o755)
        env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            FIXTURE_NOTARY=notary,
            CANDIDATES=json.dumps([{"run_id": 498, "artifact": RECOVERY + "aaaaaaa"}]),
            GITHUB_REPOSITORY=REPO,
            GITHUB_OUTPUT=str(work / "output"),
            GITHUB_ENV=str(work / "env"),
            GITHUB_STEP_SUMMARY=str(work / "summary"),
            NIGHTLY_NEXT_FEED_BASE="https://example.invalid/next",
            NIGHTLY_NEXT_LEGACY_FEED_BASE="https://example.invalid/legacy",
            CHANNEL="nightly",
            SIGN_CHANNEL="next",
            CHANNEL_RELEASE_TAG="nightly-next",
        )
        result = subprocess.run(["bash", "-c", script], cwd=work, env=env, capture_output=True, text=True)
        result.output = (work / "output").read_text()  # type: ignore[attr-defined]
        return result


class ContinueStepTests(unittest.TestCase):
    """Run 38677509707 skipped five builds Apple had accepted, saying Apple did
    not accept them: the bundle notice check after acceptance had failed. The
    skip must say which happened, and still move on to the next candidate."""

    def test_a_check_failing_after_acceptance_is_an_error_not_apple_s(self):
        result = run_continue_step("accepted-then-failed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::error::run 498: Apple accepted submission fixture-id, but a check after acceptance failed", result.stdout)
        self.assertNotIn("did not accept", result.stdout)
        self.assertIn("accepted=false", result.output)

    def test_a_submission_apple_did_not_accept_names_its_status(self):
        result = run_continue_step("invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::notice::run 498: Apple did not accept submission fixture-id (status Invalid); skipping", result.stdout)
        self.assertNotIn("::error::", result.stdout)
        self.assertIn("accepted=false", result.output)

    def test_a_submission_whose_verdict_is_unknown_says_so(self):
        result = run_continue_step("unreadable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::notice::run 498: Apple's verdict on submission fixture-id is unknown", result.stdout)
        self.assertNotIn("::error::", result.stdout)
        self.assertIn("accepted=false", result.output)


FAKE_GH = """#!/usr/bin/env bash
# gh api repos/R/actions/variables/NAME --jq .value, answered from $FAKE_VARS.
name="${2##*/}"
if [ -e "$FAKE_VARS/$name.error" ]; then echo "HTTP 500: server error" >&2; exit 1; fi
if [ ! -e "$FAKE_VARS/$name" ]; then echo "HTTP 404: Not Found" >&2; exit 1; fi
cat "$FAKE_VARS/$name"
"""


def run_gate(variables: dict, *, token: str = "app-token", track: str = "nightly-next", source: str = "own"):
    """Run the real Final publication gate against a fake gh: each key of
    variables is a live cmux variable; the value None makes it unreadable."""
    gate = step(workflow()["jobs"]["publish-nightly"], "Final publication gate")
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        (work / "bin").mkdir()
        (work / "vars").mkdir()
        gh = work / "bin" / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        for name, value in variables.items():
            (work / "vars" / (name if value is not None else f"{name}.error")).write_text(value or "")
        output = work / "output"
        output.touch()
        env = dict(
            os.environ,
            PATH=f"{work / 'bin'}:{os.environ['PATH']}",
            FAKE_VARS=str(work / "vars"),
            TRACK=track,
            SOURCE=source,
            NIGHTLY_BUILD="49801",
            BUILD_SHA="a" * 40,
            WRITER_TOKEN=token,
            GITHUB_REPOSITORY=REPO,
            CHANNEL_RELEASE_TAG="nightly-next",
            GITHUB_OUTPUT=str(output),
            GITHUB_STEP_SUMMARY=str(work / "summary"),
            RUNNER_TEMP=str(work),
            PUBLISH_TOOLING=str(ROOT / "scripts"),
        )
        result = subprocess.run(["bash", "-c", gate["run"]], cwd=ROOT, env=env, capture_output=True, text=True)
        result.output = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)  # type: ignore[attr-defined]
        return result


class WriterGateTests(unittest.TestCase):
    """cx-f76kf: one explicit writer, NIGHTLY_NEXT_WRITER (mac, linux or none).
    The Mac pipeline publishes nightly-next only while it reads mac live right
    before the first write; anything else refuses (refused=true, exit 0, not a
    failure). Unset means mac. The transition-week NIGHTLY_NEXT_HOLD is retired
    and no longer read."""

    def assert_refused(self, result, why: str, deliberate: bool = False):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.output.get("refused"), "true", result.stdout)
        self.assertIn(why, result.stdout)
        # A fault names its reason (the failure issue opens); a deliberate
        # stand-down by an operator does not.
        if deliberate:
            self.assertNotIn("refusal_reason", result.output, result.stdout)
        else:
            self.assertIn(why, result.output.get("refusal_reason", ""), result.stdout)

    def test_mac_publishes(self):
        for writer in ("mac", "mac\n"):
            with self.subTest(writer=writer):
                result = run_gate({"NIGHTLY_NEXT_WRITER": writer})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("refused", result.output)

    def test_an_unset_writer_is_mac(self):
        result = run_gate({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("refused", result.output)
        self.assertIn("NIGHTLY_NEXT_WRITER is unset, which means mac", result.stdout)

    def test_a_value_that_looks_like_unset_refuses(self):
        # Only a 404 means unset; no value read live can stand in for it.
        for writer in ("<unset>", "unset"):
            with self.subTest(writer=writer):
                self.assert_refused(run_gate({"NIGHTLY_NEXT_WRITER": writer}), "not mac")
        self.assert_refused(run_gate({"NIGHTLY_NEXT_WRITER": ""}), "'<empty>', not mac")

    def test_the_retired_hold_is_not_read(self):
        # Even an unreadable or set NIGHTLY_NEXT_HOLD no longer stops a publication.
        for hold in ("1", None):
            with self.subTest(hold=hold):
                result = run_gate({"NIGHTLY_NEXT_WRITER": "mac", "NIGHTLY_NEXT_HOLD": hold})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("refused", result.output)

    def test_any_other_writer_refuses(self):
        for writer in ("linux", "none", "", "Mac", "macos"):
            with self.subTest(writer=writer):
                self.assert_refused(run_gate({"NIGHTLY_NEXT_WRITER": writer}), "not mac",
                                    deliberate=writer in ("linux", "none"))

    def test_an_unreadable_writer_refuses(self):
        self.assert_refused(run_gate({"NIGHTLY_NEXT_WRITER": None}), "NIGHTLY_NEXT_WRITER read live is unreadable")
        self.assert_refused(run_gate({"NIGHTLY_NEXT_WRITER": "mac"}, token=""), "could not be minted")

    def test_a_recovered_build_is_refused_before_its_lineage_check(self):
        result = run_gate({"NIGHTLY_NEXT_WRITER": "linux"}, source="recovered")
        self.assert_refused(result, "not mac", deliberate=True)
        self.assertNotIn("Recovered build not checked", result.stdout)

    def test_the_main_track_reads_no_writer(self):
        result = run_gate({}, token="", track="nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("refused", result.output)

    def test_decide_builds_nightly_next_only_for_the_mac_writer(self):
        decide = workflow()["jobs"]["decide"]
        text = json.dumps(decide)
        self.assertIn("${{ vars.NIGHTLY_NEXT_WRITER || 'mac' }}", text)
        self.assertIn("track === 'nightly-next' && shouldPublish && !notaryDispatchInput && nextWriter !== 'mac'", text)
        self.assertIn("!nextNotWriter ? 'true'", text)
        # The retired hold is read nowhere: not at decide, not by the final gate.
        everything = json.dumps(workflow())
        for reader in ("vars.NIGHTLY_NEXT_HOLD", "process.env.NIGHTLY_NEXT_HOLD", "var NIGHTLY_NEXT_HOLD"):
            self.assertNotIn(reader, everything)

    def test_the_token_mint_cannot_fail_the_run(self):
        mint = step(workflow()["jobs"]["publish-nightly"], "Mint release App token")
        self.assertTrue(mint["continue-on-error"])
        self.assertIn("needs.decide.outputs.track == 'nightly-next'", mint["if"])


class ShellSnippetTests(unittest.TestCase):
    """Run 37876356169: a `python3 -c '...'` one-liner in these jobs had
    backslash-escaped quotes, which bash single quotes keep, so Python raised
    a SyntaxError as soon as a candidate existed. Run each one as bash does."""

    CANDIDATES = json.dumps([{"run_id": 498, "run_attempt": 1, "build": "49801", "head_sha": "a" * 40, "artifact": "cmux-nightly-notarization-recovery-arm64-aaaaaaa"}])

    def snippets(self):
        jobs = workflow()["jobs"]
        found = []
        for name in ("find-nightly-next-recovery", "recover-nightly-next-notarization"):
            for item in jobs[name]["steps"]:
                found += re.findall(r"python3 (?:-I )?-c '[^']*'", item.get("run", ""))
        return found

    def test_every_inline_python_runs_under_bash(self):
        snippets = self.snippets()
        self.assertEqual(len(snippets), 4, snippets)
        outputs = []
        for snippet in snippets:
            result = subprocess.run(["bash", "-c", snippet], input=self.CANDIDATES, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{snippet}\n{result.stderr}")
            outputs.append(result.stdout)
        self.assertIn("- run 498 build 49801\n", outputs)
        self.assertIn("498\tcmux-nightly-notarization-recovery-arm64-aaaaaaa\n", outputs)


if __name__ == "__main__":
    unittest.main()
