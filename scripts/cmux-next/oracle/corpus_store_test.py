#!/usr/bin/env python3
"""Tests of corpus_store.py (code-size decision 3). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/corpus_store_test.py

Each test builds a small repository in a temporary directory (a manifest, a pin, a generator) and points the
module at it, so nothing touches this checkout, the network or R2.
"""

from __future__ import annotations

import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import corpus_store as cs  # noqa: E402

# A generator like gen_tla.py: writes the cases and, beside the suite, <out>/../../Expectations.d/s.txt.
GENERATOR = """import sys, pathlib
out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1])
out.mkdir(parents=True, exist_ok=True)
(out / "a.json").write_text('{"id": "a"}\\n')
(out / "sub").mkdir(exist_ok=True)
(out / "sub" / "b.json").write_text('{"id": "b"}\\n')
side = out.parent.parent / "Expectations.d"
side.mkdir(parents=True, exist_ok=True)
(side / "s.txt").write_text("generated block\\n")
"""


class Repo:
    """A temporary repository with suites `art` (artifact) and `gen` (generate), and the module pointed at it."""

    def __init__(self, tmp: Path) -> None:
        self.root = tmp
        self.corpus = tmp / "tests" / "oracle" / "corpus"
        (self.corpus / "art").mkdir(parents=True)
        (self.corpus / "art" / "README.md").write_text("hand-written\n")
        (tmp / "gen.py").write_text(GENERATOR)
        (tmp / "tests" / "oracle" / "corpus-store").mkdir(parents=True)
        self.manifest = {"suites": {
            "art": {"kind": "artifact", "pin": "tests/oracle/corpus-store/art.pin.json",
                    "generator": ["gen.py", "--out", "{out}"], "keep": ["README.md"]},
            "gen": {"kind": "generate", "generator": ["gen.py", "--out", "{out}"]},
        }}
        (tmp / "tests" / "oracle" / "corpus-store.json").write_text(json.dumps(self.manifest))
        self.saved = {k: getattr(cs, k) for k in ("REPO", "CORPUS", "MANIFEST", "STAGING", "fetch")}
        cs.REPO, cs.CORPUS = tmp, self.corpus
        cs.MANIFEST = tmp / "tests" / "oracle" / "corpus-store.json"
        cs.STAGING = tmp / "tests" / "oracle" / "corpus-store"
        cs._DONE.clear()
        self.fetched = None  # the tarball fetch() returns
        cs.fetch = lambda spec: self.fetched

    def restore(self) -> None:
        for key, value in self.saved.items():
            setattr(cs, key, value)
        cs._DONE.clear()

    def reference(self) -> Path:
        """The generator's output, packed, and the pin that names it."""
        ref = self.root / "ref" / "corpus" / "art"
        cs.run_generator(self.manifest["suites"]["art"], ref)
        tarball = self.root / "art.tar.gz"
        cs.pack(ref, (), tarball)
        self.write_pin(cs.tree_sha256(ref), 2)
        return tarball

    def write_pin(self, tree: str, files: int) -> None:
        (self.root / "tests" / "oracle" / "corpus-store" / "art.pin.json").write_text(
            json.dumps({"asset": "art.tar.gz", "sha256": "0" * 64, "tree_sha256": tree, "files": str(files)}))


class StoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))

    def tearDown(self) -> None:
        self.repo.restore()
        self._tmp.cleanup()

    def test_pack_is_deterministic_and_unpacks_to_the_same_tree(self):
        tarball = self.repo.reference()
        again = self.repo.root / "again.tar.gz"
        cs.pack(self.repo.root / "ref" / "corpus" / "art", (), again)
        self.assertEqual(tarball.read_bytes(), again.read_bytes())
        out = self.repo.root / "unpacked"
        cs.unpack(tarball, out)
        self.assertEqual(cs.tree_sha256(out), cs.tree_sha256(self.repo.root / "ref" / "corpus" / "art"))

    def test_unpack_refuses_a_path_outside_and_a_link(self):
        for member in (tarfile.TarInfo("../escape"), tarfile.TarInfo("/abs")):
            member.size = 1
            bad = self.repo.root / "bad.tar.gz"
            with tarfile.open(bad, "w:gz") as tar:
                tar.addfile(member, io.BytesIO(b"x"))
            with self.assertRaises(cs.StoreError):
                cs.unpack(bad, self.repo.root / "out")
        link = tarfile.TarInfo("link")
        link.type, link.linkname = tarfile.SYMTYPE, "/etc/passwd"
        with tarfile.open(self.repo.root / "link.tar.gz", "w:gz") as tar:
            tar.addfile(link)
        with self.assertRaises(cs.StoreError):
            cs.unpack(self.repo.root / "link.tar.gz", self.repo.root / "out")
        self.assertFalse((self.repo.root / "escape").exists())

    def test_another_root_is_left_alone(self):
        other = self.repo.root / "elsewhere" / "corpus"
        other.mkdir(parents=True)
        self.assertEqual(cs.ensure(other), {})
        self.assertEqual(list(other.iterdir()), [])

    def test_a_generate_suite_is_written_and_then_current(self):
        self.repo.reference()
        self.repo.fetched = None
        self.assertEqual(cs.ensure(self.repo.corpus, ["gen"]), {"gen": "generated"})
        self.assertEqual(sorted(p.relative_to(self.repo.corpus / "gen").as_posix()
                                for p in (self.repo.corpus / "gen").rglob("*.json")), ["a.json", "sub/b.json"])
        cs._DONE.clear()
        self.assertEqual(cs.ensure(self.repo.corpus, ["gen"]), {"gen": "current"})

    def test_an_artifact_suite_is_fetched_and_keeps_hand_written_files(self):
        self.repo.fetched = self.repo.reference()
        self.assertEqual(cs.ensure(self.repo.corpus, ["art"]), {"art": "fetched"})
        art = self.repo.corpus / "art"
        self.assertEqual((art / "README.md").read_text(), "hand-written\n")
        self.assertEqual(json.loads((art / cs.STAMP).read_text())["files"], 2)
        cs._DONE.clear()
        self.assertEqual(cs.ensure(self.repo.corpus, ["art"]), {"art": "current"})

    def test_a_stamp_whose_files_are_gone_is_written_again(self):
        """A checkout switch deletes the files git tracked on the other side and leaves the ignored stamp."""
        self.repo.fetched = self.repo.reference()
        cs.ensure(self.repo.corpus, ["art"])
        (self.repo.corpus / "art" / "a.json").unlink()
        cs._DONE.clear()
        self.assertEqual(cs.ensure(self.repo.corpus, ["art"]), {"art": "fetched"})
        self.assertTrue((self.repo.corpus / "art" / "a.json").is_file())

    def test_a_suite_its_generator_wrote_is_kept_until_publish(self):
        self.repo.fetched = self.repo.reference()
        cs.ensure(self.repo.corpus, ["art"])
        art = self.repo.corpus / "art"
        (art / "c.json").write_text('{"id": "c"}\n')  # a regeneration with one more case
        cs.mark_local(art)
        cs._DONE.clear()
        self.assertEqual(cs.ensure(self.repo.corpus, ["art"]), {"art": "local"})
        self.assertTrue((art / "c.json").is_file())

    def test_with_no_store_the_generator_writes_it_and_nothing_lands_beside_the_corpus(self):
        self.repo.reference()
        self.repo.fetched = None
        self.assertEqual(cs.ensure(self.repo.corpus, ["art"]), {"art": "generated"})
        self.assertFalse((self.repo.corpus / "Expectations.d").exists())
        self.assertEqual(list(cs.STAGING.glob(".tmp-*")), [])

    def test_a_fallback_that_differs_from_the_pin_is_an_error_of_that_suite_only(self):
        self.repo.write_pin("f" * 64, 2)
        with self.assertRaises(cs.StoreError):
            cs.ensure(self.repo.corpus, ["art"])
        cs._DONE.clear()
        result = cs.ensure(self.repo.corpus, ["art", "gen"], strict=False)
        self.assertTrue(result["art"].startswith("error: "), result)
        self.assertEqual(result["gen"], "generated")
        errors = cs.load_errors(self.repo.corpus, ["art"])
        self.assertEqual(len(errors), 1)
        self.assertIn("art: not written", errors[0])
        self.assertEqual(cs.load_errors(self.repo.corpus, ["gen"]), [])

    def test_verify_tarball_checks_the_tree_and_the_count(self):
        tarball = self.repo.reference()
        self.assertEqual(cs.verify_tarball("art", tarball), [])
        self.repo.write_pin("f" * 64, 3)
        self.assertEqual(len(cs.verify_tarball("art", tarball)), 2)


if __name__ == "__main__":
    unittest.main()
