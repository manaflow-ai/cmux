#!/usr/bin/env python3
"""git_batch.cat_file fetches a partial clone's missing blobs in one fetch, not one round trip each.

2026-11-21: a merge push from a blobless clone (`--filter=blob:none`, what wt mirrors are) spent the pre-push
gate's whole 600 s limit inside git_batch.cat_file, three times in a row: `cat-file --batch` fetched each of the
~9,000 missing blobs of the gate's temp trees with its own round trip to the promisor remote. cat_file now
reads with GIT_NO_LAZY_FETCH first, fetches the blobs that read missed in one fetch, and reads those again.

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
        # cmd_name, not argv: git's lazy fetch is `git -c fetch.negotiationAlgorithm=noop fetch ...`.
        if event.get("event") == "cmd_name" and event.get("name") == "fetch":
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
        self.assertEqual(git_batch.fetch_blobs(clone, "origin", self.specs), 0)

        def outcome(read):
            try:
                return read(clone, self.specs)
            except git_batch.GitError as error:
                return type(error)

        plain = outcome(lambda repo, specs: git_batch._cat_file_batch(repo, specs, None, None, set()))
        self.assertEqual(outcome(git_batch.cat_file), plain)

    def test_whole_clone_skips_the_probe(self):
        self.assertIsNone(git_batch.promisor_remote(self.source))
        self.assertEqual(git_batch.cat_file(self.source, self.specs)["HEAD:dir0/file0.txt"], b"contents 0\n")

    def by_id(self):
        """git_batch with every rev read by blob id (resolve_specs), however few its specs."""
        saved = git_batch.RESOLVE_MIN_SPECS
        git_batch.RESOLVE_MIN_SPECS = 1
        self.addCleanup(setattr, git_batch, "RESOLVE_MIN_SPECS", saved)

    def test_reading_by_blob_id_answers_as_reading_by_path(self):
        """2026-11-21: cat_file reads many specs of one rev by blob id from one `ls-tree -r` (cat-file resolved each
        `<rev>:<path>` from the root, 57.7 s for a merge push's 13,462 specs on big-red; 2 s by id). The answer,
        found or None (a missing path, a tree), and the ids must be the ones the path read gives."""
        specs = self.specs + ["HEAD~0:dir1/file1.txt", "no-such-rev:dir0/file0.txt"]
        plain_ids: dict[str, str] = {}
        plain = git_batch._cat_file_batch(self.source, specs, None, plain_ids, set())
        self.by_id()
        self.assertEqual(len(git_batch.resolve_specs(self.source, specs)), len(FILES) + 1,
                         "every blob read by id; the missing path, the tree and the bad rev by their text")
        ids: dict[str, str] = {}
        self.assertEqual(git_batch.cat_file(self.source, specs, ids=ids), plain)
        self.assertEqual(ids, plain_ids)

    def test_reading_by_blob_id_still_fetches_in_one_fetch(self):
        """In a blobless clone the probe asks by id: a missing blob answers `<id> missing`, joins the one fetch, and
        the reread by id gets it."""
        if not git_batch.honors_no_lazy_fetch():
            self.skipTest("git older than 2.44 has no GIT_NO_LAZY_FETCH; cat_file reads as before")
        self.by_id()
        clone = self.clone("by-id")
        trace = self.root / "by-id.trace"
        found = git_batch.cat_file(clone, self.specs, env={**os.environ, "GIT_TRACE2_EVENT": str(trace)})
        self.assertEqual(fetches(trace), 1, "every missing blob in one fetch")
        for name, text in FILES.items():
            self.assertEqual(found[f"HEAD:{name}"], text.encode())
        self.assertIsNone(found["HEAD:no/such/file"])
        self.assertIsNone(found["HEAD:dir0"])

    def test_few_specs_of_a_rev_are_read_by_path(self):
        """Below RESOLVE_MIN_SPECS the listing costs more than it saves: no ls-tree, the specs are asked as given."""
        self.assertLess(len(self.specs), git_batch.RESOLVE_MIN_SPECS)
        self.assertEqual(git_batch.resolve_specs(self.source, self.specs), {})


if __name__ == "__main__":
    unittest.main()
