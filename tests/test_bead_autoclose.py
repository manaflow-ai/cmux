#!/usr/bin/env python3
"""scripts/cmux-next/bead-autoclose.py closes the beads merged pull requests name.

Runs the script against a fake gh (canned GraphQL answers) and a fake bd
(BEADS_BD_COMMAND, which logs its arguments), with a PATH whose ssh records any
call: the test never reaches GitHub or the real board.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/bead-autoclose.py"

MERGED = [
    {"number": 1, "title": "fix: a (cx-task1)", "mergedAt": "2026-10-10T01:00:00Z",
     "mergeCommit": {"oid": "a" * 40}, "baseRefName": "feat-cmux-next"},
    {"number": 2, "title": "feat: b (cx-epic1, cx-done1)", "mergedAt": "2026-10-10T02:00:00Z",
     "mergeCommit": {"oid": "b" * 40}, "baseRefName": "feat-cmux-next"},
    {"number": 3, "title": "fix: c part 1 (cx-multi)", "mergedAt": "2026-10-10T03:00:00Z",
     "mergeCommit": {"oid": "c" * 40}, "baseRefName": "main"},
    {"number": 4, "title": "fix: d part 1 (cx-slice)", "mergedAt": "2026-10-10T04:00:00Z",
     "mergeCommit": {"oid": "d" * 40}, "baseRefName": "feat-cmux-next", "body": "First slice."},
    {"number": 5, "title": "feat: e", "mergedAt": "2026-10-10T05:00:00Z", "mergeCommit": {"oid": "e" * 40},
     "baseRefName": "feat-cmux-next", "body": "The last piece.\n\nCloses cx-body1"},
    {"number": 6, "title": "fix: f (cx-slice2) 2/3", "mergedAt": "2026-10-10T06:00:00Z",
     "mergeCommit": {"oid": "f" * 40}, "baseRefName": "feat-cmux-next", "body": "Also see cx-other."},
]
OPEN = [{"number": 9, "title": "fix: c part 2 (cx-multi)", "baseRefName": "feat-cmux-next"}]
BEADS = {
    "cx-task1": {"status": "in_progress", "issue_type": "task", "assignee": "op-lane"},
    "cx-epic1": {"status": "open", "issue_type": "epic", "assignee": ""},
    "cx-done1": {"status": "closed", "issue_type": "task", "assignee": "op-lane"},
    "cx-multi": {"status": "open", "issue_type": "bug", "assignee": "unassigned"},
    "cx-slice": {"status": "open", "issue_type": "task", "assignee": "op-lane"},
    "cx-body1": {"status": "open", "issue_type": "task", "assignee": "op-lane"},
    "cx-slice2": {"status": "open", "issue_type": "task", "assignee": "op-lane"},
    "cx-other": {"status": "open", "issue_type": "task", "assignee": "op-lane"},
}

FAKE_GH = """#!/usr/bin/env python3
import json, sys
if not any(arg.startswith("q=") for arg in sys.argv):
    open(%(gh_log)r, "a").write(json.dumps(sys.argv[1:]) + "\\n")
    print(json.dumps({"data": {"addComment": {"commentEdge": {"node": {"url": "comment-url"}}}}}))
    raise SystemExit
query = next(arg[2:] for arg in sys.argv if arg.startswith("q="))
nodes = json.loads(open(%(open)r).read()) if "is:open" in query else json.loads(open(%(merged)r).read())
since = next((word[len("merged:>="):] for word in query.split() if word.startswith("merged:>=")), "")
nodes = [node for node in nodes if node.get("mergedAt", since) >= since]
print(json.dumps({"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}))
"""
FAKE_BD = """#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
open(%(log)r, "a").write(json.dumps(args) + "\\n")
beads = json.loads(open(%(beads)r).read())
if args[0] == "show":
    bead = beads.get(args[1])
    if bead is None:
        sys.exit(1)
    print(json.dumps([dict(bead, id=args[1])]))
elif args[0] == "children":
    print("[]")
elif args[0] == "list":
    print(json.dumps([{"id": bead_id, "external_ref": bead.get("external_ref", "")}
                      for bead_id, bead in beads.items()]))
elif "create" in args:
    print(json.dumps({"id": "cx-created"}))
"""
RECORDING = "#!/bin/sh\necho \"$0 $*\" >> %(log)r\nexit 1\n"


class BeadAutocloseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-bead-autoclose-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.bd_log, self.gh_log, self.ssh_log = root / "bd.log", root / "gh.log", root / "ssh.log"
        (root / "merged.json").write_text(json.dumps(MERGED))
        (root / "open.json").write_text(json.dumps(OPEN))
        (root / "beads.json").write_text(json.dumps(BEADS))
        self.write(self.bin / "gh", FAKE_GH % {"open": str(root / "open.json"), "merged": str(root / "merged.json"), "gh_log": str(self.gh_log)})
        self.fake_bd = root / "fake-bd"
        self.write(self.fake_bd, FAKE_BD % {"log": str(self.bd_log), "beads": str(root / "beads.json")})
        self.write(self.bin / "ssh", RECORDING % {"log": str(self.ssh_log)})
        self.state = root / "state"
        self.env = {"PATH": f"{self.bin}{os.pathsep}{os.path.dirname(sys.executable)}{os.pathsep}/usr/bin:/bin",
                    "HOME": str(root), "BEAD_AUTOCLOSE_STATE": str(self.state)}

    @staticmethod
    def write(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, *args, **env):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], env=dict(self.env, **env),
                              text=True, capture_output=True)

    def bd_calls(self, verb):
        lines = self.bd_log.read_text().splitlines() if self.bd_log.exists() else []
        return [json.loads(line) for line in lines if verb in json.loads(line)]

    def test_closes_landed_beads_and_comments_on_partial_ones(self):
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(result.returncode, 0, result.stderr)
        closes = self.bd_calls("close")
        self.assertEqual([call[3] for call in closes], ["cx-task1", "cx-body1"], closes)
        self.assertEqual(closes[0][:4], ["--actor", "leo", "close", "cx-task1"])
        self.assertIn(f"landed {'a' * 12} (#1): fix: a (cx-task1)", closes[0][5])
        comments = {call[3]: call for call in self.bd_calls("comment")}
        # A part or slice marker in the title is a partial landing: a comment
        # with the pull request link, never a close. Body references are handled
        # too, so the referenced bead gets the same landing comment.
        self.assertEqual(sorted(comments), ["cx-epic1", "cx-multi", "cx-other", "cx-slice", "cx-slice2"])
        self.assertIn("https://github.com/manaflow-ai/cmux/pull/4", comments["cx-slice"][4])
        self.assertIn("https://github.com/manaflow-ai/cmux/pull/6", comments["cx-slice2"][4])
        self.assertIn("https://github.com/manaflow-ai/cmux/pull/6", comments["cx-other"][4])
        self.assertEqual(comments["cx-epic1"][1], "leo")
        self.assertEqual(comments["cx-multi"][1], "leo")  # "unassigned" acts as leo
        self.assertIn("not closed", comments["cx-multi"][4])
        self.assertFalse(self.ssh_log.exists(), "the test reached ssh")

    def test_an_explicit_closes_line_closes_despite_other_open_pull_requests(self):
        root = Path(self.temporary.name)
        merged = [{"number": 7, "title": "fix: c part 2 (cx-multi)", "mergedAt": "2026-10-10T07:00:00Z",
                   "mergeCommit": {"oid": "7" * 40}, "baseRefName": "feat-cmux-next",
                   "body": "Fixes cx-multi."}]
        (root / "merged.json").write_text(json.dumps(merged))
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[3] for call in self.bd_calls("close")], ["cx-multi"], result.stdout)
        self.assertEqual(self.bd_calls("comment"), [])

    def test_body_and_commit_references_are_each_handled_as_beads(self):
        root = Path(self.temporary.name)
        merged = [{"number": 8, "title": "fix: references", "mergedAt": "2026-10-10T08:00:00Z",
                   "mergeCommit": {"oid": "8" * 40}, "baseRefName": "feat-cmux-next",
                   "body": "Related to cx-body2.",
                   "commits": {"nodes": [{"message": "Implement cx-commit2"}]}}]
        beads = dict(BEADS, **{
            "cx-body2": {"status": "open", "issue_type": "task", "assignee": "lane"},
            "cx-commit2": {"status": "open", "issue_type": "task", "assignee": "lane"},
        })
        (root / "merged.json").write_text(json.dumps(merged))
        (root / "beads.json").write_text(json.dumps(beads))
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[3] for call in self.bd_calls("close")], ["cx-body2", "cx-commit2"])

    def test_open_beadless_pr_gets_a_bead_and_nothing_on_the_pr(self):
        root = Path(self.temporary.name)
        (root / "open.json").write_text(json.dumps([{
            "id": "pr-node", "number": 10, "title": "feat: automatic bead",
            "body": "No tracker id yet.", "url": "https://github.com/manaflow-ai/cmux/pull/10",
            "baseRefName": "feat-cmux-next",
        }]))
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(result.returncode, 0, result.stderr)
        creates = [call for call in self.bd_calls("create")]
        self.assertEqual(len(creates), 1)
        self.assertEqual(creates[0][:3], ["--actor", "leo", "create"])
        self.assertIn("--external-ref", creates[0])
        self.assertIn("https://github.com/manaflow-ai/cmux/pull/10", creates[0])
        # The bead's external reference is the link: no comment, status line or dispatch on the PR
        # (Leo, 2026-10-29: "we want to use beads, but we don't want to fucking waste usage").
        self.assertFalse(self.gh_log.exists() and self.gh_log.read_text().strip(), "wrote to GitHub")

    def test_a_pr_a_bead_already_references_gets_no_second_bead(self):
        root = Path(self.temporary.name)
        beads = json.loads((root / "beads.json").read_text())
        beads["cx-old1"] = {"status": "open", "issue_type": "task", "assignee": "",
                            "external_ref": "https://github.com/manaflow-ai/cmux/pull/10"}
        (root / "beads.json").write_text(json.dumps(beads))
        (root / "open.json").write_text(json.dumps([{
            "id": "pr-node", "number": 10, "title": "feat: automatic bead",
            "url": "https://github.com/manaflow-ai/cmux/pull/10", "baseRefName": "feat-cmux-next",
        }]))
        # A fresh state file (another host, or a lost one) must not duplicate the bead.
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd),
                                 BEAD_AUTOCLOSE_STATE=str(root / "fresh-state"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bd_calls("create"), [])

    def test_a_second_run_does_not_repeat_comments_or_closes(self):
        # The search starts at (or before) the last merge handled, so it sees that merge again.
        first = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(first.returncode, 0, first.stderr)
        before = len(self.bd_calls("close")) + len(self.bd_calls("comment"))
        second = self.run_script(BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(self.bd_calls("close")) + len(self.bd_calls("comment")), before, second.stdout)

    def test_an_unreachable_board_keeps_the_merges_for_the_next_run(self):
        down = Path(self.temporary.name) / "board-down"
        self.write(down, "#!/bin/sh\nexit 255\n")  # ssh's own failure status
        result = self.run_script("--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(down))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("not on the board", result.stdout)
        later = self.run_script(BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(later.returncode, 0, later.stderr)
        self.assertEqual([call[3] for call in self.bd_calls("close")], ["cx-task1", "cx-body1"], later.stdout)

    def test_dry_run_changes_nothing(self):
        result = self.run_script("--dry-run", "--since", "2026-10-10T00:00:00Z", BEADS_BD_COMMAND=str(self.fake_bd))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("close cx-task1 as leo", result.stdout)
        self.assertEqual(self.bd_calls("close") + self.bd_calls("comment"), [])
        self.assertFalse(self.state.exists())

    def test_refuses_without_a_board(self):
        result = self.run_script("--since", "2026-10-10T00:00:00Z")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.ssh_log.exists(), "the test reached ssh")
        self.assertFalse(self.bd_log.exists())


if __name__ == "__main__":
    unittest.main()
