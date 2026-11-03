#!/usr/bin/env python3
"""Playwright's Chromium runs as the system Google Chrome, never Playwright's bundled build.

Every Playwright release up to 1.64.1 bundles a Chromium older than 156.0.8078.73 (1.62.1, the one
webviews pins, bundles 151.0.7922.34), so it lacks the fixes for CVE-2026-118306, -118331, -118348
and -118344, and Playwright turns the Chromium sandbox off by default. Until a Playwright release
bundles 156.0.8078.73 or later, tests, benches and scripts launch Chromium with channel "chrome"
(the installed, auto-updating Google Chrome) and no workflow or script downloads the bundled one.
"""

import os
import pathlib
import re
import subprocess
import tempfile
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

# A launch of Playwright's Chromium: chromium.launch(...) or chromium.launchPersistentContext(...).
LAUNCH = re.compile(r"chromium\s*\.\s*(launch|launchPersistentContext)\s*\(")
# A launch through an engine picked at run time: browserTypes[engine].launch(...), engine.launch(...).
DYNAMIC_LAUNCH = re.compile(r"(\]|\bengine)\s*\.\s*launch\s*\(")
# `playwright install` naming the bundled chromium (or its headless shell) engine.
INSTALL_CHROMIUM = re.compile(r"playwright\s+install\b[^\n]*?\bchromium(-headless-shell)?\b")


def tracked(*pathspecs: str) -> list[pathlib.Path]:
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", *pathspecs], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    return [ROOT / p for p in out.split("\0") if p and "node_modules/" not in p and (ROOT / p).is_file()]


def call_args(text: str, open_paren: int) -> str:
    """The text between a call's parentheses (balanced, string contents ignored only roughly)."""
    depth = 0
    for i in range(open_paren, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : i]
    return text[open_paren + 1 :]


class SystemChromeTests(unittest.TestCase):
    def test_no_bundled_chromium_install(self):
        offenders = []
        for path in tracked(".github", "scripts", "webviews/scripts", "webviews/package.json", "tests", "web/package.json"):
            if path.suffix not in {".yml", ".yaml", ".sh", ".ts", ".mjs", ".js", ".json", ".md", ".py"}:
                continue
            if path.name == pathlib.Path(__file__).name:
                continue
            for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if INSTALL_CHROMIUM.search(line):
                    offenders.append(f"{path.relative_to(ROOT)}:{n}: {line.strip()}")
        self.assertEqual(offenders, [], "install `chrome` (system Google Chrome), not Playwright's chromium")

    def test_launches_outside_preload_name_system_chrome(self):
        offenders = []
        for path in tracked("*.ts", "*.tsx", "*.mjs", "*.js", "*.yml"):
            rel = path.relative_to(ROOT).as_posix()
            # webviews' bun tests get channel "chrome" from test/preload.ts (useSystemChrome).
            if rel.startswith("webviews/test/"):
                continue
            text = path.read_text(errors="replace")
            for m in [*LAUNCH.finditer(text), *DYNAMIC_LAUNCH.finditer(text)]:
                args = call_args(text, m.end() - 1)
                if "channel" not in args and "executablePath" not in args:
                    line = text.count("\n", 0, m.start()) + 1
                    offenders.append(f"{rel}:{line}")
        self.assertEqual(offenders, [], 'pass channel: "chrome" to every Chromium launch')

    def test_webviews_preload_defaults_chromium_to_system_chrome(self):
        preload = (ROOT / "webviews/test/preload.ts").read_text()
        self.assertIn("useSystemChrome", preload)
        helper = (ROOT / "webviews/test/support/systemChrome.ts").read_text()
        self.assertIn('channel: "chrome"', helper)

    def test_web_playwright_configs_use_system_chrome(self):
        for config in tracked("web/playwright*.config.ts"):
            self.assertRegex(config.read_text(), r"channel:\s*\"chrome\"", config.name)

    def test_gallery_head_and_base_receive_the_same_resolved_browser(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/gallery-health.yml").read_text())
        steps = workflow["jobs"]["health"]["steps"]
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            for folder in ("webviews", "scripts/ci", "scripts/gallery-matrix", "bin"):
                (work / folder).mkdir(parents=True)
            browser = str(work / "resolved chrome-headless-shell")
            env_file, launches = work / "env", work / "launches"
            env_file.touch()
            stubs = {
                "scripts/ci/ensure-system-chrome.sh":
                    '#!/bin/sh\nprintf "CMUX_CHROME_HEADLESS_SHELL=%s\\n" "$TEST_BROWSER" >> "$GITHUB_ENV"\n',
                "bin/git": '#!/bin/sh\nprintf "%s\\n" "$GITHUB_WORKSPACE"\n',
                "bin/bun": '#!/bin/sh\nif [ "$1" = health.ts ]; then\n'
                    '  printf "%s\\n" "${CMUX_CHROME_HEADLESS_SHELL:-chrome}" >> "$TEST_LAUNCHES"\nfi\n',
            }
            for name, contents in stubs.items():
                script = work / name
                script.write_text(contents)
                script.chmod(0o755)
            env = {
                "PATH": str(work / "bin") + os.pathsep + os.defpath,
                "GITHUB_WORKSPACE": str(work), "GITHUB_ENV": str(env_file),
                "RUNNER_TEMP": str(work), "TEST_BROWSER": browser, "TEST_LAUNCHES": str(launches),
                "ALL": "true", "IDS": "", "SHARD": "0", "pass": "1",
            }
            render = next(entry for entry in steps if entry.get("id") == "render")
            for entry in steps:
                script = entry.get("run", "")
                if "ensure-system-chrome.sh" not in script and "bun health.ts" not in script:
                    continue
                if "ensure-system-chrome.sh" in script:
                    self.assertEqual(entry.get("if"), render.get("if"))
                if "git restore" in script:
                    # Only execute the base browser invocation; classification and rebuilding
                    # do not select the executable. Keep its real command and arguments.
                    script = re.search(r"(?m)^\s*bun health\.ts[^\n]*(?:\\\n[^\n]*)*", script).group()
                subprocess.run(["bash", "-euc", script], cwd=work, env=env,
                               check=True, capture_output=True, text=True)
                # Actions imports GITHUB_ENV between steps, never into the writer's shell.
                env.update(line.split("=", 1) for line in env_file.read_text().splitlines())
            self.assertEqual(launches.read_text().splitlines(), [browser, browser])


if __name__ == "__main__":
    unittest.main()
