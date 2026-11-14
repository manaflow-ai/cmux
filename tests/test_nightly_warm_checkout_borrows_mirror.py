#!/usr/bin/env python3
"""A cold nightly-next builder slot borrows the mini's git mirror before it fetches from GitHub.

Jobs 132417366047 (cmux15-glaeda, "fetched 4688ecb1... in 267 s") and 132487716521 (cmux15-glaeda-1,
"fetched 5e31c1f3... in 278 s") landed on slots whose git store was gone and fetched about 2.6 GiB of
history at about 9.7 MiB/s. Only at job end did glaeda's job-completed hook link the slot to the mirror
(".../_work/cmux/cmux/.git borrows /Users/Shared/cmux-build-fleet/git/cmux.git/objects; repacked against
the mirror: 2634 MiB -> 0 MiB"). A warm slot (job 132479503006) fetched in 0 s.

The step "Checkout build ref (warm nightly-next builder)" now writes the borrow record and the
alternates line itself before its fetch, when the mirror is healthy, so the fetch sends only what the
mirror lacks. The record is the one glaeda's hook reads at job-started (guard_borrowed_checkout,
same_mirror): {"objects", "dev", "ino"}, no birth time (a record without one matches on the inode;
job-completed's borrow_mirror then adds it). A slot that lists the mirror without a matching record is
wiped at job-started, so the record is written first.

This test runs the step's own `run:` text from nightly.yml against a temp mirror and an empty slot whose
origin is a local repository. Run it yourself after changing the warm checkout step or glaeda's borrow
record: python3 tests/test_nightly_warm_checkout_borrows_mirror.py (a few seconds, git only, no network,
no Mac).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]
WARM_STEP = "Checkout build ref (warm nightly-next builder)"
RECORD = "glaeda-mirror-borrow.json"


def real_git() -> str:
    """The first git on PATH that is git itself, not a wrapper script that would find the shim below again."""
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(folder or ".") / "git"
        if not (candidate.is_file() and os.access(candidate, os.X_OK)):
            continue
        with candidate.open("rb") as handle:
            if handle.read(2) != b"#!":
                return str(candidate)
    return shutil.which("git") or "git"


REAL_GIT = real_git()

# On PATH ahead of git: at each top-level `git fetch`, note what the slot borrows, then run git.
GIT_SHIM = """#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    {
      printf 'fetch:'
      if [ -f "$GITHUB_WORKSPACE/.git/$SHIM_RECORD" ]; then printf ' record'; fi
      if grep -qxF "$SHIM_OBJECTS" "$GITHUB_WORKSPACE/.git/objects/info/alternates" 2>/dev/null; then printf ' alternates'; fi
      echo
    } >> "$SHIM_LOG"
    break
  fi
done
exec "$SHIM_REAL_GIT" "$@"
"""


def step(job: str, name: str) -> dict:
    return next(s for s in JOBS[job]["steps"] if s.get("name") == name)


class WarmCheckoutBorrowsMirrorTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        for folder in ("bin", "home", "runner-temp"):
            (self.temp / folder).mkdir()
        self.env = git_fixture_env.fixture_env({
            "PATH": f"{self.temp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        # The step's helper download must not reach the network from a test.
        (self.temp / "bin/curl").write_text("#!/bin/sh\nexit 7\n")
        (self.temp / "bin/curl").chmod(0o755)
        self.origin = self.temp / "origin"
        self.git(self.temp, "init", "-q", "-b", "main", str(self.origin))
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.commit({"scripts/ci/git_fetch_retry.py": (ROOT / "scripts/ci/git_fetch_retry.py").read_text(),
                     "README": "one\n"}, "first")
        self.sha = self.commit({"README": "two\n", "Sources/App.swift": "let build = 2\n"}, "the build")
        # glaeda's mirror: a full bare mirror of origin, checked once (glaeda-verified).
        self.fleet_git = self.temp / "fleet/git"
        self.fleet_git.mkdir(parents=True)
        self.mirror = self.fleet_git / "cmux.git"
        self.git(self.temp, "clone", "-q", "--mirror", str(self.origin), str(self.mirror))
        (self.mirror / "glaeda-verified").write_text("ok\n")
        self.objects = str(self.mirror / "objects")
        # A runner slot whose git store was deleted: the workspace is there, its .git is not.
        self.ws = self.temp / "actions-runner-1/_work/cmux/cmux"
        self.ws.mkdir(parents=True)
        self.log = self.temp / "fetches.log"

    def git(self, cwd: Path, *args: str) -> str:
        result = subprocess.run([REAL_GIT, *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result.stdout.strip()

    def commit(self, tree: dict[str, str], message: str) -> str:
        for name, text in tree.items():
            path = self.origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-qm", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def run_warm_step(self) -> subprocess.CompletedProcess:
        warm = step("build-nightly-app", WARM_STEP)
        script = self.temp / "runner-temp/warm-checkout.sh"
        script.write_text(warm["run"])
        shim = self.temp / "bin/git"
        shim.write_text(GIT_SHIM)
        shim.chmod(0o755)
        env = {**self.env, "BUILD_SHA": self.sha, "WORKFLOW_SHA": self.sha, "REPO_URL": self.origin.as_uri(),
               "GITHUB_WORKSPACE": str(self.ws), "RUNNER_TEMP": str(self.temp / "runner-temp"),
               "GITHUB_REPOSITORY": "o/r", "GLAEDA_GIT_MIRROR_DIR": str(self.fleet_git),
               "SHIM_REAL_GIT": REAL_GIT, "SHIM_LOG": str(self.log), "SHIM_RECORD": RECORD,
               "SHIM_OBJECTS": self.objects}
        # The runner's default for a `run:` step with no `shell:` is `bash -e {0}`.
        result = subprocess.run(["bash", "-e", str(script)], cwd=self.temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"the warm checkout step failed\n{result.stdout}\n{result.stderr}")
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), self.sha)
        self.assertEqual((self.ws / "Sources/App.swift").read_text(), "let build = 2\n")
        return result

    def fetches(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def local_objects(self) -> dict[str, int]:
        counts = {}
        for line in self.git(self.ws, "count-objects", "-v").splitlines():
            key, _, value = line.partition(": ")
            counts[key] = int(value)
        return counts

    def alternates(self) -> list[str]:
        path = self.ws / ".git/objects/info/alternates"
        return path.read_text().splitlines() if path.exists() else []

    # -- a healthy mirror: the slot borrows it before the fetch ---------------------------------------

    def test_a_cold_slot_borrows_the_mirror_before_it_fetches(self) -> None:
        result = self.run_warm_step()
        self.assertTrue(self.fetches(), "the step ran no git fetch")
        self.assertEqual(self.fetches()[0], "fetch: record alternates",
                         "the slot must list the mirror and hold its borrow record when the fetch starts")
        self.assertEqual(self.alternates(), [self.objects])
        self.assertIn("cold slot: borrowing", result.stdout)
        self.assertIn("MiB", result.stdout.split("cold slot: borrowing", 1)[1].splitlines()[0])

    def test_the_fetch_of_a_commit_the_mirror_has_transfers_nothing(self) -> None:
        self.run_warm_step()
        counts = self.local_objects()
        self.assertEqual((counts["count"], counts["packs"], counts["size-pack"]), (0, 0, 0),
                         f"the slot stored objects of its own: {counts}")
        self.assertEqual(counts.get("size-garbage", 0), 0)

    def test_the_record_is_the_one_glaedas_job_started_guard_keeps(self) -> None:
        self.run_warm_step()
        recorded = json.loads((self.ws / ".git" / RECORD).read_text())
        st = os.stat(self.objects, follow_symlinks=False)
        # same_mirror in glaeda's scripts/glaeda-cmux-runner-hook: the inode, and the device where the
        # filesystem has no birth time; a recorded birth time must be the directory's own.
        self.assertEqual(recorded["objects"], self.objects)
        self.assertIsInstance(recorded["ino"], int)
        self.assertEqual(recorded["ino"], st.st_ino)
        self.assertEqual(recorded["dev"], st.st_dev)
        birth = getattr(st, "st_birthtime", None)
        if birth is not None:
            self.assertEqual(recorded.get("birth", birth), birth)
        else:
            self.assertNotIn("birth", recorded)
        # guard_borrowed_checkout keeps a slot whose alternates name os.fspath(mirror / "objects") exactly.
        self.assertIn(self.objects, self.alternates())

    def test_a_slot_that_already_borrows_is_left_as_it_is(self) -> None:
        self.run_warm_step()
        record = (self.ws / ".git" / RECORD).read_text()
        result = self.run_warm_step()
        self.assertEqual(self.alternates(), [self.objects], "the alternates line was written twice")
        self.assertEqual((self.ws / ".git" / RECORD).read_text(), record)
        self.assertNotIn("cold slot: borrowing", result.stdout)

    # -- an unhealthy or missing mirror: the slot is untouched and fetches from origin as before -------

    def assert_untouched(self) -> None:
        self.run_warm_step()
        self.assertFalse((self.ws / ".git" / RECORD).exists(), "a record was written for an unusable mirror")
        self.assertEqual(self.alternates(), [], "the slot borrows an unusable mirror")
        self.assertEqual(self.fetches()[0], "fetch:")
        self.assertGreater(self.local_objects()["count"] + self.local_objects()["packs"], 0,
                           "the fetch from origin brought no objects")

    def test_no_mirror(self) -> None:
        shutil.rmtree(self.mirror)
        self.assert_untouched()

    def test_a_mirror_never_verified(self) -> None:
        (self.mirror / "glaeda-verified").unlink()
        self.assert_untouched()

    def test_a_mirror_with_a_repair_pending(self) -> None:
        (self.mirror / "glaeda-repair-pending").write_text("")
        self.assert_untouched()

    def test_a_shallow_mirror(self) -> None:
        (self.mirror / "shallow").write_text(self.sha + "\n")
        self.assert_untouched()

    def test_a_mirror_without_head(self) -> None:
        (self.mirror / "HEAD").unlink()
        self.assert_untouched()

    def test_a_symlinked_mirror(self) -> None:
        real = self.fleet_git / "cmux-real.git"
        self.mirror.rename(real)
        self.mirror.symlink_to(real)
        self.assert_untouched()


if __name__ == "__main__":
    unittest.main()
