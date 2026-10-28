#!/usr/bin/env python3
"""Tests for linux_run.sh (p15-oracle-007, p15-oracle-024) and oracle.py's queue guard: no oracle job outside the queue.

Run: python3 -I scripts/cmux-next/oracle/linux_run_test.py (stdlib unittest, Linux only). Each test
builds a throwaway repo with a ghostty-next submodule, copies linux_run.sh and runnerd.py into it
next to a stub oracle.py, and puts stub cargo and rustc on PATH, so nothing compiles; runnerd runs with
ORACLE_RUNNERD_SCOPE=none.
"""

from __future__ import annotations

import concurrent.futures
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from contextlib import redirect_stderr
from pathlib import Path
from typing import Optional

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import oracle  # noqa: E402

STUB_CARGO = """#!/bin/sh
# cargo build --locked --profile P [--features F] [--target T] -p cmux-tui -j N
profile="" out="$CARGO_TARGET_DIR"
# An oracle change that needs a product change head has and the base has not.
if [ -e NEEDS ] && [ ! -e PROVIDES ]; then echo "stub cargo: NEEDS without PROVIDES" >&2; exit 101; fi
while [ $# -gt 0 ]; do
  case "$1" in --profile) profile="$2"; shift 2 ;; --target) out="$CARGO_TARGET_DIR/$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "${RUSTFLAGS:-}" ]; then
  echo "rustflags $RUSTFLAGS out=$out" >> "$ORACLE_TEST_LOG"
fi
echo "cargo $(git -C .. rev-parse HEAD) $CARGO_TARGET_DIR changed=$(git -C .. diff --name-only | tr '\\n' ,)" >> "$ORACLE_TEST_LOG"
sleep 0.5
[ "$profile" = dev ] && profile=debug
mkdir -p "$out/$profile"
printf '#!/bin/sh\\necho stub\\n' > "$out/$profile/cmux-tui"
chmod +x "$out/$profile/cmux-tui"
"""

# rustc --version | -vV | --print sysroot; the sysroot's llvm tools are stubs too.
STUB_RUSTC = """#!/bin/sh
case "$1" in
  -vV) printf 'rustc 0.0.0-stub\\nhost: x86_64-unknown-linux-gnu\\n' ;;
  --print) echo "$ORACLE_TEST_SYSROOT" ;;
  *) echo rustc 0.0.0-stub ;;
esac
"""

# llvm-profdata merge -sparse --failure-mode=all -o OUT INPUT...: OUT lists the inputs' contents.
STUB_PROFDATA = """#!/bin/sh
out=""
[ "$1" = merge ] && shift
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) break ;; esac
done
echo "profdata $out" >> "$ORACLE_TEST_LOG"
cat "$@" > "$out"
"""

STUB_ORACLE = """#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
log = os.environ["ORACLE_TEST_LOG"]
if args[0] == "run":
    out = args[args.index("--out") + 1]
    os.makedirs(out, exist_ok=True)
    profile = os.environ.get("LLVM_PROFILE_FILE")
    if profile:
        # What an instrumented case process does at exit: its counters go to the pool the pattern names.
        with open(profile.replace("%8m", "0"), "w") as handle:
            handle.write("counters " + args[args.index("--suite") + 1] + "\\n")
        with open(log, "a") as handle:
            handle.write("profile " + profile + "\\n")
    code = int(os.environ.get("ORACLE_TEST_RUN_EXIT", "0"))
    with open(os.path.join(out, "receipt.json"), "w") as handle:
        json.dump({"ok": code == 0, "args": args}, handle)
    with open(log, "a") as handle:
        handle.write("run " + " ".join(args) + "\\n")
    time.sleep(0.3)
    sys.exit(code)
print("diff " + " ".join(args))
"""

# walks_scale.py run --binary BIN --sha SHA --work DIR --commit-dir DIR [OPTIONS]: ORACLE_TEST_WALKS picks
# the outcome: clean (exit 0), failures (one minimized walk, exit 1), unminimized (no report, exit 3).
STUB_WALKS = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["ORACLE_TEST_LOG"], "a") as handle:
    handle.write("walks " + " ".join(args) + "\\n")
work, commit = args[args.index("--work") + 1], args[args.index("--commit-dir") + 1]
mode = os.environ.get("ORACLE_TEST_WALKS", "clean")
os.makedirs(work)
def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(value, handle)
if mode != "clean":
    write(os.path.join(commit, "holder-walk-3.json"), {"id": "holder-walk-3", "suite": "walks"})
if mode == "unminimized":
    write(os.path.join(work, "unminimized.json"), {"failures": [{"seed": "walk-4"}]})
    sys.exit(3)
write(os.path.join(work, "receipt.json"), {"ok": mode == "clean", "args": args})
sys.exit(0 if mode == "clean" else 1)
"""


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                           "-c", "protocol.file.allow=always", *args], cwd=cwd, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


class LinuxRunCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory(prefix="linux-run-test-")
        base = Path(cls.tmp.name)
        ghostty = base / "ghostty-src"
        ghostty.mkdir()
        git("init", "-q", cwd=ghostty)
        (ghostty / "README").write_text("ghostty\n")
        git("add", "README", cwd=ghostty)
        git("commit", "-q", "-m", "ghostty", cwd=ghostty)
        repo = cls.repo = base / "repo"
        oracle_dir = repo / "scripts" / "cmux-next" / "oracle"
        oracle_dir.mkdir(parents=True)
        git("init", "-q", cwd=repo)
        for name in ("linux_run.sh", "runnerd.py", "patch_mutants.py", "baselines.py", "overlay.py", "facets_v0.py"):
            shutil.copy(HERE / name, oracle_dir / name)
        # overlay.py's v0 list is facets_v0.py's cut of the snapshot schema.
        schema = repo / "schemas" / "oracle" / "snapshot-v1.schema.json"
        schema.parent.mkdir(parents=True)
        shutil.copy(HERE.parents[2] / "schemas" / "oracle" / "snapshot-v1.schema.json", schema)
        (oracle_dir / "oracle.py").write_text(STUB_ORACLE)
        (oracle_dir / "walks_scale.py").write_text(STUB_WALKS)
        (repo / "cmux-tui").mkdir()
        (repo / "cmux-tui" / "Cargo.toml").write_text("[workspace]\n\n[profile.oracle]\ninherits = \"release\"\n")
        lib = repo / "cmux-tui" / "crates" / "core" / "src" / "lib.rs"
        lib.parent.mkdir(parents=True)
        lib.write_text("pub fn index(i: usize) -> usize {\n    i\n}\n")
        # A cmux-tui tag from before ghostty-next builds its VT library from the ghostty submodule.
        git("submodule", "add", "-q", str(ghostty), "ghostty", cwd=repo)
        git("add", "-A", cwd=repo)
        git("commit", "-q", "-m", "tag", cwd=repo)
        cls.tag_sha = git("rev-parse", "HEAD", cwd=repo)
        git("rm", "-q", "ghostty", cwd=repo)
        git("submodule", "add", "-q", str(ghostty), "ghostty-next", cwd=repo)
        git("add", "-A", cwd=repo)
        git("commit", "-q", "-m", "base", cwd=repo)
        cls.base_sha = git("rev-parse", "HEAD", cwd=repo)
        (repo / "cmux-tui" / "main.txt").write_text("head\n")
        git("add", "-A", cwd=repo)
        git("commit", "-q", "-m", "head", cwd=repo)
        cls.head_sha = git("rev-parse", "HEAD", cwd=repo)
        # Seeded daemon mutants as tests/oracle/mutants/ holds them, left untracked.
        mutants = repo / "tests" / "oracle" / "mutants"
        cls.mutant = cls.write_mutant(mutants / "daemon" / "index-off-by-one.patch", "    i\n", "    i + 1\n")
        cls.stale_mutant = cls.write_mutant(mutants / "daemon" / "stale-context.patch", "    i\n", "    i - 1\n",
                                            context="    j\n")
        # patch_mutants.parse takes `Key:value` with no space after the colon; the receipt must record it too.
        cls.tight_mutant = mutants / "daemon" / "tight-header.patch"
        cls.tight_mutant.write_text(cls.mutant.read_text()
                                    .replace("Mutant: daemon/index-off-by-one", "Mutant:daemon/tight-header")
                                    .replace("Fault: off by one.", "Fault:off by one.")
                                    .replace("i + 1", "i + 2"))
        cls.app_mutant = mutants / "app" / "index-off-by-one.patch"
        cls.app_mutant.parent.mkdir(parents=True)
        cls.app_mutant.write_text(cls.mutant.read_text().replace("daemon/", "app/"))
        bin_dir = cls.bin_dir = base / "bin"
        bin_dir.mkdir()
        (bin_dir / "cargo").write_text(STUB_CARGO)
        (bin_dir / "rustc").write_text(STUB_RUSTC)
        for name in ("cargo", "rustc"):
            (bin_dir / name).chmod(0o755)
        tools = cls.sysroot = base / "sysroot"
        tool_dir = tools / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
        tool_dir.mkdir(parents=True)
        (tool_dir / "llvm-profdata").write_text(STUB_PROFDATA)
        (tool_dir / "llvm-cov").write_text("#!/bin/sh\nexit 0\n")
        for name in ("llvm-profdata", "llvm-cov"):
            (tool_dir / name).chmod(0o755)

    @classmethod
    def write_mutant(cls, path: Path, old: str, new: str, context: Optional[str] = None) -> Path:
        """A patch of the stub crate's lib.rs (made with git diff, then reverted) under a mutant header;
        `context` replaces the patch's context line, so the patch no longer applies."""
        lib = cls.repo / "cmux-tui" / "crates" / "core" / "src" / "lib.rs"
        text = lib.read_text()
        lib.write_text(text.replace(old, new))
        body = git("diff", "--", str(lib.relative_to(cls.repo)), cwd=cls.repo) + "\n"
        lib.write_text(text)
        if context is not None:
            body = body.replace("-" + old, "-" + context)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"Mutant: daemon/{path.stem}\nSuite: daemon-ops\nExercises: index\nFault: off by one.\n\n{body}")
        return path

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="case-", dir=self.tmp.name))
        self.log = self.work / "log"
        self.log.touch()

    def env(self, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("RUNNERD_", "GIT_", "ORACLE_")) and k != "CMUX_GHOSTTY_SRC"}
        env.update({"PATH": f"{self.bin_dir}:{env.get('PATH', '/usr/bin:/bin')}", "ORACLE_RUNNERD_SCOPE": "none",
                    "ORACLE_RUNNERD_ROOT": str(self.work / "root"), "ORACLE_TEST_LOG": str(self.log),
                    "TMPDIR": str(self.work), "ORACLE_TEST_SYSROOT": str(self.sysroot)})
        env.update(extra)
        return env

    def linux_run(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(self.repo / "scripts/cmux-next/oracle/linux_run.sh"), *args],
                              cwd=self.repo, env=self.env(**env), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=180)

    def logged(self, kind: str) -> list:
        return [line.split(" ", 1)[1] for line in self.log.read_text().splitlines() if line.startswith(kind + " ")]


class QueueOnlyTests(LinuxRunCase):
    def test_job_entry_points_refuse_outside_a_job(self) -> None:
        for command in ("_build", "_run", "_walks"):
            result = self.linux_run(command, self.base_sha)
            self.assertEqual(result.returncode, 2, command)
            self.assertIn("only inside a runnerd job", result.stderr)
        self.assertEqual(self.logged("cargo") + self.logged("run"), [])

    def test_refuses_to_queue_anything_off_linux(self) -> None:
        fake = self.work / "fake-bin"
        fake.mkdir()
        (fake / "uname").write_text("#!/bin/sh\necho Darwin\n")
        (fake / "uname").chmod(0o755)
        result = self.linux_run("build", self.base_sha, PATH=f"{fake}:{self.bin_dir}:{os.environ['PATH']}")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Linux VM only", result.stderr)
        self.assertFalse((self.work / "root").exists())

    def test_options_linux_run_sets_are_refused_after_the_separator(self) -> None:
        result = self.linux_run("run", self.base_sha, "--", "--out", "/tmp/x")
        self.assertEqual(result.returncode, 2)
        self.assertIn("set by linux_run.sh", result.stderr)

    def test_oracle_run_on_the_vm_refuses_outside_a_job(self) -> None:
        with unittest.mock.patch.dict(os.environ, {"RUNNERD_JOB": ""}), redirect_stderr(io.StringIO()) as err:
            code = oracle.main(["run", "--binary", "/bin/true", "--out", str(self.work / "run")])
        self.assertEqual(code, 2)
        self.assertIn("runnerd queue", err.getvalue())
        self.assertFalse((self.work / "run").exists())

    def test_oracle_diff_on_the_vm_refuses_a_prebuilt_binary(self) -> None:
        with unittest.mock.patch.dict(os.environ, {"RUNNERD_JOB": ""}), redirect_stderr(io.StringIO()) as err:
            code = oracle.main(["diff", "--base", self.base_sha, "--head", self.head_sha, "--base-binary", "/bin/true",
                                "--head-binary", "/bin/true", "--out", str(self.work / "cmp")])
        self.assertEqual(code, 2)
        self.assertIn("prebuilt", err.getvalue())


class BuildTests(LinuxRunCase):
    def test_twenty_builds_of_one_pair_run_cargo_twice(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(20) as pool:
            results = list(pool.map(lambda sha: self.linux_run("build", sha), [self.base_sha, self.head_sha] * 10))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(line.split()[0] for line in self.logged("cargo")), sorted([self.base_sha, self.head_sha]))
        binaries = {result.stdout.strip().splitlines()[-1] for result in results}
        self.assertEqual(len(binaries), 2)
        for binary in binaries:
            receipt = json.loads((Path(binary).parent / "build.json").read_text())
            self.assertEqual(receipt["schema"], "cmux-oracle-build-v1")
            self.assertEqual(receipt["features"], ["oracle"])

    def test_feature_sets_build_in_their_own_target_dirs(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda f: self.linux_run("build", self.base_sha, "--features", f), ["oracle", ""]))
        targets = set()
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((Path(result.stdout.strip()).parent / "build.json").read_text())
            self.assertEqual(receipt["state"], "cold")
            targets.add(receipt["targetDir"])
        self.assertEqual({Path(t).name for t in targets},
                         {f"{self.base_sha}-oracle-feat-oracle", f"{self.base_sha}-oracle-feat-none"})

    def test_a_sha_from_before_ghostty_next_builds_with_its_ghostty_submodule(self) -> None:
        result = self.linux_run("build", self.tag_sha, "--profile", "release", "--features", "")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((Path(result.stdout.strip()).parent / "build.json").read_text())
        self.assertEqual(receipt["vtModule"], "ghostty")
        self.assertIsNone(receipt["ghosttyNext"])
        self.assertEqual(receipt["gitlinks"], {"ghostty": git("rev-parse", f"{self.tag_sha}:ghostty", cwd=self.repo)})
        base = self.linux_run("build", self.base_sha)
        self.assertEqual(base.returncode, 0, base.stderr)
        receipt = json.loads((Path(base.stdout.strip()).parent / "build.json").read_text())
        self.assertEqual((receipt["vtModule"], receipt["ghosttyNext"]),
                         ("ghostty-next", git("rev-parse", f"{self.base_sha}:ghostty-next", cwd=self.repo)))

    def test_the_build_worktree_is_gone_after_the_job(self) -> None:
        result = self.linux_run("build", self.base_sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        jobs = self.work / "root" / "jobs"
        self.assertEqual([p for p in jobs.glob("*/scratch") if p.exists()], [])


class RunTests(LinuxRunCase):
    def run_dir(self, result: subprocess.CompletedProcess) -> Path:
        return Path(result.stdout.strip().splitlines()[-1])

    def test_a_clean_run_is_reused_with_its_exit_code(self) -> None:
        first = self.linux_run("run", self.base_sha, "--suite", "alpha")
        second = self.linux_run("run", self.base_sha, "--suite", "alpha")
        self.assertEqual((first.returncode, second.returncode), (0, 0), first.stderr)
        self.assertEqual(self.run_dir(first), self.run_dir(second))
        self.assertTrue((self.run_dir(first) / "receipt.json").is_file())
        self.assertEqual(len(self.logged("run")), 1)

    def test_a_failed_run_returns_its_exit_code_and_runs_again(self) -> None:
        first = self.linux_run("run", self.base_sha, "--suite", "beta", ORACLE_TEST_RUN_EXIT="4")
        self.assertEqual(first.returncode, 4, first.stderr)
        self.assertTrue((self.run_dir(first) / "receipt.json").is_file())
        second = self.linux_run("run", self.base_sha, "--suite", "beta", ORACLE_TEST_RUN_EXIT="0")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(self.logged("run")), 2)
        self.assertTrue((self.run_dir(first) / "receipt.json").is_file(), "the earlier attempt's run dir went away")

    def test_fresh_reruns_a_done_run(self) -> None:
        self.linux_run("run", self.base_sha, "--suite", "gamma")
        fresh = self.linux_run("run", self.base_sha, "--suite", "gamma", "--fresh")
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertEqual(len(self.logged("run")), 2)
        self.assertEqual(len(self.logged("cargo")), 1)

    def test_shuffle_without_a_seed_gets_its_own_order(self) -> None:
        one = self.linux_run("run", self.base_sha, "--suite", "delta", "--", "--shuffle")
        two = self.linux_run("run", self.base_sha, "--suite", "delta", "--", "--shuffle")
        self.assertEqual((one.returncode, two.returncode), (0, 0), one.stderr)
        runs = self.logged("run")
        self.assertEqual(len(runs), 2)
        seeds = {run.split("--seed ")[1].split()[0] for run in runs}
        self.assertEqual(len(seeds), 2)

    def test_diff_of_one_sha_with_itself_runs_twice(self) -> None:
        result = self.linux_run("diff", self.base_sha, self.base_sha, "--suite", "eps",
                                "--out", str(self.work / "cmp"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.logged("run")), 2)
        line = result.stdout.strip().splitlines()[-1]
        base_run = line.split("--base-run ")[1].split()[0]
        head_run = line.split("--head-run ")[1].split()[0]
        self.assertNotEqual(base_run, head_run)

    def test_diff_runs_each_side_once_and_shares_a_shuffle_seed(self) -> None:
        result = self.linux_run("diff", self.base_sha, self.head_sha, "--suite", "zeta",
                                "--out", str(self.work / "cmp"), "--", "--shuffle")
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = self.logged("run")
        self.assertEqual(len(runs), 2)
        self.assertEqual(len({run.split("--seed ")[1].split()[0] for run in runs}), 1)

    def test_diff_receipt_has_both_builds_and_never_an_old_comparison(self) -> None:
        out = self.work / "cmp"
        out.mkdir()
        (out / "comparison.json").write_text(json.dumps({"stale": True}))
        result = self.linux_run("diff", self.base_sha, self.head_sha, "--suite", "eta", "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((out / "linux-run.json").read_text())
        self.assertEqual(receipt["schema"], "cmux-oracle-linux-run-v1")
        self.assertEqual((receipt["base"]["sha"], receipt["head"]["sha"]), (self.base_sha, self.head_sha))
        ghostty = git("rev-parse", f"{self.base_sha}:ghostty-next", cwd=self.repo)
        self.assertEqual(receipt["base"]["gitlinks"], {"ghostty-next": ghostty})
        self.assertEqual(receipt["base"]["build"]["schema"], "cmux-oracle-build-v1")
        self.assertIsNone(receipt["comparison"], "the stub writes no comparison; the old one must not show")
        self.assertEqual(receipt["oracleExit"], 0)

    def test_diff_hands_both_builds_to_the_comparison(self) -> None:
        """Task 112: oracle.py diff gets --builds with each side's ref, exact SHA and gitlinks."""
        out = self.work / "cmp"
        result = self.linux_run("diff", self.base_sha, "HEAD", "--suite", "iota", "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--builds {out / 'builds.json'}", result.stdout.strip().splitlines()[-1])
        builds = json.loads((out / "builds.json").read_text())
        ghostty = git("rev-parse", f"{self.base_sha}:ghostty-next", cwd=self.repo)
        self.assertEqual((builds["base"]["ref"], builds["base"]["sha"]), (self.base_sha, self.base_sha))
        self.assertEqual((builds["head"]["ref"], builds["head"]["sha"]), ("HEAD", self.head_sha))
        for side in ("base", "head"):
            self.assertEqual(builds[side]["gitlinks"], {"ghostty-next": ghostty})
            self.assertEqual(builds[side]["schema"], "cmux-oracle-build-v1")

    def test_run_copies_its_build_receipt(self) -> None:
        receipt = self.work / "build.json"
        result = self.linux_run("run", self.head_sha, "--suite", "kappa", "--receipt", str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        build = json.loads(receipt.read_text())
        self.assertEqual(build["sha"], self.head_sha)
        self.assertEqual(build["gitlinks"], {"ghostty-next": git("rev-parse", f"{self.head_sha}:ghostty-next",
                                                                 cwd=self.repo)})
        refused = self.linux_run("diff", self.base_sha, self.head_sha, "--receipt", str(receipt),
                                 "--out", str(self.work / "c"))
        self.assertEqual(refused.returncode, 2)
        self.assertIn("--receipt is for run", refused.stderr)

    def test_diff_output_stays_outside_the_checkout(self) -> None:
        result = self.linux_run("diff", self.base_sha, self.head_sha, "--out", str(self.repo / "cmp"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside the checkout", result.stderr)
        self.assertEqual(self.logged("cargo"), [])


class OverlayTests(LinuxRunCase):
    """A base from before head's oracle (overlay.py, p15-oracle-202): the base side builds the overlay commit,
    or both sides run v0 facets when the oracle commit conflicts or the overlay does not build."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        repo = cls.repo
        cargo = repo / "cmux-tui" / "Cargo.toml"
        text = cargo.read_text()

        def commit(subject: str) -> str:
            git("add", "-A", cwd=repo)
            git("commit", "-q", "-m", subject, cwd=repo)
            return git("rev-parse", "HEAD", cwd=repo)

        cargo.write_text(text + "\n[features]\noracle = []\n")
        cls.oracle_head = commit("p15-oracle-201: the oracle feature")
        (repo / "cmux-tui" / "PROVIDES").write_text("x\n")
        commit("perf: a product change")
        (repo / "cmux-tui" / "NEEDS").write_text("x\n")
        cls.broken_head = commit("p15-oracle-203: an oracle change that builds only on that product change")
        git("checkout", "-q", "--detach", cls.base_sha, cwd=repo)
        cargo.write_text(text + "\n[features]\nfast = []\n")
        cls.conflict_base = commit("other: a feature in the same place")
        git("checkout", "-q", "--detach", cls.base_sha, cwd=repo)
        cargo.write_text("[workspace]\n")
        cls.pre_oracle = commit("other: a base from before the oracle profile")
        git("checkout", "-q", "--detach", cls.head_sha, cwd=repo)

    def diff(self, base: str, head: str, *extra: str) -> tuple:
        out = self.work / "cmp"
        result = self.linux_run("diff", base, head, "--suite", "eps", "--out", str(out), *extra)
        receipt = json.loads((out / "linux-run.json").read_text()) if (out / "linux-run.json").is_file() else None
        return result, receipt

    def test_the_base_side_builds_the_overlay_commit(self) -> None:
        result, receipt = self.diff(self.base_sha, self.oracle_head)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = receipt["overlay"]
        self.assertEqual((plan["mode"], plan["facets"], plan["applied"]), ("overlay", "v1", [self.oracle_head]))
        sha = plan["overlaySha"]
        self.assertEqual((receipt["base"]["sha"], receipt["head"]["sha"]), (sha, self.oracle_head))
        self.assertEqual(receipt["base"]["build"]["overlay"]["base"], self.base_sha)
        self.assertIsNone(receipt["head"]["build"]["overlay"])
        self.assertIn("oracle = []", git("show", f"{sha}:cmux-tui/Cargo.toml", cwd=self.repo))
        self.assertNotIn("cmux-tui/main.txt", git("ls-tree", "-r", "--name-only", sha, cwd=self.repo),
                         "the non-oracle commit between base and head stays out")
        self.assertEqual(sorted(line.split()[0] for line in self.logged("cargo")), sorted([sha, self.oracle_head]),
                         "the overlay builds once, for the plan's check and the run")
        self.assertFalse(any("--facets" in run for run in self.logged("run")))
        self.assertIn(f"--overlay {self.work / 'cmp' / 'overlay.json'}", result.stdout)

    def test_a_conflicting_oracle_commit_runs_both_sides_on_v0(self) -> None:
        result, receipt = self.diff(self.conflict_base, self.oracle_head)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = receipt["overlay"]
        self.assertEqual((plan["mode"], plan["facets"]), ("v0", "v0"))
        self.assertIn("conflicts in cmux-tui/Cargo.toml", plan["reason"])
        self.assertIn("daemon/journalHead", [e["facet"] for e in plan["notComparable"]])
        self.assertEqual(receipt["base"]["sha"], self.conflict_base)
        runs = self.logged("run")
        self.assertEqual(len(runs), 2)
        self.assertTrue(all("--facets v0" in run for run in runs))

    def test_an_overlay_that_does_not_build_falls_back_to_v0(self) -> None:
        result, receipt = self.diff(self.base_sha, self.broken_head)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = receipt["overlay"]
        self.assertEqual(plan["mode"], "v0")
        self.assertIn("does not build", plan["reason"])
        self.assertEqual(receipt["base"]["sha"], self.base_sha)
        self.assertTrue(all("--facets v0" in run for run in self.logged("run")))

    def test_a_base_without_the_oracle_profile_builds_dev(self) -> None:
        result, receipt = self.diff(self.pre_oracle, self.oracle_head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["overlay"]["mode"], "v0")
        self.assertEqual(receipt["base"]["sha"], self.pre_oracle)
        self.assertEqual((receipt["base"]["build"]["profile"], receipt["base"]["build"]["features"]), ("dev", []))
        self.assertEqual((receipt["head"]["build"]["profile"], receipt["head"]["build"]["features"]),
                         ("oracle", ["oracle"]))

    def test_diff_sets_the_facets_itself(self) -> None:
        result, _ = self.diff(self.base_sha, self.oracle_head, "--", "--facets", "v1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("set by linux_run.sh diff", result.stderr)

    def test_overlay_prints_the_plan_path(self) -> None:
        plan_path = self.work / "plan.json"
        result = self.linux_run("overlay", self.base_sha, self.oracle_head, "--out", str(plan_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], str(plan_path))
        self.assertEqual(json.loads(plan_path.read_text())["mode"], "overlay")
        refused = self.linux_run("overlay", self.base_sha, self.oracle_head, "--product", "app")
        self.assertEqual(refused.returncode, 2)


class MutantTests(LinuxRunCase):
    """Seeded patch mutants (p15-oracle-026): applied in the job worktree only, keyed and recorded."""

    def receipt(self, result: subprocess.CompletedProcess) -> dict:
        return json.loads((Path(result.stdout.strip().splitlines()[-1]).parent / "build.json").read_text())

    def test_a_mutant_build_applies_the_patch_in_its_own_worktree(self) -> None:
        mutated = self.linux_run("build", self.base_sha, "--mutant", str(self.mutant))
        self.assertEqual(mutated.returncode, 0, mutated.stderr)
        clean = self.linux_run("build", self.base_sha)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        builds = self.logged("cargo")
        self.assertEqual(len(builds), 2, "a mutant build and a clean build are two keys")
        self.assertTrue(builds[0].endswith("changed=cmux-tui/crates/core/src/lib.rs,"), builds[0])
        self.assertTrue(builds[1].endswith("changed="), builds[1])
        receipt = self.receipt(mutated)
        self.assertEqual(receipt["mutant"]["id"], "daemon/index-off-by-one")
        self.assertEqual(receipt["mutant"]["suite"], "daemon-ops")
        self.assertEqual(Path(receipt["targetDir"]).name, f"{self.base_sha}-oracle-feat-oracle+mutant")
        self.assertIsNone(self.receipt(clean)["mutant"])
        self.assertEqual(Path(self.receipt(clean)["targetDir"]).name, f"{self.base_sha}-oracle-feat-oracle")
        lib = self.repo / "cmux-tui" / "crates" / "core" / "src" / "lib.rs"
        self.assertNotIn("i + 1", lib.read_text(), "the submitter's checkout stays clean")

    def test_the_receipt_records_the_header_as_the_validator_parses_it(self) -> None:
        result = self.linux_run("build", self.base_sha, "--mutant", str(self.tight_mutant))
        self.assertEqual(result.returncode, 0, result.stderr)
        mutant = self.receipt(result)["mutant"]
        self.assertEqual(mutant["id"], "daemon/tight-header")
        self.assertEqual(mutant["fault"], "off by one.")
        self.assertEqual(mutant["exercises"], "index")
        self.assertEqual(mutant["files"], ["cmux-tui/crates/core/src/lib.rs"])

    def test_a_mutant_that_does_not_apply_fails_its_build(self) -> None:
        result = self.linux_run("build", self.base_sha, "--mutant", str(self.stale_mutant))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not apply", result.stderr)
        self.assertEqual(self.logged("cargo"), [])

    def test_an_app_mutant_is_refused_before_anything_is_queued(self) -> None:
        for command in (["build", self.base_sha], ["diff", self.base_sha, self.base_sha, "--out", str(self.work / "c")]):
            result = self.linux_run(*command, "--mutant", str(self.app_mutant))
            self.assertEqual(result.returncode, 2, command)
            self.assertIn("not a daemon mutant", result.stderr)
        self.assertFalse((self.work / "root").exists())

    def test_diff_builds_the_mutant_on_the_head_side_only(self) -> None:
        out = self.work / "cmp"
        result = self.linux_run("diff", self.base_sha, self.base_sha, "--suite", "theta", "--out", str(out),
                                "--mutant", str(self.mutant))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(line.rsplit("changed=", 1)[1] for line in self.logged("cargo")),
                         ["", "cmux-tui/crates/core/src/lib.rs,"])
        self.assertEqual(len(self.logged("run")), 2)
        receipt = json.loads((out / "linux-run.json").read_text())
        self.assertIsNone(receipt["base"]["build"]["mutant"])
        self.assertEqual(receipt["head"]["build"]["mutant"]["id"], "daemon/index-off-by-one")
        self.assertEqual(receipt["mutant"]["id"], "daemon/index-off-by-one")


# linux_run.sh run, stubbed for `oracle.py diff --base --head` (task 112): writes the build receipt (STUB_BUILT_SHA and
# STUB_GITLINKS stand in for a wrong build) and prints the run prepared for the SHA under STUB_RUNS.
STUB_LINUX_RUN = r"""#!/usr/bin/env bash
set -eu
if [[ "$1" == overlay ]]; then
  # The base build's plan (overlay.py, p15-oracle-202): these bases have head's oracle, so it builds the base.
  base="$2" out=""
  while (($#)); do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
  printf '{"schema": "cmux-oracle-overlay-v1", "mode": "native", "facets": "v1", "buildSha": "%s", "notComparable": []}\n' \
    "$base" > "$out"
  echo "$out"
  exit 0
fi
sha="$2" receipt=""
while (($#)); do
  case "$1" in --receipt) receipt="$2"; shift 2 ;; --) break ;; *) shift ;; esac
done
echo "$sha" >> "$ORACLE_TEST_LOG"
printf '{"schema": "cmux-oracle-build-v1", "sha": "%s", "gitlinks": %s}\n' "${STUB_BUILT_SHA:-$sha}" "$STUB_GITLINKS" > "$receipt"
echo "$STUB_RUNS/$sha"
"""


@unittest.skipUnless(sys.platform.startswith("linux"), "the queued diff runs on the Linux VM")
class OracleBaseHeadDiffTests(LinuxRunCase):
    """`oracle.py diff --base A [--head B]` on the VM: both builds' exact SHAs and gitlinks reach comparison.json."""

    def setUp(self) -> None:
        super().setUp()
        import oracle_cli_test as cli  # the fake driver and corpus of oracle.py's own tests
        self.stub = self.work / "linux_run.sh"
        self.stub.write_text(STUB_LINUX_RUN)
        cli.write_corpus(self.work / "corpus", suites=("alpha",), per_suite=4)
        cases, _ = oracle.load_corpus(self.work / "corpus")
        for sha in (self.base_sha, self.head_sha):
            oracle.perform_run(cli.options(self.work, out=self.work / "runs" / sha, ref=sha, run_id=sha[:8]), cases,
                               cli.FakeDriver().open_session, None, {})
        self.ghostty = git("rev-parse", f"{self.base_sha}:ghostty-next", cwd=self.repo)
        # oracle.py names its engine parity file relative to REPO (its --engine help): it moves with REPO.
        self.patches = [unittest.mock.patch.object(oracle, "REPO", self.repo),
                        unittest.mock.patch.object(oracle, "ENGINE_PARITY_FILE",
                                                   self.repo / oracle.ENGINE_PARITY_FILE.relative_to(oracle.REPO)),
                        unittest.mock.patch.object(oracle, "LINUX_RUN", self.stub),
                        unittest.mock.patch.dict(os.environ, {
                            "RUNNERD_JOB": "", "ORACLE_TEST_LOG": str(self.log), "STUB_RUNS": str(self.work / "runs"),
                            "STUB_GITLINKS": json.dumps({"ghostty-next": self.ghostty})})]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)

    def diff(self, *argv: str):
        out = self.work / "cmp"
        with redirect_stderr(io.StringIO()) as err, unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
            code = oracle.main(["diff", *argv, "--out", str(out), "--expectations-root", str(self.work / "exp")])
        self.err = err.getvalue()
        path = out / "comparison.json"
        return code, json.loads(path.read_text()) if path.is_file() else None

    def test_comparison_names_both_shas_and_gitlinks(self) -> None:
        code, comparison = self.diff("--base", self.base_sha, "--head", self.head_sha)
        self.assertEqual(code, 0, self.err)
        self.assertEqual(comparison["divergent"], [])
        builds = comparison["builds"]
        self.assertEqual((builds["base"]["sha"], builds["head"]["sha"]), (self.base_sha, self.head_sha))
        for side in ("base", "head"):
            self.assertEqual(builds[side]["gitlinks"], {"ghostty-next": self.ghostty})

    def test_head_defaults_to_HEAD_and_tip_against_tip_runs_twice(self) -> None:
        code, comparison = self.diff("--base", "HEAD")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(comparison["compared"], 4)
        self.assertEqual(comparison["builds"]["head"]["ref"], "HEAD")
        self.assertEqual({comparison["builds"][s]["sha"] for s in ("base", "head")}, {self.head_sha})
        self.assertEqual(self.log.read_text().split(), [self.head_sha, self.head_sha])

    def test_a_build_of_another_commit_or_tree_is_refused(self) -> None:
        for env, message in (({"STUB_BUILT_SHA": self.head_sha}, "build receipt is of"),
                             ({"STUB_GITLINKS": json.dumps({"ghostty-next": "f" * 40})}, "recorded gitlinks")):
            with self.subTest(env=env), unittest.mock.patch.dict(os.environ, env):
                code, _ = self.diff("--base", self.base_sha, "--head", self.base_sha)
                self.assertEqual(code, 2)
                self.assertIn(message, self.err)

    def test_a_run_of_another_sha_than_its_build_is_refused(self) -> None:
        # The run of the base SHA, reported as a build of the head: the run receipt and the build record disagree.
        builds = self.work / "builds.json"
        builds.write_text(json.dumps({side: {"sha": self.head_sha, "gitlinks": {}} for side in ("base", "head")}))
        code, comparison = self.diff("--base-run", str(self.work / "runs" / self.base_sha),
                                     "--head-run", str(self.work / "runs" / self.head_sha), "--builds", str(builds))
        self.assertEqual(code, oracle.EXIT_REFUSED, self.err)
        self.assertIn("build-mismatch: the base run is of", comparison["refused"])
        self.assertEqual(comparison["builds"]["base"]["sha"], self.head_sha)


class CoverageTests(LinuxRunCase):
    """--coverage (p15-oracle-190): an instrumented build in its own target dir, counters merged per run."""

    def test_a_coverage_build_instruments_the_target_only_and_names_its_tools(self) -> None:
        covered = self.linux_run("build", self.base_sha, "--coverage")
        self.assertEqual(covered.returncode, 0, covered.stderr)
        plain = self.linux_run("build", self.base_sha)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertEqual(len(self.logged("cargo")), 2, "an instrumented build and a plain build are two keys")
        flags = self.logged("rustflags")
        self.assertEqual(len(flags), 1, "only the coverage build sets RUSTFLAGS")
        self.assertIn("-C instrument-coverage", flags[0])
        self.assertTrue(flags[0].endswith("/x86_64-unknown-linux-gnu"), "an explicit --target keeps build scripts plain")
        binary = Path(covered.stdout.strip().splitlines()[-1])
        receipt = json.loads((binary.parent / "build.json").read_text())
        self.assertEqual(Path(receipt["targetDir"]).name, f"{self.base_sha}-oracle-feat-oracle+cov")
        tools = receipt["coverage"]
        self.assertEqual(Path(tools["llvmProfdata"]).name, "llvm-profdata")
        self.assertTrue(tools["llvmCov"].startswith(str(self.sysroot)))
        self.assertEqual(tools["target"], "x86_64-unknown-linux-gnu")
        self.assertTrue(tools["sourceRoot"].endswith("/scratch/wt"), tools["sourceRoot"])
        self.assertIsNone(json.loads((Path(plain.stdout.strip()).parent / "build.json").read_text())["coverage"])

    def test_a_coverage_run_merges_its_counters_into_the_run_dir(self) -> None:
        result = self.linux_run("run", self.base_sha, "--suite", "iota", "--coverage")
        self.assertEqual(result.returncode, 0, result.stderr)
        run_dir = Path(result.stdout.strip().splitlines()[-1])
        self.assertEqual((run_dir / "coverage.profdata").read_text(), "counters iota\n")
        self.assertFalse((run_dir.parent / "profraw").exists(), "the raw pools go once merged")
        [profile] = self.logged("profile")
        self.assertTrue(profile.endswith("/profraw/cmux-%8m.profraw"), profile)
        plain = self.linux_run("run", self.base_sha, "--suite", "iota")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertFalse((Path(plain.stdout.strip().splitlines()[-1]) / "coverage.profdata").exists())
        self.assertEqual(len(self.logged("profile")), 1, "a plain build's run sets no LLVM_PROFILE_FILE")

    def test_diff_refuses_coverage(self) -> None:
        result = self.linux_run("diff", self.base_sha, self.head_sha, "--coverage", "--out", str(self.work / "c"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("--coverage is for run", result.stderr)
        self.assertEqual(self.logged("cargo"), [])


class WalksTests(LinuxRunCase):
    """`linux_run.sh walks` (p15-oracle-099): one build, one queued walks job, minimized walks into the corpus."""

    def setUp(self) -> None:
        super().setUp()
        self.corpus = self.repo / "tests" / "oracle" / "corpus" / "walks"
        self.addCleanup(shutil.rmtree, self.corpus, True)

    def walks_dir(self, result: subprocess.CompletedProcess) -> Path:
        return Path(result.stdout.strip().splitlines()[-1])

    def test_one_build_and_one_job_run_the_walks_on_that_binary(self) -> None:
        result = self.linux_run("walks", self.base_sha, "--", "--seeds", "20", "--switch", "holder")
        self.assertEqual(result.returncode, 0, result.stderr)
        [build] = self.logged("cargo")
        self.assertTrue(build.startswith(self.base_sha), build)
        [walks] = self.logged("walks")
        args = walks.split()
        self.assertEqual(args[0], "run")
        self.assertEqual(args[args.index("--sha") + 1], self.base_sha)
        binary = Path(args[args.index("--binary") + 1])
        self.assertTrue((binary.parent / "build.json").is_file())
        self.assertEqual(args[-4:], ["--seeds", "20", "--switch", "holder"])
        work = self.walks_dir(result)
        self.assertEqual(Path(args[args.index("--work") + 1]), work)
        self.assertTrue((work / "receipt.json").is_file())
        self.assertNotIn(str(self.repo), str(work), "the walks dir stays outside the checkout")
        self.assertFalse(self.corpus.exists(), "a clean run adds no walk to the corpus")

    def test_a_clean_run_is_reused_and_fresh_runs_again(self) -> None:
        first = self.linux_run("walks", self.base_sha, "--", "--seeds", "5")
        again = self.linux_run("walks", self.base_sha, "--", "--seeds", "5")
        other = self.linux_run("walks", self.base_sha, "--", "--seeds", "6")
        fresh = self.linux_run("walks", self.base_sha, "--fresh", "--", "--seeds", "5")
        for result in (first, again, other, fresh):
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.walks_dir(first), self.walks_dir(again))
        self.assertEqual(len(self.logged("walks")), 3)
        self.assertEqual(len(self.logged("cargo")), 1)

    def test_minimized_walks_are_copied_into_the_corpus_once_reported(self) -> None:
        result = self.linux_run("walks", self.base_sha, ORACLE_TEST_WALKS="failures")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(sorted(p.name for p in self.corpus.glob("*.json")), ["holder-walk-3.json"])
        self.assertIn(f"minimized walk {self.corpus / 'holder-walk-3.json'}", result.stderr)
        again = self.linux_run("walks", self.base_sha, ORACLE_TEST_WALKS="failures")
        self.assertEqual(again.returncode, 1, again.stderr)
        self.assertEqual(len(self.logged("walks")), 2, "a run with failures is never reused")

    def test_no_walk_reaches_the_corpus_without_a_report(self) -> None:
        result = self.linux_run("walks", self.base_sha, ORACLE_TEST_WALKS="unminimized")
        self.assertEqual(result.returncode, 3, result.stderr)
        work = self.walks_dir(result)
        self.assertTrue((work / "unminimized.json").is_file())
        self.assertFalse((work / "receipt.json").exists())
        self.assertFalse(self.corpus.exists())

    def test_options_walks_sets_are_refused(self) -> None:
        for option in ("--binary", "--sha", "--work", "--commit-dir", "--registry"):
            result = self.linux_run("walks", self.base_sha, "--", option, "x")
            self.assertEqual(result.returncode, 2, option)
            self.assertIn("set by linux_run.sh walks", result.stderr)
        for argv in (("walks",), ("walks", self.base_sha, "--timeout", "1h"), ("walks", self.base_sha, "--seeds", "1")):
            self.assertEqual(self.linux_run(*argv).returncode, 2, argv)
        self.assertFalse((self.work / "root").exists(), "nothing is queued for a refused request")


class QueuedDiffArgsTests(unittest.TestCase):
    def args(self, *argv: str):
        return oracle.build_parser().parse_args(["diff", "--base", "a", "--head", "b", *argv])

    def test_defaults_add_no_run_options(self) -> None:
        self.assertEqual(oracle.queued_run_args(self.args()), [])

    def test_a_filtered_diff_keeps_its_retries(self) -> None:
        self.assertEqual(oracle.queued_run_args(self.args("--filter", "a/*", "--seed", "7")),
                         ["--filter", "a/*", "--seed", "7", "--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT)])


if __name__ == "__main__":
    unittest.main()
