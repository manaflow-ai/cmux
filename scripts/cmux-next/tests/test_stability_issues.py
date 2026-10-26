#!/usr/bin/env python3
"""stability_issues.py keeps one GitHub issue per signature, with gh faked.

1. Idempotent: two findings of one signature make one issue with count 2; syncing the same run again writes nothing.
2. Closing needs a verified fix and 3 distinct clean tips that contain the fix and ran a lane and major that found
   the signature; tips without the fix, tips that ran other lanes and repeated tips do not count.
3. A finding on a build with the fix resets the fix and reopens a closed issue; one from a build without the fix only
   counts; an issue a person closed as not planned stays closed.
4. bisect-result and fix-verified update the issue once; the state block survives `-->` in frame names.
5. Writes past --max-writes or the REST reserve are deferred with exit 75 and the same sync finishes them.
6. The gh CLI adapter, end to end against a fake `gh` executable: one issue list read per sync, labels created only
   when an issue is created, and the run file applied once.

    python3 -I -m pytest scripts/cmux-next/tests/test_stability_issues.py
    python3 -I -m unittest discover -s scripts/cmux-next/tests -p test_stability_issues.py
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
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

    def __init__(self, remaining: int | None = 5000) -> None:
        self.issues: dict[int, si.Issue] = {}
        self.comments: dict[int, list[str]] = {}
        self.calls: list[str] = []
        self.labels: set[str] = set()
        self.remaining = remaining

    def list_issues(self, label: str) -> list[si.Issue]:
        self.calls.append(f"list {label}")
        return [si.Issue(**vars(issue)) for issue in self.issues.values() if label in issue.labels]

    def ensure_labels(self, names: list[str]) -> None:
        self.calls.append("labels")
        self.labels |= set(names)

    def create_issue(self, title: str, body: str, labels: list[str]) -> int:
        self.calls.append("create")
        number = len(self.issues) + 1
        self.issues[number] = si.Issue(number, "OPEN", "", title, body, list(labels))
        return number

    def edit_issue(self, number: int, title: str, body: str) -> None:
        self.calls.append(f"edit {number}")
        self.issues[number].title, self.issues[number].body = title, body

    def comment(self, number: int, text: str) -> None:
        self.calls.append(f"comment {number}")
        self.comments.setdefault(number, []).append(text)

    def close_issue(self, number: int, text: str) -> None:
        self.calls.append(f"close {number}")
        self.issues[number].state, self.issues[number].state_reason = "CLOSED", "COMPLETED"
        self.comments.setdefault(number, []).append(text)

    def reopen_issue(self, number: int, text: str) -> None:
        self.calls.append(f"reopen {number}")
        self.issues[number].state, self.issues[number].state_reason = "OPEN", "REOPENED"
        self.comments.setdefault(number, []).append(text)

    def rest_remaining(self) -> int | None:
        self.calls.append("rate_limit")
        return self.remaining

    def state(self, number: int = 1) -> dict:
        state = si.read_state(self.issues[number].body)
        assert state is not None
        return state

    def writes(self) -> list[str]:
        return [call for call in self.calls if not call.startswith(("list", "rate_limit"))]


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


def descends_from_fix(fix_tips: set[str]):
    """Ancestry: FIX is in exactly the tips listed."""
    return lambda ancestor, tip: tip in fix_tips if ancestor == FIX else None


class Harness(unittest.TestCase):
    def setUp(self) -> None:
        self.gh = FakeGitHub()
        self.fixed: set[str] = set()
        self.tmp = Path(tempfile.mkdtemp())

    def cli(self, *argv: str) -> tuple[int, dict, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = si.main(list(argv), github=self.gh, is_ancestor=descends_from_fix(self.fixed))
        return code, json.loads(out.getvalue() or "{}"), err.getvalue()

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

    def test_max_writes_defers_and_the_same_sync_finishes(self) -> None:
        data = self.many(5)
        code, out, err = self.sync(data, "--max-writes", "3")
        self.assertEqual(code, si.EX_TEMPFAIL)
        self.assertEqual((len(self.gh.issues), len(out["deferred"])), (3, 2))
        self.assertIn("run the same command again", err)
        code, _, _ = self.sync(data, "--max-writes", "3")
        self.assertEqual((code, len(self.gh.issues)), (0, 5))
        self.assertTrue(all(self.gh.state(n)["count"] == 1 for n in self.gh.issues))

    def test_rest_reserve_is_kept(self) -> None:
        self.gh.remaining = si.REST_RESERVE + 4
        code, out, _ = self.sync(self.many(si.BUDGET_CHECK_AT))
        self.assertEqual(code, si.EX_TEMPFAIL)
        self.assertEqual(len(self.gh.issues), 4)
        self.assertIn("rate_limit", self.gh.calls)

    def test_small_runs_do_not_read_the_rate_limit_and_dry_run_writes_nothing(self) -> None:
        code, out, _ = self.sync(self.many(2), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(self.gh.writes(), [])
        self.assertNotIn("rate_limit", self.gh.calls)
        self.assertEqual(len(out["applied"]), 2)


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
        print(4000)
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
        self.assertEqual(created, ["stability-kind:ips", "stability-sig", f"stability-sig:{H1}", f"stability-sig:{H2}"])


if __name__ == "__main__":
    unittest.main()
