#!/usr/bin/env python3
"""Freeze a fixed window of local hook transcripts and measure recorded/replayed bytes.

Run locally (never upload the output directory or transcript contents):
  python3 -I scripts/measure/hook-context-window.py --workspace /path/to/leo-workspace \
    --transcripts /path/to/.claude/projects --end 2026-11-27T21:20:00Z \
    --hours 24 --output /private/new-snapshot
Synthetic verification on CI, without private transcripts:
  cmux-ci run --class exclusive --measurement --label measure \
    --script tests/test_hook_context_window.py --ref SHA

The interval is inclusive [end-hours, end]. Keep timestamped records <= end,
including the full earlier delivery prefix; never stop at the first future record.
The existing meter's since filter selects TURN STARTS, not individual attachments.
The upper cutoff is record-based, so a turn crossing it is deliberately partial.
Untimed records are retained only when followed by an eligible timestamp and not
preceded by a future timestamp. Trailing/ambiguous untimed records are omitted and
counted, including compaction markers. Such reports are exploratory, not proof of
conservation. Malformed JSON/timestamps abort measurement with counts, never text.

Each file is read only to its initially observed byte length. A frozen snapshot is
immutable by this tool (existing output directories are refused); later appends
cannot change it. A new capture can include late backdated records and is a NEW
sample. This is a per-file capture, not an atomic snapshot of all active sessions.
Only aggregate receipt JSON is printed. Output files contain private transcripts;
keep them local. Source paths are represented by opaque hashes in the manifest.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp must be an ISO string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include timezone")
    return parsed.timestamp()


def freeze(data, start, end):
    """Return eligible bytes, window membership and content-free diagnostics."""
    kept, pending = [], []
    previous = None
    in_window = False
    counts = Counter()

    def omit_pending():
        counts["omitted_untimed"] += len(pending)
        counts["omitted_untimed_compactions"] += sum(b'"compact_boundary"' in x for x in pending)
        pending.clear()

    for line in data.splitlines(keepends=True):
        counts["input_records"] += 1
        if not line.endswith(b"\n"):
            counts["incomplete_records"] += 1
            continue
        try:
            entry = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            counts["malformed_json"] += 1
            continue
        if not isinstance(entry, dict):
            counts["non_object_records"] += 1
            continue
        if "timestamp" not in entry:
            pending.append(line)
            continue
        try:
            at = timestamp(entry["timestamp"])
        except (ValueError, OverflowError):
            counts["malformed_timestamps"] += 1
            continue
        if previous is not None and at < previous:
            counts["out_of_order_records"] += 1
        if at <= end:
            if previous is None or previous <= end:
                kept.extend(pending)
                pending.clear()
            else:
                omit_pending()
            kept.append(line)
            in_window |= at >= start
        else:
            omit_pending()
            counts["excluded_future_records"] += 1
        previous = at
    omit_pending()
    return b"".join(kept), in_window, dict(counts)


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def capture(transcripts, output, start, end):
    manifest, totals = [], Counter()
    paths = sorted(transcripts.rglob("*.jsonl"))
    for path in paths:
        # A stat-bound read ignores concurrent appends; shrink/replacement is an error.
        with path.open("rb") as stream:
            before = os.fstat(stream.fileno())
            data = stream.read(before.st_size)
            after = os.fstat(stream.fileno())
        if len(data) != before.st_size or after.st_size < before.st_size:
            raise ValueError("transcript shrank during capture")
        content, selected, diagnostics = freeze(data, start, end)
        totals.update(diagnostics)
        file_id = sha256(str(path.relative_to(transcripts)).encode())
        row = {"id": file_id, "captured_bytes": len(data), "captured_sha256": sha256(data),
               "selected": selected, "diagnostics": diagnostics}
        if selected:
            name = file_id + ".jsonl"
            (output / "transcripts" / name).write_bytes(content)
            row.update(file=name, bytes=len(content), sha256=sha256(content))
        manifest.append(row)
    return manifest, dict(totals)


def measure(workspace, transcripts, output, end, hours):
    start = end - hours * 3600
    meter_path = workspace / "tools/hook_context_bytes.py"
    meter_hash = sha256(meter_path.read_bytes())
    source_sha = subprocess.check_output(
        ["git", "-C", str(workspace), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(
        ["git", "-C", str(workspace), "status", "--porcelain", "--", "tools"], text=True).strip())
    # Refuse both an existing output and one beneath the input (recursive self-capture).
    if output == transcripts or transcripts in output.parents:
        raise ValueError("output must be outside transcripts")
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    (output / "transcripts").mkdir(mode=0o700)
    manifest, diagnostics = capture(transcripts, output, start, end)
    write_json(output / "manifest.json", manifest)
    receipt = {
        "schema": "hook-context-window/v1",
        "window_start": datetime.fromtimestamp(start, timezone.utc).isoformat(),
        "window_end": datetime.fromtimestamp(end, timezone.utc).isoformat(),
        "bounds": "inclusive; lower=turn-start, upper=record timestamp",
        "untimed_policy": "retain only before next eligible timestamp with no preceding future timestamp",
        "source_sha": source_sha, "source_tools_dirty": dirty,
        "meter_sha256": meter_hash,
        "wrapper_sha256": sha256(Path(__file__).read_bytes()),
        "manifest_sha256": sha256((output / "manifest.json").read_bytes()),
        "diagnostics": diagnostics,
        "conservation_claim": False,
    }
    invalid = sum(diagnostics.get(k, 0) for k in (
        "malformed_json", "non_object_records", "malformed_timestamps", "incomplete_records"))
    if invalid or not any(x["selected"] for x in manifest):
        receipt["status"] = "invalid-input" if invalid else "empty-window"
        write_json(output / "receipt.json", receipt)
        return receipt, 2
    sys.path.insert(0, str(workspace / "tools"))
    spec = importlib.util.spec_from_file_location("hook_context_window_meter", meter_path)
    meter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(meter)
    files = [str(output / "transcripts" / x["file"]) for x in manifest if x["selected"]]
    reports = {mode: meter.report(files, after=after, since=start)
               for mode, after in (("recorded", False), ("replay", True))}
    if sha256(meter_path.read_bytes()) != meter_hash:
        raise ValueError("meter changed during measurement")
    # Loss counters cover full prefixes; unknown hook bytes and ambiguous boundaries
    # prevent treating a zero loss count as a general conservation proof.
    receipt.update(status="exploratory", reports=reports)
    write_json(output / "receipt.json", receipt)
    return receipt, 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--transcripts", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--end", required=True)
    parser.add_argument("--hours", required=True, type=float)
    args = parser.parse_args()
    if not math.isfinite(args.hours) or args.hours <= 0:
        parser.error("hours must be finite and positive")
    if not args.transcripts.is_dir():
        parser.error("transcripts must be a directory")
    try:
        receipt, code = measure(args.workspace.resolve(), args.transcripts.resolve(),
                                args.output.resolve(), timestamp(args.end), args.hours)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        # Do not echo input paths, transcript content, or subprocess output.
        print(json.dumps({"status": "error", "error_type": type(exc).__name__}), file=sys.stderr)
        return 2
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
