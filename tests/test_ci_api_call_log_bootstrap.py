#!/usr/bin/env python3
"""The API call log loads in a job whose checkout has no copy of it, and leaves a job alone when it cannot load.

On 2026-11-21 the repository's GITHUB_TOKEN hour spent about 8,800 calls an hour (ci-token-budget-sampler.yml, 5-s
samples), and the `gh-call` lines of every job that finished in 22:15-22:30Z named a few hundred. Of the 512 jobs in
those 294 runs, 307 set BASH_ENV to ${GITHUB_WORKSPACE}/scripts/ci/api_call_log/env.sh, but 149 checked out a sparse
tree without that file and 46 checked out nothing, so bash read no file and their calls went unnamed (only 112 jobs,
22%, could log). Every workflow now sets BASH_ENV to one command substitution, which bash expands when each step's
shell starts: the checkout's env.sh when it is there; else the same files at a fixed commit, fetched once a job from
raw.githubusercontent.com (no API call, no token); else a file that unsets BASH_ENV, so a step that appends to
"$BASH_ENV" (scripts/install-rust-ci.sh) skips it, as it does when env.sh switches off.

This test runs each distinct BASH_ENV value the workflows set, in bash -e steps, with a fake curl that serves the
checkout's files.

Run: python3 tests/test_ci_api_call_log_bootstrap.py
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

import yaml

ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "scripts" / "ci" / "api_call_log"
WORKFLOWS = ROOT / ".github" / "workflows"


def bash_env_values() -> dict[str, list[str]]:
    """Each distinct top-level BASH_ENV value of the workflows, with the files that set it."""
    out: dict[str, list[str]] = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(path.read_text())
        value = ((doc or {}).get("env") or {}).get("BASH_ENV") if isinstance(doc, dict) else None
        if value:
            out.setdefault(str(value), []).append(path.name)
    return out


def gh_calls(text: str) -> list[list[str]]:
    return [line.split("gh-call\t", 1)[1].split("\t") for line in text.splitlines() if "gh-call\t" in line]


class Bootstrap(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="api-call-log-boot-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.workspace = self.root / "work"
        self.workspace.mkdir()
        self.temp = self.root / "runner-temp"
        self.temp.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.curl_log = self.root / "curl.log"
        self.write_exe("gh", """#!/bin/sh
            case "$*" in
              *rate_limit*) printf '4321\\t679\\t1795297923\\n' ;;
              *) echo ok ;;
            esac
            """)
        # Serves raw.githubusercontent.com/manaflow-ai/cmux/<sha>/scripts/ci/api_call_log/<file> from this checkout,
        # logs each fetch, and fails every fetch while $CURL_FAIL is set.
        self.write_exe("curl", f"""#!/bin/sh
            out=""; url=""
            while [ $# -gt 0 ]; do
              case "$1" in -o) out=$2; shift ;; https://*) url=$1 ;; esac
              shift
            done
            echo "$url" >> {self.curl_log}
            [ -z "${{CURL_FAIL:-}}" ] || exit 22
            case "$url" in
              https://raw.githubusercontent.com/manaflow-ai/cmux/*/scripts/ci/api_call_log/*) ;;
              *) exit 22 ;;
            esac
            cp "{LOG}/${{url##*/}}" "$out"
            """)
        values = bash_env_values()
        self.assertTrue(values, "no workflow sets BASH_ENV")
        self.values = values

    def write_exe(self, name: str, text: str) -> None:
        path = self.bin / name
        path.write_text(textwrap.dedent(text))
        path.chmod(0o755)

    def step(self, value: str, script: str, *, bash: str = "bash", extra_env: dict[str, str] | None = None
             ) -> subprocess.CompletedProcess:
        """One `run:` step as the runner starts it: bash -e with the workflow's BASH_ENV, before any expansion."""
        env = {k: v for k, v in os.environ.items() if not k.startswith(("API_CALL_LOG", "GITHUB_", "GH_", "PYTHON"))}
        env.update(PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(self.temp),
                   RUNNER_OS="macOS" if sys.platform == "darwin" else "Linux", BASH_ENV=value,
                   GITHUB_WORKSPACE=str(self.workspace), GITHUB_WORKFLOW="wf", GITHUB_JOB="job",
                   GH_TOKEN="test-token-not-real")
        env.update(extra_env or {})
        return subprocess.run([bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", script], cwd=self.workspace,
                              env=env, capture_output=True, text=True, timeout=60)

    def lines(self, *done: subprocess.CompletedProcess) -> list[list[str]]:
        pending = self.temp / "api-call-log" / "pending.log"
        return gh_calls("".join(d.stderr for d in done) + (pending.read_text() if pending.exists() else ""))

    def fetches(self) -> list[str]:
        return self.curl_log.read_text().splitlines() if self.curl_log.exists() else []

    def reset(self) -> None:
        for path in list(self.temp.iterdir()) + list(self.workspace.iterdir()):
            shutil.rmtree(path) if path.is_dir() else path.unlink()
        self.curl_log.unlink(missing_ok=True)

    def each_value(self, check) -> None:
        """Runs check(value) for each distinct BASH_ENV value, from a clean runner temp and workspace."""
        for value, files in self.values.items():
            with self.subTest(files=files[:3], count=len(files)):
                self.reset()
                check(value)

    def test_a_sparse_checkout_fetches_the_log_once_and_names_every_call(self) -> None:
        def check(value: str) -> None:
            first = self.step(value, "gh api repos/o/r/pulls/1 >/dev/null")
            second = self.step(value, "gh pr view 1 >/dev/null")
            self.assertEqual((first.returncode, second.returncode), (0, 0), first.stderr + second.stderr)
            named = [c for c in self.lines(first, second) if "gh-bucket" not in c[-1]]
            self.assertEqual(len(named), 2, first.stderr + second.stderr)
            self.assertEqual(len(self.fetches()), 4, self.fetches())
            self.assertTrue(all("/manaflow-ai/cmux/" in url for url in self.fetches()))
        self.each_value(check)

    def test_a_full_checkout_uses_its_own_copy_and_fetches_nothing(self) -> None:
        def check(value: str) -> None:
            shutil.copytree(LOG, self.workspace / "scripts" / "ci" / "api_call_log")
            done = self.step(value, "gh api repos/o/r/pulls/1 >/dev/null")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(len([c for c in self.lines(done) if "pulls" in c[-1]]), 1, done.stderr)
            self.assertEqual(self.fetches(), [])
        self.each_value(check)

    def test_a_failed_fetch_tries_once_and_leaves_the_steps_as_they_were(self) -> None:
        script = 'echo out; [ -z "${BASH_ENV:-}" ] && echo "no BASH_ENV"; gh api repos/o/r/pulls/1'
        def check(value: str) -> None:
            first = self.step(value, script, extra_env={"CURL_FAIL": "1"})
            second = self.step(value, script, extra_env={"CURL_FAIL": "1"})
            for done in (first, second):
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(done.stdout.splitlines(), ["out", "no BASH_ENV", "ok"])
                self.assertEqual(done.stderr, "")
            self.assertEqual(len(self.fetches()), 1, self.fetches())
        self.each_value(check)

    def test_after_the_log_switches_off_nothing_is_fetched_or_named(self) -> None:
        real_date = shutil.which("date")
        self.write_exe("date", f"""#!/bin/sh
            [ "$*" = "-u +%Y%m%d%H" ] && {{ echo 2026112300; exit 0; }}
            exec {real_date} "$@"
            """)
        def check(value: str) -> None:
            done = self.step(value, '[ -z "${BASH_ENV:-}" ] && echo "no BASH_ENV"; gh api repos/o/r/pulls/1')
            self.assertEqual(done.stdout.splitlines(), ["no BASH_ENV", "ok"], done.stderr)
            self.assertEqual(self.fetches(), [])
            self.assertEqual(self.lines(done), [])
        self.each_value(check)

    def test_macos_system_bash_reads_it_without_a_word(self) -> None:
        # The Mac minis' /bin/bash is 3.2, which cannot parse a `case` inside $( ).
        if not Path("/bin/bash").exists():
            self.skipTest("no /bin/bash")
        def check(value: str) -> None:
            done = self.step(value, "gh api repos/o/r/pulls/1 >/dev/null; echo done", bash="/bin/bash")
            self.assertEqual((done.returncode, done.stdout.strip()), (0, "done"), done.stderr)
            self.assertNotIn("syntax error", done.stderr)
            self.assertEqual(len([c for c in self.lines(done) if "pulls" in c[-1]]), 1, done.stderr)
        self.each_value(check)


if __name__ == "__main__":
    unittest.main()
