#!/usr/bin/env python3
"""Tests of coverage.py (p15-oracle-190). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/coverage_test.py

The pipeline test compiles a small Rust program with the pinned toolchain's `-C instrument-coverage` and uses its
llvm-profdata and llvm-cov (rustup component llvm-tools); it is skipped when they are missing. linux_run.sh is
replaced by a fake `run` that executes that program as each arm's suite, so nothing is queued.
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Dict, List, Optional
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import coverage  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.com",
                           "-c", "commit.gpgsign=false", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True).stdout.strip()


def commit(repo: Path, files: Dict[str, Optional[str]], message: str) -> str:
    for name, text in files.items():
        path = repo / name
        if text is None:
            git(repo, "rm", "-q", name)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        git(repo, "add", name)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def new_repo(test: unittest.TestCase) -> Path:
    repo = Path(tempfile.mkdtemp(prefix="cov-test-"))
    test.addCleanup(shutil.rmtree, repo, True)
    git(repo, "init", "-q", "-b", "main")
    return repo


class LcovTests(unittest.TestCase):
    def test_paths_are_made_relative_and_outside_files_dropped(self):
        text = "\n".join([
            "SF:/job/wt/cmux-tui/crates/a/src/lib.rs", "DA:1,3", "DA:2,0", "end_of_record",
            "SF:/home/u/.cargo/registry/src/x/lib.rs", "DA:1,1", "end_of_record",
            "SF:/job/wt/cmux-tui/crates/a/src/lib.rs", "DA:2,4", "DA:5,0,abc", "end_of_record",
        ])
        trace = coverage.parse_lcov(text, ["/job/wt/"])
        self.assertEqual(trace, {"cmux-tui/crates/a/src/lib.rs": {1: 3, 2: 4, 5: 0}})

    def test_merge_sums_counts(self):
        merged = coverage.merge_traces([{"a.rs": {1: 1, 2: 0}}, {"a.rs": {2: 2}, "b.rs": {1: 0}}])
        self.assertEqual(merged, {"a.rs": {1: 1, 2: 2}, "b.rs": {1: 0}})


class DiffTests(unittest.TestCase):
    def test_added_modified_renamed_and_deleted_files(self):
        repo = new_repo(self)
        body = "".join(f"line {n}\n" for n in range(1, 31))
        base = commit(repo, {"a.rs": "one\ntwo\nthree\n", "old.rs": body, "gone.rs": "x\n"}, "base")
        commit(repo, {"a.rs": "one\nTWO\nthree\nfour\nfive\n", "gone.rs": None,
                             "new dir/é.swift": "let x = 1\nlet y = 2\n"}, "change")
        git(repo, "mv", "old.rs", "moved.rs")
        (repo / "moved.rs").write_text(body.replace("line 20\n", "line twenty\n"))
        git(repo, "add", "moved.rs")
        git(repo, "commit", "-q", "-m", "rename")
        head = git(repo, "rev-parse", "HEAD")
        changed = coverage.changed_lines(repo, base, head)
        self.assertEqual(changed, {"a.rs": [(2, 2), (4, 5)], "moved.rs": [(20, 20)], "new dir/é.swift": [(1, 2)]})

    def test_a_hunk_of_zero_added_lines_is_no_change(self):
        text = "+++ b/x.rs\n@@ -3,2 +2,0 @@\n@@ -9 +8 @@\n"
        self.assertEqual(coverage.parse_diff(text), {"x.rs": [(8, 8)]})


class HunkTests(unittest.TestCase):
    def test_runs_bridge_lines_without_code_and_split_at_a_line_that_ran(self):
        # 10-11 uncovered, 12 no code, 13 uncovered, 14 ran, 15 uncovered, 16-17 no code.
        lines = {10: 0, 11: 0, 13: 0, 14: 2, 15: 0, 30: 0}
        self.assertEqual(coverage.uncovered_hunks([(10, 17)], lines), [(10, 13), (15, 15)])
        self.assertEqual(coverage.uncovered_hunks([(16, 20)], lines), [])

    def test_runs_never_cross_diff_hunks(self):
        lines = {1: 0, 2: 0, 3: 0}
        self.assertEqual(coverage.uncovered_hunks([(1, 1), (3, 3)], lines), [(1, 1), (3, 3)])

    def test_labels(self):
        self.assertEqual(coverage.hunk_label("a.rs", (4, 4)), "a.rs:4")
        self.assertEqual(coverage.hunk_label("a.rs", (4, 9)), "a.rs:4-9")


class ReportTests(unittest.TestCase):
    def test_absolute_incremental_unmeasured_and_arms(self):
        changed = {"core.rs": [(2, 4)], "View.swift": [(1, 1)], "tool.py": [(1, 9)], "lost.rs": [(1, 1)]}
        tiers = {"daemon": {"core.rs": {1: 5, 2: 1, 3: 0, 4: 0, 9: 0}},
                 "swift": {"View.swift": {1: 3, 7: 0}}}
        arms = {"old": {"core.rs": {2: 1, 3: 0, 4: 0}}, "new": {"core.rs": {2: 0, 3: 0, 4: 0}}}
        report = coverage.build_report(changed, tiers, arms)
        files = {entry["path"]: entry for entry in report["files"]}
        self.assertEqual(files["core.rs"]["incremental"], {"covered": 1, "executable": 3})
        self.assertEqual(files["core.rs"]["absolute"], {"covered": 2, "executable": 5})
        self.assertEqual(files["core.rs"]["arms"], {"old": {"covered": 1, "executable": 3},
                                                    "new": {"covered": 0, "executable": 3}})
        self.assertEqual(files["View.swift"]["tier"], "swift")
        self.assertEqual(report["incremental"], {"covered": 2, "executable": 4})
        self.assertEqual(report["absolute"], {"covered": 3, "executable": 7})
        self.assertEqual(report["uncoveredHunks"], ["core.rs:3-4"])
        self.assertEqual(report["unmeasured"], ["lost.rs"])
        self.assertEqual(report["notCode"], 1)


class ReportFromTracefilesTests(unittest.TestCase):
    def test_lcov_mode_writes_the_report_outside_the_checkout(self):
        repo = new_repo(self)
        base = commit(repo, {"src/a.rs": "fn a() {}\n"}, "base")
        head = commit(repo, {"src/a.rs": "fn a() {}\nfn b() {\n    1;\n}\n"}, "head")
        work = Path(tempfile.mkdtemp(prefix="cov-out-"))
        self.addCleanup(shutil.rmtree, work, True)
        lcov = work / "daemon.lcov"
        lcov.write_text("SF:/src-root/src/a.rs\nDA:1,1\nDA:2,0\nDA:3,0\nDA:4,0\nend_of_record\n")
        out = work / "out"
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            code = coverage.main(["--repo", str(repo), "--base", base, "--head", head, "--lcov", f"daemon={lcov}",
                                  "--strip", "/src-root", "--out", str(out)])
        self.assertEqual(code, coverage.EXIT_OK)
        self.assertIn("uncovered src/a.rs:2-4", stdout.getvalue())
        doc = json.loads((out / "coverage.json").read_text())
        self.assertEqual(doc["schema"], coverage.SCHEMA)
        self.assertEqual(doc["report"]["incremental"], {"covered": 0, "executable": 3})
        with redirect_stderr(io.StringIO()) as err:
            code = coverage.main(["--repo", str(repo), "--base", base, "--lcov", f"daemon={lcov}",
                                  "--out", str(repo / "out")])
        self.assertEqual(code, coverage.EXIT_USAGE)
        self.assertIn("outside the checkout", err.getvalue())


def instrumented_toolchain() -> Optional[Dict[str, str]]:
    """The pinned toolchain (cmux-tui/rust-toolchain.toml) when it has llvm-tools: RUSTUP_TOOLCHAIN and tools."""
    pin = re.search(r'channel\s*=\s*"([^"]+)"', (coverage.REPO / "cmux-tui" / "rust-toolchain.toml").read_text())
    if not pin or not shutil.which("rustc"):
        return None
    env = {**os.environ, "RUSTUP_TOOLCHAIN": pin.group(1)}
    probe = subprocess.run(["rustc", "-vV"], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    host = re.search(r"^host: (\S+)", probe.stdout, re.M)
    sysroot = subprocess.run(["rustc", "--print", "sysroot"], env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True).stdout.strip()
    if probe.returncode or not host or not sysroot:
        return None
    tools = Path(sysroot) / "lib" / "rustlib" / host.group(1) / "bin"
    if not (tools / "llvm-profdata").is_file() or not (tools / "llvm-cov").is_file():
        return None
    return {"toolchain": pin.group(1), "llvmProfdata": str(tools / "llvm-profdata"), "llvmCov": str(tools / "llvm-cov")}


DEMO_BASE = """fn main() {
    println!("demo");
}
"""

DEMO_HEAD = """fn classify(n: i32) -> &'static str {
    if n > 0 {
        "positive"
    } else {
        "other"
    }
}

#[allow(dead_code)]
fn unused(n: i32) -> i32 {
    n * 7
}

fn main() {
    let n: i32 = std::env::args().nth(1).unwrap().parse().unwrap();
    println!("{}", classify(n));
}
"""


@unittest.skipUnless(sys.platform.startswith("linux"), "collection runs on the Linux VM")
class SwitchPipelineTests(unittest.TestCase):
    """--switch on a daemon switch: both arms run, each arm's counters and the union are reported."""

    @classmethod
    def setUpClass(cls):
        cls.tools = instrumented_toolchain()
        if cls.tools is None:
            raise unittest.SkipTest("the pinned toolchain has no llvm-tools (rustup component add llvm-tools)")

    def setUp(self):
        self.repo = repo = new_repo(self)
        self.base = commit(repo, {"cmux-tui/demo.rs": DEMO_BASE}, "base")
        switch = {"name": "demo", "owner": "t", "plan": "x.md", "read": "launch", "daemon_key": "demo",
                  "default": "old", "planned": "new", "created": "2026-10-20", "expires": "2026-10-30",
                  "suites": ["daemon-ops"], "expected_differences": []}
        self.registered = commit(repo, {f"{coverage.SWITCH_DIR}/demo.json": json.dumps(switch)}, "switch")
        self.head = commit(repo, {"cmux-tui/demo.rs": DEMO_HEAD}, "new arm")
        self.work = Path(tempfile.mkdtemp(prefix="cov-run-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        env = {**os.environ, "RUSTUP_TOOLCHAIN": self.tools["toolchain"]}
        self.binary = self.work / "build" / "cmux-tui"
        self.binary.parent.mkdir()
        subprocess.run(["rustc", "-C", "instrument-coverage", "-o", str(self.binary), "cmux-tui/demo.rs"],
                       cwd=repo, env=env, check=True, stdout=subprocess.DEVNULL)
        (self.binary.parent / "build.json").write_text(json.dumps({"coverage": {
            "llvmProfdata": self.tools["llvmProfdata"], "llvmCov": self.tools["llvmCov"],
            "sourceRoot": os.path.realpath(repo), "target": "host"}}))
        self.calls: List[List[str]] = []

    def fake_run(self, argv, **kwargs):
        """linux_run.sh build and run as the queue would answer them; everything else really runs."""
        args = list(argv[3:]) if list(argv[:3]) == ["nice", "-n", "10"] else list(argv)
        if len(args) > 2 and args[0] == "bash" and args[1].endswith("linux_run.sh"):
            self.calls.append(args[2:])
            if args[2] == "build":
                return subprocess.CompletedProcess(argv, 0, stdout=f"{self.binary}\n")
            arm = args[args.index("--arm") + 1]
            run_dir = self.work / f"run-{arm.replace('=', '-')}"
            run_dir.mkdir()
            env = {"LLVM_PROFILE_FILE": str(run_dir / "raw-%p.profraw"), "PATH": os.environ["PATH"]}
            subprocess.run([str(self.binary), "1" if arm.endswith("=old") else "-1"], env=env, check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run([self.tools["llvmProfdata"], "merge", "-sparse", "-o", str(run_dir / "coverage.profdata"),
                            *map(str, run_dir.glob("*.profraw"))], check=True)
            (run_dir / "receipt.json").write_text("{}")
            return subprocess.CompletedProcess(argv, 0, stdout=f"{run_dir}\n")
        return subprocess.run(argv, **kwargs)

    def test_each_arm_covers_its_branch_and_the_union_leaves_the_unused_function(self):
        out = self.work / "out"
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            code = coverage.main(["--repo", str(self.repo), "--switch", "demo", "--head", self.head, "--tiers",
                                  "daemon", "--out", str(out)], run=self.fake_run)
        self.assertEqual(code, coverage.EXIT_OK, stdout.getvalue())
        self.assertEqual(sorted(call[0] for call in self.calls), ["build", "run", "run"])
        self.assertEqual(sorted(call[call.index("--arm") + 1] for call in self.calls if call[0] == "run"),
                         ["demo=new", "demo=old"])
        self.assertTrue(all("--coverage" in call and "daemon-ops" in call for call in self.calls if call[0] == "run"))
        doc = json.loads((out / "coverage.json").read_text())
        self.assertEqual(doc["mergeBase"], self.base, "a switch's change starts before its registry file")
        self.assertEqual(doc["switch"]["registered"], self.registered)
        [demo] = doc["report"]["files"]
        self.assertEqual(demo["path"], "cmux-tui/demo.rs")
        lines = DEMO_HEAD.splitlines()
        positive = lines.index('        "positive"') + 1
        other = lines.index('        "other"') + 1
        unused = lines.index("fn unused(n: i32) -> i32 {") + 1
        self.assertEqual(demo["uncovered"], [[unused, unused + 2]])
        self.assertEqual(doc["report"]["uncoveredHunks"], [f"cmux-tui/demo.rs:{unused}-{unused + 2}"])
        old = coverage.parse_lcov((out / "daemon-old.lcov").read_text(), [os.path.realpath(self.repo)])
        new = coverage.parse_lcov((out / "daemon-new.lcov").read_text(), [os.path.realpath(self.repo)])
        self.assertGreater(old["cmux-tui/demo.rs"][positive], 0)
        self.assertEqual(old["cmux-tui/demo.rs"][other], 0)
        self.assertEqual(new["cmux-tui/demo.rs"][positive], 0)
        self.assertGreater(new["cmux-tui/demo.rs"][other], 0)
        self.assertLess(demo["arms"]["old"]["covered"], demo["incremental"]["covered"])
        self.assertLess(demo["arms"]["new"]["covered"], demo["incremental"]["covered"])
        self.assertIn(f"uncovered cmux-tui/demo.rs:{unused}-{unused + 2}", stdout.getvalue())

    def test_dry_run_prints_both_arms_and_queues_nothing(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = coverage.main(["--repo", str(self.repo), "--switch", "demo", "--head", self.head, "--tiers",
                                  "daemon", "--dry-run"], run=self.fake_run)
        self.assertEqual(code, coverage.EXIT_OK)
        self.assertEqual(self.calls, [])
        self.assertIn("--arm demo=old", stdout.getvalue())
        self.assertIn("--arm demo=new", stdout.getvalue())
        self.assertIn(f"change {self.base[:12]}..{self.head[:12]}", stdout.getvalue())

    def test_an_unknown_switch_is_a_usage_error(self):
        with redirect_stderr(io.StringIO()) as err:
            code = coverage.main(["--repo", str(self.repo), "--switch", "nope", "--dry-run"], run=self.fake_run)
        self.assertEqual(code, coverage.EXIT_USAGE)
        self.assertIn("no plans/cmux-next/refactor-switches/nope.json", err.getvalue())


SWIFT_BASE = "let a = 1\n"
SWIFT_HEAD = "let a = 1\nfunc f() -> Int {\n    return 2\n}\nfunc g() -> Int {\n    return 3\n}\n"


@unittest.skipUnless(sys.platform.startswith("linux"), "collection runs on the Linux VM")
class SwiftPipelineTests(unittest.TestCase):
    """The Swift tier through a fake `run`: toolchain lookup, worktree, swift-tier.sh steps, export and strip roots."""

    def setUp(self):
        self.repo = repo = new_repo(self)
        ffi = "#!/usr/bin/env bash\n"
        self.base = commit(repo, {"Sources/A/A.swift": SWIFT_BASE, "scripts/cmux-next/build-app-ffi.sh": ffi}, "base")
        self.head = commit(repo, {"Sources/A/A.swift": SWIFT_HEAD}, "head")
        self.work = Path(tempfile.mkdtemp(prefix="cov-swift-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        # The scratch is reached through a symlink, as swift-tier.sh compiles in its realpath.
        (self.work / "real").mkdir()
        (self.work / "link").symlink_to(self.work / "real")
        cov_root = self.work / "link" / "oracle-cov"
        for name, value in (("COV_ROOT", cov_root), ("SWIFT_SCRATCH", cov_root / "swift")):
            patcher = mock.patch.object(coverage, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.toolchain = self.work / "toolchain" / "usr"
        (self.toolchain / "bin").mkdir(parents=True)
        for tool in ("llvm-profdata", "llvm-cov", "swift"):
            path = self.toolchain / "bin" / tool
            path.write_text("#!/bin/sh\nexit 99\n")
            path.chmod(0o755)
        env = mock.patch.dict(os.environ, {"SWIFT": str(self.toolchain / "bin" / "swift")})
        env.start()
        self.addCleanup(env.stop)
        self.bin_dir = self.work / "bin"
        self.calls: List[Dict[str, object]] = []
        self.build_exit = 0
        self.test_times_out = False
        self.stale_at_test: List[str] = []

    def lcov(self) -> str:
        src = os.path.realpath(coverage.SWIFT_SCRATCH / "src")
        return (f"SF:{src}/Sources/A/A.swift\nDA:1,1\nDA:2,1\nDA:3,1\nDA:5,0\nDA:6,0\nend_of_record\n"
                "SF:/usr/lib/swift/Foundation.swift\nDA:1,1\nend_of_record\n")

    def fake_run(self, argv, **kwargs):
        args = list(argv[3:]) if list(argv[:3]) == ["nice", "-n", "10"] else list(argv)
        self.calls.append({"args": args, "timeout": kwargs.get("timeout"), "cwd": kwargs.get("cwd")})
        if args[:2] == [os.environ["SWIFT"], "-print-target-info"]:
            info = {"target": {"triple": "x86_64-unknown-linux-gnu"},
                    "paths": {"runtimeResourcePath": str(self.toolchain / "lib" / "swift")}}
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(info))
        if args[0] == "bash" and args[1].endswith("build-app-ffi.sh"):
            return subprocess.CompletedProcess(argv, 0, stdout="")
        if args[0] == "bash" and args[1].endswith("swift-tier.sh"):
            swift_args = args[args.index("--") + 1:]
            if swift_args[:2] == ["build", "--build-tests"]:
                return subprocess.CompletedProcess(argv, self.build_exit, stdout="")
            if swift_args[:2] == ["build", "--show-bin-path"]:
                (self.bin_dir / "codecov").mkdir(parents=True, exist_ok=True)
                (self.bin_dir / "codecov" / "stale.profraw").write_text("old run")
                (self.bin_dir / "APackageTests.xctest").write_text("elf")
                (self.bin_dir / "Resources.xctest").mkdir(exist_ok=True)  # not a Linux test bundle
                return subprocess.CompletedProcess(argv, 0, stdout=f"warning: x\n{self.bin_dir}\n")
            if swift_args[0] == "test":
                self.stale_at_test = sorted(p.name for p in (self.bin_dir / "codecov").glob("*.profraw"))
                (self.bin_dir / "codecov" / "1-2.profraw").write_text("counters")
                if self.test_times_out:
                    raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
                return subprocess.CompletedProcess(argv, 1, stdout="")
        if args[0].endswith("llvm-profdata"):
            return subprocess.CompletedProcess(argv, 0, stdout="")
        if args[0].endswith("llvm-cov"):
            kwargs["stdout"].write(self.lcov())
            return subprocess.CompletedProcess(argv, 0)
        raise AssertionError(f"unexpected command {args}")

    def commands(self, name: str) -> List[Dict[str, object]]:
        return [c for c in self.calls if any(str(a).endswith(name) for a in c["args"][:2])]

    def collect(self):
        out = self.work / "out"
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            code = coverage.main(["--repo", str(self.repo), "--base", self.base, "--head", self.head, "--tiers",
                                  "swift", "--out", str(out)], run=self.fake_run)
        doc = json.loads((out / "coverage.json").read_text())
        [tier] = doc["tiers"]
        self.assertEqual(tier["name"], "swift")
        listed = git(self.repo, "worktree", "list", "--porcelain")
        self.assertEqual(listed.count("worktree "), 1, f"the HEAD worktree is removed: {listed}")
        self.assertEqual([p.name for p in coverage.COV_ROOT.glob("wt-*")], [])
        return code, doc, tier, stdout.getvalue()

    def test_the_tier_exports_the_test_bundle_against_the_fresh_counters(self):
        code, doc, tier, text = self.collect()
        self.assertEqual(code, coverage.EXIT_OK, text)
        scratch = self.work / "link" / "oracle-cov" / "swift"
        self.assertEqual(tier["strip"], sorted([str(scratch / "src"), str(self.work / "real/oracle-cov/swift/src")]))
        self.assertEqual(tier["testExit"], 1)
        self.assertEqual(tier["binPath"], str(self.bin_dir))
        self.assertIn("swift test exited 1 (its counters still count)", tier["notes"])
        self.assertEqual(self.stale_at_test, [], "the last run's counters are deleted before the test")
        [merge] = self.commands("llvm-profdata")
        self.assertEqual(merge["args"][0], str(self.toolchain / "bin" / "llvm-profdata"))
        self.assertEqual(merge["args"][-1:], [str(self.bin_dir / "codecov" / "1-2.profraw")])
        [export] = self.commands("llvm-cov")
        self.assertEqual(export["args"][0], str(self.toolchain / "bin" / "llvm-cov"))
        self.assertEqual(export["args"][-1], str(self.bin_dir / "APackageTests.xctest"))
        self.assertFalse(any("-object=" in a for a in export["args"]), "a directory .xctest is not a bundle")
        [tier_build] = [c for c in self.commands("swift-tier.sh") if "--build-tests" in c["args"]]
        self.assertTrue(str(tier_build["cwd"]).startswith(str(coverage.COV_ROOT / "wt-")))
        self.assertIn("--enable-code-coverage", tier_build["args"])
        self.assertEqual(len(self.commands("build-app-ffi.sh")), 1)
        [entry] = doc["report"]["files"]
        self.assertEqual((entry["path"], entry["tier"]), ("Sources/A/A.swift", "swift"))
        self.assertEqual(entry["incremental"], {"covered": 2, "executable": 4})
        self.assertEqual(doc["report"]["uncoveredHunks"], ["Sources/A/A.swift:5-6"])

    def test_a_tier_that_does_not_build_says_so_and_removes_its_worktree(self):
        self.build_exit = 1
        code, doc, tier, _ = self.collect()
        self.assertEqual(code, coverage.EXIT_NO_COVERAGE)
        self.assertIsNone(tier["lcov"])
        self.assertTrue(any("does not build" in note for note in tier["notes"]), tier["notes"])
        self.assertEqual(self.commands("llvm-cov"), [])
        self.assertEqual(doc["report"]["unmeasured"], ["Sources/A/A.swift"])

    def test_a_test_run_past_its_bound_is_a_note_and_its_counters_still_count(self):
        self.test_times_out = True
        code, _, tier, text = self.collect()
        self.assertEqual(code, coverage.EXIT_OK, text)
        self.assertIsNone(tier["testExit"])
        self.assertTrue(any(f"timed out after {coverage.TEST_TIMEOUT} s" in note for note in tier["notes"]),
                        tier["notes"])
        self.assertIsNotNone(tier["lcov"])

    def test_a_queued_daemon_run_has_no_client_bound_and_its_timeout_keeps_the_other_tier(self):
        build_dir = self.work / "daemon-build"
        build_dir.mkdir()
        (build_dir / "build.json").write_text(json.dumps({"coverage": {
            "llvmProfdata": str(self.toolchain / "bin" / "llvm-profdata"),
            "llvmCov": str(self.toolchain / "bin" / "llvm-cov"), "sourceRoot": str(self.repo)}}))
        swift_run = self.fake_run

        def fake_run(argv, **kwargs):
            args = list(argv[3:])
            if args[:1] == ["bash"] and args[1].endswith("linux_run.sh"):
                self.calls.append({"args": args, "timeout": kwargs.get("timeout"), "cwd": kwargs.get("cwd")})
                if args[2] == "build":
                    return subprocess.CompletedProcess(argv, 0, stdout=f"{build_dir / 'cmux-tui'}\n")
                raise subprocess.TimeoutExpired(argv, 14400)
            return swift_run(argv, **kwargs)

        out = self.work / "out"
        with redirect_stdout(io.StringIO()) as stdout, redirect_stderr(io.StringIO()):
            code = coverage.main(["--repo", str(self.repo), "--base", self.base, "--head", self.head,
                                  "--out", str(out)], run=fake_run)
        self.assertEqual(code, coverage.EXIT_OK, stdout.getvalue())
        queued = self.commands("linux_run.sh")
        self.assertEqual(sorted(c["args"][2] for c in queued), ["build", "run"])
        self.assertTrue(all(c["timeout"] is None for c in queued), "runnerd bounds a queued job, not the client")
        doc = json.loads((out / "coverage.json").read_text())
        tiers = {tier["name"]: tier for tier in doc["tiers"]}
        self.assertIsNone(tiers["daemon"]["lcov"])
        [run] = tiers["daemon"]["runs"]
        self.assertIsNone(run["exit"])
        self.assertIn("linux_run.sh run", run["error"])
        self.assertTrue(any("timed out after 14400 s" in note for note in tiers["daemon"]["notes"]))
        self.assertIsNotNone(tiers["swift"]["lcov"])
        self.assertTrue((out / "report.txt").is_file())

    def test_a_tier_that_stops_on_an_error_is_a_note(self):
        def fake_run(argv, **kwargs):
            if list(argv[3:5]) == ["bash", str(coverage.HERE / "linux_run.sh")]:
                raise OSError("runnerd socket gone")
            return self.fake_run(argv, **kwargs)

        out = self.work / "out"
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = coverage.main(["--repo", str(self.repo), "--base", self.base, "--head", self.head,
                                  "--out", str(out)], run=fake_run)
        self.assertEqual(code, coverage.EXIT_OK)
        tiers = {tier["name"]: tier for tier in json.loads((out / "coverage.json").read_text())["tiers"]}
        self.assertEqual(tiers["daemon"]["notes"], ["collection stopped: runnerd socket gone"])
        self.assertIsNotNone(tiers["swift"]["lcov"])

    def test_a_toolchain_without_llvm_cov_is_a_usage_error_before_anything_runs(self):
        (self.toolchain / "bin" / "llvm-cov").unlink()
        with redirect_stderr(io.StringIO()) as err:
            code = coverage.main(["--repo", str(self.repo), "--base", self.base, "--head", self.head, "--tiers",
                                  "swift", "--out", str(self.work / "out")], run=self.fake_run)
        self.assertEqual(code, coverage.EXIT_USAGE)
        self.assertIn("llvm-cov: not in the Swift toolchain", err.getvalue())
        self.assertEqual([c["args"][1] for c in self.calls], ["-print-target-info"])


if __name__ == "__main__":
    unittest.main()
