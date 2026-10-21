#!/usr/bin/env python3
"""scripts/ci/job_input_fingerprint.py: a fast-tier job's key changes exactly when what it reads changes.

A key that stays the same across a change the job reads would let CI_NEXT_JOB_REUSE reuse a pass that
never ran on that change; a key that changes on everything would never reuse one. Each case builds a
small repository and compares keys before and after one edit.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/job_input_fingerprint.py"
sys.path.insert(0, str(SCRIPT.parent))
try:
    import tomllib  # noqa: F401
    HAS_TOML = True
except ModuleNotFoundError:
    HAS_TOML = False

WORKFLOW = """name: cmux-next
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
    "scripts/check/helper.py": "X = 1\n",
    "ws/Cargo.toml": '[workspace]\nmembers = ["crates/core", "crates/dep", "crates/other"]\n\n'
                     '[workspace.dependencies]\ndep = { path = "crates/dep" }\nother = { path = "crates/other" }\n',
    "ws/Cargo.lock": "# lock\n",
    "ws/crates/core/Cargo.toml": '[package]\nname = "core"\n\n[dependencies]\ndep.workspace = true\n',
    "ws/crates/core/src/lib.rs": 'pub const A: &str = include_str!("../../../../assets/a.txt");\n',
    "ws/crates/core/src/mux/tests/matrix.rs": 'fn cases() -> String {\n'
                                          '    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");\n'
                                          '    std::fs::read_to_string(root.join("fixtures/cases.json")).unwrap()\n}\n',
    "ws/crates/dep/Cargo.toml": '[package]\nname = "dep"\n',
    "ws/crates/dep/src/lib.rs": "pub fn dep() {}\n",
    "ws/crates/other/Cargo.toml": '[package]\nname = "other"\n',
    "ws/crates/other/src/lib.rs": "pub fn other() {}\n",
    "assets/a.txt": "a\n",
    "fixtures/cases.json": "[]\n",
    "fixtures/unrelated.json": "[]\n",
    "docs/readme.md": "docs\n",
    "Packages/A/Package.swift": 'let package = Package(name: "A", dependencies: [.package(path: "../B")])\n',
    "Packages/A/Sources/A/A.swift": "public let a = 1\n",
    "Packages/A/Tests/ATests/ATests.swift": "import A\n",
    "Packages/B/Package.swift": 'let package = Package(name: "B")\n',
    "Packages/B/Sources/B/B.swift": "public let b = 1\n",
    "Packages/C/Package.swift": 'let package = Package(name: "C")\n',
    "Packages/C/Sources/C/C.swift": "public let c = 1\n",
}


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull})


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

    def key(self, job: str, *extra: str) -> tuple[str, str]:
        args = [sys.executable, "-I", str(SCRIPT), job, "--root", str(self.root)]
        for value in extra:
            args += ["--extra", value]
        result = subprocess.run(args, capture_output=True, text=True, check=True, timeout=60)
        lines = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return lines.get("key", ""), result.stderr


class JobInputFingerprint(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def changes(self, job: str, name: str, text: str | None = None) -> bool:
        """Whether one edit to `name` (appending a line, or `text`) changes the job's key."""
        before, _ = self.repo.key(job)
        self.assertTrue(before, f"{job} has a key")
        self.repo.write(name, text if text is not None else (self.repo.root / name).read_text() + "// changed\n")
        self.repo.commit()
        after, _ = self.repo.key(job)
        self.assertTrue(after, f"{job} still has a key after {name}")
        return before != after

    @unittest.skipUnless(HAS_TOML, "the cargo closure needs tomllib (Python 3.11)")
    def test_cargo_key_follows_the_crates_and_files_its_entries_read(self):
        for name in ("ws/crates/core/src/lib.rs", "ws/crates/dep/src/lib.rs", "ws/Cargo.lock",
                     "assets/a.txt", "fixtures/cases.json", "scripts/cmux-next/fast-tier.py"):
            with self.subTest(name=name):
                self.assertTrue(self.changes("fast-tier-cargo", name), f"{name} is a cargo input")

    @unittest.skipUnless(HAS_TOML, "the cargo closure needs tomllib (Python 3.11)")
    def test_cargo_key_ignores_what_its_entries_never_read(self):
        for name in ("ws/crates/other/src/lib.rs", "docs/readme.md", "fixtures/unrelated.json",
                     "Packages/A/Sources/A/A.swift"):
            with self.subTest(name=name):
                self.assertFalse(self.changes("fast-tier-cargo", name), f"{name} is not a cargo input")

    def test_swift_key_follows_the_package_closure_and_the_scripts(self):
        for name in ("Packages/A/Sources/A/A.swift", "Packages/B/Sources/B/B.swift", "scripts/check/helper.py"):
            with self.subTest(name=name):
                self.assertTrue(self.changes("fast-tier", name), f"{name} is a fast-tier input")

    def test_swift_key_ignores_other_packages_and_crates(self):
        for name in ("Packages/C/Sources/C/C.swift", "ws/crates/core/src/lib.rs", "docs/readme.md"):
            with self.subTest(name=name):
                self.assertFalse(self.changes("fast-tier", name), f"{name} is not a fast-tier input")

    def test_the_job_definition_counts_but_another_job_does_not(self):
        workflow = ".github/workflows/cmux-next.yml"
        self.assertTrue(self.changes("fast-tier", workflow, WORKFLOW.replace("--kind script", "--kind script ")))
        current = (self.repo.root / workflow).read_text()
        self.assertFalse(self.changes("fast-tier", workflow, current.replace("echo other", "echo else")))

    def test_the_runner_extras_count(self):
        self.assertNotEqual(self.repo.key("fast-tier", "xcode=26.0")[0], self.repo.key("fast-tier", "xcode=26.1")[0])

    @unittest.skipUnless(HAS_TOML, "the cargo closure needs tomllib (Python 3.11)")
    def test_a_crate_that_walks_up_at_run_time_gets_no_key(self):
        self.repo.write("ws/crates/core/src/walk.rs",
                        'fn f() { Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap(); }\n')
        self.repo.commit()
        key, notice = self.repo.key("fast-tier-cargo")
        self.assertEqual(key, "")
        self.assertIn("::notice", notice)
        self.assertIn("ws/crates/core/src/walk.rs", notice)

    def test_a_tested_package_that_walks_up_at_run_time_gets_no_key(self):
        self.repo.write("Packages/A/Tests/ATests/Fixture.swift",
                        "let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()\n")
        self.repo.commit()
        self.assertEqual(self.repo.key("fast-tier")[0], "")

    def test_the_real_tree_gives_both_jobs_a_key_or_says_why_not(self):
        for job in ("fast-tier", "fast-tier-cargo"):
            with self.subTest(job=job):
                result = subprocess.run([sys.executable, "-I", str(SCRIPT), job, "--root", str(ROOT)],
                                        capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stderr[-2000:])
                self.assertTrue("key=job-pass-" in result.stdout or "::notice" in result.stderr, result.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
