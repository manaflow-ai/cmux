#!/usr/bin/env python3
"""The measurement scripts that drive Playwright refuse to run on a Mac.

Lawrence's rule (2026-11-02): no Playwright, Puppeteer or downloaded Chromium on his Mac or on any
fleet Mac. Playwright's engines are an old Chromium (the headless shell) and Playwright turns the
Chromium sandbox off; our own fleet steps had left about 4.6 GB of them on 10 fleet Macs.
scripts/ci/run-webviews-tests.sh and webviews-tests-new-reds.sh have their own tests
(test_webviews_tests_per_file.py, test_webviews_tests_new_reds.py). A fake `uname` decides the host,
so these run the same on Linux and on a Mac, and the scripts stop before they touch the checkout.
"""

import os
import pathlib
import subprocess
import tempfile
import unittest
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = pathlib.Path(__file__).resolve().parents[1]
SETTINGS_SWITCH = ROOT / "scripts" / "measure" / "settings-section-switch.sh"
BROWSER_USE_PERF = ROOT / "scripts" / "measure" / "browser-use-perf.sh"
TEAM_EVAL = ROOT / "scripts" / "measure" / "team-eval.sh"
ENSURE_CHROME = ROOT / "scripts" / "ci" / "ensure-system-chrome.sh"
PRELOAD = ROOT / "webviews" / "test" / "preload.ts"
REFUSAL = "not on a Mac (Lawrence's rule: no Playwright on Macs); run it in CI or on a cloud VM"


class MeasureScriptsOnAMac(unittest.TestCase):
    def run_script(self, script, uname, args=(), extra_env=None):
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        (bin_dir / "uname").write_text(f"#!/bin/sh\necho {uname}\n", encoding="utf-8")
        # A step that got past the guard would call these; each records that it ran.
        calls = temp / "calls"
        for tool in ("bun", "node", "cargo", "git", "curl", "hdiutil", "ditto", "codesign", "sudo", "bunx", "npx",
                     "google-chrome-stable"):
            (bin_dir / tool).write_text(f'#!/bin/sh\necho {tool} >> "{calls}"\nexit 97\n', encoding="utf-8")
            (bin_dir / tool).chmod(0o755)
        (bin_dir / "uname").chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", **(extra_env or {}))
        result = subprocess.run(["bash", str(script), *args], cwd=temp, env=env, capture_output=True, text=True,
                                timeout=30)
        ran = calls.read_text(encoding="utf-8").split() if calls.exists() else []
        return result, ran

    def test_settings_section_switch_refuses_on_a_mac(self):
        result, ran = self.run_script(SETTINGS_SWITCH, "Darwin")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"settings-section-switch.sh: {REFUSAL}", result.stderr)
        self.assertEqual(ran, [])

    def test_settings_section_switch_still_runs_on_linux(self):
        result, ran = self.run_script(SETTINGS_SWITCH, "Linux")
        self.assertNotIn(REFUSAL, result.stdout + result.stderr)
        self.assertEqual(ran[:1], ["git"])

    def test_browser_use_perf_refuses_its_bench_on_a_mac(self):
        result, ran = self.run_script(BROWSER_USE_PERF, "Darwin", args=["runs=1"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"browser-use-perf.sh: {REFUSAL}", result.stderr)
        self.assertEqual(ran, [])

    def test_browser_use_perf_still_builds_the_host_on_a_mac(self):
        # build=only builds cmux-browser-host for a run elsewhere and starts no browser.
        result, ran = self.run_script(BROWSER_USE_PERF, "Darwin", args=["build=only"])
        self.assertNotIn(REFUSAL, result.stdout + result.stderr)
        self.assertEqual(ran[:1], ["git"])

    def test_browser_use_perf_still_runs_on_linux(self):
        result, ran = self.run_script(BROWSER_USE_PERF, "Linux", args=["runs=1"])
        self.assertNotIn(REFUSAL, result.stdout + result.stderr)
        self.assertEqual(ran[:1], ["git"])

    def test_team_eval_turns_its_browser_lane_off_on_a_mac(self):
        # The eval itself needs a model route and builds; only its hidden-test step drives
        # browsers. Run that step's lane choice on its own, as the script writes it.
        text = TEAM_EVAL.read_text(encoding="utf-8")
        start = text.index("    browser_lane=on\n")
        end = text.index("    fi\n", start) + len("    fi\n")
        probe = ('set -euo pipefail\nBUN=bun\nrepo="$1"\nwork="$1"\nmkdir -p "$repo/webviews" "$work/out"\n'
                 + text[start:end]
                 + 'printf "%s\\n" "$browser_lane" "${lane[*]}"\n')
        for uname, lane, installs in (
            ("Darwin", "env -u CMUX_BROWSER_TESTS PLAYWRIGHT_BROWSERS_PATH=/var/empty/cmux-no-playwright-on-macs", False),
            ("Linux", "env CMUX_BROWSER_TESTS=1", True),
        ):
            with self.subTest(uname=uname):
                temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
                script = temp / "probe.sh"
                script.write_text(probe, encoding="utf-8")
                result, ran = self.run_script(script, uname, args=[str(temp / "w")])
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertEqual(ran == ["bun"], installs, (ran, output))
                lines = result.stdout.splitlines()
                self.assertEqual(lines[-1], lane, output)
                if installs:
                    self.assertEqual(lines[-2], "on", output)
                    self.assertNotIn(REFUSAL, output)
                else:
                    self.assertEqual(lines[-2], "off on a Mac", output)
                    self.assertIn(f"TEAM-EVAL browser lane: {REFUSAL}", output)


    def test_ensure_system_chrome_refuses_on_a_mac(self):
        # It must not copy Chrome into /Applications, install it through Playwright, or vouch for a
        # Chrome for Playwright to drive on a Mac, a fleet Mac included.
        for args, status in (([], 1), (["--optional"], 0)):
            with self.subTest(args=args):
                result, ran = self.run_script(ENSURE_CHROME, "Darwin", args=args)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertIn(f"ensure-system-chrome.sh: {REFUSAL}", result.stderr)
                self.assertNotIn("system Chrome", result.stdout)
                self.assertEqual(ran, [])

    def test_ensure_system_chrome_keeps_linux_and_github_actions(self):
        for uname, env in (("Linux", {}), ("Darwin", {"GITHUB_ACTIONS": "true"})):
            with self.subTest(uname=uname, env=env):
                result, ran = self.run_script(ENSURE_CHROME, uname, args=["--optional"], extra_env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn(REFUSAL, result.stdout + result.stderr)

    def test_webviews_preload_refuses_playwright_on_macs(self):
        # Every bun test in webviews loads test/preload.ts: it must refuse Playwright launches on a
        # Mac outside GitHub Actions for every engine, after useSystemChrome (systemChrome.test.ts
        # covers the refusal itself).
        text = PRELOAD.read_text(encoding="utf-8")
        self.assertIn("refusePlaywrightOnMacs([chromium, webkit, firefox]", text)
        self.assertLess(text.index("useSystemChrome("), text.index("refusePlaywrightOnMacs("))

    def test_browser_use_perf_says_how_a_mac_run_must_drive_the_browser(self):
        header = BROWSER_USE_PERF.read_text(encoding="utf-8").split("set -euo pipefail")[0]
        self.assertIn("cmux browser", header)


if __name__ == "__main__":
    unittest.main()
