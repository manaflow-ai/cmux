#!/usr/bin/env python3
"""cmux-next codebase health (scripts/cmux-next/codebase-health.py): its numbers are the real ones.

plans/cmux-next/perf-lead.md row 24 and codebase-health.md section 6 said `home-key` had no `// perf-hot:` marker
while it had one (Packages/Shared/CmuxMessagesLab, outside Packages/macOS/CmuxNext/Sources, the only place the
report looked). These tests build a throwaway repository with markers inside and outside the pre-push hook's
scope, one on the `{` line of a multi-line signature (KeyBindingTable.step and ChordTracker.step have that shape;
the hook's resolver marks that declaration), and one that marks no declaration, and check what the report
prints, and that its "warns at push" claim is what guardrails.py really does for an edit of each marked function. They also check that a
NotificationCenter observer behind the `MainActorObservation(` wrapper counts as an observer at each use of the
wrapper, its own body does not (sections 1 and 2),
and that the header cites a sha on feat-cmux-next, not a local commit a rebase rewrites. Not on CI (Lawrence
2026-10-23: no new CI gates): run it yourself after a change to codebase-health.py or to guardrails.py's diff
scope or declaration parser: python3 tests/test_cmux_next_codebase_health.py
"""
import re
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()

SOURCE = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


health = load("cmux_next_codebase_health", SOURCE / "scripts/cmux-next/codebase-health.py")
guardrails = load("cmux_next_guardrails_for_health", SOURCE / "scripts/cmux-next/guardrails.py")
arch_counts = load("cmux_next_arch_counts_for_health_test", SOURCE / "scripts/cmux-next/arch_counts.py")

BENCHES = """{"paths": {
  "key-dispatch": {"bench": "scripts/cmux-next/bench-typing.py", "owner": "PL-typing"},
  "home-key": {"bench": "scripts/cmux-next/home-perf.py", "owner": "PL-typing"},
  "new-tab": {"bench": "scripts/cmux-next/instant-new-surfaces-bench.py", "owner": "PL-cef-tab"}
}}
"""
PACKAGE = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CmuxNext", targets: [
    .target(name: "CmuxNextKit"),
])
"""
ROUTER = "Packages/macOS/CmuxNext/Sources/CmuxNextKit/Router.swift"
CHORD = "Packages/macOS/CmuxNext/Sources/CmuxNextKit/Chord.swift"
PANE_HOST = "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/PaneHost.swift"
OBSERVERS = "Packages/macOS/CmuxNext/Sources/CmuxNextKit/KeyWatcher.swift"
WRAPPER_PATH = "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/MainActorObservation.swift"


def marked(kind: str, path_id: str, body: str) -> str:
    return (f"import Foundation\nfinal class {kind} {{\n    var count = 0\n"
            f"    func hot(_ key: Int) {{ // perf-hot: 2ms {path_id}\n        {body}\n    }}\n}}\n")


def marked_multiline(kind: str, path_id: str, body: str) -> str:
    """The marker trails the last line of a multi-line signature (no `func` on that line)."""
    return (f"import Foundation\nfinal class {kind} {{\n    var count = 0\n"
            f"    func step(_ key: Int,\n              repeats: Int) -> Int {{ // perf-hot: 0.5ms {path_id}\n"
            f"        {body}\n        return count\n    }}\n}}\n")


WATCHER = """import AppKit
import CmuxNextCompat
extension Notification.Name {
    static let paneMoved = Notification.Name("paneMoved")
}
final class KeyWatcher {
    var observers: [MainActorObservation] = []
    func watch(_ window: NSWindow) {
        observers.append(MainActorObservation(NSWindow.didBecomeKeyNotification, object: window) { })
        observers.append(MainActorObservation(.paneMoved) { })
    }
}
"""


# CmuxNextCompat's wrapper: a use of it is an observer by what its init does; its own addObserver is not another one.
WRAPPER = """import Foundation
public final class MainActorObservation {
    private let token: any NSObjectProtocol
    public init(_ name: Notification.Name, object: AnyObject? = nil, center: NotificationCenter = .default,
                _ handler: @escaping @MainActor () -> Void) {
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
"""


# The shape of SFSpeechDictationTranscriber.swift:162: the call's `named:` is on the next line.
MULTILINE = """import Foundation
final class MoveWatcher {
    func watch() async {
        let changes = NotificationCenter.default.notifications(
            named: .paneMoved
        )
        for await _ in changes { }
    }
}
"""


# SidebarListView's shape: one registration in a loop binds two custom names.
LOOP = """import AppKit
extension Notification.Name {
    static let refused = Notification.Name("refused")
    static let settled = Notification.Name("settled")
}
final class Settler {
    var tokens: [NSObjectProtocol] = []
    func watch() {
        for name in [Notification.Name.refused, .settled] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in })
        }
        let first = Notification.Name.refused
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                             object: nil, queue: .main) { _ in _ = first })
    }
}
"""


def two_markers(first: str, second: str) -> str:
    """Two marked functions in one file; an empty id leaves that function unmarked."""
    def mark(path_id: str) -> str:
        return f" // perf-hot: 2ms {path_id}" if path_id else ""
    return (f"import Foundation\nfinal class Router {{\n    var count = 0\n"
            f"    func hot(_ key: Int) {{{mark(first)}\n        count += key\n    }}\n"
            f"    func warm(_ key: Int) {{{mark(second)}\n        count -= key\n    }}\n}}\n")


class CodebaseHealthPerfHotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.env = git_fixture_env.without_auto_maintenance(
            {k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("config", "user.email", "health@example.com")
        self.git("config", "user.name", "health")
        self.write("scripts/cmux-next/perf-hot-benches.json", BENCHES)
        self.write("Packages/macOS/CmuxNext/Package.swift", PACKAGE)
        self.write(ROUTER, marked("Router", "key-dispatch", "count += key"))
        self.write(PANE_HOST, marked("PaneHost", "home-key", "count += key"))
        self.write(CHORD, marked_multiline("Chord", "key-dispatch", "count += key"))
        self.write(OBSERVERS, WATCHER)
        self.write(WRAPPER_PATH, WRAPPER)
        self.base = self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True,
                              env=self.env).stdout

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def section6(self) -> dict[str, str]:
        lines = health.report(self.repo).splitlines()
        return {line.split("`")[1]: line for line in lines if line.startswith("- `")}

    def test_a_marker_outside_the_app_sources_counts_as_a_marker(self):
        rows = self.section6()
        self.assertNotIn("no marker", rows["home-key"])
        self.assertIn(PANE_HOST, rows["home-key"])
        self.assertIn("CmuxNextKit/Router.swift", rows["key-dispatch"])
        self.assertIn("CmuxNextKit/Chord.swift", rows["key-dispatch"])
        self.assertIn("**no marker** (owner PL-cef-tab)", rows["new-tab"])

    def test_the_report_counts_marked_ids_and_ids_that_warn_at_push(self):
        report = health.report(self.repo)
        # Only PaneHost (outside the hook's diff scope) never warns: Chord's wrapped signature warns like Router.
        self.assertIn("Marked: 2 of 3 path ids (3 markers); 1 of 3 warn at push; 1 of 3 markers never warn.", report)

    def test_a_marker_that_marks_no_declaration_is_flagged_and_the_hook_agrees(self):
        # A trailing marker on a statement line marks nothing: the report flags it, and the hook's own warning
        # for that marker line (not a hot-function edit) still gives a report.
        self.write(ROUTER, marked("Router", "key-dispatch", "count += key // perf-hot: 1ms new-tab"))
        self.commit("a marker on a statement")
        rows = self.section6()
        self.assertIn("CmuxNextKit/Router.swift:5 (marks no declaration", rows["new-tab"])
        self.assertRegex(rows["key-dispatch"], r"CmuxNextKit/Router\.swift:4(,|$)")  # its function still warns

    def test_warns_at_push_is_what_the_hook_does_for_an_edit_of_each_marked_function(self):
        rows = self.section6()
        self.write(ROUTER, marked("Router", "key-dispatch", "count += key * 2"))
        self.write(PANE_HOST, marked("PaneHost", "home-key", "count += key * 2"))
        self.write(CHORD, marked_multiline("Chord", "key-dispatch", "count += key * 2"))
        head = self.commit("edit every hot function's body")
        _, warnings = guardrails.check(self.repo, self.base, head)
        warned = {text.split(":", 1)[0] for kind, text in warnings if kind == "perf-hot"}
        for path_id, path in (("key-dispatch", ROUTER), ("key-dispatch", CHORD), ("home-key", PANE_HOST)):
            shown = path.removeprefix(health.SOURCES)
            entry = re.search(re.escape(shown) + r"(:\d+)?( \([^,]*\))?", rows[path_id])
            self.assertIsNotNone(entry, f"{path_id}: {shown} not listed in {rows[path_id]!r}")
            claims_warning = "no warning" not in entry.group(0)
            self.assertEqual(claims_warning, path in warned,
                             f"{path_id} {shown}: report says warns={claims_warning}, hook warned={path in warned}")

    def test_an_observer_behind_the_main_actor_wrapper_counts_as_an_observer(self):
        report = health.report(self.repo)
        row = next(line for line in report.splitlines() if line.startswith("| NotificationCenter observers"))
        cells = [c.strip() for c in row.strip("|").split("|")]
        self.assertEqual((cells[1], cells[2]), ("2", "1"), row)
        self.assertIn("| `paneMoved` | 1 | 1 | 0 |", report)  # observed from every sender: no `object:`
        observed = report.split("<details><summary>Observed names</summary>", 1)[1].split("</details>", 1)[0]
        self.assertRegex(observed, r"1 sites\s+0 per-instance\s+didBecomeKeyNotification")

    def test_an_uncommitted_marker_removal_still_gives_a_report(self):
        # The report reads the working tree: removing (or retagging) one of a file's two markers before a commit
        # is an edit, not a hook warning the report cannot read.
        self.write(ROUTER, two_markers("key-dispatch", "home-key"))
        self.commit("two markers in one file")
        for second in ("", "new-tab"):
            with self.subTest(second=second or "removed"):
                self.write(ROUTER, two_markers("key-dispatch", second))
                rows = self.section6()
                self.assertIn("CmuxNextKit/Router.swift:4", rows["key-dispatch"])
                self.assertNotIn("Router.swift", rows["home-key"])
                if second:
                    self.assertIn("CmuxNextKit/Router.swift:7", rows["new-tab"])

    def test_observers_are_the_arch_ratchets_observer_sites(self):
        # One counter: section 1 and section 2 read arch_counts' observer sites, so a call whose `named:` is on
        # the next line counts, and the number equals arch-ratchet.json's observer_sites at the same tree.
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextKit/MoveWatcher.swift", MULTILINE)
        self.commit("a multi-line observer")
        paths = self.git("ls-files", "Packages/macOS/CmuxNext/Sources").split()
        shared = arch_counts.observer_registrations({path: (self.repo / path).read_text() for path in paths}).total()
        self.assertEqual(shared, 3)
        report = health.report(self.repo)
        row = next(line for line in report.splitlines() if line.startswith("| NotificationCenter observers"))
        cells = [c.strip() for c in row.strip("|").split("|")]
        self.assertEqual((cells[1], cells[2]), (str(shared), "2"), row)
        self.assertIn(f"{shared} observer registrations", report)
        # Both `paneMoved` observers pass no `object:`, so both observe every sender.
        self.assertIn("| `paneMoved` | 2 | 2 | 0 |", report)
        observed = report.split("<details><summary>Observed names</summary>", 1)[1].split("</details>", 1)[0]
        self.assertRegex(observed, r"2 sites\s+0 per-instance\s+paneMoved")

    def test_a_loop_over_names_is_one_observer_of_each_name_it_binds(self):
        # SidebarListView's shape: one registration in a loop over two custom names registers two observers
        # (section 1: a literal loop whose binding the registration uses counts per element) and observes both
        # names (section 2), not a name called `name`. A system name passed as `Type.member` keeps its own name
        # even with a custom name on the line above.
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextKit/Settler.swift", LOOP)
        self.commit("a loop over two names")
        report = health.report(self.repo)
        row = next(line for line in report.splitlines() if line.startswith("| NotificationCenter observers"))
        self.assertEqual([c.strip() for c in row.strip("|").split("|")][1], "5", row)
        self.assertIn("| `refused` | 1 | 1 | 0 |", report)
        self.assertIn("| `settled` | 1 | 1 | 0 |", report)
        observed = report.split("<details><summary>Observed names</summary>", 1)[1].split("</details>", 1)[0]
        self.assertNotRegex(observed, r"\bname\b")
        self.assertRegex(observed, r"1 sites\s+0 per-instance\s+didResignKeyNotification")

    def test_a_linked_local_package_is_counted_like_the_arch_ratchet(self):
        # The arch ratchet counts CmuxNext and its local package closure (arch_counts method v5). Once CmuxNext links
        # CmuxMessagesLab, PaneHost's observer counts in section 1 and its target joins section 4's graph.
        def observers() -> str:
            report = health.report(self.repo)
            row = next(line for line in report.splitlines() if line.startswith("| NotificationCenter observers"))
            return [c.strip() for c in row.strip("|").split("|")][1]

        self.write(PANE_HOST, marked("PaneHost", "home-key", "count += key") + WATCHER.split("\n", 1)[1])
        self.commit("an observer in a Shared package CmuxNext does not link")
        self.assertEqual(observers(), "2")
        self.write("Packages/macOS/CmuxNext/Package.swift", PACKAGE.replace(
            'name: "CmuxNext", ', 'name: "CmuxNext", dependencies: [.package(path: "../../Shared/CmuxMessagesLab")], '))
        self.write("Packages/Shared/CmuxMessagesLab/Package.swift",
                   'import PackageDescription\nlet package = Package(name: "CmuxMessagesLab", '
                   'targets: [.target(name: "MessagesLabHome")])\n')
        self.commit("CmuxNext links CmuxMessagesLab")
        self.assertEqual(observers(), "4")
        self.assertIn("manifests: 2 targets (2 non-test", health.report(self.repo), "MessagesLabHome joins the graph")

    def test_the_header_cites_the_feat_cmux_next_merge_base_not_a_local_commit(self):
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", self.base)
        self.write("plans/cmux-next/notes.md", "local notes\n")
        local = self.commit("a local commit a rebase rewrites")
        header = health.report(self.repo).splitlines()[2]
        self.assertIn(f"at feat-cmux-next `{self.base[:11]}` plus this tree's changes to `plans/cmux-next/notes.md`",
                      header)
        self.assertNotIn(local[:11], header)


if __name__ == "__main__":
    unittest.main()
