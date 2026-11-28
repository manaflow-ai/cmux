#!/usr/bin/env python3
"""Same-input receipts for the react-apps-check shards (ci-web.yml react-apps-check-shard).

Leo, 2026-11-22: "if it's really so big then you guys need to be hurrying up and thinking more innovatively".
A shard whose inputs are exactly the ones a green run of the same shard already had does not run again: it restores
that run's head results and uploads them as its own, so react-apps-base-check joins them as before.

The key is a sha256 over everything the shard's verdict is a function of:
  - the input tree of the commit it tests (a pull request's merge commit): the path, mode and blob id of every file
    whose change runs react-apps-check at all (web_subareas.is_react_input: the webviews app, its lockfile, the runner
    scripts, the web bundle inputs and the workflow files), so a push that changes nothing there, or a base that
    moved elsewhere, keeps the key (Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period.").
    Before it the key hashed every file, so a rebase onto a moved base never hit. Any doubt (the input list cannot
    be derived) keys the whole tree as before, and --whole-tree / CI_REACT_RECEIPT_INPUT_SCOPE=0 does it on purpose;
  - the same input tree of that commit's first parent (the merge parent): a pull request is judged against it (new
    reds only, PR-scoped rules);
  - every file of the run's handoff from web-subarea-scope (the duration manifest that splits the shards, the base's
    known reds, the picked shards' file lists): the same tree split another way runs other files;
  - the shard's matrix entry and the run's configuration (the full-ci label, the base branch, the runner OS and arch).
Anything else that can change a verdict (the runner image, a browser the image ships, the network) is outside it,
as it is outside a re-run.

A receipt is written only for a green shard: every gate step passed and Test webviews passed with every test in its
results green. Only same-repository pull requests read or write, so the Actions cache's scope applies: a pull request
reads entries its own runs and its base branch wrote, never another pull request's. Any error fails open: no key, no
hit, and the shard runs in full. `vars.CI_REACT_SHARD_RECEIPT == '0'` turns lookups off.

    react_shard_receipt.py key --shard N --handoff DIR --config TEXT [--rev REV]   -> `key=...` (empty on any error)
    react_shard_receipt.py write --key K --results DIR --out DIR [--run URL]       -> the receipt dir to save; exit 1 if not green
    react_shard_receipt.py check --key K --receipt DIR --results DIR              -> `hit=true|false`; on a hit, the results
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

VERSION = "v1"
PREFIX = f"react-shard-receipt-{VERSION}"
RESULTS = "webviews-head-results.json"
RECEIPT = "receipt.json"
# What react-apps-base-check's join reads from a shard's head results (webviews_test_history.join_heads): the result
# map, the runner copy, and the summaries. A green shard's other raw logs are not read.
KEEP_LOGS = ("summary", "first-summary")


def tree(rev: str) -> str:
    out = subprocess.run(["git", "rev-parse", "--verify", "-q", f"{rev}^{{tree}}"], capture_output=True, text=True)
    value = out.stdout.strip()
    if out.returncode != 0 or len(value) != 40:
        raise RuntimeError(f"no tree for {rev}")
    return value


def input_tree(rev: str) -> str:
    """A hash of the files a change to which runs react-apps-check (web_subareas.is_react_input, the router's own
    list): path, mode and blob id of each at `rev`. Content-addressed: a commit that changes only other files, or a
    base that moved elsewhere, has the same input tree. Any doubt raises, and the caller keys the whole tree."""
    import os
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import web_subareas
    out = subprocess.run(["git", "ls-tree", "-r", "-z", rev], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout:
        raise RuntimeError(f"no file list for {rev}")
    root = Path(os.getcwd())
    h = hashlib.sha256()
    count = 0
    for entry in out.stdout.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        if web_subareas.is_react_input(path, root):
            h.update(f"{meta}\t{path}\n".encode())
            count += 1
    if count == 0:
        raise RuntimeError(f"no input file at {rev}")
    return h.hexdigest()


def trees(rev: str, scoped: bool) -> str:
    """The key's tree lines: the input subtree of the commit and of its first parent, else (scoped off, or any
    failure) the whole trees as before."""
    if scoped:
        try:
            tree(rev + "^1")  # a commit with no parent has no key either way
            return f"inputs={input_tree(rev)}\nparent-inputs={input_tree(rev + '^1')}\n"
        except (RuntimeError, OSError, ImportError, SyntaxError) as error:
            print(f"::warning title=react shard receipt::input tree unavailable ({error}); keying the whole tree")
    return f"tree={tree(rev)}\nparent={tree(rev + '^1')}\n"


def key(shard: str, handoff: Path, config: str, rev: str = "HEAD", scoped: bool = True) -> str:
    if not shard.isdigit():
        raise RuntimeError(f"bad shard {shard!r}")
    if not handoff.is_dir():
        raise RuntimeError(f"no handoff dir {handoff}")
    h = hashlib.sha256()
    h.update(f"{PREFIX}\nshard={shard}\nconfig={config}\n{trees(rev, scoped)}".encode())
    for path in sorted(p for p in handoff.rglob("*") if p.is_file()):
        h.update(f"file={path.relative_to(handoff).as_posix()}\n".encode())
        h.update(hashlib.sha256(path.read_bytes()).hexdigest().encode() + b"\n")
    return f"{PREFIX}-shard{shard}-{h.hexdigest()[:40]}"


def all_green(results: Path) -> bool:
    try:
        found = json.loads((results / RESULTS).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(found, dict) and bool(found) and all(v is True for v in found.values())


def write(k: str, results: Path, out: Path, run: str = "") -> None:
    if not k.startswith(PREFIX + "-"):
        raise RuntimeError(f"bad key {k!r}")
    if not all_green(results):
        raise RuntimeError(f"{results / RESULTS}: not every test is green; no receipt")
    if out.exists():
        shutil.rmtree(out)
    (out / "results").mkdir(parents=True)
    shutil.copyfile(results / RESULTS, out / "results" / RESULTS)
    if (results / "runner").is_dir():
        shutil.copytree(results / "runner", out / "results" / "runner")
    for name in KEEP_LOGS:
        log = results / "raw-logs" / name
        if log.is_file():
            (out / "results" / "raw-logs").mkdir(exist_ok=True)
            shutil.copyfile(log, out / "results" / "raw-logs" / name)
    (out / RECEIPT).write_text(json.dumps({"key": k, "run": run}, sort_keys=True) + "\n", encoding="utf-8")


def check(k: str, receipt: Path, results: Path) -> tuple[bool, str]:
    """(hit, the run that passed). A hit copies the receipt's results into RESULTS."""
    try:
        meta = json.loads((receipt / RECEIPT).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False, ""
    if not isinstance(meta, dict) or meta.get("key") != k or not all_green(receipt / "results"):
        return False, ""
    if results.exists():
        shutil.rmtree(results)
    shutil.copytree(receipt / "results", results)
    return True, str(meta.get("run") or "")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("key")
    a.add_argument("--shard", required=True)
    a.add_argument("--handoff", required=True, type=Path)
    a.add_argument("--config", required=True)
    a.add_argument("--rev", default="HEAD")
    a.add_argument("--whole-tree", action="store_true", help="key the whole trees, not the input subtree")
    w = sub.add_parser("write")
    w.add_argument("--key", required=True)
    w.add_argument("--results", required=True, type=Path)
    w.add_argument("--out", required=True, type=Path)
    w.add_argument("--run", default="")
    c = sub.add_parser("check")
    c.add_argument("--key", required=True)
    c.add_argument("--receipt", required=True, type=Path)
    c.add_argument("--results", required=True, type=Path)
    args = ap.parse_args(argv)
    if args.cmd == "key":
        try:
            print(f"key={key(args.shard, args.handoff, args.config, args.rev, not args.whole_tree)}")
        except (OSError, RuntimeError) as error:
            print(f"::warning title=react shard receipt::no key ({error}); the shard runs in full")
            print("key=")
        return 0
    if args.cmd == "write":
        try:
            write(args.key, args.results, args.out, args.run)
        except (OSError, RuntimeError) as error:
            print(f"no receipt: {error}", file=sys.stderr)
            return 1
        return 0
    try:
        hit, run = check(args.key, args.receipt, args.results)
    except OSError as error:
        print(f"::warning title=react shard receipt::unreadable receipt ({error}); the shard runs in full")
        hit, run = False, ""
    if hit:
        print(f"::notice title=react shard receipt::{args.key} passed in {run or 'an earlier run'}; "
              "its results stand for this shard and its steps are skipped")
    print(f"hit={str(hit).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
