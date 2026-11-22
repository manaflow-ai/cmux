#!/usr/bin/env python3
"""Verify the Neko gallery's pinned asset bytes and report licensed candidate coverage.

Use --ref SHA for the same measurement on a committed tree (including the base).
This measures reproducible review coverage, not runtime performance or visual quality.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = "design/icons/neko-candidates/"


def inventory(ref=None):
    def read(path):
        if ref:
            result = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT, capture_output=True)
            return result.stdout if result.returncode == 0 else None
        file = ROOT / path
        return file.read_bytes() if file.is_file() else None

    raw = read(DIRECTORY + "manifest.json")
    if raw is None:
        return {"licensed_gallery_candidates": 0}
    candidates = json.loads(raw)["candidates"]
    for candidate in candidates:
        for name, source in candidate["files"].items():
            data = read(DIRECTORY + source["path"])
            if data is None or hashlib.sha256(data).hexdigest() != source["sha256"]:
                raise ValueError(f"{candidate['id']} {name}: missing or changed bytes")
    return {"licensed_gallery_candidates": len(candidates)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref")
    args = parser.parse_args()
    print(json.dumps(inventory(args.ref), sort_keys=True))
