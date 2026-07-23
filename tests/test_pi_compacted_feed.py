#!/usr/bin/env python3
"""Focused runtime regressions for Pi compacted Feed delivery."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    test_pi_compacted_feed_allows_brief_auth_delay,
    test_pi_compacted_feed_sends_bounded_acknowledged_batch,
    test_pi_compacted_feed_rejects_failed_server_ack,
    test_pi_compacted_post_tool_use_sends_one_ordered_batch,
    test_pi_feed_rejects_missing_explicit_workspace,
    test_pi_feed_rejects_unconfirmed_server_ack,
    test_pi_feed_uses_resolved_explicit_workspace,
    test_pi_hook_rehomes_moved_explicit_surface,
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
let request = PiCompactedFeedEventExpander(
    agentPid: 42,
    workspaceId: "11111111-1111-1111-1111-111111111111",
    surfaceId: "22222222-2222-2222-2222-222222222222"
).acknowledgedBatchRequest(from: [
    "session_id": "pi-expander-session",
    "cmux_compacted_terminal_omitted_count": 1,
    "cmux_compacted_terminal_events": summaries,
])
guard let request else {{ fatalError("expected compacted Feed batch request") }}
let object = try JSONSerialization.jsonObject(with: Data(request.line.utf8)) as? [String: Any]
let params = object?["params"] as? [String: Any]
let requestEvents = params?["events"] as? [[String: Any]] ?? []
let toolCallIds = requestEvents.map {{ $0["tool_call_id"] as? String }}
guard request.eventCount == 64, requestEvents.count == 64 else {{
    fatalError("expected a bounded 64-event expansion, got \\(request.eventCount)")
}}
guard toolCallIds.contains("tool-63") else {{
    fatalError("overflow marker displaced the newest retained terminal event: \\(toolCallIds)")
}}
guard requestEvents.allSatisfy({{
    $0["surface_id"] as? String == "22222222-2222-2222-2222-222222222222"
}}) else {{
    fatalError("compacted Feed expansion dropped its resolved surface: \\(requestEvents)")
}}

let relayRequest = PiCompactedFeedEventExpander(
    agentPid: 42,
    workspaceId: "11111111-1111-1111-1111-111111111111",
    surfaceId: "22222222-2222-2222-2222-222222222222",
    maximumRequestCount: 2
).acknowledgedBatchRequest(from: [
    "session_id": "pi-expander-session",
    "cmux_compacted_terminal_omitted_count": 0,
    "cmux_compacted_terminal_events": summaries,
])
guard let relayRequest else {{ fatalError("expected relay compacted Feed batch request") }}
let relayObject = try JSONSerialization.jsonObject(with: Data(relayRequest.line.utf8)) as? [String: Any]
let relayParams = relayObject?["params"] as? [String: Any]
let relayEvents = relayParams?["events"] as? [[String: Any]] ?? []
let relayToolCallIds = relayEvents.map {{ $0["tool_call_id"] as? String }}
guard relayRequest.eventCount == 2,
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
            test_expander_preserves_newest_retained_summary(root)
            test_pi_compacted_post_tool_use_sends_one_ordered_batch(cli_path, root)
            test_pi_compacted_feed_sends_bounded_acknowledged_batch(cli_path, root)
            test_pi_compacted_feed_rejects_failed_server_ack(cli_path, root)
            test_pi_compacted_feed_allows_brief_auth_delay(cli_path, root)
            test_pi_feed_rejects_unconfirmed_server_ack(cli_path, root)
            test_pi_hook_rehomes_moved_explicit_surface(cli_path, root)
            test_pi_feed_uses_resolved_explicit_workspace(cli_path, root)
            test_pi_feed_rejects_missing_explicit_workspace(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Pi compacted Feed delivery is authoritative, bounded, and acknowledged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
