#!/usr/bin/env python3
"""Smoke test for panel lifecycle anchor identity mapping.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        snapshot = c.panel_lifecycle()
        records = list(snapshot.get("records") or [])
        _must(records, f"panel_lifecycle returned no records: {snapshot}")

        anchored_records = [row for row in records if row.get("anchor")]
        _must(anchored_records, f"panel_lifecycle returned no anchored records: {snapshot}")

        seen_anchor_ids: set[str] = set()
        for row in anchored_records:
            anchor = dict(row.get("anchor") or {})
            anchor_id = anchor.get("anchorId")
            anchor_generation = int(anchor.get("anchorGeneration") or 0)
            geometry_revision = int(anchor.get("geometryRevision") or 0)

            _must(anchor_id, f"anchored record missing anchorId: {row}")
            _must(anchor_generation >= 1, f"anchorGeneration must be >= 1: {row}")
            _must(geometry_revision >= 1, f"geometryRevision must be >= 1: {row}")
            _must(
                anchor_id not in seen_anchor_ids,
                f"duplicate anchorId across snapshot rows: {anchor_id}",
            )
            seen_anchor_ids.add(anchor_id)

            if row.get("activeWindowMembership"):
                _must(
                    row.get("desiredVisible"),
                    f"activeWindowMembership without desiredVisible: {row}",
                )

    print(
        "PASS: panel lifecycle anchor mapping includes stable anchor ids and "
        f"generations (anchored={len(anchored_records)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
