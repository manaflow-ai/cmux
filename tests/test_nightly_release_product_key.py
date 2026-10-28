#!/usr/bin/env python3
"""The cmux NEXT Nightly app's product key and record namespace (job_input_fingerprint.py
nightly-release-product, dev_release_product_reuse.NIGHTLY_NEXT).

- Key coverage: the nightly key changes with every input that can reach the nightly app (app
  sources, nightly.yml, each of decide's build outputs, the toolchain, the cmux-tui tree) and not
  with docs or tests; the same tree under another commit keys the same.
- Namespace separation: a nightly key is never a DEV key, and a nightly lookup never takes a DEV
  record (nor the reverse): other record names, workflow, branch, events and producer job.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))
import dev_release_product_reuse as reuse  # noqa: E402
import job_input_fingerprint as fingerprint  # noqa: E402
from test_dev_release_product_key import FILES, git  # noqa: E402
from test_dev_release_product_reuse import FakeApi, zip_bytes  # noqa: E402

TOOLCHAIN = {"xcode": "Xcode 26.6 Build version 17F45", "sdk": "26.5 25F70", "arch": "arm64",
             "recipe": reuse.NIGHTLY_NEXT_RECIPE, "tui_tree": "own", "macos": "26.0.1", "macos_build": "25A362"}
FLAGS = {"track": "nightly-next", "channel": "nightly", "bundle_id": "com.cmuxterm.app.nightly.cmux-next",
         "app_name": "cmux NEXT", "url_scheme": "cmux-nightly", "entitlements": "cmux.entitlements",
         "icon_name": "AppIcon-Nightly", "variants": "arm64", "compile_archs": "arm64",
         "import_variant": "no-browser-data", "swift_import_flags": "-DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT",
         "empty_browser_sources": "false", "password_readers_out": "true"}
NIGHTLY_FILES = {**FILES, ".github/workflows/nightly.yml": "name: Nightly macOS build\n"}


class NightlyKey(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q")
        for name, text in NIGHTLY_FILES.items():
            self.write(name, text)
        self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self) -> None:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "c")

    def key(self, job: str = "nightly-release-product", **values) -> str:
        merged = {**TOOLCHAIN, **(FLAGS if job == "nightly-release-product" else {}), **values}
        if job == "dev-release-product":
            merged["recipe"] = reuse.RECIPE
            merged = {name: value for name, value in merged.items() if name not in ("macos", "macos_build")}
        extra = [f"{name}={value}" for name, value in merged.items()]
        return fingerprint.fingerprint(str(self.root), "HEAD", job, extra)[0]

    def test_every_decide_flag_and_toolchain_value_is_keyed(self):
        base = self.key()
        for name in [*fingerprint.NIGHTLY_PRODUCT_FLAGS, *TOOLCHAIN]:
            with self.subTest(value=name):
                self.assertNotEqual(self.key(**{name: "changed"}), base)

    def test_a_flag_is_required_even_when_empty(self):
        extra = [f"{name}={value}" for name, value in {**TOOLCHAIN, **FLAGS}.items() if name != "swift_import_flags"]
        with self.assertRaises(fingerprint.Unresolved):
            fingerprint.fingerprint(str(self.root), "HEAD", "nightly-release-product", extra)
        self.assertNotEqual(self.key(swift_import_flags=""), self.key())

    def test_app_inputs_and_the_nightly_workflow_change_the_key(self):
        for name in ("Packages/macOS/CmuxNext/Sources/App/App.swift", ".github/workflows/nightly.yml",
                     "cmux.xcodeproj/project.pbxproj", "scripts/cmux-next/check-cmux-scheme-compile.sh",
                     "cmux-tui/src/main.rs", "webviews/src/app.ts"):
            with self.subTest(path=name):
                before = self.key()
                self.write(name, (self.root / name).read_text() + "// changed\n")
                self.commit()
                self.assertNotEqual(self.key(), before)

    def test_docs_and_tests_do_not_change_the_key(self):
        before = self.key()
        for name in ("docs/guide.md", "tests/test_something.py",
                     "Packages/macOS/CmuxNext/Tests/AppTests/AppTests.swift", ".github/workflows/other.yml"):
            self.write(name, (self.root / name).read_text() + "changed\n")
        self.commit()
        self.assertEqual(self.key(), before)

    def test_the_same_tree_under_another_commit_keys_the_same(self):
        before = self.key()
        git(self.root, "commit", "-q", "--allow-empty", "-m", "another commit, same tree")
        self.assertEqual(self.key(), before)

    def test_a_nightly_key_is_never_a_dev_key(self):
        self.assertNotEqual(self.key(), self.key("dev-release-product"))
        # Not even with the DEV recipe: the job name and the keyed workflow differ.
        self.assertNotEqual(self.key(recipe=reuse.RECIPE), self.key("dev-release-product"))
        self.assertEqual(fingerprint.JOBS["nightly-release-product"].workflow, ".github/workflows/nightly.yml")
        self.assertEqual(fingerprint.JOBS["dev-release-product"].workflow, ".github/workflows/cmux-next.yml")


REPO, REPO_ID, KEY = "manaflow-ai/cmux", "123", "d" * 64
ENV = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID,
       "GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/nightly.yml@refs/heads/nightly-next"}


RUNNER = "blacksmith-6vcpu-macos-26-7npprz7qqt554pxv"
FRESH = {"runner_name": RUNNER, "runner_environment": "github-hosted", "kind": "blacksmith", "fresh_vm": True,
         "start": dict(reuse.CLEAN_START)}
JOB = {"name": "build-nightly-app", "status": "completed", "conclusion": "success", "runner_name": RUNNER,
       "runner_group_name": "blacksmith scale sets - blacksmith-6vcpu-macos-26"}


def record_setup(run_id: int, lane: reuse.Lane, builder: object = FRESH, **run_overrides):
    sha = format(run_id, "x").rjust(40, "a")
    archive_name = f"cmux-nightly-next-release-{sha}.tar.gz" if lane is reuse.NIGHTLY_NEXT else f"x-{sha}.app.zip"
    data = b"archive-bytes" * 50
    manifest = {"schema": lane.schema, "key": KEY, "run_id": run_id, "source_sha": sha,
                "product_artifact": lane.product_prefix + sha, "archive_name": archive_name,
                "archive_bytes": len(data), "archive_sha256": hashlib.sha256(data).hexdigest()}
    if builder is not None:
        manifest["builder"] = builder
    record = {"id": run_id * 10, "name": reuse.record_name(KEY, lane), "expired": False,
              "created_at": "2026-10-26T10:00:00Z", "archive_download_url": f"record-{run_id}",
              "workflow_run": {"id": run_id, "repository_id": int(REPO_ID), "head_repository_id": int(REPO_ID),
                               "head_branch": lane.branch}}
    product = {"id": run_id * 10 + 1, "name": lane.product_prefix + sha, "expired": False,
               "archive_download_url": f"product-{run_id}"}
    run = {"id": run_id, "event": lane.events[0], "path": lane.workflow_path, "head_branch": lane.branch,
           "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO},
           "jobs": [{**JOB, "name": lane.producer_jobs[0]}]}
    run.update(run_overrides)
    files = {f"record-{run_id}": zip_bytes({"manifest.json": json.dumps(manifest).encode()}),
             f"product-{run_id}": zip_bytes({archive_name: data})}
    return FakeApi({run_id: run}, [record], files, {run_id: [product]})


class Namespaces(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def lookup(self, api, lane, env=ENV) -> dict:
        try:
            return reuse.lookup(api, KEY, env, self.out, lane)
        except reuse.Miss as why:
            return {"hit": "false", "reason": str(why)}

    def test_the_lanes_share_no_name(self):
        dev, night = reuse.DEV, reuse.NIGHTLY_NEXT
        for field in ("schema", "recipe", "record_prefix", "product_prefix", "workflow_path", "branch", "producer_jobs"):
            with self.subTest(field=field):
                self.assertNotEqual(getattr(dev, field), getattr(night, field))
        self.assertFalse(night.record_prefix.startswith(dev.record_prefix) or dev.record_prefix.startswith(night.record_prefix))
        self.assertEqual(night.events, ("push",))

    def test_a_nightly_record_is_a_hit_for_the_nightly_lane(self):
        result = self.lookup(record_setup(7, reuse.NIGHTLY_NEXT), reuse.NIGHTLY_NEXT)
        self.assertEqual(result["hit"], "true", result)

    def test_a_dev_record_is_never_taken_as_a_nightly_product(self):
        result = self.lookup(record_setup(7, reuse.DEV), reuse.NIGHTLY_NEXT)
        self.assertEqual(result["hit"], "false")
        self.assertIn("no product was recorded", result["reason"])

    def test_a_nightly_record_is_never_taken_as_a_dev_product(self):
        dev_env = {**ENV, "GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/cmux-next.yml@refs/heads/feat-cmux-next"}
        result = self.lookup(record_setup(7, reuse.NIGHTLY_NEXT), reuse.DEV, dev_env)
        self.assertEqual(result["hit"], "false")

    def test_only_nightly_yml_on_nightly_next_reuses(self):
        for ref in (f"{REPO}/.github/workflows/cmux-next.yml@refs/heads/feat-cmux-next",
                    f"{REPO}/.github/workflows/nightly.yml@refs/heads/main",
                    f"{REPO}/.github/workflows/nightly.yml@refs/pull/1/merge", ""):
            with self.subTest(ref=ref):
                api = record_setup(7, reuse.NIGHTLY_NEXT)
                result = self.lookup(api, reuse.NIGHTLY_NEXT, {**ENV, "GITHUB_WORKFLOW_REF": ref})
                self.assertIn("not the nightly-next lane", result["reason"])
                self.assertEqual(api.calls, [])

    def test_only_a_push_run_whose_build_succeeded_is_trusted(self):
        for overrides in ({"event": "workflow_dispatch"}, {"event": "pull_request"}, {"head_branch": "main"},
                          {"path": ".github/workflows/cmux-next.yml"}, {"head_repository": {"full_name": "fork/cmux"}},
                          {"jobs": [{"name": "build-nightly-app", "status": "completed", "conclusion": "failure"}]},
                          {"jobs": [{"name": "build-nightly-app", "status": "in_progress", "conclusion": None}]},
                          {"jobs": [{"name": "cmux NEXT DEV Release compile", "status": "completed", "conclusion": "success"}]}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.lookup(record_setup(7, reuse.NIGHTLY_NEXT, **overrides), reuse.NIGHTLY_NEXT)["hit"], "false")


class FreshBuilder(unittest.TestCase):
    """A nightly record is taken only when it says a fresh VM built it from a clean start and the
    jobs API shows its producer job on that runner, in that runner's fresh-VM group."""

    def lookup(self, **kwargs) -> dict:
        with tempfile.TemporaryDirectory() as out:
            try:
                return reuse.lookup(record_setup(7, reuse.NIGHTLY_NEXT, **kwargs), KEY, ENV, Path(out), reuse.NIGHTLY_NEXT)
            except reuse.Miss as why:
                return {"hit": "false", "reason": str(why)}

    def test_a_fresh_blacksmith_or_github_hosted_build_is_taken(self):
        self.assertEqual(self.lookup()["hit"], "true")
        hosted = {**FRESH, "runner_name": "GitHub Actions 1000276410", "kind": "github-hosted"}
        job = {**JOB, "runner_name": "GitHub Actions 1000276410", "runner_group_name": "GitHub Actions"}
        self.assertEqual(self.lookup(builder=hosted, jobs=[job])["hit"], "true")

    def test_a_record_without_a_clean_fresh_builder_is_refused(self):
        cases = {
            "no builder": None,
            "not a dict": "blacksmith",
            "owned runner": {**FRESH, "runner_name": "cmux14-glaeda-2", "kind": "owned", "fresh_vm": False},
            "fresh flag missing": {name: value for name, value in FRESH.items() if name != "fresh_vm"},
            "kept DerivedData": {**FRESH, "start": {"derived_data": "kept", "compilation_cache": "empty"}},
            "kept compilation cache": {**FRESH, "start": {"derived_data": "empty", "compilation_cache": "kept"}},
            "no start": {name: value for name, value in FRESH.items() if name != "start"},
        }
        for label, builder in cases.items():
            with self.subTest(case=label):
                self.assertEqual(self.lookup(builder=builder)["hit"], "false")

    def test_the_jobs_api_must_show_the_job_on_that_fresh_runner(self):
        cases = {
            "another runner": [{**JOB, "runner_name": "blacksmith-6vcpu-macos-26-otherrunner"}],
            "an owned group": [{**JOB, "runner_group_name": "Default"}],
            "a hosted group for a blacksmith record": [{**JOB, "runner_group_name": "GitHub Actions"}],
            "no runner fields": [{"name": "build-nightly-app", "status": "completed", "conclusion": "success"}],
        }
        for label, jobs in cases.items():
            with self.subTest(case=label):
                result = self.lookup(jobs=jobs)
                self.assertEqual(result["hit"], "false")
                self.assertIn("does not show the producer job", result["reason"])

    def test_builder_kind(self):
        self.assertEqual(reuse.builder_kind(RUNNER), "blacksmith")
        self.assertEqual(reuse.builder_kind("GitHub Actions 12", "github-hosted"), "github-hosted")
        for name, environment in (("cmux14-glaeda-2", "self-hosted"), ("GitHub Actions 12", "self-hosted"),
                                  ("blacksmith", "github-hosted"), ("my-blacksmith-6vcpu-macos-26", "")):
            with self.subTest(runner=name):
                self.assertEqual(reuse.builder_kind(name, environment), "owned")
        # With the jobs API's group, the group decides.
        self.assertEqual(reuse.builder_kind(RUNNER, runner_group=JOB["runner_group_name"]), "blacksmith")
        self.assertEqual(reuse.builder_kind(RUNNER, runner_group="Default"), "owned")
        self.assertEqual(reuse.builder_kind("cmux14-glaeda-2", runner_group="blacksmith scale sets - x"), "owned")

    def test_record_refuses_a_builder_that_is_not_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, builder = Path(tmp) / "a.tar.gz", Path(tmp) / "builder.json"
            archive.write_bytes(b"x")
            for facts, ok in ((FRESH, True), ({**FRESH, "kind": "owned", "fresh_vm": False}, False)):
                builder.write_text(json.dumps(facts))
                args = argparse.Namespace(key=KEY, sha="a" * 40, archive=str(archive), out=str(Path(tmp) / "m.json"),
                                                reused_from_run="", reused_from_sha="", compiled_run="", builder=str(builder))
                with self.subTest(kind=facts["kind"]):
                    if ok:
                        self.assertEqual(reuse.record(args, {"GITHUB_RUN_ID": "9"}, reuse.NIGHTLY_NEXT)["builder"], FRESH)
                    else:
                        with self.assertRaises(SystemExit):
                            reuse.record(args, {"GITHUB_RUN_ID": "9"}, reuse.NIGHTLY_NEXT)


if __name__ == "__main__":
    unittest.main()
