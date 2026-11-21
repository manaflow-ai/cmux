#!/usr/bin/env python3
"""git_batch.cat_file fetches a partial clone's missing blobs in one fetch, not one round trip each.

2026-11-21: a merge push from a blobless clone (`--filter=blob:none`, what wt mirrors are) spent the pre-push
gate's whole 600 s limit inside git_batch.cat_file, three times in a row: `cat-file --batch` fetched each of the
~9,000 missing blobs of the gate's temp trees with its own round trip to the promisor remote. cat_file now
probes for the missing blobs without fetching (GIT_NO_LAZY_FETCH) and fetches them all at once first.

The test makes a source repository, clones it blobless over file:// and reads every file through cat_file with
GIT_TRACE2_EVENT on, counting the `git fetch` processes git started (git's lazy fetch is a `git fetch` child,
started from git's exec path, so a PATH shim would not see it). The control reads the same specs with a bare
`git cat-file --batch` in a second fresh clone and must see one fetch per blob, so the count would catch a
regression.

  python3 -I tests/test_cmux_next_git_batch_prefetch.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = load("git_fixture_env", HERE / "git_fixture_env.py")  # importing it disables auto maintenance
git_batch = load("git_batch", REPO / "scripts" / "cmux-next" / "git_batch.py")

FILES = {f"dir{i % 3}/file{i}.txt": f"contents {i}\n" for i in range(12)}


def git(cwd: Path, *args: str, env: dict[str, str] | None = None, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", "-C", str(cwd), *args], input=data, capture_output=True, check=True,
                          env=env).stdout


def fetches(trace: Path) -> int:
    """The `git fetch` processes a GIT_TRACE2_EVENT file records."""
    count = 0
    if not trace.exists():
        return 0
    for line in trace.read_text().splitlines():
        event = json.loads(line)
        if event.get("event") == "start" and "fetch" in event.get("argv", [])[1:2]:
            count += 1
    return count


class GitBatchPrefetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.source = git_fixture_env.init_repo(root / "source", "-b", "main")
        for name, text in FILES.items():
            (self.source / name).parent.mkdir(parents=True, exist_ok=True)
            (self.source / name).write_text(text)
        git(self.source, "add", ".")
        git(self.source, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "files")
        git(self.source, "config", "uploadpack.allowFilter", "true")
        git(self.source, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.root = root
        self.specs = [f"HEAD:{name}" for name in FILES] + ["HEAD:no/such/file", "HEAD:dir0"]

    def tearDown(self):
        self.tmp.cleanup()

    def clone(self, name: str) -> Path:
        path = git_fixture_env.clone_repo(f"file://{self.source}", self.root / name, "--filter=blob:none",
                                          "--no-checkout")
        self.assertEqual(git(path, "config", "--get", "remote.origin.promisor").strip(), b"true")
        return path

    def missing(self, clone: Path) -> int:
        quiet = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
        out = git(clone, "cat-file", "--batch-check", env=quiet,
                  data="".join(f"HEAD:{name}\n" for name in FILES).encode()).decode()
        return sum(line.endswith(" missing") for line in out.splitlines())

    def test_missing_blobs_come_in_one_fetch(self):
        if not git_batch.honors_no_lazy_fetch():
            self.skipTest("git older than 2.44 has no GIT_NO_LAZY_FETCH; cat_file reads as before")
        clone = self.clone("prefetched")
        self.assertEqual(self.missing(clone), len(FILES))
        trace = self.root / "prefetched.trace"
        ids: dict[str, str] = {}
        found = git_batch.cat_file(clone, self.specs, env={**os.environ, "GIT_TRACE2_EVENT": str(trace)}, ids=ids)
        self.assertEqual(fetches(trace), 1, "every missing blob in one fetch")
        self.assertEqual(self.missing(clone), 0)
        for name, text in FILES.items():
            self.assertEqual(found[f"HEAD:{name}"], text.encode())
        self.assertEqual(len(ids), len(FILES))
        self.assertIsNone(found["HEAD:no/such/file"])
        self.assertIsNone(found["HEAD:dir0"])

        again = self.root / "again.trace"
        git_batch.cat_file(clone, self.specs, env={**os.environ, "GIT_TRACE2_EVENT": str(again)})
        self.assertEqual(fetches(again), 0, "a warm clone fetches nothing")

    def test_plain_batch_fetches_blob_by_blob(self):
        """The control: what cat_file did before, one fetch per missing blob, so the count above means something."""
        clone = self.clone("plain")
        trace = self.root / "plain.trace"
        git(clone, "cat-file", "--batch", env={**os.environ, "GIT_TRACE2_EVENT": str(trace)},
            data="".join(f"{spec}\n" for spec in self.specs).encode())
        self.assertEqual(fetches(trace), len(FILES))

    def test_failed_prefetch_falls_through(self):
        """A prefetch that cannot fetch (the remote is gone) leaves cat_file's answer to the plain read."""
        clone = self.clone("broken")
        git(clone, "remote", "set-url", "origin", f"file://{self.root / 'gone'}")
        self.assertEqual(git_batch.prefetch_missing_blobs(clone, self.specs), 0)
        with self.assertRaises(git_batch.GitError):
            git_batch.cat_file(clone, self.specs)

    def test_whole_clone_skips_the_probe(self):
        self.assertIsNone(git_batch.promisor_remote(self.source))
        self.assertEqual(git_batch.prefetch_missing_blobs(self.source, self.specs), 0)


if __name__ == "__main__":
    unittest.main()
