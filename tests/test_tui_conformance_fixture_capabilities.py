#!/usr/bin/env python3

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "cmux-tui" / "bindings" / "conformance" / "fixtures.json"
COMMANDS_SPEC = ROOT / "cmux-tui" / "spec" / "commands.md"
BINDING_SOURCES = (
    ROOT / "cmux-tui" / "bindings" / "rust" / "src" / "lib.rs",
    ROOT / "cmux-tui" / "bindings" / "typescript" / "src" / "client.ts",
    ROOT / "cmux-tui" / "bindings" / "python" / "cmux" / "client.py",
    ROOT / "cmux-tui" / "bindings" / "go" / "client.go",
    ROOT / "cmux-tui" / "bindings" / "java" / "src" / "com" / "cmux" / "CmuxClient.java",
)


def main() -> None:
    data = json.loads(FIXTURES.read_text())
    fixtures = {fixture["name"]: fixture for fixture in data["fixtures"]}

    baseline = fixtures["send-read-screen-round-trip"]
    assert "requires" not in baseline, "baseline send/read coverage must run on older servers"
    assert all(
        step.get("request", {}).get("cmd") != "clear-history" for step in baseline["steps"]
    ), "additive clear-history coverage must not gate the baseline fixture"

    clear_history = fixtures["clear-history-round-trip"]
    assert clear_history.get("requires") == {"commands": ["clear-history"]}
    assert any(
        step.get("request", {}).get("cmd") == "clear-history"
        for step in clear_history["steps"]
    )

    fallback = fixtures["clear-history-key-fallback-round-trip"]
    assert fallback.get("requires") == {
        "commands": ["clear-history"],
        "capabilities": ["clear-history-v1", "clear-history-key-v1"],
    }
    fallback_request = next(
        step["request"]
        for step in fallback["steps"]
        if step.get("request", {}).get("cmd") == "clear-history"
    )
    assert fallback_request["fallback_key"]["key"] == "k"
    assert fallback_request["fallback_key"]["mods"]["super"] is True

    commands_spec = COMMANDS_SPEC.read_text()
    assert "`clear-history-key-v1`" in commands_spec
    assert "`fallback_key`" in commands_spec
    for source in BINDING_SOURCES:
        binding = source.read_text()
        assert "clear-history-key-v1" in binding, source
        assert "fallback" in binding.lower(), source


if __name__ == "__main__":
    main()
