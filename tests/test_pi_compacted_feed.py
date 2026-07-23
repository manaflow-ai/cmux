#!/usr/bin/env python3
"""Focused runtime regressions for Pi compacted Feed delivery."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_pi_compacted_feed_allows_brief_auth_delay,
    test_pi_compacted_feed_pipelines_bounded_acknowledged_batch,
    test_pi_compacted_feed_rejects_failed_server_ack,
    test_pi_compacted_post_tool_use_expands_to_distinct_frames,
    test_pi_feed_rejects_unconfirmed_server_ack,
    test_pi_feed_uses_resolved_explicit_workspace,
    test_pi_hook_rehomes_moved_explicit_surface,
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
    var observedConnectTimeouts: [TimeInterval] = []
    var observedTimeouts: [TimeInterval] = []

    func connectWithoutRetry(responseTimeout: TimeInterval? = nil) throws {{
        observedConnectTimeouts.append(responseTimeout ?? 0)
        Thread.sleep(forTimeInterval: 0.04)
    }}

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
    responseTimeout: 0.35
)
guard client.observedConnectTimeouts.count == 3 else {{
    fatalError("batch did not budget all three relay authentications: \\(client.observedConnectTimeouts)")
}}
guard client.observedTimeouts.count == 3 else {{
    fatalError("expected three relay sends, got \\(client.observedTimeouts)")
}}
guard zip(client.observedConnectTimeouts, client.observedTimeouts).allSatisfy({{ connect, response in
    connect > response
}}) else {{
    fatalError(
        "relay command reused its pre-authentication timeout: "
            + "\\(client.observedConnectTimeouts) -> \\(client.observedTimeouts)"
    )
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


def test_expander_preserves_newest_retained_summary(root: Path) -> None:
    source_path = Path(__file__).resolve().parents[1] / "CLI" / "PiCompactedFeedEventExpander.swift"
    source = source_path.read_text()
    source = "\n".join(
        line for line in source.splitlines()
        if line != "import Foundation"
    )
    harness_path = root / "CompactedFeedNewestHarness.swift"
    harness_path.write_text(
        f"""
import Foundation

{source}

let summaries: [[String: Any]] = (0..<64).map {{ index in
    [
        "session_id": "pi-expander-session",
        "tool_call_id": "tool-\\(index)",
        "tool_name": "bash",
    ]
}}
let requestLines = PiCompactedFeedEventExpander(
    agentPid: 42,
    workspaceId: "11111111-1111-1111-1111-111111111111"
).requestLines(from: [
    "session_id": "pi-expander-session",
    "cmux_compacted_terminal_omitted_count": 1,
    "cmux_compacted_terminal_events": summaries,
])
let toolCallIds = try requestLines.map {{ line -> String? in
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    let params = object?["params"] as? [String: Any]
    let event = params?["event"] as? [String: Any]
    return event?["tool_call_id"] as? String
}}
guard requestLines.count == 64 else {{
    fatalError("expected a bounded 64-request expansion, got \\(requestLines.count)")
}}
guard toolCallIds.contains("tool-63") else {{
    fatalError("overflow marker displaced the newest retained terminal event: \\(toolCallIds)")
}}

let relayRequestLines = PiCompactedFeedEventExpander(
    agentPid: 42,
    workspaceId: "11111111-1111-1111-1111-111111111111",
    maximumRequestCount: 2
).requestLines(from: [
    "session_id": "pi-expander-session",
    "cmux_compacted_terminal_omitted_count": 0,
    "cmux_compacted_terminal_events": summaries,
])
let relayToolCallIds = try relayRequestLines.map {{ line -> String? in
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    let params = object?["params"] as? [String: Any]
    let event = params?["event"] as? [String: Any]
    return event?["tool_call_id"] as? String
}}
guard relayRequestLines.count == 2,
      relayToolCallIds.contains("tool-63"),
      relayToolCallIds.contains("compacted-omitted-63") else {{
    fatalError("relay expansion was not bounded to newest plus overflow: \\(relayToolCallIds)")
}}
"""
    )
    binary_path = root / "compacted-feed-newest"
    compile_result = subprocess.run(
        ["swiftc", str(harness_path), "-o", str(binary_path)],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if compile_result.returncode != 0:
        raise AssertionError(
            "failed to compile compacted Feed newest-event harness: "
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
            "compacted Pi feed expansion did not preserve its newest retained summary: "
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
            test_expander_preserves_newest_retained_summary(root)
            test_pi_compacted_post_tool_use_expands_to_distinct_frames(cli_path, root)
            test_pi_compacted_feed_pipelines_bounded_acknowledged_batch(cli_path, root)
            test_pi_compacted_feed_rejects_failed_server_ack(cli_path, root)
            test_pi_compacted_feed_allows_brief_auth_delay(cli_path, root)
            test_pi_feed_rejects_unconfirmed_server_ack(cli_path, root)
            test_pi_hook_rehomes_moved_explicit_surface(cli_path, root)
            test_pi_feed_uses_resolved_explicit_workspace(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Pi compacted Feed delivery is authoritative, bounded, and acknowledged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
