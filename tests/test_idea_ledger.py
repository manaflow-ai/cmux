#!/usr/bin/env python3
"""scripts/cmux-next/idea-ledger.py joins beads, pull requests and asks into one ledger.

Replays canned GitHub data (--replay) with a fake bd (BEADS_BD_COMMAND) and a
PATH whose gh answers only the nightly's commit listing: the test never reaches
GitHub, the board or a model.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/idea-ledger.py"
NOW = "2026-10-18T12:00:00Z"
FRESH = "2026-10-18T09:00:00Z"
OLD = "2026-10-14T09:00:00Z"
SHIPPED_SHA = "a" * 40
UNSHIPPED_SHA = "b" * 40


def pull(number, title, files, moved=FRESH, body="", comments=(), mergeable="MERGEABLE", state="SUCCESS"):
    return {"number": number, "title": title, "body": body, "url": f"https://github.com/manaflow-ai/cmux/pull/{number}",
            "createdAt": moved, "isDraft": False, "mergeable": mergeable, "headRefName": f"branch-{number}",
            "author": {"login": "teamleaderleo"},
            "files": {"nodes": [{"path": f} for f in files]},
            "commits": {"nodes": [{"commit": {"committedDate": moved, "statusCheckRollup": {"state": state}}}]},
            "comments": {"nodes": [{"body": c, "createdAt": moved, "author": {"login": "github-actions[bot]"}}
                                   for c in comments]}}


STATUS = ["Sources/Sidebar/WorkspaceRowView+StatusGlyph.swift", "Sources/Sidebar/StatusIndicatorAppearance.swift"]
RAW = {
    "open": [
        # Two attempts at one status indicator: same rare files, alike titles.
        pull(1, "Sidebar status indicator: animated running dot", STATUS, mergeable="CONFLICTING", state="FAILURE"),
        pull(2, "Sidebar status indicator on the left of rows", STATUS + ["Sources/Sidebar/Row.swift"]),
        # Owned through its bead, but nothing moved for four days.
        pull(3, "Now Playing card (cx-np1)", ["Sources/NowPlaying/Card.swift"], moved=OLD),
        # Linked by the bead-autoclose comment, not the title.
        pull(4, "Settings: font size", ["Sources/Settings/Font.swift"],
             comments=["Bead `cx-font1` created for this PR by the cmux coordinator."]),
        # Unrelated work, so shared files are rare the way they are on the real branch.
        *(pull(100 + n, f"{word} change", [f"Sources/{word}/File.swift"])
          for n, word in enumerate("Alpha Bravo Charlie Delta Echo Foxtrot Golf Hotel India Juliet".split())),
    ],
    "merged": [
        {"number": 10, "title": "Shipped thing", "url": "https://github.com/manaflow-ai/cmux/pull/10",
         "mergedAt": "2026-10-17T00:00:00Z", "mergeCommit": {"oid": SHIPPED_SHA}, "author": {"login": "a"},
         "body": "Closes #50", "comments": {"nodes": [{"body": "gallery: verified https://gallery.example/pr/10"}]}},
        {"number": 11, "title": "Merged after the nightly", "url": "https://github.com/manaflow-ai/cmux/pull/11",
         "mergedAt": "2026-10-18T10:00:00Z", "mergeCommit": {"oid": UNSHIPPED_SHA}, "author": {"login": "b"},
         "body": "", "comments": {"nodes": []}},
    ],
    "issues": [
        {"number": 50, "title": "Ask that landed", "url": "https://github.com/manaflow-ai/cmux/issues/50",
         "createdAt": OLD, "updatedAt": OLD, "author": {"login": "teamleaderleo"}, "assignees": {"nodes": []}},
        {"number": 51, "title": "Ask nobody took", "url": "https://github.com/manaflow-ai/cmux/issues/51",
         "createdAt": OLD, "updatedAt": OLD, "author": {"login": "lawrencecchen"}, "assignees": {"nodes": []}},
    ],
    "nightly": {"tag": "nightly-next 1", "sha": "c" * 40, "url": "https://example/nightly"},
}
BEADS = [
    {"id": "cx-np1", "title": "Now Playing card", "status": "in_progress", "assignee": "music-lane",
     "updated_at": OLD},
    {"id": "cx-font1", "title": "Settings: font size", "status": "open", "assignee": "",
     "external_ref": "https://github.com/manaflow-ai/cmux/pull/4", "updated_at": FRESH},
    {"id": "cx-idea1", "title": "Chat-only idea", "status": "open", "assignee": "", "updated_at": FRESH},
    {"id": "cx-build1", "title": "Being built", "status": "in_progress", "assignee": "lane-x", "updated_at": FRESH},
    {"id": "cx-done1", "title": "Dropped", "status": "closed", "assignee": "", "updated_at": OLD},
    {"id": "cx-umb1", "title": "An umbrella many PRs name", "status": "open", "assignee": "", "updated_at": FRESH},
]

FAKE_GH = """#!/usr/bin/env python3
import sys
path = sys.argv[2] if len(sys.argv) > 2 else ""
if sys.argv[1:2] == ["api"] and "/commits?sha=" in path:
    print(%(shipped)r)  # the published nightly contains only the shipped merge
    raise SystemExit
raise SystemExit("unexpected gh call: " + " ".join(sys.argv[1:]))
"""
FAKE_BD = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
assert "--readonly" in args, args
for word in ("create", "close", "update", "comment"):
    assert word not in args, args
if "--all" in args and os.environ.get("BD_FAIL_ALL"):
    raise SystemExit("the closed list timed out")
print(json.dumps(json.loads(open(%(beads)r).read())))
"""


class IdeaLedgerTest(unittest.TestCase):
    def run_ledger(self, *extra, raw=None, env_extra=None):
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "bin").mkdir()
        (temp / "bin/gh").write_text(FAKE_GH % {"shipped": SHIPPED_SHA})
        (temp / "beads.json").write_text(json.dumps(BEADS))
        (temp / "bd").write_text(FAKE_BD % {"beads": str(temp / "beads.json")})
        (temp / "raw.json").write_text(json.dumps(raw or RAW))
        for tool in ("bin/gh", "bd"):
            (temp / tool).chmod(0o755)
        env = {**os.environ, "PATH": f"{temp / 'bin'}:{os.environ['PATH']}", "BEADS_BD_COMMAND": str(temp / "bd")}
        env.pop("BEADS_SSH_HOST", None)
        env.update(env_extra or {})
        result = subprocess.run([sys.executable, str(SCRIPT), "--out", str(temp / "out"), "--replay",
                                 str(temp / "raw.json"), "--no-model", "--now", NOW, *extra],
                                cwd=temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        ledger = json.loads((temp / "out/ledger.json").read_text())
        self.markdown = (temp / "out/ledger.md").read_text()
        return {tuple(item["prs"]) or tuple(item["beads"]) or ("issue", *item["issues"]): item
                for item in ledger["items"]}, ledger, (temp / "out/index.html").read_text()

    def test_duplicates_fold_into_the_mergeable_green_pull_request(self):
        items, _, page = self.run_ledger()
        status = items[(1, 2)]
        self.assertEqual(status["state"], "pr-open")
        self.assertEqual(status["keeper"], 2)
        self.assertEqual(status["fold"], [1])
        self.assertIn("duplicates", status["flags"])
        self.assertIn("fold", page)

    def test_owner_and_stall(self):
        items, _, _ = self.run_ledger()
        playing = items[(3,)]
        self.assertEqual(playing["owner"], "music-lane")
        self.assertIn("stalled", playing["flags"])
        font = items[(4,)]
        self.assertEqual(font["beads"], ["cx-font1"])
        self.assertEqual(font["owner"], "#4 (branch-4)")
        self.assertNotIn("stalled", font["flags"])

    def test_board_only_items(self):
        items, _, _ = self.run_ledger()
        self.assertEqual(items[("cx-idea1",)]["state"], "idea")
        self.assertIn("no-owner", items[("cx-idea1",)]["flags"])
        self.assertEqual(items[("cx-build1",)]["state"], "building")
        self.assertNotIn(("cx-done1",), items)
        self.assertEqual(items[("issue", 51)]["state"], "idea")

    def test_landed_states(self):
        items, _, _ = self.run_ledger()
        shipped = items[(10,)]
        self.assertEqual(shipped["state"], "verified")
        self.assertEqual(shipped["issues"], [50])
        self.assertEqual(shipped["nightly"]["tag"], "nightly-next 1")
        self.assertEqual(items[(11,)]["state"], "merged")

    def test_stuck_items_sort_first(self):
        _, ledger, _ = self.run_ledger()
        first = ledger["items"][0]
        self.assertTrue({"stalled", "no-owner"} & set(first["flags"]), first)

    def test_passing_mentions_and_words_do_not_link(self):
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        raw = json.loads(json.dumps(RAW))
        # A body that mentions another PR's bead, and a branch name that looks like a bead.
        raw["open"][3]["body"] = "Follows the Now Playing work (cx-np1) on cx-next."
        (temp / "raw.json").write_text(json.dumps(raw))
        items, _, _ = self.run_ledger("--replay", str(temp / "raw.json"))
        self.assertEqual(items[(4,)]["beads"], ["cx-font1"])
        self.assertEqual(items[(3,)]["beads"], ["cx-np1"])

    def test_an_umbrella_bead_does_not_chain_its_pull_requests(self):
        raw = json.loads(json.dumps(RAW))
        for pr in raw["open"][4:9]:
            pr["title"] += " (cx-umb1)"
        items, _, _ = self.run_ledger(raw=raw)
        for pr in raw["open"][4:9]:
            self.assertIn((pr["number"],), items)
            self.assertEqual(items[(pr["number"],)]["fold"], [])

    def test_a_pull_request_joins_only_its_first_cluster(self):
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "clusters.json").write_text(json.dumps([{"name": "a", "prs": [100, 101]},
                                                        {"name": "b", "prs": [101, 102]}]))
        items, _, _ = self.run_ledger("--clusters", str(temp / "clusters.json"))
        self.assertEqual(items[(100, 101)]["cluster"]["name"], "a")
        self.assertIn((102,), items)

    def test_a_title_cannot_hide_the_issue_body(self):
        raw = json.loads(json.dumps(RAW))
        raw["open"][4]["title"] = "<!-- folded 0 --> sneaky <!--"
        raw["open"][4]["createdAt"] = "2026-10-10T00:00:00Z"
        raw["open"][4]["commits"]["nodes"][0]["commit"]["committedDate"] = "2026-10-10T00:00:00Z"
        self.run_ledger(raw=raw)
        self.assertNotIn("<!-- folded 0 --> sneaky", self.markdown)
        self.assertIn("&lt;!-- folded 0 --&gt; sneaky", self.markdown)
        self.assertNotIn("<!--", self.markdown.replace("<!-- folded", ""))

    def test_a_failed_closed_list_keeps_the_open_beads(self):
        items, ledger, _ = self.run_ledger(env_extra={"BD_FAIL_ALL": "1"})
        self.assertIn(("cx-idea1",), items)
        self.assertEqual(ledger["meta"]["beads_source"], "board")

    def test_curated_clusters_win(self):
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (temp / "clusters.json").write_text(json.dumps([{"name": "font and playing", "prs": [3, 4]}]))
        items, _, _ = self.run_ledger("--clusters", str(temp / "clusters.json"))
        merged = items[(3, 4)]
        self.assertEqual(merged["cluster"]["name"], "font and playing")
        self.assertEqual(merged["fold"], [3])


if __name__ == "__main__":
    unittest.main()
