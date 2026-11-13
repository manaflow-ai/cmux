"""scripts/ci/receipt_read.py: the one reader for a PR's receipts, and the lint that keeps every receipt read on it.

Tools that looked for a receipt or marker read a PR's newest few reviews or comments (`reviews(last: 30)`,
`comments(last: 100)`) and on a busy PR read "none" for a receipt further back (cmuxterm-hq
docs/handbook/newest-n-read-as-any.md). receipt_read reads the timeline newest first and pages back with `before:`
until the caller has what it needs, or a stated bound, and says when it stopped short.
"""
import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receipt_read", ROOT / "scripts/ci/receipt_read.py")
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

HEAD = "4b438e85a74f" + "0" * 28
OLD = "9" * 40
USER = {"__typename": "User", "login": "teamleaderleo"}

# Every file under scripts/ that reads a newest-N window of reviews or comments while looking for a receipt, verdict
# or marker, and why its read is whole. A new one fails ReceiptReadLint: read through receipt_read.read instead.
ALLOWED = {
    "scripts/ci/stale_agent_prs.py": "reads the newest human comment's mention and the last activity time: the "
                                     "newest items are the whole question, nothing is decided from a missing one",
}


def item(n, body="status", kind="IssueComment", oid=HEAD):
    """The Nth item of a fake timeline: N minutes after 05:00Z."""
    at = f"2026-11-11T{5 + n // 60:02d}:{n % 60:02d}:00Z"
    node = {"__typename": kind, "body": body, "authorAssociation": "MEMBER", "author": USER, "databaseId": n}
    if kind == "PullRequestReview":
        node.update(state="COMMENTED", submittedAt=at, commit={"oid": oid})
    else:
        node.update(createdAt=at)
    return node


class FakeGitHub:
    """Serves `pN: pullRequest(number: N) { headRefOid ... timelineItems(itemTypes, last, since, before) }` from
    TIMELINES ({N: [items, oldest first]}) the way GitHub does: the newest `last` items before the cursor, a
    cursor being the index of the page's oldest item."""

    FIELD = re.compile(r"p(\d+): pullRequest\(number: \d+\) \{ (headRefOid )?.*?timelineItems\(([^)]*)\)")

    def __init__(self, timelines, head=HEAD):
        self.timelines, self.head, self.queries = timelines, head, []

    def __call__(self, query, variables):
        self.queries.append((query, dict(variables)))
        repo = {}
        for number, first, args in self.FIELD.findall(query):
            n = int(number)
            kinds = re.search(r"itemTypes: \[([^\]]*)\]", args).group(1)
            last = int(re.search(r"last: (\d+)", args).group(1))
            since = re.search(r"since: \$(\w+)", args)
            before = re.search(r"before: \$(\w+)", args)
            items = [(i, x) for i, x in enumerate(self.timelines[n])
                     if ("ISSUE_COMMENT" in kinds and x["__typename"] == "IssueComment")
                     or ("PULL_REQUEST_REVIEW" in kinds and x["__typename"] == "PullRequestReview")]
            if since:
                items = [(i, x) for i, x in items if rr.at(x) >= variables[since.group(1)]]
            if before:
                items = [(i, x) for i, x in items if i < int(variables[before.group(1)])]
            page = items[-last:]
            pr = {"timelineItems": {"pageInfo": {"hasPreviousPage": len(items) > len(page),
                                                 "startCursor": str(page[0][0]) if page else None},
                                    "nodes": [x for _, x in page]}}
            if first:
                pr["headRefOid"] = self.head
            repo[f"p{n}"] = pr
        return {"repository": repo}


class Reader(unittest.TestCase):
    def test_a_receipt_deep_in_a_busy_prs_timeline_is_found_and_an_old_heads_is_not(self):
        # 200 items; the head's receipt is the 120th newest, a receipt naming an old head the 3rd newest.
        timeline = [item(n) for n in range(200)]
        timeline[80] = item(80, f"Review (codex): SHIP at {HEAD}", kind="PullRequestReview")
        timeline[197] = item(197, f"Review (codex): SHIP at {OLD}")
        gh = FakeGitHub({7: timeline})
        found, complete = rr.receipts(gh, "o/r", 7)
        self.assertEqual([x["databaseId"] for x in found], [80])
        self.assertFalse(complete)  # stopped once it had the receipt
        self.assertEqual(len(gh.queries), 3)  # 50, then 2 pages back
        # the old windows would have missed it
        self.assertNotIn(timeline[80], timeline[-30:] + timeline[-40:])

    def test_a_pr_with_no_receipt_is_read_back_only_to_the_bound_and_says_so(self):
        gh = FakeGitHub({7: [item(n) for n in range(400)]})
        found, complete = rr.receipts(gh, "o/r", 7)
        self.assertEqual((found, complete), ([], False))
        self.assertEqual(len(gh.queries), 1 + rr.MORE_PAGES)

    def test_since_bounds_the_read_and_a_short_timeline_is_complete(self):
        timeline = [item(n, f"Review (x): SHIP at {HEAD}" if n == 5 else "status") for n in range(60)]
        gh = FakeGitHub({7: timeline})
        found, complete = rr.receipts(gh, "o/r", 7, since=rr.at(timeline[20]))
        self.assertEqual((found, complete), ([], True))  # the one receipt is older than since
        self.assertEqual(len(gh.queries), 1)
        self.assertIn("since: $s7", gh.queries[0][0])

    def test_many_prs_share_each_query_and_only_those_still_looking_page_back(self):
        busy = [item(n) for n in range(120)]
        busy[10] = item(10, f"Review (x): SHIP at {HEAD}")
        quiet = [item(n, f"Review (x): SHIP at {HEAD}" if n == 2 else "x") for n in range(5)]
        gh = FakeGitHub({1: busy, 2: quiet})
        out = rr.read(gh, "o/r", [1, 2], lambda items, head: any(rr.names_head(i, head) for i in items))
        self.assertEqual(len(gh.queries), 3)
        self.assertNotIn("p2:", gh.queries[1][0])
        self.assertEqual(len(out[1]["items"]), 120)
        self.assertEqual([x["databaseId"] for x in out[1]["items"][:2]], [0, 1])  # oldest first
        self.assertTrue(out[2]["complete"])

    def test_comment_only_reads_and_a_marker_predicate(self):
        timeline = [item(n) for n in range(150)]
        timeline[3] = item(3, "<!-- tool-marker -->\nhello")
        timeline[149] = item(149, "a review", kind="PullRequestReview")
        gh = FakeGitHub({4: timeline})
        found = rr.read(gh, "o/r", [4], lambda items, _: any("<!-- tool-marker" in i["body"] for i in items),
                        types=("ISSUE_COMMENT",), page=100)[4]
        self.assertIn(timeline[3], found["items"])
        self.assertNotIn(timeline[149], found["items"])
        self.assertIn("itemTypes: [ISSUE_COMMENT]", gh.queries[0][0])

    def test_what_names_a_head(self):
        self.assertTrue(rr.names_head({"body": f"Review (codex): BLOCK at {HEAD[:8]}"}, HEAD))
        self.assertTrue(rr.names_head({"body": f"<!-- autoreview verdict=SHIP sha={HEAD} -->"}, HEAD))
        self.assertFalse(rr.names_head({"body": f"<!-- autoreview verdict=SHIP sha={OLD} -->\nReview (x): SHIP at "
                                                f"{HEAD}"}, HEAD))
        self.assertTrue(rr.names_head({"state": "APPROVED", "commit": {"oid": HEAD}, "body": ""}, HEAD))
        self.assertFalse(rr.names_head({"body": f"status: SHIP at {HEAD}"}, HEAD))  # not a receipt line
        self.assertFalse(rr.names_head({"body": f"Review (x): SHIP at {HEAD}"}, ""))

    def test_an_answer_with_no_pull_request_is_an_error_not_none(self):
        with self.assertRaises(rr.ReadError):
            rr.read(lambda q, v: {"repository": {"p7": None}}, "o/r", [7])
        with self.assertRaises(rr.ReadError):
            rr.read(lambda q, v: {}, "o/r", [7])

    def test_split_gives_the_reviews_and_comments_shape(self):
        timeline = [item(0, kind="PullRequestReview"), item(1)]
        pr = rr.split(rr.read(FakeGitHub({7: timeline}), "o/r", [7])[7])
        self.assertEqual((len(pr["reviews"]["nodes"]), len(pr["comments"]["nodes"]), pr["headRefOid"]), (1, 1, HEAD))
        self.assertTrue(pr["reviews"]["complete"])

    def test_gh_graphql_raises_on_a_failed_or_partial_answer(self):
        self.assertEqual(rr.gh_graphql(lambda argv: (0, json.dumps({"data": {"a": 1}}), ""))("q", {"x": "y"}),
                         {"a": 1})
        for answer in ((1, "", "HTTP 502"), (0, "not json", ""), (0, json.dumps({"errors": [{"m": 1}]}), "")):
            with self.assertRaises(rr.ReadError):
                rr.gh_graphql(lambda argv, a=answer: a)("q", {})


class ReceiptReadLint(unittest.TestCase):
    def test_no_newest_n_receipt_read_outside_the_shared_reader(self):
        problems = rr.lint(str(ROOT), ["scripts"], ALLOWED)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_lint_sees_the_shapes_it_refuses(self):
        refused = ['q = "comments(last: 100) { nodes { body } }"  # finds the SHIP at receipt',
                   'f"reviews(last:{N}){{nodes{{body}}}}"  # verdict',
                   'timelineItems(itemTypes: [ISSUE_COMMENT], last: 20)  # <!-- marker']
        for text in refused:
            self.assertTrue(rr.windowed_reads(text), text)
        for text in ('comments(last: 1) { nodes { createdAt } }  # activity only',
                     'timelineItems(last: 50, itemTypes: [LABELED_EVENT])  # receipt',
                     'comments(first: 100, after: $after)  # receipt'):
            self.assertFalse(rr.windowed_reads(text), text)


if __name__ == "__main__":
    unittest.main()
