#!/usr/bin/env python3
"""Focused runtime regressions for Pi compacted Feed delivery."""

from __future__ import annotations

import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_pi_compacted_feed_pipelines_bounded_acknowledged_batch,
    test_pi_compacted_feed_rejects_failed_server_ack,
    test_pi_compacted_post_tool_use_expands_to_distinct_frames,
)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-pi-compacted-feed-", dir="/tmp") as td:
        root = Path(td)
        try:
            test_pi_compacted_post_tool_use_expands_to_distinct_frames(cli_path, root)
            test_pi_compacted_feed_pipelines_bounded_acknowledged_batch(cli_path, root)
            test_pi_compacted_feed_rejects_failed_server_ack(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Pi compacted Feed delivery is authoritative, bounded, and acknowledged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
