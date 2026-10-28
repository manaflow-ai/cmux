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
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-webviews-tests.sh"
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
    def run_runner(self, files, without_timeout=False, contents=None, shard=None, shard_count=None, extra_env=None):
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
        calls.write_text("", encoding="utf-8")
        self.overlaps = temp / "overlaps"
        self.overlaps.write_text("", encoding="utf-8")
        self.dev, self.peak, running = temp / "dev", temp / "peak", temp / "running"
        self.dev.write_text("", encoding="utf-8")
        self.peak.write_text("", encoding="utf-8")
        running.mkdir()
        (web / "node_modules").mkdir(exist_ok=True)
        if getattr(self, "web_hook", None):
            self.web_hook(web)
        self.shared_cache = web / "node_modules" / ".vite"
        system_path = path_without_timeout(temp) if without_timeout else os.environ["PATH"]
        base_env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
        env = {**base_env, "PATH": f"{bin_dir}:{system_path}", "BUN_CALLS": str(calls),
               "BUN_OVERLAPS": str(self.overlaps), "SHARED_VITE_CACHE": str(web / "node_modules" / ".vite"),
               "BUN_DEV": str(self.dev), "BUN_PEAK": str(self.peak), "DEV_RUNNING": str(running),
               "CMUX_WEB_TEST_FILE_TIMEOUT": "2", "CMUX_WEB_TEST_JOBS": "8",
               # These tests read each file's first run; scripts/ci/tests/run-webviews-tests-retry.test.sh
               # covers the rerun of a failed file.
               "CMUX_WEB_TEST_RETRIES": "0"}
        if shard is not None:
            env["CMUX_WEB_TEST_SHARD"] = str(shard)
            env["CMUX_WEB_TEST_SHARD_COUNT"] = str(shard_count)
        env.update(extra_env or {})
        started = time.monotonic()
        result = subprocess.run(["bash", str(RUNNER)], cwd=web, env=env, capture_output=True, text=True, timeout=40)
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

    def test_a_timed_out_file_reports_once_without_a_serial_retry(self):
        result, _, calls = self.run_runner(
            ["test/hang.test.ts"], extra_env={"CMUX_WEB_TEST_RETRIES": "1"}
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(calls, ["./test/hang.test.ts"], output)
        self.assertIn("TIMEOUT test/hang.test.ts", output)

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

    def test_shards_cover_each_file_once(self):
        files = ["test/a.test.ts", "test/b.test.ts", "test/c.test.ts", "src/d.test.tsx", "src/e.test.tsx"]
        _, _, first = self.run_runner(files, shard=1, shard_count=2)
        _, _, second = self.run_runner(files, shard=2, shard_count=2)
        self.assertEqual(sorted(first + second), sorted(f"./{name}" for name in files))
        self.assertEqual(set(first) & set(second), set())

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


if __name__ == "__main__":
    unittest.main()
