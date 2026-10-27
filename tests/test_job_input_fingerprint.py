#!/usr/bin/env python3
"""scripts/ci/job_input_fingerprint.py: a changed input never reuses a pass.

CI_NEXT_JOB_REUSE reuses a pass recorded under the same key. The key must change when anything the job could
read changes. For the fast tiers that is any file in the commit's tree, the whole cmux-next.yml and the
toolchain (Xcode for fast-tier; Rust and Zig for fast-tier-cargo). For the three Mac jobs (swift test, the
Release compile, generated files) it is an explicit input list derived from the router and the CI target
graph, so a base move that touches none of a job's inputs keeps its key. The same inputs must give the same
key, so a rerun or a re-push of the same tree reuses. Each case builds a small repository and compares keys
before and after one change.
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


# The three Mac jobs key an explicit input list, so a small repository holds files on both sides of it.
MAC_FILES = {
    "Packages/macOS/CmuxNext/Package.swift": 'let package = Package(name: "CmuxNext")\n',
    "Packages/macOS/CmuxNext/Package.resolved": '{"pins": []}\n',
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift": "let app = 1\n",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift": "let setting = 1\n",
    "Packages/macOS/CmuxNext/ci-target-graph.json": """{"packages": {}, "targets": {
  "CmuxNextAppTests": {"kind": "test", "path": "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests",
                       "targets": [], "packages": [], "reads": ["docs/read-by-tests.json", "fixtures/read-dir/"]}
}}
""",
    "Packages/Shared/CmuxTheme/Sources/Theme.swift": "let theme = 1\n",
    "vendor/stack-auth-swift-sdk-prerelease/Package.swift": "// sdk\n",
    ".xcode-version": "26.6\n",
    "scripts/ci/xcode-pins.txt": "26 26.6\n",
    "scripts/select-ci-xcode.sh": "echo select\n",
    "scripts/cmux-next/check-release-compile.sh": "echo compile\n",
    "scripts/cmux-next/cef-manifest.json": "{}\n",
    "scripts/ci/defaults_guard.py": "print('guard')\n",
    "scripts/ci/unrelated_tool.py": "print('unrelated')\n",
    "schemas/settings/settings-schema.json": "{}\n",
    "schemas/keybindings/vectors.json": "{}\n",
    "plans/cmux-next/action-surfaces.json": "{}\n",
    "plans/other/notes.md": "notes\n",
    "docs/read-by-tests.json": "{}\n",
    "docs/mdm/index.md": "mdm\n",
    "fixtures/read-dir/case.json": "{}\n",
    "webviews/src/app.ts": "export const app = 1\n",
    "web/app/page.tsx": "export default 1\n",
    "cmux-tui/Cargo.toml": "[workspace]\n",
    "cmux-tui/Cargo.lock": "# lock\n",
    "cmux-tui/crates/cmux-layout-reducer/src/lib.rs": "pub fn reduce() {}\n",
    "cmux-tui/crates/cmux-daemon/src/lib.rs": "pub fn daemon() {}\n",
    "iosapp/Notes.txt": "ios\n",
}

MAC_TOOLCHAIN = {
    "xcode": "Xcode 26.6 Build version 17F55",
    "macos": "26.0.1",
    "macos_build": "25A362",
    "arch": "arm64",
    "pool": "owned",
}
# The env flags each Mac job passes; '' is a value (an empty swift filter runs every selected target).
MAC_FLAGS = {
    "swift-test": {"swift_targets": "CmuxNextAppTests", "swift_filter": "", "mini": "true",
                   "xcode_app": "/Applications/Xcode_26.6.app", "web_bundles": "0123abcd", "layout_reducer": "false"},
    "generated-files": {"mini": "true", "xcode_app": "/Applications/Xcode_26.6.app", "web_bundles": "0123abcd"},
    "release-compile": {"mini": "true", "xcode_app": "/Applications/Xcode_26.6.app"},
}
MAC_JOBS = tuple(MAC_FLAGS)

# Inputs every Mac job keys (a change to any changes the key), and what each job adds.
COMMON_INPUTS = (
    "Packages/macOS/CmuxNext/Package.resolved", "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift",
    "Packages/Shared/CmuxTheme/Sources/Theme.swift", "vendor/stack-auth-swift-sdk-prerelease/Package.swift",
    ".xcode-version", "scripts/ci/xcode-pins.txt", "scripts/select-ci-xcode.sh",
    "scripts/cmux-next/check-release-compile.sh", "scripts/cmux-next/cef-manifest.json",
    ".github/workflows/cmux-next.yml", "schemas/keybindings/vectors.json", "plans/cmux-next/action-surfaces.json",
    "docs/read-by-tests.json", "fixtures/read-dir/case.json", "Packages/macOS/CmuxNext/ci-target-graph.json",
)
JOB_INPUTS = {
    "swift-test": ("webviews/src/app.ts", "cmux-tui/Cargo.lock", "cmux-tui/crates/cmux-layout-reducer/src/lib.rs"),
    "generated-files": ("webviews/src/app.ts", "scripts/ci/defaults_guard.py", "docs/mdm/index.md"),
    "release-compile": ("LICENSE", "scripts/verify-app-bundle-licenses.sh",
                        "cmux-tui/build-support/notices", "cmux-tui/rust-toolchain.toml",
                        "cmux-tui/crates/ghostty-vt-sys/build.rs"),
}
# Files no Mac job reads: a base move that touches only these keeps every key.
OUTSIDE = ("docs/readme.md", "web/app/page.tsx", "cmux-tui/crates/cmux-daemon/src/lib.rs", "plans/other/notes.md",
           "scripts/ci/unrelated_tool.py", "iosapp/Notes.txt", "ws/crates/other/src/lib.rs")


class MacJobInputs(unittest.TestCase):
    """swift test, the Release compile and generated files key their own inputs, not the whole tree."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        for name, text in MAC_FILES.items():
            self.repo.write(name, text)
        self.repo.commit()
        # generated-files keys its base (HEAD^1) too, as a merge commit has one.
        self.repo.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def run_job(self, job: str, rev: str = "HEAD", base_rev: str | None = "HEAD^1", extra: tuple[str, ...] = (),
                **values: str | None) -> tuple[str, str]:
        args = [sys.executable, "-I", str(SCRIPT), job, "--root", str(self.repo.root), "--rev", rev, *extra]
        if base_rev is not None:
            args += ["--base-rev", base_rev]
        for name, value in {**MAC_TOOLCHAIN, **MAC_FLAGS[job], **values}.items():
            if value is not None:
                args += ["--extra", f"{name}={value}"]
        result = subprocess.run(args, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        lines = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return lines.get("key", ""), result.stderr

    def key(self, job: str, **values: str | None) -> str:
        key, stderr = self.run_job(job, **values)
        self.assertTrue(key.startswith(f"job-pass-{job}-"), stderr[-2000:])
        return key

    def edit(self, name: str) -> None:
        path = self.repo.root / name
        # JSON stays JSON: the graph must still parse after the edit.
        self.repo.write(name, (path.read_text() if path.exists() else "") + ("\n" if name.endswith(".json") else "// changed\n"))
        self.repo.commit()

    def test_a_base_move_outside_the_inputs_keeps_the_key(self):
        for job in MAC_JOBS:
            for name in OUTSIDE + ("notes/new-file.txt",):
                with self.subTest(job=job, name=name):
                    before = self.key(job)
                    self.edit(name)
                    self.assertEqual(before, self.key(job), f"{name} is not a {job} input")

    def test_a_change_to_any_listed_input_changes_the_key(self):
        for job in MAC_JOBS:
            for name in COMMON_INPUTS + JOB_INPUTS[job]:
                with self.subTest(job=job, name=name):
                    before = self.key(job)
                    self.edit(name)
                    self.assertNotEqual(before, self.key(job), f"{name} is a {job} input")

    def test_an_added_file_under_an_input_changes_the_key(self):
        for job in MAC_JOBS:
            with self.subTest(job=job):
                before = self.key(job)
                self.edit(f"Packages/macOS/CmuxNext/Sources/CmuxNextApp/New{job.replace('-', '')}.swift")
                self.assertNotEqual(before, self.key(job))

    def test_a_submodule_gitlink_bump_changes_the_key(self):
        for job in MAC_JOBS:
            for index, submodule in enumerate(("ghostty", "ghostty-next")):
                with self.subTest(job=job, submodule=submodule):
                    before = self.key(job)
                    git(self.repo.root, "update-index", "--add", "--cacheinfo",
                        f"160000,{(str(index + 1) + format(MAC_JOBS.index(job) + 10, 'x')) * 20},{submodule}")
                    git(self.repo.root, "commit", "-q", "-m", "bump")
                    self.assertNotEqual(before, self.key(job))

    def test_the_toolchain_and_every_env_flag_count(self):
        changed = {"xcode": "Xcode 26.6 Build version 17F56", "macos": "26.0.2", "macos_build": "25A363",
                   "arch": "x86_64", "pool": "blacksmith", "image": "macos26-20261012.1", "mini": "false",
                   "xcode_app": "/Applications/Xcode_26.7.app", "web_bundles": "4567cdef",
                   "swift_targets": "all", "swift_filter": "^(CmuxNextAppTests)\\\\.", "layout_reducer": "true"}
        for job in MAC_JOBS:
            base = self.key(job)
            for name, value in changed.items():
                if name not in {**MAC_TOOLCHAIN, **MAC_FLAGS[job]} and name != "image":
                    continue
                with self.subTest(job=job, name=name):
                    self.assertNotEqual(base, self.key(job, **{name: value}))

    def test_a_missing_value_gives_no_key(self):
        for job in MAC_JOBS:
            for name in {**MAC_TOOLCHAIN, **MAC_FLAGS[job]}:
                with self.subTest(job=job, name=name):
                    key, stderr = self.run_job(job, **{name: None})
                    self.assertEqual(key, "", f"no {name} value, no key")
                    self.assertIn(name, stderr)
            # A value the job does not declare is refused too, so a typo never keys silently.
            with self.subTest(job=job, name="unknown"):
                self.assertEqual(self.run_job(job, unknown_flag="1")[0], "")

    def test_swift_test_keys_whether_the_layout_reducer_tests_ran(self):
        # cmux-next.yml skips the reducer tests on feat-cmux-next PRs (the Linux fast tier
        # runs them), so a PR pass never stands in for a dispatch or main push that runs them.
        ran, skipped = self.key("swift-test", layout_reducer="true"), self.key("swift-test", layout_reducer="false")
        self.assertTrue(ran)
        self.assertTrue(skipped)
        self.assertNotEqual(ran, skipped)

    def test_an_empty_flag_is_a_value_but_an_empty_toolchain_or_bundle_key_is_not(self):
        self.key("swift-test", swift_filter="")
        for job in MAC_JOBS:
            for name in ("xcode", "pool") + (("web_bundles",) if "web_bundles" in MAC_FLAGS[job] else ()):
                with self.subTest(job=job, name=name):
                    self.assertEqual(self.run_job(job, **{name: " "})[0], "")

    def test_generated_files_keys_the_settings_sources_of_its_base(self):
        # check-stamp --base HEAD^1: the same head inputs over a base with other settings sources may judge
        # differently, so the base's settings inputs count; a base change elsewhere does not.
        self.edit("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift")
        settings_base = git(self.repo.root, "rev-parse", "HEAD^1").strip()
        self.edit("docs/readme.md")
        head = git(self.repo.root, "rev-parse", "HEAD").strip()
        docs_base = git(self.repo.root, "rev-parse", "HEAD^1").strip()
        same = self.run_job("generated-files", rev=head, base_rev=docs_base)[0]
        other = self.run_job("generated-files", rev=head, base_rev=settings_base)[0]
        self.assertTrue(same and other)
        self.assertNotEqual(same, other)
        self.assertEqual(self.run_job("generated-files", rev=head, base_rev=None)[0], "", "no base, no key")
        # The other two jobs read no base.
        for job in ("swift-test", "release-compile"):
            with self.subTest(job=job):
                self.assertEqual(self.run_job(job, rev=head, base_rev=docs_base)[0],
                                 self.run_job(job, rev=head, base_rev=settings_base)[0])

    def test_the_input_list_derives_from_the_router_and_the_target_graph(self):
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import cmux_next_route as route

        def listed(job: str) -> set[str]:
            key, stderr = self.run_job(job, extra=("--list-inputs",))
            return {line.split(" ", 1)[1] for line in stderr.splitlines() if line.startswith("input ")}

        def norm(path: str) -> str:
            return path.rstrip("*").rstrip("/")

        for job in MAC_JOBS:
            with self.subTest(job=job):
                inputs = listed(job)
                for path in route.FULL_INPUTS + route.VENDORED_PINS:
                    self.assertTrue(any(norm(path) == i or norm(path).startswith(i + "/") for i in inputs), path)
                for path in ("docs/read-by-tests.json", "fixtures/read-dir", "ghostty", "ghostty-next", "Packages"):
                    self.assertIn(path, inputs)
        swift = listed("swift-test")
        for path in route.SWIFT_JOB_INPUTS + route.BUNDLE_INPUTS:
            self.assertTrue(any(norm(path) == i or norm(path).startswith(i + "/") for i in swift), path)
        generated = listed("generated-files")
        for path in route.GENERATED_INPUTS:
            self.assertTrue(any(norm(path) == i or norm(path).startswith(i + "/") for i in generated), path)

    def test_the_real_tree_gives_every_mac_job_a_key(self):
        for job in MAC_JOBS:
            with self.subTest(job=job):
                args = [sys.executable, "-I", str(SCRIPT), job, "--root", str(ROOT), "--base-rev", "HEAD"]
                for name, value in {**MAC_TOOLCHAIN, **MAC_FLAGS[job]}.items():
                    args += ["--extra", f"{name}={value}"]
                result = subprocess.run(args, capture_output=True, text=True, timeout=120)
                self.assertIn(f"key=job-pass-{job}-", result.stdout, result.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
