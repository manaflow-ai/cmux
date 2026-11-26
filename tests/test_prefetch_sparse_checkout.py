#!/usr/bin/env python3
"""scripts/ci/prefetch-sparse-checkout.sh widens a blob:none sparse checkout to exactly the tree git gives.

path_route checks out two files, then the script prefetches the router's blobs in parallel and applies its
patterns (docs/ci/cmux-next-workflow-notes.md#note-558). The working tree must equal a plain checkout of the
same patterns: the same files with the same bytes, nothing excluded on disk, and the blobs fetched up front.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/prefetch-sparse-checkout.sh"
PATTERNS = ROOT / "scripts/ci/path-route-sparse-checkout.txt"

FILES = {
    "scripts/ci/prefetch-sparse-checkout.sh": SCRIPT.read_text(encoding="utf-8"),
    "scripts/ci/path-route-sparse-checkout.txt": PATTERNS.read_text(encoding="utf-8"),
    "scripts/ci/x.py": "print(1)\n",
    "cmux-tui/crates/a/Cargo.toml": "[package]\n",
    "cmux-tui/crates/a/src/lib.rs": "pub fn a() {}\n",
    "cmux-tui/crates/a/tests/fixtures/Application Support/x y.json": "{}\n",
    "Packages/macOS/CmuxNext/Sources/A.swift": "struct A {}\n",
    "Packages/macOS/CmuxNext/Sources/Localizable.xcstrings": "{}\n",
    "Packages/macOS/CmuxNext/Sources/icon.png": "png\n",
    "Packages/macOS/Other/Package.swift": "// swift-tools-version:6.0\n",
    "Packages/macOS/Other/Sources/B.swift": "struct B {}\n",
    "AGENTS.md": "agents\n",
    "web/index.ts": "export {}\n",
    "cmux-next-ios/verify/big.bin": "media\n",
}


def git(cwd: Path, *args: str, **kw) -> str:
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0"}
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env,
                          **kw).stdout


class PrefetchSparseCheckout(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        for path, text in FILES.items():
            (src / path).parent.mkdir(parents=True, exist_ok=True)
            (src / path).write_text(text, encoding="utf-8")
        git(src, "add", "-A")
        git(src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tree")
        git(src, "config", "uploadpack.allowFilter", "true")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.url = f"file://{src}"

    def clone(self, name: str, patterns: str) -> Path:
        work = self.tmp / name
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", self.url)
        git(work, "config", "core.sparseCheckout", "true")
        (work / ".git/info/sparse-checkout").write_text(patterns, encoding="utf-8")
        git(work, "fetch", "-q", "--no-tags", "--filter=blob:none", "--depth=1", "origin", "main")
        git(work, "checkout", "-q", "--force", "FETCH_HEAD")
        return work

    @staticmethod
    def tree(work: Path) -> dict[str, bytes]:
        return {p.relative_to(work).as_posix(): p.read_bytes() for p in work.rglob("*")
                if p.is_file() and ".git" not in p.relative_to(work).parts}

    def test_widened_tree_equals_a_plain_checkout_of_the_patterns(self):
        want = self.tree(self.clone("plain", PATTERNS.read_text(encoding="utf-8")))
        work = self.clone("lean", "/scripts/ci/prefetch-sparse-checkout.sh\n/scripts/ci/path-route-sparse-checkout.txt\n")
        self.assertEqual(sorted(self.tree(work)), ["scripts/ci/path-route-sparse-checkout.txt",
                                                    "scripts/ci/prefetch-sparse-checkout.sh"])
        with PATTERNS.open(encoding="utf-8") as stdin:
            out = subprocess.run(["bash", str(SCRIPT)], cwd=work, stdin=stdin, check=True, capture_output=True,
                                 text=True, env={**os.environ, "GH_TOKEN": "", "PREFETCH_JOBS": "3"}).stdout
        self.assertEqual(self.tree(work), want)
        self.assertIn("cmux-tui/crates/a/tests/fixtures/Application Support/x y.json", want)
        self.assertNotIn("Packages/macOS/CmuxNext/Sources/icon.png", want)
        self.assertNotIn("web/index.ts", want)
        self.assertIn("Packages/macOS/Other/Package.swift", want)
        # The prefetch named every checked-out blob (one per distinct content), so the reapply fetched none lazily.
        self.assertRegex(out, rf"sparse prefetch: {len(set(want.values()))} blobs in 3 fetches")

    def test_a_failed_chunk_fetch_is_tried_again_before_the_lazy_fallback(self):
        """A stalled or dropped pack (GitHub, 2026-11-25) costs one retry, not a one-by-one lazy fetch."""
        want = self.tree(self.clone("plain", PATTERNS.read_text(encoding="utf-8")))
        work = self.clone("lean", "/scripts/ci/prefetch-sparse-checkout.sh\n/scripts/ci/path-route-sparse-checkout.txt\n")
        shim, marks = self.tmp / "bin", self.tmp / "marks"
        shim.mkdir()
        marks.mkdir()
        real = subprocess.run(["bash", "-c", "command -v git"], check=True, capture_output=True, text=True).stdout.strip()
        # Every chunk's first fetch fails; its second is the real one.
        (shim / "git").write_text(f"""#!/usr/bin/env bash
if [[ " $* " == *" fetch "* && " $* " == *" --stdin "* ]]; then
  input="$(cat)"
  if mkdir "{marks}/$(printf '%s' "$input" | sha1sum | cut -c1-16)" 2>/dev/null; then exit 1; fi
  printf '%s\\n' "$input" | exec {real} "$@"
fi
exec {real} "$@"
""", encoding="utf-8")
        (shim / "git").chmod(0o755)
        env = {**os.environ, "GH_TOKEN": "", "PREFETCH_JOBS": "3", "PATH": f"{shim}:{os.environ['PATH']}"}
        with PATTERNS.open(encoding="utf-8") as stdin:
            run = subprocess.run(["bash", str(SCRIPT)], cwd=work, stdin=stdin, check=True, capture_output=True,
                                 text=True, env=env)
        self.assertEqual(self.tree(work), want)
        self.assertEqual(len(list(marks.iterdir())), 3)
        self.assertEqual(run.stderr.count("failed (try 1)"), 3)
        self.assertNotIn("::warning::", run.stdout)

    def test_a_full_clone_only_applies_the_patterns(self):
        """A pool VM's checkout borrows its mirror unfiltered: `fetch --filter` there is an error, so none runs."""
        want = self.tree(self.clone("plain", PATTERNS.read_text(encoding="utf-8")))
        work = self.tmp / "full"
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", self.url)
        git(work, "config", "core.sparseCheckout", "true")
        (work / ".git/info/sparse-checkout").write_text("/scripts/ci/prefetch-sparse-checkout.sh\n", encoding="utf-8")
        git(work, "fetch", "-q", "--no-tags", "--depth=1", "origin", "main")
        git(work, "checkout", "-q", "--force", "FETCH_HEAD")
        with PATTERNS.open(encoding="utf-8") as stdin:
            out = subprocess.run(["bash", str(SCRIPT)], cwd=work, stdin=stdin, check=True, capture_output=True,
                                 text=True, env={**os.environ, "GH_TOKEN": ""}).stdout
        self.assertIn("not a partial clone", out)
        self.assertEqual(self.tree(work), want)


if __name__ == "__main__":
    unittest.main()
