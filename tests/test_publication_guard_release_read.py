"""The publish job's release read goes through gh (own User-Agent, token, retries), never a bare urlopen.

Run 45868119309 (classic nightly resume, 2026-11-26) died there on a bare "HTTP Error 403: Forbidden" with no reason.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"
SHA = "a" * 40


def guard_script() -> str:
    text = WORKFLOW.read_text()
    match = re.search(r"python3 - \"\$GITHUB_REPOSITORY\".*?<<'PY' > \"\$RUNNER_TEMP/publication-guard\"\n(.*?)\n\s*PY\n", text, re.S)
    assert match, "publication guard heredoc not found"
    return "\n".join(line[10:] if line.startswith(" " * 10) else line for line in match.group(1).splitlines())


class PublicationGuardTests(unittest.TestCase):
    def run_guard(self, behaviour: str, timeout: int = 3900):
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp, "gh")
            gh.write_text(f"#!/bin/sh\n{behaviour}\n")
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            counter = Path(tmp, "n")
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "COUNTER": str(counter)}
            script = guard_script().replace("time.sleep(10 * (attempt + 1))", "pass").replace("timeout=3900", f"timeout={timeout}")
            result = subprocess.run([sys.executable, "-I", "-c", script, "o/r", "nightly", SHA, "5"],
                                    capture_output=True, text=True, env=env)
            self.runs = int(counter.read_text()) if counter.exists() else 0
            return result

    def test_no_bare_urlopen(self):
        self.assertNotIn("urlopen", guard_script())

    def test_missing_release_is_reported(self):
        r = self.run_guard('echo "gh: Not Found (HTTP 404)" >&2; exit 1')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "release_missing=true"))

    def test_transient_403_is_retried_then_read(self):
        body = '{"body": "<!-- cmux-published-sha: %s -->"}' % SHA
        r = self.run_guard('n=$(cat "$COUNTER" 2>/dev/null || echo 0); echo $((n+1)) > "$COUNTER"; '
                           'if [ "$n" = 0 ]; then echo "gh: Forbidden (HTTP 403)" >&2; exit 1; fi; '
                           f"echo '{body}'")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("already_published=true", r.stdout)

    def test_a_gh_timeout_is_retried_not_raised(self):
        body = '{"body": ""}'
        r = self.run_guard('n=$(cat "$COUNTER" 2>/dev/null || echo 0); echo $((n+1)) > "$COUNTER"; '
                           'if [ "$n" = 0 ]; then sleep 5; fi; '
                           f"echo '{body}'", timeout=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs, 2, "the timed-out gh call must be retried once")

    def test_a_timeout_keeps_the_refusal_gh_printed_first(self):
        r = self.run_guard('echo "gh: API rate limit exceeded (HTTP 403)" >&2; sleep 5', timeout=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rate limit exceeded", r.stderr)

    def test_persistent_403_fails_with_the_reason(self):
        r = self.run_guard('echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rate limit exceeded", r.stderr)


if __name__ == "__main__":
    unittest.main()
