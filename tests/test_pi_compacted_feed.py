#!/usr/bin/env python3
"""Focused runtime regressions for Pi compacted Feed delivery."""

from __future__ import annotations

import tempfile
import subprocess
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_pi_compacted_feed_allows_brief_auth_delay,
    test_pi_compacted_feed_pipelines_bounded_acknowledged_batch,
    test_pi_compacted_feed_rejects_failed_server_ack,
    test_pi_compacted_post_tool_use_expands_to_distinct_frames,
)


def test_relay_batch_uses_one_response_deadline(root: Path) -> None:
    source_path = Path(__file__).resolve().parents[1] / "CLI" / "SocketClient+SingleLineBatch.swift"
    source = source_path.read_text()
    source = "\n".join(
        line for line in source.splitlines()
        if line not in {"import Darwin", "import Foundation"}
    )
    harness_path = root / "RelayBatchDeadlineHarness.swift"
    harness_path.write_text(
        f"""
import Darwin
import Foundation

struct CLIError: Error {{
    let message: String
}}

final class SocketClient {{
    let isRelayBacked = true
    let socketFD: Int32 = -1
    var observedTimeouts: [TimeInterval] = []

    func send(command: String, responseTimeout: TimeInterval? = nil) throws -> String {{
        let timeout = responseTimeout ?? 0
        observedTimeouts.append(timeout)
        Thread.sleep(forTimeInterval: 0.04)
        return "OK"
    }}

    func capabilityWrappedCommand(_ command: String) -> String {{ command }}
    func configureSocketWriteSafety(_ timeout: TimeInterval) throws {{}}
    func writeAllNonBlocking(
        _ data: Data,
        deadline: Date,
        timeoutMessage: String,
        failureMessage: String
    ) throws {{}}
    func configureReceiveTimeout(_ timeout: TimeInterval) throws {{}}
}}

{source}

let client = SocketClient()
_ = try client.sendSingleLineBatch(
    commands: ["first", "second", "third"],
    responseTimeout: 0.2
)
guard client.observedTimeouts.count == 3 else {{
    fatalError("expected three relay sends, got \\(client.observedTimeouts)")
}}
guard client.observedTimeouts[0] > client.observedTimeouts[1],
      client.observedTimeouts[1] > client.observedTimeouts[2] else {{
    fatalError("relay batch reused its full timeout: \\(client.observedTimeouts)")
}}
"""
    )
    binary_path = root / "relay-batch-deadline"
    compile_result = subprocess.run(
        ["swiftc", str(harness_path), "-o", str(binary_path)],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if compile_result.returncode != 0:
        raise AssertionError(
            "failed to compile relay batch deadline harness: "
            f"{compile_result.stdout}\n{compile_result.stderr}"
        )
    result = subprocess.run(
        [str(binary_path)],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if result.returncode != 0:
        raise AssertionError(
            "relay-backed compacted Feed batch did not share one response deadline: "
            f"{result.stdout}\n{result.stderr}"
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
            test_relay_batch_uses_one_response_deadline(root)
            test_pi_compacted_post_tool_use_expands_to_distinct_frames(cli_path, root)
            test_pi_compacted_feed_pipelines_bounded_acknowledged_batch(cli_path, root)
            test_pi_compacted_feed_rejects_failed_server_ack(cli_path, root)
            test_pi_compacted_feed_allows_brief_auth_delay(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Pi compacted Feed delivery is authoritative, bounded, and acknowledged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
