#!/usr/bin/env python3
"""The fake Claude harness's model option follows FAKE_MODELS (cmux-tui/crates/acpmux/tests/fake_agent.py).

customize-app-profiles (Leo: "make customization for codex, t3code, claude code app (everything)"): the
Claude Code app profile's r27 capture ran the fake harness with FAKE_PICKER=1 FAKE_PICKER_MODES=claude
FAKE_MODELS=claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5, and its model picker listed "Fable 5.1":
FAKE_MODELS fed only ACP `models` while the "model" option, which the picker draws, kept the built-in list.

    python3 -m unittest tests/test_fake_agent_claude_models.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

FAKE = Path(__file__).resolve().parent.parent / "cmux-tui/crates/acpmux/tests/fake_agent.py"


def new_session(extra: dict[str, str]) -> dict:
    env = {key: value for key, value in os.environ.items() if not key.startswith("FAKE_")}
    env.update({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude", **extra})
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}},
        {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/tmp", "mcpServers": []}},
    ]
    with subprocess.Popen(
        [sys.executable, "-I", str(FAKE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=env, text=True,
    ) as proc:
        try:
            for line in lines:
                proc.stdin.write(json.dumps(line) + "\n")
                proc.stdin.flush()
            while True:
                raw = proc.stdout.readline()
                if not raw:
                    raise AssertionError("fake agent ended before answering session/new")
                reply = json.loads(raw)
                if reply.get("id") == 2:
                    return reply["result"]
        finally:
            proc.kill()


def model_rows(result: dict) -> list[tuple[str, str]]:
    option = next(o for o in result["configOptions"] if o["id"] == "model")
    return [(row["value"], row["name"]) for row in option["options"]]


class FakeClaudeModels(unittest.TestCase):
    def test_fake_models_is_the_model_option(self) -> None:
        result = new_session({"FAKE_MODELS": "claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5"})
        self.assertEqual(
            model_rows(result),
            [("default", "Default"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
             ("claude-haiku-5-5", "Haiku 5.5")],
        )
        self.assertNotIn("Fable 5.1", [name for _, name in model_rows(result)])
        self.assertEqual(result["models"]["currentModelId"], "claude-opus-5-5")

    def test_unknown_claude_id_is_named_as_claude_code_names_it(self) -> None:
        result = new_session({"FAKE_MODELS": "claude-opus-5-5,claude-fable-5-2"})
        self.assertIn(("claude-fable-5-2", "Fable 5.2"), model_rows(result))

    def test_without_fake_models_the_built_in_list_stays(self) -> None:
        names = [name for _, name in model_rows(new_session({}))]
        self.assertEqual(names, ["Default", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1"])


if __name__ == "__main__":
    unittest.main()
