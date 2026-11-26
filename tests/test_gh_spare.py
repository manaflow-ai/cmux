#!/usr/bin/env python3
"""scripts/ci/gh-spare: a workflow's own failure report runs gh through it, so the report outlives an exhausted token.

Runs 45548650589 and 45551813915 (2026-11-25) failed, and their failure report died on "API rate limit exceeded for
installation": about ten failed nightlies paged nobody. These run gh-spare against a fake gh on PATH.
"""
from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
GH_SPARE = ROOT / "scripts/ci/gh-spare"

# The fake gh: TOKENS_DRY lists tokens GitHub refuses for the rate limit, TOKENS_DENIED tokens it refuses otherwise;
# `gh api rate_limit` answers RESET for an exhausted core. Every call is logged as "<token> <args>".
FAKE_GH = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "${GH_TOKEN:-none} $*" >> "$LOG"
    if [ "$1" = api ] && [ "$2" = rate_limit ]; then echo "${RESET:-0}"; exit 0; fi
    if [ -f "$DRY_UNTIL_FILE" ] && [ "$(cat "$DRY_UNTIL_FILE")" -gt 0 ]; then
      n="$(cat "$DRY_UNTIL_FILE")"; echo $((n - 1)) > "$DRY_UNTIL_FILE"
      echo "HTTP 403: API rate limit exceeded for installation ID 1." >&2; exit 1
    fi
    case " ${TOKENS_DRY:-} " in *" ${GH_TOKEN:-none} "*) echo "HTTP 403: API rate limit exceeded for installation ID 1." >&2; exit 1 ;; esac
    case " ${TOKENS_DENIED:-} " in *" ${GH_TOKEN:-none} "*) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;; esac
    if [ "${FAIL_404:-}" = 1 ]; then echo "HTTP 404: Not Found" >&2; exit 1; fi
    echo "ok from ${GH_TOKEN:-none}"
    """)


class GhSpareTest(unittest.TestCase):
    def run_spare(self, *args: str, **env: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            sleeper = bin_dir / "sleep"  # a wait is recorded, not slept
            sleeper.write_text('#!/usr/bin/env bash\necho "slept $1" >> "$LOG"\n')
            sleeper.chmod(sleeper.stat().st_mode | stat.S_IEXEC)
            log = Path(tmp) / "log"
            summary = Path(tmp) / "summary"
            full_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "LOG": str(log), "GITHUB_STEP_SUMMARY": str(summary),
                        "DRY_UNTIL_FILE": str(Path(tmp) / "dry"), "HOME": tmp, **env}
            if "DRY_CALLS" in env:
                (Path(tmp) / "dry").write_text(env["DRY_CALLS"])
            proc = subprocess.run(["bash", str(GH_SPARE), *args], env=full_env, capture_output=True, text=True, timeout=60)
            lines = log.read_text().splitlines() if log.exists() else []
            if summary.exists():
                proc.summary = summary.read_text()  # type: ignore[attr-defined]
            return proc, lines

    def test_job_token_answers_with_no_spare_used(self):
        proc, calls = self.run_spare("issue", "list", GH_TOKEN="job", GH_SPARE_TOKENS="bot route")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "ok from job")
        self.assertEqual(calls, ["job issue list"])

    def test_rate_limited_job_token_goes_to_a_spare(self):
        proc, calls = self.run_spare("issue", "create", "--title", "T", GH_TOKEN="job", GH_SPARE_TOKENS="bot route",
                                     TOKENS_DRY="job")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "ok from bot")
        self.assertEqual(calls, ["job issue create --title T", "bot issue create --title T"])
        self.assertIn("spare token 1", proc.stderr)

    def test_a_spare_without_permission_is_skipped(self):
        proc, calls = self.run_spare("issue", "comment", "5", GH_TOKEN="job", GH_SPARE_TOKENS="bot route",
                                     TOKENS_DRY="job", TOKENS_DENIED="bot")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "ok from route")
        self.assertIn("could not run gh issue comment", proc.stderr)

    def test_other_errors_are_ghs_own_at_once(self):
        proc, calls = self.run_spare("issue", "view", "9", GH_TOKEN="job", GH_SPARE_TOKENS="bot", FAIL_404="1")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("HTTP 404", proc.stderr)
        self.assertEqual(calls, ["job issue view 9"])

    def test_every_token_dry_waits_for_the_reset_then_goes_again(self):
        # Three refused calls (job, bot, route), then GitHub answers.
        proc, calls = self.run_spare("issue", "list", GH_TOKEN="job", GH_SPARE_TOKENS="bot route", DRY_CALLS="3",
                                     RESET="0", GH_SPARE_WAIT_SECONDS="600")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "ok from job")
        self.assertTrue(any(c.startswith("slept ") for c in calls), calls)
        self.assertIn("every token is rate limited", proc.stderr)

    def test_past_the_wait_the_report_is_an_error_annotation_and_a_summary(self):
        proc, _calls = self.run_spare("issue", "create", "--title", "nightly failed", GH_TOKEN="job",
                                      GH_SPARE_TOKENS="bot", TOKENS_DRY="job bot", GH_SPARE_WAIT_SECONDS="0",
                                      GH_SPARE_REPORT="cmux NIGHTLY run 1 failed")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error title=Failure report not delivered", proc.stderr)
        self.assertIn("cmux NIGHTLY run 1 failed", proc.stderr)
        self.assertIn("cmux NIGHTLY run 1 failed", getattr(proc, "summary", ""))


if __name__ == "__main__":
    unittest.main()
