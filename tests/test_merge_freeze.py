"""merge_freeze.py: a freeze is an open, owned, expiring merge-freeze issue, and only its owner's
freeze-ok label lets a pull request through."""
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

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


class PagedReadTests(unittest.TestCase):
    """Lists are read one explicit page at a time: the autoland host's quota wrapper refuses
    `gh api --paginate` while its budget is charged, and that refusal held a reviewed PR."""

    def read(self, total):
        calls = []

        def fake_gh(*args):
            calls.append(args)
            self.assertNotIn("--paginate", args)
            page = int(args[-1].rsplit("page=", 1)[1])
            start = (page - 1) * freeze.PAGE_SIZE
            return json.dumps([{"n": n} for n in range(start, min(total, start + freeze.PAGE_SIZE))])

        saved, freeze.gh = freeze.gh, fake_gh
        try:
            return freeze.gh_items("repos/x/y/pulls/1/files"), calls
        finally:
            freeze.gh = saved

    def test_every_page_is_its_own_call_until_a_short_page(self):
        items, calls = self.read(150)
        self.assertEqual([item["n"] for item in items], list(range(150)))
        self.assertEqual([call[-1] for call in calls], ["repos/x/y/pulls/1/files?per_page=100&page=1",
                                                       "repos/x/y/pulls/1/files?per_page=100&page=2"])

    def test_a_full_last_page_reads_one_empty_page_after_it(self):
        items, calls = self.read(100)
        self.assertEqual(len(items), 100)
        self.assertEqual(len(calls), 2)

    def test_a_query_endpoint_keeps_its_query(self):
        calls = []

        def fake_gh(*args):
            calls.append(args[-1])
            return "[]"

        saved, freeze.gh = freeze.gh, fake_gh
        try:
            freeze.gh_items("repos/x/y/issues?state=open&labels=merge-freeze")
        finally:
            freeze.gh = saved
        self.assertEqual(calls, ["repos/x/y/issues?state=open&labels=merge-freeze&per_page=100&page=1"])

    def test_a_page_that_is_not_a_list_is_unreadable(self):
        saved, freeze.gh = freeze.gh, lambda *args: json.dumps({"message": "refused"})
        try:
            with self.assertRaises(ValueError):
                freeze.gh_items("repos/x/y/pulls/1/files")
        finally:
            freeze.gh = saved


if __name__ == "__main__":
    unittest.main()
