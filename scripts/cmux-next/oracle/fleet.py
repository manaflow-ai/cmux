#!/usr/bin/env python3
"""The oracle's app runs on the fleet: one `cmux-ci run` step per shard, waits that never resubmit, one merged receipt.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3F.1 and 3G, task 050. Stdlib only, Python 3.9+ (the
fleet minis run the system python3), safe under `python3 -I`. Agents never use maclease (spec rule 11): every step goes
through the controller with `cmux-ci`, and a client whose name says maclease is refused.

Client side (the agent's host: the Linux VM or a laptop; nothing builds here):
    fleet.py run --ref SHA [--shards N] [selection]       N steps of scripts/measure/oracle.sh, one receipt
    fleet.py diff --base A [--head B] [--shards N] [...]  both sides per shard, head on the base step's worker
                                                           (head defaults to HEAD; the default diff, task 112)
    fleet.py diff --switch NAME --ref SHA | --arm launch-config --ref SHA | --engine webkit,chromium --ref SHA
                                                           `oracle.py diff --product app ...` hands its argv here
A base/head diff builds the base side from overlay.py's plan (p15-oracle-202): head's oracle commits and runner on the
base, pushed to refs/heads/oracle-overlay/<sha> on --remote (default origin) so the controller can build it, or, when
they do not apply (or `--v0 REASON`), the base with head's runner and v0 facets (`--facets=v0`) on both sides.
OUT/overlay.json holds the plan, fleet.json its summary, and `oracle.py diff --overlay` masks what is not comparable.
Selection: --suite, --filter, --repeat, --retry-limit, --shuffle, --seed, --batch-limit, --config (bench, the
default, or debug: oracle.py's --build of the run), --dry-run (plan only: the step builds nothing).
Same-host pairing (p15-oracle-008): in a diff, shard i of the second side runs on the worker shard i of the first
side ran on (`--target-worker`), and each side's receipt records its host, macOS version and main display
(oracle.py host_info). Before anything merges, every shard's two receipts must name the same host, OS and display
(diff.py's same-host keys); a pair that does not is refused as host-mismatch (exit 3, fleet.json "verdict":
"host-mismatch", "mismatched": {"shard i": [fields]}), and nothing is compared. diff.py checks every case's host again
after the shards merge. Different shards may land on different minis; a case is never compared across them.
This is Pinpoint's rule of running both changes of a comparison on one bot (chromium/src
third_party/catapult/dashboard/dashboard/pinpoint/models/quest/run_test.py: later executions are pinned to the bot
of the first, because results from two devices are not comparable).
Seeded faults (p15-oracle-026): `run --mutant P` and `diff --base SHA --head SHA --head-mutant P` build that side
with tests/oracle/mutants/app/<name>.patch applied; the step applies the copy in its own checkout, so the patch must
be in the commit's tree, with the same content as here.

Each shard is one step: `cmux-ci run --class exclusive --label measure --no-supersede --script
scripts/measure/oracle.sh --ref SHA --key oracle-<run>-<side>-s<i>of<N> --artifact artifacts/oracle/<key>.tar.gz
--arg=--shard=i/N ...`. Spec 3G says `--class isolated`; the controller runs every scripts/measure/ script as
class exclusive (cmuxterm-hq build-fleet/cmd/controller/ci_step.go measureClass) and refuses any other class, and a
GUI app launch needs the host alone, so exclusive it is. When `cmux-ci run` ends before its step does (exit 130, the
client was interrupted or lost the controller), fleet.py waits on the same step id with `cmux-ci wait ID`; a wait that
times out (exit 2) is followed by another wait, never by a new submission. The step ids are kept in
OUT/shards/<side>/<i>/step.json as soon as `cmux-ci run` prints them, so `fleet.py run --out OUT` (or `diff --out`)
again re-attaches to the same steps.

The controller refuses scripts/measure/oracle.sh until hq lists it (ci_step.go measureScripts) or the commit is on
main or feat-cmux-next (measure_reviewed.go). Until then a run ends with exit 3 and fleet.json says so (`refused`).

Worker side (inside the step, run by scripts/measure/oracle.sh after it built the tagged app):
    fleet.py step --ref SHA --tag TAG --config C --work DIR --artifact PATH [--app APP] [--dry-run] [selection]
runs `oracle.py run --product app --binary APP ... --out DIR/run` and packs DIR/run plus fleet-step.json into the
artifact (a path in the step's checkout, the only place `cmux-ci run --artifact` returns files from). The run itself
stays outside the checkout (spec 3G). The step passes when oracle.py wrote a receipt: the verdict is the receipt's,
read after the merge; a step fails only when it has no receipt (the build, the launch or oracle.py's arguments).

Outputs (outside the checkout, default /tmp/oracle/fleet/<run id>):
    shards/<side>/<i>/   step.log, step.json, job.json (the controller's job record), run/ (the shard's run dir)
    <side>/              the merged run dir (oracle.py merge_runs: no gap, no overlap, one config)
    compare/             diff only: oracle.py diff --base-run ... --head-run ... --builds builds.json (diff.py,
                          divergence.json; comparison.json's "builds")
    builds.json          diff only: {"base", "head"}: each side's label, ref, exact sha, gitlinks, config and steps
    fleet.json           {"schema": "cmux-oracle-fleet-v1", "runId", "sides": {side: {"ref", "sha", "gitlinks",
                          "gitlinksFrom", "shards": [...], "merged", "ok", "workers"}}, "ok"}; a refused diff pair adds
                          "verdict": "host-mismatch" and "mismatched": {"shard i": [the host fields that differ or
                          were not recorded]}
Exact builds (task 112): each step records the commit it built, every gitlink of its tree and the commit each
submodule had checked out for the build (fleet-step.json). A shard built at another SHA, or with a submodule off its
gitlink (the worker's checkout is reused), is `wrong-build` and leaves its side incomplete. The side's gitlinks come
from this checkout's tree when it has the commit, else from the steps.
Exit codes: 0 every shard merged and the receipt is ok (diff: no unexplained divergence), 1 the merged receipt has
unexpected results (diff: divergences), 2 bad arguments, 3 incomplete (a shard refused, failed or without a receipt;
diff: a host-mismatch pair, or refused by oracle.py), 4 diff.py internal error.

Chrome reference (chromium/src):
- testing/trigger_scripts/base_test_triggerer.py: one swarming task per shard, the shard's index and total in
  GTEST_SHARD_INDEX / GTEST_TOTAL_SHARDS; here `--shard=i/N`, and oracle.py's stable hash places each case.
- `swarming collect` (luci-go client/cmd/swarming): collects tasks by id and never triggers them again; a lost
  collect is resumed with the same ids.
- testing/merge_scripts/standard_gtest_merge.py: the shard outputs merge into one result, and a missing shard is an
  error in that result, not a silent gap.
- testing/merge_scripts/standard_isolated_script_merge.py: each shard's output is fetched from the task's isolated
  output; here the step's artifact tarball.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import platform as platform_mod
import re
import shutil
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import diff  # noqa: E402  (host_mismatch: the same-host keys)
import oracle  # noqa: E402  (the sibling CLI: merge_runs, write_merged, DEFAULT_RETRY_LIMIT, new_run_id)
import overlay  # noqa: E402  (the base build of a base/head diff)
import patch_mutants  # noqa: E402  (the app mutants' header checks)

SCRIPT = "scripts/measure/oracle.sh"
# ci_step.go: measureClass and measureLabel. Every scripts/measure/ step runs alone on a worker that has a console.
STEP_CLASS, STEP_LABEL = "exclusive", "measure"
FLEET_SCHEMA = "cmux-oracle-fleet-v1"
STEP_SCHEMA = "cmux-oracle-fleet-step-v1"
DEFAULT_OUT_BASE = Path("/tmp/oracle/fleet")
ARTIFACT_DIR = "artifacts/oracle"
MAX_SHARDS = 64
# A step builds the tagged bench app (about 15 min cold) and runs its shard; --timeout counts from the claim.
DEFAULT_STEP_TIMEOUT_S = 4 * 3600
DEFAULT_WAIT_TIMEOUT_S = 1800
CONFIGS = ("bench", "debug")
# ci_step.go: ciStepArgPattern, ciStepMaxArgs, ciStepMaxArgLen, ciStepKeyPattern.
ARG_PATTERN = re.compile(r"^[A-Za-z0-9._/@+=,:-]+$")
MAX_STEP_ARGS, MAX_ARG_LEN = 16, 2048
KEY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
TAG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
STEP_LINE = re.compile(r"cmux-ci: step ([0-9a-f]{12,}) ")
# `cmux-ci run` exit codes that are the client's or the fleet's, not the step's (ci-client.py run_step).
CLIENT_GONE, NO_WORKER, QUEUE_TIMEOUT, SUPERSEDED, RUN_TIMEOUT = 130, 69, 75, 76, 124
WAIT_TIMED_OUT = 2  # wait-job.py: "Timed out observing ID; remote job is unchanged"
TERMINAL = ("done", "failed", "cancelled")
# The controller refuses the submission (ci_step.go, measure_reviewed.go); the worker refuses a script blob that is not
# the one on main or feat-cmux-next (cmd/worker/step_reviewed.go), after the step got an id.
REFUSAL_MARKS = ("not on the ci-step allowlist", "not on the measurement list", "runs as class")
WORKER_REFUSAL_MARK = "ci-step refused:"
HQ_ASK = (f"{SCRIPT} is not on the controller's list yet: hq adds it to measureScripts in "
          "build-fleet/cmd/controller/ci_step.go (or the commit lands on main or feat-cmux-next); "
          "asked with `cmux-ci feedback --category policy` (p15-oracle-050)")
EXIT_OK, EXIT_UNEXPECTED, EXIT_USAGE, EXIT_INCOMPLETE = 0, 1, 2, 3

# The oracle.py run options a step forwards. Values travel as `--name=value` step args; a value the controller's
# arg pattern refuses (a glob's `*`) travels as `--name-hex=<hex>` and the step decodes it.
VALUE_OPTIONS = ("suite", "filter", "repeat", "retry-limit", "seed", "batch-limit", "switch", "arm", "engine",
                 "run-id", "facets")
FLAG_OPTIONS = ("shuffle",)


class UsageError(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------
# Step arguments


def encode_arg(name: str, value: str) -> str:
    """One `--name=value` step arg, or `--name-hex=<hex>` when the controller's arg pattern refuses the value."""
    plain = f"--{name}={value}"
    if ARG_PATTERN.match(plain) and ".." not in plain.split("/"):
        return plain
    return f"--{name}-hex={value.encode('utf-8').hex()}"


def decode_args(args: Sequence[str]) -> List[str]:
    """The step side of encode_arg: `--name-hex=<hex>` back to `--name=value`; other args unchanged."""
    out = []
    for arg in args:
        m = re.match(r"^--([a-z][a-z-]*)-hex=([0-9a-f]*)$", arg)
        if m:
            try:
                out.append(f"--{m.group(1)}={bytes.fromhex(m.group(2)).decode('utf-8')}")
            except ValueError:
                raise UsageError(f"{arg}: not hex of UTF-8 text") from None
        else:
            out.append(arg)
    return out


@dataclass(frozen=True)
class Selection:
    """The oracle.py run options of every shard of one side (one config: the shard receipts must merge)."""

    suites: Tuple[str, ...] = ()
    filters: Tuple[str, ...] = ()
    repeat: Optional[int] = None
    retry_limit: Optional[int] = None
    seed: Optional[int] = None
    batch_limit: Optional[int] = None
    config: str = "bench"
    dry_run: bool = False
    corpus: Optional[str] = None

    def step_args(self, extra: Sequence[Tuple[str, str]] = ()) -> List[str]:
        args = []
        if self.suites:
            args.append(encode_arg("suite", ",".join(self.suites)))
        if self.filters:
            args.append(encode_arg("filter", ",".join(self.filters)))
        for name, value in (("repeat", self.repeat), ("retry-limit", self.retry_limit), ("seed", self.seed),
                            ("batch-limit", self.batch_limit)):
            if value is not None:
                args.append(encode_arg(name, str(value)))
        for name, value in extra:
            args.append(encode_arg(name, value))
        if self.corpus:
            args.append(encode_arg("corpus", self.corpus))
        args.append(f"--config={self.config}")
        if self.dry_run:
            args.append("--dry-run")
        return args


def add_selection_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--suite", action="append", help="suite names, comma separated (default all)")
    parser.add_argument("--filter", action="append", help="case id globs, comma separated (a filtered run)")
    parser.add_argument("--repeat", type=int)
    parser.add_argument("--retry-limit", type=int)
    parser.add_argument("--shuffle", action="store_true", help="one seed for every shard and side (printed)")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--batch-limit", type=int)
    parser.add_argument("--config", "--build", dest="config", choices=CONFIGS, default="bench",
                        help="the app's build configuration, and oracle.py's --build (default bench)")
    parser.add_argument("--dry-run", action="store_true", help="plan only: the steps build and launch nothing")
    parser.add_argument("--corpus", help="the corpus dir on the worker, relative to the step's checkout "
                                         "(default tests/oracle/corpus)")


def selection_from(args: argparse.Namespace, *, retry_default: Optional[int]) -> Selection:
    for name in ("repeat", "batch_limit"):
        value = getattr(args, name)
        if value is not None and value < 1:
            raise UsageError(f"--{name.replace('_', '-')} must be >= 1")
    if args.retry_limit is not None and args.retry_limit < 0:
        raise UsageError("--retry-limit must be >= 0")
    seed = args.seed
    if args.shuffle and seed is None:
        seed = oracle.new_seed()  # one order for every shard of both sides
        print(f"fleet: shuffle seed {seed}")
    retry = args.retry_limit if args.retry_limit is not None else retry_default
    return Selection(
        suites=tuple(oracle.parse_list(args.suite)), filters=tuple(oracle.parse_list(args.filter)),
        repeat=args.repeat, retry_limit=retry, seed=seed, batch_limit=args.batch_limit,
        config=args.config, dry_run=args.dry_run, corpus=args.corpus,
    )


# ---------------------------------------------------------------------------------------------------------------
# The fleet client


def find_client(explicit: Optional[str]) -> str:
    """The cmux-ci client: --client, CMUX_CI_CLIENT, `cmux-ci` on PATH or ~/.local/bin/cmux-ci. Never maclease."""
    candidate = explicit or os.environ.get("CMUX_CI_CLIENT") or shutil.which("cmux-ci") \
        or str(Path.home() / ".local" / "bin" / "cmux-ci")
    if "maclease" in Path(candidate).name.lower():
        raise UsageError(f"{candidate}: the oracle runs through cmux-ci only, never maclease (p15 rule 11)")
    if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
        raise UsageError(f"{candidate}: no cmux-ci client (install: python3 build-fleet/install-client.py "
                         "--prefix ~/.local from an hq checkout)")
    return candidate


MUTANT_DIR = "tests/oracle/mutants/app"


def mutant_extra(path: Optional[str], sha: str) -> Tuple[Tuple[str, str], ...]:
    """The step arg of an app mutant (p15-oracle-026): oracle.sh applies `tests/oracle/mutants/app/<name>.patch` of
    the step's own checkout before the build, so the patch must be in this checkout and in the commit's tree."""
    if path is None:
        return ()
    rel = Path(path)
    if rel.is_absolute() and rel.resolve().is_relative_to(REPO):
        rel = rel.resolve().relative_to(REPO)
    text = rel.as_posix()
    if not re.fullmatch(rf"{MUTANT_DIR}/[a-z0-9][a-z0-9-]*\.patch", text):
        raise UsageError(f"{path}: an app mutant is {MUTANT_DIR}/<name>.patch in this checkout")
    mutant, errors = patch_mutants.parse(REPO / rel, "app")
    if mutant is None or errors:
        raise UsageError(f"{path}: " + "; ".join(errors or ["unreadable"]))

    def blob(*argv: str) -> Optional[str]:
        proc = subprocess.run(["git", "-C", str(REPO), *argv], check=False, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True)
        return proc.stdout.strip() if proc.returncode == 0 else None

    committed = blob("rev-parse", "--verify", "--quiet", f"{sha}:{text}")
    if committed is None:
        raise UsageError(f"{text} is not in {sha[:12]}'s tree (or that commit is not here): the step applies "
                         "the patch of its own checkout")
    if committed != blob("hash-object", str(REPO / rel)):
        raise UsageError(f"{text} here differs from {sha[:12]}'s copy, which is the one the step applies")
    return (("mutant", text),)


def resolve_sha(ref: str) -> str:
    if SHA_PATTERN.match(ref):
        return ref
    proc = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          check=False, stdout=subprocess.PIPE, text=True)
    if proc.returncode != 0 or not SHA_PATTERN.match(proc.stdout.strip()):
        raise UsageError(f"{ref}: not a commit here; the fleet needs the full SHA of a pushed commit")
    return proc.stdout.strip()


@dataclass
class Shard:
    """One step: a side's shard i of N. Its state lives in `dir` (step.json, job.json, run/)."""

    side: str
    index: int
    total: int
    sha: str
    key: str
    args: List[str]
    dir: Path
    target_worker: Optional[str] = None
    step_id: Optional[str] = None
    state: str = "new"
    exit_code: Optional[int] = None
    worker: Optional[str] = None
    error: Optional[str] = None
    run_dir: Optional[Path] = None
    waits: int = 0
    # The step's fleet-step.json: what it built (sha, gitlinks, the submodule commits it compiled), on which host.
    build: Optional[Dict[str, Any]] = None

    @property
    def artifact(self) -> str:
        return f"{ARTIFACT_DIR}/{self.key}.tar.gz"

    def record(self) -> Dict[str, Any]:
        return {"schema": STEP_SCHEMA, "side": self.side, "index": self.index, "total": self.total, "sha": self.sha,
                "key": self.key, "args": self.args, "step_id": self.step_id, "state": self.state,
                "exit": self.exit_code, "worker": self.worker, "target_worker": self.target_worker,
                "error": self.error, "waits": self.waits, "run": str(self.run_dir) if self.run_dir else None,
                "build": self.build}

    def save(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = self.dir / "step.json.tmp"
        tmp.write_text(json.dumps(self.record(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.dir / "step.json")

    def load_previous(self) -> None:
        """Re-attach to the step an earlier fleet.py of the same request submitted (same key and args)."""
        try:
            old = json.loads((self.dir / "step.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if old.get("key") == self.key and old.get("args") == self.args and old.get("sha") == self.sha:
            self.step_id = old.get("step_id")
            self.worker = old.get("worker")


class Fleet:
    """Submits, waits for and collects steps through one cmux-ci client (an injected path: tests pass a fake)."""

    def __init__(self, client: str, *, step_timeout: int, wait_timeout: int, log=print):
        self.client = client
        self.step_timeout = step_timeout
        self.wait_timeout = wait_timeout
        self.log = log

    def run_argv(self, shard: Shard) -> List[str]:
        argv = [self.client, "run", "--class", STEP_CLASS, "--label", STEP_LABEL, "--no-supersede",
                "--script", SCRIPT, "--ref", shard.sha, "--key", shard.key, "--artifact", shard.artifact,
                "--timeout", str(self.step_timeout)]
        if shard.target_worker:
            argv += ["--target-worker", shard.target_worker]
        return argv + [f"--arg={a}" for a in shard.args]

    def submit(self, shard: Shard) -> int:
        """`cmux-ci run`; keeps the step id in step.json as soon as the client prints it. Returns the client's exit."""
        shard.dir.mkdir(parents=True, exist_ok=True)
        argv = self.run_argv(shard)
        self.log(f"fleet: {shard.side} shard {shard.index}/{shard.total}: {' '.join(argv[1:])}")
        with (shard.dir / "step.log").open("ab") as log, subprocess.Popen(
                argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=str(REPO)) as proc:
            assert proc.stdout is not None
            for line in proc.stdout:
                log.write(line)
                log.flush()
                if shard.step_id is None:
                    m = STEP_LINE.search(line.decode("utf-8", "replace"))
                    if m:
                        shard.step_id = m.group(1)
                        shard.state = "submitted"
                        shard.save()
            return proc.wait()

    def wait(self, shard: Shard) -> Optional[Dict[str, Any]]:
        """The step's job record once it is terminal. A wait that times out is followed by another wait."""
        receipt = shard.dir / "job.json"
        while True:
            receipt.unlink(missing_ok=True)
            shard.waits += 1
            with (shard.dir / "step.log").open("ab") as log:
                code = subprocess.run([self.client, "wait", shard.step_id, "--timeout", str(self.wait_timeout),
                                       "--receipt", str(receipt)], stdout=log, stderr=subprocess.STDOUT,
                                      check=False, cwd=str(REPO)).returncode
            if code == WAIT_TIMED_OUT and not receipt.is_file():
                self.log(f"fleet: step {shard.step_id} ({shard.side} {shard.index}/{shard.total}) still runs after "
                         f"{self.wait_timeout} s; waiting again (never a resubmit)")
                continue
            try:
                return json.loads(receipt.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                shard.error = f"`cmux-ci wait {shard.step_id}` exited {code} without a job record; see step.log"
                return None

    def fetch(self, shard: Shard, *, failed: bool) -> Optional[Path]:
        tarball = shard.dir / "shard.tar.gz"
        argv = [self.client, "artifact", shard.step_id, str(tarball)] + (["--failed"] if failed else [])
        with (shard.dir / "step.log").open("ab") as log:
            code = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, check=False, cwd=str(REPO)).returncode
        if code != 0 or not tarball.is_file():
            return None
        unpack(tarball, shard.dir / "unpacked")
        try:
            shard.build = json.loads((shard.dir / "unpacked" / "fleet-step.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            shard.build = None
        run = shard.dir / "unpacked" / "run"
        return run if (run / "receipt.json").is_file() else None

    def complete(self, shard: Shard) -> Shard:
        """Submit (unless an earlier fleet.py did), wait, fetch and unpack one shard."""
        shard.load_previous()
        if shard.step_id is None:
            code = self.submit(shard)
            if shard.step_id is None:
                text = (shard.dir / "step.log").read_text(encoding="utf-8", errors="replace")
                refused = any(mark in text for mark in REFUSAL_MARKS)
                shard.state = "refused" if refused else "not-submitted"
                tail = " | ".join(text.strip().splitlines()[-3:])
                shard.error = (HQ_ASK + f"; the controller said: {tail}") if refused else \
                    f"`cmux-ci run` exited {code} before the controller gave a step id: {tail}"
                shard.save()
                return shard
            if code == CLIENT_GONE:
                self.log(f"fleet: the client of step {shard.step_id} ended first; waiting on the same step")
        job = self.wait(shard)
        if job is None:
            shard.state = "lost"
            shard.save()
            return shard
        shard.state = str(job.get("state"))
        shard.worker = job.get("worker") or None
        shard.exit_code = job.get("exit_code") if isinstance(job.get("exit_code"), int) else None
        if shard.state == "cancelled" and job.get("superseded_by"):
            shard.error = f"superseded by {job['superseded_by']} (fleet.py passes --no-supersede: report this)"
        elif shard.state in ("done", "failed"):
            shard.run_dir = self.fetch(shard, failed=shard.state == "failed")
            if shard.run_dir is None:
                text = (shard.dir / "step.log").read_text(encoding="utf-8", errors="replace")
                if WORKER_REFUSAL_MARK in text:
                    shard.state, shard.error = "refused", HQ_ASK + "; the worker said: " + next(
                        line for line in text.splitlines() if WORKER_REFUSAL_MARK in line).strip()[:500]
                else:
                    shard.state = "failed"
                    shard.error = f"step {shard.step_id} {shard.state} with no shard receipt in its artifact; see step.log"
            else:
                problem = build_problem(shard)
                if problem:
                    shard.state, shard.error, shard.run_dir = "wrong-build", problem, None
        else:
            shard.error = f"step {shard.step_id} {shard.state}: {job.get('error') or 'no reason given'}"
        shard.save()
        return shard


def build_problem(shard: Shard) -> Optional[str]:
    """Why the shard's app is not a build of its commit: another SHA checked out, or a submodule the build compiled
    at another commit than the tree's gitlink (a reused checkout keeps the last step's submodules). A step of a
    commit older than task 112 records no submodules; its gitlinks then come from this checkout's tree alone."""
    step = shard.build
    if step is None:
        return f"step {shard.step_id} packed no fleet-step.json: what it built is unknown"
    if step.get("sha") != shard.sha:
        return f"step {shard.step_id} built {step.get('sha')}, not {shard.sha}"
    links = step.get("gitlinks") or {}
    for path, built in sorted((step.get("submodules") or {}).items()):
        if built is not None and built != links.get(path):
            return f"step {shard.step_id} built {path} at {built}; {shard.sha[:12]}'s gitlink is {links.get(path)}"
    return None


def unpack(tarball: Path, dest: Path) -> None:
    """Extracts a step artifact: regular files and directories under dest only (no links, no absolute or .. names)."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    root = dest.resolve()
    with tarfile.open(tarball, "r:gz") as archive:
        for member in archive.getmembers():
            name = member.name
            target = (dest / name).resolve()
            if name.startswith("/") or ".." in Path(name).parts or (target != root and root not in target.parents):
                raise UsageError(f"{tarball}: member {name!r} leaves the artifact directory")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                assert source is not None
                with source, target.open("wb") as handle:
                    shutil.copyfileobj(source, handle)
            else:
                raise UsageError(f"{tarball}: member {name!r} is not a regular file or directory")


# ---------------------------------------------------------------------------------------------------------------
# Sides, merge and fleet.json


@dataclass
class Side:
    label: str
    sha: str
    extra: Tuple[Tuple[str, str], ...] = ()
    ref: Optional[str] = None
    shards: List[Shard] = field(default_factory=list)
    merged: Optional[Path] = None
    ok: Optional[bool] = None
    errors: List[str] = field(default_factory=list)
    # Every gitlink of the commit's tree, and where it was read: "tree" (this checkout) or "step" (the steps'
    # checkouts, when the commit is not here).
    gitlinks: Optional[Dict[str, str]] = None
    gitlinks_from: Optional[str] = None

    def resolve_gitlinks(self) -> None:
        """The side's gitlinks from this checkout's tree, else from the steps, which must agree with it."""
        recorded = {json.dumps(s.build["gitlinks"], sort_keys=True) for s in self.shards
                    if s.build and isinstance(s.build.get("gitlinks"), dict)}
        local = oracle.tree_gitlinks(self.sha, REPO)
        if local is not None:
            self.gitlinks, self.gitlinks_from = local, "tree"
            if recorded - {json.dumps(local, sort_keys=True)}:
                self.errors.append(f"a step recorded other gitlinks for {self.sha} than its tree has here")
        elif len(recorded) == 1:
            self.gitlinks, self.gitlinks_from = json.loads(recorded.pop()), "step"
        elif recorded:
            self.errors.append(f"the steps of {self.sha} recorded different gitlinks")

    def build_record(self, selection: Selection) -> Dict[str, Any]:
        """The side's entry in builds.json (`oracle.py diff --builds`): exact SHA, gitlinks, config, hosts."""
        return {"label": self.label, "ref": self.ref, "sha": self.sha, "gitlinks": self.gitlinks,
                "gitlinksFrom": self.gitlinks_from, "config": selection.config, "args": dict(self.extra),
                "steps": [{"shard": s.index, "step_id": s.step_id, "worker": s.worker,
                           "host": (s.build or {}).get("host"), "submodules": (s.build or {}).get("submodules"),
                           "source_diff_sha256": (s.build or {}).get("source_diff_sha256"),
                           "build_seconds": (s.build or {}).get("build_seconds")} for s in self.shards]}


def make_shards(side: Side, *, run_id: str, total: int, selection: Selection, out: Path) -> None:
    for i in range(total):
        key = f"oracle-{run_id}-{side.label}-s{i}of{total}"
        if not KEY_PATTERN.match(key):
            raise UsageError(f"step key {key!r} does not fit the controller's pattern (shorten --run-id)")
        args = [f"--shard={i}/{total}", f"--artifact={ARTIFACT_DIR}/{key}.tar.gz",
                encode_arg("run-id", f"{run_id}-{side.label}-s{i}"), *selection.step_args(side.extra)]
        if len(args) > MAX_STEP_ARGS or any(len(a) > MAX_ARG_LEN or not ARG_PATTERN.match(a) for a in args):
            raise UsageError(f"step args do not fit the controller (<= {MAX_STEP_ARGS}, its pattern): {args}")
        side.shards.append(Shard(side.label, i, total, side.sha, key, args, out / "shards" / side.label / str(i)))


def merge_side(side: Side, out: Path) -> None:
    """One run dir for the side: oracle.py's merge (refuses a gap, an overlap or two configs)."""
    missing = [s for s in side.shards if s.run_dir is None]
    for s in missing:
        side.errors.append(f"shard {s.index}/{s.total}: {s.state}: {s.error or 'no receipt'}")
    if missing:
        return
    dirs = [s.run_dir for s in side.shards if s.run_dir is not None]
    view, errors = oracle.merge_runs(dirs, require_complete=True)
    if errors:
        side.errors.extend(errors)
        return
    side.merged = oracle.write_merged(view, out / side.label)
    side.ok = bool(view.receipt.get("ok"))


def fleet_record(run_id: str, sides: Sequence[Side], *, comparison: Optional[Dict[str, Any]] = None,
                 plan: Optional[Dict[str, Any]] = None,
                 mismatched: Optional[Dict[str, List[str]]] = None) -> Dict[str, Any]:
    record: Dict[str, Any] = {"schema": FLEET_SCHEMA, "runId": run_id, "script": SCRIPT, "class": STEP_CLASS,
                              "sides": {}}
    if plan is not None:
        record["overlay"] = overlay.summary(plan)
    for side in sides:
        record["sides"][side.label] = {
            "ref": side.ref,
            "sha": side.sha,
            "gitlinks": side.gitlinks,
            "gitlinksFrom": side.gitlinks_from,
            "args": dict(side.extra),
            "shards": [s.record() for s in side.shards],
            "merged": str(side.merged / "receipt.json") if side.merged else None,
            "ok": side.ok,
            "errors": side.errors,
            "workers": sorted({s.worker for s in side.shards if s.worker}),
        }
    if comparison is not None:
        record["comparison"] = comparison
    if mismatched:
        record["verdict"], record["mismatched"] = "host-mismatch", mismatched
    record["ok"] = all(s.ok for s in sides) and (comparison is None or comparison.get("exit") == 0) and not mismatched
    return record


def write_fleet(out: Path, record: Dict[str, Any]) -> Path:
    path = out / "fleet.json"
    path.write_text(json.dumps(record, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return path


def print_side(side: Side) -> None:
    done = sum(1 for s in side.shards if s.run_dir is not None)
    workers = ", ".join(sorted({s.worker for s in side.shards if s.worker})) or "none"
    print(f"fleet: {side.label} {side.sha[:12]}: {done}/{len(side.shards)} shards with a receipt (workers: {workers})")
    for error in side.errors[:20]:
        print(f"  {error}")
    if side.merged:
        print(f"  merged receipt: {side.merged / 'receipt.json'} (ok: {side.ok})")


def prepare_out(args: argparse.Namespace, run_id: str) -> Path:
    out = (args.out or DEFAULT_OUT_BASE / run_id).resolve()
    oracle.check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    return out


def run_id_for(args: argparse.Namespace, out: Optional[Path]) -> str:
    """--run-id, the run id an earlier fleet.py wrote to --out (re-attach), or a new one."""
    if args.run_id:
        return args.run_id
    if out is not None:
        try:
            return json.loads((out / "fleet.json").read_text(encoding="utf-8"))["runId"]
        except (OSError, ValueError, KeyError):
            pass
    return oracle.new_run_id()


def fleet_from(args: argparse.Namespace) -> Fleet:
    return Fleet(find_client(args.client), step_timeout=args.step_timeout, wait_timeout=args.wait_timeout)


def cmd_run(args: argparse.Namespace) -> int:
    if not 1 <= args.shards <= MAX_SHARDS:
        raise UsageError(f"--shards must be 1..{MAX_SHARDS}")
    fleet = fleet_from(args)
    selection = selection_from(args, retry_default=None)
    run_id = run_id_for(args, args.out)
    out = prepare_out(args, run_id)
    sha = resolve_sha(args.ref)
    side = Side("run", sha, mutant_extra(args.mutant, sha), ref=args.ref)
    make_shards(side, run_id=run_id, total=args.shards, selection=selection, out=out)
    write_fleet(out, fleet_record(run_id, [side]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.shards) as pool:
        list(pool.map(fleet.complete, side.shards))
    side.resolve_gitlinks()
    merge_side(side, out)
    path = write_fleet(out, fleet_record(run_id, [side]))
    print_side(side)
    print(f"fleet: {path}")
    if side.merged is None:
        return EXIT_INCOMPLETE
    return EXIT_OK if side.ok else EXIT_UNEXPECTED


def diff_sides(args: argparse.Namespace) -> List[Side]:
    if args.base or args.head:
        if not args.base:
            raise UsageError("--head needs --base (the default diff is --base REF, head HEAD)")
        if args.switch or args.arm or args.engine:
            raise UsageError("--base/--head, --switch, --arm launch-config and --engine are separate diffs")
        head_ref = args.head or "HEAD"
        head = resolve_sha(head_ref)
        return [Side("base", resolve_sha(args.base), ref=args.base),
                Side("head", head, mutant_extra(args.head_mutant, head), ref=head_ref)]
    if args.head_mutant:
        raise UsageError("--head-mutant goes with --base/--head (`--base SHA --head SHA` is one mutant's catch check)")
    if not args.ref:
        raise UsageError("--switch, --arm launch-config and --engine run one build: pass --ref SHA")
    sha = resolve_sha(args.ref)
    if args.engine:
        if args.switch or args.arm:
            raise UsageError("--engine runs one arm per engine at the default switches; --switch and --arm are "
                             "separate diffs")
        return [Side(engine, sha, (("engine", engine),), ref=args.ref) for engine in oracle.parse_engines(args.engine)]
    if args.switch:
        if args.arm:
            raise UsageError("--switch runs arm old against arm new; --arm is for launch-config")
        return [Side(arm, sha, (("switch", args.switch), ("arm", arm)), ref=args.ref) for arm in oracle.ARMS]
    if args.arm == "launch-config":
        return [Side("default", sha, (("arm", "default"),), ref=args.ref),
                Side("launch-config", sha, (("arm", "launch-config"),), ref=args.ref)]
    raise UsageError("diff needs --base/--head, --switch NAME, --arm launch-config or --engine webkit,chromium")


def complete_pair(fleet: Fleet, first: Shard, second: Shard) -> None:
    """Same-host pairing per shard: the second side's step targets the worker the first side's step ran on."""
    fleet.complete(first)
    if first.worker is None:
        second.state, second.error = "not-submitted", f"its pair ({first.side} shard {first.index}) ran on no worker"
        second.save()
        return
    second.target_worker = first.worker
    fleet.complete(second)
    if second.worker and second.worker != first.worker:
        second.error = f"ran on {second.worker}, its pair on {first.worker}: the controller ignored --target-worker"
        second.run_dir = None
        second.save()


def receipt_host(shard: Shard) -> Optional[Dict[str, Any]]:
    """The host a shard's receipt records (oracle.py host_info), or None when it has none."""
    if shard.run_dir is None:
        return None
    try:
        host = json.loads((shard.run_dir / "receipt.json").read_text(encoding="utf-8")).get("host")
    except (OSError, ValueError, AttributeError):
        return None
    return host if isinstance(host, dict) else None


def pairing_problems(first: Side, second: Side) -> Dict[str, List[str]]:
    """Each shard whose two receipts do not name one host, OS version and display (diff.py's same-host keys)."""
    problems: Dict[str, List[str]] = {}
    for a, b in zip(first.shards, second.shards):
        if a.run_dir is None or b.run_dir is None:
            continue  # merge_side reports a shard without a receipt
        fields = diff.host_mismatch(receipt_host(a), receipt_host(b))
        if fields:
            problems[f"shard {a.index}"] = fields
    return problems


def cmd_diff(args: argparse.Namespace) -> int:
    if args.product != "app":
        raise UsageError(f"--product {args.product}: fleet.py runs the app product; cmux-tui products diff on the VM")
    if not 1 <= args.shards <= MAX_SHARDS:
        raise UsageError(f"--shards must be 1..{MAX_SHARDS}")
    fleet = fleet_from(args)
    # A diff retries like `oracle.py diff`: DEFAULT_RETRY_LIMIT whole-shard and alone retries.
    selection = selection_from(args, retry_default=oracle.DEFAULT_RETRY_LIMIT)
    sides = diff_sides(args)
    if args.v0 and not args.base:
        raise UsageError("--v0 goes with --base/--head")
    run_id = run_id_for(args, args.out)
    out = prepare_out(args, run_id)
    plan = base_plan(args, sides, out) if args.base else None
    for side in sides:
        make_shards(side, run_id=run_id, total=args.shards, selection=selection, out=out)
    write_fleet(out, fleet_record(run_id, sides, plan=plan))
    first, second = sides
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.shards) as pool:
        list(pool.map(lambda pair: complete_pair(fleet, *pair), zip(first.shards, second.shards)))
    mismatched = pairing_problems(first, second)
    if mismatched:
        path = write_fleet(out, fleet_record(run_id, sides, plan=plan, mismatched=mismatched))
        print("fleet: host-mismatch: a shard's two sides ran on different hosts, OS versions or displays; "
              "nothing compared")
        for where, fields in sorted(mismatched.items(), key=lambda item: int(item[0].split()[1])):
            print(f"  {where}: {', '.join(fields)}")
        print(f"fleet: {path}")
        return EXIT_INCOMPLETE
    for side in sides:
        side.resolve_gitlinks()
        if side.gitlinks is None and not side.errors:
            side.errors.append(f"{side.sha} is not in this checkout and no step recorded its gitlinks "
                               "(fetch the commit and run again: the same steps are reused)")
        merge_side(side, out)
        print_side(side)
    if not all(side.merged and not side.errors for side in sides):
        path = write_fleet(out, fleet_record(run_id, sides, plan=plan))
        print(f"fleet: incomplete, nothing compared: {path}")
        if plan is not None and plan["mode"] == "overlay" and first.merged is None:
            print(f"fleet: the overlay commit {plan['overlaySha']} gave no base receipt; if it does not build, "
                  "`fleet.py diff ... --v0 'the overlay does not build'` runs both sides on v0 facets")
        return EXIT_INCOMPLETE
    # The comparison's receipt names each side's exact SHA and gitlinks (task 112); oracle.py's --base-run side is
    # the first side, whatever its label.
    builds = out / "builds.json"
    builds.write_text(json.dumps({"base": first.build_record(selection), "head": second.build_record(selection)},
                                 indent=1, sort_keys=True) + "\n", encoding="utf-8")
    argv = ["diff", "--product", "app", "--out", str(out / "compare"), "--builds", str(builds)]
    # A switch's arm runs get oracle.py's switch verdict: readback, hits and the arm pointers.
    argv += ["--switch", args.switch] if args.switch else []
    for side, flag in ((first, "--base-run"), (second, "--head-run")):
        for s in side.shards:
            argv += [flag, str(s.run_dir)]
    argv += ["--overlay", str(out / "overlay.json")] if plan is not None else []
    argv += ["--json"] if args.json else []
    code = oracle.main(argv)
    path = write_fleet(out, fleet_record(run_id, sides, plan=plan, comparison={
        "exit": code, "dir": str(out / "compare"), "labels": [first.label, second.label]}))
    print(f"fleet: {path}")
    return code


def base_plan(args: argparse.Namespace, sides: Sequence[Side], out: Path) -> Dict[str, Any]:
    """The base side's build (overlay.py, p15-oracle-202): head's oracle commits and runner on the base, pushed so
    the controller can build it, or the base with head's runner and v0 facets on both sides. Writes out/overlay.json."""
    base, head = sides
    try:
        plan = overlay.prepare(REPO, base.sha, head.sha, product="app", force_v0=args.v0)
        plan = overlay.push(REPO, args.remote, plan)
    except overlay.OverlayError as error:
        raise UsageError(str(error)) from None
    (out / "overlay.json").write_text(json.dumps(plan, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    base.sha = plan["buildSha"]
    if plan["facets"] == "v0":
        for side in sides:
            side.extra = (*side.extra, ("facets", "v0"))
    print(f"fleet: base {plan['base'][:12]} builds {plan['buildSha'][:12]} ({plan['mode']}, {plan['facets']} facets"
          f"{'; ' + plan['reason'] if plan.get('reason') else ''})")
    return plan


# ---------------------------------------------------------------------------------------------------------------
# The worker side (inside the step)


def step_artifact(path: str) -> Path:
    """The artifact path: relative, under artifacts/oracle/, in the step's checkout (the current directory)."""
    p = Path(path)
    if p.is_absolute() or ".." in p.parts or p.parts[:2] != tuple(ARTIFACT_DIR.split("/")) or not path.endswith(".tar.gz"):
        raise UsageError(f"--artifact {path}: a relative {ARTIFACT_DIR}/<name>.tar.gz in the step's checkout")
    return Path.cwd() / p


def host_meta() -> Dict[str, str]:
    meta = {"name": platform_mod.node(), "os": platform_mod.system(), "arch": platform_mod.machine()}
    if sys.platform == "darwin":
        meta["macos"] = platform_mod.mac_ver()[0]
    return meta


def built_submodules(gitlinks: Dict[str, str]) -> Dict[str, Optional[str]]:
    """The commit each gitlink's submodule has checked out in the step's checkout (None: not initialized)."""
    heads: Dict[str, Optional[str]] = {}
    for path in sorted(gitlinks):
        # An uninitialized submodule is an empty directory, where `git rev-parse` would answer for the superproject.
        if not (REPO / path / ".git").exists():
            heads[path] = None
            continue
        proc = subprocess.run(["git", "-C", str(REPO / path), "rev-parse", "HEAD"], check=False,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        heads[path] = proc.stdout.strip() if proc.returncode == 0 else None
    return heads


def pack(work: Path, artifact: Path) -> None:
    """The step's artifact: run/ (when oracle.py wrote one), fleet-step.json and oracle.log, as a tar.gz."""
    artifact.parent.mkdir(parents=True, exist_ok=True)
    tmp = artifact.with_name(artifact.name + ".tmp")
    with tarfile.open(tmp, "w:gz") as archive:
        for name in ("fleet-step.json", "oracle.log", "run"):
            path = work / name
            if path.exists():
                archive.add(str(path), arcname=name, filter=lambda info: info if info.isfile() or info.isdir() else None)
    tmp.replace(artifact)


def cmd_step(args: argparse.Namespace, rest: List[str]) -> int:
    if not SHA_PATTERN.match(args.ref):
        raise UsageError(f"--ref {args.ref}: the step's full SHA")
    if not TAG_PATTERN.match(args.tag):
        raise UsageError(f"--tag {args.tag}: lowercase letters, digits and -")
    index, total = oracle.parse_shard(args.shard)
    artifact = step_artifact(args.artifact)
    if not args.dry_run and not args.app:
        raise UsageError("--app is the tagged app oracle.sh built (only --dry-run runs without one)")
    work = Path(args.work).resolve()
    oracle.check_out_dir(work)
    work.mkdir(parents=True, exist_ok=True)
    forwarded = decode_args(rest)
    for arg in forwarded:
        name = arg[2:].split("=", 1)[0] if arg.startswith("--") else ""
        if name not in VALUE_OPTIONS + FLAG_OPTIONS + ("corpus", "expectations-root"):
            raise UsageError(f"{arg}: not an option a fleet step forwards to oracle.py run")
    argv = [sys.executable, "-I", str(HERE / "oracle.py"), "run", "--product", "app", "--build", args.config,
            "--tag", args.tag, "--shard", f"{index}/{total}", "--ref", args.ref, "--out", str(work / "run")]
    argv += ["--binary", args.app] if args.app else []
    argv += ["--dry-run"] if args.dry_run and "--dry-run" not in forwarded else []
    argv += forwarded
    started = time.monotonic()
    with (work / "oracle.log").open("wb") as log:
        code = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, check=False, cwd=str(REPO)).returncode
    seconds = round(time.monotonic() - started, 1)
    receipt = work / "run" / "receipt.json"
    gitlinks = oracle.tree_gitlinks(args.ref, REPO)
    record = {"schema": STEP_SCHEMA, "sha": args.ref, "shard": [index, total], "tag": args.tag,
              "gitlinks": gitlinks, "submodules": built_submodules(gitlinks) if gitlinks is not None else None,
              "config": args.config, "mutant": args.mutant, "source_diff_sha256": args.source_diff,
              "host": host_meta(), "oracle_exit": code,
              "oracle_seconds": seconds,
              "build_seconds": args.build_seconds, "argv": argv[2:], "receipt": receipt.is_file(),
              "step_key": os.environ.get("CMUX_CI_STEP_KEY")}
    (work / "fleet-step.json").write_text(json.dumps(record, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    pack(work, artifact)
    sys.stdout.write((work / "oracle.log").read_text(encoding="utf-8", errors="replace")[-20000:])
    print(f"fleet step: shard {index}/{total} oracle.py exit {code} in {seconds} s; receipt "
          f"{'written' if receipt.is_file() else 'missing'}; artifact {args.artifact}")
    return 0 if receipt.is_file() else 1


# ---------------------------------------------------------------------------------------------------------------
# CLI


def add_client_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--shards", type=int, default=1, help=f"steps per side, 1..{MAX_SHARDS} (default 1)")
    parser.add_argument("--out", type=Path, help=f"output dir outside the checkout (default {DEFAULT_OUT_BASE}/<run>); "
                                                 "an existing one re-attaches to its steps")
    parser.add_argument("--run-id", help="the run id in the step keys (default: new, or the one in --out)")
    parser.add_argument("--client", help="the cmux-ci client (default: cmux-ci on PATH)")
    parser.add_argument("--step-timeout", type=int, default=DEFAULT_STEP_TIMEOUT_S,
                        help="seconds a step may run from its claim (cmux-ci run --timeout)")
    parser.add_argument("--wait-timeout", type=int, default=DEFAULT_WAIT_TIMEOUT_S,
                        help="seconds per `cmux-ci wait`; a timeout leads to another wait")
    parser.add_argument("--json", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fleet.py", description=__doc__.split("\n\n")[0], allow_abbrev=False)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", allow_abbrev=False, help="one app run of a commit on the fleet, sharded, merged into one receipt")
    run.add_argument("--ref", required=True, help="the pushed commit (full SHA, or a ref this checkout resolves)")
    run.add_argument("--mutant", help="build with tests/oracle/mutants/app/<name>.patch applied (p15-oracle-026)")
    add_selection_args(run)
    add_client_args(run)
    run.set_defaults(func=cmd_run)

    diff_cmd = sub.add_parser("diff", allow_abbrev=False, help="two sides per shard on one worker, then oracle.py diff")
    diff_cmd.add_argument("--product", default="app")
    diff_cmd.add_argument("--base")
    diff_cmd.add_argument("--head")
    diff_cmd.add_argument("--switch")
    diff_cmd.add_argument("--arm", choices=["launch-config"])
    diff_cmd.add_argument("--engine", help="webkit,chromium: one arm per engine (oracle.py run --engine), engine parity")
    diff_cmd.add_argument("--ref")
    diff_cmd.add_argument("--head-mutant", help="build the head with tests/oracle/mutants/app/<name>.patch applied")
    diff_cmd.add_argument("--v0", metavar="REASON",
                          help="with --base/--head: no overlay; both sides run v0 facets (for example: the overlay "
                               "does not build)")
    diff_cmd.add_argument("--remote", default="origin",
                          help="where an overlay commit is pushed (refs/heads/oracle-overlay/<sha>) for the controller")
    add_selection_args(diff_cmd)
    add_client_args(diff_cmd)
    diff_cmd.set_defaults(func=cmd_diff)

    step = sub.add_parser("step", allow_abbrev=False, help="inside a fleet step (scripts/measure/oracle.sh): run the shard and pack it")
    step.add_argument("--ref", required=True)
    step.add_argument("--tag", required=True)
    step.add_argument("--config", choices=CONFIGS, default="bench")
    step.add_argument("--shard", required=True)
    step.add_argument("--artifact", required=True)
    step.add_argument("--work", required=True, help="a scratch dir outside the checkout")
    step.add_argument("--app", help='the tagged "cmux DEV <tag>.app"')
    step.add_argument("--build-seconds", type=int)
    step.add_argument("--dry-run", action="store_true")
    step.add_argument("--mutant", help="the app mutant oracle.sh applied before the build (recorded only)")
    step.add_argument("--source-diff", help="sha256 of the built sources' diff over the ref, or none (recorded only)")
    step.set_defaults(func=None)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()
    try:
        if argv and argv[0] == "step":
            args, rest = parser.parse_known_args(argv)
            return cmd_step(args, rest)
        args, unknown = parser.parse_known_args(argv)
        if unknown:
            raise UsageError("not options of a fleet app run (VM-only or unknown): " + " ".join(unknown))
        return args.func(args)
    except (UsageError, oracle.UsageError) as error:
        print(f"fleet: {error}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
