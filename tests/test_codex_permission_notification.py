#!/usr/bin/env python3
"""Focused regression for Codex PermissionRequest user notifications."""

from __future__ import annotations

import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_codex_permission_request_requests_gated_user_notification,
)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        with tempfile.TemporaryDirectory(
            prefix="cmux-codex-permission-notification-",
            dir="/tmp",
        ) as temporary_directory:
            test_codex_permission_request_requests_gated_user_notification(
                cli_path,
                Path(temporary_directory),
            )
    except Exception as error:
        print(f"FAIL: {error}")
        return 1

    print("PASS: Codex PermissionRequest requests a gated user notification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
