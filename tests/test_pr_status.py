#!/usr/bin/env python3
"""scripts/ci/pr_status.py keeps one sectioned status comment per pull request.

Runs upsert against an in-memory fake of the four comment endpoints; nothing reaches GitHub.
"""
from email.message import Message
import io
import os
from pathlib import Path
import sys
import unittest
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import pr_status  # noqa: E402

REPO, PR = "manaflow-ai/cmux", 7


class FakeGitHub:
    def __init__(self):
        self.comments = {}  # id -> {"id", "body", "user"}
        self.next_id = 100
        self.writes = []
        self.on_read = None  # hook: runs before a list, to simulate another writer

    def add(self, body, user=pr_status.BOT):
        self.next_id += 1
        self.comments[self.next_id] = {"id": self.next_id, "body": body, "user": user}
        return self.next_id

    def __call__(self, method, path, payload):
        if method == "GET":
            if self.on_read:
                hook, self.on_read = self.on_read, None
                hook()
            return [{"id": c["id"], "body": c["body"], "user": {"login": c["user"]}}
                    for c in self.comments.values()]
        self.writes.append(method)
        if method == "POST":
            self.add(payload["body"])
        elif method == "PATCH":
            self.comments[int(path.rsplit("/", 1)[1])]["body"] = payload["body"]
        elif method == "DELETE":
            del self.comments[int(path.rsplit("/", 1)[1])]
        return None

    def status(self):
        found = [c for c in self.comments.values() if c["body"].startswith(pr_status.MARKER)]
        assert len(found) == 1, found
        return pr_status.parse(found[0]["body"])


def upsert(gh, key, text, **kw):
    return pr_status.upsert(REPO, PR, key, text, api=gh, sleep=lambda _: None, **kw)


class PrStatusTests(unittest.TestCase):
    def test_list_comments_reads_past_the_old_thirty_page_cap(self):
        pages = []

        def api(method, path, payload):
            page = int(path.rsplit("page=", 1)[1])
            pages.append(page)
            if page > 31:
                return []
            return [{"id": page, "body": "", "user": {"login": "github-actions[bot]"}}] * 100

        comments = pr_status.list_comments(api, "o/r", 7)
        self.assertEqual(len(comments), 3100)
        self.assertEqual(pages[-1], 32)

    def test_a_clean_pull_request_gets_no_comment(self):
        gh = FakeGitHub()
        self.assertEqual(upsert(gh, "checks", None), "unchanged")
        self.assertEqual(gh.comments, {})

    def test_sections_share_one_comment_in_display_order(self):
        gh = FakeGitHub()
        upsert(gh, "receipt", "Merge receipt")
        upsert(gh, "bead", "Bead: `cx-abc1`")
        upsert(gh, "checks", "red: web / lint")
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "checks": "red: web / lint",
                                       "receipt": "Merge receipt"})
        body = next(iter(gh.comments.values()))["body"]
        self.assertLess(body.index("cx-abc1"), body.index("red: web"))
        self.assertLess(body.index("red: web"), body.index("Merge receipt"))
        self.assertEqual(gh.writes, ["POST", "PATCH", "PATCH"])

    def test_clearing_removes_only_that_section_and_an_unchanged_write_is_skipped(self):
        gh = FakeGitHub()
        upsert(gh, "bead", "Bead: `cx-abc1`")
        upsert(gh, "checks", "red: web / lint")
        upsert(gh, "checks", None)
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`"})
        writes = len(gh.writes)
        self.assertEqual(upsert(gh, "bead", "Bead: `cx-abc1`"), "unchanged")
        self.assertEqual(len(gh.writes), writes)

    def test_a_lost_write_is_written_again(self):
        gh = FakeGitHub()
        cid = gh.add(pr_status.render({"bead": "Bead: `cx-abc1`"}))
        stale = gh.comments[cid]["body"]

        def other_writer_overwrites():
            # Another writer read the comment before ours and writes after it.
            gh.on_read = lambda: gh.comments[cid].update(body=stale)
        upsert_calls = []
        orig = gh.__call__

        def gh_with_race(method, path, payload):
            out = orig(method, path, payload)
            if method == "PATCH" and not upsert_calls:
                upsert_calls.append(1)
                other_writer_overwrites()
            return out
        pr_status.upsert(REPO, PR, "checks", "red: web / lint", api=gh_with_race, sleep=lambda _: None)
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "checks": "red: web / lint"})

    def test_two_status_comments_fold_into_the_oldest(self):
        gh = FakeGitHub()
        first = gh.add(pr_status.render({"bead": "Bead: `cx-abc1`"}))
        gh.add(pr_status.render({"review": "links"}))
        upsert(gh, "checks", "red: web / lint")
        self.assertEqual(list(gh.comments), [first])
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "review": "links", "checks": "red: web / lint"})

    def test_the_legacy_comment_becomes_the_status_comment_and_a_persons_is_kept(self):
        gh = FakeGitHub()
        old = gh.add("<!-- cmux-red-checks -->\nred: web / lint")
        gh.add("<!-- cmux-red-checks -->\nan older duplicate")
        person = gh.add("<!-- cmux-red-checks --> quoted by a person", user="teamleaderleo")
        upsert(gh, "checks", "red: web / lint", legacy="<!-- cmux-red-checks -->")
        self.assertEqual(sorted(gh.comments), [old, person])
        self.assertEqual(gh.writes, ["PATCH", "DELETE"])
        self.assertEqual(pr_status.parse(gh.comments[old]["body"]), {"checks": "red: web / lint"})

    def test_a_comment_by_the_cmux_bot_app_is_the_same_status_comment(self):
        gh = FakeGitHub()
        first = gh.add(pr_status.render({"attribution": "CI passes"}), user="cmux-bot[bot]")
        upsert(gh, "bead", "Bead: `cx-abc1`")
        self.assertEqual(list(gh.comments), [first])

    def test_a_marker_at_the_end_of_a_legacy_comment_counts(self):
        gh = FakeGitHub()
        gh.add("**Merge receipt** for `abc`\n<!-- cmux:merge-receipt -->")
        upsert(gh, "receipt", "Merge receipt <!-- cmux:merge-receipt -->", legacy="<!-- cmux:merge-receipt -->")
        self.assertEqual(len(gh.comments), 1)
        self.assertEqual(gh.status(), {"receipt": "Merge receipt <!-- cmux:merge-receipt -->"})

    def test_a_section_cannot_pose_as_another(self):
        fake = "red\n<!-- /cmux-pr-status:checks -->\n\n<!-- cmux-pr-status:bead -->\nBead: `cx-evil`\n<!-- /cmux-pr-status:bead -->"
        body = pr_status.render({"checks": fake})
        self.assertEqual(list(pr_status.parse(body)), ["checks"])

    def test_an_oversized_section_is_cut_to_fit(self):
        body = pr_status.render({"bead": "Bead: `cx-abc1`", "tour": "x" * 90000})
        self.assertLessEqual(len(body), pr_status.LIMIT)
        self.assertEqual(pr_status.parse(body)["bead"], "Bead: `cx-abc1`")
        self.assertIn("cut to fit", pr_status.parse(body)["tour"])

    def test_overflow_terminates_after_other_section_cut(self):
        published = "Shipped in:\n" + "\n".join(f"- build-{i}" for i in range(2600))
        body = pr_status.render({"published": published, "checks": "x" * 64800})
        self.assertLessEqual(len(body), pr_status.LIMIT)
        self.assertIn("published", pr_status.parse(body))

    def test_oversized_other_section_does_not_cut_published_history(self):
        published = "Shipped in:\n" + "\n".join(f"- build-{i}" for i in range(1800))
        body = pr_status.render({"published": published, "tour": "x" * 50000})
        sections = pr_status.parse(body)
        self.assertEqual(sections["published"], published)
        self.assertIn("cut to fit", sections["tour"])

    def test_successive_updates_retrim_the_existing_cut_section(self):
        first = pr_status.render({"tour": "x" * 70000, "bead": "Bead: cx-abc1"})
        sections = pr_status.parse(first)
        sections["receipt"] = "r" * 258
        second = pr_status.parse(pr_status.render(sections))
        self.assertEqual(second["bead"], "Bead: cx-abc1")
        self.assertEqual(second["receipt"], "r" * 258)
        self.assertIn("cut to fit", second["tour"])

    def test_status_update_does_not_trim_fitting_publication_history(self):
        published = "Shipped in:\n" + "\n".join(f"- build-{i}" for i in range(822))
        first = pr_status.parse(pr_status.render({"published": published, "tour": "x" * 70000}))
        first["checks"] = "x" * 10
        second = pr_status.parse(pr_status.render(first))
        self.assertEqual(second["published"], first["published"])
        self.assertEqual(second["checks"], "x" * 10)

    def test_dispatched_fields_accept_only_valid_values(self):
        self.assertEqual(pr_status.field_text("cx-bi1nt", None), ("bead", "Bead: `cx-bi1nt`"))
        key, text = pr_status.field_text(None, "a" * 40)
        self.assertEqual(key, "preview")
        self.assertIn("`aaaaaaa`", text)
        for bead, preview in (("cx-x`; @everyone", None), ("not-a-bead", None), (None, "abc"), (None, None)):
            with self.assertRaises(ValueError):
                pr_status.field_text(bead, preview)


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def run_gh(self, args, **kw):
        self.runs.append((args, kw["env"].get("GH_TOKEN")))
        return type("Done", (), {"returncode": 0, "stderr": "", "stdout": ""})()

    def test_with_the_app_configured_the_dispatch_runs_as_the_app(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".id") as app_id:
            app_id.write("5313868\n")
            app_id.flush()
            env = {"CMUX_CI_GITHUB_APP_ID_FILE": app_id.name, "CMUX_CI_GITHUB_APP_KEY_FILE": "/k.pem", "GH_TOKEN": "person"}
            minted = []
            pr_status.dispatch(REPO, 7, bead="cx-abc1", env=env, run=self.run_gh,
                               mint=lambda i, k, r: minted.append((i, k, r)) or "app-token")
        self.assertEqual(minted, [("5313868", "/k.pem", REPO)])
        self.assertEqual(self.runs, [(["gh", "workflow", "run", "pr-status.yml", "-R", REPO, "--ref", "main",
                                       "-f", "pr=7", "-f", "bead=cx-abc1"], "app-token")])

    def test_a_configured_app_that_fails_never_falls_back_to_a_persons_login(self):
        env = {"CMUX_CI_GITHUB_APP_ID_FILE": "/missing", "CMUX_CI_GITHUB_APP_KEY_FILE": "/k.pem", "GH_TOKEN": "person"}
        with self.assertRaises(RuntimeError):
            pr_status.dispatch(REPO, 7, bead="cx-abc1", env=env, run=self.run_gh)
        self.assertEqual(self.runs, [])

    def test_without_the_app_gh_uses_its_own_login(self):
        pr_status.dispatch(REPO, 7, preview="a" * 40, env={}, run=self.run_gh)
        self.assertEqual(self.runs[0][0][-2:], ["-f", "preview=" + "a" * 40])
        self.assertIsNone(self.runs[0][1])

    def test_a_bad_value_is_refused_before_anything_runs(self):
        with self.assertRaises(ValueError):
            pr_status.dispatch(REPO, 7, bead="not a bead", env={}, run=self.run_gh)
        self.assertEqual(self.runs, [])


class RetryTests(unittest.TestCase):
    """2026-10-21: GitHub's secondary rate limit refused the review-line write for 90% of pushes (HTTP 403)."""

    def setUp(self):
        os.environ.setdefault("GH_TOKEN", "t")

    def call(self, answers, method="PATCH"):
        sleeps, sent = [], []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout):
            sent.append(request.get_method())
            code, body, retry_after = answers.pop(0)
            if code == 200:
                return Response(body.encode())
            headers = Message()
            if retry_after:
                headers["Retry-After"] = retry_after
            raise urllib.error.HTTPError(request.full_url, code, "x", headers, io.BytesIO(body.encode()))

        try:
            result = pr_status.http_api(method, "/repos/o/r/issues/comments/1", {"body": "x"}, sleep=sleeps.append,
                                        opener=opener)
        except RuntimeError as error:
            result = error
        return result, sleeps, sent

    def test_a_rate_limit_is_retried_with_backoff_and_retry_after(self):
        limit = (403, '{"message":"You have exceeded a secondary rate limit"}', "")
        result, sleeps, _ = self.call([limit, (429, "{}", "7"), (200, '{"id": 1}', "")])
        self.assertEqual((result, sleeps), ({"id": 1}, [5, 7.0]))

    def test_a_permission_403_and_other_4xx_are_final_and_say_why(self):
        for code, body in ((403, '{"message":"Resource not accessible by integration"}'), (422, '{"message":"bad"}')):
            result, sleeps, _ = self.call([(code, body, "")])
            self.assertIsInstance(result, RuntimeError)
            self.assertIn(f"HTTP {code}", str(result))
            self.assertIn(body[13:30], str(result))
            self.assertEqual(sleeps, [])

    def test_a_5xx_post_is_not_sent_twice(self):
        result, sleeps, sent = self.call([(502, "", "")], method="POST")
        self.assertIsInstance(result, RuntimeError)
        self.assertEqual(sent, ["POST"])
        _, _, sent = self.call([(502, "", ""), (200, "{}", "")], method="PATCH")
        self.assertEqual(sent, ["PATCH", "PATCH"])

    def test_retries_stop(self):
        limit = (429, "{}", "")
        result, sleeps, _ = self.call([limit] * (len(pr_status.RETRY_WAITS) + 1))
        self.assertIsInstance(result, RuntimeError)
        self.assertEqual(sleeps, list(pr_status.RETRY_WAITS))


class GraphQLReadTests(unittest.TestCase):
    """The comment reads go over GraphQL, a separate pool from REST (2026-10-31: the REST pool ran out at 00:50Z)."""

    def test_graphql_comments_have_the_rest_shape(self):
        pages = [
            {"repository": {"issueOrPullRequest": {"comments": {
                "pageInfo": {"hasNextPage": True, "endCursor": "c1"},
                "nodes": [{"fullDatabaseId": "3412345678901", "body": pr_status.MARKER + "x",
                           "author": {"__typename": "Bot", "login": "github-actions"}},
                          {"fullDatabaseId": "3412345678902", "body": "hi",
                           "author": {"__typename": "User", "login": "someone"}}]}}}},
            {"repository": {"issueOrPullRequest": {"comments": {
                "pageInfo": {"hasNextPage": False, "endCursor": None},
                "nodes": [{"fullDatabaseId": "3412345678903", "body": "b",
                           "author": {"__typename": "Bot", "login": "cmux-bot"}},
                          {"fullDatabaseId": "3412345678904", "body": "ghost", "author": None}]}}}},
        ]
        asked = []

        def query(text, variables):
            asked.append(variables)
            return pages.pop(0)

        found = pr_status.graphql_comments("o/r", 7, query=query)
        self.assertEqual([c["id"] for c in found], [3412345678901, 3412345678902, 3412345678903, 3412345678904])
        self.assertEqual([c["user"]["login"] for c in found], ["github-actions[bot]", "someone", "cmux-bot[bot]", ""])
        self.assertEqual([a["after"] for a in asked], [None, "c1"])
        self.assertEqual(asked[0]["owner"], "o")
        self.assertEqual([c["id"] for c in pr_status.bot_comments(found, pr_status.MARKER)], [3412345678901])

    def test_the_default_client_reads_over_graphql_and_falls_back_to_rest(self):
        saved = pr_status.graphql_comments
        try:
            pr_status.graphql_comments = lambda repo, pr: [{"id": 1, "body": "g", "user": {"login": "x"}}]
            self.assertEqual(pr_status.list_comments(pr_status.http_api, "o/r", 7)[0]["body"], "g")

            def refused(repo, pr):
                raise RuntimeError("GraphQL: rate limited")
            pr_status.graphql_comments = refused
            saved_api, sent = pr_status.REST_CLIENT, []
            # list_comments recognises the default client by identity, so the REST fallback is checked through it
            pr_status.REST_CLIENT = lambda m, p, b=None: sent.append(p) or []
            try:
                self.assertEqual(pr_status.list_comments(pr_status.REST_CLIENT, "o/r", 7), [])
            finally:
                pr_status.REST_CLIENT = saved_api
            self.assertEqual(sent, ["/repos/o/r/issues/7/comments?per_page=100&page=1"])
        finally:
            pr_status.graphql_comments = saved

    def test_any_other_client_is_read_as_before(self):
        gh = FakeGitHub()
        gh.add("hello")
        self.assertEqual([c["body"] for c in pr_status.list_comments(gh, "o/r", 7)], ["hello"])
        # a test that patches http_api with its fake (test_defaults_guard) still reads the fake, never GraphQL
        saved = pr_status.http_api
        pr_status.http_api = gh
        try:
            self.assertEqual([c["body"] for c in pr_status.list_comments(pr_status.http_api, "o/r", 7)], ["hello"])
        finally:
            pr_status.http_api = saved


class QuotaTests(unittest.TestCase):
    """2026-10-31 00:50Z: the installation's hourly REST quota hit 0 and every push's `link` job went red after six
    refused tries. A spent quota now ends the job at once with a warning, green."""

    def setUp(self):
        os.environ.setdefault("GH_TOKEN", "t")

    def call(self, answers, now=1000.0):
        sleeps, sent = [], []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout):
            sent.append(request.get_method())
            code, body, remaining, reset = answers.pop(0)
            if code == 200:
                return Response(body.encode())
            headers = Message()
            if remaining is not None:
                headers["X-RateLimit-Remaining"] = remaining
                headers["X-RateLimit-Reset"] = reset
            raise urllib.error.HTTPError(request.full_url, code, "x", headers, io.BytesIO(body.encode()))

        try:
            result = pr_status.http_api("GET", "/repos/o/r/issues/7/comments", None, sleep=sleeps.append,
                                        opener=opener, now=lambda: now)
        except RuntimeError as error:
            result = error
        return result, sleeps, sent

    SPENT = '{"message":"API rate limit exceeded for installation."}'

    def test_a_spent_quota_is_not_retried(self):
        result, sleeps, sent = self.call([(403, self.SPENT, "0", "4000")])
        self.assertIsInstance(result, pr_status.QuotaSpent)
        self.assertEqual((sleeps, sent), ([], ["GET"]))

    def test_a_quota_that_resets_within_a_minute_is_waited_out_once(self):
        result, sleeps, sent = self.call([(403, self.SPENT, "0", "1030"), (200, "[]", None, None)])
        self.assertEqual((result, sleeps, len(sent)), ([], [31.0], 2))
        result, sleeps, _ = self.call([(403, self.SPENT, "0", "1030"), (403, self.SPENT, "0", "1030")])
        self.assertIsInstance(result, pr_status.QuotaSpent)
        self.assertEqual(sleeps, [31.0])

    def test_a_reset_wait_after_the_last_retry_never_reads_as_success(self):
        secondary = (403, '{"message":"You have exceeded a secondary rate limit"}', "12", "4000")
        answers = [secondary] * len(pr_status.RETRY_WAITS) + [(403, self.SPENT, "0", "1030"), secondary]
        result, sleeps, sent = self.call(answers)
        self.assertIsInstance(result, RuntimeError)
        self.assertNotIsInstance(result, pr_status.QuotaSpent)
        self.assertEqual(len(sent), len(pr_status.RETRY_WAITS) + 2)
        self.assertEqual(sleeps, list(pr_status.RETRY_WAITS) + [31.0])

    def test_the_graphql_endpoint_follows_the_rest_one(self):
        seen = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout):
            seen.append(request.full_url)
            return Response(b'{"data": {"rateLimit": {}}}')
        saved = {k: os.environ.get(k) for k in ("GITHUB_API_URL", "GITHUB_GRAPHQL_URL")}
        try:
            os.environ.pop("GITHUB_GRAPHQL_URL", None)
            for api, want in (("https://ghe.example/api/v3", "https://ghe.example/api/graphql"),
                              ("https://api.github.com", "https://api.github.com/graphql")):
                os.environ["GITHUB_API_URL"] = api
                pr_status.graphql("query{rateLimit{used}}", {}, opener=opener)
                self.assertEqual(seen.pop(), want)
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_a_secondary_limit_still_backs_off(self):
        secondary = (403, '{"message":"You have exceeded a secondary rate limit"}', "12", "4000")
        result, sleeps, _ = self.call([secondary, (200, "{}", None, None)])
        self.assertEqual((result, sleeps), ({}, [5]))

    def test_set_warns_and_passes_when_the_quota_is_spent(self):
        import contextlib
        import tempfile

        saved = pr_status.upsert

        def spent(*args, **kwargs):
            raise pr_status.QuotaSpent("GET /x: HTTP 403: the API quota is spent until 01:19:51Z")
        pr_status.upsert = spent
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".md") as body:
                body.write("Review")
                body.flush()
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    code = pr_status.main(["set", "--repo", "o/r", "--pr", "7", "--section", "review",
                                           "--body-file", body.name])
        finally:
            pr_status.upsert = saved
        self.assertEqual(code, 0)
        self.assertIn("::warning title=pr-status::#7 review not written", out.getvalue())

    def test_any_other_failure_still_fails(self):
        saved = pr_status.upsert

        def broken(*args, **kwargs):
            raise RuntimeError("PATCH /x: HTTP 422: bad")
        pr_status.upsert = broken
        try:
            with self.assertRaises(RuntimeError):
                pr_status.main(["set", "--repo", "o/r", "--pr", "7", "--section", "review", "--clear"])
        finally:
            pr_status.upsert = saved


if __name__ == "__main__":
    unittest.main()
