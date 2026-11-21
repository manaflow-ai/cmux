#!/usr/bin/env python3
"""The API call log names the calls it could not see, and the token hour each gh call drew on.

On 2026-11-21 the repository's self-hosted GITHUB_TOKEN hour ran dry about every hour (15:49, 16:12, 17:28,
18:46, 19:48 and 20:44Z), and the production promote gates read their staging runs from it. A 5-second sampler on
it (ci-token-budget-sampler.yml, run 44946812143) measured about 8,000 calls an hour, but the `gh-call` lines in
174 self-hosted job logs and 76 main gate logs of the same ten minutes named only a few dozen of them. The log
could not see:

- `python3 -I` / `python3 -E` scripts: isolated mode ignores PYTHONPATH, so sitecustomize.py never loaded;
- curl to api.github.com;
- which token hour a gh call drew on: the shim logs no rate-limit headers, and gh shows them only through
  flags that change what the step sees.

env.sh now wraps python3/python and curl in the step shell, and the gh shim reads GET /rate_limit (which costs
no quota) once per token, so every token's calls carry its hour's reset. None of it changes what a step sees.

Run: python3 tests/test_ci_api_call_log_blind_spots.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "scripts" / "ci" / "api_call_log"


def gh_calls(text: str) -> list[list[str]]:
    return [line.split("gh-call\t", 1)[1].split("\t") for line in text.splitlines() if "gh-call\t" in line]


class BlindSpots(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="api-call-log-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.temp = self.root / "runner-temp"
        self.temp.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # A gh that answers `gh api rate_limit` like GitHub and anything else with "ok".
        self.write_exe("gh", """#!/bin/sh
            case "$*" in
              *rate_limit*) printf '4321\\t679\\t1795297923\\n' ;;
              *) echo ok ;;
            esac
            """)
        # A curl that writes GitHub's rate-limit headers where -D asks and prints a body.
        self.write_exe("curl", """#!/bin/sh
            out=""
            while [ $# -gt 0 ]; do
              case "$1" in -D) out=$2; shift ;; esac
              shift
            done
            if [ -n "$out" ]; then
              printf 'HTTP/2 200\\r\\nx-ratelimit-limit: 5000\\r\\nx-ratelimit-remaining: 680\\r\\nx-ratelimit-used: 4320\\r\\nx-ratelimit-reset: 1795297923\\r\\nx-ratelimit-resource: core\\r\\n\\r\\n' > "$out"
            fi
            echo '{"body":true}'
            """)

    def write_exe(self, name: str, text: str) -> None:
        path = self.bin / name
        path.write_text(textwrap.dedent(text))
        path.chmod(0o755)

    def step(self, script: str, *, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        """One `run:` step: bash -e with BASH_ENV at the checkout's env.sh, as the workflows set it. On a host with
        no /proc (macOS) the lines wait in pending.log, printed by the next bash step: this test reads both."""
        env = {k: v for k, v in os.environ.items() if not k.startswith(("API_CALL_LOG", "GITHUB_", "GH_", "PYTHON"))}
        env.update(PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(self.temp),
                   RUNNER_OS="macOS" if sys.platform == "darwin" else "Linux", BASH_ENV=str(LOG / "env.sh"),
                   GITHUB_WORKFLOW="wf", GITHUB_JOB="job", GH_TOKEN="test-token-not-real")
        env.update(extra_env or {})
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script], cwd=self.root,
                              env=env, capture_output=True, text=True, timeout=60)

    def lines(self, done: subprocess.CompletedProcess) -> list[list[str]]:
        pending = self.temp / "api-call-log" / "pending.log"
        return gh_calls(done.stderr + (pending.read_text() if pending.exists() else ""))

    def test_python_in_isolated_mode_gets_the_hook(self) -> None:
        script = self.root / "probe.py"
        script.write_text("import http.client, sys\n"
                          "print('hooked' if getattr(http.client, '_api_call_log_installed', False) else 'bare')\n"
                          "print('argv', sys.argv[1:])\n"
                          "print('main', __name__)\n")
        for flags in ("-I", "-E", "-IB"):
            with self.subTest(flags=flags):
                done = self.step(f"python3 {flags} {script} one 'two words'")
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn("hooked", done.stdout)
                self.assertIn("argv ['one', 'two words']", done.stdout)
                self.assertIn("main __main__", done.stdout)

    def test_isolated_python_keeps_its_exit_code_and_its_stdin(self) -> None:
        script = self.root / "exit.py"
        script.write_text("import sys\nsys.exit(int(sys.stdin.read().strip()))\n")
        done = self.step(f"echo 7 | python3 -I {script} || echo \"exit=$?\"")
        self.assertIn("exit=7", done.stdout)

    def test_isolated_python_module_and_command_modes_get_the_hook(self) -> None:
        done = self.step("python3 -I -c 'import http.client; print(getattr(http.client, \"_api_call_log_installed\", 0))'")
        self.assertEqual(done.stdout.strip(), "True", done.stderr)
        (self.root / "mod_probe.py").write_text("import http.client\nprint(getattr(http.client, '_api_call_log_installed', 0))\n")
        done = self.step(f"cd {self.root} && python3 -E -m mod_probe")
        self.assertEqual(done.stdout.strip(), "True", done.stderr)

    def test_curl_to_the_api_is_named_with_its_token_hour(self) -> None:
        done = self.step("curl -sS -H 'Authorization: Bearer test-token-not-real' "
                         "https://api.github.com/repos/o/r/actions/runs/123?per_page=1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), '{"body":true}')
        (call,) = [c for c in self.lines(done) if "curl" in c[-1]]
        self.assertEqual(call[3:7], ["core", "4320", "680", "1795297923"])
        self.assertTrue(call[-1].startswith("GET /repos/o/r/actions/runs/{n} 200 [curl tok="), call)
        self.assertNotIn("test-token-not-real", done.stderr)

    def test_curl_that_dumps_its_own_headers_keeps_them(self) -> None:
        # The function adds -D only when the caller has none: curl keeps one -D, so theirs would be lost.
        done = self.step(f"curl -sS -D {self.root}/mine.txt https://api.github.com/rate_limit")
        self.assertEqual([c for c in self.lines(done) if "curl" in c[-1]], [])
        self.assertEqual(done.stdout.strip(), '{"body":true}')
        self.assertIn("x-ratelimit-used: 4320", (self.root / "mine.txt").read_text())

    def test_curl_elsewhere_is_not_named(self) -> None:
        done = self.step("curl -sS https://example.com/x")
        self.assertEqual(self.lines(done), [])

    def test_each_gh_token_names_its_hour_once(self) -> None:
        done = self.step("gh api repos/o/r/pulls/1 >/dev/null; gh pr view 1 >/dev/null")
        self.assertEqual(done.returncode, 0, done.stderr)
        calls = self.lines(done)
        buckets = [c for c in calls if "gh-bucket" in c[-1]]
        self.assertEqual(len(buckets), 1, calls)
        self.assertEqual(buckets[0][3:7], ["core", "4321", "679", "1795297923"])
        token = buckets[0][-1].split("tok=", 1)[1].rstrip("]")
        named = [c for c in calls if "gh-bucket" not in c[-1]]
        self.assertEqual(len(named), 2, calls)
        self.assertTrue(all(c[-1].endswith(f"tok={token}]") for c in named), calls)

    def test_the_log_stays_on_through_2026_11_22_and_then_switches_off(self) -> None:
        real_date = shutil.which("date")
        for hour, on in (("2026112213", True), ("2026112300", False)):
            with self.subTest(hour=hour):
                # A date that answers env.sh's `date -u +%Y%m%d%H` with this hour, and anything else as usual.
                self.write_exe("date", f"""#!/bin/sh
                    [ "$*" = "-u +%Y%m%d%H" ] && {{ echo {hour}; exit 0; }}
                    exec {real_date} "$@"
                    """)
                done = self.step("gh api repos/o/r/pulls/1 >/dev/null")
                self.assertEqual(bool([c for c in self.lines(done) if "pulls" in c[-1]]), on, done.stderr)
                shutil.rmtree(self.temp / "api-call-log", ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
