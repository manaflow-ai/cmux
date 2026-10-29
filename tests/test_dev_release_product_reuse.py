#!/usr/bin/env python3
"""scripts/ci/dev_release_product_reuse.py: a reused DEV Release app is trusted and intact, or the job compiles.

The lookup takes a record only from this repository's own push or dispatch runs of cmux-next.yml on
the DEV branch, checks the downloaded archive's SHA-256 against it, and runs only in that lane: never
nightly or stable (hq#3967). Every error is a miss with a reason, never a failed job. The key itself
is tests/test_dev_release_product_key.py.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import dev_release_product_reuse as reuse  # noqa: E402

def zip_bytes(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return buffer.getvalue()


REPO, REPO_ID, KEY, SHA = "manaflow-ai/cmux", "123", "c" * 64, "a" * 40
ENV = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID,
       "GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/cmux-next.yml@refs/heads/feat-cmux-next"}
APP = b"PK-the-unsigned-app" * 100


class FakeApi(reuse.Api):
    def __init__(self, runs: dict[int, dict], records: list[dict], files: dict[str, bytes],
                 products: dict[int, list[dict]], fail: str = ""):
        self.runs, self.records, self.files, self.products, self.fail = runs, records, files, products, fail
        self.calls = []

    def json(self, path: str) -> dict:
        self.calls.append(path)
        if self.fail and self.fail in path:
            raise reuse.Miss(f"GET {path} failed: HTTP 502")
        if path.startswith("actions/artifacts?"):
            return {"artifacts": self.records}
        run_id = int(path.split("/")[2])
        if path.endswith("/artifacts") or "/artifacts?" in path:
            return {"artifacts": self.products.get(run_id, [])}
        if "/jobs" in path:
            return {"jobs": self.runs[run_id].get("jobs", [{"name": "cmux NEXT DEV Release compile",
                                                            "status": "completed", "conclusion": "success"}])}
        return self.runs[run_id]

    def download(self, url: str, dest: Path) -> None:
        if url not in self.files:
            raise reuse.Miss("download failed (curl 22)")
        dest.write_bytes(self.files[url])


def trusted_run(run_id: int, **overrides) -> dict:
    run = {"id": run_id, "event": "workflow_dispatch", "path": ".github/workflows/cmux-next.yml",
           "head_branch": "feat-cmux-next", "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO}}
    run.update(overrides)
    return run


def setup(run_id: int = 7, created: str = "2026-10-24T10:00:00Z", app: bytes = APP, digest: str | None = None,
          repo_id: str = REPO_ID, expired: bool = False, **run_overrides):
    """A record from run `run_id` and the product artifact it names."""
    sha = format(run_id, "x").rjust(40, "a")
    archive_name = f"cmux-next-dev-daily-unsigned-{sha}.app.zip"
    manifest = {"schema": reuse.SCHEMA, "key": KEY, "run_id": run_id, "source_sha": sha,
                "product_artifact": reuse.PRODUCT_PREFIX + sha, "archive_name": archive_name,
                "archive_bytes": len(APP), "archive_sha256": digest or hashlib.sha256(APP).hexdigest(),
                "compiled_run_id": run_id}
    record = {"id": run_id * 10, "name": reuse.record_name(KEY), "expired": False, "created_at": created,
              "archive_download_url": f"record-{run_id}",
              "workflow_run": {"id": run_id, "repository_id": int(REPO_ID), "head_repository_id": int(repo_id),
                               "head_branch": "feat-cmux-next"}}
    product = {"id": run_id * 10 + 1, "name": reuse.PRODUCT_PREFIX + sha, "expired": expired,
               "archive_download_url": f"product-{run_id}"}
    files = {f"record-{run_id}": zip_bytes({"manifest.json": json.dumps(manifest).encode()}),
             f"product-{run_id}": zip_bytes({archive_name: app})}
    return trusted_run(run_id, **run_overrides), record, files, product


def fake(*setups, fail: str = "") -> FakeApi:
    runs, records, files, products = {}, [], {}, {}
    for run, record, more, product in setups:
        runs[run["id"]] = run
        records.append(record)
        files.update(more)
        products[run["id"]] = [product]
    return FakeApi(runs, records, files, products, fail)


class Lookup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def lookup(self, api: FakeApi, env: dict | None = None) -> dict:
        try:
            return reuse.lookup(api, KEY, env or ENV, self.out)
        except reuse.Miss as why:
            return {"hit": "false", "reason": str(why)}

    def test_a_trusted_record_with_a_matching_digest_is_a_hit(self):
        result = self.lookup(fake(setup(7)))
        self.assertEqual(result["hit"], "true", result)
        self.assertEqual(Path(result["archive"]).read_bytes(), APP)
        self.assertEqual(result["source_run_id"], "7")

    def test_the_newest_trusted_record_wins_and_a_broken_one_falls_back(self):
        result = self.lookup(fake(setup(7, "2026-10-24T09:00:00Z"), setup(8, "2026-10-24T10:00:00Z")))
        self.assertEqual(result["source_run_id"], "8")
        result = self.lookup(fake(setup(7, "2026-10-24T09:00:00Z"), setup(8, "2026-10-24T10:00:00Z", expired=True)))
        self.assertEqual((result["hit"], result["source_run_id"]), ("true", "7"), result)

    def test_a_record_from_an_unfinished_or_failed_app_job_is_never_taken(self):
        for jobs in ([{"name": "cmux NEXT DEV Release compile", "status": "in_progress", "conclusion": None}],
                     [{"name": "cmux NEXT DEV Release compile", "status": "completed", "conclusion": "failure"}],
                     [{"name": "cmux NEXT DEV Release compile", "status": "completed", "conclusion": "cancelled"}],
                     [{"name": "other", "status": "completed", "conclusion": "success"}]):
            with self.subTest(jobs=jobs):
                result = self.lookup(fake(setup(7, jobs=jobs)))
                self.assertEqual(result["hit"], "false")
                self.assertIn("did not finish successfully", result["reason"])

    def test_a_digest_mismatch_is_a_miss(self):
        result = self.lookup(fake(setup(7, app=b"X" * len(APP))))
        self.assertEqual(result["hit"], "false")
        self.assertIn("SHA-256 does not match", result["reason"])
        self.assertFalse(any(self.out.glob("*")) if self.out.exists() else False)

    def test_a_fork_or_pull_request_record_is_never_taken(self):
        result = self.lookup(fake(setup(7, repo_id="999")))
        self.assertIn("no product was recorded", result["reason"])
        for overrides in ({"event": "pull_request"}, {"head_branch": "other"}, {"path": ".github/workflows/nightly.yml"},
                          {"head_repository": {"full_name": "fork/cmux"}}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.lookup(fake(setup(7, **overrides)))["hit"], "false")

    def test_only_cmux_next_on_feat_cmux_next_reuses(self):
        for ref in (f"{REPO}/.github/workflows/nightly.yml@refs/heads/main",
                    f"{REPO}/.github/workflows/cmux-next.yml@refs/heads/main",
                    f"{REPO}/.github/workflows/cmux-next.yml@refs/pull/1/merge", ""):
            with self.subTest(ref=ref):
                api = fake(setup(7))
                result = self.lookup(api, {**ENV, "GITHUB_WORKFLOW_REF": ref})
                self.assertIn("not the DEV lane", result["reason"])
                self.assertEqual(api.calls, [])

    def test_an_unreachable_store_is_a_miss(self):
        self.assertIn("HTTP 502", self.lookup(fake(setup(7), fail="actions/artifacts?"))["reason"])
        api = fake(setup(7))
        api.files.pop("product-7")
        self.assertIn("curl 22", self.lookup(api)["reason"])

    def test_the_command_never_fails_the_job(self):
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
        with unittest.mock.patch.dict(os.environ, {**env, **ENV, "GH_TOKEN": "t", "GITHUB_API_URL": "http://127.0.0.1:9"},
                                      clear=True), unittest.mock.patch("sys.stdout", out):
            code = reuse.main(["lookup", "--key", KEY, "--out", str(self.out), "--timeout", "5", "--summary", ""])
        self.assertEqual(code, 0)
        self.assertIn("hit=false", out.getvalue())
        self.assertIn("reason=", out.getvalue())

    def test_a_record_round_trips(self):
        archive = Path(self.tmp.name) / f"cmux-next-dev-daily-unsigned-{SHA}.app.zip"
        archive.write_bytes(APP)
        manifest_path = Path(self.tmp.name) / "manifest.json"
        args = reuse.argparse.Namespace(key=KEY, sha=SHA, archive=str(archive), out=str(manifest_path),
                                        reused_from_run="5", reused_from_sha="b" * 40, compiled_run="3")
        manifest = reuse.record(args, {"GITHUB_RUN_ID": "9", "GITHUB_RUN_ATTEMPT": "1"})
        reuse.check_manifest(manifest, KEY, 9)
        self.assertEqual((manifest["origin"], manifest["compiled_run_id"]), ("reused", 3))
        self.assertEqual(manifest["archive_sha256"], hashlib.sha256(APP).hexdigest())


class Workflows(unittest.TestCase):
    def test_only_the_dev_release_compile_reuses_a_product(self):
        for workflow in (ROOT / ".github/workflows").glob("*.y*ml"):
            text = workflow.read_text()
            uses = "dev_release_product_reuse.py" in text or "cmux-next-dev-release-product-" in text
            with self.subTest(workflow=workflow.name):
                self.assertEqual(uses, workflow.name == "cmux-next.yml")
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text()
        job = text[text.index("\n  cmux-scheme-compile:\n"):text.index("\n  crash-ends-app:\n")]
        # The landing compile (push only, through dev-landing-place) looks up the same key.
        landing = text[text.index("\n  dev-landing-place:\n"):text.index("\n  request-cmux-next-dev-publish:\n")]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'",
                      landing.split("\n    if: ", 1)[1].splitlines()[0])
        self.assertEqual(text.count("dev_release_product_reuse.py lookup"),
                         job.count("dev_release_product_reuse.py lookup") + landing.count("dev_release_product_reuse.py lookup"))
        lookup = job[job.index("id: dev-product\n"):]
        condition = lookup.splitlines()[1]
        self.assertIn("refs/heads/feat-cmux-next", condition)
        self.assertNotIn("pull_request", condition)
        # A skipped step only ever skips on a dev_daily run; push runs compile Debug with them.
        for line in job.splitlines():
            if "steps.dev-product.outputs.hit != 'true'" in line and line.strip().startswith("if:"):
                self.assertIn("inputs.dev_daily != true ||", line)

    def test_an_unset_switch_leaves_reuse_on(self):
        # An unset variable is null in an expression, and null == '0' is true (both coerce to the
        # number 0): a bare `vars.X == '0'` switched reuse off for every run. Compare its string form.
        import re
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text()
        job = text[text.index("\n  cmux-scheme-compile:\n"):text.index("\n  crash-ends-app:\n")]
        lookup = job[job.index("id: dev-product\n"):job.index("      - name: Fetch the same-tree cmux-tui")]
        self.assertIn("format('{0}', vars.CI_NEXT_DEV_PRODUCT_REUSE) == '0'", lookup)
        self.assertEqual(re.findall(r"(?<!')vars\.[A-Z0-9_]+\s*==\s*'[0-9]", lookup), [])

    def test_every_variable_the_compile_step_reads_is_keyed(self):
        # The workflow file is keyed, but a repository variable's value is not in it: one that changes
        # the build (the Swift compilation mode) must be passed to the key by the lookup step.
        import re
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text()
        job = text[text.index("\n  cmux-scheme-compile:\n"):text.index("\n  crash-ends-app:\n")]
        lookup = job[job.index("id: dev-product\n"):job.index("      - name: Fetch the same-tree cmux-tui")]
        compile_step = job[job.index("id: compile-cmux-next-dev-release\n"):job.index("      - name: Upload DEV daily compile timing")]
        # The compilation cache decides how much is rebuilt, never what the product is.
        not_product = {"CMUX_NEXT_DEV_COMPILATION_CACHE"}
        for name in sorted(set(re.findall(r"vars\.([A-Z0-9_]+)", compile_step)) - not_product):
            with self.subTest(variable=name):
                self.assertIn(f"vars.{name}", lookup)


if __name__ == "__main__":
    unittest.main()
