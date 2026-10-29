"""merge_freeze.py: a freeze is an open, owned, expiring merge-freeze issue, and only its owner's
freeze-ok label lets a pull request through."""
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_freeze", ROOT / "scripts/ci/merge_freeze.py")
freeze = importlib.util.module_from_spec(spec)
sys.modules["merge_freeze"] = freeze  # dataclasses looks the module up by name
spec.loader.exec_module(freeze)

NOW = datetime.now(timezone.utc)


def stamp(when: datetime) -> str:
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def issue(number=7, body="", author="lawrence", created=None, labels=("merge-freeze",), title="Cut 0.70",
          labeled_by="lawrence", labeler_role="admin", labeled_at=None, last_edited_at=None):
    created = created or NOW - timedelta(hours=1)
    return {
        "labeled_by": labeled_by,
        "labeler_role": labeler_role,
        "labeled_at": labeled_at or stamp(created),
        "last_edited_at": last_edited_at,
        "number": number,
        "title": title,
        "user": {"login": author},
        "created_at": stamp(created),
        "body": body,
        "state": "open",
        "labels": [{"name": name} for name in labels],
    }


def body(paths="cmux-tui/crates/acpmux/ cmux-tui/spec/", expires=None, extra=""):
    expires = expires or stamp(NOW + timedelta(hours=4))
    return f"paths: {paths}\nexpires: {expires}\n{extra}"


def labeled(actor, name="freeze-ok", event="labeled"):
    return {"event": event, "label": {"name": name}, "actor": {"login": actor}}


class FreezeTests(unittest.TestCase):
    def check(self, issues, files, events=(), base="feat-cmux-next"):
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name, content in (("issues", issues), ("events", list(events))):
                paths[name] = Path(directory) / f"{name}.json"
                paths[name].write_text(json.dumps(content))
            paths["files"] = Path(directory) / "files.txt"
            paths["files"].write_text("\n".join(files) + "\n")
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = freeze.main([
                    "check", "--repo", "manaflow-ai/cmux", "--pr", "42", "--base", base,
                    "--files", str(paths["files"]), "--issues-file", str(paths["issues"]),
                    "--events-file", str(paths["events"]),
                ])
            return status, out.getvalue(), err.getvalue()

    def test_a_frozen_path_blocks_and_names_the_freeze_and_owner(self):
        status, out, _ = self.check([issue(body=body())], ["docs/a.md", "cmux-tui/crates/acpmux/src/deliver.rs"])
        self.assertEqual(status, 1)
        self.assertIn("#7", out)
        self.assertIn("@lawrence", out)
        self.assertIn("cmux-tui/crates/acpmux/src/deliver.rs", out)

    def test_a_sibling_of_a_frozen_prefix_is_not_frozen(self):
        status, _, _ = self.check([issue(body=body(paths="docs/frozen docs/app.md"))],
                                  ["docs/frozen-notes/a.md", "docs/app.md.orig"])
        self.assertEqual(status, 0)

    def test_leading_slashes_and_commas_still_freeze_and_globs_are_malformed(self):
        for paths in ("/cmux-tui/spec/", "./cmux-tui/spec/", "cmux-tui/spec/,"):
            with self.subTest(paths=paths):
                self.assertEqual(self.check([issue(body=body(paths=paths))], ["cmux-tui/spec/x.json"])[0], 1)
        status, _, err = self.check([issue(body=body(paths="cmux-tui/*"))], ["cmux-tui/spec/x.json"])
        self.assertEqual(status, 0)
        self.assertIn("not globs", err)

    def test_only_an_admin_or_maintainer_label_turns_a_freeze_on(self):
        files = ["cmux-tui/spec/x.json"]
        for role in ("admin", "maintain"):
            with self.subTest(role=role):
                self.assertEqual(self.check([issue(body=body(), labeler_role=role)], files)[0], 1)
        for labeler, role in (("triager", "triage"), ("writer", "write"), ("outsider", None), (None, None)):
            with self.subTest(labeler=labeler, role=role):
                status, _, err = self.check([issue(body=body(), labeled_by=labeler, labeler_role=role)], files)
                self.assertEqual(status, 0)
                self.assertIn("not an admin or maintainer", err)

    def test_an_edit_after_the_label_turns_the_freeze_off_until_labeled_again(self):
        files = ["cmux-tui/spec/x.json"]
        labeled, edited = NOW - timedelta(minutes=30), NOW - timedelta(minutes=10)
        widened = issue(body=body(), labeled_at=stamp(labeled), last_edited_at=stamp(edited))
        status, _, err = self.check([widened], files)
        self.assertEqual(status, 0)
        self.assertIn("edited after", err)
        relabeled = issue(body=body(), labeled_at=stamp(NOW - timedelta(minutes=5)), last_edited_at=stamp(edited))
        self.assertEqual(self.check([relabeled], files)[0], 1)

    def test_an_expired_freeze_blocks_nothing(self):
        status, _, _ = self.check([issue(body=body(expires=stamp(NOW - timedelta(minutes=1))))],
                                  ["cmux-tui/spec/x.json"])
        self.assertEqual(status, 0)

    def test_a_freeze_never_outlasts_72_hours_from_its_issue(self):
        old = issue(body=body(expires=stamp(NOW + timedelta(days=30))), created=NOW - timedelta(hours=73))
        status, _, _ = self.check([old], ["cmux-tui/spec/x.json"])
        self.assertEqual(status, 0)

    def test_a_malformed_freeze_warns_and_blocks_nothing(self):
        for text in ("expires: tomorrow\npaths: cmux-tui/", "paths: cmux-tui/", body(paths="/")):
            with self.subTest(body=text):
                status, _, err = self.check([issue(body=text)], ["cmux-tui/spec/x.json"])
                self.assertEqual(status, 0)
                self.assertIn("malformed", err)

    def test_only_the_owners_freeze_ok_lets_a_pull_request_through(self):
        frozen = [issue(body=body())]
        files = ["cmux-tui/spec/x.json"]
        self.assertEqual(self.check(frozen, files, [labeled("lawrence")])[0], 0)
        self.assertEqual(self.check(frozen, files, [labeled("someone-else")])[0], 1)
        self.assertEqual(self.check(frozen, files, [labeled("lawrence"), labeled("lawrence", event="unlabeled")])[0], 1)

    def test_an_owner_line_hands_the_freeze_to_someone_else(self):
        frozen = [issue(body=body(extra="owner: @austin"))]
        self.assertEqual(self.check(frozen, ["cmux-tui/spec/x.json"], [labeled("austin")])[0], 0)
        self.assertEqual(self.check(frozen, ["cmux-tui/spec/x.json"], [labeled("lawrence")])[0], 1)

    def test_a_branch_line_limits_the_freeze_to_that_base(self):
        frozen = [issue(body=body(extra="branch: main"))]
        self.assertEqual(self.check(frozen, ["cmux-tui/spec/x.json"], base="feat-cmux-next")[0], 0)
        self.assertEqual(self.check(frozen, ["cmux-tui/spec/x.json"], base="main")[0], 1)

    def test_closed_or_unlabeled_issues_are_not_freezes(self):
        closed = dict(issue(body=body()), state="closed")
        other = issue(body=body(), labels=("bug",))
        self.assertEqual(self.check([closed, other], ["cmux-tui/spec/x.json"])[0], 0)

    def test_expire_closes_lapsed_and_old_inactive_freezes_only(self):
        old = NOW - timedelta(hours=73)
        cases = {
            "active": (issue(body=body()), None),
            "lapsed": (issue(body=body(expires=stamp(NOW - timedelta(minutes=5)))), "set"),
            "fresh unauthorised": (issue(body=body(), labeled_by="triager", labeler_role="triage"), None),
            "old unauthorised": (issue(body=body(), created=old, labeled_by="triager", labeler_role="triage"), "set"),
            "old malformed": (issue(body="paths: cmux-tui/", created=old), "set"),
        }
        with tempfile.TemporaryDirectory() as directory:
            for name, (raw, expected) in cases.items():
                with self.subTest(case=name):
                    path = Path(directory) / f"{name}.json"
                    path.write_text(json.dumps([raw]))
                    [parsed] = freeze.open_freezes("x/y", str(path))
                    result = freeze.lapsed_at(parsed, NOW)
                    self.assertEqual(result is not None, expected is not None)

    def test_an_unexpected_api_shape_is_status_2_not_1(self):
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory) / "files.txt"
            files.write_text("docs/a.md\n")
            issues = Path(directory) / "issues.json"
            issues.write_text(json.dumps([{"number": 1, "created_at": None, "labels": [{"name": "merge-freeze"}]}]))
            with redirect_stderr(io.StringIO()):
                status = freeze.main(["check", "--repo", "x/y", "--pr", "1", "--files", str(files),
                                      "--issues-file", str(issues), "--events-file", "/dev/null"])
        self.assertEqual(status, 2)

    def test_list_and_expire_report_an_unreadable_list_as_status_2(self):
        with tempfile.TemporaryDirectory() as directory:
            issues = Path(directory) / "issues.json"
            issues.write_text(json.dumps([{"number": 1, "created_at": None, "labels": [{"name": "merge-freeze"}]}]))
            original = freeze.open_freezes
            freeze.open_freezes = lambda repo, issues_file=None: original(repo, str(issues))
            try:
                for mode in (["list"], ["expire", "--dry-run"]):
                    with self.subTest(mode=mode[0]), redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                        self.assertEqual(freeze.main([*mode, "--repo", "x/y"]), 2)
            finally:
                freeze.open_freezes = original

    def test_an_unreadable_freeze_list_is_status_2_not_clear(self):
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory) / "files.txt"
            files.write_text("docs/a.md\n")
            with redirect_stderr(io.StringIO()):
                status = freeze.main(["check", "--repo", "x/y", "--pr", "1", "--files", str(files),
                                      "--issues-file", str(Path(directory) / "missing.json")])
        self.assertEqual(status, 2)


class FakeGh:
    """subprocess.run for `gh`: answers from `responses` by endpoint prefix and records each call
    with the token it was made with."""

    def __init__(self, responses, refuse_token=None):
        self.responses, self.refuse_token, self.calls = responses, refuse_token, []

    def __call__(self, args, check=False, capture_output=False, text=False, env=None):
        token = (env or os.environ).get("GH_TOKEN")
        endpoint = next((a for a in args if a.startswith("repos/") or a == "graphql"), "")
        self.calls.append((endpoint, token))
        if self.refuse_token is not None and token == self.refuse_token:
            raise subprocess.CalledProcessError(1, args, "", "gh: API rate limit exceeded for installation (HTTP 403)")
        for prefix, value in self.responses.items():
            if endpoint.startswith(prefix):
                if "--jq" in args:  # gh_items: one JSON object per line
                    return subprocess.CompletedProcess(args, 0, "".join(json.dumps(v) + "\n" for v in value), "")
                return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
        raise AssertionError(f"unexpected gh call {args}")


class CheckApiCalls(unittest.TestCase):
    """`check` from the merge-freeze workflow reads GitHub only as far as a freeze could block."""

    REPO = "manaflow-ai/cmux"
    ISSUES = f"repos/{REPO}/issues?state=open&labels=merge-freeze"

    def run_check(self, fake, *extra, env=None):
        with mock.patch.object(freeze.subprocess, "run", fake), mock.patch.dict(os.environ, env or {}), \
                redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()):
            status = freeze.main(["check", "--repo", self.REPO, "--pr", "42", "--base", "feat-cmux-next", *extra])
        return status, out.getvalue(), [endpoint for endpoint, _ in fake.calls]

    def test_no_open_freeze_reads_only_the_freeze_list(self):
        fake = FakeGh({self.ISSUES: []})
        status, _, calls = self.run_check(fake, "--changed-files", "3")
        self.assertEqual(status, 0)
        self.assertEqual(calls, [f"{self.ISSUES}&per_page=100"])  # was: + pulls/42/files and pulls/42

    def test_a_freeze_on_another_branch_reads_no_pull_request(self):
        frozen = {**issue(body=body(extra="branch: main")), "state": "open"}
        fake = FakeGh({self.ISSUES: [frozen], f"repos/{self.REPO}/issues/7/events": [labeled("lawrence", "merge-freeze")],
                       f"repos/{self.REPO}/collaborators/": {"role_name": "admin"},
                       "graphql": {"data": {"repository": {"issue": {"lastEditedAt": None}}}}})
        status, _, calls = self.run_check(fake)
        self.assertEqual(status, 0)
        self.assertFalse([c for c in calls if "/pulls/" in c or "/issues/42/" in c], calls)
        # A freeze that cannot apply to this base costs no authority reads either (GITHUB_TOKEN budget).
        self.assertEqual(calls, [f"{self.ISSUES}&per_page=100"])

    def test_a_lapsed_freeze_reads_only_the_freeze_list(self):
        lapsed = {**issue(body=body(expires="2020-01-01T00:00Z")), "state": "open"}
        status, _, calls = self.run_check(FakeGh({self.ISSUES: [lapsed]}))
        self.assertEqual(status, 0)
        self.assertEqual(calls, [f"{self.ISSUES}&per_page=100"])

    def applicable(self, files):
        return FakeGh({
            self.ISSUES: [issue(body=body())],
            f"repos/{self.REPO}/issues/7/events": [labeled("lawrence", "merge-freeze")],
            f"repos/{self.REPO}/collaborators/": {"role_name": "admin"},
            "graphql": {"data": {"repository": {"issue": {"lastEditedAt": None}}}},
            f"repos/{self.REPO}/pulls/42/files": [{"filename": f} for f in files],
            f"repos/{self.REPO}/pulls/42": {"changed_files": len(files)},
            f"repos/{self.REPO}/issues/42/events": [],
        })

    def test_an_applicable_freeze_still_blocks_using_the_events_file_count(self):
        fake = self.applicable(["cmux-tui/spec/a.md"])
        status, out, calls = self.run_check(fake, "--changed-files", "1")
        self.assertEqual(status, 1)
        self.assertIn("#7", out)
        self.assertIn(f"repos/{self.REPO}/pulls/42/files?per_page=100", calls)
        self.assertNotIn(f"repos/{self.REPO}/pulls/42", calls)  # the count came from the event

    def test_a_cut_short_file_list_is_still_status_2(self):
        status, _, _ = self.run_check(self.applicable(["docs/a.md"]), "--changed-files", "3001")
        self.assertEqual(status, 2)

    def test_without_the_event_count_the_pull_request_is_read(self):
        status, _, calls = self.run_check(self.applicable(["docs/a.md"]))
        self.assertEqual(status, 0)
        self.assertIn(f"repos/{self.REPO}/pulls/42", calls)

    def test_a_refused_app_read_falls_back_to_the_workflow_token(self):
        fake = FakeGh({self.ISSUES: []}, refuse_token="app")
        status, _, _ = self.run_check(fake, env={"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": "workflow"})
        self.assertEqual(status, 0)
        self.assertEqual([token for _, token in fake.calls], ["app", "workflow"])
        fake = FakeGh({self.ISSUES: []}, refuse_token="app")
        status, _, _ = self.run_check(fake, env={"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": ""})
        self.assertEqual(status, 3)  # no fallback: rate-limited, not checked, never clear

    def test_a_write_is_never_retried_with_the_fallback(self):
        with mock.patch.dict(os.environ, {"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": "workflow"}):
            fake = FakeGh({}, refuse_token="app")
            with mock.patch.object(freeze.subprocess, "run", fake):
                with self.assertRaises(subprocess.CalledProcessError):
                    freeze.gh("issue", "close", "7", write=True)
        self.assertEqual(len(fake.calls), 1)

    def test_a_collaborator_404_on_the_app_token_is_asked_again_with_the_workflow_token(self):
        # A 404 means "not a collaborator" and drops the freeze; a narrow App token must not decide that.
        calls = []

        def fake(args, **kwargs):
            token = (kwargs.get("env") or os.environ).get("GH_TOKEN")
            calls.append(token)
            if token == "app":
                raise subprocess.CalledProcessError(1, args, "", "gh: Not Found (HTTP 404)")
            return subprocess.CompletedProcess(args, 0, json.dumps({"role_name": "admin"}), "")

        with mock.patch.dict(os.environ, {"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": "workflow"}), \
                mock.patch.object(freeze.subprocess, "run", fake):
            self.assertEqual(freeze.repo_role("o/r", "maintainer"), "admin")
        self.assertEqual(calls, ["app", "workflow"])

    def rate_limited_check(self, failures, retry="120", error="gh: API rate limit exceeded for installation."):
        """check with the first `failures` GitHub reads failing with `error`: (status, sleeps, stderr)."""
        calls, sleeps = [], []

        def gh(*args):
            calls.append(args)
            if len(calls) <= failures:
                raise freeze.subprocess.CalledProcessError(1, ["gh", *args], stderr=error)
            return ""

        original_gh, original_sleep = freeze.gh, freeze.time.sleep
        freeze.gh, freeze.time.sleep = gh, sleeps.append
        try:
            with tempfile.TemporaryDirectory() as directory:
                files = Path(directory) / "files.txt"
                files.write_text("docs/a.md\n")
                err = io.StringIO()
                with redirect_stderr(err), redirect_stdout(io.StringIO()):
                    status = freeze.main(["check", "--repo", "x/y", "--pr", "1", "--files", str(files),
                                          "--rate-limit-retry", retry])
        finally:
            freeze.gh, freeze.time.sleep = original_gh, original_sleep
        return status, sleeps, err.getvalue()

    def test_a_rate_limited_read_is_retried_once(self):
        status, sleeps, _ = self.rate_limited_check(failures=1)
        self.assertEqual((status, sleeps), (0, [120]))

    def test_a_read_still_rate_limited_after_the_retry_is_status_3_could_not_check(self):
        """Not 1 (frozen) and not 0 (clear): the merge freeze check shows a warning instead of a
        red, and gh-merge-green and next-autoland, which read again before merging, refuse it."""
        for error in ("gh: API rate limit exceeded for installation.",
                      "gh: You have exceeded a secondary rate limit. (HTTP 403)",
                      "gh: Too Many Requests (HTTP 429)"):
            with self.subTest(error=error):
                status, sleeps, err = self.rate_limited_check(failures=2, error=error)
                self.assertEqual((status, sleeps), (3, [120]))
                self.assertIn("could not check", err)

    def test_any_other_unreadable_answer_is_still_status_2_with_no_retry(self):
        status, sleeps, _ = self.rate_limited_check(
            failures=2, error="gh: Resource not accessible by integration (HTTP 403)")
        self.assertEqual((status, sleeps), (2, []))

    def test_without_a_retry_a_rate_limited_read_is_status_3_at_once(self):
        status, sleeps, _ = self.rate_limited_check(failures=1, retry="0")
        self.assertEqual((status, sleeps), (3, []))

if __name__ == "__main__":
    unittest.main()
