#!/usr/bin/env python3
"""Write a semantically identical, deterministic compact JSON resource."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path


def compact(source: Path, destination: Path) -> tuple[int, int]:
    with source.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    encoded = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return source.stat().st_size, len(encoded)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        raise SystemExit(f"usage: {argv[0]} SOURCE DESTINATION")
    before, after = compact(Path(argv[1]), Path(argv[2]))
    print(f"compact-json: {argv[1]} {before} -> {after} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
