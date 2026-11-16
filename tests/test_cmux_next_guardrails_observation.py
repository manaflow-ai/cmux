#!/usr/bin/env python3
"""guardrails.py rules `observation-onchange` and `observation-scope` (main-thread-scheduling.md G2 and 1.4).

An observation's `onChange:` runs inside the write that fired it (the store drain): it only marks dirty and
enqueues. An observation closure reads one item, or the list of ids an `ObservedItems` owner keeps, never a walk
over every workspace or tab. Both rules judge only the lines a push adds.

Not on CI (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to either rule:
python3 tests/test_cmux_next_guardrails_observation.py
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
KIT = suite.KIT
WRAPPER = "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/SingleArmedTracking.swift"

# A computing onChange: it reads the model or does more than one enqueue inside the writer.
ONCHANGE_REFUSED = {
    "reads and applies": "withObservationTracking { _ = store.tabs } onChange: { [weak self] in\n"
                         "        let titles = store.tabs.map(\\.title)\n"
                         "        self?.apply(titles)\n"
                         "    }",
    "one call that computes its argument": "tracking.track(shape: []) { render() } onChange: { [weak self] in "
                                           "self?.apply(store.tabs.map(\\.title)) }",
    "control flow": "withObservationTracking { render() } onChange: { [weak self] in\n"
                    "        if self?.isVisible == true { self?.render() }\n"
                    "    }",
    "two calls, call form": "withObservationTracking({ render() }, onChange: { markDirty(); flush() })",
    "a dirty mark and two calls": "withObservationTracking { render() } onChange: { [weak self] in\n"
                                  "        self?.isDirty = true\n"
                                  "        self?.snapshots.markStale()\n"
                                  "        Task { @MainActor in self?.publish() }\n"
                                  "    }",
    "a value assignment": "withObservationTracking { render() } onChange: { [weak self] in self?.titles = store.titles }",
}
ONCHANGE_ALLOWED = {
    "one enqueue": "withObservationTracking { render() } onChange: { [weak self] in self?.markDirty() }",
    "a deferred rebuild": "withObservationTracking { render() } onChange: { [weak self] in\n"
                          "        Task { @MainActor in self?.rebuild(store.tabs.map(\\.title)) }\n"
                          "    }",
    "a yield": "tracking.track(shape: []) { render() } onChange: { continuation.yield(()) }",
    "a call over lines": "withObservationTracking { render() } onChange: { [weak self] in\n"
                         "        self?.schedule(\n"
                         "            site)\n"
                         "    }",
    "a dirty mark": "withObservationTracking { render() } onChange: { [weak self] in self?.isDirty = true }",
    "a guard, a dirty mark and an enqueue": "withObservationTracking { render() } onChange: { [weak self] in\n"
                                            "        guard let self else { return }\n"
                                            "        self.isDirty = true\n"
                                            "        Task { @MainActor in self.flush() }\n"
                                            "    }",
    "a file watcher's callback": "watcher = ConfigFileWatcher(url: file, onChange: { reload(); log() })",
    "a pointer callback": "hover.followPointer(isHoverable: { true }, onChange: { a(); b() })",
    "the escape": "withObservationTracking({ render() }, onChange: { markDirty(); flush() }) "
                  "// onchange-allow: flush only posts the batch it was handed",
}

# A session-wide read in an observation closure (outside an ObservedItems owner's list of ids).
SCOPE_REFUSED = {
    "item fields of every workspace": "_ = ObservationStream({ ObservationTrigger(store.workspaces.map(\\.title)) })",
    "a for loop over the workspaces": "_ = ObservationStream({ () -> [String] in\n"
                                      "        var out: [String] = []\n"
                                      "        for workspace in workspaces() {\n"
                                      "            out.append(workspace.name)\n"
                                      "        }\n"
                                      "        return out\n"
                                      "    })",
    "a walk down to every tab": "_ = ObservationStream.current({ windows.flatMap(\\.screens).flatMap(\\.panes).map(\\.title) })",
    "a pane walk from every screen": "_ = ObservationStream({ store.screens.flatMap(\\.panes).count })",
    "a store map's values": "_ = ObservationStream { store.liveTabs.values.filter { $0.attention } }",
    "a raw tracking": "withObservationTracking { _ = model.allTabs.compactMap(\\.url) } onChange: { markDirty() }",
    "an observation loop": "loop = ObservationLoop({ render(tabs.map(\\.title)) })",
    "the apply closure of a tracking": "tracking.track(shape: []) { render(store.workspaces.map(\\.name)) } onChange: { markDirty() }",
}
SCOPE_ALLOWED = {
    "an ObservedItems owner's list": "_ = ObservationStream({ ObservationTrigger(workspaces()) })",
    "the ids only": "_ = ObservationStream({ ObservationTrigger(store.workspaces.map(\\.id)) })",
    "the ids in a closure": "_ = ObservationStream({ store.workspaces.map { $0.id } })",
    "a count": "_ = ObservationStream({ store.tabs.count })",
    "one workspace's own walk": "_ = ObservationStream.current({ workspace.screens.flatMap(\\.panes).flatMap(\\.tabs).map(\\.title) })",
    "one pane's tabs": "_ = ObservationStream({ pane.tabs.map(\\.title) })",
    "one item's field": "_ = ObservationStream({ ObservationTrigger(tab.title) })",
    "a walk outside any observation": "for workspace in workspaces { print(workspace.name) }",
    "the stream's for-await body": "for await list in ObservationStream({ ObservationTrigger(workspaces()) }) {\n"
                                   "        for workspace in list.value { print(workspace.name) }\n"
                                   "    }",
    "an ObservedItems item closure": "items = ObservedItems<WorkspaceModel, [String]>(\n"
                                     "        item: { workspace in workspace.screens.flatMap(\\.panes).map(\\.title) },\n"
                                     "        same: { $0 == $1 }, changed: { refresh() })",
    "the escape": "_ = ObservationStream({ store.workspaces.map(\\.title) }) "
                  "// observation-scope-allow: the picker shows at most 3 pinned workspaces",
}


def swift(body: str) -> str:
    return f"@MainActor func watch() {{\n    {body}\n}}\n"


class ObservationRuleTests(suite.Fixture):
    def refused_ids(self, body, path=None):
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(path or f"{KIT}/Added.swift", swift(body))
        self.commit("adds an observation")
        refusals, _ = self.check()
        return [r.id for r, _ in refusals]

    def test_a_computing_on_change_is_refused(self):
        for name, body in ONCHANGE_REFUSED.items():
            with self.subTest(name):
                self.assertIn("observation-onchange", self.refused_ids(body))

    def test_one_enqueue_a_dirty_mark_other_callbacks_and_the_escape_pass(self):
        for name, body in ONCHANGE_ALLOWED.items():
            with self.subTest(name):
                self.assertNotIn("observation-onchange", self.refused_ids(body))

    def test_a_session_wide_read_in_an_observation_is_refused(self):
        for name, body in SCOPE_REFUSED.items():
            with self.subTest(name):
                self.assertIn("observation-scope", self.refused_ids(body))

    def test_an_observed_items_list_read_ids_one_item_and_the_escape_pass(self):
        for name, body in SCOPE_ALLOWED.items():
            with self.subTest(name):
                self.assertNotIn("observation-scope", self.refused_ids(body))

    def test_the_tracked_wrappers_own_on_change_is_theirs(self):
        self.assertNotIn("observation-onchange", self.refused_ids(ONCHANGE_REFUSED["reads and applies"], WRAPPER))

    def test_a_line_added_to_an_existing_on_change_body_is_refused(self):
        self.rebase_on({f"{KIT}/Old2.swift": swift(ONCHANGE_ALLOWED["one enqueue"].replace(
            "in self?.markDirty() }", "in\n        self?.markDirty()\n    }"))})
        self.write(f"{KIT}/Old2.swift", swift("withObservationTracking { render() } onChange: { [weak self] in\n"
                                              "        self?.markDirty()\n        self?.render()\n    }"))
        self.commit("computes in an old onChange")
        refusals, _ = self.check()
        self.assertIn("observation-onchange", [r.id for r, _ in refusals])

    def test_an_old_loop_wrapped_in_a_new_observation_is_refused(self):
        loop = "for workspace in workspaces() {\n        print(workspace.name)\n    }"
        self.rebase_on({f"{KIT}/Old2.swift": swift(loop)})
        self.write(f"{KIT}/Old2.swift", swift("_ = ObservationStream({ () -> Int in\n    " + loop + "\n    return 0\n    })"))
        self.commit("observes an old loop")
        refusals, _ = self.check()
        self.assertIn("observation-scope", [r.id for r, _ in refusals])

    def test_existing_debt_never_counts(self):
        self.rebase_on({f"{KIT}/Old2.swift": swift(SCOPE_REFUSED["a for loop over the workspaces"] + "\n    "
                                                   + ONCHANGE_REFUSED["reads and applies"])})
        self.write(f"{KIT}/Old2.swift", swift(SCOPE_REFUSED["a for loop over the workspaces"] + "\n    "
                                              + ONCHANGE_REFUSED["reads and applies"]) + "// edited\n")
        self.commit("edits around old debt")
        refusals, _ = self.check()
        ids = [r.id for r, _ in refusals]
        self.assertNotIn("observation-scope", ids)
        self.assertNotIn("observation-onchange", ids)

    def test_the_rules_are_fast(self):
        import time
        bodies = list(ONCHANGE_REFUSED.values()) + list(ONCHANGE_ALLOWED.values()) + list(SCOPE_REFUSED.values()) \
            + list(SCOPE_ALLOWED.values())
        self.write(f"{KIT}/Many.swift", "".join(swift(body) for body in bodies * 100))
        self.commit("many observations")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 3.0)


if __name__ == "__main__":
    unittest.main()
