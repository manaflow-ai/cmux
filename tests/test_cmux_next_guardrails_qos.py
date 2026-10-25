#!/usr/bin/env python3
"""guardrails.py rule `task-priority` (PL-qos, p02-threads-011): a new task, queue or thread states its priority.

Forms: `Task.detached` and `DispatchQueue.global(` only in CmuxNextWakeups (and there with a priority), a serial
queue with `qos:`/`target:`, a Thread with `.qualityOfService =`, no `Thread.detachNewThread`, an OperationQueue()
with `.qualityOfService =` and `.name =`, no `delegateQueue: nil`; `// qos-allow:` escapes each.

Not on CI (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the rule:
python3 tests/test_cmux_next_guardrails_qos.py
"""
import importlib.util
from pathlib import Path
import sys
import time
import unittest

_HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_suite", _HERE / "test_cmux_next_guardrails.py")
suite = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = suite
_spec.loader.exec_module(suite)
guardrails = suite.guardrails
KIT = suite.KIT
WAKEUPS = f"{suite.PKG}/Sources/CmuxNextWakeups"

# Refused in any module.
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
# Refused outside CmuxNextWakeups, allowed inside it: the one owner of detached tasks and root queues.
OWNER_ONLY = [
    "Task.detached(priority: .utility) {",
    "DispatchQueue.global(qos: .utility).async {",
    "Task.detached(\n        priority: .utility\n    ) {",
]
ALLOWED = [
    "Task(priority: .high) {",
    "Task {",
    "Task { [weak self] in",
    "Task { @MainActor in",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .utility)",
    "let q = DispatchQueue(label: \"com.x.y\", target: other)",
    "Task.detached { // qos-allow: inherits the request's priority on purpose",
    "let task: Task<Void, Never>? = nil",
    "group.addTask {",
    "MyTask {",
    "let q = DispatchQueue(label: \"com.x.y\", qos: .userInteractive) // qos-allow: the frame waits for this parse",
    "Task.detached(priority: .background) { // qos-allow: telemetry upload, nothing waits for it",
    "let q = DispatchQueue(\n        label: \"com.x.y\",\n        qos: .utility)",
    "DispatchQueue.global(qos: .utility).async { // qos-allow: the compat seam's own root-queue hop",
]

# Threads, OperationQueues and URLSession delegate queues.
THREAD_REFUSED = [
    # No qualityOfService.
    "let thread = Thread {\n        work()\n    }\n    thread.name = \"cmux.reader\"\n    thread.start()",
    "let thread = Thread(block: run)\n    thread.start()",
    "let thread = Thread(target: self, selector: #selector(run), object: nil)\n    thread.start()",
    # Set on another object, not the new thread.
    "let thread = Thread {\n        work()\n    }\n    other.qualityOfService = .utility\n    thread.start()",
    # Set too late (more than 40 lines on).
    "let thread = Thread {\n" + "        work()\n" * 45 + "    }\n    thread.qualityOfService = .utility",
    # Starts at once: no way to set its QoS first.
    "Thread.detachNewThread {\n        work()\n    }",
    "Thread.detachNewThread { [self] in read() }",
    # OperationQueue without a name, without a QoS, or without either.
    "let queue = OperationQueue()\n    queue.qualityOfService = .utility",
    "let queue = OperationQueue()\n    queue.name = \"cmux.download\"",
    "let queue = OperationQueue()\n    queue.maxConcurrentOperationCount = 1",
    "let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())",
    # URLSession's own unnamed default-QoS queue.
    "let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)",
    "return URLSession(\n        configuration: configuration,\n        delegate: RefuseRedirects(),\n        delegateQueue: nil)",
]
THREAD_ALLOWED = [
    "let thread = Thread {\n        work()\n    }\n    thread.name = \"cmux.reader\"\n"
    "    thread.qualityOfService = .utility\n    thread.start()",
    "let thread = Thread(block: run)\n    thread.qualityOfService = .userInitiated\n    thread.start()",
    "let thread: Thread = Thread {\n        work()\n    }\n    thread.qualityOfService = .utility",
    "let queue = OperationQueue()\n    queue.maxConcurrentOperationCount = 1\n    queue.name = \"cmux.download\"\n"
    "    queue.qualityOfService = .utility",
    "let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)",
    "// qos-allow: nothing waits for it and it never blocks a frame\n    Thread.detachNewThread {\n        work()\n    }",
    "let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil) "
    "// qos-allow: a one-shot probe whose callbacks only copy a value",
    "let t: Thread? = nil",
    "if Thread.isMainThread {",
    "let q = OperationQueue.main",
]
TYPE_LEVEL_ALLOWED = [
    "final class Reader: Thread {\n    override func main() {}\n}\n",
    "extension Thread {\n    var tag: Int { 0 }\n}\n",
    "func makeThread() -> Thread {\n    fatalError()\n}\n",
]


def swift(line: str) -> str:
    return f"func f() {{\n    {line}\n    }}\n}}\n"


class TaskPriorityRuleTests(suite.Fixture):
    def refused_ids(self, line, folder=KIT, text=None):
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(f"{folder}/Added.swift", text if text is not None else swift(line))
        self.commit(f"adds {line}")
        refusals, _ = self.check()
        return [r.id for r, _ in refusals]

    def test_a_task_or_queue_without_a_priority_is_refused(self):
        for line in REFUSED + OWNER_ONLY:
            with self.subTest(line=line):
                self.assertIn("task-priority", self.refused_ids(line))

    def test_a_stated_priority_a_main_actor_hop_or_the_escape_passes(self):
        for line in ALLOWED:
            with self.subTest(line=line):
                self.assertNotIn("task-priority", self.refused_ids(line))

    def test_wakeups_may_detach_a_task_or_use_a_root_queue_with_a_priority(self):
        for line in OWNER_ONLY:
            with self.subTest(line=line):
                self.assertNotIn("task-priority", self.refused_ids(line, WAKEUPS))
        for line in REFUSED:
            with self.subTest(line=line, owner=True):
                self.assertIn("task-priority", self.refused_ids(line, WAKEUPS))

    def test_a_thread_or_operation_queue_without_qos_or_a_nil_delegate_queue_is_refused(self):
        for line in THREAD_REFUSED:
            with self.subTest(line=line):
                self.assertIn("task-priority", self.refused_ids(line))

    def test_a_thread_or_operation_queue_that_states_its_qos_passes(self):
        for line in THREAD_ALLOWED:
            with self.subTest(line=line):
                self.assertNotIn("task-priority", self.refused_ids(line))
        for text in TYPE_LEVEL_ALLOWED:
            with self.subTest(text=text):
                self.assertNotIn("task-priority", self.refused_ids(text, text=text))

    def test_an_existing_task_without_a_priority_never_counts(self):
        self.rebase_on({f"{KIT}/Old2.swift": swift("Task.detached(priority: .utility) {")})
        self.write(f"{KIT}/Old2.swift", swift("Task.detached(priority: .utility) {") + "// edited\n")
        self.commit("edits around an old task")
        refusals, _ = self.check()
        self.assertNotIn("task-priority", [r.id for r, _ in refusals])

    def test_existing_threads_queues_and_sessions_never_count(self):
        old = swift("let thread = Thread {\n        work()\n    }\n    thread.name = \"cmux.reader\"\n    thread.start()\n"
                    "    Thread.detachNewThread { work() }\n"
                    "    let queue = OperationQueue()\n    queue.maxConcurrentOperationCount = 1\n"
                    "    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)\n"
                    "    DispatchQueue.global(qos: .utility).async {")
        self.rebase_on({f"{KIT}/Old3.swift": old})
        self.write(f"{KIT}/Old3.swift", old.replace("work()", "work(1)") + "// edited\n")
        self.commit("edits around old threads")
        refusals, _ = self.check()
        self.assertNotIn("task-priority", [r.id for r, _ in refusals])

    def test_deleting_a_threads_qos_line_is_new_debt(self):
        stated = swift("let thread = Thread {\n        work()\n    }\n    thread.qualityOfService = .utility\n"
                       "    thread.start()")
        self.rebase_on({f"{KIT}/Old4.swift": stated})
        self.write(f"{KIT}/Old4.swift", stated.replace("    thread.qualityOfService = .utility\n", ""))
        self.commit("drops the thread's QoS")
        refusals, _ = self.check()
        self.assertIn("task-priority", [r.id for r, _ in refusals])

    def test_the_rule_is_fast(self):
        # About 30,000 lines (the 45-line late-QoS fixture left out): the whole check, every rule, stays under 1 s.
        short = [line for line in THREAD_REFUSED + THREAD_ALLOWED if line.count("\n") < 10]
        lines = (REFUSED + OWNER_ONLY + ALLOWED + short) * 120
        self.write(f"{KIT}/Many.swift", "".join(swift(line) for line in lines))
        self.commit("many lines")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main()
