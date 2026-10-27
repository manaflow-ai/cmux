#!/usr/bin/env python3
"""Resuming publication requires an authenticated digest, never size alone."""
import importlib.util
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("artifact_download", ROOT / "scripts/ci/download-run-artifact.py")
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)
spec = importlib.util.spec_from_file_location("unsigned_resume", ROOT / "scripts/ci/resume-unsigned-nightly.py")
resume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resume)
spec = importlib.util.spec_from_file_location("nightly_decide_tests", ROOT / "tests/test_ci_nightly_push_throttle.py")
decisions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decisions)


class ArtifactDigestTests(unittest.TestCase):
    def test_an_unsigned_input_without_a_digest_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "artifact.zip"
            path.write_bytes(b"same size is not identity")
            with self.assertRaises(SystemExit):
                download.verify(str(path), {"size_in_bytes": path.stat().st_size})

    def test_same_length_replacement_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "artifact.zip"
            path.write_bytes(b"forged")
            with self.assertRaises(SystemExit):
                download.verify(str(path), {"size_in_bytes": 6, "digest": "sha256:" + hashlib.sha256(b"signed").hexdigest()})


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.run = {"id": 123, "run_attempt": 1, "repository": {"id": 9, "full_name": "manaflow-ai/cmux"},
                    "head_repository": {"full_name": "manaflow-ai/cmux"}, "head_sha": self.sha,
                    "head_branch": "nightly-next", "path": ".github/workflows/nightly.yml", "event": "push",
                    "status": "completed", "conclusion": "failure"}
        self.jobs = [{"name": name, "run_attempt": 1, "conclusion": "success", "started_at": "2026-10-16T00:01:00Z",
                      "completed_at": "2026-10-16T00:03:00Z"} for name in {v[0] for v in resume.ARTIFACTS.values()}]
        self.artifacts = [{"id": i, "name": name, "expired": False, "digest": "sha256:" + "b" * 64,
                           "created_at": "2026-10-16T00:02:00Z", "workflow_run": {"id": 123, "head_sha": self.sha,
                           "head_branch": "nightly-next", "repository_id": 9, "head_repository_id": 9}}
                          for i, name in enumerate(resume.ARTIFACTS, 1)]
        self.artifacts.append({"name": "nightly-next-dsyms-" + self.sha, "created_at": "2026-10-16T00:02:00Z"})

    def receipt(self):
        return resume.validate(self.run, self.jobs, self.artifacts, "manaflow-ai/cmux", "123", "1")

    def test_failed_signing_reuses_successful_compile_and_original_identity(self):
        receipt = self.receipt()
        self.assertEqual(receipt["build"], "12301")
        self.assertEqual(receipt["build_sha"], self.sha)
        self.assertEqual(len(receipt["artifacts"]), 5)

    def test_a_helper_the_resolver_reused_is_its_producer(self):
        helper = next(a for a in self.artifacts if a["name"] == "cmux-nightly-ghostty-cli-helper")
        helper["created_at"] = "2026-10-16T00:00:30Z"
        with self.assertRaises(SystemExit):
            self.receipt()
        self.jobs.append({"name": resume.HELPER_RESOLVER, "run_attempt": 1, "conclusion": "success",
                          "started_at": "2026-10-16T00:00:00Z", "completed_at": "2026-10-16T00:00:45Z"})
        self.assertEqual(self.receipt()["artifacts"]["cmux-nightly-ghostty-cli-helper"], helper)
        self.jobs[-1]["run_attempt"] = 2
        with self.assertRaises(SystemExit):
            self.receipt()

    def test_each_untrusted_or_incomplete_source_is_rejected(self):
        for field, value in (("event", "pull_request"), ("head_branch", "feature"), ("run_attempt", 2),
                             ("path", ".github/workflows/evil.yml"), ("status", "in_progress"),
                             ("head_repository", {"full_name": "fork/cmux"})):
            with self.subTest(field=field):
                original = copy.deepcopy(self.run)
                self.run[field] = value
                with self.assertRaises(SystemExit):
                    self.receipt()
                self.run = original

    def test_each_producer_must_succeed_in_the_exact_attempt(self):
        for field, value in (("conclusion", "failure"), ("run_attempt", 2)):
            original = copy.deepcopy(self.jobs)
            self.jobs[0][field] = value
            with self.assertRaises(SystemExit):
                self.receipt()
            self.jobs = original

    def test_later_failed_job_rerun_does_not_replace_original_attempt(self):
        def api(path, token):
            if path.endswith("/actions/runs/123"):
                return {**self.run, "run_attempt": 2}
            if path.endswith("/attempts/1"):
                return self.run
            if "/jobs?" in path:
                return {"total_count": len(self.jobs), "jobs": self.jobs}
            if "/artifacts?" in path:
                return {"total_count": len(self.artifacts), "artifacts": self.artifacts}
            if "/compare/" in path:
                return {"status": "ahead"}
            self.fail(f"unexpected API request: {path}")

        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "test",
                                          "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_SHA": "c" * 40,
                                          "GITHUB_EVENT_NAME": "workflow_dispatch"}), \
                mock.patch.object(resume.download, "api_json", side_effect=api):
            self.assertEqual(resume.plan("123", "1")["build"], "12301")

    def test_missing_expired_unhashed_or_different_attempt_artifacts_are_rejected(self):
        for change in ({"expired": True}, {"digest": ""}, {"created_at": "2026-10-15T00:02:00Z"},
                       {"workflow_run": {"id": 456}}):
            with self.subTest(change=change):
                original = copy.deepcopy(self.artifacts)
                self.artifacts[0].update(change)
                with self.assertRaises(SystemExit):
                    self.receipt()
                self.artifacts = original

    def test_duplicate_artifacts_and_missing_source_receipt_are_rejected(self):
        self.artifacts.append(copy.deepcopy(self.artifacts[0]))
        with self.assertRaises(SystemExit):
            self.receipt()
        self.artifacts.pop()
        self.artifacts.pop()
        with self.assertRaises(SystemExit):
            self.receipt()

    def test_restore_preserves_the_original_daemon_version(self):
        receipt = self.receipt()

        def fake_download(artifact, token, dest, connections):
            with zipfile.ZipFile(dest, "w") as archive:
                if artifact["name"] == "cmux-nightly-remote-daemon":
                    archive.writestr("cmuxd-remote-manifest-12301.json", json.dumps({"appVersion": "0.1.0-nightly.12301"}))
                else:
                    archive.writestr("payload", "original")
            artifact["size_in_bytes"] = Path(dest).stat().st_size
            artifact["digest"] = "sha256:" + hashlib.sha256(Path(dest).read_bytes()).hexdigest()

        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict("os.environ", {"GH_TOKEN": "test"}), \
                mock.patch.object(resume.download, "download", side_effect=fake_download):
            self.assertEqual(resume.restore(receipt, Path(tmp)), "0.1.0-nightly.12301")
            self.assertEqual((Path(tmp) / "app/payload").read_text(), "original")

    def test_zip_escape_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../escape", "untrusted")
            with self.assertRaises(SystemExit):
                resume.extract(archive, Path(tmp) / "out")
            self.assertFalse((Path(tmp) / "escape").exists())


class WorkflowRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]

    def evaluate(self, expression, resuming):
        values = {"inputs.nightly_next_unsigned_run": "123" if resuming else "",
                  "needs.decide.outputs.track": "nightly-next", "needs.decide.outputs.fast_build": "false",
                  "needs.decide.outputs.build_only": "false", "github.ref_name": "nightly-next",
                  "github.repository_owner": "manaflow-ai", "runner.environment": "github-hosted"}
        condition = expression.removeprefix("${{").removesuffix("}}").strip()
        condition = re.sub(r"\b(?:inputs|needs|steps|github|env|runner)\.[\w.-]+", lambda m: repr(values.get(m[0], "")), condition)
        condition = re.sub(r"\bvars\.[\w.-]+", "''", condition)
        condition = condition.replace("&&", " and ").replace("||", " or ")
        return eval(condition, {"__builtins__": {}}, {"always": lambda: True, "success": lambda: True,
                                                      "failure": lambda: False, "cancelled": lambda: False,
                                                      "true": True, "false": False})

    def enabled(self, step, resuming):
        return bool(self.evaluate(step.get("if", "true"), resuming))

    def test_only_restore_workloads_take_linux_and_fresh_builds_keep_macos(self):
        for name, native_runner, resume_runner in (("build-nightly-app", "blacksmith-6vcpu-macos-26", "blacksmith-4vcpu-ubuntu-2404"),
                                                   ("build-nightly-ghostty-cli-helper", "blacksmith-6vcpu-macos-26", "ubuntu-24.04")):
            with self.subTest(name=name):
                self.assertEqual(self.evaluate(self.jobs[name]["runs-on"], True), resume_runner)
                self.assertEqual(self.evaluate(self.jobs[name]["runs-on"], False), native_runner)

    def test_resume_selects_restore_and_zero_native_or_cache_work(self):
        for name in ("build-nightly-app", "build-nightly-ghostty-cli-helper"):
            selected = [step for step in self.jobs[name]["steps"] if self.enabled(step, True)]
            self.assertTrue(selected)
            for step in selected:
                run = step.get("run", "")
                self.assertNotIn("xcodebuild", run)
                self.assertNotIn("cargo build", run)
                self.assertNotIn("zig build", run)
                self.assertNotIn("cache", step.get("uses", ""))
            if name == "build-nightly-app":
                self.assertTrue(any(step.get("id") == "resume" for step in selected))
                names = {step.get("with", {}).get("name") for step in selected if "upload-artifact" in step.get("uses", "")}
                self.assertTrue(set(resume.ARTIFACTS) <= names)

    def test_ordinary_build_still_selects_release_compilation(self):
        selected = [step["name"] for step in self.jobs["build-nightly-app"]["steps"] if self.enabled(step, False)]
        self.assertIn("Build nightly app (Release)", selected)
        self.assertNotIn("Restore the original unsigned nightly inputs", selected)

    def test_resume_keeps_normal_publication_and_forces_past_same_tip_skip(self):
        result = decisions.run_decide(event="workflow_dispatch", ref="refs/heads/nightly-next",
                                      tag_sha=decisions.HEAD_SHA,
                                      extra_env={"UNSIGNED_RUN": "123", "UNSIGNED_ATTEMPT": "1"})
        self.assertEqual(result["outputs"]["should_build"], "true")
        self.assertEqual(result["outputs"]["should_publish"], "true")

    def test_resume_is_rejected_on_wrong_track_or_conflicting_modes(self):
        for ref, extra in (("refs/heads/main", {}), ("refs/heads/nightly-next", {"FAST_BUILD": "true"}),
                           ("refs/heads/nightly-next", {"CONTINUE_ONLY": "true"}),
                           ("refs/heads/nightly-next", {"NOTARY_TEST_BROWSER_DATA": "true"})):
            with self.subTest(ref=ref, extra=extra):
                result = decisions.run_decide(event="workflow_dispatch", ref=ref,
                                              extra_env={"UNSIGNED_RUN": "123", "UNSIGNED_ATTEMPT": "1", **extra})
                self.assertIn("failed", result["outputs"])
                self.assertNotIn("should_build", result["outputs"])

    def test_signing_uses_new_controls_while_preserving_source_notices(self):
        step = next(step for step in self.jobs["build-sign-notarize-nightly"]["steps"]
                    if step["name"] == "Install the current signing keychain controls")
        controls = ("scripts/ci/signing-keychain.sh", "scripts/ci/lib/signing-runtime-guard.sh",
                    "scripts/import-apple-developer-id-intermediates.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for path in controls:
                source = root / path
                current = root / ".nightly-signing-control" / path
                for item, contents in ((source, "old"), (current, "trusted")):
                    item.parent.mkdir(parents=True, exist_ok=True)
                    item.write_text(contents)
            notices = root / "scripts/notices.json"
            notices.write_text("original source notices")
            subprocess.run(["bash", "-c", step["run"]], cwd=root, check=True,
                           env={**os.environ, "GITHUB_SHA": "control-commit", "GITHUB_STEP_SUMMARY": str(root / "summary")})
            self.assertTrue(all((root / path).read_text() == "trusted" for path in controls))
            self.assertEqual(notices.read_text(), "original source notices")


if __name__ == "__main__":
    unittest.main()
