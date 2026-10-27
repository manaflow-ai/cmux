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
# cargo build --locked --profile P [--features F] -p cmux-tui -j N
profile=""
while [ $# -gt 0 ]; do
  case "$1" in --profile) profile="$2"; shift 2 ;; *) shift ;; esac
done
echo "cargo $(git -C .. rev-parse HEAD) $CARGO_TARGET_DIR changed=$(git -C .. diff --name-only | tr '\\n' ,)" >> "$ORACLE_TEST_LOG"
sleep 0.5
mkdir -p "$CARGO_TARGET_DIR/$profile"
printf '#!/bin/sh\\necho stub\\n' > "$CARGO_TARGET_DIR/$profile/cmux-tui"
chmod +x "$CARGO_TARGET_DIR/$profile/cmux-tui"
"""

STUB_ORACLE = """#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
log = os.environ["ORACLE_TEST_LOG"]
if args[0] == "run":
    out = args[args.index("--out") + 1]
    os.makedirs(out, exist_ok=True)
    code = int(os.environ.get("ORACLE_TEST_RUN_EXIT", "0"))
    with open(os.path.join(out, "receipt.json"), "w") as handle:
        json.dump({"ok": code == 0, "args": args}, handle)
    with open(log, "a") as handle:
        handle.write("run " + " ".join(args) + "\\n")
    time.sleep(0.3)
    sys.exit(code)
print("diff " + " ".join(args))
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
        for name in ("linux_run.sh", "runnerd.py", "patch_mutants.py", "baselines.py"):
            shutil.copy(HERE / name, oracle_dir / name)
        (oracle_dir / "oracle.py").write_text(STUB_ORACLE)
        (repo / "cmux-tui").mkdir()
        (repo / "cmux-tui" / "Cargo.toml").write_text("[workspace]\n\n[profile.oracle]\ninherits = \"release\"\n")
        lib = repo / "cmux-tui" / "crates" / "core" / "src" / "lib.rs"
        lib.parent.mkdir(parents=True)
        lib.write_text("pub fn index(i: usize) -> usize {\n    i\n}\n")
        # A cmux-tui tag from before ghostty-next builds its VT library from the ghostty submodule (p15-oracle-208).
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
        # Seeded daemon mutants as tests/oracle/mutants/ holds them (p15-oracle-026), left untracked.
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
        (bin_dir / "rustc").write_text("#!/bin/sh\necho rustc 0.0.0-stub\n")
        for name in ("cargo", "rustc"):
            (bin_dir / name).chmod(0o755)

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
                    "TMPDIR": str(self.work)})
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
        for command in ("_build", "_run"):
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

    def test_diff_output_stays_outside_the_checkout(self) -> None:
        result = self.linux_run("diff", self.base_sha, self.head_sha, "--out", str(self.repo / "cmp"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside the checkout", result.stderr)
        self.assertEqual(self.logged("cargo"), [])


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
