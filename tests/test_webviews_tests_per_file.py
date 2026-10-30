#!/usr/bin/env python3
"""scripts/ci/run-webviews-tests.sh runs each webviews test file in its own bun process.

A full `bun test` in webviews stalled in a different file each run (ui-menu,
markdown-viewer-shell, chips/linkChips) until the job timeout, and each stalled
file passes alone. Per-file processes with a wall-clock timeout name the stuck
file and fail the step instead of hanging the job. A fake `bun` stands in for
the real one, so no web test runs here.
"""

import os
import json
import hashlib
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-webviews-tests.sh"
SHARDS = ROOT / "scripts" / "ci" / "webviews_test_shards.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci-web.yml"

FAKE_BUN = """#!/usr/bin/env bash
[ "$1" = test ] || exit 9
# The test file is the last argument: the runner passes options such as --timeout before it.
file="${!#}"
printf '%s\\n' "$file" >> "$BUN_CALLS"
# A file that starts a Vite dev server optimizes dependencies into its Vite cache while it runs: two
# at once on one cache lose each other's files, and a cold cache is the slow first bundle.
if grep -q -e '"dev",' -e 'createServer(' -e 'vite.config.gallery-dev.ts' -e 'vite.config.acpmux-pane.mjs' "$file"; then
  config=default
  grep -q 'vite.config.settings-page.mjs' "$file" && config=settings
  grep -q 'vite.config.gallery-dev.ts' "$file" && config=gallery
  grep -q 'vite.config.acpmux-pane.mjs' "$file" && config=pane
  cache="${CMUX_VITE_CACHE_DIR:-$SHARED_VITE_CACHE}"
  warm=cold
  [ -e "$cache/warm-$config" ] && warm=warm
  printf '%s %s %s\\n' "$file" "$cache" "$warm" >> "$BUN_DEV"
  mkdir "$DEV_RUNNING/$$"
  ls "$DEV_RUNNING" | wc -l >> "$BUN_PEAK"
  if mkdir "$cache.lock" 2> /dev/null; then
    sleep 0.5
    mkdir -p "$cache"
    touch "$cache/warm-$config"
    rmdir "$cache.lock"
  else
    printf 'overlap %s\\n' "$file" >> "$BUN_OVERLAPS"
  fi
  rmdir "$DEV_RUNNING/$$"
fi
case "$file" in
  *pool-*)
    # Counts the files running at once, and the browser files among them.
    mkdir "$POOL_RUNNING/all-$$"
    ls "$POOL_RUNNING" | grep -c '^all-' >> "$POOL_PEAK"
    if grep -qE 'from "playwright"|requireBrowserLane\\(' "$file"; then
      mkdir "$POOL_RUNNING/browser-$$"
      ls "$POOL_RUNNING" | grep -c '^browser-' >> "$BROWSER_PEAK"
      sleep 0.4
      rmdir "$POOL_RUNNING/browser-$$"
    else
      sleep 0.4
    fi
    rmdir "$POOL_RUNNING/all-$$"
    echo "(pass) $file"; exit 0 ;;
  *contended*)
    # Times out beside the others on its first run and passes alone, as composer-footer-plain did.
    stamp="$BUN_CALLS.$(basename "$file")"
    if [ ! -f "$stamp" ]; then touch "$stamp"; sleep 60; fi
    echo "(pass) $file alone"; exit 0 ;;
  *retry-hang*)
    if [ -f "$BUN_CALLS.retry" ]; then sleep 60; fi
    touch "$BUN_CALLS.retry"
    echo "(fail) first attempt assertion"; exit 1 ;;
  *notice-flood*)
    printf '::notice title=browser-flood::%*s\n' 350000 ''
    exit 0 ;;
  *flood*)
    # One very long line models a browser diagnostic burst; the assertion at the end must still
    # survive the runner's bounded public display and the retry's raw artifact copy.
    printf '%*s' 2000000 '' | tr ' ' F
    printf '\n(fail) inspector-dead-clicks sentinel\n'
    exit 1 ;;
  *timed-out-once*|*timed-out-then-fail*|*timed-out-slow-retry*)
    # A timeout without the wait: exit 124 is what the runner's per-file limit reports.
    stamp="$BUN_CALLS.$(basename "$file")"
    if [ ! -f "$stamp" ]; then touch "$stamp"; echo "killed beside the others"; exit 124; fi
    case "$file" in
      *then-fail*) echo "(fail) still broken alone"; exit 1 ;;
      # Passes alone just inside its limit; the runner's own upkeep then runs past it.
      *slow-retry*) sleep 1.9 ;;
    esac
    echo "(pass) $file alone"; exit 0 ;;
  *fail-slow*) sleep 1; echo "(fail) a slow broken test"; exit 1 ;;
  *hang*) sleep 60 ;;
  *slow*) sleep 3; echo "(pass) $file" ;;
  *fail*) echo "(fail) a broken test"; exit 1 ;;
  *) echo "(pass) $file" ;;
esac
"""


def path_without_timeout(temp):
    """A PATH with the tools the runner needs and no `timeout`/`gtimeout`, as on a stock Mac.

    The fleet Macs (cmux-lawrence-2, nx-remote jobs) have no coreutils `timeout`, so the
    runner must keep its per-file limit without it.
    """
    farm = temp / "system-bin"
    farm.mkdir()
    for name in ("bash", "git", "xargs", "tr", "wc", "sort", "cat", "mktemp", "rm", "getconf",
                 "sleep", "perl", "dirname", "env", "grep", "mkdir", "rmdir", "basename"):
        found = shutil.which(name)
        if found:
            (farm / name).symlink_to(found)
    return str(farm)


class PerFileRunner(unittest.TestCase):
    def run_runner(self, files, without_timeout=False, contents=None, shard=None, shard_count=None, extra_env=None, args=()):
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        web = temp / "webviews"
        for name in files:
            path = web / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text((contents or {}).get(name, ""), encoding="utf-8")
        (web / "src" / "helper.ts").parent.mkdir(parents=True, exist_ok=True)
        (web / "src" / "helper.ts").write_text("", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(temp)], check=True)
        subprocess.run(["git", "-C", str(temp), "add", "-A"], check=True)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        (bin_dir / "bun").write_text(FAKE_BUN, encoding="utf-8")
        (bin_dir / "bun").chmod(0o755)
        calls = temp / "calls"
        self.calls_file = calls
        calls.write_text("", encoding="utf-8")
        self.overlaps = temp / "overlaps"
        self.overlaps.write_text("", encoding="utf-8")
        self.dev, self.peak, running = temp / "dev", temp / "peak", temp / "running"
        self.dev.write_text("", encoding="utf-8")
        self.peak.write_text("", encoding="utf-8")
        running.mkdir()
        self.pool_peak, self.browser_peak, pool_running = temp / "pool-peak", temp / "browser-peak", temp / "pool-running"
        self.pool_peak.write_text("", encoding="utf-8")
        self.browser_peak.write_text("", encoding="utf-8")
        pool_running.mkdir()
        (web / "node_modules").mkdir(exist_ok=True)
        if getattr(self, "web_hook", None):
            self.web_hook(web)
        self.shared_cache = web / "node_modules" / ".vite"
        system_path = path_without_timeout(temp) if without_timeout else os.environ["PATH"]
        base_env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
        env = {**base_env, "PATH": f"{bin_dir}:{system_path}", "BUN_CALLS": str(calls),
               "BUN_OVERLAPS": str(self.overlaps), "SHARED_VITE_CACHE": str(web / "node_modules" / ".vite"),
               "BUN_DEV": str(self.dev), "BUN_PEAK": str(self.peak), "DEV_RUNNING": str(running),
               "POOL_PEAK": str(self.pool_peak), "BROWSER_PEAK": str(self.browser_peak),
               "POOL_RUNNING": str(pool_running),
               "CMUX_WEB_TEST_FILE_TIMEOUT": "2", "CMUX_WEB_TEST_JOBS": "8",
               # These tests read each file's first run; scripts/ci/tests/run-webviews-tests-retry.test.sh
               # covers the rerun of a failed file.
               "CMUX_WEB_TEST_RETRIES": "0"}
        if shard is not None:
            env["CMUX_WEB_TEST_SHARD"] = str(shard)
            env["CMUX_WEB_TEST_SHARD_COUNT"] = str(shard_count)
        env.update(extra_env or {})
        started = time.monotonic()
        result = subprocess.run(["bash", str(RUNNER), *args], cwd=web, env=env, capture_output=True, text=True, timeout=40)
        return result, time.monotonic() - started, sorted(calls.read_text(encoding="utf-8").split())

    def test_a_stuck_file_is_named_and_fails_without_hanging(self):
        files = ["test/a.test.ts", "test/hang.test.tsx", "src/pages/fail.test.ts", "src/b.test.tsx"]
        result, elapsed, calls = self.run_runner(files)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(elapsed, 20, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        self.assertRegex(output, r"TIMEOUT[^\n]*test/hang\.test\.tsx")
        self.assertRegex(output, r"FAIL[^\n]*src/pages/fail\.test\.ts")
        self.assertNotRegex(output, r"(FAIL|TIMEOUT)[^\n]*test/a\.test\.ts")
        self.assertIn("(fail) a broken test", output)

    def test_a_host_without_timeout_still_runs_and_limits_each_file(self):
        files = ["test/a.test.ts", "test/hang.test.tsx", "src/b.test.tsx"]
        result, elapsed, calls = self.run_runner(files, without_timeout=True)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(elapsed, 20, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        self.assertRegex(output, r"TIMEOUT[^\n]*test/hang\.test\.tsx")
        self.assertNotRegex(output, r"(FAIL|TIMEOUT)[^\n]*test/a\.test\.ts")
        self.assertNotRegex(output, r"(FAIL|TIMEOUT)[^\n]*src/b\.test\.tsx")

    def test_a_declared_long_file_cannot_exceed_the_runner_hard_limit(self):
        result, elapsed, calls = self.run_runner(
            ["test/slow.test.ts"],
            contents={"test/slow.test.ts": "// cmux-web-test-timeout: 3000\n"},
            extra_env={"CMUX_WEB_TEST_MAX_FILE_TIMEOUT": "1"},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(elapsed, 3, output)
        self.assertIn("TIMEOUT test/slow.test.ts", output)
        self.assertEqual(calls, ["./test/slow.test.ts"])

    def test_a_timeout_on_its_retry_stays_a_timeout(self):
        """A file that times out again alone is a TIMEOUT: never a pass, never a named failure."""
        results_path = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "results.json"
        result, _, calls = self.run_runner(
            ["test/hang.test.ts"],
            extra_env={"CMUX_WEB_TEST_RETRIES": "1", "CMUX_WEB_TEST_RESULTS": str(results_path)},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(calls, ["./test/hang.test.ts"] * 2, output)
        self.assertIn("RETRY test/hang.test.ts after its timeout", output)
        self.assertIn("TIMEOUT test/hang.test.ts (limit 2s)", output)
        self.assertNotIn("passed only when run alone", output)
        self.assertEqual(json.loads(results_path.read_text()), {"test/hang.test.ts": False})

    def test_each_timed_out_file_gets_its_own_retry_outside_the_shared_budget(self):
        """#27130's shard 4: two files timed out beside the others and were never retried, while
        failed files spent the shared retry budget. Each timed-out file now gets one retry alone,
        whatever the failed files' budget and retry count left."""
        files = ["test/0-fail-slow.test.ts", "test/1-fail-slow.test.ts",
                 "test/a-contended.test.ts", "test/b-contended.test.ts"]
        result, _, calls = self.run_runner(
            files,
            extra_env={"CMUX_WEB_TEST_RETRIES": "1", "CMUX_WEB_TEST_RETRY_BUDGET": "1",
                       "CMUX_WEB_TEST_TIMEOUT_RETRY_BUDGET": "10"},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)  # the fail-slow files stay red
        self.assertEqual(calls.count("./test/a-contended.test.ts"), 2, output)
        self.assertEqual(calls.count("./test/b-contended.test.ts"), 2, output)
        self.assertIn("passed only when run alone", output)
        self.assertIn("  test/a-contended.test.ts (first run: TIMEOUT)", output)
        self.assertIn("  test/b-contended.test.ts (first run: TIMEOUT)", output)
        self.assertNotRegex(output, r"(FAIL|TIMEOUT) test/[ab]-contended\.test\.ts \(limit")
        for file in files[:2]:
            self.assertRegex(output, rf"FAIL {file} \(limit")

    def test_timeout_retries_start_only_when_their_whole_limit_fits_their_budget(self):
        result, _, calls = self.run_runner(
            ["test/a-hang.test.ts", "test/b-hang.test.ts"],
            extra_env={"CMUX_WEB_TEST_RETRIES": "1", "CMUX_WEB_TEST_TIMEOUT_RETRY_BUDGET": "3"},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        # The first retry uses its whole 2 s limit of the 3 s budget; the second no longer fits.
        self.assertEqual(len(calls), 3, output)
        self.assertEqual(output.count("RETRY "), 1, output)
        self.assertIn("cannot fit", output)
        self.assertIn("TIMEOUT test/a-hang.test.ts (limit 2s)", output)
        self.assertIn("TIMEOUT test/b-hang.test.ts (limit 2s)", output)

    def test_every_timed_out_file_gets_its_retry_by_default(self):
        """Job 123436110075 (#27007's shard 1): 12 files timed out 32 wide, a fixed 240 s timeout
        retry budget fit three 120 s retries, and the other 7 stayed TIMEOUT though each passed
        alone. With no budget set, every timed-out file's whole limit is budgeted; one that still
        fails alone stays red."""
        files = [f"test/{index}-timed-out-once.test.ts" for index in range(3)] + ["test/timed-out-then-fail.test.ts"]
        results_path = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "results.json"
        # Their 250 s limits sum past the old fixed 240 s; the fake reports its timeout at once.
        result, _, calls = self.run_runner(
            files,
            extra_env={"CMUX_WEB_TEST_RETRIES": "60", "CMUX_WEB_TEST_FILE_TIMEOUT": "250",
                       "CMUX_WEB_TEST_RESULTS": str(results_path)},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)  # the file that fails alone stays red
        for file in files:
            self.assertEqual(calls.count(f"./{file}"), 2, output)
        self.assertNotIn("cannot fit", output)
        for file in files[:3]:
            self.assertIn(f"  {file} (first run: TIMEOUT)", output)
            self.assertNotRegex(output, rf"(FAIL|TIMEOUT) {file} \(limit")
        self.assertIn("FAIL test/timed-out-then-fail.test.ts (limit 250s)", output)
        self.assertIn("1 failed or timed out (4 retried alone, 3 passed alone)", output)
        self.assertEqual(json.loads(results_path.read_text())["test/timed-out-then-fail.test.ts > still broken alone"],
                         False, output)

    def test_a_retry_running_to_its_limit_costs_the_next_file_nothing(self):
        """A retry that passes just inside its limit plus the runner's upkeep took more than its
        limit; a budget summed from the limits then had too little left for the last file's retry."""
        files = ["test/a-timed-out-slow-retry.test.ts", "test/b-timed-out-slow-retry.test.ts"]
        result, _, calls = self.run_runner(files, extra_env={"CMUX_WEB_TEST_RETRIES": "60"})
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        for file in files:
            self.assertEqual(calls.count(f"./{file}"), 2, output)
            self.assertIn(f"  {file} (first run: TIMEOUT)", output)
        self.assertNotIn("cannot fit", output)

    def test_no_retry_runs_past_the_retry_deadline(self):
        """CMUX_WEB_TEST_RETRY_DEADLINE keeps the step inside its job's timeout-minutes: a timeout
        retry whose limit does not fit before it stays TIMEOUT, and a failed file keeps its failure."""
        files = ["test/a-timed-out-once.test.ts", "test/b-fail.test.ts"]
        result, _, calls = self.run_runner(
            files,
            extra_env={"CMUX_WEB_TEST_RETRIES": "60", "CMUX_WEB_TEST_FILE_TIMEOUT": "250",
                       "CMUX_WEB_TEST_RETRY_DEADLINE": "0"},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(calls, ["./test/a-timed-out-once.test.ts", "./test/b-fail.test.ts"], output)
        self.assertIn("retry deadline", output)
        self.assertIn("TIMEOUT test/a-timed-out-once.test.ts (limit 250s)", output)
        self.assertIn("FAIL test/b-fail.test.ts (limit 250s)", output)

    def test_no_retries_means_no_timeout_retry(self):
        result, _, calls = self.run_runner(["test/a-contended.test.ts"], extra_env={"CMUX_WEB_TEST_RETRIES": "0"})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./test/a-contended.test.ts"])

    def test_serial_retries_have_a_shared_time_budget(self):
        files = [f"test/{index}-fail-slow.test.ts" for index in range(4)]
        result, _, calls = self.run_runner(
            files,
            extra_env={"CMUX_WEB_TEST_RETRIES": "60", "CMUX_WEB_TEST_RETRY_BUDGET": "1"},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(len(calls), 8, output)
        for file in files:
            self.assertIn(f"FAIL {file}", output)
        self.assertIn("retry budget exhausted", output)

    def test_a_retry_cannot_outlive_the_remaining_shared_budget(self):
        results_path = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "results.json"
        result, elapsed, calls = self.run_runner(
            ["test/retry-hang.test.ts"],
            contents={"test/retry-hang.test.ts": "// cmux-web-test-timeout: 4\n"},
            extra_env={"CMUX_WEB_TEST_RETRIES": "1", "CMUX_WEB_TEST_RETRY_BUDGET": "1",
                       "CMUX_WEB_TEST_RESULTS": str(results_path)},
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(elapsed, 3, output)
        self.assertEqual(calls, ["./test/retry-hang.test.ts"] * 2)
        self.assertIn("TIMEOUT test/retry-hang.test.ts", output)

        self.assertEqual(json.loads(results_path.read_text()), {
            "test/retry-hang.test.ts > first attempt assertion": False,
        }, "an incomplete retry must preserve the named first failure")

    def test_a_flood_is_bounded_but_raw_retry_logs_and_named_failure_are_kept(self):
        raw_logs = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        results_path = raw_logs / "results.json"
        result, _, calls = self.run_runner(
            ["test/inspector-dead-clicks-flood.test.ts"],
            extra_env={
                "CMUX_WEB_TEST_RETRIES": "1",
                "CMUX_WEB_TEST_LOG_DISPLAY_BYTES": "4096",
                "CMUX_WEB_TEST_RAW_LOG_DIR": str(raw_logs / "raw"),
                "CMUX_WEB_TEST_RESULTS": str(results_path),
            },
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(calls, ["./test/inspector-dead-clicks-flood.test.ts"] * 2)
        self.assertLess(len(output.encode()), 12_000, output)
        self.assertIn("output truncated; complete log is in the configured webviews raw-log artifact", output)
        self.assertIn("(fail) inspector-dead-clicks sentinel", output)
        self.assertEqual(
            json.loads(results_path.read_text()),
            {"test/inspector-dead-clicks-flood.test.ts > inspector-dead-clicks sentinel": False},
        )
        logs = list((raw_logs / "raw").glob("*.log"))
        self.assertEqual(len(logs), 1, logs)
        raw = logs[0].read_bytes()
        self.assertGreater(len(raw), 4_000_000, len(raw))
        self.assertIn(b"(fail) inspector-dead-clicks sentinel", raw)

    def test_a_passing_annotation_flood_is_bounded(self):
        result, _, calls = self.run_runner(
            ["test/browser-notice-flood.test.ts"],
            extra_env={"CMUX_WEB_TEST_LOG_DISPLAY_BYTES": "4096"},
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(calls, ["./test/browser-notice-flood.test.ts"])
        self.assertLess(len(output.encode()), 12_000, output)
        self.assertIn("::notice title=browser-flood", output)
        self.assertIn("output truncated; complete log remains in the runner's per-file log", output)

    def test_retry_budget_expiring_during_limit_lookup_starts_no_retry(self):
        system_head = shutil.which("head")
        def delay_limit_lookup(web):
            head = web.parent / "bin/head"
            head.write_text("#!/usr/bin/env bash\n"
                            'if [ -f "$BUN_CALLS.retry" ] && [ ! -f "$BUN_CALLS.delayed" ]; then\n'
                            '  touch "$BUN_CALLS.delayed"; sleep 2\nfi\n'
                            f'exec "{system_head}" "$@"\n')
            head.chmod(0o755)
        self.web_hook = delay_limit_lookup
        result, _, calls = self.run_runner(
            ["test/retry-hang.test.ts"],
            contents={"test/retry-hang.test.ts": "// cmux-web-test-timeout: 4\n"},
            extra_env={"CMUX_WEB_TEST_RETRIES": "1", "CMUX_WEB_TEST_RETRY_BUDGET": "1"},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./test/retry-hang.test.ts"], result.stdout + result.stderr)

    def test_passing_files_pass(self):
        result, _, calls = self.run_runner(["test/a.test.ts", "src/b.test.tsx"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./src/b.test.tsx", "./test/a.test.ts"])

    def test_a_focused_list_runs_only_those_files(self):
        """scripts/ci/car_guards.py passes the focused tests a car selects."""
        files = ["test/a.test.ts", "test/fail.test.ts", "src/b.test.tsx"]
        result, _, calls = self.run_runner(files, extra_env={"CMUX_WEB_TEST_FILES": "src/b.test.tsx\ntest/a.test.ts\n"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./src/b.test.tsx", "./test/a.test.ts"])

    def test_a_focused_list_naming_no_test_file_fails(self):
        """A stale selection (a moved or deleted test) must not pass by running nothing."""
        result, _, calls = self.run_runner(["test/a.test.ts"], extra_env={"CMUX_WEB_TEST_FILES": "test/gone.test.ts"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test/gone.test.ts", result.stderr)
        self.assertEqual(calls, [])

    def test_arguments_pick_files_dirs_and_name_filters(self):
        """`bun run test FILES` (webviews' test script) runs only the named files, one process each."""
        files = ["test/a.test.ts", "test/fail.test.ts", "src/b.test.tsx", "src/chips/c.test.tsx"]
        result, _, calls = self.run_runner(files, args=["./test/a.test.ts", "src/chips", "b.test"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./src/b.test.tsx", "./src/chips/c.test.tsx", "./test/a.test.ts"])

    def test_an_argument_matching_no_test_file_fails(self):
        result, _, calls = self.run_runner(["test/a.test.ts"], args=["test/a.test.ts", "gone"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gone", result.stderr)
        self.assertEqual(calls, [])

    def test_a_bun_option_is_refused_with_the_single_file_command(self):
        result, _, calls = self.run_runner(["test/a.test.ts"], args=["--watch"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("bun test FILE --watch", result.stderr)
        self.assertEqual(calls, [])

    def test_an_untracked_test_runs_outside_github_actions(self):
        """A new test runs under `bun run test` before it is staged, named or not, as bare `bun test` ran it;
        GitHub Actions keeps the git index list."""
        def add_untracked(web):
            (web / "test" / "new.test.ts").write_text("", encoding="utf-8")
            (web / ".gitignore").write_text("ignored.test.ts\n", encoding="utf-8")
            (web / "test" / "ignored.test.ts").write_text("", encoding="utf-8")
        self.web_hook = add_untracked
        result, _, calls = self.run_runner(["test/a.test.ts"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./test/a.test.ts", "./test/new.test.ts"])
        result, _, calls = self.run_runner(["test/a.test.ts"], args=["test/new.test.ts"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./test/new.test.ts"])
        result, _, calls = self.run_runner(["test/a.test.ts"], extra_env={"GITHUB_ACTIONS": "true"})
        self.assertEqual(calls, ["./test/a.test.ts"])

    def test_webviews_test_script_is_the_per_file_runner(self):
        """A single `bun test` over many files leaks globals between them: diff-viewer-git before
        access-chip-refused-mode fails 13 tests that pass alone and in CI."""
        scripts = json.loads((ROOT / "webviews" / "package.json").read_text(encoding="utf-8"))["scripts"]
        self.assertEqual(scripts["test"], "bash ../scripts/ci/run-webviews-tests.sh")

    def test_shards_cover_each_file_once(self):
        files = ["test/a.test.ts", "test/b.test.ts", "test/c.test.ts", "src/d.test.tsx", "src/e.test.tsx"]
        _, _, first = self.run_runner(files, shard=1, shard_count=2)
        _, _, second = self.run_runner(files, shard=2, shard_count=2)
        self.assertEqual(sorted(first + second), sorted(f"./{name}" for name in files))
        self.assertEqual(set(first) & set(second), set())

    def manifest(self, durations):
        path = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "durations.json"
        path.write_text(json.dumps(durations), encoding="utf-8")
        return str(path)

    def test_recorded_durations_split_the_shards_by_load(self):
        """Index mod 2 put both long files (10 s, 9 s) on shard 1 and both 1 s files on shard 2.
        Each plain file has a lane of its own, so the shards' wall times are their longest files:
        the two long ones must part."""
        files = ["test/a.test.ts", "test/b.test.ts", "test/c.test.ts", "test/d.test.ts"]
        manifest = self.manifest({"test/a.test.ts": 10, "test/b.test.ts": 1, "test/c.test.ts": 9, "test/d.test.ts": 1})
        shards = [self.run_runner(files, shard=n, shard_count=2, extra_env={"CMUX_WEB_TEST_DURATIONS": manifest})[2]
                  for n in (1, 2)]
        self.assertEqual(sorted(shards[0] + shards[1]), sorted(f"./{name}" for name in files))
        a = 0 if "./test/a.test.ts" in shards[0] else 1
        self.assertIn("./test/c.test.ts", shards[1 - a], shards)

    def test_a_new_file_moves_only_itself(self):
        known = {f"test/{name}.test.ts": seconds for name, seconds in zip("abcdefgh", (9, 8, 7, 5, 4, 3, 2, 1))}
        manifest = self.manifest(known)
        def split(files):
            return {name: n for n in (1, 2, 3)
                    for name in self.run_runner(files, shard=n, shard_count=3, extra_env={"CMUX_WEB_TEST_DURATIONS": manifest})[2]}
        before = split(list(known))
        after = split(list(known) + ["test/new.test.ts", "test/0-first.test.ts"])
        self.assertEqual({name: after[name] for name in before}, before)
        self.assertEqual(len(after), len(known) + 2)

    def test_unrecorded_files_split_by_a_stable_hash_of_their_path(self):
        names = [f"test/{index}.test.ts" for index in range(40)]
        expected = {name: int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "big") % 4 + 1 for name in names}
        got = {name: n for n in (1, 2, 3, 4) for name in self.run_runner(names, shard=n, shard_count=4)[2]}
        self.assertEqual(got, {f"./{name}": shard for name, shard in expected.items()})

    def test_a_config_warms_on_its_shortest_file_and_the_rest_start_longest_first(self):
        """accent-glass-invariants warmed its config alone for 549 s of an 18.6 min shard: it came
        first in the index. With durations the shortest file warms, and the long ones start first."""
        pane = "// vite.config.acpmux-pane.mjs\n"
        files = ["test/a-long.test.ts", "test/b-short.test.ts", "test/c-mid.test.ts", "test/d-plain.test.ts", "test/e-plain.test.ts"]
        contents = {name: pane for name in files[:3]}
        manifest = self.manifest({"test/a-long.test.ts": 549, "test/b-short.test.ts": 2, "test/c-mid.test.ts": 90,
                                  "test/d-plain.test.ts": 1, "test/e-plain.test.ts": 30})
        result, _, _ = self.run_runner(files, contents=contents,
                                       extra_env={"CMUX_WEB_TEST_DURATIONS": manifest, "CMUX_WEB_TEST_JOBS": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        order = self.calls_file.read_text(encoding="utf-8").split()
        self.assertEqual(order, ["./test/e-plain.test.ts", "./test/d-plain.test.ts", "./test/b-short.test.ts",
                                 "./test/a-long.test.ts", "./test/c-mid.test.ts"])
        warm = [line.split() for line in self.dev.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(warm[0][0], "./test/b-short.test.ts")
        self.assertEqual([entry[2] for entry in warm], ["cold", "warm", "warm"])

    def test_without_durations_the_order_is_the_git_index_order(self):
        pane = "// vite.config.acpmux-pane.mjs\n"
        files = ["test/a-long.test.ts", "test/b-short.test.ts"]
        result, _, _ = self.run_runner(files, contents={name: pane for name in files}, extra_env={"CMUX_WEB_TEST_JOBS": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls_file.read_text(encoding="utf-8").split(), ["./test/a-long.test.ts", "./test/b-short.test.ts"])

    def test_each_files_first_run_seconds_are_recorded(self):
        out = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "out" / "shard.json"
        result, _, calls = self.run_runner(
            ["test/slow.test.ts", "test/a.test.ts", "test/hang.test.ts"],
            extra_env={"CMUX_WEB_TEST_DURATIONS_OUT": str(out), "CMUX_WEB_TEST_RETRIES": "1"})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)  # hang times out twice
        self.assertEqual(calls.count("./test/hang.test.ts"), 2)
        recorded = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(set(recorded), {"test/slow.test.ts", "test/a.test.ts", "test/hang.test.ts"})
        self.assertGreaterEqual(recorded["test/slow.test.ts"], 2)
        self.assertLess(recorded["test/a.test.ts"], 2)
        self.assertGreaterEqual(recorded["test/hang.test.ts"], 2)

    def test_dev_server_files_run_at_once_each_on_its_own_warm_vite_cache(self):
        # Every file that starts a dev server once ran one at a time after the rest (#19812): on
        # one node_modules/.vite two at once lost each other's optimized files, and editor-page
        # timed out beside ui-a11y and text-field-focus (#19746). That lane added 2.5 minutes. Each
        # file now has its own cache, copied from one warmed per config, so several run at once.
        default_server = 'spawn(vp, ["dev", "--port", String(port), "--strictPort"]);\n'
        settings_server = 'spawn(vp, [\n  "dev",\n  "--config",\n  "vite.config.settings-page.mjs",\n]);\n'
        gallery_server = 'import config from "../vite.config.gallery-dev.ts";\n'
        pane_server = 'spawn(vp, ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port)]);\n'
        created_server = 'vite = await createServer({\n  configFile: path.join(webviews, "vite.config.ts"),\n'
        contents = {
            "test/editor-page.test.ts": default_server,
            "test/ui-a11y.test.ts": default_server,
            "test/text-field-focus.test.ts": default_server,
            "test/new-tab-typing.test.ts": created_server,
            "test/settings-scroll.test.ts": settings_server,
            "test/composer-mention.test.ts": gallery_server,
            "test/composer-send-stop.test.ts": gallery_server,
            "test/chat-find.test.ts": pane_server,
            "test/agent-history.test.ts": pane_server,
            "test/agent-pane-peer-chat.test.ts": pane_server,
        }
        files = [*contents, "test/a.test.ts", "src/b.test.tsx"]
        result, _, calls = self.run_runner(files, contents=contents)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        self.assertEqual(self.overlaps.read_text(encoding="utf-8"), "", output)
        runs = [line.split() for line in self.dev.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(sorted(name for name, _, _ in runs), sorted(f"./{name}" for name in contents))
        caches = [cache for _, cache, _ in runs]
        self.assertEqual(len(set(caches)), len(caches), "each dev server file has its own Vite cache")
        self.assertNotIn(str(self.shared_cache), caches)
        # One file per config warms its cache first; every other file starts from a copy of it.
        self.assertEqual(sum(warm == "cold" for _, _, warm in runs), 4, runs)
        self.assertGreater(max(int(n) for n in self.peak.read_text(encoding="utf-8").split()), 1, output)

    def test_a_failed_warming_file_hands_warming_to_the_next_file_of_its_config(self):
        # One red pane file warmed first, and every other pane file then ran one at a time on a
        # cold cache: about 7 minutes of a 13-minute shard (react-apps-check 4/4, job 118973285057).
        pane_server = 'spawn(vp, ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port)]);\n'
        contents = {f"test/agent-{name}.test.ts": pane_server
                    for name in ("a-fail", "history", "peer-chat", "steps", "subagents")}
        result, _, calls = self.run_runner(list(contents), contents=contents)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in contents), "each file runs once")
        runs = [line.split() for line in self.dev.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([warm for _, _, warm in runs].count("cold"), 2,
                         f"the failed warmer and the one after it start cold, the rest warm: {runs}")
        self.assertGreater(max(int(n) for n in self.peak.read_text(encoding="utf-8").split()), 1, output)

    def test_warming_stops_after_the_attempt_limit_and_the_rest_run_one_at_a_time_cold(self):
        # A config whose warmers all fail must not try every file as a warmer: after
        # CMUX_WEB_TEST_WARM_ATTEMPTS failures its other files run one at a time on cold caches.
        pane_server = 'spawn(vp, ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port)]);\n'
        contents = {f"test/agent-{name}-fail.test.ts": pane_server for name in ("a", "b", "c", "d")}
        result, _, calls = self.run_runner(list(contents), contents=contents,
                                           extra_env={"CMUX_WEB_TEST_WARM_ATTEMPTS": "2"})
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in contents), "each file runs once")
        self.assertIn("4 failed or timed out", output)
        runs = [line.split() for line in self.dev.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([warm for _, _, warm in runs], ["cold"] * 4, runs)
        self.assertEqual(self.overlaps.read_text(encoding="utf-8"), "", output)
        self.assertEqual(max(int(n) for n in self.peak.read_text(encoding="utf-8").split()), 1, output)

    def test_a_file_that_loads_the_machine_runs_alone_after_the_others(self):
        # agent-pane-attach-huge-files (2 GB uploads) ran beside three composer files: they timed
        # out and its own typing read 85 ms (run 40732464791). It declares cmux-web-test-alone and
        # runs last, by itself, on its config's warm cache.
        pane_server = 'spawn(vp, ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port)]);\n'
        contents = {f"test/agent-{name}.test.ts": pane_server for name in ("a", "b", "c", "d")}
        contents["test/agent-huge.test.ts"] = "// cmux-web-test-alone\n" + pane_server
        result, _, calls = self.run_runner(list(contents), contents=contents)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in contents), "each file runs once")
        runs = [line.split() for line in self.dev.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(runs[-1][0], "./test/agent-huge.test.ts", runs)
        self.assertNotEqual(runs[-1][2], "cold", "it starts from its config's warm cache")
        self.assertGreater(max(int(n) for n in self.peak.read_text(encoding="utf-8").split()), 1, output)
        self.assertEqual(int(self.peak.read_text(encoding="utf-8").split()[-1]), 1, "it runs by itself")

    def peaks(self):
        def peak(path):
            return max((int(n) for n in path.read_text(encoding="utf-8").split()), default=0)
        return peak(self.pool_peak), peak(self.browser_peak)

    def test_browser_files_run_in_a_narrow_pool_beside_the_other_plain_files(self):
        """Started 32 at once with the jsdom files, longest first, 29 browser files (Chromium and
        WebKit each) shared one 32 vCPU shard: eight timed out and frame-timing plays failed, and
        every one passed alone on the base replay (job 123385326827 against 123394574731). The
        browser files get a quarter of the jobs; the other plain files run beside them on the rest."""
        browser = {f"test/pool-browser-{index}.test.ts": ('import { chromium } from "playwright";\n' if index % 2
                   else 'await requireBrowserLane("x", async () => {});\n') for index in range(8)}
        files = [*browser, *(f"test/pool-jsdom-{index}.test.ts" for index in range(8))]
        result, _, calls = self.run_runner(files, contents=browser)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        everything, browsers = self.peaks()
        self.assertEqual(browsers, 2, output)  # 8 jobs: a quarter for browsers
        self.assertGreater(everything, 2, "the jsdom files run beside the browser files")
        self.assertLessEqual(everything, 8, "both pools together stay inside the jobs")
        self.assertIn("6 at a time, beside 8 browser files 2 at a time", output)

    def test_browser_pool_width_can_be_set_and_one_job_runs_one_file_at_a_time(self):
        browser = {f"test/pool-browser-{index}.test.ts": 'import { webkit } from "playwright";\n' for index in range(6)}
        files = [*browser, "test/pool-jsdom-a.test.ts", "test/pool-jsdom-b.test.ts"]
        result, _, _ = self.run_runner(files, contents=browser, extra_env={"CMUX_WEB_TEST_BROWSER_JOBS": "3"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.peaks()[1], 3, result.stdout)
        # The base replay runs one file at a time: the two pools then run one after the other.
        result, _, calls = self.run_runner(files, contents=browser, extra_env={"CMUX_WEB_TEST_JOBS": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        self.assertEqual(self.peaks(), (1, 1), result.stdout)

    def test_a_file_can_declare_a_longer_limit_than_the_default(self):
        # editor-page runs 24 browser tests in two engines, about 115 s on the CI runner: the
        # 120 s default killed it mid-WebKit, and its later tests read "browser has been closed".
        # A file names its own limit on a header line; one without it keeps the default.
        contents = {
            "test/slow-declared.test.ts": "// cmux-web-test-timeout: 8\n",
            "test/slow-default.test.ts": "",
            # A declared limit never shortens a longer CMUX_WEB_TEST_FILE_TIMEOUT.
            "test/slow-shorter.test.ts": "// cmux-web-test-timeout: 1\n",
        }
        result, _, calls = self.run_runner(list(contents), contents=contents)
        output = result.stdout + result.stderr
        self.assertEqual(calls, sorted(f"./{name}" for name in contents))
        self.assertNotRegex(output, r"(FAIL|TIMEOUT)[^\n]*test/slow-declared\.test\.ts")
        self.assertRegex(output, r"TIMEOUT[^\n]*test/slow-default\.test\.ts \(limit 2s\)")
        self.assertIn("test/slow-declared.test.ts", output)
        self.assertRegex(output, r"TIMEOUT[^\n]*test/slow-shorter\.test\.ts \(limit 2s\)")

    def install_fake_playwright(self):
        """A fake webviews/node_modules/.bin/playwright that logs its install calls."""
        self.playwright_calls = None

        def hook(web):
            bin_dir = web / "node_modules" / ".bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            log = web.parent / "playwright-calls"
            log.write_text("", encoding="utf-8")
            script = bin_dir / "playwright"
            script.write_text('#!/usr/bin/env bash\nprintf \'%s|%s\\n\' "$*" "$PLAYWRIGHT_BROWSERS_PATH" >> "' + str(log)
                              + '"\n', encoding="utf-8")
            script.chmod(0o755)
            self.playwright_calls = log
        return hook

    def test_a_fleet_browser_run_installs_the_ci_engines_into_the_step_cache(self):
        """A fleet cmux-ci step passes CMUX_BROWSER_TESTS=1 to run the browser lane, which needs the
        engines CI installs (requireBrowserLane.ts); without it the lane skips everywhere but PR CI."""
        cache = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.web_hook = self.install_fake_playwright()
        result, _, calls = self.run_runner(["test/a.test.ts"], extra_env={
            "CMUX_BROWSER_TESTS": "1", "CMUX_CI_CACHE_DIR": str(cache)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./test/a.test.ts"])
        lines = self.playwright_calls.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 1, lines)
        args, browsers = lines[0].split("|")
        self.assertEqual(args, "install --only-shell chromium webkit")
        self.assertTrue(browsers.startswith(str(cache / "playwright")), browsers)

    def test_ci_and_plain_runs_install_no_engines(self):
        for env in ({}, {"CMUX_BROWSER_TESTS": "0"}, {"CMUX_BROWSER_TESTS": "1", "GITHUB_ACTIONS": "true"}):
            with self.subTest(env=env):
                self.web_hook = self.install_fake_playwright()
                result, _, _ = self.run_runner(["test/a.test.ts"], extra_env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.playwright_calls.read_text(encoding="utf-8"), "")

    def test_no_test_files_is_an_error(self):
        result, _, _ = self.run_runner([])
        self.assertNotEqual(result.returncode, 0)

    def test_ci_runs_webviews_tests_per_file(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        step = text[text.index("      - name: Test webviews\n"):]
        step = step[: step.index("\n      - name:", 10)]
        # The step's wrapper runs this runner, then compares a pull request's reds with its base's.
        self.assertIn("scripts/ci/webviews-tests-new-reds.sh", step)
        self.assertIn('bash "$here/run-webviews-tests.sh"', (RUNNER.parent / "webviews-tests-new-reds.sh").read_text())
        self.assertNotIn("bun run test", step)


class ShardHelper(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run([sys.executable, str(SHARDS), *args], capture_output=True, text=True, check=True)

    def test_merge_averages_with_the_prior_manifest_and_drops_bad_entries(self):
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "prior.json").write_text(json.dumps({"a": 10, "gone": 4, "bad": "x"}))
        (temp / "s1.json").write_text(json.dumps({"a": 20, "b": 5}))
        (temp / "s2.json").write_text(json.dumps({"c": -1, "d": True, "e": 7.25}))
        self.run_helper("merge", str(temp / "new" / "m.json"), str(temp / "prior.json"), str(temp / "s1.json"),
                        str(temp / "s2.json"), str(temp / "missing.json"))
        self.assertEqual(json.loads((temp / "new" / "m.json").read_text()), {"a": 15, "b": 5, "e": 7.2, "gone": 4})

    def test_record_keeps_each_files_first_run(self):
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "lines").write_text("12 test/a.test.ts\n3 test/b.test.ts\n40 test/a.test.ts\nnot a line\n")
        self.run_helper("record", str(temp / "lines"), str(temp / "out.json"))
        self.assertEqual(json.loads((temp / "out.json").read_text()), {"test/a.test.ts": 12, "test/b.test.ts": 3})

    def test_the_split_weighs_dev_server_and_alone_files_by_how_few_run_at_once(self):
        """Seventeen dev-server files of 8 s on one config: one warms alone (8 s), sixteen share the
        8-wide pool (16 s), 24 s in all; an alone file of 24 s is as much. A seconds-sum split would
        put 8 dev files beside it (64 + 24 against 72 s)."""
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        files = [f"test/dev{index:02}.test.ts" for index in range(17)] + ["test/alone.test.ts"]
        (temp / "test").mkdir()
        for name in files:
            (temp / name).write_text("// cmux-web-test-alone\n" if "alone" in name else "// vite.config.acpmux-pane.mjs\n")
        (temp / "files").write_bytes(b"".join(name.encode() + b"\0" for name in files))
        (temp / "serial").write_bytes((temp / "files").read_bytes())
        (temp / "d.json").write_text(json.dumps({**{name: 8 for name in files}, "test/alone.test.ts": 24}))
        split = [subprocess.run([sys.executable, str(SHARDS), "assign", "files", "serial", "d.json", str(n), "2"],
                                cwd=temp, capture_output=True, check=True).stdout.split(b"\0")[:-1] for n in (1, 2)]
        self.assertEqual(sorted(len(shard) for shard in split), [1, 17], split)

    def test_the_plan_counts_each_configs_warming_file_alone(self):
        """One config with files of 100 s and 20 s: the 20 s file warms alone, then the 100 s one runs
        on the warm cache. 120 s, not the 100 s of an 8-lane pool."""
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        spec = importlib.util.spec_from_file_location("webviews_test_shards", SHARDS)
        shards = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(shards)
        for name in ("pane-a", "pane-b"):
            (temp / name).write_text("// vite.config.acpmux-pane.mjs\n")
        (temp / "gallery-c").write_text("// vite.config.gallery-dev.ts\n")
        plan = shards.ShardPlan()
        configs = {name: shards.vite_config(str(temp / name)) for name in ("pane-a", "pane-b", "gallery-c")}
        self.assertEqual(configs, {"pane-a": "pane", "pane-b": "pane", "gallery-c": "gallery"})
        plan.add("dev", 100_000, "pane")
        self.assertEqual(plan.wall(), 100_000)
        self.assertEqual(plan.wall("dev", 20_000, "pane"), 120_000)
        plan.add("dev", 20_000, "pane")
        self.assertEqual(plan.wall("dev", 5_000, "gallery"), 125_000)  # a second config warms alone too
        self.assertEqual(plan.wall("plain", 30_000), 150_000)


    def test_the_split_spreads_browser_files_by_how_few_run_at_once(self):
        """A 30 s plain file and 32 browser files of 10 s on two shards. Counted as plain files on 32
        lanes, all 32 browser files fit beside nothing on the other shard in 10 s, and they went there
        together (shard 1 of #27329's run held 34 of them). On 8 browser lanes they would take 40 s
        there, so the plain file's shard takes about half of them beside its 30 s file."""
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "test").mkdir()
        browsers = [f"test/b{index:02}.test.ts" for index in range(32)]
        for name in browsers:
            (temp / name).write_text('import { chromium } from "playwright";\n')
        (temp / "test/plain.test.ts").write_text("")
        files = ["test/plain.test.ts", *browsers]
        (temp / "files").write_bytes(b"".join(name.encode() + b"\0" for name in files))
        (temp / "serial").write_bytes(b"")
        (temp / "d.json").write_text(json.dumps({**{name: 10 for name in browsers}, "test/plain.test.ts": 30}))
        split = [subprocess.run([sys.executable, str(SHARDS), "assign", "files", "serial", "d.json", str(n), "2"],
                                cwd=temp, capture_output=True, check=True).stdout.split(b"\0")[:-1] for n in (1, 2)]
        with_plain = next(shard for shard in split if b"test/plain.test.ts" in shard)
        without = next(shard for shard in split if b"test/plain.test.ts" not in shard)
        # Counted on 32 plain lanes, all 32 went beside nothing: (0, 32).
        self.assertEqual((len(with_plain) - 1, len(without)), (15, 17), split)

    def test_the_plan_runs_browser_files_beside_plain_files(self):
        spec = importlib.util.spec_from_file_location("webviews_test_shards", SHARDS)
        shards = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(shards)
        plan = shards.ShardPlan()
        plan.add("plain", 50_000)
        self.assertEqual(plan.wall("browser", 30_000), 50_000)  # beside the plain pool, not after it
        for _ in range(8):
            plan.add("browser", 30_000)
        self.assertEqual(plan.wall("browser", 30_000), 60_000)  # a ninth waits for a lane


class Workflow(unittest.TestCase):
    def test_every_shard_splits_by_the_one_manifest_web_subarea_scope_hands_it(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        scope = text[text.index("  web-subarea-scope:"):text.index("  web-typecheck:")]
        self.assertIn("restore-keys: webviews-test-durations-", scope)
        self.assertIn("name: webviews-test-durations\n", scope)
        self.assertIn("overwrite: true", scope[scope.index("name: webviews-test-durations\n"):][:200])
        shard = text[text.index("  react-apps-check-shard:"):text.index("  react-apps-base-check:")]
        download = shard[shard.index("      - name: Download the duration manifest"):]
        download = download[:download.index("\n      - name:", 10)]
        self.assertIn("name: webviews-test-durations\n", download)
        self.assertNotIn("continue-on-error", download)  # a shard never splits without it
        self.assertNotIn("webviews-test-durations-", shard.split("Download the duration manifest")[1].split("Test webviews")[0])  # no cache restore
        self.assertIn("CMUX_WEB_TEST_DURATIONS: ${{ runner.temp }}/webviews-durations/manifest.json", shard)
        self.assertIn("webviews_test_shards.py", shard[shard.index("cp ../scripts/ci/run-webviews-tests.sh"):][:200])
        upload = shard[shard.index("      - name: Upload this shard's durations"):]
        upload = upload[:upload.index("\n      - name:", 10)]
        self.assertIn("continue-on-error: true", upload)  # optional upkeep never fails a required shard
        self.assertIn("timeout-minutes:", upload)
        gate = shard[shard.index("      - name: Fail on the gate checks"):]
        self.assertIn("DURATIONS_UPLOAD: ${{ steps.durations-upload.outcome }}", gate)
        self.assertNotIn('"DURATIONS_UPLOAD|', gate)  # read as a warning, never one of the failing gates
        check = text[text.index("  react-apps-check:"):text.index("  webviews-test-durations:")]
        self.assertNotIn("durations", check)  # the required gate does no manifest upkeep
        upkeep = text[text.index("  webviews-test-durations:"):text.index("  diff-sidecar-check:")]
        self.assertIn("webviews_test_shards.py merge", upkeep)
        self.assertIn("key: webviews-test-durations-${{ github.run_id }}-${{ github.run_attempt }}", upkeep)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", upkeep)
        self.assertIn("timeout-minutes: 5", upkeep)


if __name__ == "__main__":
    unittest.main()
