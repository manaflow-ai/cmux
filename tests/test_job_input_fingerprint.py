#!/usr/bin/env python3
"""scripts/ci/job_input_fingerprint.py: a changed input never reuses a pass.

CI_NEXT_JOB_REUSE reuses a fast-tier pass recorded under the same key. The key must change when anything the
job could read changes: any file in the commit's tree, the whole cmux-next.yml, and the toolchain (Xcode for
fast-tier; Rust and Zig for fast-tier-cargo). The same inputs must give the same key, so a rerun or a re-push
of the same tree reuses. Each case builds a small repository and compares keys before and after one change.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/job_input_fingerprint.py"

WORKFLOW = """name: cmux-next
env:
  SHARED: "1"
jobs:
  fast-tier:
    name: cmux-next fast tier
    steps:
      - run: python3 -I scripts/cmux-next/fast-tier.py --kind swift --kind script

  # The cargo entries.
  fast-tier-cargo:
    name: cmux-next fast tier (cargo)
    steps:
      - run: python3 -I scripts/cmux-next/fast-tier.py --kind cargo

  other:
    steps:
      - run: echo other
"""

REGISTRY = """{"entries": [
  {"name": "core", "kind": "cargo", "path": "ws", "package": "core", "owner": "x"},
  {"name": "a", "kind": "swift", "package": "Packages/A", "filter": "ATests", "owner": "x"},
  {"name": "check", "kind": "script", "path": "scripts/check/run.py", "owner": "x"}
]}
"""

FILES = {
    ".github/workflows/cmux-next.yml": WORKFLOW,
    "scripts/cmux-next/fast-tier.json": REGISTRY,
    "scripts/cmux-next/fast-tier.py": "print('tier')\n",
    "scripts/cmux-next/quarantine.json": '{"entries": []}\n',
    "scripts/check/run.py": "print('check')\n",
    "ws/Cargo.toml": '[workspace]\nmembers = ["crates/core", "crates/other"]\n',
    "ws/Cargo.lock": "# lock\n",
    "ws/crates/core/Cargo.toml": '[package]\nname = "core"\n',
    "ws/crates/core/src/lib.rs": "pub fn core() {}\n",
    "ws/crates/other/Cargo.toml": '[package]\nname = "other"\n',
    "ws/crates/other/src/lib.rs": "pub fn other() {}\n",
    "docs/readme.md": "docs\n",
    "Packages/A/Package.swift": 'let package = Package(name: "A")\n',
    "Packages/A/Sources/A/A.swift": "public let a = 1\n",
    "Packages/C/Package.swift": 'let package = Package(name: "C")\n',
    "Packages/C/Sources/C/C.swift": "public let c = 1\n",
}

# What each job's workflow step passes (the real values come from the runner).
TOOLCHAIN = {
    "fast-tier": {
        "xcode": "Xcode 26.0 Build version 17A324",
        "macos": "26.0.1",
        "macos_build": "25A362",
        "arch": "arm64",
        "pool": "owned",
    },
    "fast-tier-cargo": {
        "runner": "Linux-X64",
        "rustc": "rustc 1.95.0 (abc 2026-09-01) binary: rustc commit-hash: abc host: x86_64-unknown-linux-gnu "
                 "release: 1.95.0 LLVM version: 21.1.0",
        "cargo": "cargo 1.95.0 (def 2026-08-20)",
        "zig": "0.15.2",
        "clang": "Ubuntu clang version 18.1.3 (1ubuntu1)",
    },
}
JOBS = tuple(TOOLCHAIN)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull,
                               "GIT_CONFIG_SYSTEM": os.devnull}).stdout


def run(job: str, root: Path, toolchain: dict[str, str | None]) -> tuple[str, str]:
    args = [sys.executable, "-I", str(SCRIPT), job, "--root", str(root)]
    for name, value in toolchain.items():
        if value is not None:
            args += ["--extra", f"{name}={value}"]
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    lines = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return lines.get("key", ""), result.stderr


class Repo:
    def __init__(self, root: Path):
        self.root = root
        git(root, "init", "-q")
        for name, text in FILES.items():
            self.write(name, text)
        self.commit()

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self) -> None:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "c")

    def key(self, job: str, **toolchain: str | None) -> tuple[str, str]:
        return run(job, self.root, {**TOOLCHAIN[job], **toolchain})


class JobInputFingerprint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def key(self, job: str, **toolchain: str | None) -> str:
        key, stderr = self.repo.key(job, **toolchain)
        self.assertTrue(key.startswith(f"job-pass-{job}-"), stderr[-2000:])
        return key

    def changes(self, job: str, name: str, text: str | None = None) -> bool:
        """Whether one edit to `name` (appending a line, or `text`) changes the job's key."""
        before = self.key(job)
        self.repo.write(name, text if text is not None else (self.repo.root / name).read_text() + "// changed\n")
        self.repo.commit()
        return before != self.key(job)

    def test_the_same_inputs_give_the_same_key(self):
        for job in JOBS:
            with self.subTest(job=job):
                first = self.key(job)
                self.assertEqual(first, self.key(job))
                # A new commit with the same tree (a rerun, or a re-push of the same tree) reuses.
                self.repo.commit()
                self.assertEqual(first, self.key(job))

    def test_any_file_in_the_tree_changes_the_key(self):
        # Files the job reads and files no entry of it reads: the key covers the whole tree.
        for job in JOBS:
            for name in ("Packages/A/Sources/A/A.swift", "ws/crates/core/src/lib.rs", "ws/crates/other/src/lib.rs",
                         "Packages/C/Sources/C/C.swift", "docs/readme.md"):
                with self.subTest(job=job, name=name):
                    self.assertTrue(self.changes(job, name), f"{name} changes the {job} key")

    def test_a_new_or_removed_file_changes_the_key(self):
        for job in JOBS:
            with self.subTest(job=job, change="added"):
                self.assertTrue(self.changes(job, f"notes/{job}.txt", "new\n"))
            with self.subTest(job=job, change="removed"):
                before = self.key(job)
                git(self.repo.root, "rm", "-q", f"notes/{job}.txt")
                self.repo.commit()
                self.assertNotEqual(before, self.key(job))

    def test_the_workflow_file_counts_outside_the_job_block(self):
        workflow = ".github/workflows/cmux-next.yml"
        for job in JOBS:
            with self.subTest(job=job):
                current = (self.repo.root / workflow).read_text()
                # Another job's step, and a top-level comment.
                self.assertTrue(self.changes(job, workflow, current.replace("echo other", f"echo other {job}")))
                current = (self.repo.root / workflow).read_text()
                self.assertTrue(self.changes(job, workflow, current.replace("\nenv:", f"\n# {job}\nenv:", 1)))

    def test_the_key_names_the_tree_and_the_workflow_file(self):
        for job in JOBS:
            with self.subTest(job=job):
                _, stderr = self.repo.key(job)
                self.assertIn(f"tree {git(self.repo.root, 'rev-parse', 'HEAD^{tree}').strip()}", stderr)
                blob = git(self.repo.root, "rev-parse", "HEAD:.github/workflows/cmux-next.yml").strip()
                self.assertIn(f"workflow {blob}", stderr)

    def test_the_xcode_version_and_build_count(self):
        base = self.key("fast-tier")
        self.assertNotEqual(base, self.key("fast-tier", xcode="Xcode 26.1 Build version 17B55"))
        self.assertNotEqual(base, self.key("fast-tier", xcode="Xcode 26.0 Build version 17A325"))
        self.assertNotEqual(base, self.key("fast-tier", macos="26.0.2"))
        self.assertNotEqual(base, self.key("fast-tier", macos_build="25A363"))
        self.assertNotEqual(base, self.key("fast-tier", arch="x86_64"))

    def test_the_runner_pool_counts(self):
        # Owned minis, Blacksmith and hosted Macs differ in settings such as Reduce Motion/Transparency.
        base = self.key("fast-tier")
        for pool in ("blacksmith", "hosted"):
            with self.subTest(pool=pool):
                self.assertNotEqual(base, self.key("fast-tier", pool=pool))

    def test_the_rust_and_zig_toolchain_count(self):
        base = self.key("fast-tier-cargo")
        rustc = TOOLCHAIN["fast-tier-cargo"]["rustc"]
        self.assertNotEqual(base, self.key("fast-tier-cargo", rustc=rustc.replace("1.95.0", "1.96.0")))
        self.assertNotEqual(base, self.key("fast-tier-cargo", rustc=rustc.replace("LLVM version: 21.1.0",
                                                                                   "LLVM version: 21.1.1")))
        self.assertNotEqual(base, self.key("fast-tier-cargo", cargo="cargo 1.95.1 (fed 2026-09-20)"))
        self.assertNotEqual(base, self.key("fast-tier-cargo", zig="0.16.0"))
        self.assertNotEqual(base, self.key("fast-tier-cargo", runner="Linux-ARM64"))

    def test_the_clang_that_bindgen_uses_counts(self):
        base = self.key("fast-tier-cargo")
        self.assertNotEqual(base, self.key("fast-tier-cargo", clang="Ubuntu clang version 18.1.8 (1ubuntu1)"))

    def test_the_runner_image_counts_when_the_runner_names_one(self):
        for job in JOBS:
            with self.subTest(job=job):
                base = self.key(job)
                self.assertNotEqual(base, self.key(job, image="ubuntu24-20261012.1"))
                self.assertNotEqual(self.key(job, image="ubuntu24-20261012.1"),
                                    self.key(job, image="ubuntu24-20261019.1"))

    def test_a_bad_rev_or_a_git_failure_gives_no_key(self):
        for job in JOBS:
            with self.subTest(job=job, case="bad rev"):
                args = [sys.executable, "-I", str(SCRIPT), job, "--root", str(self.repo.root), "--rev", "no-such-rev"]
                for name, value in TOOLCHAIN[job].items():
                    args += ["--extra", f"{name}={value}"]
                result = subprocess.run(args, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("key=", result.stdout)
                self.assertIn("::notice", result.stderr)
            with self.subTest(job=job, case="not a repository"):
                with tempfile.TemporaryDirectory() as empty:
                    key, stderr = run(job, Path(empty), TOOLCHAIN[job])
                    self.assertEqual(key, "")
                    self.assertIn("::notice", stderr)

    def test_a_submodule_bump_changes_the_key(self):
        def gitlink(sha: str) -> None:
            git(self.repo.root, "update-index", "--add", "--cacheinfo", f"160000,{sha},ghostty-next")
            git(self.repo.root, "commit", "-q", "-m", "bump")

        gitlink("1" * 40)
        for job in JOBS:
            with self.subTest(job=job):
                before = self.key(job)
                gitlink(("2" if job == "fast-tier" else "3") * 40)
                self.assertNotEqual(before, self.key(job))

    def test_a_missing_or_empty_toolchain_value_gives_no_key(self):
        for job in JOBS:
            for name in TOOLCHAIN[job]:
                for value in (None, "", "  "):
                    with self.subTest(job=job, name=name, value=value):
                        key, stderr = self.repo.key(job, **{name: value})
                        self.assertEqual(key, "")
                        self.assertIn("::notice", stderr)
                        self.assertIn(name, stderr)

    def test_the_real_tree_gives_both_jobs_a_key(self):
        for job in JOBS:
            with self.subTest(job=job):
                key, stderr = run(job, ROOT, TOOLCHAIN[job])
                self.assertTrue(key.startswith(f"job-pass-{job}-"), stderr[-2000:])
                self.assertTrue(re.search(r"^tree [0-9a-f]{40}", stderr, re.M), stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
