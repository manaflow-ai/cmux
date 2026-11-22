#!/usr/bin/env python3
"""Same-input receipts for the react-apps-check shards (ci-web.yml react-apps-check-shard).

Leo, 2026-11-22: "if it's really so big then you guys need to be hurrying up and thinking more innovatively".
A shard whose inputs are exactly the ones a green run of the same shard already had does not run again: it restores
that run's head results and uploads them as its own, so react-apps-base-check joins them as before.

The key is a sha256 over everything the shard's verdict is a function of:
  - the tree of the commit it tests (a pull request's merge commit): every file, so the webviews app, its lockfile,
    the shared packages and Swift sources its tests read, the runner scripts and this workflow are all in it;
  - the tree of that commit's first parent (the merge parent): a pull request is judged against it (new reds only,
    PR-scoped rules);
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


def key(shard: str, handoff: Path, config: str, rev: str = "HEAD") -> str:
    if not shard.isdigit():
        raise RuntimeError(f"bad shard {shard!r}")
    if not handoff.is_dir():
        raise RuntimeError(f"no handoff dir {handoff}")
    h = hashlib.sha256()
    h.update(f"{PREFIX}\nshard={shard}\nconfig={config}\ntree={tree(rev)}\nparent={tree(rev + '^1')}\n".encode())
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
            print(f"key={key(args.shard, args.handoff, args.config, args.rev)}")
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
