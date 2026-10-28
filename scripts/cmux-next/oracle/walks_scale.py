#!/usr/bin/env python3
"""Daemon walks at scale on both arms of every daemon refactor switch (p15-oracle-099).

Usage (through `linux_run.sh walks REF`, which builds the oracle-profile binary in the runnerd queue and
runs `run` on it as one queued job; on the VM every cmux-tui suite run is a runnerd job, spec 3G):
  walks_scale.py run --binary BIN [--sha SHA] [--switch NAME ...] [--seeds 100000] [--first-seed 1]
                     [--length 30] [--chunk 10000] [--jobs 200] [--work DIR] [--commit-dir DIR]
                     [--minimize-all] [--minimize-jobs 16] [--keep]
  walks_scale.py interesting --binary BIN --switch NAME --signature-file FILE [--sha SHA] [--work DIR] CASE

`run`, for each daemon switch of plans/cmux-next/refactor-switches (an entry with `daemon_key`):
1. generates seeds FIRST .. FIRST+SEEDS-1 in chunks (`oracle.py gen --suite walks`, gen_walks.py of
   p15-oracle-098) into a scratch corpus outside the checkout;
2. runs each chunk on arm old and arm new of one build and compares them
   (`oracle.py diff --switch NAME --suite walks`, p15-oracle-111);
3. collects the failures: a case that diverges between the arms or has an unexpected result on
   either arm (a flaky case is not a failure: diff leaves it out and it goes to WORK/flaky.jsonl).
   The kept copy of a failing walk lists the switch in `switches`, so every ddmin candidate and the
   committed walk must hit the switch on each arm (diff --switch refuses arm-not-exercised);
4. groups the failures by signature and minimizes one walk per group (every walk with
   --minimize-all) through `oracle.py minimize` (minimize.py of p15-oracle-098, ddmin), with
   `walks_scale.py interesting` as the test;
5. names the minimized walk `<switch>-<seed>` (id, suite, title), checks that exact content again (it
   must still give the same signature and be no longer than the walk it came from), writes it to
   --commit-dir as `<id>.json` and runs `oracle.py check` on it (`linux_run.sh walks` copies the
   committed walks into tests/oracle/corpus/walks/ of the checkout once the report is written);
6. only then writes the report: receipt.json and index.md in --work. If one failure could not be
   minimized, there is no report: unminimized.json names each such failure and the exit is 3.

Chrome reference: ClusterFuzz groups crashes by crash state and minimizes one testcase per group
(google/clusterfuzz src/clusterfuzz/_internal/bot/tasks/minimize_task.py with the delta minimizer
of bot/minimizer/delta_minimizer.py, a ddmin over a "still crashes the same way" test); libFuzzer's
-minimize_crash=1 (chromium/src testing/libfuzzer/reproducing.md) keeps the input only while the
same crash reproduces. The signature here is that crash state: the arms and results of an
unexpected result, else the first divergent pointer with array indexes generalized.

Interfaces of the sibling tasks this file calls (oracle.py runs every one of them):
    oracle.py gen --suite walks --corpus DIR --first-seed N --count N --length N    (098)
        writes DIR/walks/<id>.json, one case per seed, the seed in fixture.seed
    oracle.py diff --switch NAME --product daemon --suite walks --corpus DIR --binary BIN
        --out DIR ...: OUT/{old,new}/receipt.json, OUT/comparison.json, OUT/divergence.json  (017, 111)
    oracle.py minimize --case IN --out OUT --jobs N -- TEST ARGV...                 (098)
        runs `TEST ARGV... CANDIDATE`: exit 0 the candidate is interesting, 1 it is not, any other
        exit is an error that stops the minimization; exit 0 with OUT written when done
    oracle.py check FILE                                                             (017)

`interesting` exits 0 when CASE gives the signature on a deterministic two-repeat diff of the arms
(no retries: a flaky candidate is not interesting), 1 when it does not, 2 on an infrastructure
error. `run` refuses to start on Linux outside a runnerd job (RUNNERD_JOB), where oracle.py would
refuse each chunk's diff. Stdlib only, Python 3.9+, safe under `python3 -I`. Spec: plans/cmux-next/chrome-parity/
p15-oracle.md, tasks 098 and 099.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import platform as platform_mod
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ORACLE = HERE / "oracle.py"
SWITCH_REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
DEFAULT_COMMIT_DIR = REPO / "tests" / "oracle" / "corpus" / "walks"
DEFAULT_WORK_BASE = Path("/tmp/oracle-walks")
SUITE = "walks"
ARMS = ("old", "new")
RECEIPT_SCHEMA = "cmux-oracle-walks-v1"

DEFAULT_SEEDS = 100_000
DEFAULT_LENGTH = 30
DEFAULT_CHUNK = 10_000
DEFAULT_JOBS = 200
DEFAULT_MINIMIZE_JOBS = 16
# The predicate runs one case: two daemons per arm repeat, so two jobs keep the arms concurrent.
PREDICATE_JOBS = 2

DIFF_OK, DIFF_DIVERGENT, DIFF_BAD_INPUT, DIFF_REFUSED, DIFF_INTERNAL = 0, 1, 2, 3, 4
INTERESTING, NOT_INTERESTING, PREDICATE_ERROR = 0, 1, 2
EXIT_REFUSED = 3
CASE_ID_MAX = 64


class UsageError(Exception):
    """A bad argument or a missing sibling: exit 2."""


class InfraError(Exception):
    """A sibling tool failed in a way that says nothing about the walk: exit 2."""


# ---------------------------------------------------------------------------------------
# The oracle.py seam


class OracleCli:
    """Runs oracle.py subcommands. Tests inject a fake with the same four methods."""

    def __init__(self, oracle: Path = ORACLE, python: str = sys.executable) -> None:
        self.prefix = [python, "-I", str(oracle)]

    def _run(self, argv: Sequence[str]) -> int:
        return subprocess.run([*self.prefix, *argv], check=False).returncode

    def gen(self, corpus: Path, *, first_seed: int, count: int, length: int) -> int:
        return self._run(gen_argv(corpus, first_seed=first_seed, count=count, length=length))

    def diff(self, **kwargs: Any) -> int:
        return self._run(diff_argv(**kwargs))

    def minimize(self, case: Path, out: Path, *, jobs: int, test: Sequence[str]) -> int:
        return self._run(["minimize", "--case", str(case), "--out", str(out), "--jobs", str(jobs), "--", *test])

    def check(self, path: Path) -> int:
        return self._run(["check", str(path)])


def gen_argv(corpus: Path, *, first_seed: int, count: int, length: int) -> List[str]:
    return ["gen", "--suite", SUITE, "--corpus", str(corpus), "--first-seed", str(first_seed),
            "--count", str(count), "--length", str(length)]


def diff_argv(*, switch: str, corpus: Path, binary: str, out: Path, jobs: int, sha: Optional[str],
              retry_limit: Optional[int] = None, repeat: int = 1, flaky_out: Optional[Path] = None) -> List[str]:
    argv = ["diff", "--switch", switch, "--product", "daemon", "--suite", SUITE, "--corpus", str(corpus),
            "--binary", binary, "--jobs", str(jobs), "--repeat", str(repeat), "--out", str(out)]
    if sha:
        argv += ["--ref", sha]
    if retry_limit is not None:
        argv += ["--retry-limit", str(retry_limit)]
    if flaky_out is not None:
        argv += ["--flaky-out", str(flaky_out)]
    return argv


# ---------------------------------------------------------------------------------------
# Signatures


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def generalize_pointer(pointer: Optional[str]) -> str:
    """`/daemon/workspaces/3/title` -> `/daemon/workspaces/*/title`: a shorter walk has fewer items."""
    if not pointer:
        return ""
    return "/".join("*" if part.isdigit() else part for part in pointer.split("/"))


def signature_key(signature: Mapping[str, Any]) -> str:
    return json.dumps(signature, sort_keys=True, separators=(",", ":"))


def failures_of(out: Path) -> Dict[str, Dict[str, Any]]:
    """Case id -> signature for each failing case of one `oracle.py diff --switch` directory.

    An unexpected result on an arm is the signature (arm -> result) even when the arms also
    diverge, because the divergence then only reports the result change. Otherwise the first
    divergent pointer is.
    """
    unexpected: Dict[str, Dict[str, str]] = {}
    for arm in ARMS:
        receipt_path = out / arm / "receipt.json"
        if not receipt_path.is_file():
            continue
        receipt = read_json(receipt_path)
        for cid in receipt.get("unexpected", []):
            unexpected.setdefault(cid, {})[arm] = receipt["cases"][cid]["status"]
    failures: Dict[str, Dict[str, Any]] = {cid: {"kind": "unexpected", "arms": arms} for cid, arms in unexpected.items()}
    divergence = out / "divergence.json"
    if divergence.is_file():
        for item in read_json(divergence).get("divergences", []):
            failures.setdefault(item["journey"], {"kind": "divergent", "pointer": generalize_pointer(item.get("pointer"))})
    return failures


# ---------------------------------------------------------------------------------------
# Registry and corpus


def daemon_switches(registry_root: Path, wanted: Sequence[str]) -> Dict[str, Dict[str, Any]]:
    entries: Dict[str, Dict[str, Any]] = {}
    if registry_root.is_dir():
        for path in sorted(registry_root.glob("*.json")):
            entries[path.stem] = read_json(path)
    daemon = {name: entry for name, entry in entries.items() if entry.get("daemon_key")}
    for name in wanted:
        if name not in entries:
            raise UsageError(f"--switch {name}: no {registry_root / (name + '.json')}")
        if name not in daemon:
            raise UsageError(f"--switch {name} is an app switch (no daemon_key); daemon walks run daemon switches only")
    selected = {name: daemon[name] for name in wanted} if wanted else daemon
    if not selected:
        raise UsageError(f"no daemon switch in {registry_root} (p15-oracle-232 seeds the registry)")
    return selected


def corpus_cases(corpus: Path) -> Dict[str, Path]:
    """`walks/<name>` -> path for each case gen_walks.py wrote."""
    suite_dir = corpus / SUITE
    if not suite_dir.is_dir():
        return {}
    return {
        f"{SUITE}/{path.relative_to(suite_dir).with_suffix('').as_posix()}": path
        for path in sorted(suite_dir.rglob("*.json"))
        if path.name != "coverage.json" and not path.name.startswith("_")
    }


def case_seed(case: Mapping[str, Any], fallback: str) -> str:
    seed = (case.get("fixture") or {}).get("seed")
    return str(seed) if seed not in (None, "") else fallback


def case_length(case: Mapping[str, Any]) -> int:
    return len(case.get("steps") or ())


def with_switch(case: Mapping[str, Any], switch: str) -> Dict[str, Any]:
    """The case listing `switch`: a diff --switch run then needs hits of it on each arm in this case."""
    return {**case, "switches": sorted(set(case.get("switches") or ()) | {switch})}


def committed_id(switch: str, seed: str, content: str) -> str:
    slug = re.sub(r"[^a-z0-9-]+", "-", seed.lower()).strip("-") or "seed"
    name = f"{switch}-{slug}"
    if len(name) <= CASE_ID_MAX:
        return name
    suffix = hashlib.sha256(content.encode()).hexdigest()[:8]
    return f"{name[:CASE_ID_MAX - 9].rstrip('-')}-{suffix}"


# ---------------------------------------------------------------------------------------
# The predicate


def interesting(cli: OracleCli, *, case_path: Path, switch: str, binary: str, sha: Optional[str],
                signature: Mapping[str, Any], work: Path) -> int:
    """INTERESTING when the candidate walk gives `signature` on two repeats without retries."""
    try:
        case = read_json(case_path)
    except (OSError, ValueError):
        return NOT_INTERESTING  # ddmin may cut a candidate into nothing a case can be
    if not isinstance(case, dict) or not case.get("steps"):
        return NOT_INTERESTING
    work.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="p-", dir=work))
    try:
        case = {**case, "id": "candidate", "suite": SUITE}
        write_json(scratch / "corpus" / SUITE / "candidate.json", case)
        code = cli.diff(switch=switch, corpus=scratch / "corpus", binary=binary, out=scratch / "out",
                        jobs=PREDICATE_JOBS, sha=sha, retry_limit=0, repeat=2)
        if code in (DIFF_BAD_INPUT, DIFF_INTERNAL):
            return PREDICATE_ERROR
        if code == DIFF_REFUSED:
            # arm-not-exercised (the cut walk no longer reaches the switch) or flaky: not the failure.
            return NOT_INTERESTING
        found = failures_of(scratch / "out").get(f"{SUITE}/candidate")
        return INTERESTING if found is not None and signature_key(found) == signature_key(signature) else NOT_INTERESTING
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def predicate_argv(*, switch: str, binary: str, sha: Optional[str], signature_file: Path, work: Path) -> List[str]:
    argv = [sys.executable, "-I", str(HERE / "walks_scale.py"), "interesting", "--switch", switch,
            "--binary", binary, "--signature-file", str(signature_file), "--work", str(work)]
    if sha:
        argv += ["--sha", sha]
    return argv


# ---------------------------------------------------------------------------------------
# The run


@dataclass
class Failure:
    switch: str
    case: str
    seed: str
    chunk: int
    signature: Dict[str, Any]
    path: Path
    length: int
    minimized: Optional[str] = None
    minimized_length: Optional[int] = None
    duplicate_of: Optional[str] = None
    error: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        out = {"switch": self.switch, "case": self.case, "seed": self.seed, "chunk": self.chunk,
               "signature": self.signature, "steps": self.length}
        for key, value in (("minimized", self.minimized), ("minimizedSteps", self.minimized_length),
                           ("duplicateOf", self.duplicate_of), ("error", self.error)):
            if value is not None:
                out[key] = value
        return out


@dataclass
class ArmTotals:
    cases: int = 0
    counts: Dict[str, int] = field(default_factory=dict)
    hits: Dict[str, int] = field(default_factory=dict)
    duration_s: float = 0.0

    def add(self, receipt: Mapping[str, Any], switch: str) -> None:
        self.cases += len(receipt.get("order", ()))
        for key, value in (receipt.get("counts") or {}).items():
            self.counts[key] = self.counts.get(key, 0) + int(value)
        for arm, value in ((receipt.get("switch_hits") or {}).get(switch) or {}).items():
            self.hits[arm] = self.hits.get(arm, 0) + int(value)
        self.duration_s += float(receipt.get("duration_s") or 0.0)

    def to_json(self) -> Dict[str, Any]:
        return {"cases": self.cases, "counts": dict(sorted(self.counts.items())),
                "switch_hits": dict(sorted(self.hits.items())), "duration_s": round(self.duration_s, 3)}


@dataclass
class SwitchTotals:
    daemon_key: str
    arms: Dict[str, ArmTotals] = field(default_factory=lambda: {arm: ArmTotals() for arm in ARMS})
    compared: int = 0
    divergent: int = 0
    unexpected: int = 0
    flaky: int = 0
    refused: List[str] = field(default_factory=list)
    wall_s: float = 0.0

    def to_json(self) -> Dict[str, Any]:
        return {"daemon_key": self.daemon_key, "arms": {arm: t.to_json() for arm, t in self.arms.items()},
                "compared": self.compared, "divergent": self.divergent, "unexpected": self.unexpected,
                "flaky": self.flaky, "refused": self.refused, "wall_s": round(self.wall_s, 3)}


@dataclass(frozen=True)
class RunConfig:
    binary: str
    sha: Optional[str]
    seeds: int
    first_seed: int
    length: int
    chunk: int
    jobs: int
    work: Path
    commit_dir: Path
    minimize_all: bool
    minimize_jobs: int
    keep: bool


def run_chunk_for_switch(cli: OracleCli, config: RunConfig, *, switch: str, chunk: int, corpus: Path,
                         cases: Mapping[str, Path], totals: SwitchTotals) -> List[Failure]:
    out = config.work / "chunks" / f"{chunk:04d}" / switch
    started = time.monotonic()
    code = cli.diff(switch=switch, corpus=corpus, binary=config.binary, out=out, jobs=config.jobs,
                    sha=config.sha, flaky_out=config.work / "flaky.jsonl")
    totals.wall_s += time.monotonic() - started
    if code in (DIFF_BAD_INPUT, DIFF_INTERNAL):
        raise InfraError(f"oracle.py diff --switch {switch} on chunk {chunk} exited {code} (see {out})")
    for arm in ARMS:
        receipt_path = out / arm / "receipt.json"
        if receipt_path.is_file():
            receipt = read_json(receipt_path)
            totals.arms[arm].add(receipt, switch)
    comparison_path = out / "comparison.json"
    comparison = read_json(comparison_path) if comparison_path.is_file() else {}
    totals.flaky += len(comparison.get("flaky_excluded") or ())
    if code == DIFF_REFUSED or comparison.get("refused"):
        totals.refused.append(f"chunk {chunk}: {comparison.get('refused') or 'arm-not-exercised'}")
    totals.compared += int(comparison.get("compared") or 0)
    failures = []
    keep_dir = config.work / "failures" / switch
    for cid, signature in sorted(failures_of(out).items()):
        source = cases.get(cid)
        if source is None:
            raise InfraError(f"{cid} failed on {switch} but is not in chunk {chunk}'s corpus")
        kept = keep_dir / f"{cid.split('/', 1)[1].replace('/', '__')}.json"
        case = with_switch(read_json(source), switch)
        write_json(kept, case)
        if signature["kind"] == "unexpected":
            totals.unexpected += 1
        else:
            totals.divergent += 1
        failures.append(Failure(switch, cid, case_seed(case, cid.split("/", 1)[1]), chunk, signature, kept,
                                case_length(case)))
    if not config.keep:
        for arm in ARMS:
            for name in ("checkpoints.jsonl", "events.jsonl"):
                (out / arm / name).unlink(missing_ok=True)
    return failures


def group_failures(failures: Sequence[Failure], minimize_all: bool) -> List[Failure]:
    """The failures to minimize: all of them, or the shortest walk of each (switch, signature)."""
    if minimize_all:
        return list(failures)
    leaders: Dict[Tuple[str, str], Failure] = {}
    for failure in sorted(failures, key=lambda f: (f.length, f.chunk, f.case)):
        leaders.setdefault((failure.switch, signature_key(failure.signature)), failure)
    return list(leaders.values())


def minimize_one(cli: OracleCli, config: RunConfig, failure: Failure) -> None:
    """Minimizes one failure, checks it again, writes it to the commit dir and checks the case file."""
    base = config.work / "minimize" / failure.switch / Path(failure.path).stem
    base.mkdir(parents=True, exist_ok=True)
    signature_file = base / "signature.json"
    write_json(signature_file, failure.signature)
    test = predicate_argv(switch=failure.switch, binary=config.binary, sha=config.sha,
                          signature_file=signature_file, work=base / "predicate")
    reduced = base / "minimized.json"
    code = cli.minimize(failure.path, reduced, jobs=PREDICATE_JOBS, test=test)
    if code != 0 or not reduced.is_file():
        failure.error = f"oracle.py minimize exited {code}" + ("" if reduced.is_file() else " without writing the case")
        return
    try:
        case = read_json(reduced)
    except (OSError, ValueError) as error:
        failure.error = f"the minimized walk is not JSON: {error}"
        return
    if not isinstance(case, dict):
        failure.error = "the minimized walk is not a case object"
        return
    length = case_length(case)
    if length > failure.length:
        failure.error = f"the minimized walk has {length} steps, more than the {failure.length} it came from"
        return
    cid = committed_id(failure.switch, failure.seed, json.dumps(case, sort_keys=True))
    case = {**with_switch(case, failure.switch), "id": cid, "suite": SUITE,
            "title": f"{failure.switch}: minimized daemon walk, seed {failure.seed}"[:200]}
    final = base / "final.json"
    write_json(final, case)
    # The content checked again is the content committed.
    verdict = interesting(cli, case_path=final, switch=failure.switch, binary=config.binary, sha=config.sha,
                          signature=failure.signature, work=base / "verify")
    if verdict != INTERESTING:
        failure.error = "the minimized walk does not reproduce the signature" if verdict == NOT_INTERESTING \
            else "the reproduction check of the minimized walk failed (infrastructure)"
        return
    target = config.commit_dir / f"{cid}.json"
    shutil.copyfile(final, target)
    if cli.check(target) != 0:
        target.unlink(missing_ok=True)
        failure.error = f"oracle.py check refused the minimized case {cid}"
        return
    failure.minimized = str(target)
    failure.minimized_length = length


def write_report(config: RunConfig, receipt: Dict[str, Any]) -> None:
    write_json(config.work / "receipt.json", receipt)
    lines = [
        f"# daemon walks at scale: {receipt['sha'] or 'unknown sha'}",
        "",
        f"- seeds {config.first_seed}..{config.first_seed + config.seeds - 1} ({config.seeds} per arm per switch), "
        f"length {config.length}, chunk {config.chunk}, jobs {config.jobs}",
        f"- wall {receipt['wall_s']} s, ok {receipt['ok']}",
    ]
    for name, totals in receipt["switches"].items():
        arms = ", ".join(f"{arm} {t['cases']} cases hits {t['switch_hits'].get(arm, 0)}" for arm, t in totals["arms"].items())
        lines.append(f"- {name} ({totals['daemon_key']}): {arms}; compared {totals['compared']}, divergent "
                     f"{totals['divergent']}, unexpected {totals['unexpected']}, flaky {totals['flaky']}, "
                     f"wall {totals['wall_s']} s" + (f"; refused: {'; '.join(totals['refused'])}" if totals["refused"] else ""))
    for failure in receipt["failures"]:
        where = failure.get("minimized") or f"duplicate of {failure.get('duplicateOf')}"
        lines.append(f"  - {failure['switch']} {failure['case']} seed {failure['seed']} "
                     f"{signature_key(failure['signature'])}: {where}")
    (config.work / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def host_info() -> Dict[str, Any]:
    return {"name": platform_mod.node(), "os": platform_mod.system(), "arch": platform_mod.machine(),
            "cpus": os.cpu_count()}


def perform_run(cli: OracleCli, config: RunConfig, switches: Mapping[str, Mapping[str, Any]]) -> int:
    started = time.monotonic()
    if (config.work / "receipt.json").exists() or (config.work / "chunks").exists():
        raise UsageError(f"--work {config.work} holds an earlier run; pass a new directory")
    config.work.mkdir(parents=True, exist_ok=True)
    totals = {name: SwitchTotals(str(entry["daemon_key"])) for name, entry in switches.items()}
    failures: List[Failure] = []
    chunks = range(0, config.seeds, config.chunk)
    for index, offset in enumerate(chunks):
        count = min(config.chunk, config.seeds - offset)
        corpus = config.work / "corpus" / f"{index:04d}"
        first = config.first_seed + offset
        if cli.gen(corpus, first_seed=first, count=count, length=config.length) != 0:
            raise InfraError(f"oracle.py gen --suite walks failed for seeds {first}..{first + count - 1}")
        cases = corpus_cases(corpus)
        if len(cases) != count:
            raise InfraError(f"gen_walks.py wrote {len(cases)} walks for {count} seeds ({corpus})")
        for name in switches:
            failures.extend(run_chunk_for_switch(cli, config, switch=name, chunk=index, corpus=corpus, cases=cases,
                                                 totals=totals[name]))
        if not config.keep:
            shutil.rmtree(corpus, ignore_errors=True)
        print(f"walks: chunk {index + 1}/{len(chunks)} done, {len(failures)} failures so far", flush=True)

    targets = group_failures(failures, config.minimize_all)
    config.commit_dir.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=config.minimize_jobs) as pool:
        list(pool.map(lambda f: minimize_one(cli, config, f), targets))
    if not config.minimize_all:
        leaders = {(f.switch, signature_key(f.signature)): f for f in targets}
        for failure in failures:
            leader = leaders[(failure.switch, signature_key(failure.signature))]
            if leader is not failure and leader.minimized:
                failure.duplicate_of = leader.minimized
    unminimized = [f for f in failures if not f.minimized and not f.duplicate_of]
    refused = {name: t.refused for name, t in totals.items() if t.refused}
    short = {name: {arm: t.arms[arm].cases for arm in ARMS} for name, t in totals.items()
             if any(t.arms[arm].cases != config.seeds for arm in ARMS) and not t.refused}
    if unminimized:
        # No report before every failure has a minimized walk (p15-oracle-099 acceptance).
        write_json(config.work / "unminimized.json", {
            "schema": RECEIPT_SCHEMA + "-unminimized",
            "failures": [f.to_json() for f in unminimized],
            "minimized": [f.minimized for f in failures if f.minimized],
        })
        for failure in unminimized:
            print(f"walks: not minimized: {failure.switch} {failure.case}: {failure.error or 'its group leader failed'}")
        print(f"walks: no report: {len(unminimized)} failures are not minimized ({config.work / 'unminimized.json'})")
        return EXIT_REFUSED
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "sha": config.sha or "",
        "binary": config.binary,
        "host": host_info(),
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "seeds": {"first": config.first_seed, "count": config.seeds, "length": config.length, "chunk": config.chunk},
        "jobs": config.jobs,
        "minimize": "all" if config.minimize_all else "one per (switch, signature)",
        "switches": {name: t.to_json() for name, t in sorted(totals.items())},
        "failures": [f.to_json() for f in sorted(failures, key=lambda f: (f.switch, f.chunk, f.case))],
        "minimized": sorted({f.minimized for f in failures if f.minimized}),
        "refused": refused,
        "short": short,
        "wall_s": round(time.monotonic() - started, 3),
    }
    receipt["ok"] = not failures and not refused and not short
    write_report(config, receipt)
    print(f"walks: report {config.work / 'receipt.json'}; {len(failures)} failures, "
          f"{len(receipt['minimized'])} minimized walks in {config.commit_dir}")
    for path in receipt["minimized"]:
        print(f"  minimized: {path}")
    for name, reasons in refused.items():
        print(f"  refused: {name}: {'; '.join(reasons)}")
    if refused or short:
        return EXIT_REFUSED
    return 0 if not failures else 1


# ---------------------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="walks_scale.py", description="Daemon walks at scale on both switch arms.")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="walk every daemon switch on both arms, minimize failures, report")
    run.add_argument("--binary", required=True, help="cmux-tui built by linux_run.sh build (oracle profile)")
    run.add_argument("--sha", help="source SHA of the binary, recorded in the receipts")
    run.add_argument("--switch", action="append", default=[], help="daemon switch (default: every daemon switch)")
    run.add_argument("--seeds", type=int, default=DEFAULT_SEEDS)
    run.add_argument("--first-seed", type=int, default=1)
    run.add_argument("--length", type=int, default=DEFAULT_LENGTH)
    run.add_argument("--chunk", type=int, default=DEFAULT_CHUNK, help="walks per oracle.py diff (bounds disk)")
    run.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    run.add_argument("--work", type=Path, help=f"run directory (default {DEFAULT_WORK_BASE}/<utc time>)")
    run.add_argument("--commit-dir", type=Path, default=DEFAULT_COMMIT_DIR, help="where minimized walks go")
    run.add_argument("--minimize-all", action="store_true", help="minimize every failure, not one per signature")
    run.add_argument("--minimize-jobs", type=int, default=DEFAULT_MINIMIZE_JOBS)
    run.add_argument("--keep", action="store_true", help="keep the scratch corpus and checkpoint files")
    run.add_argument("--registry", type=Path, default=SWITCH_REGISTRY, help=argparse.SUPPRESS)
    pred = sub.add_parser("interesting", help="the ddmin test: exit 0 when CASE gives the signature")
    pred.add_argument("--binary", required=True)
    pred.add_argument("--switch", required=True)
    pred.add_argument("--signature-file", type=Path, required=True)
    pred.add_argument("--sha")
    pred.add_argument("--work", type=Path, default=DEFAULT_WORK_BASE / "predicate")
    pred.add_argument("case", type=Path)
    return parser


def resolve_work(work: Optional[Path]) -> Path:
    path = (work or DEFAULT_WORK_BASE / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())).resolve()
    if path == REPO or REPO in path.parents:
        raise UsageError(f"--work {path}: run output stays outside the checkout (spec 3G)")
    return path


def outside_queue_job(environ: Mapping[str, str]) -> bool:
    """True on the Linux VM outside a runnerd job: oracle.py runs cmux-tui suites only inside one."""
    return sys.platform.startswith("linux") and not environ.get("RUNNERD_JOB")


def main(argv: Optional[Sequence[str]] = None, cli: Optional[OracleCli] = None,
         environ: Optional[Mapping[str, str]] = None) -> int:
    args = build_parser().parse_args(argv)
    cli = cli or OracleCli()
    try:
        if args.command == "interesting":
            return run_predicate(cli, args)
        if outside_queue_job(os.environ if environ is None else environ):
            raise UsageError("on the Linux VM the walks run as one runnerd job: `linux_run.sh walks REF [-- OPTIONS]`")
        for name in ("seeds", "length", "chunk", "jobs", "minimize_jobs"):
            if getattr(args, name) < 1:
                raise UsageError(f"--{name.replace('_', '-')} must be >= 1")
        if args.first_seed < 0:
            raise UsageError("--first-seed must be >= 0")
        switches = daemon_switches(args.registry, args.switch)
        config = RunConfig(binary=args.binary, sha=args.sha, seeds=args.seeds, first_seed=args.first_seed,
                           length=args.length, chunk=args.chunk, jobs=args.jobs, work=resolve_work(args.work),
                           commit_dir=args.commit_dir.resolve(), minimize_all=args.minimize_all,
                           minimize_jobs=args.minimize_jobs, keep=args.keep)
        return perform_run(cli, config, switches)
    except UsageError as error:
        print(f"walks: {error}", file=sys.stderr)
        return 2
    except InfraError as error:
        print(f"walks: infrastructure: {error}", file=sys.stderr)
        return 2


def run_predicate(cli: OracleCli, args: argparse.Namespace) -> int:
    """An uncaught exception exits 1, which ddmin reads as "not interesting": every error is 2."""
    try:
        signature = read_json(args.signature_file)
        return interesting(cli, case_path=args.case, switch=args.switch, binary=args.binary, sha=args.sha,
                           signature=signature, work=args.work)
    except Exception as error:  # noqa: BLE001 - any failure of the test itself is PREDICATE_ERROR
        print(f"walks interesting: {type(error).__name__}: {error}", file=sys.stderr)
        return PREDICATE_ERROR


if __name__ == "__main__":
    sys.exit(main())
