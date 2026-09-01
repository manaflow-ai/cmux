#!/usr/bin/env python3
"""Focused subprocess regressions for durable Codex turn settlement."""

from __future__ import annotations

import tempfile
import traceback
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_codex_deferred_settlement_has_single_live_replay_claim,
    test_codex_deferred_settlement_replay_requires_exact_acknowledgement,
    test_codex_subagent_stop_replays_deferred_turn_settlement,
    test_structured_background_work_bounds_and_generation_owned_clear,
)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(
        prefix="cmux-codex-deferred-settlement-",
        dir="/tmp",
    ) as temporary_directory:
        root = Path(temporary_directory)
        for test in (
            test_codex_subagent_stop_replays_deferred_turn_settlement,
            test_codex_deferred_settlement_replay_requires_exact_acknowledgement,
            test_structured_background_work_bounds_and_generation_owned_clear,
            test_codex_deferred_settlement_has_single_live_replay_claim,
        ):
            try:
                test(cli_path, root)
            except Exception as exc:
                print(f"FAIL: {test.__name__}: {exc}")
                traceback.print_exc()
                return 1

    print("PASS: Codex deferred settlement is durable and single-owner")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
