#!/usr/bin/env python3
"""guardrails.py rules `task-priority` and `pool-blocking` (PL-qos): a new detached Task or dispatch queue states its
priority, and no blocking call is written directly in a Task body.

Not on CI (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the rule:
python3 tests/test_cmux_next_guardrails_qos.py
"""
import importlib.util
from pathlib import Path
import sys
import unittest

_HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_suite", _HERE / "test_cmux_next_guardrails.py")
suite = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = suite
_spec.loader.exec_module(suite)
guardrails = suite.guardrails
KIT = suite.KIT

REFUSED = [
    "Task.detached {",
    "Task.detached { [weak self] in",
    "Task.detached(name: \"x\") {",
    "DispatchQueue.global().async {",
    "let q = DispatchQueue(label: \"com.x.y\")",
    "let q = DispatchQueue(label: \"com.x.y\",\n        attributes: .concurrent)",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .userInteractive)",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .unspecified)",
    "DispatchQueue.global(qos: .background).async {",
    "Task.detached(priority: .background) {",
    # Split over lines: read to the call's closing parenthesis, from its first token.
    "let q = DispatchQueue(\n        label: \"com.x.y\")",
    "let q = DispatchQueue(\n        label: \"com.x.y\",\n        qos: .userInteractive)",
    "Task.detached\n    {",
    "let t = Task\n        .detached {",
    "Task.detached(\n        name: \"x\"\n    ) {",
    "Task\n        .detached(priority: .background) {",
]
ALLOWED = [
    "Task.detached(priority: .utility) {",
    "Task(priority: .high) {",
    "Task {",
    "Task { [weak self] in",
    "Task { @MainActor in",
    "DispatchQueue.global(qos: .utility).async {",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .utility)",
    "let q = DispatchQueue(label: \"com.x.y\", target: other)",
    "Task.detached { // qos-allow: inherits the request's priority on purpose",
    "let task: Task<Void, Never>? = nil",
    "group.addTask {",
    "MyTask {",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .userInteractive) // qos-allow: the frame waits for this parse",
    "Task.detached(priority: .background) { // qos-allow: telemetry upload, nothing waits for it",
    "let q = DispatchQueue(\n        label: \"com.x.y\",\n        qos: .utility)",
    "Task.detached(\n        priority: .utility\n    ) {",
    "let t = Task\n        .detached(priority: .utility) {",
    "let q = DispatchQueue(\n        label: \"com.x.y\",\n        target: other)",
    "let pick = DispatchQueue.global",
    "rows\n        .detached()",
]


def swift(line: str) -> str:
    return f"func f() {{\n    {line}\n    }}\n}}\n"


class TaskPriorityRuleTests(suite.Fixture):
    def refused_ids(self, line):
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(f"{KIT}/Added.swift", swift(line))
        self.commit(f"adds {line}")
        refusals, _ = self.check()
        return [r.id for r, _ in refusals]

    def test_a_task_or_queue_without_a_priority_is_refused(self):
        for line in REFUSED:
            with self.subTest(line=line):
                self.assertIn("task-priority", self.refused_ids(line))

    def test_a_stated_priority_a_main_actor_hop_or_the_escape_passes(self):
        for line in ALLOWED:
            with self.subTest(line=line):
                self.assertNotIn("task-priority", self.refused_ids(line))

    def test_an_existing_task_without_a_priority_never_counts(self):
        self.rebase_on({f"{KIT}/Old2.swift": swift("Task.detached {")})
        self.write(f"{KIT}/Old2.swift", swift("Task.detached {") + "// edited\n")
        self.commit("edits around an old task")
        refusals, _ = self.check()
        self.assertNotIn("task-priority", [r.id for r, _ in refusals])

    def test_the_rule_is_fast(self):
        import time
        # About 5,200 calls (the first lists' 26 cases x 200), whatever the lists hold now: the budget is per call.
        cases = REFUSED + ALLOWED
        self.write(f"{KIT}/Many.swift", "".join(swift(line) for line in cases * (5200 // len(cases))))
        self.commit("many lines")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 1.0)


POOL_REFUSED = [
    "Task.detached(priority: .utility) {\n        let data = try? Data(contentsOf: url)\n    }",
    "Task {\n        try data.write(to: url, options: .atomic)\n    }",
    "Task { [weak self] in\n        if ready {\n            _ = FileManager.default.fileExists(atPath: path)\n        }\n    }",
    "group.addTask {\n        try? FileManager.checked.removeItem(at: url)\n    }",
    "Task.detached(\n        priority: .utility\n    ) {\n        _ = try? String(contentsOf: url, encoding: .utf8)\n    }",
    "Task(priority: .high) {\n        process.waitUntilExit()\n    }",
]
POOL_ALLOWED = [
    "Task {\n        let data = try await work.run(.userVisible, mayBlock: .files) { try Data(blockingContentsOf: url) }\n    }",
    "Task {\n        work.post(.bestEffort, mayBlock: .files) {\n            try? FileManager.checked.removeItem(at: url)\n        }\n    }",
    "Task { @MainActor in\n        refresh()\n    }",
    "Task {\n        // blocking-allow: a one-byte read of a pipe the child just closed\n        _ = handle.readDataToEndOfFile()\n    }",
    "func save() {\n        try? data.write(to: url)\n    }",
    "Task {\n        await model.reload()\n    }",
]


class PoolBlockingRuleTests(suite.Fixture):
    """Rule (c) of P14: a blocking call written directly in a Task body (the cooperative pool, or main)."""

    refused_ids = TaskPriorityRuleTests.refused_ids

    def test_a_blocking_call_in_a_task_body_is_refused(self):
        for text in POOL_REFUSED:
            with self.subTest(text=text):
                self.assertIn("pool-blocking", self.refused_ids(text))

    def test_a_lane_body_a_main_actor_hop_plain_code_or_the_escape_passes(self):
        for text in POOL_ALLOWED:
            with self.subTest(text=text):
                self.assertNotIn("pool-blocking", self.refused_ids(text))

    def test_an_existing_blocking_task_never_counts(self):
        old = swift("Task {\n        _ = try? Data(contentsOf: url)\n    }")
        self.rebase_on({f"{KIT}/Old3.swift": old})
        self.write(f"{KIT}/Old3.swift", old + "// edited\n")
        self.commit("edits around an old blocking task")
        refusals, _ = self.check()
        self.assertNotIn("pool-blocking", [r.id for r, _ in refusals])

    def test_the_rule_is_fast(self):
        import time
        cases = POOL_REFUSED + POOL_ALLOWED
        self.write(f"{KIT}/Many.swift", "".join(swift(text) for text in cases * (3000 // len(cases))))
        self.commit("many tasks")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main()
