#!/usr/bin/env python3
"""The oracle's app diffs on the fleet: both sides of every shard on one mini, then one comparison.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3F.1 and 3G, tasks 050 and 008. Stdlib plus the
sibling oracle.py and diff.py, Python 3.9+, safe under `python3 -I`. Fleet work goes through `cmux-ci` only
(never maclease): one `cmux-ci run --class isolated --script scripts/measure/oracle.sh` step per shard.

Same-host pairing (task 008). A step builds both apps (the two refs, or one ref for a switch) and runs side
A's shard and then side B's shard back to back on its one host, so every case of the shard has its A and its
B from that host, OS version and display. Each side's receipt records that host (oracle.py host_info). Before
comparing, this file checks each shard's pair: a shard whose A and B receipts name different hosts is refused
as host-mismatch (exit 3), and diff.py checks every case again after the shards merge, so a cross-host or
cross-OS pair never reaches the comparison. Different shards may land on different minis; a case is never
compared across them. This is Pinpoint's rule of running both changes of a comparison on one bot
(chromium/src third_party/catapult/dashboard/dashboard/pinpoint/models/quest/run_test.py: later executions
are pinned to the bot of the first, because results from two devices are not comparable).

Builds: the step builds in the bench configuration with reload.sh (`--config bench`), the split-spring way,
because `cmux-ci build cmux` has no bench config; a worker keeps built apps in its shared cache per commit.

Waiting. A shard's step key is a digest of its whole request, so running the same command again joins the
same steps instead of submitting new ones; `OUT/shards/<i>/step.json` keeps each step id, and a rerun with the
same --out waits for that step (`cmux-ci wait ID`) instead of submitting. A step that ran past --timeout is
cancelled by cmux-ci (exit 124) and reported; nothing here resubmits. Only a new --attempt N (part of the key)
asks for new steps, for example after a worker lost a step.

Usage:
  fleet.py diff (--base SHA --head SHA | --switch NAME [--ref SHA] | --arm launch-config [--ref SHA])
                [--suite S] [--filter GLOB] [--repeat N] [--retry-limit N] [--batch-limit K] [--shuffle]
                [--seed N] [--build bench] [--shards N] [--timeout SECONDS] [--attempt N] [--out DIR] [--json]
      (`oracle.py diff --product app ...` runs this.) Exit codes are oracle.py diff's: 0 no unexplained
      divergence, 1 divergences, 2 bad input or a failed step, 3 refused (host-mismatch, incomplete shards).
  fleet.py compare OUT [--json]   compare the shards already downloaded into OUT again (no fleet)
  fleet.py --selftest             the offline tests (fleet_test.py)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import diff  # noqa: E402
import oracle  # noqa: E402

REPO = oracle.REPO
SCRIPT = "scripts/measure/oracle.sh"
ARTIFACT = "artifacts/oracle/shard.tgz"
STEP_CLASS = "isolated"
DEFAULT_SHARDS = 6
DEFAULT_TIMEOUT_S = 4 * 3600
STEP_LINE = re.compile(r"^cmux-ci: step (\S+) \(")
SHA = re.compile(r"^[0-9a-f]{40}$")
# cmux-ci run's own exit codes (no worker takes steps, queue timeout, superseded, run timeout, interrupted).
STEP_INFRA = {69: "no fleet worker takes CI steps", 75: "still queued after --queue-timeout",
              76: "superseded by a newer head", 124: "ran past --timeout (cancelled)",
              130: "interrupted: rerun the same command to wait for the same steps"}
EXIT_FAILED = 2


class FleetError(Exception):
    """A request fleet.py cannot run, or a shard that gave no result."""


# Runs a cmux-ci command; calls on_line with each output line; returns its exit code.
Runner = Callable[[Sequence[str], Callable[[str], None]], int]


@dataclass(frozen=True)
class Request:
    mode: str  # refs | switch | launch-config
    ref: str  # the commit every step checks out: the head of a refs diff, else the one build
    base: Optional[str]
    switch: Optional[str]
    labels: Tuple[str, str]
    selection: Tuple[str, ...]  # oracle.py run arguments shared by both sides and every shard
    shards: int
    timeout_s: int
    attempt: int = 1

    def step_args(self, index: int) -> List[str]:
        """oracle.sh's arguments for shard `index`."""
        side = {"refs": f"--base={self.base}", "switch": f"--switch={self.switch}",
                "launch-config": "--arm=launch-config"}[self.mode]
        return ["pair", side, f"--shard={index}/{self.shards}", *self.selection]

    def key(self, index: int) -> str:
        """The step's idempotency key: equal requests join one step (cmux-ci keys are at most 120 bytes)."""
        request = json.dumps([self.mode, self.ref, self.base, self.switch, list(self.selection), self.shards,
                              self.attempt])
        digest = hashlib.sha256(request.encode()).hexdigest()[:12]
        return f"oracle-{self.mode}-{(self.base or self.switch or 'lc')[:12]}-{self.ref[:12]}-{digest}-s{index}of{self.shards}"


@dataclass
class Shard:
    index: int
    key: str
    directory: Path
    step: Optional[str] = None
    code: Optional[int] = None
    error: Optional[str] = None
    hosts: Dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> Dict[str, Any]:
        return {"index": self.index, "key": self.key, "step": self.step, "code": self.code, "error": self.error,
                "hosts": self.hosts}


def run_command(command: Sequence[str], on_line: Callable[[str], None]) -> int:
    """The real Runner: cmux-ci from PATH, stdout and stderr merged, line by line."""
    proc = subprocess.Popen(list(command), cwd=str(REPO), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    assert proc.stdout is not None
    for line in proc.stdout:
        on_line(line.rstrip("\n"))
    return proc.wait()


def resolve(ref: str) -> str:
    try:
        sha = oracle.resolve_commit(ref)
    except oracle.UsageError as error:
        raise FleetError(str(error)) from None
    if not SHA.match(sha):
        raise FleetError(f"{ref}: resolved to {sha!r}, not a 40-character commit")
    return sha


def request_from_args(args: argparse.Namespace, resolve_ref: Callable[[str], str] = resolve) -> Request:
    if args.product != "app":
        raise FleetError(f"--product {args.product}: fleet.py runs the app product; cmux-tui products run on the VM")
    if args.shards < 1 or args.attempt < 1:
        raise FleetError("--shards and --attempt must be at least 1")
    modes = [bool(args.base or args.head), bool(args.switch), args.arm == "launch-config"]
    if sum(modes) != 1:
        raise FleetError("diff needs exactly one of --base/--head, --switch NAME or --arm launch-config")
    base: Optional[str] = None
    if args.base or args.head:
        if not (args.base and args.head):
            raise FleetError("--base and --head go together")
        mode, labels = "refs", ("base", "head")
        base, ref = resolve_ref(args.base), resolve_ref(args.head)
    else:
        ref = resolve_ref(args.ref or "HEAD")
        mode, labels = ("switch", oracle.ARMS) if args.switch else ("launch-config", ("default", "launch-config"))
    if args.switch and args.switch not in oracle.load_switch_registry():
        raise FleetError(f"--switch {args.switch}: no plans/cmux-next/refactor-switches/{args.switch}.json")
    selection: List[str] = [f"--build={args.build}"]
    selection += [f"--suite={value}" for value in args.suite or []]
    selection += [f"--filter={value}" for value in args.filter or []]
    for name in ("repeat", "retry_limit", "batch_limit", "seed"):
        value = getattr(args, name)
        if value is not None:
            selection.append(f"--{name.replace('_', '-')}={value}")
    if args.shuffle and args.seed is None:
        # One seed for both sides of every shard, taken from the request so the same command rejoins its steps.
        request = json.dumps([mode, ref, base, args.switch, selection, args.attempt]).encode()
        selection.append(f"--seed={int(hashlib.sha256(request).hexdigest()[:8], 16) % (2**31 - 1) + 1}")
    return Request(mode, ref, base, args.switch, labels, tuple(selection), args.shards, args.timeout, args.attempt)


def run_command_line(request: Request, shard: Shard) -> List[str]:
    return ["cmux-ci", "run", "--class", STEP_CLASS, "--script", SCRIPT, "--ref", request.ref, "--key", shard.key,
            "--no-supersede", "--artifact", ARTIFACT, "--timeout", str(request.timeout_s),
            *[f"--arg={value}" for value in request.step_args(shard.index)]]


class Fleet:
    """Submits (or rejoins) every shard's step, downloads its runs and checks each pair's host."""

    def __init__(self, runner: Runner = run_command, emit: Callable[[str], None] = print,
                 resolve_ref: Callable[[str], str] = resolve) -> None:
        self.runner = runner
        self.emit = emit
        self.resolve_ref = resolve_ref
        self.lock = threading.Lock()

    def say(self, text: str) -> None:
        with self.lock:
            self.emit(text)

    def shards(self, request: Request, out: Path) -> List[Shard]:
        return [Shard(i, request.key(i), out / "shards" / str(i)) for i in range(request.shards)]

    def run(self, request: Request, out: Path) -> List[Shard]:
        shards = self.shards(request, out)
        threads = [threading.Thread(target=self.run_shard, args=(request, shard), daemon=True) for shard in shards]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        return shards

    def run_shard(self, request: Request, shard: Shard) -> None:
        try:
            self.fetch_shard(request, shard)
        except FleetError as error:
            shard.error = str(error)
        except OSError as error:
            shard.error = f"{type(error).__name__}: {error}"
        if shard.error:
            self.say(f"[s{shard.index}/{request.shards}] {shard.error}")

    def fetch_shard(self, request: Request, shard: Shard) -> None:
        shard.directory.mkdir(parents=True, exist_ok=True)
        if pair_dirs(shard.directory):
            self.say(f"[s{shard.index}/{request.shards}] already downloaded")
            return
        record = shard.directory / "step.json"
        saved = read_json(record) if record.is_file() else {}
        log = (shard.directory / "step.log").open("a", encoding="utf-8")
        try:
            def on_line(line: str) -> None:
                log.write(line + "\n")
                log.flush()
                match = STEP_LINE.match(line)
                if match and shard.step is None:
                    shard.step = match.group(1)
                    write_json(record, {"key": shard.key, "step": shard.step, "ref": request.ref})
                self.say(f"[s{shard.index}/{request.shards}] {line}")

            if saved.get("key") == shard.key and saved.get("step"):
                shard.step = str(saved["step"])  # a step this request already submitted: wait, never resubmit
                shard.code = self.runner(["cmux-ci", "wait", shard.step], on_line)
            else:
                shard.code = self.runner(run_command_line(request, shard), on_line)
        finally:
            log.close()
        if shard.code != 0:
            reason = STEP_INFRA.get(shard.code or 0, f"oracle.sh exited {shard.code}")
            where = f"; cmux-ci log {shard.step}" if shard.step else ""
            raise FleetError(f"step gave no runs: {reason}{where}")
        if shard.step is None:
            raise FleetError("cmux-ci printed no step id")
        archive = shard.directory / "shard.tgz"
        if self.runner(["cmux-ci", "artifact", shard.step, str(archive)], lambda line: None) != 0:
            raise FleetError(f"cannot download the artifact of step {shard.step}")
        extract(archive, shard.directory)
        if not pair_dirs(shard.directory):
            raise FleetError(f"the artifact of step {shard.step} has no a/receipt.json and b/receipt.json")


def pair_dirs(directory: Path) -> Optional[Tuple[Path, Path]]:
    a, b = directory / "a", directory / "b"
    return (a, b) if (a / "receipt.json").is_file() and (b / "receipt.json").is_file() else None


def extract(archive: Path, target: Path) -> None:
    """Unpacks a step's tarball: regular files and dirs only, every member inside `target`."""
    try:
        with tarfile.open(archive, "r:gz") as tar:
            members = tar.getmembers()
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                    raise FleetError(f"{archive}: refused member {member.name!r}")
            for member in members:
                destination = target.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                assert source is not None
                with source, destination.open("wb") as handle:
                    shutil.copyfileobj(source, handle)
    except (tarfile.TarError, EOFError) as error:
        raise FleetError(f"{archive}: not a gzip tarball ({error})") from None


def read_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise FleetError(f"{path}: unreadable ({error})") from None
    if not isinstance(value, dict):
        raise FleetError(f"{path}: not an object")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def pairing_problems(shard: Shard) -> List[str]:
    """Why shard's A and B did not run on one host (diff.py's same-host keys); fills shard.hosts."""
    dirs = pair_dirs(shard.directory)
    if dirs is None:
        return ["no runs"]
    a, b = (read_json(d / "receipt.json").get("host") for d in dirs)
    shard.hosts = {"a": a, "b": b}
    return diff.host_mismatch(a if isinstance(a, dict) else None, b if isinstance(b, dict) else None)


def compare(request_doc: Dict[str, Any], shards: List[Shard], out: Path, *, as_json: bool,
            emit: Callable[[str], None] = print) -> int:
    """Checks each shard's pair, then merges the shards of each side and compares them through oracle.py."""
    failed = [shard for shard in shards if shard.error or not pair_dirs(shard.directory)]
    mismatched = {}
    for shard in shards:
        if shard.error or not pair_dirs(shard.directory):
            continue
        problems = pairing_problems(shard)
        if problems:
            mismatched[f"shard {shard.index}"] = problems
    labels = tuple(request_doc["labels"])
    document = {"schema": "cmux-oracle-fleet-v1", "request": request_doc, "shards": [s.to_json() for s in shards],
                "comparison": None}
    if failed:
        document["verdict"] = "failed"
        write_json(out / "fleet.json", document)
        emit("oracle fleet: no result from " + ", ".join(f"shard {s.index} ({s.error or 'no runs'})" for s in failed))
        return EXIT_FAILED
    if mismatched:
        document.update(verdict="host-mismatch", mismatched=mismatched)
        write_json(out / "fleet.json", document)
        emit("oracle fleet: host-mismatch: a shard's two sides ran on different hosts, OS versions or displays")
        for where, problems in sorted(mismatched.items()):
            emit(f"  {where}: {', '.join(problems)}")
        return oracle.EXIT_REFUSED
    sides = []
    for position in (0, 1):
        dirs = [pair_dirs(shard.directory)[position] for shard in shards]  # type: ignore[index]
        view, errors = oracle.merge_runs(dirs, require_complete=True)
        if errors:
            document["verdict"] = "refused"
            write_json(out / "fleet.json", document)
            emit(f"oracle fleet: {labels[position]} shards do not merge: " + "; ".join(errors))
            return oracle.EXIT_REFUSED
        sides.append(view)
    registry = oracle.load_switch_registry()
    if request_doc["mode"] == "switch":
        expected = oracle.switch_expected_files(registry, [request_doc["switch"]])
    elif request_doc["mode"] == "launch-config":
        expected = oracle.switch_expected_files(registry, oracle.resolve_switches(registry, None, "launch-config"))
    else:
        expected = []
    code = oracle.compare_views(
        sides[0], sides[1], a_dir=oracle.write_merged(sides[0], out / "a-merged"),
        b_dir=oracle.write_merged(sides[1], out / "b-merged"), out=out, labels=labels, partial=False,
        expected=expected, rules=oracle.comparison_rules(sides[1], Path(request_doc["expectations_root"])),
        as_json=as_json)
    document["verdict"] = {0: "pass", 1: "divergent", oracle.EXIT_REFUSED: "refused"}.get(code, "internal-error")
    document["comparison"] = str(out / "comparison.json")
    write_json(out / "fleet.json", document)
    return code


def request_document(request: Request, expectations_root: Path) -> Dict[str, Any]:
    return {"mode": request.mode, "ref": request.ref, "base": request.base, "switch": request.switch,
            "labels": list(request.labels), "selection": list(request.selection), "shards": request.shards,
            "attempt": request.attempt, "keys": [request.key(i) for i in range(request.shards)],
            "expectations_root": str(expectations_root)}


# ---------------------------------------------------------------------------------------------------------
# CLI


# oracle.py diff options that have no meaning here: the step builds the apps from the refs and runs the
# repository's corpus, Expectations and state roots at the ref.
UNSUPPORTED = ("--binary", "--base-binary", "--head-binary", "--tag", "--corpus", "--state-base", "--flaky-out",
               "--dry-run", "--run-id", "--jobs", "--shard", "--partial", "--fresh", "--base-run", "--head-run",
               "--baselines", "--baselines-root", "--platform")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="oracle app diffs on the fleet, both sides of a shard on one host")
    parser.add_argument("--selftest", action="store_true", help="run fleet_test.py")
    sub = parser.add_subparsers(dest="command")
    run = sub.add_parser("diff", help="build and run both sides of every shard on one mini each, then compare")
    run.add_argument("--product", default="app")
    run.add_argument("--base")
    run.add_argument("--head")
    run.add_argument("--switch")
    run.add_argument("--arm", choices=["launch-config"])
    run.add_argument("--ref", help="the commit of a --switch or --arm launch-config diff (default HEAD)")
    run.add_argument("--suite", action="append")
    run.add_argument("--filter", action="append")
    run.add_argument("--repeat", type=int)
    run.add_argument("--retry-limit", type=int)
    run.add_argument("--batch-limit", type=int)
    run.add_argument("--shuffle", action="store_true")
    run.add_argument("--seed", type=int)
    run.add_argument("--build", choices=oracle.BUILDS, default="bench")
    run.add_argument("--shards", type=int, default=DEFAULT_SHARDS, help=f"steps, one host each (default {DEFAULT_SHARDS})")
    run.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S, help="seconds a step may run, from its claim")
    run.add_argument("--attempt", type=int, default=1,
                     help="a new number makes new steps; the same request and attempt always rejoins its steps")
    run.add_argument("--expectations-root", type=Path, default=oracle.DEFAULT_EXPECTATIONS_ROOT)
    run.add_argument("--out", type=Path, help="output dir outside the checkout (default /tmp/oracle/runs/fleet-<id>)")
    run.add_argument("--json", action="store_true")
    again = sub.add_parser("compare", help="compare the shards already in OUT again")
    again.add_argument("out", type=Path)
    again.add_argument("--json", action="store_true")
    return parser


def cmd_diff(args: argparse.Namespace, fleet: Fleet) -> int:
    request = request_from_args(args, fleet.resolve_ref)
    if fleet.runner is run_command and shutil.which("cmux-ci") is None:
        raise FleetError("cmux-ci is not on PATH (install: python3 build-fleet/install-client.py --prefix ~/.local)")
    out = args.out or oracle.DEFAULT_OUT_BASE / ("fleet-" + oracle.new_run_id())
    oracle.check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    request_doc = request_document(request, args.expectations_root)
    previous = out / "request.json"
    if previous.is_file() and read_json(previous).get("keys") != request_doc["keys"]:
        raise FleetError(f"{out} holds another request's shards; pass a new --out")
    write_json(previous, request_doc)
    shards = fleet.run(request, out)
    return compare(request_doc, shards, out, as_json=args.json, emit=fleet.say)


def cmd_compare(args: argparse.Namespace) -> int:
    request_doc = read_json(args.out / "request.json")
    shards = [Shard(i, key, args.out / "shards" / str(i)) for i, key in enumerate(request_doc["keys"])]
    for shard in shards:
        saved = shard.directory / "step.json"
        if saved.is_file():
            shard.step = read_json(saved).get("step")
    return compare(request_doc, shards, args.out, as_json=args.json)


def main(argv: Optional[List[str]] = None, fleet: Optional[Fleet] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()
    if argv[:1] == ["diff"]:
        given = sorted({arg.split("=", 1)[0] for arg in argv if arg.split("=", 1)[0] in UNSUPPORTED})
        if given:
            print(f"fleet: {', '.join(given)}: not for fleet app diffs (the step builds both refs and runs the "
                  "corpus at the ref; use --shards N for sharding)", file=sys.stderr)
            return EXIT_FAILED
    args = parser.parse_args(argv)
    if args.selftest:
        import fleet_test

        return fleet_test.main()
    try:
        if args.command == "diff":
            return cmd_diff(args, fleet or Fleet())
        if args.command == "compare":
            return cmd_compare(args)
    except (FleetError, oracle.UsageError) as error:
        print(f"fleet: {error}", file=sys.stderr)
        return EXIT_FAILED
    parser.print_help(sys.stderr)
    return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
