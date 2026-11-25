#!/usr/bin/env python3
"""guardrails.py rule `task-priority` (PL-qos): a new detached Task or dispatch queue states its priority.

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
        self.write(f"{KIT}/Many.swift", "".join(swift(line) for line in (REFUSED + ALLOWED) * 200))
        self.commit("many lines")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main()
