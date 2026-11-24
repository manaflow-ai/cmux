#!/usr/bin/env python3
"""scripts/cmux-next/hot-verify-pr.sh reads the pull request without waiting out a spent REST hour.

A fake `gh` on PATH answers the REST read, the GraphQL read, or refuses either for the rate limit. Cases: REST
answers (no GraphQL call); REST refused for the rate limit and GraphQL answers (same outputs, no waiting REST
call); both refused (the waiting REST read runs, as before); REST fails for another reason (no GraphQL, the
waiting read runs and its failure fails the step).
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/hot-verify-pr.sh"
HEAD = "a" * 40
MERGE = "b" * 40
REPO = "manaflow-ai/cmux"

FAKE_GH = textwrap.dedent(r"""
    #!/bin/bash
    # Fake gh: logs each call with GH_BUDGET_WAIT_ATTEMPTS, then answers per FAKE_REST / FAKE_GRAPHQL.
    echo "attempts=${GH_BUDGET_WAIT_ATTEMPTS:-unset} $1 $2" >> "$FAKE_LOG"
    kind=rest
    [ "$2" = graphql ] && kind=graphql
    mode="$FAKE_REST"
    [ "$kind" = graphql ] && mode="$FAKE_GRAPHQL"
    # The last call (no GH_BUDGET_WAIT_ATTEMPTS) is the waiting read: it answers when FAKE_WAITED is ok.
    if [ "$kind" = rest ] && [ -z "${GH_BUDGET_WAIT_ATTEMPTS:-}" ]; then mode="$FAKE_WAITED"; fi
    case "$mode" in
      ok)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FAKE_REPO" "$FAKE_HEAD" feat-cmux-next open false - - ;;
      limit) echo "gh: API rate limit exceeded for installation ID 1. (HTTP 403)" >&2; exit 1 ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
""").lstrip()


class HotVerifyPrRead(unittest.TestCase):
    def run_script(self, rest: str, graphql: str, waited: str = "ok"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            gh = tmp_path / "bin/gh"
            gh.parent.mkdir()
            gh.write_text(FAKE_GH)
            gh.chmod(0o755)
            out, summary, log = tmp_path / "out", tmp_path / "summary", tmp_path / "log"
            env = {
                **os.environ,
                "PATH": f"{gh.parent}{os.pathsep}{os.environ['PATH']}",
                "PR": "123", "HEAD_SHA": HEAD, "LAYERS": "web,rust", "GITHUB_REPOSITORY": REPO,
                "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary), "FAKE_LOG": str(log),
                "FAKE_REST": rest, "FAKE_GRAPHQL": graphql, "FAKE_WAITED": waited,
                "FAKE_REPO": REPO, "FAKE_HEAD": HEAD,
            }
            env.pop("GH_BUDGET_WAIT_ATTEMPTS", None)
            proc = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
            read = lambda p: p.read_text() if p.exists() else ""  # noqa: E731
            return proc, read(out), read(log).splitlines(), read(summary)

    def test_rest_answers_without_graphql(self):
        proc, out, calls, _ = self.run_script("ok", "fail")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ok=true", out)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("attempts=1 api repos/"), calls)

    def test_rate_limited_rest_reads_graphql_and_never_waits(self):
        proc, out, calls, summary = self.run_script("limit", "ok", waited="fail")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ok=true", out)
        self.assertIn(f"pr_head={HEAD}", out)
        self.assertEqual([c.split()[0:3] for c in calls],
                         [["attempts=1", "api", f"repos/{REPO}/pulls/123"], ["attempts=1", "api", "graphql"]])
        self.assertIn("over GraphQL", summary)

    def test_both_refused_falls_back_to_the_waiting_read(self):
        proc, out, calls, _ = self.run_script("limit", "limit")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ok=true", out)
        self.assertEqual(len(calls), 3)
        self.assertTrue(calls[2].startswith("attempts=unset api repos/"), calls)

    def test_other_rest_failure_skips_graphql_and_fails_like_before(self):
        proc, out, calls, _ = self.run_script("fail", "ok", waited="fail")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(out, "")
        self.assertEqual(len(calls), 2)
        self.assertNotIn("graphql", " ".join(calls))


if __name__ == "__main__":
    sys.exit(unittest.main())
