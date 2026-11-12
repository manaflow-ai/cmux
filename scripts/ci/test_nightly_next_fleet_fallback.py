#!/usr/bin/env python3
"""scripts/ci/nightly_next_fleet_fallback.py: the cmux NEXT nightly from the fleet while Actions starts no runs.

Two halves. The parity tests are the class detector for drift between the fallback and nightly.yml: the fallback
runs nightly.yml's own steps, and every step it does not run, every script it runs, every secret, variable and decide
output it provides is listed; a nightly.yml change it has not reviewed fails here, naming the step or script.
The run tests drive the whole interpreter over the real nightly.yml with every external command stubbed: a local
git mirror, a local-directory R2 with compare-and-swap, a fake signer, and the real write-feed, final gate, build
number and step selection.

Plain Python (unittest, PyYAML); `python3 scripts/ci/test_nightly_next_fleet_fallback.py`.
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORKFLOW = ROOT / ".github/workflows/nightly.yml"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fb = load("nightly_next_fleet_fallback", HERE / "nightly_next_fleet_fallback.py")
fb.load_reviewed_scripts()
r2 = load("publish_nightly_next_r2_for_fallback", HERE / "publish-nightly-next-r2.py")
WF = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

# Steps that sign, notarize, gate or publish: the fallback must run every one of them, never skip one.
MUST_RUN = (
    "scripts/ci/signing-keychain.sh", "scripts/sign-cmux-bundle.sh", "scripts/ci/notarize-nightly-dmg.sh",
    "scripts/sparkle_generate_appcast.sh", "scripts/strip-release-bundle.sh",
    "scripts/ci/nightly-steps/app-build-release.sh", "scripts/ci/nightly-steps/helper-build.sh",
    "scripts/ci/nightly-steps/remote-daemon-build-assets.sh", "scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh",
    "scripts/ci/nightly-steps/app-build-web-bundles.sh", "scripts/ci/nightly-steps/verify-final-dmg.sh",
    "scripts/ci/nightly-steps/publish-lease.sh", "scripts/ci/nightly-steps/publish-final-gate.sh",
    "scripts/ci/nightly-steps/publish-guard-nightly-next.sh", "scripts/ci/nightly-steps/publish-next-download.sh",
    "scripts/ci/nightly-steps/publish-upload-next-appcasts.sh", "scripts/ci/nightly-steps/publish-next-feed-readback.sh",
)


class ParityTests(unittest.TestCase):
    """The fallback cannot silently diverge from nightly.yml."""

    def test_the_fallback_covers_nightly_yml_as_it_is(self) -> None:
        self.assertEqual(fb.drift(WF), [], "update scripts/ci/nightly_next_fleet_fallback.py (or its _scripts.json)")

    def test_every_script_the_fallback_runs_is_the_one_the_workflow_step_calls(self) -> None:
        # The fallback runs each step's own body, so its scripts are the step's scripts; the reviewed list must
        # be exactly that set per job (a script dropped from the workflow is dropped from the review too).
        for job in fb.MIRRORED_JOBS:
            with self.subTest(job=job):
                called = set()
                for step in WF["jobs"][job]["steps"]:
                    if (job, fb.step_name(step)) not in fb.SKIPPED_STEPS:
                        called.update(fb.step_scripts(step))
                self.assertEqual(sorted(called), sorted(fb.REVIEWED_SCRIPTS[job]))

    def test_steps_run_in_the_workflow_order_and_jobs_after_their_needs(self) -> None:
        plan = fb.plan_steps(WF)
        for job in fb.MIRRORED_JOBS:
            self.assertEqual([s["step"] for s in plan if s["job"] == job],
                             [fb.step_name(s) for s in WF["jobs"][job]["steps"]])
            for need in fb.as_list(WF["jobs"][job].get("needs")):
                need = fb.JOB_ALIASES.get(need, need)
                if need in fb.MIRRORED_JOBS:
                    self.assertLess(fb.MIRRORED_JOBS.index(need), fb.MIRRORED_JOBS.index(job), f"{job} needs {need}")

    def test_no_signing_notary_or_publication_step_is_skipped(self) -> None:
        skipped = {script for (job, name) in fb.SKIPPED_STEPS
                   for step in WF["jobs"][job]["steps"] if fb.step_name(step) == name
                   for script in fb.step_scripts(step)}
        self.assertEqual(skipped & set(MUST_RUN), set())
        ran = {script for scripts in fb.REVIEWED_SCRIPTS.values() for script in scripts}
        self.assertEqual(set(MUST_RUN) - ran, set(), "a step the fallback must run is gone from nightly.yml")

    def drifted(self, mutate) -> list[str]:
        workflow = copy.deepcopy(WF)
        mutate(workflow["jobs"])
        return fb.drift(workflow)

    def test_a_new_script_in_a_mirrored_job_fails_listing_it(self) -> None:
        def add(jobs):
            jobs["publish-nightly"]["steps"].insert(5, {"name": "Brand new check",
                                                        "run": "bash .publish-tooling/scripts/ci/nightly-steps/brand-new.sh"})
        problems = self.drifted(add)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("scripts/ci/nightly-steps/brand-new.sh", problems[0])
        self.assertIn("Brand new check", problems[0])

    def test_a_script_added_to_an_existing_step_fails(self) -> None:
        def add(jobs):
            step = next(s for s in jobs["build-sign-notarize-nightly"]["steps"] if s.get("name") == "Codesign apps")
            step["run"] = step["run"] + "\npython3 scripts/ci/new_signer_check.py\n"
        self.assertTrue(any("new_signer_check.py" in p for p in self.drifted(add)))

    def test_a_removed_or_renamed_skipped_step_fails(self) -> None:
        def rename(jobs):
            step = next(s for s in jobs["build-nightly-app"]["steps"] if s.get("name") == "Upload dSYMs to Sentry")
            step["name"] = "Upload dSYMs to Sentry (renamed)"
        problems = self.drifted(rename)
        self.assertTrue(any("no longer has" in p and "Upload dSYMs to Sentry" in p for p in problems), problems)

    def test_a_new_secret_variable_need_or_action_fails(self) -> None:
        cases = {
            "secrets.NEW_SIGNING_SECRET": lambda jobs: next(
                s for s in jobs["build-sign-notarize-nightly"]["steps"] if s.get("name") == "Codesign apps"
            ).setdefault("env", {}).update(X="${{ secrets.NEW_SIGNING_SECRET }}"),
            "vars.NEW_SWITCH": lambda jobs: jobs["publish-nightly"].update(
                {"if": jobs["publish-nightly"]["if"] + " && vars.NEW_SWITCH != 'off'"}),
            "needs.decide.outputs.new_output": lambda jobs: jobs["verify-signed-nightly"].update(
                {"if": jobs["verify-signed-nightly"]["if"] + " && needs.decide.outputs.new_output != 'x'"}),
            "needs new-job": lambda jobs: jobs["publish-nightly"]["needs"].append("new-job"),
            "uses some/action": lambda jobs: jobs["publish-nightly"]["steps"].insert(3, {"uses": "some/action@v1"}),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                problems = self.drifted(mutate)
                self.assertTrue(problems, label)
                needle = label.split(" ", 1)[-1].split(".")[-1]
                self.assertTrue(any(needle in p for p in problems), problems)

    def test_decide_outputs_match_what_decide_declares(self) -> None:
        self.assertEqual(set(fb.DECIDE_OUTPUT_NAMES), set(WF["jobs"]["decide"]["outputs"]))
        outputs = fb.decide_outputs("a" * 40, "", WF["env"], {})
        self.assertEqual((outputs["track"], outputs["feeds"], outputs["variants"]), ("nightly-next", "appcast-arm64.xml",
                                                                                     '["arm64"]'))
        self.assertEqual(outputs["pipeline"], "false")  # one run builds and publishes

    def test_required_credentials_are_workflow_secret_names(self) -> None:
        named = fb.references(WF["jobs"], "secrets")
        self.assertEqual(set(fb.REQUIRED_CREDENTIALS) - named, set())
        self.assertEqual(set(fb.OPTIONAL_CREDENTIALS) - named, set())


class ExpressionTests(unittest.TestCase):
    def ev(self, text: str, **context):
        return fb.Evaluator(context).evaluate(text)

    def test_operators_and_functions_behave_as_actions(self) -> None:
        self.assertEqual(self.ev("a.b == 'X'", a={"b": "x"}), True)  # case-insensitive strings
        self.assertEqual(self.ev("a.missing || 'fallback'", a={}), "fallback")
        self.assertEqual(self.ev("a.x && 'yes' || 'no'", a={"x": "1"}), "yes")
        self.assertEqual(self.ev("!a.x", a={"x": ""}), True)
        self.assertEqual(self.ev("format('-run-{0}', 7)"), "-run-7")
        self.assertEqual(self.ev("fromJSON('[\"arm64\"]')[0]"), "arm64")
        self.assertEqual(self.ev("contains(' a b ', ' b ')"), True)
        self.assertEqual(self.ev("a.n == 3", a={"n": "3"}), True)
        two = fb.interpolate("${{ a.x }}-${{ a.y }}", fb.Evaluator({"a": {"x": 1, "y": "b"}}))
        self.assertEqual(two, "1-b")

    def test_if_adds_success_unless_it_names_a_status_function(self) -> None:
        failing = fb.Evaluator({}, {"success": False, "failure": True, "always": True, "cancelled": False})
        self.assertFalse(fb.condition("true", failing))
        self.assertTrue(fb.condition("always()", failing))
        self.assertTrue(fb.condition("${{ !cancelled() }}", failing))


# ------------------------------------------------------------------------------------------------ run tests

def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def feed(build: int, source: str) -> str:
    return ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
            'xmlns:cmux="https://cmux.com/xml-namespaces/cmux"><channel>'
            f'<item><sparkle:version>{build}</sparkle:version><cmux:sourceCommit>{source}</cmux:sourceCommit>'
            f'<enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg" '
            'length="5" sparkle:edSignature="sig"/></item></channel></rss>')


CREDENTIALS = {name: f"value-of-{name.lower()}" for name in fb.REQUIRED_CREDENTIALS}


class StubbedInterpreter(fb.Interpreter):
    """Every external command stubbed. Real: the steps' own selection logic, the build-number step, the final gate
    (through the gh shim and the variables snapshot), the tag outcome, and write-feed against a local R2."""

    REAL = {("resolve-nightly-cmux-tui-client", "Fix this run's build number"),
            ("publish-nightly", "Select the build to publish"),
            ("publish-nightly", "Final publication gate"),
            ("publish-nightly", "Record nightly publication marker outcome")}
    r2_dir: Path
    before_write = None  # a callable run just before write-feed reads the live feed (a racing publisher)
    ran: list

    def checkout(self, workspace, ref, path, submodules):
        if path == ".publish-tooling":
            (workspace / path).symlink_to(ROOT, target_is_directory=True)
        else:
            (workspace / (path or ".")).mkdir(parents=True, exist_ok=True)

    def setup_node(self, version):
        return f"/fake-tool-cache/node/{version}/arm64/bin"

    def run_action(self, job, step, evaluator, workspace, outputs):
        kind = fb.action_kind(step["uses"])
        if kind in ("upload", "download"):
            return
        super().run_action(job, step, evaluator, workspace, outputs)

    def run_shell(self, job, name, body, shell, env, cwd, timeout):
        self.ran.append((job, name))
        out = Path(env["GITHUB_OUTPUT"])

        def output(**values):
            with out.open("a") as handle:
                handle.writelines(f"{k}={v}\n" for k, v in values.items())

        if (job, name) in self.REAL:
            return super().run_shell(job, name, body, shell, env, cwd, timeout)
        if (job, name) == ("resolve-nightly-cmux-tui-client", "Choose the build commit"):
            output(build_sha=env["TIP_SHA"], build_short_sha=env["TIP_SHA"][:7], behind=0, behind_hours=0,
                   already_published="false")
        elif (job, name) == ("build-nightly-app", "Resolve immutable SSH daemon metadata"):
            output(build=env["RESOLVED_DAEMON_BUILD"], version=f"1.0.0-nightly.{env['RESOLVED_DAEMON_BUILD']}")
        elif (job, name) == ("build-sign-notarize-nightly", "Codesign apps"):
            # The fake signer: records the build it signed, never runs codesign.
            (self.workdir / "signed").write_text(env.get("NIGHTLY_BUILD", ""))
        elif (job, name) == ("publish-nightly", "Upload nightly-next appcasts to R2"):
            return self.write_feed(env, cwd)
        return 0

    def write_feed(self, env: dict, cwd: Path) -> int:
        """publish-upload-next-appcasts.sh's write-feed call, in-process, against the local-directory R2."""
        if self.before_write:
            self.before_write()
        candidate = cwd / "nightly-out" / "appcast-arm64.xml"
        candidate.parent.mkdir(parents=True, exist_ok=True)
        candidate.write_text(feed(int(env["NIGHTLY_BUILD"]), env["SOURCE_SHA"]).replace(
            f"<cmux:sourceCommit>{env['SOURCE_SHA']}</cmux:sourceCommit>", ""))
        live_path = self.r2_dir / "appcast-arm64.xml"
        real_run = subprocess.run

        def fake_run(args, *rest, **kwargs):
            if len(args) > 1 and str(args[1]).endswith("upload-r2-object.py"):
                source = Path(args[args.index("--file") + 1]).read_bytes()
                if "--write-once" in args and live_path.exists():
                    return subprocess.CompletedProcess(args, r2.CONFLICT)
                if "--replace-sha256" in args:
                    expected = args[args.index("--replace-sha256") + 1]
                    if not live_path.exists() or hashlib.sha256(live_path.read_bytes()).hexdigest() != expected:
                        return subprocess.CompletedProcess(args, r2.CONFLICT)
                live_path.write_bytes(source)
                return subprocess.CompletedProcess(args, 0)
            return real_run(args, *rest, **kwargs)

        result = cwd / "write-feed.out"
        result.write_text("")
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(r2, "guard_key", lambda key: None), \
                mock.patch.object(r2, "read_live", lambda key: live_path.read_bytes() if live_path.exists() else None), \
                mock.patch.object(r2.subprocess, "run", fake_run):
            code = r2.write_feed(candidate, str(result), source_sha=env["SOURCE_SHA"])
        lines = result.read_text().splitlines()
        values = {k: "true" in [line.split("=", 1)[1] for line in lines if line.startswith(k + "=")]
                  for k in ("feed_written", "publication_refused")}
        current = "feed_current=true" in lines
        with Path(env["GITHUB_OUTPUT"]).open("a") as out:
            out.write(f"feed_written={str(values['feed_written']).lower()}\nfeed_current={str(current).lower()}\n"
                      f"publication_refused={str(values['publication_refused']).lower()}\n")
        return code


class RunTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        base = Path(self.dir.name)
        work = base / "src"
        (work / ".github/workflows").mkdir(parents=True)
        (work / ".github/workflows/nightly.yml").write_text(WORKFLOW.read_text(encoding="utf-8"))
        git(work, "init", "-q")
        git(work, "add", ".")
        git(work, "commit", "-q", "-m", "older")
        self.older = git(work, "rev-parse", "HEAD")
        git(work, "commit", "-q", "--allow-empty", "-m", "candidate")
        self.sha = git(work, "rev-parse", "HEAD")
        git(work, "commit", "-q", "--allow-empty", "-m", "newer")
        self.newer = git(work, "rev-parse", "HEAD")
        self.mirror = base / "cmux.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(work), str(self.mirror)], check=True)
        self.r2_dir = base / "r2"
        self.r2_dir.mkdir()
        self.vars = base / "vars.json"
        self.vars.write_text(json.dumps({"NIGHTLY_NEXT_DEV_RING": "off"}))  # NIGHTLY_NEXT_WRITER unset: mac
        self.workdir = base / "work"
        self.env = {**{k: v for k, v in os.environ.items() if k not in fb.REQUIRED_CREDENTIALS},
                    **CREDENTIALS, "NIGHTLY_FALLBACK_FEED_BASE": f"file://{self.r2_dir}",
                    "CMUX_FLEET_DIR": str(base / "no-fleet-dir"), "HOME": str(base)}
        StubbedInterpreter.r2_dir = self.r2_dir
        StubbedInterpreter.before_write = None
        StubbedInterpreter.ran = []

    def live(self, build: int, source: str) -> None:
        (self.r2_dir / "appcast-arm64.xml").write_text(feed(build, source))

    def run_fallback(self, *extra: str, env: dict | None = None, vars_file: Path | None = None,
                     interpreter=StubbedInterpreter) -> tuple[int, dict, str]:
        args = ["run", "--sha", self.sha, "--build", "auto", "--git-dir", str(self.mirror),
                "--workdir", str(self.workdir), "--vars", str(vars_file or self.vars), *extra]
        parser_args = self.parse(args)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = fb.run(parser_args, env if env is not None else self.env, interpreter)
        lines = stdout.getvalue().strip().splitlines()
        self.assertTrue(lines[-1].startswith(fb.RESULT_PREFIX), lines[-1:])
        return code, json.loads(lines[-1][len(fb.RESULT_PREFIX):]), stdout.getvalue() + stderr.getvalue()

    @staticmethod
    def parse(args: list[str]):
        import argparse
        ns = argparse.Namespace(sha=None, build=None, workdir=None, git_dir=None, vars=None, dry_run=False)
        it = iter(args[1:])
        for flag in it:
            if flag == "--dry-run":
                ns.dry_run = True
            else:
                setattr(ns, flag[2:].replace("-", "_"), next(it))
        return ns

    def assert_nothing_built(self) -> None:
        self.assertEqual(StubbedInterpreter.ran, [])
        self.assertFalse((self.workdir / "signed").exists())
        self.assertFalse((self.workdir / "jobs").exists())

    def test_missing_credentials_exit_78_with_nothing_built(self) -> None:
        env = {k: v for k, v in self.env.items() if k not in ("ASC_API_KEY_P8_BASE64", "SPARKLE_NEXT_PRIVATE_KEY")}
        self.live(4310027042601, self.older)

        class Never(StubbedInterpreter):
            def __init__(self, *a, **k):
                raise AssertionError("nothing may be built without credentials")

        code, result, text = self.run_fallback(env=env, interpreter=Never)
        self.assertEqual(code, 78)
        self.assertEqual(result["outcome"], "no-credentials")
        self.assertIn("ASC_API_KEY_P8_BASE64", text)
        self.assertIn("SPARKLE_NEXT_PRIVATE_KEY", text)
        for value in CREDENTIALS.values():
            self.assertNotIn(value, text)  # names only, never values
        self.assert_nothing_built()

    def test_the_same_source_live_stands_down_with_3(self) -> None:
        self.live(4310027042601, self.sha)
        code, result, _ = self.run_fallback()
        self.assertEqual((code, result["outcome"]), (3, "already-live"))
        self.assertEqual(result["feed_build_before"], 4310027042601)
        self.assert_nothing_built()

    def test_a_newer_source_live_stands_down_with_3(self) -> None:
        self.live(4310027042601, self.newer)
        code, result, _ = self.run_fallback()
        self.assertEqual((code, result["outcome"]), (3, "superseded"))
        self.assert_nothing_built()

    def test_an_older_source_live_publishes_build_n(self) -> None:
        self.live(4310027042601, self.older)
        code, result, text = self.run_fallback()
        self.assertEqual(code, 0, text[-3000:])
        self.assertEqual(result["outcome"], "published")
        self.assertEqual(result["build"], 4310027042650)  # <live run id><50>
        self.assertEqual((result["feed_build_before"], result["feed_build_after"]), (4310027042601, 4310027042650))
        self.assertEqual(result["github_names"], "pending")
        live = (self.r2_dir / "appcast-arm64.xml").read_bytes()
        self.assertEqual(r2.item_source(live, 4310027042650), self.sha)
        self.assertEqual(r2.item_source(live, 4310027042601), self.older)  # kept for a rollback
        # The build number the workflow's own step computes from GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT.
        self.assertEqual((self.workdir / "signed").read_text(), "4310027042650")
        outcomes = {(s["job"], s["step"]): s["outcome"] for s in result["steps"]}
        for step in (("build-nightly-app", "Build nightly app (Release)"),
                     ("build-nightly-app", "Strip unsigned nightly app before transfer"),
                     ("build-sign-notarize-nightly", "Import signing cert"),
                     ("build-sign-notarize-nightly", "Codesign apps"),
                     ("build-sign-notarize-nightly", "Notarize app ticket through final DMG"),
                     ("build-sign-notarize-nightly", "Generate Sparkle appcasts (nightly)"),
                     ("verify-final-dmg-nightly", "Verify final DMG artifact"),
                     ("publish-nightly", "Take the nightly-next publish lease"),
                     ("publish-nightly", "Final publication gate"),
                     ("publish-nightly", "Publish the nightly-next download to R2"),
                     ("publish-nightly", "Upload nightly-next appcasts to R2"),
                     ("publish-nightly", "Release the nightly-next publish lease")):
            self.assertEqual(outcomes.get(step), "success", step)
        self.assertEqual(outcomes[("build-nightly-app", "Upload dSYMs to Sentry")], "skipped-fallback")
        # Main's feeds and the GitHub release never run on nightly-next, in the workflow or here.
        self.assertNotIn(("publish-nightly", "Publish nightly release assets"), StubbedInterpreter.ran)
        # Same order as the workflow: build before sign before publish.
        ran = StubbedInterpreter.ran
        self.assertLess(ran.index(("build-nightly-app", "Build nightly app (Release)")),
                        ran.index(("build-sign-notarize-nightly", "Codesign apps")))
        self.assertLess(ran.index(("build-sign-notarize-nightly", "Codesign apps")),
                        ran.index(("publish-nightly", "Upload nightly-next appcasts to R2")))

    def test_actions_publishing_the_same_source_mid_fallback_stands_down_at_write_feed(self) -> None:
        self.live(4310027042601, self.older)
        # Actions recovered while the fallback built: run 43100270430 published the same commit as <R>01.
        StubbedInterpreter.before_write = staticmethod(lambda: self.live(4310027043001, self.sha))
        code, result, text = self.run_fallback()
        self.assertEqual(code, 3, text[-3000:])
        self.assertEqual(result["outcome"], "superseded")
        self.assertEqual(r2.newest_build((self.r2_dir / "appcast-arm64.xml").read_bytes()), 4310027043001)
        self.assertIn("already live from another publisher", text)

    def test_no_variables_snapshot_refuses_at_the_gate(self) -> None:
        # NIGHTLY_NEXT_WRITER unknown: the final gate cannot tell the writer and refuses; nothing published.
        self.live(4310027042601, self.older)
        code, result, text = self.run_fallback(vars_file=Path(self.dir.name) / "absent.json")
        self.assertEqual(code, 1)
        self.assertIn("does not exist", text)
        empty = Path(self.dir.name) / "empty-home"
        empty.mkdir()
        args = self.parse(["run", "--sha", self.sha, "--build", "auto", "--git-dir", str(self.mirror),
                           "--workdir", str(self.workdir)])
        env = {**self.env, "HOME": str(empty)}
        env.pop("NIGHTLY_FALLBACK_VARS", None)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()), \
                mock.patch.object(fb.os.path, "expanduser", lambda p: p.replace("~", str(empty))):
            code = fb.run(args, env, StubbedInterpreter)
        result = json.loads(stdout.getvalue().strip().splitlines()[-1][len(fb.RESULT_PREFIX):])
        self.assertEqual((code, result["outcome"]), (1, "refused"))
        self.assertIn("NIGHTLY_NEXT_WRITER", result["detail"])
        self.assertEqual(r2.newest_build((self.r2_dir / "appcast-arm64.xml").read_bytes()), 4310027042601)

    def test_writer_linux_in_the_snapshot_stands_down(self) -> None:
        self.live(4310027042601, self.older)
        self.vars.write_text(json.dumps({"NIGHTLY_NEXT_WRITER": "linux"}))
        code, result, _ = self.run_fallback()
        self.assertEqual(code, 3)
        self.assertEqual(r2.newest_build((self.r2_dir / "appcast-arm64.xml").read_bytes()), 4310027042601)

    def test_dry_run_plans_without_building(self) -> None:
        self.live(4310027042601, self.older)
        code, result, _ = self.run_fallback("--dry-run")
        self.assertEqual((code, result["outcome"], result["build"]), (0, "dry-run", 4310027042650))
        self.assertTrue(any(s["outcome"] == "skipped-fallback" for s in result["steps"]))
        self.assert_nothing_built()

    def test_a_non_fallback_build_number_is_refused(self) -> None:
        self.live(4310027042601, self.older)
        args = self.parse(["run", "--sha", self.sha, "--build", "4310027042602", "--git-dir", str(self.mirror),
                           "--workdir", str(self.workdir), "--vars", str(self.vars)])
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fb.run(args, self.env, StubbedInterpreter), 1)
        self.assert_nothing_built()

    def test_the_shell_entry_point_exits_78_without_credentials(self) -> None:
        env = {k: v for k, v in self.env.items() if k not in fb.REQUIRED_CREDENTIALS}
        done = subprocess.run(["bash", str(HERE / "nightly-next-fleet-fallback.sh"), "--sha", self.sha, "--build",
                               "auto", "--git-dir", str(self.mirror), "--workdir", str(self.workdir)],
                              env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 78, done.stderr)
        self.assertTrue(done.stdout.strip().splitlines()[-1].startswith(fb.RESULT_PREFIX))
        self.assertFalse(self.workdir.exists())


class CandidateInterpreter(StubbedInterpreter):
    """The stubbed run, plus the prepared app's tarball where prepare-nightly-variant-primary uploads it."""

    fail_step: tuple | None = None

    paths: dict = {}

    def run_shell(self, job, name, body, shell, env, cwd, timeout):
        CandidateInterpreter.paths[(job, name)] = env["PATH"]
        if (job, name) == self.fail_step:
            self.ran.append((job, name))
            return 1
        if (job, name) == ("prepare-nightly-variant-primary", "Package prepared app for signing"):
            self.ran.append((job, name))
            app = cwd / "stage" / "cmux.app" / "Contents"
            app.mkdir(parents=True)
            (app / "Info.plist").write_text("<plist/>")
            store = self.workdir / "artifacts" / f"cmux-nightly-prepared-app-arm64-{self.sha[:7]}"
            store.mkdir(parents=True)
            subprocess.run(["tar", "-C", str(cwd / "stage"), "-czf", str(store / "cmux-prepared-app.tar.gz"),
                            "cmux.app"], check=True)
            return 0
        return super().run_shell(job, name, body, shell, env, cwd, timeout)


class CandidateTests(unittest.TestCase):
    """run --candidate-out: the unsigned build for the tip loop, with no credentials at all. It borrows RunTests'
    fixture (a local mirror, a local feed) without inheriting its publishing tests."""

    live = RunTests.live
    parse = staticmethod(RunTests.parse)

    def setUp(self) -> None:
        RunTests.setUp(self)
        self.env = {k: v for k, v in self.env.items() if k not in fb.REQUIRED_CREDENTIALS}
        self.out = Path(self.dir.name) / "candidates"
        CandidateInterpreter.fail_step = None
        self.smoked: list = []

    def run_candidate(self, verdict: str = "pass") -> tuple[int, dict]:
        self.live(4310027042601, self.older)
        args = self.parse(["run", "--sha", self.sha, "--build", "auto", "--git-dir", str(self.mirror),
                           "--workdir", str(self.workdir), "--vars", str(self.vars), "--candidate-out", str(self.out)])

        def smoke(app, out):
            self.smoked.append(app)
            return {"verdict": verdict, "attempts": [0 if verdict == "pass" else 1], "out": str(out)}

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = fb.run_candidate(args, self.env, CandidateInterpreter, smoke=smoke)
        line = stdout.getvalue().strip().splitlines()[-1]
        return code, json.loads(line[len(fb.RESULT_PREFIX):])

    def test_a_candidate_builds_and_smokes_the_unsigned_app_with_no_credentials(self) -> None:
        code, result = self.run_candidate()
        self.assertEqual(code, 0, result)
        self.assertEqual(result["outcome"], "green")
        self.assertEqual(result["build_sha"], self.sha)
        self.assertTrue(result["candidate_app"].endswith("cmux.app"))
        self.assertEqual([str(a) for a in self.smoked], [result["candidate_app"]])
        jobs = {job for job, _ in StubbedInterpreter.ran}
        self.assertTrue(jobs <= set(fb.CANDIDATE_JOBS), jobs - set(fb.CANDIDATE_JOBS))
        self.assertFalse((self.workdir / "signed").exists())
        self.assertFalse((self.r2_dir / "appcast-arm64.xml").read_text().count(self.sha))  # nothing published

    def test_setup_node_puts_the_asked_node_on_the_later_steps_path(self) -> None:
        code, _ = self.run_candidate()
        self.assertEqual(code, 0)
        version = next(st["with"]["node-version"] for st in WF["jobs"]["build-nightly-inputs"]["steps"]
                       if str(st.get("uses", "")).startswith("actions/setup-node"))
        self.assertIn(f"/fake-tool-cache/node/{version}/arm64/bin",
                      CandidateInterpreter.paths[("build-nightly-inputs", "Build the web bundles")])

    def test_a_failed_compile_is_red_naming_the_step(self) -> None:
        CandidateInterpreter.fail_step = ("build-nightly-app", "Build nightly app (Release)")
        code, result = self.run_candidate()
        self.assertEqual(code, 1)
        self.assertEqual(result["outcome"], "red")
        self.assertEqual(result["failed"], {"job": "build-nightly-app", "step": "Build nightly app (Release)"})
        self.assertEqual(self.smoked, [])

    def test_a_launch_crash_is_red(self) -> None:
        code, result = self.run_candidate("crash")
        self.assertEqual(code, 1)
        self.assertEqual(result["failed"]["job"], "launch smoke")

    def test_a_smoke_that_cannot_run_here_stays_green(self) -> None:
        code, result = self.run_candidate("cannot-run")
        self.assertEqual(code, 0)
        self.assertEqual(result["smoke"]["verdict"], "cannot-run")

    def test_drift_in_jobs_a_candidate_never_runs_does_not_stop_it(self) -> None:
        workflow = copy.deepcopy(WF)
        workflow["jobs"]["publish-nightly"]["steps"].append({"name": "A new publish step", "run": "bash scripts/ci/new.sh"})
        self.assertTrue(fb.drift(workflow))
        self.assertEqual(fb.drift(workflow, fb.CANDIDATE_JOBS), [])


class GhShimTests(unittest.TestCase):
    def test_variables_compare_and_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            snapshot = Path(d) / "vars.json"
            snapshot.write_text(json.dumps({"NIGHTLY_NEXT_WRITER": "mac"}))
            with mock.patch.dict(os.environ, {"NIGHTLY_FALLBACK_VARS_FILE": str(snapshot)}):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(fb.gh_shim(["api", "repos/manaflow-ai/cmux/actions/variables/NIGHTLY_NEXT_WRITER",
                                                 "--jq", ".value"]), 0)
                self.assertEqual(out.getvalue().strip(), "mac")
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(fb.gh_shim(["api", "repos/manaflow-ai/cmux/actions/variables/OTHER"]), 1)
                self.assertIn("HTTP 404", err.getvalue())
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(fb.gh_shim(["release", "view", "nightly-next"]), 1)
                    self.assertEqual(fb.gh_shim(["api", "repos/manaflow-ai/cmux/actions/runs"]), 1)


class OriginTests(unittest.TestCase):
    """The checkout's origin is the mirror's upstream, so a step asking origin for a tag the mirror does not fetch
    (the notices step's cmux-rbh-src-* check) sees GitHub's answer, not a false red (tip loop, 2026-11-12)."""

    def test_origin_is_the_mirrors_upstream_or_the_mirror(self) -> None:
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as base:
            mirror = Path(base) / "cmux.git"
            git(Path(base), "init", "-q", "--bare", str(mirror))
            here = SimpleNamespace(git_dir=str(mirror))
            self.assertEqual(fb.Interpreter.origin_url(here), str(mirror.resolve()))
            git(Path(base), "--git-dir", str(mirror), "remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git")
            self.assertEqual(fb.Interpreter.origin_url(here), "https://github.com/manaflow-ai/cmux.git")
            git(Path(base), "--git-dir", str(mirror), "remote", "set-url", "origin", "/elsewhere/cmux.git")
            self.assertEqual(fb.Interpreter.origin_url(here), str(mirror.resolve()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
