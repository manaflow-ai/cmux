#!/usr/bin/env python3
"""Drive one cmux NEXT nightly train (nightly-next-train.yml, mode `drive`).

  drive --tip SHA [--mode dry-run|on] [--out result.json]
        [--good-build B --quarantine SHA --reason TEXT]   (a fix-forward)

1. Plan the cars of base..tip (nightly_next_train.plan_cars); `nightly-hold`
   cars start quarantined.
2. Per-car fast guards: when NIGHTLY_NEXT_TRAIN_CAR_GUARD names a command
   (default scripts/ci/nightly-next-car-guard.sh when it exists; PR 3 of the
   design owns it), it runs once per car with `--car-json FILE`. Exit 0 keeps
   the car, exit 1 quarantines it, anything else is a guard error: a warning,
   and the car rides (the candidate build still checks it).
3. Build the candidate (tip minus the quarantined cars) as a train commit and
   run nightly-next-train.yml mode `build` on it (Release compile).
4. Red: k-way bisection over the cars' prefixes, k builds at a time, until one
   car is the first red prefix; it is quarantined (with any later car its
   revert needs) and the candidate is built again. The whole train gives up
   after NIGHTLY_NEXT_TRAIN_ROUNDS bisection rounds or
   NIGHTLY_NEXT_TRAIN_CAP_MINUTES: it ships nothing and says why.
5. Green: ask main's nightly.yml to promote the train commit (guard G1'/G2'),
   and leave one comment per newly quarantined car (its PR, or the
   `nightly-next quarantine` issue for a direct push).

Mode dry-run (the default) stops after step 2 and prints the plan.

A fix-forward (nightly_next_fix_forward.py, after a feed pull) passes the
build the feed serves now as --good-build (the base) and the pulled build's
newest change as --quarantine: the car holding that commit starts out.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from typing import Callable, Protocol

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_pages  # noqa: E402
import nightly_next_train as train  # noqa: E402

GATE_JOB = "nightly-next train Release compile"
WORKFLOW = "nightly-next-train.yml"
QUARANTINE_ISSUE = "nightly-next quarantine"
MARKER = "<!-- nightly-next-quarantine:{car}:{sha} -->"
DEFAULT_GUARD = "scripts/ci/nightly-next-car-guard.sh"


@dataclass
class Config:
    k: int = 4
    rounds: int = 3
    cap_minutes: int = 120
    poll_seconds: int = 60

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Config":
        env = os.environ if env is None else env

        def number(name: str, default: int, low: int, high: int) -> int:
            raw = (env.get(name) or "").strip()
            if not raw:
                return default
            if not raw.isdigit() or not low <= int(raw) <= high:
                raise train.TrainError(f"{name}={raw!r} must be a whole number from {low} to {high}")
            return int(raw)

        return cls(
            k=number("NIGHTLY_NEXT_TRAIN_K", 4, 1, 8),
            rounds=number("NIGHTLY_NEXT_TRAIN_ROUNDS", 3, 1, 6),
            cap_minutes=number("NIGHTLY_NEXT_TRAIN_CAP_MINUTES", 120, 30, 300),
        )


class Builder(Protocol):
    def build(self, commits: list[tuple[str, str]], deadline: float) -> dict[str, bool | None]:
        """{commit: green} for each (commit, label); None = no result by the deadline."""


@dataclass
class Outcome:
    shipped: bool = False
    commit: str = ""
    reason: str = ""
    quarantined: list[str] = field(default_factory=list)
    with_: dict = field(default_factory=dict)
    culprits: list[str] = field(default_factory=list)
    rounds: int = 0
    builds: list[dict] = field(default_factory=list)


class Train:
    def __init__(self, cars: list[train.Car], tip: str, parent: str, source_base: str, builder: Builder,
                 config: Config, clock: Callable[[], float] = time.monotonic,
                 make_commit: Callable[..., dict] = train.make_train_commit, log: Callable[[str], None] = print):
        self.cars, self.tip, self.parent, self.source_base = cars, tip, parent, source_base
        self.builder, self.config, self.clock, self.make_commit, self.log = builder, config, clock, make_commit, log
        self.start = clock()
        self.deadline = self.start + config.cap_minutes * 60
        self.outcome = Outcome()

    def _candidate(self, head: str, quarantine: list[str], title: str) -> dict:
        return self.make_commit(self.parent, head, self.cars, quarantine, title)

    def _build(self, candidates: list[tuple[dict, str]]) -> dict[str, bool | None]:
        results = self.builder.build([(c["commit"], label) for c, label in candidates], self.deadline)
        for candidate, label in candidates:
            self.outcome.builds.append({"label": label, "commit": candidate["commit"], "green": results.get(candidate["commit"])})
        return results

    def _over_time(self) -> bool:
        return self.clock() >= self.deadline

    def run(self, quarantine: list[str]) -> Outcome:
        quarantine = list(dict.fromkeys(quarantine))
        while True:
            if self._over_time():
                return self._give_up(f"the {self.config.cap_minutes}-minute cap passed before a green candidate")
            try:
                full = self._candidate(self.tip, quarantine, None)
            except train.TrainError as error:
                return self._give_up(f"the candidate cannot be made: {error}")
            quarantine = full["quarantined"]
            self.outcome.with_.update(full["with"])
            green = self._build([(full, f"candidate minus {len(quarantine)}")]).get(full["commit"])
            if green is True:
                self.outcome.shipped, self.outcome.commit = True, full["commit"]
                self.outcome.quarantined = quarantine
                self.outcome.reason = f"candidate {full['commit'][:12]} is green with {len(quarantine)} car(s) out"
                return self.outcome
            if green is None:
                return self._give_up("the candidate build had no result before the cap")
            culprit = self._bisect(quarantine)
            if culprit is None:
                return self._give_up(self.outcome.reason or "bisection found no single red car")
            self.log(f"culprit: {culprit}")
            self.outcome.culprits.append(culprit)
            quarantine.append(culprit)

    def _bisect(self, quarantine: list[str]) -> str | None:
        lo, hi = 0, len(self.cars)
        # Prefix 0 is the base itself (good by definition); prefix n is the red candidate.
        while hi - lo > 1:
            if self.outcome.rounds >= self.config.rounds:
                self.outcome.reason = f"no culprit after {self.config.rounds} bisection rounds (between car {lo} and {hi})"
                return None
            if self._over_time():
                self.outcome.reason = f"the {self.config.cap_minutes}-minute cap passed during bisection"
                return None
            points = train.bisect_points(lo, hi, self.config.k)
            self.outcome.rounds += 1
            candidates = []
            for length in points:
                head, reverts = train.prefix_candidate(self.cars, length, quarantine, self.source_base)
                try:
                    candidates.append((length, self._candidate(head, reverts, f"nightly-next train bisect: first {length} car(s)")))
                except train.TrainError as error:
                    self.log(f"prefix {length} cannot be made ({error}); skipped")
            results = self._build([(c, f"prefix {length}") for length, c in candidates])
            known = {length: results.get(c["commit"]) for length, c in candidates}
            if any(green is None for green in known.values()) and self._over_time():
                self.outcome.reason = f"the {self.config.cap_minutes}-minute cap passed during bisection"
                return None
            lo, hi = train.narrow(lo, hi, {p: g for p, g in known.items() if g is not None})
            if not candidates:
                self.outcome.reason = "no prefix candidate could be made"
                return None
        culprit = self.cars[lo]
        if culprit.id in quarantine:
            self.outcome.reason = f"the first red prefix ends at {culprit.id}, which is already out"
            return None
        return culprit.id

    def _give_up(self, reason: str) -> Outcome:
        self.outcome.shipped = False
        self.outcome.reason = f"shipped nothing: {reason}; the current nightly stays"
        return self.outcome


# ---------------------------------------------------------------- GitHub side

def gh(*args: str, input: str | None = None, check: bool = True) -> str:
    proc = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise train.TrainError(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()[:500]}")
    return proc.stdout


def comments(repo: str, number: int) -> list[dict]:
    """Every comment on an issue or pull request, one bounded page per call (scripts/ci/gh_pages.py:
    the gh quota wrapper refuses an unbounded paginating call). Past the page cap it raises
    TrainError, so a marker is never missed for a list cut short."""
    try:
        return gh_pages.items(lambda url: json.loads(gh("api", url)), f"repos/{repo}/issues/{number}/comments")
    except (gh_pages.PageCapError, TypeError) as error:
        raise train.TrainError(str(error)) from None


# The runner's own setup steps, inside which glaeda's job-started hook admits or refuses a job,
# and its own last step.
SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
RUNNER_STEPS = SETUP_STEPS | {"Complete job"}
# A compile is re-run off an owned Mac only from attempt 1: attempt 2 takes Blacksmith.
RERUN_ATTEMPTS = 2


def refused_on_owned(job: dict | None) -> bool:
    """The compile ran on an owned (glaeda-*) label and never reached its own steps.

    Failed or cancelled before any step of its own ran: no steps (a lost runner), a
    failed setup step (a refusal at job start), or only the runner's own steps (a runner
    lost after setup). A Blacksmith job, or one that failed in
    the compile, is the candidate's own result.
    """
    if not job or not any(str(label).startswith("glaeda-") for label in job.get("labels") or []):
        return False
    if job.get("conclusion") not in ("failure", "cancelled"):
        return False
    steps = [step for step in job.get("steps") or [] if isinstance(step, dict)]
    ran = [step for step in steps if step.get("name") not in RUNNER_STEPS
           and step.get("conclusion") not in (None, "skipped")]
    # Failed or cancelled with none of its own steps run: refused at setup, or the runner was lost
    # after setup succeeded (only the runner's steps are listed).
    return not ran


class GitHubBuilder:
    """Push each candidate to refs/heads/nightly-train/<run>/<n> and run
    nightly-next-train.yml mode `build` there; read its gate job."""

    def __init__(self, repo: str, run_id: str, poll_seconds: int = 60, sleep: Callable[[float], None] = time.sleep):
        self.repo, self.run_id, self.poll, self.sleep = repo, run_id, poll_seconds, sleep
        self.count = 0
        self.refs: list[str] = []
        # run id -> the attempt whose refused compile was re-run.
        self.rerun_asked: dict[int, int] = {}

    def _start(self, commit: str) -> str:
        self.count += 1
        ref = f"nightly-train/{self.run_id}/{self.count}"
        train.git("push", "--quiet", "origin", f"{commit}:refs/heads/{ref}")
        self.refs.append(ref)
        gh("workflow", "run", WORKFLOW, "--repo", self.repo, "--ref", ref, "-f", "mode=build", "-f", f"train_run={self.run_id}")
        return ref

    def _run_of(self, ref: str, commit: str) -> dict | None:
        data = json.loads(gh("api", f"repos/{self.repo}/actions/workflows/{WORKFLOW}/runs?branch={ref}&event=workflow_dispatch&per_page=20"))
        runs = [r for r in data.get("workflow_runs", []) if r.get("head_sha") == commit]
        return runs[0] if runs else None

    def _gate_job(self, run_id: int) -> dict | None:
        data = json.loads(gh("api", f"repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"))
        return next((j for j in data.get("jobs", []) if j.get("name") == GATE_JOB), None)

    def _rerun_off_owned(self, run: dict, job: dict | None) -> bool:
        """Re-run a compile an owned Mac refused or never ran, once; True when it was asked.

        pick-train-runner offers an owned label only while a runner is idle, so one can still
        be refused at "Set up runner" or lose its runner. The re-run of failed jobs keeps the
        pick and its attempt, so the compile then takes the moving Blacksmith label.
        """
        attempt = int(run.get("run_attempt") or 1)
        if self.rerun_asked.get(run["id"]) == attempt:
            return True  # asked already; GitHub has not started the new attempt yet
        if not refused_on_owned(job) or attempt >= RERUN_ATTEMPTS:
            return False
        try:
            gh("run", "rerun", str(run["id"]), "--failed", "--repo", self.repo)
        except train.TrainError as error:
            print(f"warning: could not re-run {run.get('html_url')} off the owned Mac: {error}", file=sys.stderr)
            return False
        self.rerun_asked[run["id"]] = attempt
        print(f"{run.get('html_url')}: the owned Mac did not run the compile; re-run on Blacksmith")
        return True

    def build(self, commits: list[tuple[str, str]], deadline: float) -> dict[str, bool | None]:
        refs = {commit: self._start(commit) for commit, _ in commits}
        results: dict[str, bool | None] = {commit: None for commit, _ in commits}
        pending = dict(refs)
        while pending and time.monotonic() < deadline:
            self.sleep(self.poll)
            for commit, ref in list(pending.items()):
                try:
                    run = self._run_of(ref, commit)
                except train.TrainError as error:
                    print(f"warning: {error}", file=sys.stderr)
                    continue
                if run and run.get("status") == "completed":
                    job = self._gate_job(run["id"])
                    if not (job and job.get("conclusion") == "success") and self._rerun_off_owned(run, job):
                        continue
                    results[commit] = bool(job) and job.get("conclusion") == "success"
                    print(f"{ref}: {'green' if results[commit] else 'red'} ({run.get('html_url')})")
                    del pending[commit]
        return results

    def cleanup(self, keep: str | None) -> None:
        for ref in self.refs:
            if keep and ref == keep:
                continue
            subprocess.run(["git", "push", "--quiet", "origin", f":refs/heads/{ref}"], capture_output=True)


def run_car_guards(cars: list[train.Car], command: str) -> tuple[list[str], list[str]]:
    """(quarantined car ids, warnings)."""
    if not command:
        return [], []
    out, warnings = [], []

    def one(car: train.Car) -> tuple[str, int, str]:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(asdict(car), handle)
            path = handle.name
        try:
            proc = subprocess.run([command, "--car-json", path], capture_output=True, text=True, timeout=1800)
            return car.id, proc.returncode, (proc.stdout + proc.stderr)[-2000:]
        except (OSError, subprocess.TimeoutExpired) as error:
            return car.id, 2, str(error)
        finally:
            os.unlink(path)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for car_id, code, tail in pool.map(one, [c for c in cars if not c.held]):
            if code == 1:
                out.append(car_id)
            elif code != 0:
                warnings.append(f"{car_id}: car guard error {code}: {tail.strip()[-300:]}")
    return out, warnings


def comment_quarantine(repo: str, cars: list[train.Car], outcome_ids: list[str], why: dict[str, str], run_url: str) -> list[str]:
    """One comment per car: its PR, or one line in the quarantine issue."""
    by_id = {car.id: car for car in cars}
    posted = []
    issue = None
    for car_id in outcome_ids:
        car = by_id[car_id]
        if car.held:
            continue
        marker = MARKER.format(car=car_id, sha=car.commits[-1][:12] if car.commits else "")
        body = (f"{marker}\nThis change is out of the cmux NEXT nightly train ({why.get(car_id, 'failed the candidate build')}): {run_url}\n\n"
                f"Owner: @{car.owner or 'unknown'}. This car rejoins the train once a fix lands on feat-cmux-next.")
        try:
            if car.pr:
                existing = comments(repo, car.pr)
                if any(marker in (c.get("body") or "") for c in existing):
                    continue
                gh("api", f"repos/{repo}/issues/{car.pr}/comments", "-f", f"body={body}")
            else:
                if issue is None:
                    found = json.loads(gh("api", f"repos/{repo}/issues?state=open&per_page=100&creator=github-actions%5Bbot%5D"))
                    match = next((i for i in found if i.get("title") == QUARANTINE_ISSUE and not i.get("pull_request")), None)
                    issue = match["number"] if match else json.loads(gh("api", f"repos/{repo}/issues", "-f", f"title={QUARANTINE_ISSUE}", "-f", "body=Direct pushes that the cmux NEXT nightly train left out. One line per car."))["number"]
                existing = comments(repo, issue)
                if any(marker in (c.get("body") or "") for c in existing):
                    continue
                gh("api", f"repos/{repo}/issues/{issue}/comments", "-f", f"body={body}\nCommits: {', '.join(c[:12] for c in car.commits)}")
            posted.append(car_id)
        except train.TrainError as error:
            print(f"warning: could not comment on {car_id}: {error}", file=sys.stderr)
    return posted


def suspect_car(cars: list[train.Car], commit: str) -> str | None:
    """The car holding `commit` (a fix-forward's quarantine input)."""
    if not commit:
        return None
    if not train.SHA_RE.match(commit):
        raise train.TrainError(f"--quarantine must be 40 lowercase hex, got {commit!r}")
    return next((car.id for car in cars if commit in car.commits), None)


def summary(doc: dict, outcome: Outcome | None, mode: str, warnings: list[str]) -> str:
    text = train.summary_markdown(doc).replace("(dry run)", "(dry run)" if mode != "on" else "")
    if warnings:
        text += "\nCar guard warnings:\n" + "\n".join(f"- {w}" for w in warnings) + "\n"
    if outcome is not None:
        text += f"\n**{'Shipped' if outcome.shipped else 'Not shipped'}**: {outcome.reason}\n"
        if outcome.quarantined:
            text += "\nOut of this train: " + ", ".join(outcome.quarantined) + "\n"
        if outcome.builds:
            text += "\n| build | commit | result |\n| --- | --- | --- |\n"
            for b in outcome.builds:
                text += f"| {b['label']} | `{b['commit'][:12]}` | {'green' if b['green'] else 'red' if b['green'] is False else 'no result'} |\n"
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["drive"])
    parser.add_argument("--tip", required=True)
    parser.add_argument("--mode", default=os.environ.get("NIGHTLY_NEXT_TRAIN", "dry-run") or "dry-run")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    parser.add_argument("--base-commit", default="")
    parser.add_argument("--feed", default=train.FEED)
    parser.add_argument("--verdicts", default=train.VERDICTS)
    parser.add_argument("--good-build", default="")
    parser.add_argument("--quarantine", default="", help="a commit (40 hex) whose car starts quarantined")
    parser.add_argument("--reason", default="")
    parser.add_argument("--out", default="train-result.json")
    args = parser.parse_args(argv)
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{args.repo}/actions/runs/{run_id}"
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "")
    try:
        if args.mode not in ("dry-run", "on"):
            raise train.TrainError(f"mode {args.mode!r} is not dry-run or on")
        config = Config.from_env()
        base = train.resolve_base(args)
        train.ensure_history(base["commit"], args.tip)
        source, carried = train.source_base(base["commit"])
        cars = train.plan_cars(source, args.tip, args.repo, carried=carried)
        train.require_on_tip(source, cars, args.tip)
        doc = train.train_json(base, source, args.tip, cars)
        guard = os.environ.get("NIGHTLY_NEXT_TRAIN_CAR_GUARD") or (DEFAULT_GUARD if os.path.exists(DEFAULT_GUARD) else "")
        guarded_out, warnings = run_car_guards(cars, guard)
        quarantine = [car.id for car in cars if car.held] + guarded_out
        suspect = suspect_car(cars, args.quarantine)
        if suspect:
            quarantine.append(suspect)
            warnings.append(f"fix-forward: {suspect} starts out ({args.reason or 'pulled build'})")
        elif args.quarantine:
            warnings.append(f"fix-forward: {args.quarantine[:12]} is in no car of this train")
        quarantine = list(dict.fromkeys(quarantine))
        outcome = None
        if args.mode == "on" and cars:
            parent = train.git("ls-remote", "origin", f"refs/heads/{train.TARGET}").split()[0]
            train.git("fetch", "--no-tags", "--filter=blob:none", "origin", parent, check=False)
            builder = GitHubBuilder(args.repo, run_id, config.poll_seconds)
            runner = Train(cars, args.tip, parent, source, builder, config)
            outcome = runner.run(quarantine)
            keep = None
            if outcome.shipped:
                keep = next((ref for ref, b in zip(builder.refs, outcome.builds) if b["commit"] == outcome.commit), None)
                now = train.git("ls-remote", "origin", f"refs/heads/{train.TARGET}").split()[0]
                if now != parent:
                    outcome.shipped = False
                    outcome.reason = f"shipped nothing: nightly-next moved from {parent[:12]} to {now[:12]} during the train; the next tick starts a new one"
                else:
                    # "tick:": main admits only the 30-minute tick's promotions (promote-nightly-next.mjs decideRequest),
                    # and a train is the tick's (or a person's) one promotion, so it carries the mark.
                    gh("workflow", "run", "nightly.yml", "--repo", args.repo, "--ref", "main", "-f", f"promote_nightly_next_sha=tick:{outcome.commit}")
                    outcome.reason += f"; promotion of {outcome.commit} requested"
            builder.cleanup(keep)
            why = {cid: f"quarantined with {outcome.with_[cid]}" for cid in outcome.with_}
            why.update({cid: "failed the candidate Release compile" for cid in outcome.culprits})
            why.update({cid: "failed its car guard" for cid in guarded_out})
            if suspect:
                why[suspect] = f"the newest change of a pulled build ({args.reason or 'canary'})"
            guarded_out = guarded_out + ([suspect] if suspect else [])
            carried_ids = {x.id for x in cars if x.carried}
            out_ids = outcome.quarantined if outcome.shipped else list(dict.fromkeys(guarded_out + outcome.culprits))
            comment_quarantine(args.repo, cars, [c for c in out_ids if c not in carried_ids], why, run_url)
        result = {**doc, "mode": args.mode, "guardWarnings": warnings, "outcome": asdict(outcome) if outcome else None}
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
        text = summary(doc, outcome, args.mode, warnings)
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as handle:
                handle.write(text)
        print(text)
        return 0 if outcome is None or outcome.shipped else 1
    except train.TrainError as error:
        print(f"nightly-next train: {error}", file=sys.stderr)
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as handle:
                handle.write(f"### nightly-next train failed\n\n{error}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
