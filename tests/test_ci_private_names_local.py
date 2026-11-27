#!/usr/bin/env python3
"""private_names_local.py answers the checker's per-file contents reads from git: REST reads per run drop from
1 + N (files page, one contents read per changed file) to 1 (the files page)."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/ci/private_names_local.py"
spec = importlib.util.spec_from_file_location("private_names_local", SCRIPT)
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)

CHECKER = '''
import urllib.parse
READS = []
FILES = %r
def _get(path, token, raw=False, **kw):
    READS.append(path)
    if "/files" in path:
        return [{"filename": f, "status": "modified"} for f in FILES]
    raise AssertionError("contents read went to REST: " + path)
def main(argv):
    for f in FILES:
        _get_ = globals()["_get"]
        data = _get_("/repos/o/r/contents/" + urllib.parse.quote(f) + "?ref=" + SHA, "t", raw=True)
        assert data == ("body of " + f).encode(), (f, data)
    _get_("/repos/o/r/pulls/5/files?per_page=100&page=1", "t")
    return 0
SHA = %r
'''


class PrivateNamesLocal(unittest.TestCase):
    def run_with(self, count: int):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "r.git"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            names = [f"dir/file {i}.txt" for i in range(count)]
            for name in names:
                (repo / name).parent.mkdir(parents=True, exist_ok=True)
                (repo / name).write_text(f"body of {name}")
            git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-q", "-m", "x"], check=True)
            sha = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
            checker = Path(tmp) / "checker.py"
            checker.write_text(CHECKER % (names, sha))
            before = local.REST_READS, local.GIT_READS
            local.REST_READS = local.GIT_READS = 0
            code = local.main([str(checker), str(repo / ".git"), sha, "o/r", "5"])
            result = (code, local.REST_READS, local.GIT_READS)
            local.REST_READS, local.GIT_READS = before
            return result

    def test_contents_come_from_git(self):
        for count in (1, 6, 40):
            code, rest, git = self.run_with(count)
            self.assertEqual(code, 0)
            self.assertEqual(rest, 1, f"{count} files: only the files page is a REST read")
            self.assertEqual(git, count)

    def test_prefetch_uses_the_promisor_remote(self):
        # private-names.yml names its remote pr-head (the pool's git shim rewrites an origin of cmux into a fetch
        # without --depth or --filter); the batched blob fetch has to ask that remote, not origin.
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "h.git"
            subprocess.run(["git", "init", "-q", "--bare", str(repo)], check=True)
            self.assertEqual(local.promisor_remote(str(repo)), "origin")
            subprocess.run(["git", "-C", str(repo), "remote", "add", "pr-head", "https://example.invalid/r.git"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "remote.pr-head.promisor", "true"], check=True)
            self.assertEqual(local.promisor_remote(str(repo)), "pr-head")

    def test_workflow_remote_is_not_origin(self):
        workflow = (SCRIPT.parent.parent.parent / ".github/workflows/private-names.yml").read_text()
        self.assertIn('remote add pr-head "https://github.com/', workflow)
        self.assertIn("--filter=blob:none pr-head", workflow)
        self.assertNotIn("remote add origin", workflow)


if __name__ == "__main__":
    unittest.main()
