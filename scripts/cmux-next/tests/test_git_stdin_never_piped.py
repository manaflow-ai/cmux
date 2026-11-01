#!/usr/bin/env python3
"""The pre-push hook's git batch reads never send their request through a pipe.

2026-10-28: about a dozen agents' pushes hung 25-60 minutes inside the pre-push hook (a817, a786, a796, a808).
The stacks showed the hook's Python blocked in write() to `git cat-file --batch`'s stdin: on a Mac short of
pipe memory (git_batch.py) a write into a pipe blocks in the kernel for good, so subprocess's `timeout=60`
never runs, and each stuck hook holds its pipes, which makes the next push hang too. A request through a
temporary file cannot block. The test puts a `git` first on PATH that hangs whenever its stdin is a pipe
(what that Mac does) and requires each reader to answer inside a deadline.

  python3 scripts/cmux-next/tests/test_git_stdin_never_piped.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
HOOKS = SCRIPTS.parent / "git-hooks"
REPO = SCRIPTS.parents[1]
SPEC = "HEAD:scripts/cmux-next/git_batch.py"
DEADLINE = 20.0

# Each snippet loads one hook-path module by file and reads SPEC with its own batch reader.
READERS = {
    "refresh_checks.blobs": (HOOKS / "refresh_checks.py", "print(len(m.blobs(repo, [spec])[0]) > 0)"),
    "compile_trailer.blobs": (SCRIPTS / "compile_trailer.py", "print(bool(m.blobs(repo, [spec])[spec]))"),
    "layer_gate.blobs": (SCRIPTS / "arch_rules" / "layer_gate.py",
                         "rev, path = spec.split(':', 1)\nprint(bool(m.blobs(repo, [(rev, path)])[0]))"),
}


class GitStdinNeverPipedTest(unittest.TestCase):
    def setUp(self):
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        self.tmp = tempfile.TemporaryDirectory()
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        git = bin_dir / "git"
        git.write_text(f"#!/bin/sh\nif [ -p /dev/stdin ]; then exec sleep 600; fi\nexec {real_git} \"$@\"\n")
        git.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ.get('PATH', '')}")

    def tearDown(self):
        self.tmp.cleanup()

    def answers(self, name: str) -> None:
        path, body = READERS[name]
        code = ("import importlib.util, sys\n"
                f"sys.path[:0] = [{str(path.parent)!r}, {str(SCRIPTS)!r}]\n"
                f"spec_ = importlib.util.spec_from_file_location('m', {str(path)!r})\n"
                "m = importlib.util.module_from_spec(spec_); sys.modules['m'] = m; spec_.loader.exec_module(m)\n"
                f"from pathlib import Path\nrepo = Path({str(REPO)!r}); spec = {SPEC!r}\n" + body + "\n")
        child = subprocess.Popen([sys.executable, "-I", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            out, err = child.communicate(timeout=DEADLINE)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, 9)  # this test's own child and the fake git it started
            child.communicate()
            self.fail(f"{name} sent its git request through a pipe and hung past {DEADLINE:.0f}s")
        self.assertEqual(child.returncode, 0, err)
        self.assertEqual(out.strip(), "True", err)

    def test_refresh_checks(self):
        self.answers("refresh_checks.blobs")

    def test_compile_trailer(self):
        self.answers("compile_trailer.blobs")

    def test_layer_gate(self):
        self.answers("layer_gate.blobs")


if __name__ == "__main__":
    unittest.main()
