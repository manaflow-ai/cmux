#!/usr/bin/env python3
"""scripts/ci/traced_inputs.py records what a traced command read, and its key moves only when one of those changes.

A temporary git repository holds a tiny "check" that reads one file, lists one directory, probes one absent path and
asks git for one committed path. The test traces it (strace; skipped where strace is missing or ptrace is refused),
then edits an input, an unread file, and the listed directory, and checks the key each time. It also checks the
receipt_input_key `names` rows the export writes and the audit that catches a read the list does not cover.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts" / "ci"))
import receipt_input_key as rik  # noqa: E402
import traced_inputs as ti  # noqa: E402

sys.path.insert(0, str(HERE))
import git_fixture_env  # noqa: E402

ENV = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                                   "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
CHECK = """\
import os, subprocess, sys
open("inputs/read.txt").read()
os.listdir("listed")
os.path.exists("absent.txt")
subprocess.run(["git", "show", "HEAD:shown.txt"], check=True, capture_output=True)
open("out/result.txt", "w").write("ok")      # an output: not an input
open("out/result.txt").read()                # reading back what it wrote: still not an input
"""


def strace_works() -> bool:
    if not shutil.which("strace"):
        return False
    return subprocess.run(["strace", "-f", "-qq", "-e", "trace=none", "true"], capture_output=True).returncode == 0


class ParseTest(unittest.TestCase):
    """Parsing needs no strace: canned lines in strace -y form."""

    def test_reads_lists_probes_and_writes(self):
        tr = ti.Trace()
        for line in [
            'openat(AT_FDCWD</r>, "a.txt", O_RDONLY|O_CLOEXEC) = 3</r/a.txt>',
            'openat(AT_FDCWD</r>, "b.txt", O_RDONLY) = -1 ENOENT (No such file or directory)',
            'openat(AT_FDCWD</r>, "o.txt", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 3</r/o.txt>',
            'getdents64(4</r/d>, 0x1 /* 3 entries */, 32768) = 80',
            'newfstatat(AT_FDCWD</r/sub>, "../c.txt", {st_mode=S_IFREG|0644, ...}, 0) = 0',
            'execve("/usr/bin/git", ["git", "show", "HEAD:x"], 0x1 /* 3 vars */) = 0',
            'connect(5<socket:[1]>, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("1.2.3.4")}, 16) = 0',
            'connect(5<socket:[2]>, {sa_family=AF_UNIX, sun_path="/run/x"}, 110) = 0',
        ]:
            tr.feed(line)
        self.assertIn("/r/a.txt", tr.reads)
        self.assertIn("/r/b.txt", tr.probed)
        self.assertIn("/r/o.txt", tr.written)
        self.assertIn("/r/d", tr.listed)
        self.assertIn("/r/c.txt", tr.probed)
        self.assertIn("/usr/bin/git", tr.reads)
        self.assertEqual(len(tr.connects), 1)

    def test_git_classes(self):
        self.assertEqual(ti.classify_git(["git", "show", "HEAD:a/b.txt"]), (None, ["a/b.txt"]))
        self.assertEqual(ti.classify_git(["git", "ls-tree", "HEAD", "--", "sub"]), (None, ["sub"]))
        self.assertEqual(ti.classify_git(["git", "ls-files"])[0], "L")
        self.assertEqual(ti.classify_git(["git", "log", "-1"])[0], "H")
        self.assertEqual(ti.classify_git(["git", "show", "HEAD~1:a"])[0], "H")
        self.assertEqual(ti.classify_git(["git", "diff", "--name-only", "HEAD^1"])[0], "H")
        self.assertEqual(ti.classify_git(["git", "rev-parse", "--show-toplevel"]), (None, []))
        self.assertEqual(ti.classify_git(["git", "-C", "mod", "log"], "/r", "/r"), (None, ["mod"]))


@unittest.skipUnless(strace_works(), "strace missing or ptrace refused")
class TraceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        for rel, text in {"check.py": CHECK, "inputs/read.txt": "1", "inputs/unread.txt": "1", "listed/a": "a",
                          "shown.txt": "s", "other/x.txt": "x", "out/.keep": ""}.items():
            self.write(rel, text)
        self.commit()
        self.manifest = Path(self.tmp.name) / "m.json"
        env = {**ENV, "PYTHONDONTWRITEBYTECODE": "1"}
        rc = subprocess.run([sys.executable, str(HERE.parent / "scripts/ci/traced_inputs.py"), "trace", "--root",
                             str(self.repo), "--out", str(self.manifest), "--", sys.executable, "-I", "check.py"],
                            cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(rc.returncode, 0, rc.stderr)
        self.man = json.loads(self.manifest.read_text())

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=ENV, capture_output=True,
                              text=True).stdout.strip()

    def write(self, rel, text):
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "c", "--allow-empty")
        return self.git("rev-parse", "HEAD")

    def key(self, rev="HEAD"):
        return ti.compute_key(self.man, self.repo, rev)[0]

    def test_manifest(self):
        e = self.man["entries"]
        self.assertEqual(e.get("inputs/read.txt"), "F")
        self.assertEqual(e.get("check.py"), "F")
        self.assertEqual(e.get("listed"), "N")
        self.assertEqual(e.get("absent.txt"), "E")
        self.assertEqual(e.get("shown.txt"), "F", "git show HEAD:P is a read of P")
        self.assertNotIn("inputs/unread.txt", e)
        self.assertNotIn("other/x.txt", e)
        self.assertNotIn("out/result.txt", e, "the check's own output is not an input")
        self.assertIsNone(self.man["git"])

    def test_key_moves_only_with_inputs(self):
        k0 = self.key()
        self.assertTrue(k0)
        self.write("inputs/unread.txt", "2")
        self.write("other/x.txt", "y")
        self.write("listed/a", "edited")  # listed, not read: content does not matter
        self.assertEqual(self.key(self.commit()), k0, "a change to nothing the check read moved the key")
        for rel, text in {"inputs/read.txt": "2", "shown.txt": "t", "absent.txt": "now here", "listed/b": "new",
                          "check.py": CHECK + "\n"}.items():
            before = self.key()
            self.write(rel, text)
            self.assertNotEqual(self.key(self.commit()), before, f"changing {rel} did not move the key")

    def test_export_matches_receipt_input_key_and_audit(self):
        rows = Path(self.tmp.name) / "inputs.txt"
        ti.main(["export", "--check", "t", "--root", str(self.repo), "--manifest", str(self.manifest), "--out", str(rows)])
        text = rows.read_text()
        self.assertIn("* names listed", text)
        self.assertIn("* blob inputs/read.txt", text)
        parsed = rik.load_inputs("t", rows)
        old_root, rik.ROOT = rik.ROOT, self.repo
        old_checks = dict(rik.CHECKS)
        rik.CHECKS["t"] = {"check": "t", "command": "python3 check.py"}
        try:
            k0, _ = rik.input_key("t", [], rows=parsed)
            self.write("listed/a", "edited")
            self.write("other/x.txt", "z")
            self.commit()
            self.assertEqual(rik.input_key("t", [], rows=parsed)[0], k0, "names row keyed on contents")
            self.write("listed/new", "n")
            self.commit()
            self.assertNotEqual(rik.input_key("t", [], rows=parsed)[0], k0, "names row missed an added entry")
            self.assertNotIn("listed", [p.rstrip("/*") for p in rik.pinned_patterns("t", "HEAD", parsed)])
        finally:
            rik.ROOT = old_root
            rik.CHECKS.clear()
            rik.CHECKS.update(old_checks)
        # The audit: the committed list covers this trace; drop a row and it names the miss.
        out = subprocess.run([sys.executable, str(HERE.parent / "scripts/ci/traced_inputs.py"), "audit",
                              "--manifest", str(self.manifest), "--inputs", str(rows), "--strict"],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout)
        rows.write_text("\n".join(l for l in text.splitlines() if "inputs/read.txt" not in l) + "\n")
        out = subprocess.run([sys.executable, str(HERE.parent / "scripts/ci/traced_inputs.py"), "audit",
                              "--manifest", str(self.manifest), "--inputs", str(rows), "--strict"],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 1)
        self.assertIn("F inputs/read.txt", out.stdout)


if __name__ == "__main__":
    unittest.main()
