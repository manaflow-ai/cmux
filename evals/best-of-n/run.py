#!/usr/bin/env python3
"""Best-of-N eval (RFD 0167 row 14): does the judge's pick beat a single attempt?

Each task is a small function with a written spec and hidden tests the agents never see. One `acpmux race` per task
runs N attempts of the same model in separate worktrees and an independent reviewer picks one (`hub/races.rs`).
Each attempt's worktree is then scored on the hidden tests here, with no model in the loop:

- single: the mean solve rate of the N attempts, the expected result of running one attempt (no extra runs needed:
  every attempt is an independent single attempt);
- pick: the solve rate of the attempt the reviewer picked (none picked scores 0);
- oracle: 1 when any attempt solved it (pass@N, the ceiling any judge can reach);
- win_rate_gain = pick - single, in solve-rate points (a ratio, 0..1).

    run.py setup --work DIR                      make DIR/repo, a git repo with every task's starter
    run.py start --work DIR [--model M] [--attempts N] [--reviewer R] [--tasks a,b] [--diverse models|full] [--max-live K]
    run.py score --work DIR [--wait SECONDS] [--out FILE]
    run.py merge --out FILE RESULTS RESULTS...   fill a run's unjudged tasks from reruns of exactly those tasks

`start` must run inside an authenticated acpmux agent session: the races' parent is a sub-session of it that works in
DIR/repo. Put DIR under a folder the person trusts by rule (`agents.trust.projectRoots`, such as ~/scratch): the
candidates' worktree starts are made from DIR/repo, and a folder with no trust decision raises one trust card per
candidate on the parent, which only the person can answer (`hub/trust_wait.rs`); /tmp hangs the same way.
Attempts are identical samples of one prompt by default. `--diverse` makes them differ on purpose, so the judge has
something to choose between (DIVERSE below): `models` gives each attempt its own model (haiku, sonnet, codex, haiku);
`plans` keeps --model and gives each attempt a different plan hint; `full` does both: a different plan hint per attempt (`acpmux race new --hint`, one per candidate), the first attempt cold
with none. `score` reports oracle_gain (oracle - single: did the attempts differ in a way that matters) and
judge_gap (pick - oracle: what the judge left on the table) beside win_rate_gain.

`score` waits for every race to end (or its deadline) and writes the results (schema best-of-n-results/v1).
A race whose attempts or review broke (no worktree, a reviewer with no JSON verdict) measures nothing: it is left out
of n_tasks and listed in `unjudged` with its reason, so a run that lost races says so. `merge` fills those from a
rerun of the same config; it refuses a task judged in two runs, so a judged task is never re-rolled.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import time

HERE = Path(__file__).resolve().parent
TASKS = HERE / "tasks"
# Task sets: `tasks` (small, saturated for current models), `tasks_hard` (aimed at single ~0.3-0.5, but single 0.85
# for haiku) and `tasks_real` (real cmux bug fixes ported to Python: the buggy code, its bug report and the spec;
# saturated too: haiku solved 36 of 36 at effort low, results/ holds the runs), `tasks_report` (the same nine fixes
# with only the bug report a user would file: no spec, the buggy code, hidden tests limited to what the report implies;
# haiku x4 at effort low, two runs of 9: single 0.75 and 0.78, pick 0.78 and 0.89, pass@4 0.89, gain +0.03 and +0.11,
# pooled +0.07 over 18 races) and `tasks_deep` (modules where the reported symptom is one site of a bug class, plus
# perf bounds, counter-default rules and random op sequences checked against a model; 27 tasks). haiku still solves
# tasks_deep at 0.92 single (gain +0.05); codex/gpt-5.6-luna at effort low solves 0.70 single, 0.96 picked by a sonnet
# judge (gain +0.26, judge gap 0; results/tasks_deep-*.json).
SETS = ("tasks", "tasks_hard", "tasks_real", "tasks_report", "tasks_deep")
REPORT_SETS = ("tasks_report",)


def brief_name() -> str:
    """The file each task folder's prompt.md is copied to: a spec, or a bug report for the report-only sets."""
    return "ISSUE.md" if TASKS.name in REPORT_SETS else "SPEC.md"


def use_set(work: Path, chosen: str | None = None) -> str:
    """Point TASKS at the work dir's task set: `setup --set` records it in WORK/task_set, the rest read it."""
    global TASKS
    marker = work / "task_set"
    name = chosen or (marker.read_text().strip() if marker.is_file() else "tasks")
    if name not in SETS:
        sys.exit(f"run.py: no task set {name} (sets: {', '.join(SETS)})")
    TASKS = HERE / name
    # `setup` freezes the set into WORK/tasks, so a task edited mid-run is scored with the tests its starter had.
    if (work / "tasks").is_dir():
        TASKS = work / "tasks"
    return name
SCHEMA = "best-of-n-results/v1"
# `--diverse`: one (model, plan hint) per attempt, cycled past four. The first attempt starts cold: no hint at all.
DIVERSE = (
    ("claude/haiku", ""),
    ("claude/sonnet", "Approach for this attempt: write the failing test first. Turn the spec's bug report into a "
                      "check that fails on the current code, then change the code until it passes, then add edge cases."),
    ("codex", "Approach for this attempt: read the code path first. Trace how the current code handles each input the "
              "spec names before you edit anything, write down where it goes wrong, then make the smallest fix."),
    ("claude/haiku", "Approach for this attempt: enumerate the spec's rules and edge cases as a list first, then "
                     "rewrite the function from that list rather than patching the old code, and check every item."),
)
TERMINAL = {"completed", "failed", "cancelled"}
ABSTAINED = "reviewer did not select"


def tasks(only: str | None) -> list[str]:
    names = sorted(p.name for p in TASKS.iterdir() if (p / "prompt.md").is_file())
    if only:
        wanted = [t.strip() for t in only.split(",") if t.strip()]
        missing = [t for t in wanted if t not in names]
        if missing:
            sys.exit(f"run.py: no task {', '.join(missing)} (tasks: {', '.join(names)})")
        names = wanted
    return names


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=best-of-n", "-c", "user.email=best-of-n@cmux.invalid",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


def setup(work: Path, only: str | None = None) -> Path:
    repo = work / "repo"
    if repo.exists():
        sys.exit(f"run.py: {repo} exists; use a new --work")
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    for name in tasks(only):
        (repo / name).mkdir()
        shutil.copy(TASKS / name / "starter.py", repo / name / f"{name}.py")
        shutil.copy(TASKS / name / "prompt.md", repo / name / brief_name())
    (repo / "README.md").write_text(f"Small functions, one folder each; {brief_name()} in each folder is its "
                                    f"{'bug report' if brief_name() == 'ISSUE.md' else 'spec'}.\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "starters")
    return repo


def acpmux(*args: str, timeout: float = 120) -> dict:
    out = subprocess.run(["acpmux", *args, "--json"], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(f"acpmux {' '.join(args[:2])}: {out.stderr.strip() or out.stdout.strip()}")
    return json.loads(out.stdout)


def prompt_for(name: str) -> str:
    spec = (TASKS / name / "prompt.md").read_text().strip()
    if brief_name() == "ISSUE.md":
        return (f"In this repository, fix the bug reported in `{name}/ISSUE.md` (repeated here) in `{name}/{name}.py`. "
                f"Write your own checks if you want; do not add dependencies.\n\n{spec}")
    return (f"In this repository, edit only `{name}/{name}.py` (its spec is `{name}/SPEC.md`, repeated here). "
            f"Write your own checks if you want; do not add dependencies.\n\n{spec}")


def plan(model: str, attempts: int, diverse: str | None) -> list[tuple[str, str]]:
    """Each attempt's (model, plan hint): the same model and no hint unless `--diverse`."""
    if not diverse:
        return [(model, "")] * attempts
    rows = [DIVERSE[i % len(DIVERSE)] for i in range(attempts)]
    return [(model if diverse == "plans" else m, "" if diverse == "models" else h) for m, h in rows]


def hints_in_prompt(prompt: str, hints: list[str]) -> str:
    """For an acpmux with no `race new --hint`: every attempt reads every approach, keyed by its worktree's name
    (a race's candidate worktree ends -c1, -c2, ...), so this is weaker than a real per-attempt hint."""
    table = "\n".join(f"- `-c{i + 1}`: {h or 'no set approach: work however you think best.'}" for i, h in enumerate(hints))
    return (f"First run `basename \"$PWD\"`: your attempt is the -cN it ends with. Follow your attempt's approach and "
            f"no other:\n{table}\n\n{prompt}")


# acpmux refuses a lane's sub-session past agents.subsessions.maxLaneSessions (32 by default), and a race's candidates
# and reviewer stay live sessions until the race is stopped. Starting every task's race at once (27 tasks x 5 sessions
# on tasks_deep, 2026-11-26) had the cap refuse candidates in arbitrary order, so most races ran with 1-3 of their N
# attempts and the run measured nothing. `start` now keeps at most max_live races in flight, stops each one that ends
# (its worktrees stay for `score`), and re-queues a race the cap refused.
LANE_CAP = int(os.environ.get("ACPMUX_MAX_LANE_SESSIONS") or 32)
REFUSED = "fan-out cap"


def default_max_live(attempts: int) -> int:
    """Races in flight that fit the lane cap: each holds N candidates and a reviewer; the parent holds one slot."""
    return max(1, (LANE_CAP - 2) // (attempts + 1))


def refused(race: dict) -> bool:
    return any(REFUSED in (c.get("error") or "") for c in race.get("candidates") or [])


def settle(state: dict, name: str, wait: bool) -> bool:
    """True once NAME's race has ended (stopped to free its sessions); a race the cap refused is dropped to rerun."""
    while True:
        race = race_show(state["parent"], state["races"][name])
        if race.get("state") in TERMINAL or refused(race):
            break
        if not wait:
            return False
        time.sleep(15)
    # `race stop` turns an ended race's record into "cancelled" and drops its reason, so keep the verdict first:
    # a reviewer that judged every attempt wrong leaves state "failed", winnerId null (2026-11-26: 14 of 36 races
    # read "cancelled" for that and score dropped them, hiding the judge's misses).
    state.setdefault("verdicts", {})[name] = {k: race.get(k) for k in ("state", "reason", "winnerId", "updatedAt")}
    try:
        acpmux("race", "stop", state["races"][name], "--parent", state["parent"])
    except RuntimeError:
        pass  # already stopped; score reads the saved record either way
    if refused(race):
        del state["races"][name]
    else:
        state.setdefault("settled", []).append(name)
    return True


def start(work: Path, model: str, attempts: int, reviewer: str, effort: str | None, only: str | None,
          diverse: str | None = None, emulate: bool = False, max_live: int | None = None) -> None:
    hinted = diverse in ("full", "plans")
    has_hint = "--hint" in subprocess.run(["acpmux", "race", "new", "--help"], capture_output=True, text=True).stdout
    if hinted and not has_hint and not emulate:
        sys.exit("run.py: this acpmux has no `race new --hint` (per-attempt plan hints); pass --emulate-hints, or "
                 "use --diverse models")
    repo = work / "repo"
    state_file = work / "state.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if not state.get("parent"):
        name = f"bon-bench-{dt.datetime.now(dt.timezone.utc):%m%d%H%M%S}"
        acpmux("new", "--parent", os.environ["ACPMUX_SESSION_ID"], "--cwd", str(repo), "-m", reviewer, "--name", name, "-d",
               "You hold best-of-N benchmark races as their parent. Reply with the single word ready and stop.",
               timeout=300)
        state = {"parent": name, "repo": str(repo), "model": model, "attempts": attempts, "reviewer": reviewer,
                 "effort": effort, "diverse": diverse, "plan": plan(model, attempts, diverse),
                 "hints_emulated": hinted and not has_hint, "races": {}}
    # Only the tasks `setup` put in the repo (a set can grow after setup).
    max_live = max_live or default_max_live(attempts)
    queue = [t for t in tasks(only) if (repo / t).is_dir()]
    while queue:
        name = queue.pop(0)
        if name in state["races"]:
            if name in state.get("settled", []) or not settle(state, name, wait=False):
                continue
            if name in state["races"]:
                continue
        live = [n for n in state["races"] if n not in state.get("settled", [])]
        while len(live) >= max_live:
            for n in live:
                if settle(state, n, wait=False):
                    if n not in state["races"]:
                        queue.append(n)
            state_file.write_text(json.dumps(state, indent=2))
            live = [n for n in state["races"] if n not in state.get("settled", [])]
            if len(live) >= max_live:
                time.sleep(15)
        args = ["race", "new", "--parent", state["parent"], "--reviewer", reviewer, "--prompt-file",
                str(work / f"{name}.prompt.md")]
        hints = [h for _, h in plan(model, attempts, diverse)]
        emulated = hinted and not has_hint
        (work / f"{name}.prompt.md").write_text(hints_in_prompt(prompt_for(name), hints) if emulated
                                               else prompt_for(name))
        for model_i, _ in plan(model, attempts, diverse):
            args += ["-m", model_i]
        if hinted and not emulated:
            for hint in hints:
                args += ["--hint", hint]
        if effort:
            args += ["-e", effort]
        race = acpmux(*args, timeout=300)
        state["races"][name] = race["id"]
        state_file.write_text(json.dumps(state, indent=2))
        print(f"{name}: race {race['id']}", flush=True)
    for n in [n for n in state["races"] if n not in state.get("settled", [])]:
        settle(state, n, wait=True)
        if n not in state["races"]:
            sys.exit(f"run.py: {n}'s race was refused by the lane cap at the end; run start again to rerun it")
        state_file.write_text(json.dumps(state, indent=2))
    state_file.write_text(json.dumps(state, indent=2))


def hidden_tests(name: str, folder: Path) -> tuple[int, int, list[str]]:
    """(passed, total, failures) of the task's hidden tests against the module in FOLDER, in a fresh python."""
    code = (
        "import importlib.util, json, sys, traceback\n"
        f"sys.path[:0] = [{str(folder)!r}, {str(HERE)!r}]\n"
        f"spec = importlib.util.spec_from_file_location('hidden', {str(TASKS / name / 'hidden_test.py')!r})\n"
        "mod = importlib.util.module_from_spec(spec)\n"
        "res = {'passed': 0, 'total': 0, 'failures': []}\n"
        "try:\n    spec.loader.exec_module(mod)\n"
        "except BaseException as e:\n    res['failures'].append('import: ' + repr(e)[:200]); res['total'] = 1\n"
        "for k in sorted(k for k in dir(mod) if k.startswith('test_')):\n"
        "    res['total'] += 1\n"
        "    try:\n        getattr(mod, k)(); res['passed'] += 1\n"
        "    except BaseException as e:\n        res['failures'].append(k + ': ' + repr(e)[:200])\n"
        "print(json.dumps(res))\n"
    )
    try:
        out = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=60,
                             cwd=str(folder))
        res = json.loads(out.stdout.strip().splitlines()[-1])
    except (subprocess.TimeoutExpired, IndexError, json.JSONDecodeError) as e:
        return 0, 1, [f"runner: {e!r}"[:200]]
    return res["passed"], res["total"], res["failures"]


def check(only: str | None = None) -> int:
    """Each task's hidden tests pass on its reference.py and fail on its starter (and on partial.py, a fix of only the
    reported symptom, where a task has one): the set is solvable and not free."""
    bad = 0
    for name in tasks(only):
        with tempfile.TemporaryDirectory() as tmp:
            for src, want in (("reference.py", True), ("starter.py", False), ("partial.py", False)):
                if src == "partial.py" and not (TASKS / name / src).is_file():
                    continue
                if not (TASKS / name / src).is_file():
                    print(f"{name}: no {src}")
                    bad += src == "reference.py"
                    continue
                folder = Path(tmp) / src.removesuffix(".py") / name
                folder.mkdir(parents=True)
                shutil.copy(TASKS / name / src, folder / f"{name}.py")
                passed, total, fails = hidden_tests(name, folder)
                solved = passed == total and total > 0
                print(f"{name} {src}: {passed}/{total}" + ("" if solved == want else f"  WRONG {fails[:3]}"))
                bad += solved != want
    return 1 if bad else 0


def race_show(parent: str, rid: str) -> dict:
    """`acpmux race show`, else the parent's own saved record: a daemon restart leaves this agent's caller token
    stale (`subsessions.caller_not_proven`) while the races go on, and reading them needs no authority."""
    try:
        return acpmux("race", "show", rid, "--parent", parent)
    except RuntimeError as e:
        home = Path(os.environ.get("ACPMUX_HOME", Path.home() / ".acpmux"))
        for meta in home.glob("sessions/*/session.json"):
            try:
                doc = json.loads(meta.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if (doc.get("name") or "").split("/")[-1] == parent:
                race = next((r for r in doc.get("races") or [] if r.get("id") == rid), None)
                if race:
                    return race
        raise RuntimeError(f"{e} (and no saved record of race {rid} under {home})") from e


def score(work: Path, wait_s: float, out: Path | None) -> dict:
    state = json.loads((work / "state.json").read_text())
    deadline = time.time() + wait_s
    races = {}
    while True:
        races = {n: race_show(state["parent"], rid) for n, rid in state["races"].items()}
        if all(r.get("state") in TERMINAL for r in races.values()) or time.time() >= deadline:
            break
        time.sleep(20)
    rows = []
    for name, race in sorted(races.items()):
        verdict = (state.get("verdicts") or {}).get(name)
        if verdict and race.get("state") == "cancelled":
            race = {**race, **verdict}
        cands = []
        for c in race.get("candidates", []):
            cwd = c.get("cwd")
            passed, total, fails = hidden_tests(name, Path(cwd) / name) if cwd else (0, 1, ["no worktree"])
            cands.append({"id": c["id"], "state": c.get("state"), "target": c.get("target"), "passed": passed,
                          "total": total,
                          "solved": passed == total and total > 0, "failures": fails[:5]})
        winner = race.get("winnerId")
        pick = next((c for c in cands if c["id"] == winner), None)
        n = len(cands) or 1
        # Judged: the reviewer gave a verdict on every attempt, a pick or an abstention ("did not select"), which
        # scores as a pick that fails. A race whose attempts or review never finished measures nothing.
        judged = race.get("state") == "completed" or (
            race.get("state") == "failed" and ABSTAINED in (race.get("reason") or "")
            and cands and all(c["state"] == "completed" for c in cands))
        rows.append({
            "task": name, "race": race.get("id"), "state": race.get("state"), "winner": winner, "judged": judged,
            "reason": (race.get("reason") or "")[:400],
            "single": sum(c["solved"] for c in cands) / n,
            "single_tests": sum(c["passed"] / c["total"] for c in cands) / n,
            "pick": 1.0 if pick and pick["solved"] else 0.0,
            "pick_tests": pick["passed"] / pick["total"] if pick else 0.0,
            "oracle": 1.0 if any(c["solved"] for c in cands) else 0.0,
            "oracle_tests": max((c["passed"] / c["total"] for c in cands), default=0.0),
            # createdAt to the verdict (or last change): every attempt and the review, wall clock.
            "wall_s": round(((race.get("updatedAt") or 0) - (race.get("createdAt") or 0)) / 1000, 1),
            "candidates": cands,
        })
    doc = {
        "schema": SCHEMA,
        "measured_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "task_set": f"cmux evals/best-of-n/{(work / 'task_set').read_text().strip() if (work / 'task_set').is_file() else TASKS.name}",
        "model": state["model"], "attempts": state["attempts"], "reviewer": state["reviewer"],
        "effort": state.get("effort"), "diverse": state.get("diverse"), "plan": state.get("plan"),
        "hints_emulated": state.get("hints_emulated"),
        "rows": rows,
    }
    summarize(doc)
    text = json.dumps(doc, indent=2) + "\n"
    (out or work / "results.json").write_text(text)
    return doc


MERGE_SAME = ("schema", "model", "attempts", "reviewer", "effort", "diverse", "plan", "hints_emulated", "task_set")


def summarize(doc: dict) -> None:
    """The run's means, counts and gains, from its rows."""
    rows = doc["rows"]
    done = [r for r in rows if r["judged"]]
    mean = lambda key: round(sum(r[key] for r in done) / len(done), 4) if done else None  # noqa: E731
    doc.update({
        "n_tasks": len(done), "n_started": len(rows), "n_abstained": sum(r["winner"] is None for r in done),
        "unjudged": {r["task"]: r["reason"][:160] for r in rows if not r["judged"]},
        "single_solve_rate": mean("single"), "pick_solve_rate": mean("pick"), "oracle_solve_rate": mean("oracle"),
        "single_test_share": mean("single_tests"), "pick_test_share": mean("pick_tests"),
        "oracle_test_share": mean("oracle_tests"), "mean_wall_s": mean("wall_s"),
    })
    if done:
        doc["win_rate_gain"] = round(doc["pick_solve_rate"] - doc["single_solve_rate"], 4)
        doc["oracle_gain"] = round(doc["oracle_solve_rate"] - doc["single_solve_rate"], 4)
        doc["judge_gap"] = round(doc["pick_solve_rate"] - doc["oracle_solve_rate"], 4)


def merge(paths: list[Path], out: Path) -> dict:
    """The first run, its unjudged tasks filled from later runs of the same config (a rerun of only those tasks)."""
    docs = [json.loads(p.read_text()) for p in paths]
    base = docs[0]
    rows = {r["task"]: r for r in base["rows"]}
    for p, d in zip(paths[1:], docs[1:]):
        differ = [k for k in MERGE_SAME if d.get(k) != base.get(k)]
        if differ:
            sys.exit(f"run.py merge: {p} differs from {paths[0]} in {', '.join(differ)}")
        for r in d["rows"]:
            have = rows.get(r["task"])
            if have and have["judged"] and r["judged"]:
                sys.exit(f"run.py merge: {r['task']} is judged in {p} and an earlier run; a judged task is not re-rolled")
            if r["judged"] or not have:
                rows[r["task"]] = {**r, "from": str(p)}
    doc = {**base, "rows": [rows[t] for t in sorted(rows)], "merged_from": [str(p) for p in paths],
           "measured_at": max(d["measured_at"] for d in docs)}
    summarize(doc)
    out.write_text(json.dumps(doc, indent=2) + "\n")
    return doc


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--out", type=Path, required=True)
    m.add_argument("results", type=Path, nargs="+")
    for name in ("setup", "start", "score", "check"):
        p = sub.add_parser(name)
        p.add_argument("--work", type=Path, required=name != "check")
        if name in ("setup", "check"):
            p.add_argument("--set", choices=SETS, default="tasks")
            p.add_argument("--tasks", help="only these tasks (comma-separated), as for a calibration run")
        if name == "start":
            p.add_argument("--model", default="claude/haiku")
            p.add_argument("--attempts", type=int, default=4)
            p.add_argument("--reviewer", default="claude/sonnet")
            p.add_argument("--effort")
            p.add_argument("--tasks")
            p.add_argument("--diverse", choices=("models", "plans", "full"),
                           help="make attempts differ: models (per-attempt models), plans (--model with per-attempt "
                                "plan hints), full (both)")
            p.add_argument("--max-live", type=int,
                           help="races in flight at once (default: what fits acpmux's lane session cap)")
            p.add_argument("--emulate-hints", action="store_true",
                           help="with no `race new --hint`, key the hints to each attempt's worktree in the prompt")
        if name == "score":
            p.add_argument("--wait", type=float, default=3600)
            p.add_argument("--out", type=Path)
    a = ap.parse_args()
    if a.cmd == "merge":
        doc = merge(a.results, a.out)
        print(json.dumps({k: v for k, v in doc.items() if k != "rows"}, indent=2))
        return
    if a.cmd == "check":
        use_set(Path("/nonexistent"), a.set)
        sys.exit(check(a.tasks))
    work = a.work.resolve()
    if a.cmd == "setup":
        use_set(work, a.set)
        repo = setup(work, a.tasks)
        for name in tasks(a.tasks):
            shutil.copytree(TASKS / name, work / "tasks" / name, ignore=shutil.ignore_patterns("__pycache__"))
        (work / "task_set").write_text(a.set + "\n")
        print(repo)
        return
    use_set(work)
    if a.cmd == "start":
        if a.attempts < 2:
            sys.exit("run.py: --attempts must be at least 2 (a race needs two candidates)")
        start(work, a.model, a.attempts, a.reviewer, a.effort, a.tasks, a.diverse, a.emulate_hints, a.max_live)
    else:
        doc = score(work, a.wait, a.out)
        print(json.dumps({k: v for k, v in doc.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
