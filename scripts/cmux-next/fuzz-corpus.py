#!/usr/bin/env python3
"""The stored fuzz corpus of each target: pull, push back minimized, coverage history, regressions.

ClusterFuzz keeps one persistent corpus per fuzz target, starts every run from it, prunes it
(libFuzzer -merge=1) and tracks each target's coverage so a fuzzer that stops growing gets work
(src/clusterfuzz/_internal/bot/tasks/utasks/corpus_pruning_task.py, fuzz_task.py). This is that
store for cmux (plans/cmux-next/chrome-parity/p10-stability.md, task 183). rust-fuzz.sh calls it;
the stability lab's fuzz lanes (stability-lanes.json) carry a store between fleet hosts as one
tarball (export / import), the step's --artifact.

A store is a directory per fuzz family (cmux-tui, swift, ...):

    <store>/inputs/<target>/<sha1>        one corpus input per file, named by its SHA-1 as libFuzzer
                                          names corpus files. CMUX_FUZZ_CORPUS=<store>/inputs feeds a
                                          CmuxFuzzSupport suite the same files (Corpus.swift).
    <store>/meta/<target>.json            {"target", "generation", "count", "bytes", "run", "updated"}
    <store>/meta/<target>.history.jsonl   one row per run: {"run", "at", "kind", "edges", ...}
    <store>/.lock                         flock held while a command reads or writes the store

Commands:
  default-store [--family F]   print the store of a family: $CMUX_FUZZ_CORPUS_STORE/<family>, else the fleet
                               host cache /Users/Shared/cmux-build-fleet/cache/fuzz-corpus/<family> when this
                               user owns its parent, else ${XDG_CACHE_HOME:-~/.cache}/cmux/fuzz-corpus/<family>.
  pull --store S --into DIR [--receipt FILE] TARGET...
                               copy each target's stored inputs into DIR/<target> and print the count (the run's
                               log shows that it started from the store). The receipt records the generation each
                               target had, for push.
  push --store S --target T --from DIR [--receipt FILE] [--run ID] [--fuzz-log LOG]
                               store DIR (the run's -merge=1 output) as T's corpus. When another run pushed T after
                               this run's pull (the generation moved), the inputs are added to the stored ones
                               instead, so no run loses another's finds; the next merge minimizes them. --fuzz-log
                               adds the run's libFuzzer cov/ft to the history (kind "fuzz").
  record-coverage --store S --target T --run ID --llvm-cov-json FILE
                               add a weekly llvm-cov summary (`llvm-cov export -summary-only`) to the history
                               (kind "llvm-cov"; edges = covered regions).
  quality --store S [--runs 3] [--kind llvm-cov] [--json] [--file-issues --repo OWNER/NAME [--dry-run]]
                               list the targets whose last --runs records of --kind cover no more edges than the
                               first of them (flat coverage: the fuzzer needs a dictionary, seeds or a better
                               target). --file-issues keeps one open issue per flat target (label fuzz-quality),
                               found in one batched `gh issue list`, commented once per new run.
  regress --target T --input FILE [--corpus-dir DIR]
                               check a crash input in as a regression next to its fix: DIR/<T>/regress-<sha1[:16]>
                               (default DIR cmux-tui/fuzz/corpus, which seeds.py replays on every run). Refuses an
                               input over 64 KiB: minimize it first (rust-fuzz.sh --minimize-crash).
  check [--repo R]             every checked-in corpus or regression file is at most 64 KiB (exit 1 otherwise).
  export --store S --out TAR   pack the store (inputs and meta) as a .tar.gz; prints its sha256.
  import --store S --in TAR    add a packed store to S: inputs are added, histories joined by run, and a target
                               whose inputs changed gets a new generation.

Exit 0 on success, 1 when check or quality finds something, 2 on a usage or store error.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Protocol

ROOT = Path(__file__).resolve().parents[2]
MAX_CHECKED_IN_BYTES = 64 * 1024
FLEET_CACHE_PARENT = Path("/Users/Shared/cmux-build-fleet/cache")
QUALITY_LABEL = "fuzz-quality"
TARGET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
INPUT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# libFuzzer's status line: "#123  NEW    cov: 456 ft: 789 corp: 12/3456b ..."
STATUS_LINE = re.compile(r"^#\d+\s+\S+\s+cov: (\d+) ft: (\d+) corp: (\d+)/")


class CorpusError(Exception):
    """A store, input or argument that cannot be used; the message says which and why."""


# MARK: - Store


@dataclass(frozen=True)
class Store:
    root: Path

    def inputs(self, target: str) -> Path:
        return self.root / "inputs" / checked_target(target)

    def meta(self, target: str) -> Path:
        return self.root / "meta" / f"{checked_target(target)}.json"

    def history(self, target: str) -> Path:
        return self.root / "meta" / f"{checked_target(target)}.history.jsonl"

    def targets(self) -> list[str]:
        directory = self.root / "inputs"
        names = {p.name for p in directory.iterdir() if p.is_dir()} if directory.is_dir() else set()
        meta = self.root / "meta"
        if meta.is_dir():
            names |= {p.name[: -len(".json")] for p in meta.glob("*.json")}
            names |= {p.name[: -len(".history.jsonl")] for p in meta.glob("*.history.jsonl")}
        return sorted(n for n in names if TARGET_NAME.match(n))

    def read_meta(self, target: str) -> dict:
        path = self.meta(target)
        if not path.is_file():
            return {"target": target, "generation": 0, "count": 0, "bytes": 0}
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            raise CorpusError(f"{path} is not JSON: {error}") from None
        if not isinstance(data, dict) or not isinstance(data.get("generation"), int):
            raise CorpusError(f"{path} has no integer generation")
        return data

    def read_history(self, target: str) -> list[dict]:
        path = self.history(target)
        if not path.is_file():
            return []
        rows = []
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise CorpusError(f"{path}:{number} is not JSON: {error}") from None
            if isinstance(row, dict):
                rows.append(row)
        return rows

    def write_meta(self, target: str, meta: dict) -> None:
        atomic_write(self.meta(target), json.dumps(meta, sort_keys=True) + "\n")

    def append_history(self, target: str, row: dict) -> None:
        path = self.history(target)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / ".lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)


def checked_target(target: str) -> str:
    if not TARGET_NAME.match(target):
        raise CorpusError(f"'{target}' is not a fuzz target name (letters, digits, '.', '-', '_')")
    return target


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        handle.write(text)
    os.replace(handle.name, path)


def input_files(directory: Path) -> list[Path]:
    """The corpus inputs of a directory: regular files, hidden ones skipped, as libFuzzer and FuzzCorpus read them."""
    if not directory.is_dir():
        return []
    return sorted(p for p in directory.iterdir() if p.is_file() and not p.is_symlink() and not p.name.startswith("."))


def sha1_name(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_store(family: str, environ: dict[str, str] | None = None, fleet_parent: Path = FLEET_CACHE_PARENT) -> Path:
    environ = os.environ if environ is None else environ
    checked_target(family)
    if environ.get("CMUX_FUZZ_CORPUS_STORE"):
        return Path(environ["CMUX_FUZZ_CORPUS_STORE"]) / family
    if fleet_parent.is_dir() and not fleet_parent.is_symlink() and fleet_parent.stat().st_uid == os.getuid() \
            and os.access(fleet_parent, os.W_OK):
        return fleet_parent / "fuzz-corpus" / family
    cache = Path(environ.get("XDG_CACHE_HOME") or Path(environ.get("HOME", str(Path.home()))) / ".cache")
    return cache / "cmux" / "fuzz-corpus" / family


# MARK: - pull / push


def pull(store: Store, into: Path, targets: list[str]) -> dict[str, dict]:
    receipt: dict[str, dict] = {}
    with store.locked():
        for target in targets:
            meta = store.read_meta(target)
            destination = into / checked_target(target)
            destination.mkdir(parents=True, exist_ok=True)
            count = size = 0
            for path in input_files(store.inputs(target)):
                data = path.read_bytes()
                count += 1
                size += len(data)
                copy = destination / path.name
                if not copy.exists():
                    copy.write_bytes(data)
            receipt[target] = {"generation": meta["generation"], "count": count, "bytes": size}
            if count:
                print(f"fuzz-corpus: {target}: {count} stored inputs ({size} bytes, generation "
                      f"{meta['generation']}) from {store.root}")
            else:
                print(f"fuzz-corpus: {target}: no stored corpus in {store.root}; starting from seeds")
    return receipt


def fuzz_stats(log: Path) -> dict | None:
    """The last libFuzzer status line of a run's log: edges (cov), features (ft) and corpus size."""
    if not log.is_file():
        return None
    last = None
    for line in log.read_text(errors="replace").splitlines():
        match = STATUS_LINE.match(line)
        if match:
            last = match
    if last is None:
        return None
    return {"edges": int(last.group(1)), "features": int(last.group(2)), "corpus": int(last.group(3))}


def push(store: Store, target: str, source: Path, pulled_generation: int | None, run: str,
         fuzz_log: Path | None = None) -> dict:
    if not source.is_dir():
        raise CorpusError(f"{source} is not a directory: nothing to push for {target}")
    files = input_files(source)
    with store.locked():
        meta = store.read_meta(target)
        current = store.inputs(target)
        raced = pulled_generation is not None and meta["generation"] != pulled_generation
        current.parent.mkdir(parents=True, exist_ok=True)
        staged = Path(tempfile.mkdtemp(dir=current.parent, prefix=f".{target}.new-"))
        names: set[str] = set()
        keep = [*input_files(current)] if raced else []
        for path in (*keep, *files):
            data = path.read_bytes()
            name = sha1_name(data)
            if name not in names:
                (staged / name).write_bytes(data)
                names.add(name)
        old = None
        if current.exists():
            old = current.with_name(f".{target}.old-{os.getpid()}")
            os.replace(current, old)
        os.replace(staged, current)
        if old is not None:
            shutil.rmtree(old, ignore_errors=True)
        stored = input_files(current)
        size = sum(p.stat().st_size for p in stored)
        updated = {"target": target, "generation": meta["generation"] + 1, "count": len(stored),
                   "bytes": size, "run": run, "updated": now_iso()}
        store.write_meta(target, updated)
        row = {"run": run, "at": updated["updated"], "kind": "fuzz", "count": len(stored), "bytes": size,
               "merged_with_concurrent_run": raced}
        stats = fuzz_stats(fuzz_log) if fuzz_log else None
        if stats:
            row.update(stats)
        store.append_history(target, row)
    how = "added to the corpus another run pushed" if raced else "stored"
    print(f"fuzz-corpus: {target}: {len(stored)} inputs ({size} bytes) {how}, generation {updated['generation']}")
    return updated


def record_coverage(store: Store, target: str, run: str, summary: Path) -> dict:
    try:
        data = json.loads(summary.read_text())
        totals = data["data"][0]["totals"]
        regions = totals["regions"]
        lines = totals["lines"]
    except (OSError, json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
        raise CorpusError(f"{summary} is not an llvm-cov export summary: {error}") from None
    row = {"run": run, "at": now_iso(), "kind": "llvm-cov", "edges": int(regions["covered"]),
           "regions": int(regions["count"]), "lines_covered": int(lines["covered"]), "lines": int(lines["count"])}
    with store.locked():
        store.append_history(checked_target(target), row)
    print(f"fuzz-corpus: {target}: llvm-cov {row['edges']}/{row['regions']} regions, "
          f"{row['lines_covered']}/{row['lines']} lines")
    return row


# MARK: - quality


@dataclass(frozen=True)
class Flat:
    target: str
    kind: str
    runs: list[dict]

    @property
    def edges(self) -> int:
        return int(self.runs[-1]["edges"])

    @property
    def latest_run(self) -> str:
        return str(self.runs[-1].get("run", ""))

    def title(self) -> str:
        return f"fuzz-quality: {self.target} coverage flat over {len(self.runs)} runs"

    def body(self) -> str:
        rows = "\n".join(f"| {r.get('run', '?')} | {r.get('at', '?')} | {r['edges']} |" for r in self.runs)
        return (f"The `{self.target}` fuzz target covered no new edges ({self.kind}) in its last {len(self.runs)} "
                f"runs, so its fuzzer needs work: a dictionary, seeds past the first checks, or a target that "
                f"reaches more of the decoder (ClusterFuzz's fuzzer-quality signal).\n\n"
                f"| run | at | edges |\n| --- | --- | --- |\n{rows}\n\n"
                f"Written by scripts/cmux-next/fuzz-corpus.py quality (plans/cmux-next/chrome-parity/"
                f"p10-stability.md, task 183). Comment instead of editing this body.")


def flat_targets(store: Store, runs: int, kind: str) -> list[Flat]:
    if runs < 2:
        raise CorpusError("--runs needs at least 2 records to call coverage flat")
    flat = []
    for target in store.targets():
        rows = [r for r in store.read_history(target) if r.get("kind") == kind and isinstance(r.get("edges"), int)]
        window = rows[-runs:]
        if len(window) == runs and max(r["edges"] for r in window) <= window[0]["edges"]:
            flat.append(Flat(target, kind, window))
    return flat


class GitHub(Protocol):
    def list_quality_issues(self) -> list[dict]: ...
    def ensure_label(self) -> None: ...
    def create_issue(self, title: str, body: str) -> int: ...
    def comment(self, number: int, body: str) -> None: ...


class GhCli:
    """gh, as the glaeda-gh read rules want it: one batched issue list per invocation, no polling."""

    def __init__(self, repo: str) -> None:
        self.repo = repo

    def _gh(self, *args: str) -> str:
        done = subprocess.run(["gh", *args, "--repo", self.repo], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            raise CorpusError(f"gh {' '.join(args[:2])} failed: {done.stderr.strip()}")
        return done.stdout

    def list_quality_issues(self) -> list[dict]:
        return json.loads(self._gh("issue", "list", "--label", QUALITY_LABEL, "--state", "open",
                                   "--limit", "500", "--json", "number,title"))

    def ensure_label(self) -> None:
        self._gh("label", "create", QUALITY_LABEL, "--force", "--color", "c5def5",
                 "--description", "A fuzz target whose coverage stopped growing (fuzz-corpus.py quality)")

    def create_issue(self, title: str, body: str) -> int:
        url = self._gh("issue", "create", "--title", title, "--body", body, "--label", QUALITY_LABEL).strip()
        return int(url.rstrip("/").rsplit("/", 1)[-1])

    def comment(self, number: int, body: str) -> None:
        self._gh("issue", "comment", str(number), "--body", body)


def file_quality_issues(store: Store, flat: list[Flat], github: GitHub, dry_run: bool) -> list[str]:
    """One open issue per flat target, commented once per new latest run (noted in the target's meta)."""
    actions = []
    open_issues = {}
    for issue in github.list_quality_issues():
        match = re.match(r"^fuzz-quality: (\S+) ", issue.get("title", ""))
        if match:
            open_issues.setdefault(match.group(1), int(issue["number"]))
    labelled = False
    for item in flat:
        with store.locked():
            meta = store.read_meta(item.target)
        if meta.get("quality_noted_run") == item.latest_run:
            continue
        number = open_issues.get(item.target)
        if number is None:
            actions.append(f"create issue for {item.target}")
            if not dry_run:
                if not labelled:
                    github.ensure_label()
                    labelled = True
                number = github.create_issue(item.title(), item.body())
        else:
            actions.append(f"comment on #{number} for {item.target}")
            if not dry_run:
                github.comment(number, f"Still flat at {item.edges} edges after run {item.latest_run}.")
        if not dry_run:
            with store.locked():
                meta = store.read_meta(item.target)
                meta["quality_noted_run"] = item.latest_run
                store.write_meta(item.target, meta)
    return actions


# MARK: - regressions and size check


def regress(target: str, source: Path, corpus_dir: Path) -> Path:
    data = source.read_bytes()
    if len(data) > MAX_CHECKED_IN_BYTES:
        raise CorpusError(f"{source} is {len(data)} bytes, over the {MAX_CHECKED_IN_BYTES}-byte limit of a "
                          f"checked-in input; minimize it first "
                          f"(scripts/cmux-next/rust-fuzz.sh --minimize-crash {target} {source})")
    directory = corpus_dir / checked_target(target)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"regress-{sha1_name(data)[:16]}"
    path.write_bytes(data)
    print(f"fuzz-corpus: {target}: regression input {path} ({len(data)} bytes); commit it with the fix")
    return path


def checked_in_corpus_files(repo: Path) -> list[Path]:
    """Tracked files under a fuzz corpus or a FuzzRegressions directory."""
    listed = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, check=True).stdout
    paths = []
    for raw in listed.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode(errors="surrogateescape")
        parts = rel.split("/")
        in_corpus = any(parts[i] == "fuzz" and parts[i + 1] == "corpus" for i in range(len(parts) - 2))
        if in_corpus or "FuzzRegressions" in parts[:-1]:
            paths.append(repo / rel)
    return paths


def oversized(paths: list[Path]) -> list[tuple[Path, int]]:
    return [(p, p.stat().st_size) for p in paths if p.is_file() and p.stat().st_size > MAX_CHECKED_IN_BYTES]


# MARK: - export / import


def export_store(store: Store, out: Path) -> str:
    out.parent.mkdir(parents=True, exist_ok=True)
    with store.locked():
        with tarfile.open(out, "w:gz") as tar:
            for target in store.targets():
                for path in input_files(store.inputs(target)):
                    tar.add(path, arcname=f"inputs/{target}/{path.name}", recursive=False)
                for path in (store.meta(target), store.history(target)):
                    if path.is_file():
                        tar.add(path, arcname=f"meta/{path.name}", recursive=False)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"fuzz-corpus: exported {store.root} to {out} sha256 {digest}")
    return digest


def packed_members(archive: Path) -> Iterator[tuple[str, str, bytes]]:
    """(kind, name, bytes) of each member, kind "input:<target>" or "meta"; anything else is refused."""
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            if member.isdir():
                continue
            parts = member.name.split("/")
            if not member.isfile():
                raise CorpusError(f"{archive}: {member.name} is not a regular file")
            if len(parts) == 3 and parts[0] == "inputs" and TARGET_NAME.match(parts[1]) and INPUT_NAME.match(parts[2]):
                kind = f"input:{parts[1]}"
            elif len(parts) == 2 and parts[0] == "meta" and TARGET_NAME.match(parts[1]):
                kind = "meta"
            else:
                raise CorpusError(f"{archive}: {member.name} is not inputs/<target>/<file> or meta/<file>")
            handle = tar.extractfile(member)
            yield kind, parts[-1], handle.read() if handle else b""


def packed_json(archive: Path, name: str, data: str | bytes) -> object:
    try:
        return json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise CorpusError(f"{archive}: meta/{name} is not JSON: {error}") from None


def import_store(store: Store, archive: Path) -> dict[str, int]:
    added: dict[str, int] = {}
    histories: dict[str, list[dict]] = {}
    metas: dict[str, dict] = {}
    with store.locked():
        for kind, name, data in packed_members(archive):
            if kind.startswith("input:"):
                target = kind.split(":", 1)[1]
                directory = store.inputs(target)
                directory.mkdir(parents=True, exist_ok=True)
                path = directory / sha1_name(data)
                if not path.exists():
                    path.write_bytes(data)
                    added[target] = added.get(target, 0) + 1
                else:
                    added.setdefault(target, 0)
            elif name.endswith(".history.jsonl"):
                lines = data.decode(errors="replace").splitlines()
                rows = [packed_json(archive, name, line) for line in lines if line.strip()]
                histories[name[: -len(".history.jsonl")]] = [r for r in rows if isinstance(r, dict)]
            elif name.endswith(".json"):
                meta = packed_json(archive, name, data)
                metas[name[: -len(".json")]] = meta if isinstance(meta, dict) else {}
        for target, rows in histories.items():
            seen = {(r.get("run"), r.get("kind")) for r in store.read_history(target)}
            for row in rows:
                if (row.get("run"), row.get("kind")) not in seen:
                    store.append_history(target, row)
        for target in sorted(set(added) | set(metas)):
            local = store.read_meta(target)
            packed = metas.get(target, {})
            stored = input_files(store.inputs(target))
            generation = max(local["generation"], int(packed.get("generation", 0)))
            if added.get(target):
                generation += 1
            local.update({"target": target, "generation": generation, "count": len(stored),
                          "bytes": sum(p.stat().st_size for p in stored), "updated": now_iso()})
            store.write_meta(target, local)
    for target, count in sorted(added.items()):
        print(f"fuzz-corpus: {target}: {count} new inputs from {archive}")
    return added


# MARK: - CLI


def read_receipt(path: str | None) -> dict:
    if not path or not Path(path).is_file():
        return {}
    data = json.loads(Path(path).read_text())
    return data if isinstance(data, dict) else {}


def main(argv: list[str] | None = None, github: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("default-store")
    p.add_argument("--family", default="cmux-tui")
    p = commands.add_parser("pull")
    p.add_argument("--store", required=True)
    p.add_argument("--into", required=True)
    p.add_argument("--receipt")
    p.add_argument("targets", nargs="+")
    p = commands.add_parser("push")
    p.add_argument("--store", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--from", dest="source", required=True)
    p.add_argument("--receipt")
    p.add_argument("--run", default="")
    p.add_argument("--fuzz-log")
    p = commands.add_parser("record-coverage")
    p.add_argument("--store", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--run", required=True)
    p.add_argument("--llvm-cov-json", required=True)
    p = commands.add_parser("quality")
    p.add_argument("--store", required=True)
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--kind", default="llvm-cov", choices=["llvm-cov", "fuzz"])
    p.add_argument("--json", action="store_true")
    p.add_argument("--file-issues", action="store_true")
    p.add_argument("--repo", default="manaflow-ai/cmux")
    p.add_argument("--dry-run", action="store_true")
    p = commands.add_parser("regress")
    p.add_argument("--target", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--corpus-dir", default=str(ROOT / "cmux-tui/fuzz/corpus"))
    p = commands.add_parser("check")
    p.add_argument("--repo", default=str(ROOT))
    p = commands.add_parser("export")
    p.add_argument("--store", required=True)
    p.add_argument("--out", required=True)
    p = commands.add_parser("import")
    p.add_argument("--store", required=True)
    p.add_argument("--in", dest="archive", required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == "default-store":
            print(default_store(args.family))
            return 0
        if args.command == "check":
            found = oversized(checked_in_corpus_files(Path(args.repo)))
            for path, size in found:
                print(f"fuzz-corpus: {path} is {size} bytes, over {MAX_CHECKED_IN_BYTES}", file=sys.stderr)
            if not found:
                print(f"fuzz-corpus: every checked-in corpus file is at most {MAX_CHECKED_IN_BYTES} bytes")
            return 1 if found else 0
        if args.command == "regress":
            regress(args.target, Path(args.input), Path(args.corpus_dir))
            return 0
        store = Store(Path(args.store))
        if args.command == "pull":
            receipt = pull(store, Path(args.into), args.targets)
            if args.receipt:
                merged = read_receipt(args.receipt) | receipt
                atomic_write(Path(args.receipt), json.dumps(merged, sort_keys=True) + "\n")
            return 0
        if args.command == "push":
            pulled = read_receipt(args.receipt).get(args.target, {}).get("generation")
            push(store, args.target, Path(args.source), pulled, args.run,
                 Path(args.fuzz_log) if args.fuzz_log else None)
            return 0
        if args.command == "record-coverage":
            record_coverage(store, args.target, args.run, Path(args.llvm_cov_json))
            return 0
        if args.command == "export":
            export_store(store, Path(args.out))
            return 0
        if args.command == "import":
            import_store(store, Path(args.archive))
            return 0
        if args.command == "quality":
            flat = flat_targets(store, args.runs, args.kind)
            if args.json:
                print(json.dumps([{"target": f.target, "kind": f.kind, "edges": f.edges,
                                   "runs": [r.get("run") for r in f.runs]} for f in flat]))
            else:
                for item in flat:
                    print(f"fuzz-corpus: {item.target}: flat at {item.edges} edges over {len(item.runs)} "
                          f"{item.kind} runs")
            if args.file_issues and flat:
                for action in file_quality_issues(store, flat, github or GhCli(args.repo), args.dry_run):
                    print(f"fuzz-corpus: {'would ' if args.dry_run else ''}{action}")
            return 1 if flat else 0
    except CorpusError as error:
        print(f"fuzz-corpus: {error}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
