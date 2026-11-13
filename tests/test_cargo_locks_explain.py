#!/usr/bin/env python3
"""A stale Cargo.lock is named as such by every CI wrapper that runs cargo with --locked.

cargo exits 101 before compiling when a Cargo.lock does not match its manifests and --locked was passed, and
prints one of three sentences. A wrapper that then prints a cause of its own ("fix each lint", "the tests do not
build", "Windows build broken", "retrying Cargo registry fetches") sends the reader after something that did not
happen: 2026-11-12, one pull request went red on 15 checks for a stale lock; the clippy job said "fix each lint",
the author reran twice and stopped. `scripts/cmux-next/cargo-locks.py explain LOG` is the one place that knows
cargo's words; each wrapper asks it on its failure path.

What this holds:
- explain itself: each spelling, a path with a space, stdin, the GitHub annotation, silence on anything else, and a
  5 MB log in well under 2 s.
- The Python and shell wrappers, run against a fake cargo: a refusal prints the stale-lock block and not the old
  cause, with the old exit code; any other failure prints the old cause.
- The four workflow steps ask explain before their own ::error.
- The list: every file (workflow step, for workflows) under scripts/ and .github/ that runs cargo with --locked and
  prints ::error, FAIL or left: is either explained or allowlisted as passing cargo's output through. A new wrapper
  fails here until it is one or the other.

No cargo is needed: every cargo here is a fake. Run: python3 -m unittest tests/test_cargo_locks_explain.py
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/cargo-locks.py"

SPELLINGS = {
    "update": "error: cannot update the lock file {lock} because --locked was passed to prevent this",
    "create": "error: cannot create the lock file {lock} because --locked was passed to prevent this",
    "needs": "error: the lock file {lock} needs to be updated but --locked was passed to prevent this",
}
COMPILE_ERROR = ("error[E0425]: cannot find value `x` in this scope\n"
                 " --> crates/a/src/lib.rs:1:1\n"
                 "error: could not compile `a` (lib) due to 1 previous error\n")

# A fake cargo: FAKE_CARGO=update|create|needs prints that refusal for FAKE_LOCK (default $PWD/Cargo.lock) and
# exits 101; FAKE_CARGO=broken prints a compile error and exits 101; anything else succeeds (metadata prints
# FAKE_METADATA). FAKE_CARGO_ONLY: fail only that subcommand. FAKE_CARGO_IF_FILE: fail only when that path exists
# (relative to cargo's directory).
FAKE_CARGO = r"""#!/usr/bin/env bash
sub="${1:-}"
mode="${FAKE_CARGO:-ok}"
if [[ -n "${FAKE_CARGO_ONLY:-}" && "$sub" != "$FAKE_CARGO_ONLY" ]]; then mode=ok; fi
if [[ -n "${FAKE_CARGO_IF_FILE:-}" && ! -e "$FAKE_CARGO_IF_FILE" ]]; then mode=ok; fi
lock="${FAKE_LOCK:-$PWD/Cargo.lock}"
case "$mode" in
  update) echo "error: cannot update the lock file $lock because --locked was passed to prevent this" >&2; exit 101 ;;
  create) echo "error: cannot create the lock file $lock because --locked was passed to prevent this" >&2; exit 101 ;;
  needs) echo "error: the lock file $lock needs to be updated but --locked was passed to prevent this" >&2; exit 101 ;;
  broken) printf '%s' "$FAKE_COMPILE_ERROR" >&2; exit 101 ;;
esac
if [[ "$sub" == metadata ]]; then cat "${FAKE_METADATA:-/dev/null}"; fi
exit 0
"""

GIT_ENV = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_AUTHOR_NAME": "F",
           "GIT_AUTHOR_EMAIL": "f@e", "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"}


def clean_env(**extra: str) -> dict[str, str]:
    """os.environ without GitHub's variables (a run on CI must not change what explain prints) and git's."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GIT_", "FAKE_"))}
    env.update(GIT_ENV)
    env.update(extra)
    return env


class Scratch(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="cmux-stale-lock ")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.fake("cargo", FAKE_CARGO)

    def fake(self, name: str, text: str) -> None:
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def env(self, **extra: str) -> dict[str, str]:
        return clean_env(PATH=f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
                         FAKE_COMPILE_ERROR=COMPILE_ERROR, **extra)

    def git(self, repo: Path, *args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], env=clean_env(), check=True, capture_output=True,
                              text=True).stdout.strip()

    def assert_stale_block(self, text: str, lock: str) -> None:
        self.assertIn(f"stale Cargo.lock: {lock} does not match its manifests on this ref", text)
        self.assertIn("scripts/cmux-next/cargo-locks.py fix", text)
        self.assertIn("A rerun does not help.", text)


class ExplainTests(Scratch):
    def explain(self, *args: str, stdin: str | None = None, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "explain", *args], input=stdin, text=True,
                              capture_output=True, env=clean_env(**env), timeout=60)

    def log(self, text: str, name: str = "cargo.log") -> Path:
        path = self.tmp / name
        path.write_text(text)
        return path

    def test_each_spelling_names_the_lock_and_the_fix(self) -> None:
        for spelling, line in SPELLINGS.items():
            with self.subTest(spelling=spelling):
                lock = ROOT / "cmux-tui/Cargo.lock"
                log = self.log(f"   Compiling a v0.1.0\n{line.format(lock=lock)}\n")
                result = self.explain(str(log))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_stale_block(result.stderr, "cmux-tui/Cargo.lock")
                self.assertEqual(result.stdout, "", "no annotation outside GitHub Actions")

    def test_github_actions_gets_one_error_annotation(self) -> None:
        log = self.log(SPELLINGS["update"].format(lock=ROOT / "Cargo.lock") + "\n")
        result = self.explain(str(log), GITHUB_ACTIONS="true")
        self.assertEqual(result.returncode, 0)
        self.assertRegex(result.stdout, r"^::error title=stale Cargo\.lock::Cargo\.lock does not match")
        self.assertEqual(result.stdout.count("::error"), 1)
        self.assert_stale_block(result.stderr, "Cargo.lock")

    def test_stdin(self) -> None:
        result = self.explain("-", stdin=SPELLINGS["needs"].format(lock=ROOT / "a/Cargo.lock") + "\n")
        self.assertEqual(result.returncode, 0)
        self.assert_stale_block(result.stderr, "a/Cargo.lock")

    def test_a_lock_outside_the_repository_keeps_its_path_and_a_space_in_it_matches(self) -> None:
        lock = self.tmp / "my work" / "Cargo.lock"
        result = self.explain(str(self.log(f"[crate] {SPELLINGS['update'].format(lock=lock)}\n")))
        self.assertEqual(result.returncode, 0)
        self.assert_stale_block(result.stderr, str(lock))
        inside = self.explain(str(self.log(SPELLINGS["create"].format(lock=lock) + "\n")), "--repo", str(self.tmp))
        self.assert_stale_block(inside.stderr, "my work/Cargo.lock")

    def test_two_locks_are_one_block(self) -> None:
        text = "".join(SPELLINGS["update"].format(lock=ROOT / d / "Cargo.lock") + "\n" for d in ("a", "b", "a"))
        result = self.explain(str(self.log(text)))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count("stale Cargo.lock:"), 1)
        self.assertIn("a/Cargo.lock, b/Cargo.lock do not match their manifests", result.stderr)

    def test_anything_else_is_silent(self) -> None:
        cases = {
            "a compile error": self.log(COMPILE_ERROR),
            "an empty log": self.log(""),
            "a missing file": self.tmp / "missing.log",
            "a directory": self.tmp,
            "binary noise": self.log(""),
        }
        cases["binary noise"].write_bytes(bytes(range(256)) * 64)
        for what, path in cases.items():
            with self.subTest(what=what):
                result = self.explain(str(path), GITHUB_ACTIONS="true")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, "", ""))

    def test_a_5_mb_log_answers_in_under_2_s(self) -> None:
        noise = ("   Compiling serde v1.0.0 (registry+https://github.com/rust-lang/crates.io-index)\n"
                 "warning: the lock file is fine, but --locked was passed and this is not cargo's sentence\n")
        long_line = ("the lock file " * 80000) + "--locked was passed\n"
        body = noise * (5_000_000 // len(noise)) + long_line
        for refusal in ("", SPELLINGS["update"].format(lock=ROOT / "Cargo.lock") + "\n"):
            with self.subTest(refusal=bool(refusal)):
                log = self.log(body + refusal, "big.log")
                self.assertGreater(log.stat().st_size, 5_000_000)
                started = time.monotonic()
                result = self.explain(str(log))
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0 if refusal else 1)
                self.assertLess(elapsed, 2.0)


class PythonAndShellSiteTests(Scratch):
    """Sites 1 to 5, each with a fake cargo: a refusal and an ordinary failure."""

    def run_site(self, argv: list[str], cwd: Path, stdin: str = "", **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(argv, cwd=cwd, input=stdin, text=True, capture_output=True, env=self.env(**env),
                              timeout=120)

    # Site 1: cargo metadata's stderr was captured and never printed (a CalledProcessError traceback).
    def test_app_crate_licenses(self) -> None:
        argv = [sys.executable, "-I", str(ROOT / "scripts/cmux-next/check_app_crate_licenses.py"),
                "--manifest", "cmux-tui/crates/cmux-app-ffi/Cargo.toml", "--root", "cmux-app-ffi"]
        stale = self.run_site(argv, self.tmp, FAKE_CARGO="update", FAKE_LOCK=str(ROOT / "cmux-tui/Cargo.lock"))
        self.assertEqual(stale.returncode, 1, stale.stderr)
        self.assert_stale_block(stale.stderr, "cmux-tui/Cargo.lock")
        self.assertNotIn("CalledProcessError", stale.stderr)
        broken = self.run_site(argv, self.tmp, FAKE_CARGO="broken")
        self.assertEqual(broken.returncode, 1)
        self.assertIn("CalledProcessError", broken.stderr)
        self.assertNotIn("stale Cargo.lock", broken.stderr)

    # Site 2: "FAST-TIER FAIL build:crate: the tests do not build".
    def test_fast_tier(self) -> None:
        root = self.tmp / "root"
        (root / "crate").mkdir(parents=True)
        registry = self.tmp / "registry.json"
        registry.write_text(json.dumps({"entries": [
            {"name": "core hit", "kind": "cargo", "path": "crate", "package": "core", "owner": "op-test"}]}))
        quarantine = self.tmp / "quarantine.json"
        quarantine.write_text('{"entries": []}')
        argv = [sys.executable, "-I", str(ROOT / "scripts/cmux-next/fast-tier.py"), "--root", str(root),
                "--registry", str(registry), "--quarantine", str(quarantine), "--kind", "cargo"]
        for spelling in SPELLINGS:
            with self.subTest(spelling=spelling):
                stale = self.run_site(argv, self.tmp, FAKE_CARGO=spelling)
                out = stale.stdout + stale.stderr
                self.assertEqual(stale.returncode, 1, out)
                self.assert_stale_block(out, "crate/Cargo.lock")
                self.assertIn("FAST-TIER FAIL build:crate: a stale Cargo.lock", out)
                self.assertNotIn("the tests do not build", out)
        broken = self.run_site(argv, self.tmp, FAKE_CARGO="broken")
        out = broken.stdout + broken.stderr
        self.assertEqual(broken.returncode, 1)
        self.assertIn("FAST-TIER FAIL build:crate: the tests do not build", out)
        self.assertNotIn("stale Cargo.lock", out)

    # Site 3: "left: cargo clippy --fix could not build a (see the job log)".
    def test_autofix_clippy(self) -> None:
        repo = self.tmp / "repo"
        (repo / "cmux-tui/crates/a/src").mkdir(parents=True)
        (repo / "cmux-tui/crates/a/src/lib.rs").write_text("")
        self.git(self.tmp, "init", "-q", str(repo))
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-qm", "base")
        metadata = self.tmp / "metadata.json"
        metadata.write_text(json.dumps({"workspace_members": ["a 0.1.0"], "packages": [
            {"id": "a 0.1.0", "name": "a", "manifest_path": str(repo / "cmux-tui/crates/a/Cargo.toml")}]}))
        argv = ["bash", str(ROOT / "scripts/cmux-next/autofix-clippy.sh"), str(repo)]
        changed = "cmux-tui/crates/a/src/lib.rs\n"
        # cargo clippy --fix refuses; cargo metadata answers.
        clippy_only = {"FAKE_METADATA": str(metadata), "FAKE_CARGO_ONLY": "clippy"}
        stale = self.run_site(argv, self.tmp, changed, FAKE_CARGO="update", **clippy_only)
        self.assertEqual(stale.returncode, 0, stale.stderr)
        self.assert_stale_block(stale.stderr, "cmux-tui/Cargo.lock")
        self.assertIn("left: cargo clippy --fix did not run on a (a stale Cargo.lock", stale.stdout)
        self.assertNotIn("could not build", stale.stdout)
        broken = self.run_site(argv, self.tmp, changed, FAKE_CARGO="broken", **clippy_only)
        self.assertEqual(broken.returncode, 0)
        self.assertIn("left: cargo clippy --fix could not build a (see the job log)", broken.stdout)
        self.assertNotIn("stale Cargo.lock", broken.stdout + broken.stderr)
        # cargo metadata, the script's first cargo, refuses too: named, and still a failure.
        meta = self.run_site(argv, self.tmp, changed, FAKE_CARGO="needs", FAKE_METADATA=str(metadata))
        self.assertEqual(meta.returncode, 1)
        self.assert_stale_block(meta.stderr, "cmux-tui/Cargo.lock")
        meta_broken = self.run_site(argv, self.tmp, changed, FAKE_CARGO="broken", FAKE_METADATA=str(metadata))
        self.assertEqual(meta_broken.returncode, 1)
        self.assertNotIn("stale Cargo.lock", meta_broken.stdout + meta_broken.stderr)

    def origin_repo(self, files: dict[str, str], head_files: dict[str, str]) -> tuple[Path, str, str]:
        """A repository that is its own origin, with a base commit and a head commit above it."""
        repo = self.tmp / "repo"
        repo.mkdir()
        self.git(self.tmp, "init", "-q", "-b", "main", str(repo))
        for commit in (files, head_files):
            for relative, text in commit.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            self.git(repo, "add", "-A")
            self.git(repo, "commit", "-qm", "commit")
        head = self.git(repo, "rev-parse", "HEAD")
        base = self.git(repo, "rev-parse", "HEAD^")
        self.git(repo, "branch", "base", base)
        self.git(repo, "remote", "add", "origin", str(repo))
        return repo, base, head

    # Site 4: a lock refusal read as `base-build-failed`, or as a row of empty outcomes.
    def test_ci_apply_rust_both_ways(self) -> None:
        affected = "import sys\nprint('-p a')\n"
        repo, base, head = self.origin_repo(
            {"scripts/ci/cargo_affected.py": affected, "cmux-tui/crates/a/src/lib.rs": ""},
            {"cmux-tui/crates/a/src/lib.rs": "// head\n"})
        argv = ["bash", str(ROOT / "scripts/cmux-next/ci-apply-rust-both-ways.sh"), f"{base}:{head}"]

        def rows(result: subprocess.CompletedProcess[str], out: Path) -> list[list[str]]:
            self.assertTrue((out / "results.tsv").is_file(), result.stderr)
            return [line.split("\t") for line in (out / "results.tsv").read_text().splitlines()[1:]]

        out = self.tmp / "out-stale"
        stale = self.run_site(argv, repo, FAKE_CARGO="update", FAST_CHECKS_OUT=str(out), RUNNER_TEMP=str(self.tmp))
        self.assertEqual(stale.returncode, 1, stale.stderr)
        self.assertEqual(rows(stale, out), [[base, head, "-p a", "stale-lock"]])
        self.assertIn("stale Cargo.lock: cmux-tui/Cargo.lock does not match", stale.stderr)
        self.assertNotIn("base-build-failed", (out / "results.tsv").read_text())

        out = self.tmp / "out-broken"
        broken = self.run_site(argv, repo, FAKE_CARGO="broken", FAST_CHECKS_OUT=str(out), RUNNER_TEMP=str(self.tmp))
        self.assertEqual(broken.returncode, 1)
        self.assertEqual(rows(broken, out), [[base, head, "-p a", "base-build-failed"]])
        self.assertNotIn("stale Cargo.lock", broken.stderr)

    def test_ci_apply_rust_both_ways_a_stale_head_lock(self) -> None:
        repo, base, head = self.origin_repo(
            {"scripts/ci/cargo_affected.py": "print('-p a')\n", "cmux-tui/crates/a/src/lib.rs": ""},
            {"cmux-tui/STALE": ""})
        out = self.tmp / "out"
        result = self.run_site(["bash", str(ROOT / "scripts/cmux-next/ci-apply-rust-both-ways.sh"), f"{base}:{head}"],
                               repo, FAKE_CARGO="needs", FAKE_CARGO_IF_FILE="STALE", FAST_CHECKS_OUT=str(out),
                               RUNNER_TEMP=str(self.tmp))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in (out / "results.tsv").read_text().splitlines()[1:]]
        self.assertEqual(rows, [[base, head, "-p a", "stale-lock"]])
        self.assertIn("stale Cargo.lock: cmux-tui/Cargo.lock does not match", result.stderr)

    # Site 5: a lock refusal read as `"tests": 0`.
    def test_affected_tests_measure(self) -> None:
        for name in ("cargo-nextest", "fish"):
            self.fake(name, "#!/bin/sh\nexit 0\n")
        files = {
            "scripts/ci/cargo_affected.py": "print('-p a')\n",
            "scripts/ci/init-submodule.sh": "exit 0\n",
            "scripts/ci/run_python_test_lane.py": "",
            "scripts/cmux-next/cargo-locks.py": SCRIPT.read_text(),
            "cmux-tui/crates/a/src/lib.rs": "",
        }
        for mode, want in (("update", "stale-lock"), ("broken", None)):
            with self.subTest(mode=mode):
                shutil.rmtree(self.tmp / "repo", ignore_errors=True)
                repo, _, head = self.origin_repo(files, {"cmux-tui/crates/a/src/lib.rs": "// head\n"})
                out = self.tmp / f"out-{mode}"
                result = self.run_site(["bash", str(ROOT / "scripts/ci/affected_tests_measure.sh"), head], repo,
                                       FAKE_CARGO=mode, FAST_CHECKS_OUT=str(out))
                self.assertEqual(result.returncode, 0, result.stderr)
                runs = {run["label"]: run for run in json.loads((out / "measure.json").read_text())["runs"]}
                for label in ("rust-full", "rust-affected"):
                    self.assertEqual(runs[label]["rc"], 101)
                    self.assertEqual(runs[label].get("outcome"), want)
                    self.assertEqual(runs[label]["tests"], None if want else 0)
                if want:
                    self.assert_stale_block(result.stderr, "cmux-tui/Cargo.lock")
                else:
                    self.assertNotIn("stale Cargo.lock", result.stderr)


# Sites 6 to 9: (workflow, a text of the step's own failure line).
WORKFLOW_SITES = {
    ".github/workflows/cmux-next-base-autofix.yml": "fails cmux-config's tests (the daemon would not start)",
    ".github/workflows/cmux-tui-spec.yml": "::error title=acpmux protocol tests::a protocol test failed",
    ".github/workflows/cmux-tui-windows-check.yml": "::error title=Windows build broken::",
    ".github/workflows/cmux-tui-artifacts.yml": "retrying Cargo registry and build fetches",
}


def steps(path: Path) -> list[tuple[str, dict]]:
    """(job, step) for every step of a workflow or composite action."""
    data = yaml.safe_load(path.read_text()) or {}
    found = [(job, step) for job, body in (data.get("jobs") or {}).items() if isinstance(body, dict)
             for step in (body.get("steps") or []) if isinstance(step, dict)]
    runs = data.get("runs") if isinstance(data.get("runs"), dict) else {}
    return found + [("action", step) for step in (runs.get("steps") or []) if isinstance(step, dict)]


class WorkflowSiteTests(unittest.TestCase):
    def test_each_step_asks_explain_before_its_own_cause(self) -> None:
        for workflow, old in WORKFLOW_SITES.items():
            with self.subTest(workflow=workflow):
                matching = [step["run"] for _, step in steps(ROOT / workflow) if old in (step.get("run") or "")]
                self.assertEqual(len(matching), 1, f"{workflow}: the step that prints {old!r}")
                run = matching[0]
                explain = re.search(r"python3 (\.\./)?scripts/cmux-next/cargo-locks\.py explain ", run)
                self.assertIsNotNone(explain, f"{workflow}: the step does not call cargo-locks.py explain")
                self.assertLess(explain.start(), run.index(old), f"{workflow}: explain runs after the old cause")
                prefix = "../" if explain.group(1) else ""
                directory = next(step.get("working-directory", ".") for _, step in steps(ROOT / workflow)
                                 if step.get("run") == run)
                self.assertEqual(prefix, "../" if directory == "cmux-tui" else "",
                                 f"{workflow}: the explain path is wrong for working-directory {directory}")

    def test_the_daemon_tests_never_retry_a_stale_lock(self) -> None:
        run = next(step["run"] for _, step in steps(ROOT / ".github/workflows/cmux-tui-artifacts.yml")
                   if "retrying Cargo registry" in (step.get("run") or ""))
        loop = run[run.index("for attempt in 1 2 3"):run.index("retrying Cargo registry")]
        self.assertRegex(loop, r"cargo-locks\.py explain [^\n]*; then\n\s*exit \"\$status\"")


# The list. A file (a workflow: a step, `path#job/step name`) under scripts/ or .github/ that runs cargo with
# --locked and prints ::error, FAIL or left: must be in one of these two tables.
EXPLAINED = {
    "scripts/cmux-next/check_app_crate_licenses.py": "cargo metadata's refusal goes to explain",
    "scripts/cmux-next/fast-tier.py": "a build's refusal goes to explain, then FAST-TIER FAIL names the stale lock",
    "scripts/cmux-next/autofix-clippy.sh": "cargo metadata's and clippy --fix's refusals go to explain",
    "scripts/cmux-next/ci-apply-rust-both-ways.sh": "a refused build is a stale-lock row",
    "scripts/ci/affected_tests_measure.sh": "a refused nextest run is outcome stale-lock",
    ".github/workflows/cmux-next-base-autofix.yml#autofix/The daemon parses the regenerated settings schema":
        "explain before the schema ::error",
    ".github/workflows/cmux-tui-spec.yml#acpmux-protocol-ir/cargo test -p acpmux --lib -- protocol::":
        "explain before the protocol test ::error",
    ".github/workflows/cmux-tui-windows-check.yml#windows-gnu-check/cargo check cmux-tui-core, cmux-tui and acpmux "
    "for Windows": "explain before Windows build broken",
    ".github/workflows/cmux-tui-artifacts.yml#cmux-next-daemon-tests/cargo test cmux_next_":
        "explain stops the retry loop",
    # cmux#42257: their own match of the same three spellings.
    ".github/scripts/cmux-tui-clippy-changed.py": "cmux#42257",
    "scripts/cmux-next/rust_panic_ratchet.py": "cmux#42257",
}
# Each reason says where the reader sees cargo's own error, or why the printed cause is not about cargo.
PASSES_THROUGH = {
    "scripts/cmux-next/cargo-locks.py": "the explainer; its left: lines are its own fix's",
    "scripts/cmux-next/prepush-gate.py": "runs cargo-locks.py check; its ::error lines are other guards'",
    "scripts/cmux-next/cloud-devloop.ts": "FAIL build prints cargo's error lines and tail",
    "scripts/ci/car_guards.py": "a red result prints cargo's output tail",
    "scripts/ci/chief-first-turn-cost.sh": "set -e stops at the cargo build, its stderr in the log",
    "scripts/ci/cmux-tui-focused-test.sh": "set -e stops at cargo; the ::error lines judge a listing",
    "scripts/ci/cmux-tui-rust-check.sh": "step() streams cargo; FAIL rows give its exit code",
    "scripts/ci/feat-parity-check.sh": "step() streams cargo; FAIL rows give its exit code",
    "scripts/ci/macos-cross.sh": "set -e stops at cargo; FAIL lines compare built outputs",
    "scripts/ci/tests/feat-parity-check.test.sh": "a test of feat-parity-check.sh; FAIL is its own",
    "scripts/cmux-next/tests/fast-tier.test.sh": "a test of fast-tier.py; FAIL is its own",
    "scripts/measure/acpmux-overhead.sh": "set -e stops at cargo fetch --locked, its stderr in the log",
    "scripts/measure/new-terminal-100x.sh": "set -e stops at the cargo build, its stderr in the log",
    "scripts/measure/rust-dev-loop.py": "cargo fetch --locked prints first; DEVLOOP-FAIL names the build log",
    ".github/workflows/cmux-browser-host-chromium.yml#chromium/Run the ignored real-Chromium tests":
        "set -e stops at cargo; ::error judges its output",
    ".github/workflows/cmux-mobile-ffi.yml#apple/Build static libraries":
        "set -e stops at cargo; ::error judges the library",
    ".github/workflows/cmux-tui-spec.yml#clippy/Cloud host identity tests":
        "bash -e and pipefail stop at cargo; ::error judges its output",
    ".github/workflows/cmux-tui-testbox-warmup.yml#cmux-tui-rust/Record runner, toolchain, and Ghostty identity":
        "set -e stops at cargo metadata; ::error is about the runner",
    ".github/workflows/cmux-tui.yml#cdp-browser-smoke/Run configured Chrome CDP smoke":
        "set -e stops at cargo; ::error judges its listing",
    ".github/workflows/cmux-tui.yml#cdp-browser-smoke/Run browser host Chromium driver test":
        "set -e stops at cargo; ::error judges its listing",
}

RUNS_CARGO_LOCKED = re.compile(r"(?<![\w./-])cargo\b(?![-_.\w]).*--locked\b|[\"']cargo[\"'].*[\"']--locked[\"']")
PRINTS_A_CAUSE = re.compile(r"::error|\bFAIL\b|\bleft:")
SKIP_SUFFIXES = {".md", ".json", ".lock", ".toml", ".txt", ".png", ".jpg", ".svg"}


def wraps_cargo(text: str) -> bool:
    """TEXT runs cargo with --locked and prints a cause of its own (comments and continuations aside)."""
    joined = re.sub(r"\\\n\s*", " ", text)
    code = [line for line in joined.splitlines() if not line.lstrip().startswith(("#", "//"))]
    return any(RUNS_CARGO_LOCKED.search(line) for line in code) and any(PRINTS_A_CAUSE.search(line) for line in code)


def wrappers() -> set[str]:
    listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "scripts", ".github"],
                            capture_output=True, text=True, check=True).stdout.split("\0")
    found = set()
    for relative in filter(None, listed):
        path = ROOT / relative
        if path.suffix in SKIP_SUFFIXES or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        workflow = path.suffix in (".yml", ".yaml") and relative.startswith((".github/workflows/", ".github/actions/"))
        if workflow:
            found |= {f"{relative}#{job}/{step.get('name')}" for job, step in steps(path)
                      if wraps_cargo(step.get("run") or "")}
        elif wraps_cargo(text):
            found.add(relative)
    return found


class EveryWrapperIsListedTests(unittest.TestCase):
    def test_every_cargo_locked_wrapper_explains_or_passes_cargo_through(self) -> None:
        found = wrappers()
        unlisted = sorted(found - set(EXPLAINED) - set(PASSES_THROUGH))
        self.assertEqual(unlisted, [], "these run cargo --locked and print a cause of their own: on failure, hand "
                         "cargo's output to scripts/cmux-next/cargo-locks.py explain and list them in EXPLAINED, or, "
                         "when cargo's own error reaches the log first, add them to PASSES_THROUGH with the reason")
        gone = sorted(set(PASSES_THROUGH) - found)
        self.assertEqual(gone, [], "no longer a cargo --locked wrapper: remove it from PASSES_THROUGH")
        self.assertFalse(set(EXPLAINED) & set(PASSES_THROUGH))
        self.assertTrue(all(len(reason) <= 80 for reason in PASSES_THROUGH.values()), "one short line each")

    def test_every_explained_site_asks_explain(self) -> None:
        for site in EXPLAINED:
            if EXPLAINED[site] == "cmux#42257":
                continue
            with self.subTest(site=site):
                path, _, step = site.partition("#")
                if step:
                    run = [s.get("run") or "" for job, s in steps(ROOT / path) if f"{job}/{s.get('name')}" == step]
                    self.assertEqual(len(run), 1, f"{site}: no such step")
                    text = run[0]
                else:
                    text = (ROOT / path).read_text()
                self.assertRegex(text, r"cargo-locks\.py[\"']?[ ,)]*[\"']?explain|\"explain\"")

    def test_the_detector_sees_a_new_wrapper(self) -> None:
        self.assertTrue(wraps_cargo('cargo test --locked -p a || { echo "::error::tests failed"; exit 1; }'))
        self.assertTrue(wraps_cargo('cargo build \\\n  --locked\necho "FAIL build"'))
        self.assertFalse(wraps_cargo('# cargo test --locked\necho "::error::x"'))
        self.assertFalse(wraps_cargo('cargo test --locked'))


if __name__ == "__main__":
    unittest.main()
