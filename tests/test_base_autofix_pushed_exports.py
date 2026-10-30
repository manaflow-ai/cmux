#!/usr/bin/env python3
"""The base autofix takes the Swift exports a push's generated-files job already built, or the Mac job
regenerates them (cmuxterm-hq#5424, "one compile per base tree").

scripts/cmux-next/base-autofix-exports-pack.sh packs every export on the generated-files job's own
package build, named after the commit's tree; scripts/cmux-next/base_autofix_pushed_exports.py takes a
pack only from this repository's own feat-cmux-next push runs with every digest intact, prefers the
newest commit up to the tip (as the Mac job regenerated on the newest tip), waits a bounded time for this
push's own pack, and otherwise misses so cmux-next-base-autofix.yml's Mac job runs as before.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import base_autofix_pushed_exports as px  # noqa: E402

PACK_SCRIPT = ROOT / "scripts/cmux-next/base-autofix-exports-pack.sh"
AUTOFIX = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
NEXT = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
REPO, REPO_ID = "manaflow-ai/cmux", "123"
ENV = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID}
NAMES = px.exports(ROOT)


def oid(n: int) -> str:
    return f"{n:040x}"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pack_zip(tree: str, run_id: int, head: str, files: dict[str, bytes] | None = None, **overrides) -> bytes:
    files = files if files is not None else {rel: f"fresh {rel}\n".encode() for rel in NAMES}
    manifest = {"schema": px.SCHEMA, "tree": tree, "run_id": run_id, "source_sha": head,
                "files": {rel: sha256(data) for rel, data in files.items()}}
    manifest.update(overrides)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        for rel, data in files.items():
            archive.writestr(rel, data)
    return buffer.getvalue()


def artifact(tree: str, run_id: int, ident: int, *, repo_id: str = REPO_ID, branch: str = px.BRANCH,
             expired: bool = False, created: str = "2026-10-30T12:00:00Z") -> dict:
    return {"id": ident, "name": px.pack_name(tree), "expired": expired, "created_at": created,
            "archive_download_url": f"https://api/artifacts/{ident}",
            "workflow_run": {"id": run_id, "repository_id": int(repo_id), "head_repository_id": int(repo_id),
                             "head_branch": branch}}


def push_run(run_id: int, head: str, **overrides) -> dict:
    run = {"id": run_id, "event": "push", "path": px.WORKFLOW_PATH, "head_branch": px.BRANCH, "head_sha": head,
           "status": "completed", "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO}}
    run.update(overrides)
    return run


class FakeApi(px.Api):
    """Artifacts by tree, runs by id, cmux-next push runs (with their jobs) by head commit, and a clock."""

    def __init__(self, *, packs=None, blobs=None, runs=None, pushes=None, jobs=None, wait=600.0):
        self.packs, self.blobs, self.runs = packs or {}, blobs or {}, runs or {}
        self.pushes, self.jobs = pushes or {}, jobs or {}
        self.now, self.deadline = 0.0, wait
        self.calls: list[str] = []
        self.on_sleep = None

    def left(self) -> float:
        return self.deadline - self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
        if self.on_sleep:
            self.on_sleep(self)

    def json(self, path: str) -> dict:
        self.calls.append(path)
        if path.startswith("actions/artifacts?"):
            name = path.split("name=")[1].split("&")[0]
            return {"artifacts": [a for tree, items in self.packs.items() for a in items if px.pack_name(tree) == name]}
        if path.startswith("actions/workflows/"):
            head = path.split("head_sha=")[1].split("&")[0]
            return {"workflow_runs": self.pushes.get(head, [])}
        run_id = int(path.split("/")[2].split("?")[0])
        if "/jobs" in path:
            return {"jobs": self.jobs.get(run_id, [])}
        if run_id not in self.runs:
            raise px.Miss(f"GET actions/runs/{run_id} failed: HTTP 404")
        return self.runs[run_id]

    def download(self, url: str, dest: Path) -> None:
        self.calls.append(url)
        dest.write_bytes(self.blobs[int(url.rsplit("/", 1)[1])])


def lookup(api: FakeApi, history, sha: str, tree: str, into: Path, **kw):
    return px.lookup(api, lambda: history, sha, tree, ENV, NAMES, into, poll=60, first_run_grace=kw.get("grace", 0))


class TakesOnlyTrustedIntactPacks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        self.sha, self.tree = oid(1), oid(101)

    def tearDown(self):
        self.tmp.cleanup()

    def api_with(self, blob: bytes, *, run=None, art=None) -> FakeApi:
        return FakeApi(packs={self.tree: [art or artifact(self.tree, 7, 70)]}, blobs={70: blob},
                       runs={7: run or push_run(7, self.sha)})

    def test_a_pack_of_this_commit_is_taken_and_unpacked(self):
        api = self.api_with(pack_zip(self.tree, 7, self.sha))
        hit = lookup(api, [(self.sha, self.tree)], self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertEqual(hit["made_at"], self.sha)
        self.assertEqual(hit["source_run_id"], "7")
        for rel in NAMES:
            self.assertEqual((self.into / rel).read_bytes(), f"fresh {rel}\n".encode())

    def assert_miss(self, api: FakeApi, why: str):
        with self.assertRaises(px.Miss) as caught:
            lookup(api, [(self.sha, self.tree)], self.sha, self.tree, self.into)
        self.assertIn(why, str(caught.exception))
        self.assertFalse(self.into.exists(), "a refused pack must leave nothing behind")

    def test_a_file_that_does_not_match_its_digest_is_refused(self):
        files = {rel: b"fresh\n" for rel in NAMES}
        blob = pack_zip(self.tree, 7, self.sha, files)
        tampered = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(blob)) as source, zipfile.ZipFile(tampered, "w") as sink:
            for info in source.infolist():
                data = source.read(info.filename)
                sink.writestr(info.filename, b"replaced\n" if info.filename == NAMES[-1] else data)
        self.assert_miss(self.api_with(tampered.getvalue()), "does not match the pack's digest")

    def test_a_pack_missing_an_export_is_refused(self):
        files = {rel: b"x" for rel in NAMES[:-1]}
        self.assert_miss(self.api_with(pack_zip(self.tree, 7, self.sha, files)), "exactly the exports")

    def test_a_manifest_of_another_tree_or_run_is_refused(self):
        self.assert_miss(self.api_with(pack_zip(oid(999), 7, self.sha)), "another tree")
        self.assert_miss(self.api_with(pack_zip(self.tree, 8, self.sha)), "another run")

    def test_a_pack_whose_commit_is_not_its_runs_head_is_refused(self):
        self.assert_miss(self.api_with(pack_zip(self.tree, 7, oid(2))), "not the head of the run")

    def test_only_push_runs_of_cmux_next_on_the_branch_in_this_repository(self):
        blob = pack_zip(self.tree, 7, self.sha)
        cases = {
            "not a push": push_run(7, self.sha, event="pull_request"),
            "not .github/workflows/cmux-next.yml": push_run(7, self.sha, path=".github/workflows/other.yml"),
            "this repository's own": push_run(7, self.sha, head_repository={"full_name": "fork/cmux"}),
        }
        for why, run in cases.items():
            with self.subTest(why=why):
                self.assert_miss(self.api_with(blob, run=run), why.split(" on ")[0] if why != "not a push" else "not a push")

    def test_artifacts_of_forks_other_branches_or_expired_are_never_read(self):
        for art in (artifact(self.tree, 7, 70, repo_id="999"), artifact(self.tree, 7, 70, branch="main"),
                    artifact(self.tree, 7, 70, expired=True)):
            with self.subTest(art=art):
                api = self.api_with(pack_zip(self.tree, 7, self.sha), art=art)
                self.assert_miss(api, "none is coming")
                self.assertFalse(any(call.startswith("https://") for call in api.calls), "nothing downloaded")

    def test_no_repository_id_trusts_nothing(self):
        api = self.api_with(pack_zip(self.tree, 7, self.sha))
        with self.assertRaises(px.Miss):
            px.lookup(api, lambda: [], self.sha, self.tree, {"GITHUB_REPOSITORY": REPO}, NAMES, self.into, 60, 0)


class PrefersTheNewestPackUpToTheTip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        # The tip's first-parent line, newest first: tip (3), 2, the run's commit (1), an older one (0).
        self.history = [(oid(3), oid(103)), (oid(2), oid(102)), (oid(1), oid(101)), (oid(0), oid(100))]

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_newer_commits_pack_is_taken_and_named_as_made_at(self):
        api = FakeApi(packs={oid(102): [artifact(oid(102), 9, 90)], oid(101): [artifact(oid(101), 7, 70)]},
                      blobs={90: pack_zip(oid(102), 9, oid(2)), 70: pack_zip(oid(101), 7, oid(1))},
                      runs={9: push_run(9, oid(2)), 7: push_run(7, oid(1))})
        hit = lookup(api, self.history, oid(1), oid(101), self.into)
        self.assertEqual(hit["made_at"], oid(2))
        self.assertEqual(hit["source_run_id"], "9")

    def test_an_older_commits_pack_is_never_taken(self):
        api = FakeApi(packs={oid(100): [artifact(oid(100), 5, 50)]}, blobs={50: pack_zip(oid(100), 5, oid(0))},
                      runs={5: push_run(5, oid(0))})
        with self.assertRaises(px.Miss):
            lookup(api, self.history, oid(1), oid(101), self.into)

    def test_candidates_are_bounded_and_end_with_the_run_commit(self):
        history = [(oid(n), oid(100 + n)) for n in range(30, 0, -1)]
        got = px.candidates(history, oid(1), oid(101))
        self.assertEqual(len(got), px.NEWER_CANDIDATES + 1)
        self.assertEqual(got[0], (oid(30), oid(130)))
        self.assertEqual(got[-1], (oid(1), oid(101)))

    def test_a_commit_the_history_does_not_reach_looks_only_at_itself(self):
        self.assertEqual(px.candidates([], oid(1), oid(101)), [(oid(1), oid(101))])
        self.assertEqual(px.candidates(self.history[:1], oid(1), oid(101)), [(oid(1), oid(101))])


class WaitsABoundedTimeThenFallsBack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.into = Path(self.tmp.name) / "into"
        self.sha, self.tree = oid(1), oid(101)
        self.history = [(self.sha, self.tree)]

    def tearDown(self):
        self.tmp.cleanup()

    def running(self, jobs):
        return {self.sha: [push_run(7, self.sha, status="in_progress")]}, {7: jobs}

    def test_it_waits_for_this_pushs_generated_files_job_and_takes_its_pack(self):
        pushes, jobs = self.running([{"name": px.GENERATED_JOB, "status": "in_progress"}])
        api = FakeApi(pushes=pushes, jobs=jobs, runs={7: push_run(7, self.sha)}, blobs={70: pack_zip(self.tree, 7, self.sha)},
                      wait=1800)

        def finish(fake):
            if fake.now >= 600:  # the job finishes and uploads ten minutes in
                fake.jobs[7] = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "success"}]
                fake.packs[self.tree] = [artifact(self.tree, 7, 70)]
        api.on_sleep = finish
        hit = lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertLessEqual(api.now, 660)
        # Each poll reads one jobs list; artifacts are read only before and after the wait.
        self.assertEqual(len([c for c in api.calls if c.startswith("actions/artifacts?")]), 2)
        self.assertEqual(len([c for c in api.calls if c.startswith("actions/workflows/")]), 1)

    def test_a_folded_daemon_test_pack_is_taken_once_its_upload_step_is_done(self):
        upload = {"name": px.UPLOAD_STEP, "status": "queued"}
        pushes, jobs = self.running([{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                                     {"name": px.DAEMON_JOB, "status": "in_progress", "steps": [upload]}])
        api = FakeApi(pushes=pushes, jobs=jobs, runs={7: push_run(7, self.sha)}, blobs={70: pack_zip(self.tree, 7, self.sha)},
                      wait=1800)

        def upload_done(fake):
            if fake.now >= 300:  # the daemon tests go on for another 20 minutes after this
                upload["status"], upload["conclusion"] = "completed", "success"
                fake.packs[self.tree] = [artifact(self.tree, 7, 70)]
        api.on_sleep = upload_done
        hit = lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertEqual(hit["hit"], "true")
        self.assertLessEqual(api.now, 360)

    def test_daemon_test_is_not_waited_for_when_generated_files_ran(self):
        jobs = [{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "failure"},
                {"name": px.DAEMON_JOB, "status": "in_progress", "steps": [{"name": px.UPLOAD_STEP, "status": "queued"}]}]
        self.assertEqual(px.job_pending(jobs), "")
        self.assertIn(px.DAEMON_JOB, px.job_pending([{**jobs[0], "conclusion": "skipped"}, jobs[1]]))
        self.assertIn(px.GENERATED_JOB, px.job_pending([{"name": px.GENERATED_JOB, "status": "queued"}, jobs[1]]))

    def test_it_gives_up_at_the_deadline_while_the_job_still_runs(self):
        pushes, jobs = self.running([{"name": px.GENERATED_JOB, "status": "queued"}])
        api = FakeApi(pushes=pushes, jobs=jobs, wait=1800)
        with self.assertRaises(px.Miss) as caught:
            lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertIn("no pack within the wait", str(caught.exception))
        self.assertLessEqual(api.now, 1800)

    def test_it_does_not_wait_when_no_pack_is_coming(self):
        # Both producers skipped (path routing ran neither): miss at once.
        pushes, jobs = self.running([{"name": px.GENERATED_JOB, "status": "completed", "conclusion": "skipped"},
                                     {"name": px.DAEMON_JOB, "status": "completed", "conclusion": "skipped"}])
        api = FakeApi(pushes=pushes, jobs=jobs)
        with self.assertRaises(px.Miss) as caught:
            lookup(api, self.history, self.sha, self.tree, self.into)
        self.assertIn("none is coming", str(caught.exception))
        self.assertEqual(api.now, 0)

    def test_a_run_not_listed_yet_gets_a_grace_then_misses(self):
        api = FakeApi(wait=1800)
        with self.assertRaises(px.Miss):
            lookup(api, self.history, self.sha, self.tree, self.into, grace=180)
        self.assertGreaterEqual(api.now, 180)
        self.assertLess(api.now, 400)

    def test_jobs_not_listed_yet_count_as_pending(self):
        self.assertIn("not listed yet", px.job_pending([]))


class ChangedExports(unittest.TestCase):
    def test_only_exports_that_differ_from_head_go_to_the_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, staged, out = Path(tmp) / "repo", Path(tmp) / "staged", Path(tmp) / "out"
            for rel in NAMES:
                for base, text in ((repo, "committed"), (staged, "committed")):
                    (base / rel).parent.mkdir(parents=True, exist_ok=True)
                    (base / rel).write_text(text)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"], check=True)
            (staged / NAMES[0]).write_text("fresh")
            self.assertEqual(px.changed_exports(repo, staged, NAMES, out), [NAMES[0]])
            self.assertEqual((out / NAMES[0]).read_text(), "fresh")
            self.assertFalse((out / NAMES[1]).exists())


class PackScript(unittest.TestCase):
    """base-autofix-exports-pack.sh on a scratch repository, with fake regenerations."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        for name in ("base-autofix-exports-pack.sh", "base_autofix_pushed_exports.py", "settings-exports.txt"):
            (self.repo / "scripts/cmux-next" / name).write_bytes((ROOT / "scripts/cmux-next" / name).read_bytes())
        for rel in NAMES:
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / rel).write_text(f"committed {rel}\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        self.fake = Path(self.tmp.name) / "regen.sh"

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout.strip()

    def run_pack(self, actions_writes: list[str], settings_writes: list[str]):
        def script(paths):
            return "#!/usr/bin/env bash\n" + "".join(f"printf 'fresh %s\\n' '{p}' > '{p}'\n" for p in paths)
        actions, settings = Path(self.tmp.name) / "a.sh", Path(self.tmp.name) / "s.sh"
        actions.write_text(script(actions_writes))
        settings.write_text(script(settings_writes))
        actions.chmod(0o755)
        settings.chmod(0o755)
        out = Path(self.tmp.name) / "out"
        env = {**os.environ, "CMUX_BASE_EXPORTS_REGENERATE_ACTIONS": str(actions),
               "CMUX_BASE_EXPORTS_REGENERATE_SETTINGS": str(settings), "GITHUB_RUN_ID": "42"}
        # A stale export the checks left in the checkout, for the job's later steps.
        (self.repo / NAMES[0]).write_text("left by the checks\n")
        result = subprocess.run(["bash", "scripts/cmux-next/base-autofix-exports-pack.sh", str(out)],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        return result, out

    def test_every_export_is_packed_with_its_digest_and_the_checkout_is_put_back(self):
        actions = list(px.ACTION_EXPORTS)
        settings = [rel for rel in NAMES if rel not in actions]
        result, out = self.run_pack(actions, settings)
        self.assertEqual(result.returncode, 0, result.stderr)
        tree = self.git("rev-parse", "HEAD^{tree}")
        self.assertIn(f"name={px.NAME_PREFIX}{tree}", result.stdout)
        manifest = json.loads((out / "manifest.json").read_text())
        self.assertEqual(manifest["tree"], tree)
        self.assertEqual(manifest["source_sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(manifest["run_id"], 42)
        for rel in NAMES:
            self.assertEqual((out / rel).read_text(), f"fresh {rel}\n")
            self.assertEqual(manifest["files"][rel], sha256((out / rel).read_bytes()))
        self.assertEqual((self.repo / NAMES[0]).read_text(), "left by the checks\n")
        self.assertEqual((self.repo / NAMES[1]).read_text(), f"committed {NAMES[1]}\n")

    def test_an_export_a_failing_test_did_not_rewrite_makes_no_pack(self):
        actions = list(px.ACTION_EXPORTS)
        settings = [rel for rel in NAMES if rel not in actions][:-1]
        result, out = self.run_pack(actions, settings)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not rewrite", result.stderr)
        self.assertNotIn("name=", result.stdout)
        self.assertEqual((self.repo / NAMES[0]).read_text(), "left by the checks\n")
        self.assertEqual((self.repo / NAMES[-1]).read_text(), f"committed {NAMES[-1]}\n")


class Wiring(unittest.TestCase):
    def test_the_mac_job_runs_only_without_a_pack(self):
        mac = AUTOFIX["jobs"]["action-exports"]
        self.assertIn("pushed-exports", mac["needs"])
        self.assertIn("needs.pushed-exports.outputs.hit != 'true'", mac["if"])
        deferred = AUTOFIX["jobs"]["mac-exports-deferred"]
        self.assertIn("needs.pushed-exports.outputs.hit != 'true'", deferred["if"])

    def test_the_consumer_reads_only_and_its_wait_is_bounded(self):
        job = AUTOFIX["jobs"]["pushed-exports"]
        self.assertEqual(job["permissions"], {"contents": "read"})
        step = next(s for s in job["steps"] if s.get("id") == "lookup")
        # It polls, so only through the App's own budget, never github.token's shared one.
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.read-token.outputs.token }}")
        mint = next(s for s in job["steps"] if s.get("id") == "read-token")
        self.assertEqual(mint["with"]["permission-actions"], "read")
        self.assertTrue(step["continue-on-error"])
        self.assertIn("--wait 1800", step["run"])
        self.assertLess(1800 / 60, step["timeout-minutes"])
        self.assertLess(step["timeout-minutes"], job["timeout-minutes"])
        self.assertNotIn("runs-on: macos", json.dumps(job))
        self.assertIn("ubuntu", job["runs-on"])

    def test_autofix_uses_the_pack_as_this_commits_exports(self):
        job = AUTOFIX["jobs"]["autofix"]
        self.assertIn("pushed-exports", job["needs"])
        repair = next(s for s in job["steps"] if s.get("name") == "Repair")
        self.assertIn("needs.pushed-exports.outputs.hit == 'true'", repair["env"]["EXPORTS_VERIFIED"])
        download = next(s for s in job["steps"] if s.get("name") == "Download the regenerated action exports")
        self.assertIn("needs.pushed-exports.outputs.exports", download["if"])

    def test_the_producer_runs_on_branch_pushes_only_and_never_fails_its_job(self):
        steps = NEXT["jobs"]["generated-files"]["steps"]
        pack = next(s for s in steps if s.get("id") == "base-exports")
        self.assertIn("github.event_name == 'push'", pack["if"])
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", pack["if"])
        self.assertTrue(pack["continue-on-error"])
        self.assertIn("base-autofix-exports-pack.sh", pack["run"])
        names = [s.get("name") for s in steps]
        self.assertLess(names.index("Check the settings exports"), names.index(pack["name"]))
        self.assertLess(names.index(pack["name"]), names.index("Regenerate stale files"))
        upload = steps[names.index(pack["name"]) + 1]
        self.assertIn("upload-artifact", upload["uses"])
        self.assertEqual(upload["with"]["name"], "${{ steps.base-exports.outputs.name }}")
        self.assertEqual(upload["with"]["retention-days"], 1)

    def test_a_folded_daemon_test_packs_on_its_own_build(self):
        steps = NEXT["jobs"]["daemon-test"]["steps"]
        names = [s.get("name") for s in steps]
        pack = next(s for s in steps if s.get("id") == "base-exports")
        self.assertIn("env.CMUX_NEXT_FOLD_GENERATED == 'true'", pack["if"])
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", pack["if"])
        self.assertTrue(pack["continue-on-error"])
        self.assertLess(names.index("Check the settings exports"), names.index(pack["name"]))
        self.assertEqual(steps[names.index(pack["name"]) + 1]["name"], px.UPLOAD_STEP)
        self.assertEqual(NEXT["jobs"]["daemon-test"]["name"], px.DAEMON_JOB)
        self.assertEqual(NEXT["jobs"]["generated-files"]["name"], px.GENERATED_JOB)

    def test_both_workflows_start_on_changes_to_the_scripts(self):
        autofix_paths = AUTOFIX[True]["push"]["paths"]
        for path in ("scripts/cmux-next/base_autofix_pushed_exports.py", "scripts/cmux-next/base-autofix-exports-pack.sh"):
            self.assertIn(path, autofix_paths)

    def test_ci_runs_this_test(self):
        self.assertIn("tests/test_base_autofix_pushed_exports.py", (ROOT / ".github/workflows/cmux-next.yml").read_text())


if __name__ == "__main__":
    unittest.main()
