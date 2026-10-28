#!/usr/bin/env python3
"""confirm: a divergence reaches an owner only when the head fails twice and the base passes.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F.5 and rule 10, task 184. Stdlib only,
Python 3.9+, safe under `python3 -I`.

    confirm.py --diff DIR [--out DIR/confirm] [--flaky-out F] [--base-red-out F] [--no-route] [route options]

DIR is the --out of `oracle.py diff` (any mode: base/head, --switch, --arm launch-config). Its
comparison.json names the two run dirs (a: base or old arm, b: head or new arm), diff.py's --expected
files and the divergent cases. For those cases:

1. Head retry: every shard of the head that holds a divergent case runs again with the head's config
   and the shard's shuffle seed (the same order and batches). diff.py compares it with the base run.
   `fail`: the case diverges again at the same first (step, checkpoint, pointer) with the same head
   value. `pass`: it matches the base. `flaky`: the retry run itself called it flaky, or it diverges
   at another place or value (a head that changes its answer is never compared, rule 10).
2. Base alone: each case whose head retry failed runs on the base alone (batch limit 1, no retry).
   diff.py compares it with the base run. `pass`: the same answer and an expected result. `fail`:
   another answer (the base run's value depended on its order) or an unexpected result (a red base).

Classes, one line per divergent case in OUT/confirmed.jsonl (schema cmux-oracle-confirmed-v1):
    confirmed    head fail, head retry fail, base pass: routed to an owner by route.py (unless --no-route)
    flake        the head retry passed or was flaky: appended to MQ-flakes (--flaky-out)
    base-red     the head failed twice but the base alone failed: appended to the base-red queue
    unconfirmed  a rerun did not run or could not be compared (host mismatch, no receipt): no queue
Every line carries three verdicts, `head`, `head_retry` and `base`, each {"verdict", "run", "dir",
"sha", "detail"} (`run` is the run id); a verdict that was not needed is `not-run` and says why.
A line is also route.py's input (task 118): the diff.py finding (`journey`, `step`, `checkpoint`,
`pointer`, `a`, `b`, `replay`, `evidence`), `confidence` (the class; `flaky` for a flake), `product`,
and the target: `switch` and `source` (the head SHA) for a switch, `mode` launch-config and `source`
for every switch, `base` and `head` SHAs for a base/head comparison.

Reruns go through the product's own runner (the Launcher seam): the app on the fleet through
fleet.py's cmux-ci steps, pinned to the worker of the shard it repeats, with the mutant its step applied;
cmux-tui products on the Linux VM through `linux_run.sh run SHA --fresh` (the runnerd queue, never a
reused receipt) with the profile, features and mutant of the side's build.json, refused when the rebuilt
binary's sha256 is not the side's; elsewhere `oracle.py run` with the receipt's binary. A rerun the runner
refuses leaves its cases unconfirmed; base-alone cases split into as many runs as the fleet's step
argument limits need.

Exit codes: 0 no confirmed divergence, 1 confirmed divergences, 2 bad input, 3 refused or incomplete
(the comparison was refused, or a case stayed unconfirmed and none was confirmed).

Chrome reference: the CQ's test retries in chromium/tools/build
recipes/recipe_modules/chromium_tests/api.py. A failing suite runs again as "(retry shards with patch)":
the failing shards, whole, with the same config, so an order-dependent failure reproduces; the tests
that still fail run "(without patch)" on the base. Only a test that fails with the patch twice and
passes without it fails the CL; a pass on retry is reported as flaky, and a failure without the patch
is not the CL's.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Protocol, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import oracle  # noqa: E402  (shard_of, merge_runs, run_diff_py, check_out_dir, RUST_PRODUCTS)
import patch_mutants  # noqa: E402  (where the seeded mutants live)

SCHEMA = "cmux-oracle-confirmed-v1"
SUMMARY_SCHEMA = "cmux-oracle-confirm-v1"
FAIL, PASS, FLAKY, NOT_RUN, NOT_COMPARABLE = "fail", "pass", "flaky", "not-run", "not-comparable"
CONFIRMED, FLAKE, BASE_RED, UNCONFIRMED = "confirmed", "flake", "base-red", "unconfirmed"
VERDICT_KEYS = ("head", "head_retry", "base")
# route.py's input (task 118): the diff.py finding fields a line carries, and its `confidence` for each class.
FINDING_KEYS = ("step", "checkpoint", "pointer", "a", "b", "count", "evidence", "replay")
ROUTE_CONFIDENCE = {FLAKE: "flaky"}
DEFAULT_FLAKY_OUT = Path("/tmp/oracle/flaky.jsonl")
DEFAULT_BASE_RED_OUT = Path("/tmp/oracle/base-red.jsonl")
EXIT_NONE, EXIT_CONFIRMED, EXIT_USAGE, EXIT_INCOMPLETE = 0, 1, 2, 3
MAX_PARALLEL_RUNS = 16
BUILD_SCHEMA = "cmux-oracle-build-v1"  # linux_run.sh's build.json, beside the binary it built
MUTANT_ID = re.compile(r"^[a-z]+/[a-z0-9][a-z0-9-]*$")


class ConfirmError(Exception):
    """Bad input: no comparison, a refused one, unreadable receipts. Exit 2 or 3."""

    def __init__(self, message: str, code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.code = code


class LaunchError(Exception):
    """A rerun wrote no receipt; its cases stay unconfirmed."""


# ---------------------------------------------------------------------------------------
# The sides of the comparison


@dataclass(frozen=True)
class SideRun:
    """One side of the comparison as its receipt recorded it (a shard's, or a merge of shards)."""

    label: str
    dir: Path
    receipt: Dict[str, Any]

    @classmethod
    def load(cls, label: str, directory: Path) -> "SideRun":
        try:
            return cls(label, directory, oracle.read_receipt(directory))
        except oracle.UsageError as error:
            raise ConfirmError(str(error)) from None

    @property
    def config(self) -> Dict[str, Any]:
        return self.receipt["config"]

    @property
    def sha(self) -> str:
        return str(self.receipt.get("sha") or "")

    @property
    def product(self) -> str:
        return str(self.receipt["product"])

    @property
    def total(self) -> int:
        return int(self.config["shard_total"])

    def seed(self, shard: int) -> Optional[int]:
        seed = (self.receipt.get("seeds") or {}).get(str(shard))
        return seed if isinstance(seed, int) else None

    def shard_runs(self) -> Dict[int, Tuple[Path, str]]:
        """Shard index -> (its run dir, its run id); a merged receipt lists its shard runs."""
        runs = self.receipt.get("shard_runs")
        if not runs:
            return {index: (self.dir, str(self.receipt["runId"])) for index in self.receipt.get("shards") or ()}
        out: Dict[int, Tuple[Path, str]] = {}
        for run in runs:
            directory = Path(run["dir"])
            try:
                shards = oracle.read_receipt(directory).get("shards") or ()
            except oracle.UsageError:
                continue
            for index in shards:
                out[index] = (directory, str(run["runId"]))
        return out

    def arm_args(self) -> List[str]:
        """The side's arm as `oracle.py run` options."""
        switch, arm = self.config.get("switch"), self.config.get("arm")
        if switch:
            return ["--switch", switch, "--arm", arm]
        return ["--arm", arm] if arm else []

    def arm_spec(self) -> str:
        """The side's arm as `linux_run.sh run --arm` takes it."""
        switch, arm = self.config.get("switch"), self.config.get("arm")
        return f"{switch}={arm}" if switch else arm or "-"

    def mode(self) -> str:
        if self.config.get("switch"):
            return "switch"
        if self.config.get("arm") == "launch-config":
            return "launch-config"
        return "base-head"


@dataclass(frozen=True)
class RunRequest:
    """One rerun: a side's config with the shard, seed, filters and retry policy confirm asks for."""

    confirm_id: str
    label: str
    side: SideRun
    shard: Tuple[int, int]
    seed: Optional[int]
    filters: Tuple[str, ...]
    batch_limit: int
    repeat: int
    retry_limit: int
    out: Path
    # The original shard run whose host this rerun repeats on (diff.py compares only same-host runs).
    pin: Optional[Path] = None
    corpus: Optional[Path] = None
    expectations_root: Optional[Path] = None

    @property
    def run_id(self) -> str:
        return f"{self.confirm_id}-{self.label}"

    def suites(self) -> str:
        return ",".join(self.side.config.get("suites") or ()) or "all"

    def selection_args(self) -> List[str]:
        """`oracle.py run` options other than --suite, --switch, --arm, --ref, --binary and --out
        (linux_run.sh sets those itself)."""
        config = self.side.config
        args = ["--product", self.side.product, "--shard", f"{self.shard[0]}/{self.shard[1]}",
                "--batch-limit", str(self.batch_limit), "--repeat", str(self.repeat),
                "--retry-limit", str(self.retry_limit), "--platform", str(self.side.receipt["platform"]),
                "--build", str(config["build"]), "--run-id", self.run_id]
        for value in self.filters:
            args += ["--filter", value]
        if self.seed is not None:
            args += ["--seed", str(self.seed)]
        if config.get("tag"):
            args += ["--tag", str(config["tag"])]
        isolation = (self.side.receipt.get("isolation") or {}).get("mode")
        if isolation:
            args += ["--isolation", str(isolation)]
        if self.corpus is not None:
            args += ["--corpus", str(self.corpus.resolve())]
        if self.expectations_root is not None:
            args += ["--expectations-root", str(self.expectations_root.resolve())]
        return args


class Launcher(Protocol):
    def run(self, request: RunRequest) -> Path:
        """Runs the request and returns its run dir (a receipt.json in it), or raises LaunchError."""

    def fits(self, request: RunRequest) -> bool:
        """Whether the runner takes the request's arguments (confirm splits the base-alone cases until they do)."""


def last_run_dir(stdout: str, what: str, code: int) -> Path:
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    run_dir = Path(lines[-1]) if lines else None
    if run_dir is None or not (run_dir / "receipt.json").is_file():
        raise LaunchError(f"{what} wrote no receipt (exit {code})")
    return run_dir


class LocalLauncher:
    """`oracle.py run` here, with the side's recorded binary (a runnerd job, a Mac, a prebuilt binary)."""

    def command(self, request: RunRequest) -> List[str]:
        side = request.side
        command = [sys.executable, "-I", str(HERE / "oracle.py"), "run", "--suite", request.suites(),
                   *side.arm_args(), "--out", str(request.out), *request.selection_args()]
        if side.sha:
            command += ["--ref", side.sha]
        if side.config.get("binary"):
            command += ["--binary", str(side.config["binary"])]
        return command

    def fits(self, request: RunRequest) -> bool:
        return True

    def run(self, request: RunRequest) -> Path:
        code = subprocess.run(self.command(request), check=False, stdout=subprocess.DEVNULL).returncode
        if not (request.out / "receipt.json").is_file():
            raise LaunchError(f"oracle.py run for {request.label} wrote no receipt (exit {code})")
        return request.out


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_record(binary: Optional[str], what: str) -> Dict[str, Any]:
    """linux_run.sh's build receipt of BINARY: build.json beside it (profile, features, mutant, binarySha256)."""
    if not binary:
        raise LaunchError(f"{what} records no binary, so the queue cannot rebuild the same one")
    path = Path(binary).parent / "build.json"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise LaunchError(f"{what}: no build receipt at {path} ({error}), so the queue cannot rebuild the same "
                          "binary") from None
    if not isinstance(record, dict) or record.get("schema") != BUILD_SCHEMA or not record.get("binarySha256") \
            or not record.get("profile"):
        raise LaunchError(f"{path}: not a {BUILD_SCHEMA} receipt with a profile and a binarySha256")
    return record


def mutant_patch(mutant: Mapping[str, Any]) -> Path:
    """The checkout's patch of the mutant a build applied: linux_run.sh takes only that path, not the job's copy."""
    mutant_id = str(mutant.get("id") or "")
    if MUTANT_ID.match(mutant_id):
        for root in (patch_mutants.DEFAULT_ROOT, patch_mutants.TASK_ROOT):
            path = root / f"{mutant_id}.patch"
            if path.is_file() and sha256_of(path) == mutant.get("sha256"):
                return path
    raise LaunchError(f"the build applied mutant {mutant_id or '?'}, and this checkout has no patch with its content")


class QueueLauncher:
    """The Linux VM's runnerd queue: `linux_run.sh run SHA --fresh` reruns, never reusing a receipt, with the side's
    own build (the profile, features and mutant of build.json beside its binary). A rebuild into another binary is
    refused, so the rerun repeats the build it judges."""

    def build_args(self, side: SideRun) -> List[str]:
        record = build_record(side.config.get("binary"), f"the {side.label} run")
        args = ["--profile", str(record["profile"]), "--features", ",".join(record.get("features") or ())]
        if record.get("mutant"):
            args += ["--mutant", str(mutant_patch(record["mutant"]))]
        return args

    def command(self, request: RunRequest) -> List[str]:
        side = request.side
        if not side.sha:
            raise LaunchError(f"the {side.label} receipt records no SHA, so the queue cannot build it again")
        return ["bash", str(HERE / "linux_run.sh"), "run", side.sha, "--suite", request.suites(),
                "--arm", side.arm_spec(), "--side", request.run_id, *self.build_args(side), "--fresh", "--",
                *request.selection_args()]

    def fits(self, request: RunRequest) -> bool:
        return True

    def run(self, request: RunRequest) -> Path:
        side = request.side
        command = self.command(request)
        expected = build_record(side.config.get("binary"), f"the {side.label} run")["binarySha256"]
        proc = subprocess.run(command, check=False, stdout=subprocess.PIPE, text=True)
        run_dir = last_run_dir(proc.stdout, f"linux_run.sh run {side.sha[:12]} ({request.label})", proc.returncode)
        try:
            binary = oracle.read_receipt(run_dir)["config"].get("binary")
        except (oracle.UsageError, KeyError) as error:
            raise LaunchError(f"{run_dir}: {error}") from None
        got = build_record(binary, f"the rerun {request.label}")["binarySha256"]
        if got != expected:
            raise LaunchError(f"the queue rebuilt {side.sha[:12]} into another binary (sha256 {got[:12]}, the "
                              f"{side.label} run's is {expected[:12]}), so the rerun does not repeat that build")
        return run_dir


def log_stderr(message: str) -> None:
    """fleet.py's progress lines: stdout carries only the summary (`--json` is one JSON document)."""
    print(message, file=sys.stderr)


class FleetLauncher:
    """The app on the fleet: one fleet.py step for the shard, on the worker the repeated shard ran on, with its mutant."""

    def __init__(self, client: Optional[str] = None) -> None:
        self.fleet_module = oracle.require_sibling("fleet", "p15-oracle-050")
        try:
            self.client = self.fleet_module.find_client(client)
        except self.fleet_module.UsageError as error:
            raise ConfirmError(f"the app reruns on the fleet: {error}", EXIT_INCOMPLETE) from None

    def step_record(self, pin: Optional[Path]) -> Dict[str, Any]:
        """fleet.py keeps a shard's run in shards/<side>/<i>/unpacked/run, beside step.json (its worker and args)."""
        if pin is None:
            return {}
        try:
            record = json.loads((pin.parent.parent / "step.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return record if isinstance(record, dict) else {}

    def plan(self, request: RunRequest) -> Any:
        """The request's fleet.Shard; raises fleet.UsageError when the controller would refuse its step args."""
        fleet = self.fleet_module
        config = request.side.config
        step = self.step_record(request.pin)
        extra: Tuple[Tuple[str, str], ...] = ()
        if config.get("switch"):
            extra = (("switch", config["switch"]), ("arm", config["arm"]))
        elif config.get("arm"):
            extra = (("arm", config["arm"]),)
        # A mutant side (`fleet.py diff --head-mutant`) reruns with the patch its step applied.
        extra += tuple(("mutant", arg.split("=", 1)[1]) for arg in fleet.decode_args(step.get("args") or ())
                       if arg.startswith("--mutant="))
        selection = fleet.Selection(
            suites=tuple(config.get("suites") or ()), filters=request.filters, repeat=request.repeat,
            retry_limit=request.retry_limit, seed=request.seed, batch_limit=request.batch_limit,
            config=str(config["build"]))
        fleet_side = fleet.Side(request.label, request.side.sha, extra)
        index, total = request.shard
        fleet.make_shards(fleet_side, run_id=request.confirm_id, total=total, selection=selection, out=request.out)
        shard = fleet_side.shards[index]
        shard.target_worker = step.get("worker") or None
        return shard

    def fits(self, request: RunRequest) -> bool:
        try:
            self.plan(request)
        except self.fleet_module.UsageError:
            return False
        return True

    def run(self, request: RunRequest) -> Path:
        fleet = self.fleet_module
        if not request.side.sha:
            raise LaunchError(f"the {request.side.label} receipt records no SHA, so the fleet cannot build it again")
        try:
            shard = self.plan(request)
            fleet.Fleet(self.client, step_timeout=fleet.DEFAULT_STEP_TIMEOUT_S,
                        wait_timeout=fleet.DEFAULT_WAIT_TIMEOUT_S, log=log_stderr).complete(shard)
        except (fleet.UsageError, OSError) as error:
            raise LaunchError(f"fleet step for {request.label}: {error}") from None
        if shard.run_dir is None:
            raise LaunchError(f"fleet step {shard.key}: {shard.state}: {shard.error or 'no receipt'}")
        return shard.run_dir


def default_launcher(product: str) -> Launcher:
    if product == "app":
        return FleetLauncher()
    if oracle.outside_vm_queue(product):
        return QueueLauncher()
    return LocalLauncher()


# ---------------------------------------------------------------------------------------
# Verdicts


def verdict(value: str, *, run_id: Optional[str], directory: Optional[Path], sha: str, detail: str) -> Dict[str, Any]:
    return {"verdict": value, "run": run_id, "dir": str(directory) if directory else None, "sha": sha,
            "detail": detail}


def first_place(finding: Mapping[str, Any]) -> Tuple[Any, ...]:
    """Where and what the head answered at its first divergence; the head retry must answer the same."""
    return (finding.get("step"), finding.get("checkpoint"), finding.get("pointer"),
            json.dumps(finding.get("b"), sort_keys=True))


def place_text(finding: Mapping[str, Any]) -> str:
    where = " ".join(str(p) for p in (finding.get("step"), finding.get("checkpoint")) if p) or "result"
    return f"{where} {finding.get('pointer')}"


@dataclass(frozen=True)
class Rerun:
    """One rerun's run dir and its diff.py comparison with the base run, limited to its cases."""

    directory: Optional[Path]
    run_id: Optional[str]
    receipt: Dict[str, Any]
    statuses: Dict[str, str]
    findings: Dict[str, Dict[str, Any]]
    error: Optional[str]


def compare_rerun(base: SideRun, run_dir: Optional[Path], error: Optional[str], cases: Sequence[str],
                  expected: Sequence[Path], out: Path, arm_pointers: Sequence[str] = ()) -> Rerun:
    """diff.py of the base run against a rerun, for `cases` only; an error makes every case not-comparable.

    `arm_pointers` only for a rerun of the other arm (the head retry of a switch diff): there the arm
    readback must differ, and is not a divergence; a base-arm rerun reads back the same arm by design.
    """
    if run_dir is None:
        return Rerun(None, None, {}, {}, {}, error or "no run dir")
    try:
        receipt = oracle.read_receipt(run_dir)
    except oracle.UsageError as failure:
        return Rerun(run_dir, None, {}, {}, {}, str(failure))
    run_id = str(receipt.get("runId"))
    ran = [cid for cid in cases if cid in receipt.get("cases", {})]
    if not ran:
        return Rerun(run_dir, run_id, receipt, {}, {}, None)
    try:
        code, document = oracle.run_diff_py(base.dir, run_dir, out, expected, arm_pointers, cases=ran)
    except oracle.UsageError as failure:
        return Rerun(run_dir, run_id, receipt, {}, {}, f"diff.py: {failure}")
    if code == oracle.DIFF_HOST_MISMATCH:
        mismatched = "; ".join(f"{k}: {', '.join(v)}" for k, v in sorted((document.get("mismatched") or {}).items()))
        return Rerun(run_dir, run_id, receipt, {}, {}, f"host-mismatch with the base run: {mismatched}")
    if code == oracle.DIFF_INTERNAL:
        return Rerun(run_dir, run_id, receipt, {}, {}, f"diff.py internal error: {document.get('error')}")
    if code == oracle.DIFF_ARMS_SAME:
        return Rerun(run_dir, run_id, receipt, {}, {}, "the rerun read back the base's arm, not the head's")
    statuses = {row["case"]: row["status"] for row in document.get("cases", [])}
    findings = {item["journey"]: item for item in document.get("divergences", [])}
    return Rerun(run_dir, run_id, receipt, statuses, findings, None)


def not_ran(rerun: Rerun, case_id: str) -> Optional[str]:
    """Why the case has no result in the rerun, or None."""
    if rerun.error is not None:
        return None
    record = (rerun.receipt.get("cases") or {}).get(case_id)
    if record is None:
        return "the rerun did not select the case"
    if record.get("outcome") in ("not-run", "planned"):
        return "no launch of the rerun ran the case"
    if record.get("outcome") == "skipped":
        return "the rerun's expectations skip the case"
    return None


def head_retry_verdict(rerun: Rerun, case_id: str, original: Mapping[str, Any], sha: str) -> Dict[str, Any]:
    def make(value: str, detail: str) -> Dict[str, Any]:
        return verdict(value, run_id=rerun.run_id, directory=rerun.directory, sha=sha, detail=detail)

    if rerun.error is not None:
        return make(NOT_COMPARABLE, rerun.error)
    missing = not_ran(rerun, case_id)
    if missing:
        return make(NOT_RUN, missing)
    status = rerun.statuses.get(case_id)
    if status == "flaky":
        reasons = (rerun.receipt["cases"][case_id].get("reasons") or ["flaky"])
        return make(FLAKY, "the head retry run calls it flaky: " + "; ".join(reasons))
    if status in ("equal", "explained"):
        return make(PASS, "the head retry matches the base run")
    if status == "divergent":
        again = rerun.findings[case_id]
        if first_place(again) == first_place(original):
            return make(FAIL, f"diverges again at {place_text(again)}")
        return make(FLAKY, f"diverges elsewhere on retry: {place_text(again)} head "
                           f"{json.dumps(again.get('b'), sort_keys=True)}, first run {place_text(original)} head "
                           f"{json.dumps(original.get('b'), sort_keys=True)}")
    return make(NOT_COMPARABLE, f"diff.py gave the case status {status!r}")


def base_alone_verdict(rerun: Rerun, case_id: str, sha: str) -> Dict[str, Any]:
    def make(value: str, detail: str) -> Dict[str, Any]:
        return verdict(value, run_id=rerun.run_id, directory=rerun.directory, sha=sha, detail=detail)

    if rerun.error is not None:
        return make(NOT_COMPARABLE, rerun.error)
    missing = not_ran(rerun, case_id)
    if missing:
        return make(NOT_RUN, missing)
    record = rerun.receipt["cases"][case_id]
    status = rerun.statuses.get(case_id)
    if status == "flaky":
        return make(FLAKY, "the base alone run calls it flaky: " + "; ".join(record.get("reasons") or ["flaky"]))
    if status == "divergent":
        finding = rerun.findings[case_id]
        return make(FAIL, f"alone, the base answers otherwise than in its run at {place_text(finding)}: "
                          f"{json.dumps(finding.get('a'), sort_keys=True)} then {json.dumps(finding.get('b'), sort_keys=True)}")
    if status not in ("equal", "explained"):
        return make(NOT_COMPARABLE, f"diff.py gave the case status {status!r}")
    if record.get("outcome") == "unexpected":
        return make(FAIL, f"the base result {record.get('status')} is not an expected one ({', '.join(record.get('expected') or [])})")
    return make(PASS, "alone, the base gives its run's answer with an expected result")


def classify(verdicts: Mapping[str, Mapping[str, Any]]) -> Tuple[str, str]:
    """(class, reason) from the three verdicts."""
    retry, base = verdicts["head_retry"]["verdict"], verdicts["base"]["verdict"]
    if retry in (PASS, FLAKY):
        return FLAKE, f"head retry {retry}: {verdicts['head_retry']['detail']}"
    if retry != FAIL:
        return UNCONFIRMED, f"head retry {retry}: {verdicts['head_retry']['detail']}"
    if base == PASS:
        return CONFIRMED, "head failed twice and the base passes"
    if base in (FAIL, FLAKY):
        return BASE_RED, f"base {base}: {verdicts['base']['detail']}"
    return UNCONFIRMED, f"base {base}: {verdicts['base']['detail']}"


# ---------------------------------------------------------------------------------------
# The confirmation


@dataclass(frozen=True)
class Inputs:
    diff_dir: Path
    comparison: Dict[str, Any]
    findings: Dict[str, Dict[str, Any]]
    base: SideRun
    head: SideRun
    expected: Tuple[Path, ...]
    # A switch diff's arm readback pointers (task 111): the base arm and a head-arm rerun must differ there.
    arm_pointers: Tuple[str, ...] = ()


def load_inputs(diff_dir: Path) -> Inputs:
    path = diff_dir / "comparison.json"
    try:
        comparison = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ConfirmError(f"{path}: no readable comparison ({error}); give the --out of `oracle.py diff`") from None
    if comparison.get("schema") != oracle.COMPARISON_SCHEMA:
        raise ConfirmError(f"{path}: not a {oracle.COMPARISON_SCHEMA} comparison")
    if comparison.get("refused"):
        raise ConfirmError(f"the comparison was refused ({comparison['refused']}): nothing to confirm", EXIT_INCOMPLETE)
    if comparison.get("order_parity") or comparison.get("a") == "baselines":
        raise ConfirmError("an order-parity or baselines comparison has no base and head to rerun")
    missing = [key for key in ("a_dir", "b_dir", "expected_files") if key not in comparison]
    if missing:
        raise ConfirmError(f"{path} has no {', '.join(missing)}: it predates confirm; run `oracle.py diff` again")
    findings: Dict[str, Dict[str, Any]] = {}
    if comparison.get("divergent"):
        try:
            document = json.loads(Path(comparison["divergence"]).read_text(encoding="utf-8"))
        except (OSError, TypeError, ValueError) as error:
            raise ConfirmError(f"the comparison's divergence.json is unreadable ({error})") from None
        findings = {item["journey"]: item for item in document.get("divergences", [])}
        absent = sorted(set(comparison["divergent"]) - set(findings))
        if absent:
            raise ConfirmError(f"divergence.json has no finding for {', '.join(absent[:5])}")
    expected = tuple(Path(p) for p in comparison["expected_files"])
    unreadable = [str(p) for p in expected if not p.is_file()]
    if unreadable:
        raise ConfirmError(f"the comparison's --expected files are gone: {', '.join(unreadable)}")
    base = SideRun.load(str(comparison["a"]), Path(comparison["a_dir"]))
    head = SideRun.load(str(comparison["b"]), Path(comparison["b_dir"]))
    if base.total != head.total:
        raise ConfirmError(f"shard totals differ: {base.total} vs {head.total}")
    arm_pointers = tuple(str(p) for p in comparison.get("arm_pointers") or ())
    return Inputs(diff_dir, comparison, findings, base, head, expected, arm_pointers)


@dataclass(frozen=True)
class Options:
    out: Path
    confirm_id: str
    corpus: Optional[Path] = None
    expectations_root: Optional[Path] = None
    parallel: int = MAX_PARALLEL_RUNS


def launch_all(launcher: Launcher, requests: Sequence[RunRequest], parallel: int) -> Dict[str, Tuple[Optional[Path], Optional[str]]]:
    """label -> (run dir, None) or (None, why it has none)."""
    def one(request: RunRequest) -> Tuple[str, Tuple[Optional[Path], Optional[str]]]:
        try:
            return request.label, (launcher.run(request), None)
        except LaunchError as error:
            return request.label, (None, str(error))

    if not requests:
        return {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(parallel, len(requests)))) as pool:
        return dict(pool.map(one, requests))


def filter_of(case_id: str) -> Optional[str]:
    """An exact-match --filter glob for the case; None when the id cannot be one (parse_list splits on commas)."""
    return None if "," in case_id else glob.escape(case_id)


def split_cases(ids: Sequence[str], make: Callable[[int, List[str]], RunRequest],
                fits: Callable[[RunRequest], bool]) -> List[Tuple[RunRequest, List[str]]]:
    """IDS in consecutive parts, each as long as `fits(make(part, ids))` allows. A case that fits in no request
    still gets its own; its launcher refuses it, and the case stays unconfirmed."""
    parts: List[Tuple[RunRequest, List[str]]] = []
    chunk: List[str] = []
    for cid in ids:
        if chunk and not fits(make(len(parts), chunk + [cid])):
            parts.append((make(len(parts), chunk), chunk))
            chunk = []
        chunk.append(cid)
    if chunk:
        parts.append((make(len(parts), chunk), chunk))
    return parts


def confirm(inputs: Inputs, launcher: Launcher, options: Options) -> List[Dict[str, Any]]:
    """The three verdicts and the class of every divergent case, in case order."""
    base, head = inputs.base, inputs.head
    cases = sorted(inputs.comparison.get("divergent") or ())
    total = head.total
    config = head.config
    head_runs, base_runs = head.shard_runs(), base.shard_runs()
    oracle.check_out_dir(options.out)
    # Every confirm reruns into its own dir, so no receipt of an earlier confirm can stand in for a rerun.
    runs = options.out / "runs" / options.confirm_id
    runs.mkdir(parents=True, exist_ok=False)

    by_shard: Dict[int, List[str]] = {}
    for cid in cases:
        by_shard.setdefault(oracle.shard_of(cid, total), []).append(cid)
    retry_requests = [
        RunRequest(options.confirm_id, f"retry-s{index}of{total}", head, (index, total), head.seed(index), tuple(config.get("filters") or ()),
                   int(config["batch_limit"]), int(config["repeat"]), int(config["retry_limit"]),
                   runs / "head-retry" / f"s{index}", (head_runs.get(index) or (None, ""))[0],
                   options.corpus, options.expectations_root)
        for index in sorted(by_shard)
    ]
    launched = launch_all(launcher, retry_requests, options.parallel)
    retries: Dict[str, Rerun] = {}
    for request in retry_requests:
        run_dir, error = launched[request.label]
        index = request.shard[0]
        rerun = compare_rerun(base, run_dir, error, by_shard[index], inputs.expected,
                              runs / "head-retry" / f"divergence-s{index}.json", inputs.arm_pointers)
        for cid in by_shard[index]:
            retries[cid] = rerun

    verdicts: Dict[str, Dict[str, Dict[str, Any]]] = {}
    alone: Dict[int, List[str]] = {}
    for cid in cases:
        shard_dir, run_id = head_runs.get(oracle.shard_of(cid, total)) or (head.dir, str(head.receipt["runId"]))
        finding = inputs.findings[cid]
        verdicts[cid] = {
            "head": verdict(FAIL, run_id=run_id, directory=shard_dir, sha=head.sha,
                            detail=f"diverges from the base at {place_text(finding)}"),
            "head_retry": head_retry_verdict(retries[cid], cid, finding, head.sha),
        }
        if verdicts[cid]["head_retry"]["verdict"] != FAIL:
            verdicts[cid]["base"] = verdict(NOT_RUN, run_id=None, directory=None, sha=base.sha,
                                            detail="not needed: the head did not fail twice")
        elif filter_of(cid) is None:
            verdicts[cid]["base"] = verdict(NOT_RUN, run_id=None, directory=None, sha=base.sha,
                                            detail="a case id with a comma cannot be a --filter")
        else:
            alone.setdefault(oracle.shard_of(cid, total), []).append(cid)

    # Each case alone in its own launch (batch limit 1), no retry, on its base shard's host: one run per shard, or
    # more when its cases do not fit the runner's argument limits in one.
    def alone_request(index: int, part: int, ids: Sequence[str]) -> RunRequest:
        suffix = f"-p{part}" if part else ""
        return RunRequest(options.confirm_id, f"alone-s{index}of{total}{suffix}", base, (0, 1), None,
                          tuple(filter_of(cid) or "" for cid in ids), 1, 1, 0, runs / "base-alone" / f"s{index}{suffix}",
                          (base_runs.get(index) or (None, ""))[0], options.corpus, options.expectations_root)

    alone_parts: List[Tuple[RunRequest, List[str]]] = []
    for index, ids in sorted(alone.items()):
        alone_parts += split_cases(ids, lambda part, chunk, index=index: alone_request(index, part, chunk),
                                   launcher.fits)
    launched = launch_all(launcher, [request for request, _ in alone_parts], options.parallel)
    for request, ids in alone_parts:
        run_dir, error = launched[request.label]
        rerun = compare_rerun(base, run_dir, error, ids, inputs.expected,
                              request.out.with_name(f"divergence-{request.out.name}.json"))
        for cid in ids:
            verdicts[cid]["base"] = base_alone_verdict(rerun, cid, base.sha)

    mode = head.mode()
    # route.py's target (task 118): a switch at the head's ref, every switch (launch-config), or the commit pair.
    target: Dict[str, Any] = {"source": head.sha} if mode != "base-head" else {"base": base.sha, "head": head.sha}
    rows = []
    for cid in cases:
        kind, reason = classify(verdicts[cid])
        finding = inputs.findings[cid]
        rows.append({
            "schema": SCHEMA,
            "case": cid,
            "class": kind,
            "confidence": ROUTE_CONFIDENCE.get(kind, kind),
            "reason": reason,
            "mode": mode,
            "product": head.product,
            "switch": head.config.get("switch"),
            "arm": head.config.get("arm"),
            "a_label": base.label,
            "b_label": head.label,
            "base_sha": base.sha,
            "head_sha": head.sha,
            **target,
            "verdicts": {key: verdicts[cid][key] for key in VERDICT_KEYS},
            "journey": cid,
            **{key: finding.get(key) for key in FINDING_KEYS},
            "comparison": str(inputs.diff_dir / "comparison.json"),
        })
    return rows


# ---------------------------------------------------------------------------------------
# Outputs


def write_lines(path: Path, rows: Sequence[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    temp.replace(path)


def append_lines(path: Path, rows: Sequence[Mapping[str, Any]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def flake_line(row: Mapping[str, Any]) -> Dict[str, Any]:
    """The MQ-flakes line (`oracle.py run --flaky-out` shape) of a head that passed or flaked on retry."""
    retry = row["verdicts"]["head_retry"]
    return {"case": row["case"], "run_id": retry["run"], "product": row["product"], "arm": row["arm"],
            "switches": {row["switch"]: row["arm"]} if row["switch"] else {}, "source": "confirm",
            "pointer": row["pointer"], "reasons": [row["reason"]], "verdicts": row["verdicts"]}


def summary_of(inputs: Inputs, rows: Sequence[Mapping[str, Any]], out: Path, routed: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    counts = {kind: 0 for kind in (CONFIRMED, FLAKE, BASE_RED, UNCONFIRMED)}
    for row in rows:
        counts[row["class"]] += 1
    return {
        "schema": SUMMARY_SCHEMA,
        "diff": str(inputs.diff_dir),
        "base": {"label": inputs.base.label, "sha": inputs.base.sha, "dir": str(inputs.base.dir)},
        "head": {"label": inputs.head.label, "sha": inputs.head.sha, "dir": str(inputs.head.dir)},
        "counts": counts,
        "cases": {row["case"]: row["class"] for row in rows},
        "confirmed": str(out / "confirmed.jsonl"),
        "route": routed,
    }


def exit_code(rows: Sequence[Mapping[str, Any]]) -> int:
    kinds = {row["class"] for row in rows}
    if CONFIRMED in kinds:
        return EXIT_CONFIRMED
    return EXIT_INCOMPLETE if UNCONFIRMED in kinds else EXIT_NONE


def print_summary(summary: Mapping[str, Any], rows: Sequence[Mapping[str, Any]]) -> None:
    counts = summary["counts"]
    print(f"oracle confirm {summary['base']['label']} vs {summary['head']['label']}: "
          + ", ".join(f"{kind} {counts[kind]}" for kind in (CONFIRMED, FLAKE, BASE_RED, UNCONFIRMED)))
    for row in rows:
        marks = " ".join(f"{key}={row['verdicts'][key]['verdict']}" for key in VERDICT_KEYS)
        print(f"  {row['class']}: {row['case']} {row['pointer']} ({marks}): {row['reason']}")
    print(f"  confirmed.jsonl: {summary['confirmed']}")
    if summary["route"] is not None:
        print(f"  routed {summary['route']['routed']} to {summary['route']['out']}")
        for item in summary["route"]["unrouted"]:
            print(f"  unrouted {item['where']}: {item['why']}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="confirm.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--diff", type=Path, required=True, help="the --out dir of `oracle.py diff` (comparison.json)")
    parser.add_argument("--out", type=Path, help="confirm dir (default DIFF/confirm)")
    parser.add_argument("--flaky-out", type=Path, default=DEFAULT_FLAKY_OUT, help=f"MQ-flakes (default {DEFAULT_FLAKY_OUT})")
    parser.add_argument("--base-red-out", type=Path, default=DEFAULT_BASE_RED_OUT,
                        help=f"base-red queue (default {DEFAULT_BASE_RED_OUT})")
    parser.add_argument("--corpus", type=Path, help="corpus of the reruns (default the run's own default)")
    parser.add_argument("--expectations-root", type=Path, help="expectations of the reruns")
    parser.add_argument("--parallel", type=int, default=MAX_PARALLEL_RUNS, help="reruns at once")
    parser.add_argument("--no-route", action="store_true", help="write confirmed.jsonl only; do not run route.py")
    parser.add_argument("--route-out", type=Path, help="route.py --out, joined under its lock (default its own)")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    return parser


def main(argv: Optional[List[str]] = None, *, launcher: Optional[Launcher] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        inputs = load_inputs(args.diff)
        out = args.out or args.diff / "confirm"
        rows = confirm(inputs, launcher or default_launcher(inputs.head.product),
                       Options(out, "confirm-" + oracle.new_run_id(), args.corpus, args.expectations_root,
                               max(1, args.parallel)))
    except ConfirmError as error:
        print(f"confirm: {error}", file=sys.stderr)
        return error.code
    except oracle.UsageError as error:
        print(f"confirm: {error}", file=sys.stderr)
        return EXIT_USAGE
    write_lines(out / "confirmed.jsonl", rows)
    append_lines(args.flaky_out, [flake_line(row) for row in rows if row["class"] == FLAKE])
    append_lines(args.base_red_out, [row for row in rows if row["class"] == BASE_RED])
    routed = None
    if not args.no_route:
        route = oracle.require_sibling("route", "p15-oracle-118")
        try:
            routed = route.route_files([out / "confirmed.jsonl"], args.route_out or route.DEFAULT_OUT, merge=True)
        except route.InputError as error:
            print(f"confirm: route.py: {error}; confirmed.jsonl is written, route it with `oracle.py route`",
                  file=sys.stderr)
            return EXIT_USAGE
    summary = summary_of(inputs, rows, out, routed)
    oracle.write_json(out / "confirm.json", summary)
    if args.json:
        print(json.dumps(summary, indent=1, sort_keys=True))
    else:
        print_summary(summary, rows)
    return exit_code(rows)


if __name__ == "__main__":
    sys.exit(main())
