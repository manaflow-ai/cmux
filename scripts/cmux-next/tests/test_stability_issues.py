#!/usr/bin/env python3
"""stability_issues.py keeps one GitHub issue per signature, with gh faked.

1. Idempotent: two findings of one signature make one issue with count 2; syncing the same run again writes nothing.
2. Closing needs a verified fix and 3 distinct clean tips that contain the fix and ran a lane and major that found
   the signature; tips without the fix, tips that ran other lanes and repeated tips do not count.
3. A finding on a build with the fix resets the fix and reopens a closed issue; one from a build without the fix only
   counts; an issue a person closed as not planned or duplicate stays closed, with one comment.
4. A build git cannot place relative to the fix counts as a recurrence (reopens, resets) and never as a clean tip;
   a fix git cannot resolve is refused; GitAncestry fetches a commit the checkout lacks.
5. bisect-result and fix-verified update the issue once; the state block survives `-->` in frame names.
6. Writes past --max-writes or the graphql or core reserve are deferred with exit 75 and the same sync finishes
   them; label creates count as writes and a deferred signature creates none.
7. Two issues for one signature (a race between hosts) are merged into the lowest and the other closed, once;
   a sync holds the host repo lock while it reads and writes.
8. The gh CLI adapter, end to end against a fake `gh` executable: one issue list read per sync, labels created only
   when an issue is created, the run file applied once, and both rate buckets read.
9. Sentry import (task 035), fed stability-health.py's recorded --json output: one Sentry issue is one GitHub issue
   and keeps its link through re-imports, lab syncs and a raced create; a Sentry issue that already links a GitHub
   issue or that another owner claims is not imported; an import never resets a fix or reopens; a bad report is
   refused, and stdin is read, before the lock and any read.

    python3 -I -m pytest scripts/cmux-next/tests/test_stability_issues.py
    python3 -I -m unittest discover -s scripts/cmux-next/tests -p test_stability_issues.py
"""

from __future__ import annotations

import fcntl
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import stability_issues as si  # noqa: E402

SCRIPT = HERE / "stability_issues.py"
H1 = "0123456789ab"
H2 = "fedcba987654"
FIX = "f" * 40


def sha(n: int) -> str:
    return f"{n:040x}"


class FakeGitHub:
    """GitHub in memory, with every call recorded."""

    def __init__(self) -> None:
        self.issues: dict[int, si.Issue] = {}
        self.comments: dict[int, list[str]] = {}
        self.calls: list[str] = []
        self.labels: set[str] = set()
        self.remaining: dict[str, int] | None = {"core": 5000, "graphql": 5000}

    def list_issues(self, label: str) -> list[si.Issue]:
        self.calls.append(f"list {label}")
        return [si.Issue(**vars(issue)) for issue in self.issues.values() if label in issue.labels]

    def existing_labels(self) -> set[str]:
        self.calls.append("list labels")
        return set(self.labels)

    def create_label(self, name: str) -> None:
        self.calls.append(f"label {name}")
        self.labels.add(name)

    def create_issue(self, title: str, body: str, labels: list[str]) -> int:
        self.calls.append("create")
        missing = [name for name in labels if name not in self.labels]
        assert not missing, f"issue created before its labels: {missing}"
        number = max(self.issues, default=0) + 1
        self.issues[number] = si.Issue(number, "OPEN", "", title, body, list(labels))
        return number

    def edit_issue(self, number: int, title: str, body: str) -> None:
        self.calls.append(f"edit {number}")
        self.issues[number].title, self.issues[number].body = title, body

    def comment(self, number: int, text: str) -> None:
        self.calls.append(f"comment {number}")
        self.comments.setdefault(number, []).append(text)

    def close_issue(self, number: int, text: str, reason: str) -> None:
        self.calls.append(f"close {number}")
        reason_name = {"completed": "COMPLETED", "not planned": "NOT_PLANNED"}[reason]
        self.issues[number].state, self.issues[number].state_reason = "CLOSED", reason_name
        self.comments.setdefault(number, []).append(text)

    def reopen_issue(self, number: int, text: str) -> None:
        self.calls.append(f"reopen {number}")
        self.issues[number].state, self.issues[number].state_reason = "OPEN", "REOPENED"
        self.comments.setdefault(number, []).append(text)

    def rate_remaining(self) -> dict[str, int] | None:
        self.calls.append("rate_limit")
        return self.remaining

    def state(self, number: int = 1) -> dict:
        state = si.read_state(self.issues[number].body)
        assert state is not None
        return state

    def writes(self) -> list[str]:
        return [call for call in self.calls if not call.startswith(("list", "rate_limit"))]

    def label_writes(self) -> list[str]:
        return [call for call in self.calls if call.startswith("label ")]


def finding(hash12: str = H1, lane: str = "smoke", major: str = "26", build: str | None = None, **extra) -> dict:
    out = {"kind": "ips", "process": "cmux", "exception": "EXC_BREAKPOINT", "hash12": hash12, "lane": lane,
           "major": major, "frames": ["Workspace.close(_:)", "PaneStore.remove(_:)", "ActionRegistry.run(_:)"]}
    if build:
        out["sha"] = build
    out.update(extra)
    return out


def run(run_id: str, tip: str, findings: list[dict], lanes: list[tuple[str, str]] = (("smoke", "26"),)) -> dict:
    return {"schema": si.RUN_SCHEMA, "run": run_id, "tip": tip, "at": "2026-10-25T00:00:00Z",
            "lanes": [{"lane": lane, "major": major} for lane, major in lanes], "findings": findings}


def descends_from_fix(fix_tips: set[str], unknown: set[str] = frozenset()):
    """Ancestry: FIX is in exactly the tips listed; the `unknown` builds cannot be placed (None)."""
    return lambda ancestor, tip: None if ancestor != FIX or tip in unknown else tip in fix_tips


class Harness(unittest.TestCase):
    def setUp(self) -> None:
        self.gh = FakeGitHub()
        self.fixed: set[str] = set()
        self.unknown: set[str] = set()
        self.tmp = Path(tempfile.mkdtemp())
        self.notes: list[str] = []

    def cli(self, *argv: str) -> tuple[int, dict, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = si.main(["--lock-file", str(self.tmp / "lock"), *argv], github=self.gh,
                           is_ancestor=descends_from_fix(self.fixed, self.unknown))
        result = json.loads(out.getvalue() or "{}")
        self.notes = result.get("notes", [])
        return code, result, err.getvalue()

    def sync(self, data: dict, *flags: str) -> tuple[int, dict, str]:
        path = self.tmp / f"{data['run']}.json"
        path.write_text(json.dumps(data))
        return self.cli(*flags, "sync", str(path))


class IdempotenceTests(Harness):
    def test_same_signature_twice_is_one_issue_with_count_two(self) -> None:
        repro = {"minimal": "https://hq/minimal.jsonl", "seed": 7}
        code, _, _ = self.sync(run("r1", sha(1), [finding(major="26", repro=repro), finding(major="27")],
                                   lanes=[("smoke", "26"), ("smoke", "27")]))
        self.assertEqual(code, 0)
        self.assertEqual(len(self.gh.issues), 1)
        issue = self.gh.issues[1]
        state = self.gh.state()
        self.assertEqual(state["count"], 2)
        self.assertEqual(state["per_major"], {"26": 1, "27": 1})
        self.assertEqual(state["first_sha"], sha(1))
        self.assertEqual(sorted(issue.labels), sorted(["stability-sig", f"stability-sig:{H1}", "stability-kind:ips"]))
        self.assertIn(H1, issue.title)
        self.assertIn("Workspace.close(_:)", issue.title)
        self.assertIn("https://hq/minimal.jsonl", issue.body)
        self.assertIn("seed: 7", issue.body)
        self.assertIn("macOS 26 1, macOS 27 1", issue.body)

    def test_same_run_again_writes_nothing(self) -> None:
        data = run("r1", sha(1), [finding(), finding()])
        self.sync(data)
        self.gh.calls.clear()
        code, out, _ = self.sync(data)
        self.assertEqual(code, 0)
        self.assertEqual(self.gh.writes(), [])
        self.assertEqual(out["applied"], [])
        self.assertEqual(self.gh.state()["count"], 2)

    def test_second_run_updates_the_same_issue(self) -> None:
        self.sync(run("r1", sha(1), [finding()]))
        self.sync(run("r2", sha(2), [finding(build=sha(2))]))
        self.assertEqual(len(self.gh.issues), 1)
        state = self.gh.state()
        self.assertEqual((state["count"], state["first_sha"], state["last_sha"]), (2, sha(1), sha(2)))
        self.assertEqual(self.gh.calls.count("create"), 1)

    def test_issue_found_by_its_hash_label_alone(self) -> None:
        self.gh.issues[1] = si.Issue(1, "OPEN", "", "hand made", "no state", ["stability-sig", f"stability-sig:{H1}"])
        self.sync(run("r1", sha(1), [finding()]))
        self.assertEqual(len(self.gh.issues), 1)
        self.assertEqual(self.gh.state()["count"], 1)

    def test_bad_run_file_is_refused_without_writes(self) -> None:
        code, _, err = self.sync(run("r1", sha(1), [finding(hash12="NOT-HEX")]))
        self.assertEqual(code, 1)
        self.assertIn("hash12", err)
        self.assertEqual(self.gh.writes(), [])


class CloseTests(Harness):
    def setUp(self) -> None:
        super().setUp()
        self.sync(run("r0", sha(0), [finding()]))
        self.assertEqual(self.cli("fix-verified", "--hash12", H1, "--fix", FIX, "--evidence", "job 9")[0], 0)

    def clean(self, n: int, lanes=(("smoke", "26"),), with_fix: bool = True) -> None:
        if with_fix:
            self.fixed.add(sha(n))
        self.sync(run(f"c{n}", sha(n), [], lanes=list(lanes)))

    def test_three_clean_tips_with_the_fix_close(self) -> None:
        self.clean(1)
        self.clean(2)
        self.assertEqual(self.gh.issues[1].state, "OPEN")
        self.assertEqual(len(self.gh.state()["clean_tips"]), 2)
        self.clean(3)
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.assertIn("3 clean tips", self.gh.comments[1][-1])

    def test_no_close_without_a_verified_fix(self) -> None:
        self.sync(run("r9", sha(9), [finding(H2)]))
        for n in (1, 2, 3, 4):
            self.fixed.add(sha(n))
            self.sync(run(f"c{n}", sha(n), []))
        self.assertEqual(self.gh.issues[2].state, "OPEN")
        self.assertIsNone(self.gh.state(2)["fix"])

    def test_tips_without_the_fix_other_lanes_and_repeats_do_not_count(self) -> None:
        self.clean(1, with_fix=False)
        self.clean(2, lanes=[("chaos", "26")])
        self.clean(3, lanes=[("smoke", "27")])
        self.clean(4)
        self.sync(run("c4-again", sha(4), []))
        self.assertEqual(self.gh.state()["clean_tips"], [sha(4)])
        self.assertEqual(self.gh.issues[1].state, "OPEN")

    def test_unknown_ancestry_does_not_count(self) -> None:
        self.sync(run("c1", sha(1), []))  # git does not know the fix or the tip: None
        self.assertEqual(self.gh.state()["clean_tips"], [])

    def test_close_left_undone_is_retried_by_the_next_sync(self) -> None:
        self.clean(1)
        self.clean(2)
        state = self.gh.state()
        state["clean_tips"].append(sha(3))
        self.gh.issues[1].body = si.render_body(state)  # body written, close failed
        self.sync(run("c5", sha(5), [], lanes=[("other", "26")]))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")


class RecurrenceTests(Harness):
    def close_with_fix(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.cli("fix-verified", "--hash12", H1, "--fix", FIX, "--evidence", "job 9")
        for n in (1, 2, 3):
            self.fixed.add(sha(n))
            self.sync(run(f"c{n}", sha(n), []))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")

    def test_recurrence_on_a_build_with_the_fix_reopens_and_resets(self) -> None:
        self.close_with_fix()
        self.fixed.add(sha(4))
        self.sync(run("r4", sha(4), [finding()]))
        issue, state = self.gh.issues[1], self.gh.state()
        self.assertEqual(issue.state, "OPEN")
        self.assertIsNone(state["fix"])
        self.assertEqual(state["clean_tips"], [])
        self.assertEqual(state["fix_history"][0]["sha"], FIX)
        self.assertIn("Reopened", self.gh.comments[1][-1])
        self.assertIn("fix is reset", self.gh.comments[1][-1])
        self.assertLess(self.gh.calls.index("reopen 1"), len(self.gh.calls) - 1)  # body written after the reopen
        self.assertEqual(self.gh.calls[-1], "edit 1")

    def test_finding_from_a_build_without_the_fix_only_counts(self) -> None:
        self.close_with_fix()
        self.sync(run("r4", sha(4), [finding(build=sha(0))]))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.assertEqual(self.gh.state()["fix"]["sha"], FIX)
        self.assertEqual(self.gh.state()["count"], 2)

    def test_recurrence_on_an_open_issue_with_a_fix_resets_it_with_a_comment(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.cli("fix-verified", "--hash12", H1, "--fix", FIX, "--evidence", "job 9")
        self.fixed |= {sha(1), sha(2)}
        self.sync(run("c1", sha(1), []))
        self.sync(run("r2", sha(2), [finding()]))
        self.assertIsNone(self.gh.state()["fix"])
        self.assertEqual(self.gh.state()["clean_tips"], [])
        self.assertIn("fix is reset", self.gh.comments[1][-1])

    def test_not_planned_stays_closed(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.gh.issues[1].state, self.gh.issues[1].state_reason = "CLOSED", "NOT_PLANNED"
        self.sync(run("r1", sha(1), [finding()]))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.assertEqual(self.gh.state()["count"], 2)

    def test_closed_by_a_person_without_a_fix_reopens(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.gh.issues[1].state, self.gh.issues[1].state_reason = "CLOSED", "COMPLETED"
        self.sync(run("r1", sha(1), [finding()]))
        self.assertEqual(self.gh.issues[1].state, "OPEN")


class RecordTests(Harness):
    def test_bisect_result_is_recorded_once(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        argv = ("bisect-result", "--hash12", H1, "--first-bad", sha(5), "--range", f"{sha(1)}..{sha(9)}")
        self.assertEqual(self.cli(*argv)[0], 0)
        self.assertEqual(self.gh.state()["bisect"]["sha"], sha(5))
        self.assertIn(f"first bad commit {sha(5)}", self.gh.issues[1].body)
        self.gh.calls.clear()
        self.cli(*argv)
        self.assertEqual(self.gh.writes(), [])

    def test_flaky_bisect_blames_no_commit(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.cli("bisect-result", "--hash12", H1, "--flaky", "1/3")
        self.assertIn("flaky, reproduced 1/3", self.gh.issues[1].body)
        self.assertNotIn("sha", self.gh.state()["bisect"])

    def test_record_for_an_unknown_signature_fails(self) -> None:
        code, _, err = self.cli("fix-verified", "--hash12", H2, "--fix", FIX, "--evidence", "x")
        self.assertEqual(code, 1)
        self.assertIn(H2, err)

    def test_state_survives_comment_markers_in_frames(self) -> None:
        spoof = '<!-- stability-sig-state: {"hash12":"fedcba987654"} -->'
        frames = ["a-->b", spoof, "d`e"]
        self.sync(run("r0", sha(0), [finding(frames=frames)]))
        self.assertEqual(self.gh.state()["frames"], frames)
        self.assertEqual(self.gh.state()["hash12"], H1)
        self.sync(run("r1", sha(1), [finding(frames=frames)]))
        self.assertEqual((len(self.gh.issues), self.gh.state()["count"]), (1, 2))


class BudgetTests(Harness):
    def many(self, n: int) -> dict:
        return run("r1", sha(1), [finding(f"{i:012x}") for i in range(n)])

    def test_max_writes_counts_label_creates_and_the_same_sync_finishes(self) -> None:
        data = self.many(5)
        # The first new issue needs 3 labels and its create (4 writes), each later one its hash label and create.
        code, out, err = self.sync(data, "--max-writes", "6")
        self.assertEqual(code, si.EX_TEMPFAIL)
        self.assertEqual(len(self.gh.writes()), 6)
        self.assertEqual(len(self.gh.label_writes()), 4)
        self.assertEqual((len(self.gh.issues), len(out["deferred"])), (2, 3))
        self.assertIn("run the same command again", err)
        self.gh.calls.clear()
        code, _, _ = self.sync(data, "--max-writes", "6")
        self.assertEqual((code, len(self.gh.issues), len(self.gh.writes())), (0, 5, 6))
        self.assertTrue(all(self.gh.state(n)["count"] == 1 for n in self.gh.issues))
        self.assertEqual(len(self.gh.labels), 7)

    def test_a_deferred_signature_creates_no_labels(self) -> None:
        self.sync(self.many(3), "--max-writes", "4")
        self.assertEqual(len(self.gh.issues), 1)
        self.assertEqual(self.gh.labels, {"stability-sig", f"stability-sig:{0:012x}", "stability-kind:ips"})

    def test_max_writes_below_one_signature_still_applies_it(self) -> None:
        code, _, _ = self.sync(self.many(2), "--max-writes", "1")
        self.assertEqual((code, len(self.gh.issues)), (si.EX_TEMPFAIL, 1))

    def test_graphql_reserve_is_kept_when_core_is_high(self) -> None:
        self.gh.remaining = {"core": 5000, "graphql": si.RATE_RESERVE + 4}
        code, out, _ = self.sync(self.many(si.BUDGET_CHECK_AT))
        self.assertEqual(code, si.EX_TEMPFAIL)
        self.assertEqual(len(self.gh.issues), 4)
        self.assertIn("rate_limit", self.gh.calls)
        self.assertIn("graphql 504", " ".join(out["notes"]))

    def test_core_reserve_is_kept_for_label_creates(self) -> None:
        self.gh.remaining = {"core": si.RATE_RESERVE + 3, "graphql": 5000}
        code, _, _ = self.sync(self.many(si.BUDGET_CHECK_AT))
        self.assertEqual(code, si.EX_TEMPFAIL)
        self.assertEqual((len(self.gh.issues), len(self.gh.label_writes())), (1, 3))

    def test_small_runs_do_not_read_the_rate_limit_and_dry_run_writes_nothing(self) -> None:
        code, out, _ = self.sync(self.many(2), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(self.gh.writes(), [])
        self.assertNotIn("rate_limit", self.gh.calls)
        kinds = [entry.split()[0] for entry in out["applied"]]
        self.assertEqual((kinds.count("create"), kinds.count("label")), (2, 4))


class UnknownAncestryTests(Harness):
    """git cannot place a build relative to the fix: a finding counts as a recurrence, a clean tip does not count."""

    def verified(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.assertEqual(self.cli("fix-verified", "--hash12", H1, "--fix", FIX, "--evidence", "job 9")[0], 0)

    def test_closed_issue_reopens_on_a_recurrence_git_cannot_place(self) -> None:
        self.verified()
        for n in (1, 2, 3):
            self.fixed.add(sha(n))
            self.sync(run(f"c{n}", sha(n), []))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.unknown.add(sha(9))
        self.sync(run("r9", sha(9), [finding()]))
        self.assertEqual(self.gh.issues[1].state, "OPEN")
        self.assertIsNone(self.gh.state()["fix"])
        self.assertEqual(self.gh.state()["fix_history"][-1]["recurred_on"], sha(9))
        self.assertIn("could not tell", self.gh.comments[1][-1])
        self.assertTrue(any(sha(9) in note and "could not tell" in note for note in self.notes))

    def test_open_issue_does_not_close_after_a_recurrence_git_cannot_place(self) -> None:
        self.verified()
        self.unknown.add(sha(9))
        self.sync(run("r9", sha(9), [finding()]))
        for n in (1, 2, 3):
            self.fixed.add(sha(n))
            self.sync(run(f"c{n}", sha(n), []))
        self.assertEqual(self.gh.issues[1].state, "OPEN")
        self.assertIsNone(self.gh.state()["fix"])

    def test_unknown_clean_tip_is_noted_and_not_counted(self) -> None:
        self.verified()
        self.unknown.add(sha(1))
        self.sync(run("c1", sha(1), []))
        self.assertEqual(self.gh.state()["clean_tips"], [])
        self.assertTrue(any(sha(1) in note and "not counted" in note for note in self.notes))

    def test_fix_git_cannot_resolve_is_refused(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        code, _, err = self.cli("fix-verified", "--hash12", H1, "--fix", sha(77), "--evidence", "x")
        self.assertEqual(code, 1)
        self.assertIn("squash commit", err)
        self.assertIsNone(self.gh.state()["fix"])


class PersonCloseTests(Harness):
    def test_duplicate_close_stays_closed_with_one_comment(self) -> None:
        self.sync(run("r0", sha(0), [finding()]))
        self.gh.issues[1].state, self.gh.issues[1].state_reason = "CLOSED", "DUPLICATE"
        self.sync(run("r1", sha(1), [finding()]))
        self.sync(run("r2", sha(2), [finding()]))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.assertEqual(self.gh.state()["count"], 3)
        self.assertNotIn("reopen 1", self.gh.calls)
        self.assertEqual(len(self.gh.comments[1]), 1)
        self.assertIn("stays closed as duplicate", self.gh.comments[1][0])


class DuplicateIssueTests(Harness):
    """Two collectors on different hosts raced and made two issues for one signature."""

    def raced(self) -> None:
        other = FakeGitHub()
        self.sync(run("a", sha(1), [finding()]))
        first = self.gh
        self.gh = other
        self.sync(run("b", sha(2), [finding(major="27")], lanes=[("smoke", "27")]))
        self.gh = first
        dup = other.issues[1]
        self.gh.issues[2] = si.Issue(2, dup.state, dup.state_reason, dup.title, dup.body, list(dup.labels))

    def test_next_sync_merges_and_closes_the_higher_number(self) -> None:
        self.raced()
        self.sync(run("c", sha(3), [finding()]))
        self.assertEqual((self.gh.issues[2].state, self.gh.issues[2].state_reason), ("CLOSED", "NOT_PLANNED"))
        self.assertIn("Duplicate of #1", self.gh.comments[2][-1])
        state = self.gh.state(1)
        self.assertEqual((state["count"], state["per_major"]), (3, {"26": 2, "27": 1}))
        self.assertEqual(state["merged"], [2])
        self.gh.calls.clear()
        for again in ("a", "b", "c"):
            self.sync(run(again, sha(3), [finding()]))
        self.assertEqual(self.gh.writes(), [])
        self.assertEqual(self.gh.state(1)["count"], 3)

    def test_a_sync_without_the_signature_heals_it_too(self) -> None:
        self.raced()
        self.sync(run("c", sha(3), []))
        self.assertEqual(self.gh.issues[2].state, "CLOSED")
        self.assertEqual(self.gh.state(1)["count"], 2)


RECORDED_HEALTH = HERE / "tests" / "fixtures" / "stability-health" / "report-nightly-next.json"
HEALTH_SCRIPT = HERE / "stability-health.py"


def recorded_health() -> dict:
    """stability-health.py --json --top 3 (task 034) run on its own recorded Sentry responses: CMUXTERM-MACOS-10
    links GitHub #30001, -11 is claimed by the PL-cefhost owner entry, -12 has no GitHub issue."""
    return json.loads(RECORDED_HEALTH.read_text())


def health_entry(sentry_id: str = "4501", **extra) -> dict:
    """One normalized top_issues entry, as stability-health.py's normalize_issue writes it."""
    out = {"id": sentry_id, "short_id": f"CMUXTERM-MACOS-{sentry_id}", "title": "EXC_BAD_ACCESS: Workspace.close",
           "culprit": "Workspace.close(_:)", "level": "error", "events": 12, "users": 3,
           "first_seen": "2026-10-20T00:00:00Z", "last_seen": "2026-10-24T00:00:00Z",
           "permalink": f"https://manaflow.sentry.io/issues/{sentry_id}/", "github": [], "owner": None}
    out.update(extra)
    return out


def health(entries: list[dict]) -> dict:
    report = recorded_health()
    report["top_issues"] = entries
    return report


class SentryTests(Harness):
    """stability-health.py's top Sentry issues become signatures with source sentry."""

    def sentry(self, report: dict, *flags: str) -> tuple[int, dict, str]:
        path = self.tmp / "health.json"
        path.write_text(json.dumps(report))
        return self.cli(*flags, "sentry", str(path))

    def test_the_recorded_034_report_imports_only_the_issue_without_a_github_issue(self) -> None:
        code, out, _ = self.sentry(recorded_health())
        self.assertEqual(code, 0)
        self.assertEqual(len(self.gh.issues), 1)
        issue, state = self.gh.issues[1], self.gh.state()
        self.assertEqual(state["hash12"], si.sentry_hash12("1012"))
        self.assertEqual(state["source"], "sentry")
        self.assertIn("stability-kind:sentry", issue.labels)
        self.assertEqual(state["sentry"]["1012"]["events"], 20)
        self.assertEqual(state["sentry"]["1012"]["users"], 5)
        self.assertIn("[CMUXTERM-MACOS-12](https://manaflow.sentry.io/issues/1012/)", issue.body)
        self.assertIn("20 events and 5 users in the last 3 d", issue.body)
        self.assertIn("NSInternalInconsistencyException", issue.title)
        # Sentry gives dates, not commits: the lab's commit table stays empty instead of pairing a wrong commit.
        self.assertEqual((state["first_sha"], state["last_sha"]), ("", ""))
        self.assertIn("| First | - | - |", issue.body)
        self.assertTrue(any("CMUXTERM-MACOS-10 already links GitHub issue #30001" in n for n in out["notes"]))
        self.assertTrue(any("CMUXTERM-MACOS-11 is claimed by PL-cefhost (#24913)" in n for n in out["notes"]))

    def test_import_is_idempotent_and_updates_counts_in_place(self) -> None:
        self.sentry(health([health_entry()]))
        self.gh.calls.clear()
        self.sentry(health([health_entry()]))
        self.assertEqual(self.gh.writes(), [])
        self.sentry(health([health_entry(events=40, last_seen="2026-10-25T00:00:00Z")]))
        self.assertEqual(len(self.gh.issues), 1)
        self.assertEqual(self.gh.calls.count("create"), 0)
        self.assertEqual(self.gh.state()["sentry"]["4501"]["events"], 40)
        self.assertEqual(self.gh.state()["sentry"]["4501"]["last_seen"], "2026-10-25T00:00:00Z")

    def test_two_sentry_issues_are_two_github_issues(self) -> None:
        self.sentry(health([health_entry("1"), health_entry("2")]))
        self.assertEqual(len(self.gh.issues), 2)
        self.assertEqual(sorted(link for n in self.gh.issues for link in self.gh.state(n)["sentry"]), ["1", "2"])

    def test_a_sentry_issue_linked_to_a_github_issue_is_not_imported(self) -> None:
        code, out, _ = self.sentry(health([health_entry(github=[123])]))
        self.assertEqual(code, 0)
        self.assertEqual(self.gh.calls.count("create"), 0)
        self.assertEqual(self.gh.issues, {})
        self.assertTrue(any("already links GitHub issue #123" in note for note in out["notes"]))

    def test_a_sentry_issue_linked_to_a_stability_issue_joins_it(self) -> None:
        self.sync(run("r1", sha(1), [finding()]))
        self.sentry(health([health_entry(github=[1])]))
        self.assertEqual(len(self.gh.issues), 1)
        state = self.gh.state()
        self.assertEqual((state["hash12"], state["source"], state["kind"]), (H1, "lab", "ips"))
        self.assertIn("4501", state["sentry"])
        # A lab sync after the import keeps the link.
        self.sync(run("r2", sha(2), [finding()]))
        self.assertIn("https://manaflow.sentry.io/issues/4501/", self.gh.issues[1].body)
        self.assertEqual(self.gh.state()["count"], 2)

    def test_a_linked_sentry_issue_stays_on_its_issue_when_sentry_links_change(self) -> None:
        self.sentry(health([health_entry()]))
        owner = {"owner": "PL-cefhost", "eta": "later", "github_issue": 24913}
        self.sentry(health([health_entry(events=13, github=[24913], owner=owner)]))
        self.assertEqual(len(self.gh.issues), 1)
        self.assertEqual(self.gh.state()["hash12"], si.sentry_hash12("4501"))
        self.assertEqual(self.gh.state()["sentry"]["4501"]["events"], 13)

    def test_two_imports_that_raced_heal_into_one_issue(self) -> None:
        report = health([health_entry()])
        listed = self.gh.list_issues(si.LABEL)
        # Two hosts listed the issues before either created one.
        for _ in range(2):
            tracked, _ = si.plan_sentry(listed, report)
            si.apply(tracked, self.gh, max_writes=60, dry_run=False)
        self.assertEqual(sorted(self.gh.issues), [1, 2])
        self.sentry(report)
        self.assertEqual((self.gh.issues[2].state, self.gh.issues[2].state_reason), ("CLOSED", "NOT_PLANNED"))
        self.assertEqual(list(self.gh.state(1)["sentry"]), ["4501"])
        self.assertEqual(self.gh.state(1)["merged"], [2])
        self.gh.calls.clear()
        self.sentry(report)
        self.assertEqual(self.gh.writes(), [])

    def test_imports_never_reset_a_verified_fix_or_reopen(self) -> None:
        self.unknown.add(sha(3))
        self.sentry(health([health_entry()]))
        hash12 = si.sentry_hash12("4501")
        for events in (20, 30, 40):
            self.cli("fix-verified", "--hash12", hash12, "--fix", FIX, "--evidence", "job 9")
            self.sentry(health([health_entry(events=events)]))
            self.assertEqual(self.gh.state()["fix"]["sha"], FIX)
        self.assertEqual(self.gh.state()["fix_history"], [])
        self.gh.issues[1].state, self.gh.issues[1].state_reason = "CLOSED", "COMPLETED"
        self.sentry(health([health_entry(events=50)]))
        self.assertEqual(self.gh.issues[1].state, "CLOSED")
        self.assertNotIn("reopen 1", self.gh.calls)

    def test_bad_report_is_refused_before_any_read(self) -> None:
        for report, text in ((health([{"title": "no id"}]), "without an id"),
                             ({**health([health_entry()]), "schema": "other"}, "expected cmux-stability-health/v1"),
                             (health([health_entry(github="#5")]), "not issue numbers")):
            code, _, err = self.sentry(report)
            self.assertEqual(code, 1)
            self.assertIn(text, err)
        self.assertEqual(self.gh.calls, [])

    def test_stdin_is_read_before_the_repo_lock(self) -> None:
        lock = self.tmp / "lock"
        held: list[bool] = []

        class Stdin:
            def read(self) -> str:
                with open(lock, "a") as handle:
                    try:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        held.append(True)
                    else:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                        held.append(False)
                return json.dumps(health([health_entry()]))

        with mock.patch.object(si.sys, "stdin", Stdin()):
            code, _, _ = self.cli("sentry", "-")
        self.assertEqual((code, held), (0, [False]))
        self.assertEqual(len(self.gh.issues), 1)

    def test_a_link_that_is_not_https_is_not_rendered_as_a_link(self) -> None:
        self.sentry(health([health_entry(permalink="javascript:alert(1)")]))
        self.assertNotIn("](javascript", self.gh.issues[1].body)
        self.assertIn("CMUXTERM-MACOS-4501", self.gh.issues[1].body)

    @unittest.skipUnless(HEALTH_SCRIPT.exists(), "stability-health.py (task 034) is not in this checkout")
    def test_stability_health_output_imports_with_its_counts(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("stability_health", HEALTH_SCRIPT)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        self.assertEqual(module.SCHEMA, si.HEALTH_SCHEMA)
        raw = {"id": "77", "shortId": "CMUXTERM-MACOS-77", "title": "SIGSEGV: PaneStore.remove", "culprit": "",
               "count": "90", "userCount": 9, "filtered": {"count": "40", "userCount": 4}, "annotations": [],
               "firstSeen": "2026-10-20T00:00:00Z", "lastSeen": "2026-10-25T00:00:00Z",
               "permalink": "https://manaflow.sentry.io/issues/77/"}
        self.sentry(health([module.normalize_issue(raw, [])]))
        self.assertEqual(self.gh.state()["sentry"]["77"]["events"], 40)
        self.assertEqual(self.gh.state()["sentry"]["77"]["users"], 4)


class LockTests(Harness):
    def test_sync_holds_the_repo_lock_while_it_reads_and_writes(self) -> None:
        lock = self.tmp / "lock"
        held: list[bool] = []
        real_create = self.gh.create_issue

        def probe() -> None:
            with open(lock, "a") as handle:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    held.append(True)
                else:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                    held.append(False)

        def create(*args):
            probe()
            return real_create(*args)

        self.gh.create_issue = create
        self.sync(run("r1", sha(1), [finding()]))
        self.assertEqual(held, [True])
        probe()
        self.assertEqual(held, [True, False])


class GitAncestryTests(unittest.TestCase):
    def test_a_commit_the_checkout_lacks_is_fetched_from_the_remote(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

        def vcs(cwd: Path, *args: str) -> str:
            return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True,
                                  check=True).stdout.strip()

        upstream = tmp / "upstream"
        upstream.mkdir()
        vcs(upstream, "init", "-q")
        vcs(upstream, "commit", "-q", "--allow-empty", "-m", "fix")
        fix = vcs(upstream, "rev-parse", "HEAD")
        vcs(tmp, "clone", "-q", str(upstream), "checkout")
        vcs(upstream, "commit", "-q", "--allow-empty", "-m", "newer tip")
        tip = vcs(upstream, "rev-parse", "HEAD")

        with mock.patch.dict(os.environ, env):
            self.assertIsNone(si.GitAncestry(tmp / "checkout", remote="")(fix, tip))
            ancestry = si.GitAncestry(tmp / "checkout")
            self.assertTrue(ancestry(fix, tip))
            self.assertFalse(ancestry(tip, fix))
            self.assertIsNone(ancestry(fix, sha(5)))


FAKE_GH = textwrap.dedent('''\
    #!/usr/bin/env python3
    """A fake gh: issues and labels in $FAKE_GH_STATE, every argv appended to $FAKE_GH_LOG."""
    import json, os, sys
    args = sys.argv[1:]
    path = os.environ["FAKE_GH_STATE"]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(args) + "\\n")
    db = json.load(open(path)) if os.path.exists(path) else {"issues": [], "labels": []}
    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default
    def opts(name):
        return [args[i + 1] for i, a in enumerate(args) if a == name]
    assert args[0] == "api" or opt("--repo") == "o/r", args
    if args[:2] == ["api", "rate_limit"]:
        print(json.dumps({"resources": {"core": {"remaining": 4000}, "graphql": {"remaining": 600}}}))
    elif args[:2] == ["issue", "list"]:
        label = opt("--label")
        print(json.dumps([dict(i, labels=[{"name": n} for n in i["labels"]]) for i in db["issues"]
                          if label in i["labels"]]))
    elif args[:2] == ["label", "list"]:
        print(json.dumps([{"name": n} for n in db["labels"] if opt("--search", "") in n]))
    elif args[:2] == ["label", "create"]:
        db["labels"].append(args[2])
    elif args[:2] == ["issue", "create"]:
        missing = [n for n in opts("--label") if n not in db["labels"]]
        if missing:
            sys.exit("could not add label: " + missing[0])
        number = len(db["issues"]) + 1
        db["issues"].append({"number": number, "state": "OPEN", "stateReason": None, "title": opt("--title"),
                             "body": sys.stdin.read(), "labels": opts("--label")})
        print(f"https://github.com/o/r/issues/{number}")
    elif args[:2] == ["issue", "edit"]:
        issue = db["issues"][int(args[2]) - 1]
        issue["title"], issue["body"] = opt("--title"), sys.stdin.read()
    else:
        sys.exit("fake gh: unexpected " + " ".join(args))
    json.dump(db, open(path, "w"))
''')


class GhCliTests(unittest.TestCase):
    def test_sync_through_the_gh_cli(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                   FAKE_GH_STATE=str(tmp / "db.json"), FAKE_GH_LOG=str(tmp / "log.jsonl"))
        run_file = tmp / "run.json"
        run_file.write_text(json.dumps(run("r1", sha(1), [finding(), finding()])))

        def sync() -> subprocess.CompletedProcess:
            return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", "o/r", "--git-dir", str(tmp),
                                   "sync", str(run_file)], env=env, capture_output=True, text=True, check=False)

        first = sync()
        self.assertEqual(first.returncode, 0, first.stderr)
        second = sync()
        self.assertEqual(second.returncode, 0, second.stderr)
        db = json.loads((tmp / "db.json").read_text())
        self.assertEqual(len(db["issues"]), 1)
        self.assertEqual(si.read_state(db["issues"][0]["body"])["count"], 2)
        calls = [json.loads(line)[:2] for line in (tmp / "log.jsonl").read_text().splitlines()]
        self.assertEqual(calls.count(["issue", "list"]), 2)
        self.assertEqual(calls.count(["issue", "create"]), 1)
        self.assertEqual(calls.count(["label", "list"]), 1)
        self.assertNotIn(["issue", "edit"], calls)

        # A second signature of the same kind creates only its own hash label: stability-kind:ips already exists.
        run_file.write_text(json.dumps(run("r2", sha(2), [finding(H2)])))
        third = sync()
        self.assertEqual(third.returncode, 0, third.stderr)
        created = [json.loads(line)[2] for line in (tmp / "log.jsonl").read_text().splitlines()
                   if json.loads(line)[:2] == ["label", "create"]]
        self.assertEqual(created, ["stability-sig", f"stability-sig:{H1}", "stability-kind:ips", f"stability-sig:{H2}"])

        with mock.patch.dict(os.environ, env):
            remaining = si.GhCli("o/r", gh=str(bin_dir / "gh")).rate_remaining()
        self.assertEqual(remaining, {"core": 4000, "graphql": 600})


if __name__ == "__main__":
    unittest.main()
