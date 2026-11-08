"""Execute the review rerun step with a fake API; no GitHub access or waits."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-defaults-guard-review.yml"
HEAD = "a" * 40
BASE = "c" * 40
REPO = "example/cmux"


def rerun_script():
    source = WORKFLOW.read_text()
    step = source.split("      - name: Re-run the trusted defaults guard\n", 1)[1]
    body = step.split("        run: |\n", 1)[1]
    lines = []
    for line in body.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines)


def receipt_script():
    source = WORKFLOW.read_text()
    step = source.split("      - name: Resolve an exact-head SHIP receipt comment\n", 1)[1]
    body = step.split("        run: |\n", 1)[1].split("      - name: Accept a pull-request review", 1)[0]
    lines = []
    for line in body.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines)


class Rerun(unittest.TestCase):
    def invoke(self, status="completed", *, missing=False, error="", post_error=False):
        self.assertIsNotNone(shutil.which("jq"), "this shell harness needs jq")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls.jsonl"
            gh = root / "gh"
            gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, subprocess, sys
                args = sys.argv[1:]
                with open(os.environ["CALL_LOG"], "a") as log:
                    log.write(json.dumps(args) + "\\n")
                if args[:1] != ["api"]:
                    sys.exit("only bounded API requests are allowed")
                endpoint = next((arg for arg in args if arg.startswith("repos/")), "")
                if "/actions/workflows/" in endpoint:
                    if os.environ["API_ERROR"]:
                        sys.exit(os.environ["API_ERROR"])
                    query = args[args.index("--jq") + 1]
                    result = subprocess.run(["jq", "-r", query], input=os.environ["RUNS"], text=True)
                    sys.exit(result.returncode)
                if args[1:3] == ["-X", "POST"] and endpoint.endswith("/runs/123/rerun"):
                    sys.exit(1 if os.environ["POST_ERROR"] == "1" else 0)
                sys.exit("unexpected API read or mutation: " + repr(args))
                '''))
            gh.chmod(0o755)
            runs = [] if missing else [{"id": 123, "status": status}]
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "REPO": REPO, "HEAD_SHA": HEAD, "CALL_LOG": str(log),
                   "RUNS": json.dumps({"workflow_runs": runs}), "API_ERROR": error,
                   "POST_ERROR": "1" if post_error else "0"}
            result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", rerun_script()],
                                    env=env, text=True, capture_output=True, timeout=5)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertIn(f"head_sha={HEAD}&", calls[0][1])
        return result, calls

    def test_completed_run_is_rerun_with_one_read(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2, calls)
        self.assertEqual(calls[1], ["api", "-X", "POST", f"repos/{REPO}/actions/runs/123/rerun"])

    def test_active_run_is_not_polled_or_rerun(self):
        for status in ("queued", "in_progress", "pending", "waiting", "requested"):
            with self.subTest(status=status):
                result, calls = self.invoke(status)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 1, calls)

    def test_missing_run_is_a_noop(self):
        result, calls = self.invoke(missing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_missing_endpoint_is_a_noop(self):
        result, calls = self.invoke(error="gh: HTTP 404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_read_errors_are_not_retried_or_treated_as_missing(self):
        for error in ("gh: HTTP 403 API rate limit exceeded for installation", "gh: HTTP 500"):
            with self.subTest(error=error):
                result, calls = self.invoke(error=error)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_rerun_failure_is_reported(self):
        result, calls = self.invoke(post_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2, calls)

    def invoke_receipt(self, event):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls.jsonl"
            event_path = root / "event.json"
            event_path.write_text(json.dumps(event))
            gh = root / "gh"
            gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import os, sys
                with open(os.environ["CALL_LOG"], "a") as log:
                    log.write("called\\n")
                sys.exit("API should not be called for an ineligible event")
                '''))
            gh.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "EVENT_PATH": str(event_path), "REPO": REPO, "PR_NUMBER": "7",
                   "COMMENT_ID": "8", "GITHUB_OUTPUT": str(output), "CALL_LOG": str(log)}
            result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", receipt_script()],
                                    env=env, text=True, capture_output=True, timeout=5)
            calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def test_irrelevant_comment_is_rejected_before_api_read(self):
        event = {"comment": {"body": "Thanks!", "author_association": "MEMBER"}}
        result, calls = self.invoke_receipt(event)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def invoke_authoritative(self, *, event_association="MEMBER", fetched_association="MEMBER", fetched_head=HEAD,
                             login="reviewer", user_type="User", owners=None, git_fails=False):
        event = {"comment": {"body": f"Review (router): SHIP at {HEAD}\nEvidence: focused checks passed", "author_association": event_association}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_path = root / "event.json"
            event_path.write_text(json.dumps(event))
            log = root / "calls.jsonl"
            gh = root / "gh"
            gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import os, sys
                args = sys.argv[1:]
                with open(os.environ["CALL_LOG"], "a") as log:
                    log.write("called\\n")
                endpoint = next(arg for arg in args if arg.startswith("repos/"))
                if "/contents/" in endpoint or "/collaborators/" in endpoint:
                    sys.exit("the owners file is read with git, never the API: " + endpoint)
                if "/pulls/" in endpoint:
                    print(os.environ["PR_RESPONSE"])
                elif "/issues/comments/" in endpoint:
                    print(os.environ["COMMENT_RESPONSE"])
                else:
                    sys.exit("unexpected API endpoint")
                '''))
            gh.chmod(0o755)
            # A fake git: the owners file at BASE, served from OWNERS_JSON; no network.
            git_log = root / "git.jsonl"
            git = root / "git"
            git.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, sys
                args = sys.argv[1:]
                with open(os.environ["GIT_LOG"], "a") as log:
                    log.write(json.dumps(args) + "\\n")
                if os.environ["GIT_FAILS"] == "1" and "fetch" in args:
                    sys.exit("fatal: unable to access")
                if "show" in args:
                    if args[-1] != os.environ["BASE"] + ":.github/defaults-call-owners.json":
                        sys.exit("unexpected show: " + args[-1])
                    print(os.environ["OWNERS_JSON"])
                '''))
            git.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "EVENT_PATH": str(event_path), "REPO": REPO, "PR_NUMBER": "7",
                   "COMMENT_ID": "8", "GITHUB_OUTPUT": str(output), "CALL_LOG": str(log),
                   "GIT_LOG": str(git_log), "GIT_FAILS": "1" if git_fails else "0", "BASE": BASE,
                   "OWNERS_JSON": json.dumps({"cmux-next": owners if owners is not None else ["Lawrencecchen"]}),
                   "PR_RESPONSE": json.dumps({"base": {"ref": "feat-cmux-next", "sha": BASE},
                                              "head": {"repo": {"full_name": REPO}, "sha": fetched_head}}),
                   "COMMENT_RESPONSE": json.dumps({"author_association": fetched_association,
                                                   "user": {"login": login, "type": user_type},
                                                   "body": event["comment"]["body"]})}
            result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", receipt_script()],
                                    env=env, text=True, capture_output=True, timeout=5)
            calls = log.read_text().splitlines()
            output_text = output.read_text() if output.exists() else ""
            self.git_calls = [json.loads(line) for line in git_log.read_text().splitlines()] if git_log.exists() else []
        return result, calls, output_text

    def test_valid_receipt_reaches_authoritative_api_checks(self):
        result, calls, output = self.invoke_authoritative()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["called", "called"])
        self.assertIn("eligible=true", output)
        self.assertIn(f"head_sha={HEAD}", output)

    def test_fetched_untrusted_author_is_still_rejected(self):
        result, calls, output = self.invoke_authoritative(fetched_association="CONTRIBUTOR")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["called", "called"])
        self.assertNotIn("eligible=true", output)

    def test_a_call_owner_who_reads_as_contributor_wakes_the_guard(self):
        # #32979, #33111: a private org member reads as CONTRIBUTOR; their SHIP left the guard red until a manual
        # re-run. The owners file at the base commit trusts them, read with git (no API quota), case-insensitive.
        result, calls, output = self.invoke_authoritative(fetched_association="CONTRIBUTOR", login="lawrencecchen")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["called", "called"])
        self.assertIn("eligible=true", output)
        self.assertIn(["show", f"{BASE}:.github/defaults-call-owners.json"], [c[-2:] for c in self.git_calls])

    def test_a_contributor_who_is_no_call_owner_is_still_rejected(self):
        for kwargs in ({"login": "outsider"}, {"login": "lawrencecchen", "user_type": "Bot"},
                       {"login": "lawrencecchen", "owners": []}, {"login": "lawrencecchen", "git_fails": True},
                       {"login": ""}):
            with self.subTest(**kwargs):
                result, calls, output = self.invoke_authoritative(fetched_association="CONTRIBUTOR", **kwargs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("eligible=true", output)

    def test_a_member_receipt_needs_no_owners_read(self):
        result, calls, output = self.invoke_authoritative()
        self.assertIn("eligible=true", output)
        self.assertEqual(self.git_calls, [])

    def test_fetched_stale_head_is_still_rejected(self):
        result, calls, output = self.invoke_authoritative(fetched_head="b" * 40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["called", "called"])
        self.assertNotIn("eligible=true", output)

    def test_event_association_does_not_replace_api_authority(self):
        result, calls, output = self.invoke_authoritative(event_association="CONTRIBUTOR")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["called", "called"])
        self.assertIn("eligible=true", output)


if __name__ == "__main__":
    unittest.main()
