#!/usr/bin/env python3
"""Pair a measured CEF binary with its generated V8 snapshots, retaining a receipt."""

import hashlib
import json
from pathlib import Path
import shutil
import sys


def pair_snapshots(source: Path, destination: Path) -> list[dict]:
    snapshots = {p.name: p for p in source.glob("*snapshot*.bin") if p.is_file()}
    existing = {p.name: p for p in destination.glob("*snapshot*.bin") if p.is_file()}
    # A different resource inventory needs a complete packaging comparison;
    # do not silently remove a runtime input or test a partial engine.
    if not snapshots or snapshots.keys() != existing.keys():
        raise ValueError(f"CEF snapshot inventory differs: source={sorted(snapshots)}, app={sorted(existing)}")
    receipt = []
    for name, path in sorted(snapshots.items()):
        before, after = existing[name].read_bytes(), path.read_bytes()
        receipt.append({"name": name, "before_bytes": len(before), "after_bytes": len(after),
                        "before_sha256": hashlib.sha256(before).hexdigest(),
                        "after_sha256": hashlib.sha256(after).hexdigest()})
        shutil.copy2(path, existing[name])
    return receipt


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: cef-snapshot-resources.py SOURCE_RESOURCES APP_RESOURCES RECEIPT_JSON")
    receipt = pair_snapshots(Path(sys.argv[1]), Path(sys.argv[2]))
    Path(sys.argv[3]).write_text(json.dumps(receipt, indent=2) + "\n")
