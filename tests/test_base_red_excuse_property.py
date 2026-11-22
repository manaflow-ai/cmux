"""A generative property test of the base-red excuse: random head and base job logs, judged by the real judge().

Four review rounds in a row (#41113 F1, #41158 F1/F2, #41172, #41166 F1/F2) found by hand the same class of bug: an
excuse key that dropped part of a failure's identity, so a head red matched a base that never failed that way. This
test finds that class by itself. Each seed builds, with random.Random(seed), one head job and a window of one to three
base verdicts for it (newest first; a green one ends the window): steps with conclusions (failure, cancelled,
timed_out, success), and in each failed step runner blocks (Swift Testing, XCTest, xcresult `FAILED:` lines,
xcodebuild's `Failing tests:` list, cargo, unittest, pytest, bun with its file header, its closing recap (a title
failing twice in it too) and the wrapper's retry), each with named failures, deliberately unparseable ones, and the
runner's counted summary. The head's log is placed onto its steps or not (a composite action's inner `Run` line: the
whole-log comparison). judge() is asked about the head, and
whenever it excuses, an oracle computed from the generator's own ground truth (never from the code under test) checks:

1. Identity: some ONE base verdict of the window judge() can read has every failed step of the head, by (name,
   conclusion), as often (a multiset that covers the head's); a whole-log head's failing tests must be on that same
   verdict, as often; a placed head's each on some verdict of the window that has those steps (the per-test window,
   BASE_WINDOW), as often, and with an error printed there exactly when the head prints one (#41329's review F1).
2. Count: every failure the head's runners report is one its parsers name: no unparseable failure in it. Exempt is an
   XCTest-family failure (XCTest, xcresult, xcodebuild's list) beside a named one of that family: XCTest's summary
   counts assertion failures per enclosing suite, never failing tests, so no total can show the unnamed one.

3. Single verdict (black-box, #41329's review: "an excuse built from facts drawn from different records"): each of
   the head's failing tests, alone in the head, that the window excuses is excused by some ONE reachable base verdict
   alone (single_verdict_violations). judge() alone decides it, so it holds whatever the oracle above models.

BASE_RED_PROPERTY_SEEDS (default 1500) sets how many seeds run, BASE_RED_PROPERTY_START the first. Each violation is
printed with its seed and a short description; replay one with BASE_RED_PROPERTY_START=SEED BASE_RED_PROPERTY_SEEDS=1.
The full run (100k seeds) is `BASE_RED_PROPERTY_SEEDS=100000 python3 tests/test_base_red_excuse_property.py`.
"""
from __future__ import annotations

import copy
import os
import random
import sys
import time
import unittest
import unittest.mock
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Imported by name, never loaded by path (tests/test_script_module_loads.py).
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
import base_red_excuse as excuse  # noqa: E402

REPO = "manaflow-ai/cmux"
HEAD = "a" * 40
BASE_SHA = "b" * 40
JOB = "cmux-next swift test"
STEP_NAMES = ("package tests", "ui tests")
CONCLUSIONS = ("failure",) * 6 + ("cancelled",) * 2 + ("timed_out",) + ("success",) * 2
RUNNERS = ("swift", "xctest", "xcresult", "listing", "cargo", "unittest", "pytest", "bun")
XC_FAMILY = frozenset({"xctest", "xcresult", "listing"})
NAMES = ("alpha", "beta", "gamma")
NON_VACUOUS_SEEDS = 20  # the fewest seeds over which the excuse count must be above zero


def setUpModule():
    # As tests/test_base_red_excuse.py: no git, network or on-disk cache read.
    for patch in (unittest.mock.patch.object(excuse, "git_text", lambda repo, ref, path: None, create=True),
                  unittest.mock.patch.object(excuse, "compile_receipt", lambda repo, sha: None),
                  unittest.mock.patch.dict(os.environ, {"BASE_RED_EXCUSE_JOBS_CACHE": "off",
                                                        "BASE_RED_EXCUSE_FIXTURE_SHA": "1"})):
        patch.start()
        unittest.addModuleCleanup(patch.stop)


# --- the generator's ground truth -----------------------------------------------------------------------------------
# A failure: (runner, name, named). A block: {"runner", "failures": [failure], "passes", "retry": [failure] | None,
# "recap": None | "both" | "only"} (bun alone: the wrapper ran the file again, alone, and only that run counts; bun's
# closing recap `N tests failed:` repeats the results' titles, or is all that names them). A step: {"name",
# "conclusion", "blocks"}; only a failed step has blocks.

def key(runner: str, name: str) -> str:
    """The identity a runner's parser gives NAME: one namespace per runner, xcresult's and xcodebuild's list shared."""
    return {"swift": f"{name}()", "xctest": f"KitTests {name}", "xcresult": f"KitTests.{name}()",
            "listing": f"KitTests.{name}()", "cargo": f"tests::{name}",
            "unittest": f"test_{name} (pkg.mod.Case.test_{name})", "pytest": f"tests/test_mod.py::test_{name}",
            "bun": f"test/pane.test.ts > pane > {name}"}[runner]


def final_failures(block: dict) -> list:
    return block["retry"] if block.get("retry") is not None else block["failures"]


def final_identities(block: dict) -> list:
    """(runner, identity, named) of each of BLOCK's final failures, as its log can tell them. A bun recap that alone
    names its failures prints `(fail) pane > NAME`, no file: each line is one failure of that title, so a title listed
    twice is two failures of it (#41222's review F1 at 6719ba22: "a name failing twice is 2")."""
    return [(runner, f"pane > {name}" if runner == "bun" and titled(block) else key(runner, name), ok)
            for runner, name, ok in final_failures(block)]


def titled(block: dict) -> bool:
    """Whether BLOCK's bun failures are named by title alone (`pane > NAME`): its recap alone names them, or its run
    printed no file header (bun's results are then titles, each with its error)."""
    return block.get("recap") == "only" or bool(block.get("headerless"))


def diagnosed(steps: list) -> set:
    """The named failure identities a log prints an error for (test_reds' messages): bun's results print their
    assertion block; a recap names a title with none. Every other runner's are compared by name."""
    found = set()
    for step in steps:
        for block in step["blocks"]:
            if block["runner"] == "bun" and block.get("recap") != "only":
                found |= {ident for _, ident, ok in final_identities(block) if ok}
    return found


def truth(steps: list) -> tuple[Counter, Counter, list]:
    """(failed step keys, named failure identities, unparseable failures) of a job, as generated."""
    keys = Counter((step["name"], step["conclusion"]) for step in steps if step["conclusion"] != "success")
    found = []
    for step in steps:
        mine = []  # this step's: a retry supersedes its file's earlier attempts in its own step, never another's
        for block in step["blocks"]:
            if block.get("retry") is not None:
                # run-webviews-tests.sh's contract: a file run again, alone, is judged by that run only, so every
                # earlier failure of the file in the step (every bun block here runs one file) is superseded, recap
                # titles and all. A run with no file header ran no file: its results stay.
                mine = [failure for failure in mine if failure[0] != "bun" or failure[3]]
            mine += [(*failure, bool(block.get("headerless"))) for failure in final_identities(block)]
        found += mine
    named = Counter(ident for runner, ident, ok, _ in found if ok)
    return keys, named, [(runner, ident) for runner, ident, ok, _ in found if not ok]


def unreported(steps: list) -> list:
    """The unparseable failures a summary can show (oracle 2): all but an XCTest-family one beside a named one."""
    _, named, unnamed = truth(steps)
    xc_named = any(ok and runner in XC_FAMILY for step in steps for block in step["blocks"]
                   for runner, _, ok in final_failures(block))
    return [(runner, name) for runner, name in unnamed if not (runner in XC_FAMILY and xc_named)]


# --- rendering a job's log ------------------------------------------------------------------------------------------

def block_lines(block: dict) -> list[str]:
    runner, failures, passes = block["runner"], block["failures"], block["passes"]
    # Named failures first: an unnamed bun failure's error lines or an unnamed list entry end what they follow.
    failures = sorted(failures, key=lambda f: not f[2])
    total = len(failures) + passes
    out: list[str] = []
    if runner == "swift":
        out.append("◇ Test run started.")
        for _, name, ok in failures:
            shown = f"{name}()" if ok else name  # a name the parser cannot read: no parentheses
            out += [f"✘ Test {shown} recorded an issue at KitTests.swift:3:5: Expectation failed",
                    f"✘ Test {shown} failed after 0.010 seconds with 1 issue."]
        out.append(f"✘ Test run with {total} tests in 1 suite failed after 0.100 seconds with {len(failures)} "
                   f"issue{'s' if len(failures) != 1 else ''}.")
    elif runner == "xctest":
        out += ["Test Suite 'All tests' started at 2026-10-07 02:10:10.000",
                "Test Suite 'KitTests' started at 2026-10-07 02:10:10.000"]
        for _, name, ok in failures:
            case = f"-[KitTests {name}]" if ok else f"KitTests.{name}"  # Linux XCTest's form: unread
            out += [f"Test Case '{case}' started.", f"Test Case '{case}' failed (0.010 seconds)."]
        summary = (f"Executed {total} tests, with {len(failures)} failure{'s' if len(failures) != 1 else ''} "
                   "(0 unexpected) in 0.100 (0.100) seconds")
        out += ["Test Suite 'KitTests' failed at 2026-10-07 02:10:11.000", f"\t {summary}",
                "Test Suite 'All tests' failed at 2026-10-07 02:10:11.000", f"\t {summary}"]
    elif runner in ("xcresult", "listing"):
        if runner == "xcresult":
            out += [f"FAILED: CmuxKit / KitTests / KitTests / {name}()" if ok else
                    f"FAILED: CmuxKit / KitTests / KitTests / {name}" for _, name, ok in failures]
        else:
            out += ["Failing tests:"] + [f"\tKitTests.{name}()" if ok else f"\tKitTests.{name}"
                                         for _, name, ok in failures] + ["", "** TEST FAILED **"]
        out.append(f"Executed {total} tests, with {len(failures)} failure{'s' if len(failures) != 1 else ''} "
                   "(0 unexpected) in 0.100 (0.100) seconds")
    elif runner == "cargo":
        out.append(f"running {total} tests")
        out += [f"test tests::ok_{n} ... ok" for n in range(passes)]
        out += [f"test tests::{name} ... FAILED" if ok else f"test src/lib.rs - {name} (line 3) ... FAILED"
                for _, name, ok in failures]
        out.append(f"test result: FAILED. {passes} passed; {len(failures)} failed; 0 ignored; 0 measured; "
                   "0 filtered out; finished in 0.01s")
    elif runner == "unittest":
        out += [f"FAIL: test_{name} (pkg.mod.Case.test_{name})" if ok else "FAIL: [interrupted]"
                for _, name, ok in failures]
        out += [f"Ran {total} tests in 0.010s", f"FAILED (failures={len(failures)})"]
    elif runner == "pytest":
        out.append("============================= test session starts ==============================")
        out += [f"FAILED tests/test_mod.py::test_{name} - assert 1 == 2" if ok else
                "FAILED tests/test_mod.py - fixture setup broke" for _, name, ok in failures]
        out.append(f"========================= {len(failures)} failed, {passes} passed in 0.12s "
                   "=========================")
    elif runner == "bun" and block.get("silent"):
        # A run that failed naming nothing (a module that would not load): ` 0 fail`, and the wrapper's `FAIL file`
        # the only sign of its one unnamed failure (#41329's follow-up F2).
        out += ["bun test v1.3.0", "test/pane.test.ts:", *(f"(pass) pane > ok {n} [0.10ms]" for n in range(passes)),
                "error: Cannot find module './gone'", f" {passes} pass", " 0 fail", "FAIL test/pane.test.ts (exit 1)"]
    elif runner == "bun":
        recap = block.get("recap")
        out += bun_run(failures, passes, recap, headerless=bool(block.get("headerless")))
        if block.get("retry") is not None:
            out += ["--- retry, alone ---"] + bun_run(sorted(block["retry"], key=lambda f: not f[2]), 0, recap)
    return out


def bun_run(failures: list, passes: int, recap: str | None = None, headerless: bool = False) -> list[str]:
    """One bun invocation of FAILURES (named ones first). RECAP "both": the closing `N tests failed:` recap repeats
    each named result's title; "only": no result line names a failure, the recap alone does. HEADERLESS: no file
    header, so each result is named by its title alone, with its error (#41329's review F1)."""
    out = ["bun test v1.3.0"] + ([] if headerless else ["test/pane.test.ts:"])
    out += [f"(pass) pane > ok {n} [0.10ms]" for n in range(passes)]
    for _, name, ok in failures:
        out += ["error: expect(received).toBe(expected)", "", f"Expected: \"{name}\"", "Received: \"other\"", ""]
        if ok and recap != "only":
            out.append(f"(fail) pane > {name} [1.00ms]")
    if recap:
        titles = [name for _, name, ok in failures if ok]
        out += [f"{len(titles)} test{'s' if len(titles) != 1 else ''} failed:"] + [f"(fail) pane > {name} [1.00ms]"
                                                                                for name in titles]
    return out + [f" {passes} pass", f" {len(failures)} fail"]


def render(steps: list, *, job_id: int, run_id: int, sha: str, placed: bool, conclusion: str = "failure"):
    """(the jobs API's job, its log as the job-log endpoint serves it): a `Set up job` step, STEPS, `Complete job`, each
    with times, and each of STEPS opening its section with its own `Run` line in its window (step_owners places it). A
    log not PLACED has a composite action's inner `Run` line in its first failed step: two in one step, so unplaced."""
    listed = [{"name": "Set up job", "conclusion": "success"}] + [
        {"name": step["name"], "conclusion": step["conclusion"]} for step in steps] + [
        {"name": "Complete job", "conclusion": "success"}]
    out, inner = [], not placed
    for n, step in enumerate(listed):
        step.update(number=n + 1, status="completed", started_at=f"2026-10-07T02:{10 + n:02d}:00Z",
                    completed_at=f"2026-10-07T02:{10 + n:02d}:30Z")
        stamp = f"2026-10-07T02:{10 + n:02d}:10.0000000Z "
        if n == 0:
            out.append(stamp + "fixture: set up job")
            continue
        if n == len(listed) - 1:
            break
        own = steps[n - 1]
        # The runner's echo of the step's script, as a job log shows it: test_reds reads a step's bounds from it.
        out += [stamp + f"##[group]Run fixture-step-{n}", stamp + "shell: /usr/bin/bash -e {0}", stamp + "##[endgroup]"]
        out.append(stamp + "compiling the package")
        if own["conclusion"] != "success" and inner:
            out.append(stamp + "##[group]Run python3 scripts/ci/run_inner.py")
            inner = False
        for block in own["blocks"]:
            out += [stamp + line for line in block_lines(block)]
        if own["conclusion"] != "success" and not own.get("quiet"):
            out.append(stamp + "##[error]Process completed with exit code 1.")
    job = {"id": job_id, "run_id": run_id, "head_sha": sha, "name": JOB, "status": "completed",
           "conclusion": conclusion, "steps": listed}
    return job, "\n".join(out)


# --- the generator ---------------------------------------------------------------------------------------------------

def gen_failure(rng: random.Random, runner: str, unnamed_rate: float) -> tuple:
    return (runner, rng.choice(NAMES), rng.random() >= unnamed_rate)


def gen_block(rng: random.Random, unnamed_rate: float) -> dict:
    runner = rng.choice(RUNNERS)
    failures = [gen_failure(rng, runner, unnamed_rate) for _ in range(rng.randint(1, 3))]
    block = {"runner": runner, "failures": failures, "passes": rng.randint(0, 2), "retry": None, "recap": None}
    if runner == "bun" and rng.random() < 0.25:
        block["retry"] = [failure for failure in failures if rng.random() < 0.6]
    if runner == "bun" and block["retry"] is None and rng.random() < 0.12:
        # Nothing named, the wrapper's `FAIL file` alone (#41329's follow-up F2): one unnamed failure.
        block.update(silent=True, failures=[(runner, rng.choice(NAMES), False)])
        return block
    if runner == "bun" and rng.random() < 0.4:
        # bun's closing recap, and in it a title that failed twice (#41222's review F1: a title listed twice is two
        # failures), alone or after the results, in a retried block too: the retry supersedes the attempt's recap
        # titles with the rest of it (#41329's review F1 and its follow-up F1).
        block["recap"] = rng.choice(("both", "only"))
        named = [failure for failure in failures if failure[2]]
        if named and rng.random() < 0.5:
            failures.append(rng.choice(named))
    elif runner == "bun" and block["retry"] is None and rng.random() < 0.3:
        # No file header: each result is named by its title, the identity a recap-only block gives it, but with its
        # error (#41329's review F1: the same title, one verdict with an error and another without).
        block["headerless"] = True
        # Every failure named: an unnamed one's count line would be kept or dropped by a later retry of whichever
        # file ran before it, which is no contract to model.
        failures[:] = [(runner, name, True) for runner, name, _ in failures]
        named = list(failures)
        if named and rng.random() < 0.5:
            failures.append(rng.choice(named))
    return block


def gen_steps(rng: random.Random, unnamed_rate: float) -> list:
    steps = []
    for _ in range(rng.randint(1, 3)):
        conclusion = rng.choice(CONCLUSIONS)
        blocks = [] if conclusion == "success" else [gen_block(rng, unnamed_rate) for _ in range(rng.randint(1, 3))]
        # A failed step that prints no `##[error]` line (the jobs API alone says it failed): split text is never
        # judged pass or fail again (#41329's follow-up F3).
        quiet = conclusion != "success" and rng.random() < 0.2
        steps.append({"name": rng.choice(STEP_NAMES), "conclusion": conclusion, "blocks": blocks, "quiet": quiet})
    if all(step["conclusion"] == "success" for step in steps):
        steps[0]["conclusion"] = "failure"
        steps[0]["blocks"] = [gen_block(rng, unnamed_rate)]
    return steps


def mutate(rng: random.Random, steps: list, window: list) -> list:
    """One of the ways a head differs from a base verdict: the shapes each past review found by hand."""
    steps = copy.deepcopy(steps)
    failed = [step for step in steps if step["conclusion"] != "success"]
    what = rng.randrange(7)
    if what == 0 and len(window) > 1:
        # Two verdicts' steps in one head (#41166 F1): a failed step of each.
        other = rng.choice(window[1:])["steps"]
        steps += copy.deepcopy([step for step in other if step["conclusion"] != "success"][:1])
    elif what == 1 and failed:
        # An unparseable failure beside the named ones (#41166 F2), or a new block of one named and one unnamed.
        step = rng.choice(failed)
        if step["blocks"] and rng.random() < 0.6:
            block = rng.choice(step["blocks"])
            target = block["retry"] if block.get("retry") is not None else block["failures"]
            if not block.get("silent"):  # a silent run names nothing and prints its one failure alone
                target.append((block["runner"], rng.choice(NAMES), bool(block.get("headerless"))))  # see gen_block
        else:
            runner = rng.choice(RUNNERS)
            step["blocks"].append({"runner": runner, "failures": [(runner, rng.choice(NAMES), True),
                                                                  (runner, rng.choice(NAMES), False)],
                                   "passes": 1, "retry": None})
    elif what == 2 and failed:
        rng.choice(failed)["conclusion"] = rng.choice(("failure", "cancelled", "timed_out"))
    elif what == 3 and failed:
        steps.append(copy.deepcopy(rng.choice(failed)))  # a step that failed twice
    elif what == 4 and failed:
        step = rng.choice(failed)
        if step["blocks"]:
            block = rng.choice(step["blocks"])
            if len(block["failures"]) > 1:
                block["failures"].pop(rng.randrange(len(block["failures"])))
    elif what == 5 and failed:
        step = rng.choice(failed)
        if step["blocks"]:
            block = rng.choice(step["blocks"])
            if not block.get("silent"):
                block["failures"].append(gen_failure(rng, block["runner"], 0.0))
    return steps


def scenario(seed: int) -> dict:
    rng = random.Random(seed)
    unnamed_rate = rng.choice((0.0, 0.0, 0.15, 0.4))
    window = []
    for n in range(rng.randint(1, 3)):
        green = n > 0 and rng.random() < 0.15
        if green:
            window.append({"green": True, "steps": [{"name": name, "conclusion": "success", "blocks": []}
                                                    for name in STEP_NAMES]})
        elif n > 0 and rng.random() < 0.5:
            window.append({"green": False, "steps": mutate(rng, window[rng.randrange(n)]["steps"], window)})
        else:
            window.append({"green": False, "steps": gen_steps(rng, unnamed_rate)})
    reds = [entry for entry in window if not entry["green"]]
    head = copy.deepcopy(rng.choice(reds)["steps"])
    for _ in range(rng.choice((0, 1, 1, 2))):
        head = mutate(rng, head, reds)
    return {"seed": seed, "placed": rng.random() < 0.65, "window": window, "head": head}


# --- the judge, on a fake GitHub ------------------------------------------------------------------------------------

class PropertyGitHub:
    """The head's run 10 (workflow 7, job 1) and the window's base runs 30, 29, 28 (job id = run id), newest first."""

    def __init__(self, case: dict):
        self.jobs, self.logs, self.base_runs = {}, {}, []
        self.jobs[1], self.logs[1] = render(case["head"], job_id=1, run_id=10, sha=HEAD, placed=case["placed"])
        for n, entry in enumerate(case["window"]):
            run = 30 - n
            green = entry["green"]
            self.base_runs.append({"id": run, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                                   "conclusion": "success" if green else "failure", "head_sha": BASE_SHA,
                                   "created_at": f"2026-11-11T{12 - n:02d}:00:00Z"})
            self.jobs[run], self.logs[run] = render(entry["steps"], job_id=run, run_id=run, sha=BASE_SHA,
                                                    placed=case["placed"],
                                                    conclusion="success" if green else "failure")

    def json(self, route, *, paginate=False):
        if f"/compare/feat-cmux-next...{HEAD}" in route:
            return {"merge_base_commit": {"sha": BASE_SHA}, "files": []}
        if f"/compare/{BASE_SHA}..." in route:
            return {"status": "ahead"}
        if "/actions/runs/" in route and route.endswith(("/jobs?filter=latest&per_page=100",
                                                         "/jobs?filter=all&per_page=100")):
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/workflows/7/runs?" in route:
            runs = copy.deepcopy(self.base_runs)
            if "&event=" in route:
                event = route.split("&event=", 1)[1].split("&", 1)[0]
                runs = [run for run in runs if run.get("event") == event]
            return {"workflow_runs": runs}
        if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
            return [{"check_runs": []}]
        if "/actions/jobs/" in route:
            return copy.deepcopy(self.jobs[int(route.rsplit("/", 1)[1])])
        if route.endswith("/annotations?per_page=100"):
            return [[]] if paginate else []
        if "/actions/runs?head_sha=" in route:
            sha = route.split("head_sha=", 1)[1].split("&", 1)[0]
            runs = [{"id": run, "workflow_id": 7, "head_sha": sha}
                    for run in sorted({job["run_id"] for job in self.jobs.values() if job["head_sha"] == sha})]
            return [{"total_count": len(runs), "workflow_runs": runs}]
        if "/actions/runs/" in route:
            return {"id": int(route.rsplit("/", 1)[1]), "workflow_id": 7}
        raise AssertionError(route)

    def log(self, repo, job):
        return self.logs[job["id"]]


def reachable(window: list) -> list:
    """The red verdicts judge() may read: newest first, up to the first green one, at most BASE_WINDOW."""
    found = []
    for entry in window[:excuse.BASE_WINDOW]:
        if entry["green"]:
            break
        found.append(entry)
    return found


def violations(case: dict, said: str) -> list[str]:
    """What an excuse SAID of CASE breaks, by the generator's ground truth."""
    found = []
    keys, named, _ = truth(case["head"])
    reds = reachable(case["window"])
    sides = [truth(entry["steps"]) for entry in reds]
    if case["placed"]:
        one = [n for n, (theirs, _, _) in enumerate(sides) if not keys - theirs]
        # Each failing test whole on ONE verdict of the window: there as often as the head fails it (#41222's review
        # F1), with an error printed there exactly when the head prints one (#41329's review F1: the count from one
        # verdict and the name and error from another is a failure no base run had).
        mine = diagnosed(case["head"])
        theirs_diagnosed = [diagnosed(entry["steps"]) for entry in reds]
        # That verdict holds the head's failed steps too (the window detector's finding: a test on one verdict, the
        # steps on another).
        tests_ok = all(any(not keys - theirs and tests[ident] >= n and (ident in mine) == (ident in seen)
                           for (theirs, tests, _), seen in zip(sides, theirs_diagnosed))
                       for ident, n in named.items())
    else:
        one = [n for n, (theirs, tests, _) in enumerate(sides) if not keys - theirs and not named - tests]
        tests_ok = True
    if not one or not tests_ok:
        found.append("identity: no single base verdict covers the head's failed steps"
                     + ("" if tests_ok else " (or a failing test is on none)")
                     + f"; head steps {sorted(keys.items())}, tests {sorted(named.items())}; verdicts "
                     + " | ".join(f"{sorted(theirs.items())} {sorted(tests.items())}" for theirs, tests, _ in sides))
    if missing := unreported(case["head"]):
        found.append(f"count: the head reports {len(missing)} failure(s) no parser names ({missing}) beside "
                     f"{sum(named.values())} named")
    return [f"seed {case['seed']} ({'placed' if case['placed'] else 'whole log'}): {what}; judge said: {said[:240]}"
            for what in found]


def judged(case: dict) -> str | None:
    """What judge() says of CASE: its audit line, or None when it refuses."""
    try:
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], PropertyGitHub(case)))
    except excuse.Refused:
        return None


def only(steps: list, ident: str) -> list:
    """STEPS with every failure but those of identity IDENT taken out (a block left with none is dropped): one failing
    test of the head, its steps kept as they are."""
    steps = copy.deepcopy(steps)
    for step in steps:
        for block in step["blocks"]:
            mine = [n for n, (_, found, _) in enumerate(final_identities(block)) if found == ident]
            final = final_failures(block)
            kept = [final[n] for n in mine]
            if block.get("retry") is not None:
                block["retry"] = kept
                block["failures"] = [f for f in block["failures"] if f in kept] or kept
            else:
                block["failures"] = kept
        step["blocks"] = [block for block in step["blocks"] if final_failures(block)]
    return steps


def single_verdict_violations(case: dict) -> list[str]:
    """The window detector of #41329's review ("an excuse built from facts drawn from different records"): each of
    the head's failing tests, alone in the head, that the window excuses must be excused by some ONE reachable base
    verdict alone. The per-test window lets two tests rest on two verdicts; never one test's name, error and count on
    several. Black-box: judge() alone decides, no ground truth."""
    reds = reachable(case["window"])
    if len(reds) < 2:
        return []
    _, named, _ = truth(case["head"])
    found = []
    for ident in sorted(named):
        head = only(case["head"], ident)
        if truth(head)[1] != Counter({ident: named[ident]}) or judged(dict(case, head=head)) is None:
            continue
        if not any(judged(dict(case, head=head, window=[entry])) is not None for entry in reds):
            found.append(f"seed {case['seed']} ({'placed' if case['placed'] else 'whole log'}): single verdict: "
                         f"{ident} x{named[ident]} is excused by the window of {len(reds)} verdicts and by none alone")
    return found


def run_seeds(start: int, count: int) -> tuple[list[str], int, Counter]:
    """(violations, excuses, refusals by kind) over seeds START .. START + COUNT."""
    found, excused, refused = [], 0, Counter()
    for seed in range(start, start + count):
        case = scenario(seed)
        try:
            said = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], PropertyGitHub(case)))
        except excuse.Refused as why:
            refused[str(why).split(":", 2)[1].strip()[:40] if ":" in str(why) else str(why)[:40]] += 1
            continue
        excused += 1
        found += violations(case, said)
        found += single_verdict_violations(case)
    return found, excused, refused


class ExcuseIdentityProperty(unittest.TestCase):
    def test_an_excuse_has_one_verdict_with_the_heads_identity_and_every_head_failure_named(self):
        count = int(os.environ.get("BASE_RED_PROPERTY_SEEDS", "1500"))
        start = int(os.environ.get("BASE_RED_PROPERTY_START", "0"))
        began = time.monotonic()
        found, excused, _ = run_seeds(start, count)
        took = time.monotonic() - began
        if found or count > 5000:
            print(f"\n{count} seeds from {start} in {took:.1f}s: {excused} excused, {len(found)} violation(s)",
                  file=sys.stderr)
            kinds = Counter(line.split("): ", 1)[1].split(":", 1)[0] for line in found)
            print(f"  by invariant: {dict(kinds)}", file=sys.stderr)
            for kind in kinds:  # the first few of each, seed first
                for line in [line for line in found if line.split("): ", 1)[1].startswith(kind)][:3]:
                    print("  " + line, file=sys.stderr)
        self.assertEqual(len(found), 0, "\n".join(found[:5]))
        # Not vacuous: the generator makes heads the base does excuse. Only over enough seeds to hold: a single-seed
        # replay (BASE_RED_PROPERTY_SEEDS=1) of a seed judge() rightly refuses excuses nothing (#41222's review F2).
        if count >= NON_VACUOUS_SEEDS:
            self.assertGreater(excused, count // 20)


class GeneratorIsSound(unittest.TestCase):
    """The oracle's ground truth is what the logs say: a head copied from a verdict with nothing unparseable is
    excused against it, so a refusal-only judge cannot pass the property for nothing."""

    def test_an_identical_named_head_is_excused_placed_and_whole(self):
        for placed in (True, False):
            steps = [{"name": "package tests", "conclusion": "failure", "blocks": [
                {"runner": runner, "failures": [(runner, "alpha", True)], "passes": 1, "retry": None}
                for runner in RUNNERS]}]
            case = {"seed": -1, "placed": placed, "window": [{"green": False, "steps": steps}],
                    "head": copy.deepcopy(steps)}
            with self.subTest(placed=placed):
                said = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], PropertyGitHub(case))
                self.assertTrue(said[0].startswith(f"excused '{JOB}'"), said)
                self.assertEqual(violations(case, said[0]), [])


if __name__ == "__main__":
    unittest.main()
