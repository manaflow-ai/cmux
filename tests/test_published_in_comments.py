"""The "Shipped in" comment each release workflow leaves on its PRs."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/published_in_comments.py"
spec = importlib.util.spec_from_file_location("published_in_comments", SCRIPT)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class PublishedInTests(unittest.TestCase):
    def test_pr_numbers_from_subject_suffix_once_each(self):
        subjects = ["fix: a (#12)", "feat: b (#11)", "revert fix: a (#12)", "safe-push train", "mentions (#9) mid subject", "c (#10) "]
        self.assertEqual(module.pr_numbers(subjects), [12, 11, 10])

    def test_publication_lines_preserved_in_shared_status(self):
        nightly = module.build_line("nightly-next 2026101901", "https://x/n", "a" * 40)
        stable = module.build_line("v0.66.0", "https://x/v", "b" * 40)
        comments = [{"id": 1, "body": module.pr_status.render({"review": "SHIP", "published": "Shipped in:\n" + nightly}),
                     "user": {"login": "github-actions[bot]"}}]
        text = module.publication_text(comments, stable)
        self.assertEqual(text, "Shipped in:\n" + nightly + "\n" + stable)
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments
            self.assertEqual(method, "PATCH")
            comments[0]["body"] = payload["body"]

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, stable, comments.copy(), 0), "written")
            self.assertEqual(module.publish("o/r", 7, stable, comments.copy(), 0), "unchanged")
        self.assertEqual(module.pr_status.parse(comments[0]["body"]), {"review": "SHIP", "published": text})
        self.assertEqual([method for method, _, _ in calls], ["GET", "PATCH", "GET", "GET"])

    def test_legacy_migration_preserves_builds_and_other_sections(self):
        nightly = module.build_line("nightly-next 1", "https://x/n", "a" * 40)
        stable = module.build_line("v1", "https://x/v", "b" * 40)
        comments = [
            {"id": 1, "body": module.pr_status.render({"checks": "green"}), "user": {"login": "cmux-bot[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + nightly + "\n" + stable,
             "user": {"login": "github-actions[bot]"}},
        ]
        writes = []

        def api(method, path, payload=None):
            if method == "GET":
                return comments
            writes.append(method)
            if method == "PATCH":
                comments[0]["body"] = payload["body"]
            elif method == "DELETE":
                comments.pop()

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep") as sleep:
            self.assertEqual(module.publish("o/r", 7, stable, comments.copy(), 7.5), "written")
            self.assertEqual(writes, ["PATCH", "DELETE"])
            self.assertEqual(len(comments), 1)
            self.assertEqual(module.publish("o/r", 7, stable, comments.copy(), 7.5), "unchanged")
        self.assertEqual(writes, ["PATCH", "DELETE"])
        self.assertEqual([call.args for call in sleep.call_args_list], [(7.5,), (7.5,)])
        self.assertEqual(module.pr_status.parse(comments[0]["body"]),
                         {"checks": "green", "published": "Shipped in:\n" + nightly + "\n" + stable})

    def test_failed_shared_status_write_keeps_legacy_history(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        comments = [
            {"id": 1, "body": module.pr_status.render({"checks": "green"}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + old,
             "user": {"login": "github-actions[bot]"}},
        ]
        writes = []
        refusal = subprocess.CalledProcessError(1, "gh", stderr="HTTP 403: secondary rate limit")

        def api(method, path, payload=None):
            if method == "GET":
                return comments
            writes.append(method)
            raise refusal

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            with self.assertRaises(subprocess.CalledProcessError):
                module.publish("o/r", 7, new, comments.copy(), 7.5)
        self.assertEqual(writes, ["PATCH"])
        self.assertEqual(len(comments), 2)
        self.assertIn(old, comments[1]["body"])

    def test_legacy_updated_during_migration_is_not_deleted(self):
        old, first, concurrent = [module.build_line(f"v{i}", f"https://x/v{i}", str(i) * 40)
                                  for i in range(3)]
        published = "Shipped in:\n" + old + "\n" + first
        size = module.pr_status.LIMIT - len(module.pr_status.render(
            {"checks": "x", "published": published})) + 1 - 5
        comments = [
            {"id": 1, "body": module.pr_status.render({"checks": "x" * size}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + old,
             "user": {"login": "github-actions[bot]"}},
        ]
        injected = False
        writes = []

        def api(method, path, payload=None):
            if method == "GET":
                return [dict(comment) for comment in comments]
            writes.append((method, path))
            target = next(c for c in comments if str(c["id"]) == path.rsplit("/", 1)[-1])
            if method == "PATCH":
                target["body"] = payload["body"]
            elif method == "DELETE":
                comments.remove(target)
            else:
                self.fail(f"unexpected write: {method}")

        def sleep(_):
            nonlocal injected
            if not injected:
                injected = True
                self.assertEqual(module.publish("o/r", 7, concurrent, comments.copy(), 7.5), "written")

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep", sleep):
            self.assertEqual(module.publish("o/r", 7, first, comments.copy(), 7.5), "written")
        self.assertNotIn(("DELETE", "repos/o/r/issues/comments/2"), writes)
        bodies = "\n".join(c["body"] for c in comments)
        self.assertTrue(all(line in bodies for line in (old, first, concurrent)))
        self.assertEqual(module.pr_status.parse(comments[0]["body"])["checks"], "x" * size)

    def test_duplicate_shared_comments_consolidate_without_retrying_unchanged_edit(self):
        line = module.build_line("v1", "https://x/v1", "a" * 40)
        comments = [
            {"id": 1, "body": module.pr_status.render({"checks": "green"}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.pr_status.render({"review": "SHIP"}),
             "user": {"login": "github-actions[bot]"}},
        ]
        writes = []

        def api(method, path, payload=None):
            if method == "GET":
                return [dict(comment) for comment in comments]
            writes.append(method)
            if method == "PATCH":
                comments[0]["body"] = payload["body"]
            elif method == "DELETE":
                comments.pop()
            else:
                self.fail(f"unexpected write: {method}")

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, line, comments.copy(), 7.5), "written")
            self.assertEqual(module.publish("o/r", 7, line, comments.copy(), 7.5), "unchanged")
        self.assertEqual(writes, ["PATCH", "DELETE"])
        self.assertEqual(len(comments), 1)
        self.assertEqual(module.pr_status.parse(comments[0]["body"]),
                         {"checks": "green", "review": "SHIP", "published": "Shipped in:\n" + line})

    def test_standalone_migration_edits_without_new_timeline_entry(self):
        line = module.build_line("v1", "https://x/v", "a" * 40)
        comments = [{"id": 2, "body": module.MARKER + "\nShipped in:\n" + line,
                     "user": {"login": "github-actions[bot]"}}]
        plan = module.pr_status.plan("o/r", 7, comments, module.SECTION,
                                     module.publication_text(comments, line), legacy=module.MARKER)
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0][:2], ("PATCH", "repos/o/r/issues/comments/2"))
        self.assertEqual(module.pr_status.parse(plan[0][2]["body"]), {"published": "Shipped in:\n" + line})

    def test_oversized_status_keeps_lossless_legacy_fallback(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        history = "\n".join(f"- [v{i}](https://x/{i}) (`{i:010d}`)" for i in range(1200))
        comments = [
            {"id": 1, "body": module.pr_status.render({"checks": "green" * 5000}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + old + "\n" + history,
             "user": {"login": "github-actions[bot]"}},
        ]
        calls = []
        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments
        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, new, comments, 0), "written")
        writes = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual(len(writes), 1)
        self.assertIn(old, writes[0][2]["body"])
        self.assertIn(new, writes[0][2]["body"])

    def test_duplicate_status_sections_are_kept_lossless(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        comments = [
            {"id": 1, "body": module.pr_status.render({"published": "Shipped in:\n" + old}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.pr_status.render({"tour": "x" * 64800}),
             "user": {"login": "github-actions[bot]"}},
        ]
        calls = []
        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments
        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, new, comments, 0), "written")
        writes = [call for call in calls if call[0] == "POST"]
        self.assertEqual(len(writes), 1)
        self.assertIn(new, writes[0][2]["body"])
        self.assertNotIn("/comments/2", "".join(call[1] for call in calls))

    def test_near_limit_other_section_uses_lossless_legacy_fallback(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        history = "\n".join(f"- [v{i}](https://x/{i}) (`{i:010d}`)" for i in range(30))
        comments = [
            {"id": 1, "body": module.pr_status.render({"tour": "x" * 64000}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + old + "\n" + history,
             "user": {"login": "github-actions[bot]"}},
        ]
        calls = []
        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments
        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, new, comments, 0), "written")
        writes = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual(len(writes), 1)
        self.assertIn(new, writes[0][2]["body"])
        self.assertNotIn("cmux-pr-status", writes[0][2]["body"])

    def test_truncated_status_without_line_uses_lossless_fallback_when_plan_is_empty(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        comments = [{
            "id": 1,
            "body": module.pr_status.render({
                "published": "Shipped in:\n" + old +
                "\n\n(cut to fit GitHub's comment limit; the run that wrote this has the rest)",
            }),
            "user": {"login": "github-actions[bot]"},
        }]
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments

        # This is the cap-boundary case: render() has discarded `new` and
        # happened to return the body already on GitHub, so plan() has no
        # write to report even though the requested line is absent.
        with patch.object(module.pr_status, "plan", return_value=[]), \
             patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, new, comments, 0), "written")
        self.assertEqual([method for method, _, _ in calls], ["GET", "GET", "POST"])
        self.assertIn(new, calls[-1][2]["body"])

    def test_overflow_fallback_keeps_accumulated_publication_history(self):
        history = [module.build_line(f"v{i}", f"https://x/{i}", str(i) * 40) for i in range(30)]
        new = module.build_line("v30", "https://x/30", "3" * 40)
        comments = [{
            "id": 1,
            "body": module.pr_status.render({
                "tour": "x" * 70000,
                "published": "Shipped in:\n" + "\n".join(history),
            }),
            "user": {"login": "github-actions[bot]"},
        }]
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments

        # Simulate a concurrent status overwrite that leaves plan() with no
        # write while the accumulated publication text still has all history.
        with patch.object(module.pr_status, "plan", return_value=[]), \
             patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, new, comments, 0), "written")
        fallback = calls[-1][2]["body"]
        self.assertTrue(all(item in fallback for item in history + [new]))

    def test_overflow_fallback_rereads_legacy_before_patch(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        concurrent = module.build_line("v2", "https://x/v2", "b" * 40)
        new = module.build_line("v3", "https://x/v3", "c" * 40)
        stale = [{"id": 1, "body": module.MARKER + "\nShipped in:\n" + old,
                  "user": {"login": "github-actions[bot]"}}]
        fresh = [{"id": 1, "body": module.MARKER + "\nShipped in:\n" + old + "\n" + concurrent,
                  "user": {"login": "github-actions[bot]"}}]
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return fresh

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.legacy_publish(
                "o/r", 7, new, stale, 0,
                "Shipped in:\n" + old + "\n" + new,
            ), "written")
        self.assertEqual([method for method, _, _ in calls], ["GET", "PATCH"])
        patched = calls[-1][2]["body"]
        self.assertTrue(all(item in patched for item in (old, concurrent, new)))

    def test_overflow_fallback_never_merges_legacy_comments_past_cap(self):
        first_lines = [module.build_line(f"a{i}", "https://x/a", "a" * 40) for i in range(800)]
        second_lines = [module.build_line(f"b{i}", "https://x/b", "b" * 40) for i in range(800)]
        new = module.build_line("v-new", "https://x/new", "c" * 40)
        legacy = lambda lines: module.MARKER + "\nShipped in:\n" + "\n".join(lines)
        comments = [
            {"id": 1, "body": legacy(first_lines), "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": legacy(second_lines), "user": {"login": "github-actions[bot]"}},
        ]
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.legacy_publish("o/r", 7, new, comments, 0, new), "written")
        payloads = [payload["body"] for method, _, payload in calls if method in {"PATCH", "POST"}]
        self.assertTrue(payloads)
        self.assertTrue(all(len(body) <= module.pr_status.LIMIT for body in payloads))
        self.assertIn(new, "\n".join(payloads))

    def test_duplicate_legacy_is_deleted_when_status_already_has_line(self):
        line = module.build_line("v1", "https://x/v1", "a" * 40)
        comments = [
            {"id": 1, "body": module.pr_status.render({"published": "Shipped in:\n" + line}),
             "user": {"login": "github-actions[bot]"}},
            {"id": 2, "body": module.MARKER + "\nShipped in:\n" + line,
             "user": {"login": "github-actions[bot]"}},
        ]
        calls = []
        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return comments
            if method == "DELETE":
                comments.pop()
        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            self.assertEqual(module.publish("o/r", 7, line, comments, 0), "written")
        self.assertEqual([method for method, _, _ in calls if method != "GET"], ["DELETE"])
        self.assertEqual(len(comments), 1)

    def test_settle_preserves_prior_build_after_stale_writer(self):
        old = module.build_line("v1", "https://x/v1", "a" * 40)
        new = module.build_line("v2", "https://x/v2", "b" * 40)
        comments = [{"id": 1, "body": module.pr_status.render({"published": "Shipped in:\n" + old}),
                     "user": {"login": "github-actions[bot]"}}]
        writes = []

        def api(method, path, payload=None):
            if method == "GET":
                if len(writes) == 1:
                    comments[0]["body"] = module.pr_status.render({"checks": "new status"})
                return comments
            writes.append(payload["body"])
            comments[0]["body"] = payload["body"]

        with patch.object(module, "status_api", api), patch.object(module.time, "sleep"):
            module.publish("o/r", 7, new, comments.copy(), 0)
        self.assertEqual(len(writes), 2)
        self.assertEqual(module.pr_status.parse(comments[0]["body"]),
                         {"checks": "new status", "published": "Shipped in:\n" + old + "\n" + new})

    def test_dry_run_over_a_git_span(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            run = lambda *args: subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env).stdout.strip()
            run("init", "-q")
            run("commit", "-q", "--allow-empty", "-m", "old (#1)")
            since = run("rev-parse", "HEAD")
            run("commit", "-q", "--allow-empty", "-m", "fix: x (#2)")
            run("commit", "-q", "--allow-empty", "-m", "train commit")
            run("commit", "-q", "--allow-empty", "-m", "feat: y (#3)")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", since, "--head", "HEAD", "--name", "v1", "--url", "https://x", "--dry-run"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.split(":")[0] for line in result.stdout.splitlines()[:-1]], ["#3", "#2"])
        self.assertIn("2 PRs, 2 written", result.stdout)

    def test_merged_in_history_is_not_commented(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
            run = lambda *args: subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True, env=env).stdout.strip()
            run("init", "-q", "-b", "main")
            run("commit", "-q", "--allow-empty", "-m", "base (#100)")
            since = run("rev-parse", "HEAD")
            run("checkout", "-q", "--orphan", "other")
            run("commit", "-q", "--allow-empty", "-m", "another repo's PR (#5)")
            run("checkout", "-q", "main")
            run("merge", "-q", "--allow-unrelated-histories", "-m", "Merge other", "other")
            run("commit", "-q", "--allow-empty", "-m", "fix: x (#101)")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", since, "--head", "HEAD", "--name", "v1", "--url", "https://x", "--dry-run"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual([line.split(":")[0] for line in result.stdout.splitlines()[:-1]], ["#101"])

    def test_marker_comment_and_rate_limit_detection(self):
        node = {"comments": {"nodes": [
            {"databaseId": 1, "body": module.MARKER + " old", "author": {"login": "someone"}},
            {"databaseId": 2, "body": module.MARKER + "\nShipped in:", "author": {"login": "github-actions"}},
        ]}}
        self.assertEqual(module.normalize_comments(node)[1]["user"]["login"], "github-actions[bot]")
        self.assertEqual(module.normalize_comments({}), [])
        refusal = subprocess.CalledProcessError(1, "gh", stderr="HTTP 403: You have exceeded a secondary rate limit")
        self.assertTrue(module.rate_limited(refusal))
        self.assertFalse(module.rate_limited(subprocess.CalledProcessError(1, "gh", stderr="HTTP 404: Not Found")))

    def test_rate_limit_during_batched_comment_read_propagates(self):
        refusal = subprocess.CalledProcessError(1, "gh", stderr="HTTP 429: secondary rate limit")
        with patch.object(module, "gh", side_effect=refusal):
            with self.assertRaises(subprocess.CalledProcessError):
                module.existing_comments("o/r", [7])

    def test_unreadable_span_never_fails_the_release(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--since", "nope", "--head", "HEAD", "--name", "v1", "--url", "https://x"],
                cwd=directory, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0)
        self.assertIn("cannot read", result.stderr)


if __name__ == "__main__":
    unittest.main()
