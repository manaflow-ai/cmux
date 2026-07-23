#!/usr/bin/env python3

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "cmux-tui" / "bindings" / "conformance" / "fixtures.json"


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


if __name__ == "__main__":
    main()
