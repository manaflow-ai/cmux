#!/usr/bin/env python3
"""scripts/ci/cargo_test_retry.py runs a red test once; only a fetch fault runs it again.

Against a fake cargo that counts its runs: an assertion failure runs once and keeps cargo's exit code; a fetch
fault runs again up to --attempts and passes when a later run does, or fails after the last; a run that passed no
test (--require-tests) and a stale Cargo.lock end at once; a test whose own output names a network error is a test
failure, not a fetch fault. And scripts/ci/check_test_retry_loops.py: it finds an inline retry loop around a test
command, passes the shared script, a loop over packages, a message that names a test command and a `test-repeat:`
loop, and finds nothing in this checkout.

No cargo is needed. Run: python3 tests/test_ci_cargo_test_retry.py (a few seconds).
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cargo_test_retry.py"
_spec = importlib.util.spec_from_file_location("check_test_retry_loops", ROOT / "scripts/ci/check_test_retry_loops.py")
loops = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(loops)

# FAKE_PLAN: one mode per run, the last repeated (ok, none, assert, fetch, lock, netassert). Each run appends a line
# to FAKE_COUNT.
FAKE_CARGO = r"""#!/usr/bin/env bash
echo run >> "$FAKE_COUNT"
n=$(wc -l < "$FAKE_COUNT" | tr -d ' ')
IFS=, read -r -a plan <<<"$FAKE_PLAN"
i=$(( n - 1 )); (( i < ${#plan[@]} )) || i=$(( ${#plan[@]} - 1 ))
case "${plan[$i]}" in
  ok) printf 'running 2 tests\ntest a ... ok\ntest b ... ok\n\ntest result: ok. 2 passed; 0 failed\n'; exit 0 ;;
  none) printf 'running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 5 filtered out\n'; exit 0 ;;
  assert) printf 'running 1 test\ntest a ... FAILED\n\nthread a panicked at src/lib.rs:3:5:\nassertion `left == right` failed\n\ntest result: FAILED. 0 passed; 1 failed\n'
          echo "error: test failed, to rerun pass '--lib'" >&2; exit 101 ;;
  netassert) printf 'running 1 test\ntest a ... FAILED\nConnection refused (os error 111)\n\ntest result: FAILED. 0 passed; 1 failed\n'; exit 101 ;;
  fetch) printf '    Updating crates.io index\nwarning: spurious network error (3 tries remaining): [6] Could not resolve host: index.crates.io\nerror: failed to download from `https://static.crates.io/crates/x/x-1.0.0.crate`\n' >&2; exit 101 ;;
  lock) echo "error: the lock file $PWD/Cargo.lock needs to be updated but --locked was passed to prevent this" >&2; exit 101 ;;
esac
"""


class RetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="cargo-test-retry-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        cargo = bin_dir / "cargo"
        cargo.write_text(FAKE_CARGO)
        cargo.chmod(0o755)
        self.count = self.tmp / "count"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "FAKE_"))}
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", FAKE_COUNT=str(self.count))

    def run_script(self, plan: str, *extra: str) -> tuple[int, str, int]:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--log", str(self.tmp / "out/log.txt"), "--backoff", "0", *extra,
             "--", "cargo", "test", "--locked", "cmux_next_"],
            env={**self.env, "FAKE_PLAN": plan}, cwd=self.tmp, capture_output=True, text=True, timeout=60)
        runs = len(self.count.read_text().splitlines()) if self.count.exists() else 0
        return result.returncode, result.stdout + result.stderr, runs

    def test_a_pass_runs_once(self) -> None:
        code, out, runs = self.run_script("ok", "--require-tests")
        self.assertEqual((code, runs), (0, 1), out)
        self.assertIn("test result: ok. 2 passed", (self.tmp / "out/log.txt").read_text())

    def test_an_assertion_failure_runs_once(self) -> None:
        code, out, runs = self.run_script("assert,ok")
        self.assertEqual((code, runs), (101, 1), out)
        self.assertIn("a test failure is not run again", out)
        self.assertIn("assertion `left == right` failed", out)

    def test_a_test_naming_a_network_error_is_a_test_failure(self) -> None:
        code, out, runs = self.run_script("netassert,ok")
        self.assertEqual((code, runs), (101, 1), out)

    def test_a_fetch_fault_runs_again_and_passes(self) -> None:
        code, out, runs = self.run_script("fetch,fetch,ok", "--require-tests")
        self.assertEqual((code, runs), (0, 3), out)
        self.assertIn("a fetch fault failed attempt 1/3; running again", out)

    def test_a_fetch_fault_fails_after_the_last_attempt(self) -> None:
        code, out, runs = self.run_script("fetch", "--attempts", "3")
        self.assertEqual((code, runs), (101, 3), out)
        self.assertIn("a fetch fault failed all 3 attempts", out)

    def test_a_fetch_fault_then_an_assertion_stops_there(self) -> None:
        code, out, runs = self.run_script("fetch,assert,ok")
        self.assertEqual((code, runs), (101, 2), out)

    def test_zero_tests_is_red_at_once(self) -> None:
        code, out, runs = self.run_script("none,ok", "--require-tests")
        self.assertEqual((code, runs), (1, 1), out)
        self.assertIn("the run passed no test (the filter matched nothing)", out)

    def test_zero_tests_passes_without_require_tests(self) -> None:
        self.assertEqual(self.run_script("none")[:1], (0,))

    def test_a_stale_lock_is_named_and_never_run_again(self) -> None:
        code, out, runs = self.run_script("lock,ok")
        self.assertEqual((code, runs), (101, 1), out)
        self.assertIn("Cargo.lock does not match its manifests on this ref", out)
        self.assertNotIn("a test failure is not run again", out)

    def test_github_annotations_on_actions(self) -> None:
        self.env["GITHUB_ACTIONS"] = "true"
        code, out, _ = self.run_script("assert")
        self.assertIn("::error::the tests failed (exit 101); a test failure is not run again", out)


class DetectorTests(unittest.TestCase):
    def test_finds_an_inline_retry_loop(self) -> None:
        for text in (
            'for attempt in 1 2 3; do\n  cargo test --locked && break\n  sleep 10\ndone\n',
            'for i in $(seq 1 3); do\n  swift test && exit 0\ndone\n',
            'until bun test; do\n  sleep 1\ndone\n',
            'while (( tries < 3 )); do\n  (cd x && xcodebuild test -scheme A) && break\n  tries=$((tries + 1))\ndone\n',
            'while :; do\n  if cargo nextest run; then break; fi\ndone\n',
            'for attempt in {1..3}; do\n  python3 -m pytest tests/ \\\n    -q && break\ndone\n',
        ):
            with self.subTest(text=text):
                self.assertEqual(len(loops.retry_loops(text)), 1)

    def test_passes_what_is_not_a_retry(self) -> None:
        for text in (
            'for attempt in 1 2 3; do\n  curl -fsS https://x && break\ndone\n',
            'for pkg in a b c; do\n  cargo test -p "$pkg"\ndone\n',
            'while IFS= read -r pkg; do\n  swift test --package-path "$pkg"\ndone < list\n',
            'while :; do\n  echo "::error::cargo test still running"\n  sleep 5\ndone\n',
            '# test-repeat: three benchmark runs\nfor run in 1 2 3; do\n  xcodebuild test -scheme B || break\ndone\n',
            'for attempt in 1 2 3; do\n  # cargo test in a comment\n  sleep 1\ndone\n',
            'python3 scripts/ci/cargo_test_retry.py --log x -- cargo test --locked\n',
        ):
            with self.subTest(text=text):
                self.assertEqual(loops.retry_loops(text), [])

    def test_this_checkout_has_none(self) -> None:
        self.assertEqual(loops.findings(ROOT), [], "run the test command once through scripts/ci/cargo_test_retry.py")


if __name__ == "__main__":
    unittest.main()
