#!/usr/bin/env python3
"""Create and verify trusted receipts for tests run on an exact source tree.

The fleet injects ``CMUX_CI_RECEIPT_SIGNING_KEY`` only while it owns a test
step.  The key never enters the receipt or the child test environment.  CI
verifies the HMAC over the canonical payload and then checks the requested
tree, job and command.  A missing or malformed receipt is an unknown result,
never a pass.  Set ``CMUX_CI_RECEIPT_PATH`` or a receipt directory variable
when publishing a result for a later consumer; discovery uses
``<directory>/<tree_sha>/<job>.json`` (with ``/`` and ``:`` replaced by ``_``).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import uuid


SCHEMA = "cmux-same-tree-receipt/v1"
HEX_SHA = 64


class ReceiptError(ValueError):
    pass


def _key(value: str | None) -> bytes:
    if not value:
        raise ReceiptError("trusted receipt key is unavailable")
    value = value.strip()
    try:
        if len(value) % 2 == 0 and all(c in "0123456789abcdefABCDEF" for c in value):
            decoded = bytes.fromhex(value)
        else:
            decoded = base64.b64decode(value, validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ReceiptError("trusted receipt key is not hex or base64") from exc
    if len(decoded) < 32:
        raise ReceiptError("trusted receipt key is shorter than 32 bytes")
    return decoded


def command_digest(command: str) -> str:
    if not isinstance(command, str) or not command.strip() or "\n" in command:
        raise ReceiptError("command must be one non-empty line")
    return hashlib.sha256(command.strip().encode("utf-8")).hexdigest()


def _valid_tree(value: object) -> bool:
    return (isinstance(value, str) and len(value) == 40
            and all(c in "0123456789abcdef" for c in value))


def _payload(receipt: dict) -> bytes:
    signed = {k: receipt[k] for k in (
        "schema", "tree_sha", "job", "command", "command_sha256", "result",
        "exit_code", "execution_id", "runner", "started_at", "finished_at", "signer",
    )}
    return json.dumps(signed, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _signature(receipt: dict, key: bytes) -> str:
    return hmac.new(key, _payload(receipt), hashlib.sha256).hexdigest()


def _tree(repo: Path) -> str:
    try:
        value = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ReceiptError(f"could not read source tree: {exc}") from exc
    if len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
        raise ReceiptError("git returned an invalid source tree")
    return value


def _tracked_state(repo: Path) -> str:
    """Return a stable digest of tracked worktree and index changes.

    The caller may already have unrelated edits (for example, a local checkout
    running this helper while preparing a commit), so receipt minting compares
    the state before and after the command instead of requiring a clean checkout.
    """
    try:
        worktree = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--binary", "HEAD", "--"],
        )
        index = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--cached", "--binary", "HEAD", "--"],
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ReceiptError(f"could not read tracked checkout state: {exc}") from exc
    return hashlib.sha256(b"worktree\0" + worktree + b"\0index\0" + index).hexdigest()


def _validate_shape(receipt: dict) -> None:
    if not isinstance(receipt, dict) or receipt.get("schema") != SCHEMA:
        raise ReceiptError("unsupported receipt schema")
    for field in ("tree_sha", "job", "command", "command_sha256", "result", "execution_id",
                  "runner", "started_at", "finished_at", "signature", "signer"):
        if not receipt.get(field):
            raise ReceiptError(f"receipt is missing {field}")
    if not _valid_tree(receipt["tree_sha"]):
        raise ReceiptError("receipt tree_sha is not a commit tree")
    for field in ("job", "command", "execution_id", "runner", "started_at", "finished_at",
                  "signature", "signer"):
        if not isinstance(receipt[field], str):
            raise ReceiptError(f"receipt {field} must be a string")
    if receipt["result"] != "passed" or receipt.get("exit_code") != 0:
        raise ReceiptError("receipt does not prove a passing command")
    if receipt["command_sha256"] != command_digest(receipt["command"]):
        raise ReceiptError("receipt command_sha256 does not match command")
    if not isinstance(receipt["signer"], str) or not receipt["signer"].startswith("fleet:"):
        raise ReceiptError("receipt signer is not a trusted fleet signer")


def verify(receipt: dict, *, tree: str, job: str, command: str, key: bytes) -> None:
    _validate_shape(receipt)
    expected = {"tree_sha": tree, "job": job, "command": command.strip(),
                "command_sha256": command_digest(command)}
    for field, value in expected.items():
        if receipt.get(field) != value:
            raise ReceiptError(f"receipt {field} does not match the requested check")
    supplied = receipt.get("signature", "")
    if not isinstance(supplied, str) or not hmac.compare_digest(supplied, _signature(receipt, key)):
        raise ReceiptError("receipt signature is invalid")


def filter_jobs(items: list[dict], *, tree: str, job_template: str,
                command_template: str, key: bytes | None) -> tuple[list[dict], int]:
    """Drop only jobs covered by a verified receipt before a matrix is allocated."""
    kept: list[dict] = []
    reused = 0
    for item in items:
        try:
            values = {field: item[field] for field in ("root",)}
            job = job_template.format(**values)
            command = command_template.format(**values)
            if key is None:
                raise ReceiptError("trusted receipt key is unavailable")
            path = next((candidate for candidate in candidates(tree, job) if candidate.is_file()), None)
            if path is None:
                raise ReceiptError("no receipt")
            verify(read_receipt(path), tree=tree, job=job, command=command, key=key)
        except (KeyError, ReceiptError):
            kept.append(item)
        else:
            reused += 1
    return kept, reused


def candidates(tree: str, job: str) -> list[Path]:
    paths: list[Path] = []
    explicit = os.environ.get("CMUX_CI_RECEIPT_PATH") or os.environ.get("CMUX_LOCAL_TEST_RECEIPT")
    if explicit:
        paths.append(Path(explicit))
    for name in ("CMUX_CI_RECEIPT_DIR", "CMUX_CI_RECEIPTS_DIR"):
        root = os.environ.get(name)
        if root:
            base = Path(root)
            safe = job.replace("/", "_").replace(":", "_")
            paths.extend((base / tree / f"{safe}.json", base / f"{tree}.json"))
    return list(dict.fromkeys(paths))


def read_receipt(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReceiptError(f"could not read receipt {path}: {exc}") from exc


def emit(*, path: Path, tree: str, job: str, command: str, exit_code: int, key: bytes,
         runner: str, started_at: str, finished_at: str) -> dict:
    if exit_code != 0:
        raise ReceiptError("only a successful command may mint a receipt")
    record = {
        "schema": SCHEMA,
        "tree_sha": tree,
        "job": job,
        "command": command.strip(),
        "command_sha256": command_digest(command),
        "result": "passed",
        "exit_code": 0,
        "execution_id": str(uuid.uuid4()),
        "runner": runner,
        "started_at": started_at,
        "finished_at": finished_at,
        "signer": f"fleet:{os.environ.get('CMUX_CI_RECEIPT_KEY_ID', 'default')}",
    }
    record["signature"] = _signature(record, key)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)
    return record


def run(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    tree = _tree(repo)
    if args.tree and args.tree != tree:
        print(f"same-tree-receipt: requested tree {args.tree} differs from checkout {tree}", file=sys.stderr)
        return 2
    try:
        before_state = _tracked_state(repo)
    except ReceiptError as error:
        print(f"same-tree-receipt: {error}", file=sys.stderr)
        return 2
    actual_command = shlex.join(args.command_argv)
    if args.command.strip() != actual_command:
        print("same-tree-receipt: command identity does not match the executed argv", file=sys.stderr)
        return 2
    started = str(time.time_ns())
    command_env = os.environ.copy()
    # The command is the untrusted part of a local/fleet run.  It may inspect
    # its environment, but it must never receive the key that can mint a
    # trusted receipt after it exits successfully.
    command_env.pop("CMUX_CI_RECEIPT_SIGNING_KEY", None)
    command_env.pop("CMUX_CI_RECEIPT_VERIFY_KEY", None)
    completed = subprocess.run(args.command_argv, cwd=repo, env=command_env)
    if completed.returncode == 0:
        try:
            after_state = _tracked_state(repo)
            after_tree = _tree(repo)
        except ReceiptError as error:
            print(f"same-tree-receipt: {error}", file=sys.stderr)
            return 2
        if before_state != after_state or after_tree != tree:
            print("same-tree-receipt: command passed but changed the source tree; no receipt minted",
                  file=sys.stderr)
            return 2
        try:
            emit(path=Path(args.receipt), tree=tree, job=args.job, command=args.command,
                 exit_code=0, key=_key(os.environ.get("CMUX_CI_RECEIPT_SIGNING_KEY")),
                 runner=os.environ.get("CMUX_CI_RUNNER_ID") or os.environ.get("RUNNER_NAME") or "unknown",
                 started_at=started, finished_at=str(time.time_ns()))
        except ReceiptError as error:
            print(f"same-tree-receipt: command passed but receipt was not minted: {error}", file=sys.stderr)
            return 2
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    check = sub.add_parser("verify")
    check.add_argument("--receipt", type=Path)
    check.add_argument("--tree", required=True)
    check.add_argument("--job", required=True)
    check.add_argument("--command", required=True)
    check.add_argument("--key-env", default="CMUX_CI_RECEIPT_VERIFY_KEY")
    check.add_argument("--discover", action="store_true")
    runner = sub.add_parser("run")
    runner.add_argument("--repo", default=".")
    runner.add_argument("--tree")
    runner.add_argument("--receipt", required=True)
    runner.add_argument("--job", required=True)
    runner.add_argument("--command", required=True)
    runner.add_argument("command_argv", nargs=argparse.REMAINDER)
    filter_parser = sub.add_parser("filter")
    filter_parser.add_argument("--tree", required=True)
    filter_parser.add_argument("--job-template", required=True)
    filter_parser.add_argument("--command-template", required=True)
    filter_parser.add_argument("--key-env", default="CMUX_CI_RECEIPT_VERIFY_KEY")
    args = parser.parse_args()
    if args.mode == "run":
        if args.command_argv[:1] == ["--"]:
            args.command_argv = args.command_argv[1:]
        if not args.command_argv:
            parser.error("run requires a command after --")
        return run(args)
    if args.mode == "filter":
        if not _valid_tree(args.tree):
            parser.error("filter requires a full lowercase tree SHA")
        try:
            items = json.load(sys.stdin)
            if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
                raise ValueError("jobs JSON must be a list of objects")
            key_value = os.environ.get(args.key_env)
            try:
                key = _key(key_value) if key_value else None
            except ReceiptError:
                key = None
            kept, reused = filter_jobs(items, tree=args.tree, job_template=args.job_template,
                                       command_template=args.command_template, key=key)
        except (ValueError, json.JSONDecodeError) as error:
            print(f"same-tree-receipt: invalid jobs JSON: {error}", file=sys.stderr)
            return 2
        print(json.dumps(kept, separators=(",", ":")))
        print(f"same-tree-receipt: reused {reused}/{len(items)} jobs", file=sys.stderr)
        return 0
    path = args.receipt
    if not _valid_tree(args.tree):
        print("same-tree-receipt: unknown (requested tree is not a full lowercase tree SHA)", file=sys.stderr)
        return 2
    if path is None and args.discover:
        path = next((candidate for candidate in candidates(args.tree, args.job) if candidate.is_file()), None)
    if path is None:
        print("same-tree-receipt: unknown (no receipt supplied)", file=sys.stderr)
        return 2
    try:
        verify(read_receipt(path), tree=args.tree, job=args.job, command=args.command, key=_key(os.environ.get(args.key_env)))
    except ReceiptError as error:
        print(f"same-tree-receipt: unknown ({error})", file=sys.stderr)
        return 2
    print(f"same-tree-receipt: verified {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
