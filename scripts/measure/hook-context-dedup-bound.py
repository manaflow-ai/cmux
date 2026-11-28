#!/usr/bin/env python3
"""Measure exact-block deduplication ceilings on a frozen hook-context window.

  python3 -I scripts/measure/hook-context-dedup-bound.py --snapshot SNAPSHOT \
    --workspace /path/to/leo-workspace --output NEW_RECEIPT.json
  cmux-ci run --class exclusive --measurement --label measure \
    --script tests/test_hook_context_dedup_bound.py --ref SHA

Consumes hook-context-window.py's immutable snapshot. Counts duplicate UTF-8
blocks within a compaction epoch and across a whole session, including delivery
history before the window. This is an optimistic byte ceiling, NOT safe policy:
identical pointers may name changed pages, and compaction may discard earlier
instructions. Never rewrites transcripts or claims instruction conservation.
Only aggregate counts are printed; transcript contents remain local.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def count_file(path, meter, since, data=None):
    turns, current = [], None
    session_seen, epoch_seen = set(), set()
    prompts = 0
    captured = path.read_bytes() if data is None else data
    for line in captured.decode("utf-8").splitlines():
        entry = json.loads(line)
        if meter.COMPACT_MARK in line:
            epoch_seen.clear()
        if meter.is_prompt(entry):
            prompts += 1
            if prompts == 1 and current is not None:
                current["at"] = meter.entry_time(entry)
            else:
                current = {"at": meter.entry_time(entry), "bytes": Counter(),
                           "session": Counter(), "epoch": Counter()}
                turns.append(current)
            continue
        attachment = entry.get("attachment") or {}
        if attachment.get("type") != "hook_additional_context" or entry.get("isSidechain"):
            continue
        if current is None:
            current = {"at": meter.entry_time(entry), "bytes": Counter(),
                       "session": Counter(), "epoch": Counter()}
            turns.append(current)
        content = attachment.get("content")
        for text in content if isinstance(content, list) else [content]:
            for source, block in meter.blocks(str(text or "")):
                raw = block.encode("utf-8")
                key = digest(raw)
                current["bytes"][source] += len(raw)
                for scope, seen in (("session", session_seen), ("epoch", epoch_seen)):
                    if key in seen:
                        current[scope][source] += len(raw)
                    seen.add(key)
    return [t for t in turns if t["at"] is not None and t["at"] >= since]


def summarize(turns):
    totals = {key: Counter() for key in ("bytes", "session", "epoch")}
    for turn in turns:
        for key in totals:
            totals[key].update(turn[key])
    total = sum(totals["bytes"].values())
    count = len(turns)
    result = {"turns": count, "total_bytes": total,
              "mean_bytes_per_turn": total / count if count else None}
    for scope in ("epoch", "session"):
        duplicate = sum(totals[scope].values())
        result[scope] = {"duplicate_bytes": duplicate,
                         "duplicate_by_source": dict(totals[scope]),
                         "remaining_bytes": total - duplicate,
                         "optimistic_mean_bytes_per_turn": (total - duplicate) / count if count else None}
    return result


def measure(snapshot, workspace):
    receipt_bytes = (snapshot / "receipt.json").read_bytes()
    receipt = json.loads(receipt_bytes)
    if receipt.get("schema") != "hook-context-window/v1" or "reports" not in receipt:
        raise ValueError("not a measured fixed-window snapshot")
    manifest_bytes = (snapshot / "manifest.json").read_bytes()
    if digest(manifest_bytes) != receipt["manifest_sha256"]:
        raise ValueError("manifest hash mismatch")
    meter_path = workspace / "tools/hook_context_bytes.py"
    if digest(meter_path.read_bytes()) != receipt["meter_sha256"]:
        raise ValueError("meter hash mismatch")
    sys.path.insert(0, str(workspace / "tools"))
    spec = importlib.util.spec_from_file_location("dedup_meter", meter_path)
    meter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(meter)
    since = meter.entry_time({"timestamp": receipt["window_start"]})
    if since is None:
        raise ValueError("invalid window start")
    turns = []
    for row in json.loads(manifest_bytes):
        if not row["selected"]:
            continue
        if Path(row["file"]).name != row["file"]:
            raise ValueError("invalid snapshot filename")
        path = snapshot / "transcripts" / row["file"]
        data = path.read_bytes()
        if len(data) != row["bytes"] or digest(data) != row["sha256"]:
            raise ValueError("transcript hash mismatch")
        turns.extend(count_file(path, meter, since, data))
    result = summarize(turns)
    recorded = receipt["reports"]["recorded"]
    if digest(meter_path.read_bytes()) != receipt["meter_sha256"]:
        raise ValueError("meter changed during measurement")
    if (result["turns"], result["total_bytes"], result["epoch"]["duplicate_bytes"]) != (
            recorded["turns"], recorded["total_bytes"], recorded["repeat_bytes"]):
        raise ValueError("counts disagree with source meter")
    return {"schema": "hook-context-dedup-bound/v1", "status": "theoretical-bound",
            "conservation_claim": False, "snapshot_receipt_sha256": digest(receipt_bytes),
            "script_sha256": digest(Path(__file__).read_bytes()),
            "meter_sha256": receipt["meter_sha256"], "window_start": receipt["window_start"],
            "window_end": receipt["window_end"], **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = measure(args.snapshot.resolve(), args.workspace.resolve())
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except (OSError, ValueError, KeyError) as exc:
        print(json.dumps({"status": "error", "error_type": type(exc).__name__}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
