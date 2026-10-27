#!/usr/bin/env python3
"""scripts/cmux-next/p06_queue.py: the p06 scheduler sweep's queues, file groups, recipes, owners and --check.

Acceptance of task p06-scheduler-216: a file three queues hit is in one group with three recipes, no file is
in two groups, and a file's owner is the OWNERS.md row guardrails.py picks. Also: an escape counts in the
hook's whole escape window, a site the recipe leaves in place is settled (--check is 0 after the migration),
membership is a function of the path (a hit moved to a new file in the group's folder still fails --check,
a Q1b predicate change moves no file), a file no row covers is residual, and a planned row over 70 hits is
reported. The end-to-end tests commit a small Sources tree, OWNERS.md and WORK.tsv into a throwaway repository
and run main() on it; RealCutTests reads the spec's cut when this clone has it.

Not on CI (Lawrence 2026-10-23: no new CI tests): python3 -m pytest tests/test_p06_queue.py (portable, git only).
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


_load("git_fixture_env", SOURCE / "tests/git_fixture_env.py")  # no background git maintenance in fixtures
q = _load("p06_queue_under_test", SOURCE / "scripts/cmux-next/p06_queue.py")
S = q.SOURCES

OWNERS_MD = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/` | a590 (sidebar-owner agent) | [s.md](s.md) |
| Sidebar rows | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/Row*.swift` | PL-rows | [r.md](r.md) |
| Terminal | `Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/` | PL-ghostty (session cmux-b6) | [g.md](g.md) |
"""

WORK_HEADER = "id\tprogram\tsize\tdepends_on\ttitle\tfiles\n"


def work_row(n, title, files):
    return f"p06-scheduler-{n}\tp06-scheduler\tM\tp06-scheduler-216\tFG: {title}\t{files}\n"


def owner_rows():
    guardrails = q._load("guardrails")
    return guardrails, guardrails.parse_owners(OWNERS_MD)


class QueueTests(unittest.TestCase):
    def hits(self, path, text):
        return q.scan({path: text}, q.heuristic_main_inherited)

    def test_each_queue_hits_its_line_with_its_recipe(self):
        lines = {
            "Q1": ("Task { @MainActor in work() }", "R-hop"),
            "Q1c": ("DispatchQueue.main.async { work() }", "R-hop"),
            "Q2": ("let stream = ObservationStream(model) { $0.title }", "R-obs"),
            "Q3": ("withObservationTracking { _ = model.title } onChange: {}", "R-obs"),
            "Q4": ("center.addObserver(self, selector: #selector(changed), name: nil, object: nil)", "R-notif"),
            "Q5": ("guard !isHiddenOrHasHiddenAncestor else { return }", "R-vis"),
            "Q6": ("try await Task.sleep(for: .seconds(1))", "R-timer"),
            "Q7": ("await MainActor.run { work() }", "R-hop"),
            "Q8": ("override func mouseMoved(with event: NSEvent) {", "R-input"),
            "QA": ("override func viewDidChangeEffectiveAppearance() {", "R-appear"),
        }
        for queue, (line, recipe) in lines.items():
            with self.subTest(queue):
                found = [(h.queue, h.recipe) for h in self.hits(f"{S}A/F.swift", line + "\n")]
                self.assertIn((queue, recipe), found)

    def test_a_line_matches_the_recipe_its_text_needs(self):
        recipes = lambda text: {h.recipe for h in self.hits(f"{S}A/F.swift", text)}
        self.assertEqual(recipes("let d = MainDelivery(owner: \"x\")"), {"R-delivery"})
        self.assertEqual(recipes("CFRunLoopPerformBlock(loop, mode) { }"), {"R-delivery"})
        self.assertEqual(recipes("override func viewDidHide() {"), {"R-hide"})
        self.assertEqual(recipes("monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { $0 }"),
                         {"R-monitor"})

    def test_predicate_waits_and_all_scans_hit_q10_and_q11(self):
        wait = "for await done in ObservationStream(store) { $0.ready } where done { break }"
        self.assertIn(("Q10", "R-wait"), {(h.queue, h.recipe) for h in self.hits(f"{S}A/F.swift", wait)})
        scan_all = "ObservationStream(store) { $0.workspaces.map { $0.id } }"
        self.assertIn(("Q11", "R-index"), {(h.queue, h.recipe) for h in self.hits(f"{S}A/F.swift", scan_all)})
        self.assertIn("Q11", {h.queue for h in self.hits(f"{S}A/F.swift", "let tab = index.locateTab(id)")})

    def test_doc_comment_lines_are_dropped(self):
        self.assertEqual(self.hits(f"{S}A/F.swift", "/// Use `Task { @MainActor in }` here.\n"), [])

    def test_the_observation_primitive_itself_is_not_a_hit(self):
        self.assertEqual(self.hits(f"{S}CmuxNextCompat/ObservationStream.swift", "ObservationStream(x)\n"), [])
        self.assertEqual(self.hits(f"{S}X/ObservationStream.swift", "withObservationTracking {}\n"), [])

    def test_plain_task_counts_only_in_a_main_actor_file(self):
        main = "@MainActor\nfinal class Model {\n    func go() { Task { await load() } }\n}\n"
        self.assertEqual([(h.queue, h.line) for h in self.hits(f"{S}A/M.swift", main)], [("Q1b", 3)])
        view = "final class Badge: NSView {\n    func go() { Task(priority: .low) { await load() } }\n}\n"
        self.assertEqual([h.queue for h in self.hits(f"{S}A/B.swift", view)], ["Q1b"])
        plain = "struct Loader {\n    func go() { Task { await load() } }\n}\n"
        self.assertEqual(self.hits(f"{S}A/L.swift", plain), [])

    def test_the_hops_nonisolated_task_is_not_main_inherited(self):
        off_main = ("@MainActor\nfinal class M {\n    func go() {\n        Task { @concurrent in await load() }\n"
                    "        Task.detached(priority: .utility) { await load() }\n    }\n}\n")
        self.assertEqual(self.hits(f"{S}A/M.swift", off_main), [])

    def test_q1b_reads_arch_counts_main_inherited_tasks_once_task_015_adds_it(self):
        def site(row, line):
            return type("Site", (), {"row": row, "line": line})()

        facts = type("Facts", (), {"sites": [site("observer_sites", 1), site("main_inherited_tasks", 2)]})()
        arch = type("Arch", (), {"ROW_IDS": ("observer_sites", "main_inherited_tasks"),
                                 "analyze": staticmethod(lambda path, text: facts)})
        lines, name = q.main_inherited_predicate(arch)
        self.assertEqual(name, "arch_counts main_inherited_tasks")
        hits = q.scan({f"{S}A/F.swift": "struct S {\n    func go() { Task { await x() } }\n}\n"}, lines)
        self.assertEqual([(h.queue, h.line) for h in hits], [("Q1b", 2)])
        without = type("Arch", (), {"ROW_IDS": ("observer_sites",)})
        self.assertIs(q.main_inherited_predicate(without)[0], q.heuristic_main_inherited)

    def test_an_explicit_main_actor_task_is_q1_not_q1b(self):
        text = "@MainActor final class M {\n    func go() { Task { @MainActor in work() } }\n}\n"
        self.assertEqual([h.queue for h in self.hits(f"{S}A/M.swift", text)], ["Q1"])

    def test_the_queue_rule_escape_marks_a_hit_reviewed(self):
        same = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // main-hop-allow: the C callback needs it\n")
        above = self.hits(f"{S}A/F.swift", "// main-hop-allow: the C callback needs it\nawait MainActor.run { x() }\n")
        wrong_rule = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // timer-class-allow: no\n")
        no_reason = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // main-hop-allow:\n")
        self.assertEqual([h.escaped for h in same + above + wrong_rule + no_reason], [True, True, False, False])

    def test_an_escape_counts_anywhere_in_the_hooks_escape_window(self):
        wrapped = self.hits(f"{S}A/F.swift", "// main-hop-allow: AppKit posts this off main and the order\n"
                                             "// needs the next turn.\nawait MainActor.run { x() }\n")
        attribute = self.hits(f"{S}A/F.swift", "struct V {\n"
                                               "    // timer-class-allow: the race's own deadline\n"
                                               "    @discardableResult\n"
                                               "    func f() async { try? await Task.sleep(for: .seconds(1)) }\n}\n")
        trailing = self.hits(f"{S}A/F.swift", "let a = 1 // raw-observer-allow: KVO on WebKit, the tab node owns it\n"
                                              "center.addObserver(self, selector: s, name: n, object: nil)\n")
        too_far = self.hits(f"{S}A/F.swift", "// main-hop-allow: the C callback needs it\nlet a = 1\n"
                                             "await MainActor.run { x() }\n")
        self.assertEqual([(h.queue, h.escaped) for h in wrapped + attribute + trailing + too_far],
                         [("Q7", True), ("Q6", True), ("Q4", True), ("Q7", False)])

    def test_every_queue_escapes_with_a_rule_of_the_spec(self):
        spec_rules = {"main-hop", "view-observation", "raw-observer", "visibility-walk", "timer-class", "local-monitor"}
        self.assertEqual({queue.rule for queue in q.QUEUES}, spec_rules)

    def test_union_weight_counts_a_line_two_queues_hit_once(self):
        text = "let s = ObservationStream(store) { $0.workspaces.count }\n"
        hits = self.hits(f"{S}A/F.swift", text)
        self.assertEqual({h.queue for h in hits}, {"Q2", "Q11"})
        self.assertEqual(q.file_weights(hits), {f"{S}A/F.swift": 1})


class SettledTests(unittest.TestCase):
    """A site the recipe keeps is settled once its body does only what the recipe allows."""

    def states(self, text):
        return [(h.queue, h.recipe, h.settled) for h in q.scan({f"{S}A/V.swift": text}, q.heuristic_main_inherited)]

    def view(self, *body):
        return "@MainActor\nfinal class V: NSView {\n" + "\n".join(body) + "\n}\n"

    def test_a_main_delivery_with_a_class_is_the_delivery_recipe_target(self):
        self.assertEqual(self.states('let d = MainDelivery(class: .userVisible, owner: "x")\n'),
                         [("Q1c", "R-delivery", True)])
        self.assertEqual(self.states('let d = MainDelivery(\n    class: .userVisible, owner: "x")\n'),
                         [("Q1c", "R-delivery", True)])
        self.assertEqual(self.states('let d = MainDelivery(owner: "x")\n'), [("Q1c", "R-delivery", False)])
        self.assertEqual(self.states("CFRunLoopPerformBlock(loop, mode) { }\n"), [("Q1c", "R-delivery", False)])

    def notif_states(self, files):
        return [(h.path.rsplit("/", 1)[-1], h.queue, h.settled)
                for h in q.scan(files, q.heuristic_main_inherited) if h.recipe == "R-notif"]

    def test_a_notice_name_passed_to_a_subscribe_is_the_notice_recipe_target(self):
        app = 'watch = appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "x") { stop() }\n'
        window = 'watch = WindowEvents.of(w).subscribe( NSWindow.didResignKeyNotification, owner: "x") { stop() }\n'
        self.assertEqual(self.states(app) + self.states(window), [("Q4", "R-notif", True)] * 2)
        raw = 'watch = MainActorObservation(NSApplication.didResignActiveNotification) { stop() }\n'
        listed = "let names = [NSWindow.didMoveNotification]\n"
        workspace = 'events = AppEvents(center: NSWorkspace.shared.notificationCenter)\n'
        both = 'a = events.subscribe(NSWindow.didMoveNotification, owner: "x") { center.addObserver(self) }\n'
        self.assertEqual(self.states(raw) + self.states(listed) + self.states(workspace) + self.states(both),
                         [("Q4", "R-notif", False)] * 4)

    def test_only_the_composition_root_makes_an_app_events(self):
        line = "let workspaceEvents = AppEvents(center: NSWorkspace.shared.notificationCenter)\n"
        self.assertEqual(self.notif_states({q.COMPOSITION_ROOT: line}), [("AppServices.swift", "Q4", True)])
        # A feature's own AppEvents is one more observer per name: R-notif's pattern stays open.
        self.assertEqual(self.notif_states({f"{S}CmuxNextApp/Feature/F.swift": line}), [("F.swift", "Q4", False)])

    def test_hide_and_unhide_that_forward_to_the_node_are_settled(self):
        forward = self.view("    override func viewDidHide() {", "        super.viewDidHide()",
                            "        visibilityNode.setHidden(true)", "    }",
                            "    override func viewDidUnhide() {", "        super.viewDidUnhide()",
                            "        deferUntilVisible { self.refresh() }", "    }")
        self.assertEqual([s for s in self.states(forward) if s[0] == "Q5"],
                         [("Q5", "R-hide", True), ("Q5", "R-hide", True)])
        gating = self.view("    override func viewDidHide() {", "        super.viewDidHide()", "        ticker.cancel()",
                           "    }")
        self.assertEqual([s for s in self.states(gating) if s[0] == "Q5"], [("Q5", "R-hide", False)])

    def test_input_overrides_that_forward_or_coalesce_are_settled(self):
        forward = self.view("    override func mouseMoved(with event: NSEvent) {",
                            "        frameInput.hover(event, in: self)", "        super.mouseMoved(with: event)", "    }",
                            "    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }")
        self.assertEqual([s for s in self.states(forward) if s[0] == "Q8"],
                         [("Q8", "R-input", True), ("Q8", "R-input", True)])
        direct = self.view("    override func mouseDragged(with event: NSEvent) {", "        updateDropTarget(event)",
                           "    }")
        self.assertEqual([s for s in self.states(direct) if s[0] == "Q8"], [("Q8", "R-input", False)])

    def test_appearance_that_sets_layer_colors_or_defers_is_settled(self):
        colors = self.view("    override func viewDidChangeEffectiveAppearance() {",
                           "        super.viewDidChangeEffectiveAppearance()", "        applyColors()", "    }",
                           "    private func applyColors() {",
                           "        layer?.backgroundColor = performWithTheme { Palette.fill.cgColor }",
                           "        separator.layer?.borderColor = NSColor.separatorColor.cgColor", "    }")
        deferred = self.view("    override func viewDidChangeEffectiveAppearance() {",
                             "        super.viewDidChangeEffectiveAppearance()",
                             "        deferUntilVisible { [weak self] in self?.render() }", "    }")
        relayout = self.view("    override func viewDidChangeEffectiveAppearance() {",
                             "        super.viewDidChangeEffectiveAppearance()", "        applyColors()", "    }",
                             "    private func applyColors() {", "        layer?.backgroundColor = .clear",
                             "        needsLayout = true", "    }")
        self.assertEqual([self.states(t) for t in (colors, deferred, relayout)],
                         [[("QA", "R-appear", True)], [("QA", "R-appear", True)], [("QA", "R-appear", False)]])


class PlanTests(unittest.TestCase):
    def test_plan_rows_expand_braces_and_drop_prose(self):
        tsv = WORK_HEADER + work_row(319, "small", f"{S}CmuxNextApp/{{Focus,Cloud}}/") + \
            work_row(327, "Views first half", f"{S}CmuxNextSidebar/Views/ (first half by file name)") + \
            "p06-scheduler-216\tp06-scheduler\tS\t\tQueue generator\tscripts/x.py\n"
        rows = q.parse_plan(tsv)
        self.assertEqual([(r.id, r.specs) for r in rows], [
            (319, (f"{S}CmuxNextApp/Focus/", f"{S}CmuxNextApp/Cloud/")),
            (327, (f"{S}CmuxNextSidebar/Views/",)),
        ])

    def test_root_files_and_named_folders_in_the_prose_are_paths(self):
        tsv = WORK_HEADER + work_row(330, "first", f"{S}CmuxNextAgentPane/ (root files, first half by name)") + \
            work_row(331, "second", f"{S}CmuxNextAgentPane/ (root files second half, FreeTier/, Approvals/)")
        self.assertEqual([r.specs for r in q.parse_plan(tsv)], [
            (f"{S}CmuxNextAgentPane/*.swift",),
            (f"{S}CmuxNextAgentPane/*.swift", f"{S}CmuxNextAgentPane/FreeTier/", f"{S}CmuxNextAgentPane/Approvals/"),
        ])

    def test_a_root_file_glob_matches_root_files_in_its_range_only(self):
        spec = f"{S}CmuxNextApp/[B-M]*.swift"
        self.assertTrue(q.spec_match(f"{S}CmuxNextApp/Browser.swift", spec))
        self.assertFalse(q.spec_match(f"{S}CmuxNextApp/Pane.swift", spec))
        self.assertFalse(q.spec_match(f"{S}CmuxNextApp/Cloud/Move.swift", spec))

    def test_rows_naming_the_same_folder_split_it_by_name_and_a_later_file_joins_its_run(self):
        views = f"{S}CmuxNextSidebar/Views/"
        rows = [q.PlanRow(327, "first", (views,)), q.PlanRow(328, "second", (views,))]
        cut = q.PlannedCut(rows, {f"{views}{c}.swift": 10 for c in "ABCDEFGH"})
        self.assertEqual({c: cut.group_of(f"{views}{c}.swift") for c in "ABCDEFGH"},
                         dict(zip("ABCDEFGH", [327] * 4 + [328] * 4)))
        self.assertEqual([cut.group_of(f"{views}{n}.swift") for n in ("Aa", "Da", "Ea", "Zz")], [327, 327, 328, 328])

    def test_a_file_between_name_ranges_goes_to_the_range_before_it(self):
        handlers = f"{S}CmuxNextApp/Handlers/"
        rows = [q.PlanRow(304, "A-B", (f"{handlers}[A-B]*.swift",)),
                q.PlanRow(305, "C-H", (f"{handlers}[C-H]*.swift",)),
                q.PlanRow(306, "K-W", (f"{handlers}[K-W]*.swift",))]
        cut = q.PlannedCut(rows, {})
        self.assertEqual([cut.group_of(f"{handlers}{n}.swift") for n in ("Bar", "IconMenu", "Jump", "Kill", "Zoom")],
                         [304, 305, 305, 306, 306])
        self.assertIsNone(cut.group_of(f"{handlers}Sub/Deep.swift"))
        self.assertIsNone(cut.group_of(f"{S}CmuxNextApp/Notifications/Center.swift"))

    def test_membership_does_not_move_when_the_q1b_predicate_changes(self):
        views = f"{S}CmuxNextSidebar/Views/"
        rows = [q.PlanRow(327, "first", (views,)), q.PlanRow(328, "second", (views,))]
        tree = {f"{views}{c}.swift": "@MainActor\nfinal class V: NSView {\n"
                + "    func f() { Task { await x() } }\n" * tasks
                + "    func g() async { try? await Task.sleep(for: .seconds(1)) }\n}\n"
                for c, tasks in zip("ABCDEF", (9, 0, 0, 0, 0, 0))}
        heuristic = q.file_weights(q.scan(tree, q.heuristic_main_inherited))
        none = q.file_weights(q.scan(tree, lambda path, text: []))
        # With Q1b weights, A alone would be half the folder; the split reads the regex queues only.
        self.assertEqual(q.split_balanced(sorted(tree), heuristic, 2)[1][0], f"{views}B.swift")
        self.assertNotEqual(heuristic, none)
        cut = q.PlannedCut(rows, q.frozen_weights(q.scan(tree, q.heuristic_main_inherited)))
        self.assertEqual([cut.group_of(f"{views}{c}.swift") for c in "ABCDEF"], [327] * 3 + [328] * 3)


class PackTests(unittest.TestCase):
    def test_a_folder_within_the_limit_stays_in_one_group(self):
        weight = {f"{S}Big/{n}.swift": 20 for n in range(5)} | {f"{S}Small/Sub/{n}.swift": 10 for n in range(6)}
        groups = q.pack(sorted(weight), weight, {f: () for f in weight}, S)
        self.assertIn(sorted(f for f in weight if "/Small/" in f), groups)

    def test_a_large_flat_folder_splits_by_owner_then_by_name(self):
        weight = {f"{S}App/A{n:02}.swift": 5 for n in range(20)} | {f"{S}App/Ghostty{n}.swift": 10 for n in range(5)}
        owners = {f: ("PL-ghostty",) if "Ghostty" in f else () for f in weight}
        groups = q.pack(sorted(weight), weight, owners, S)
        ghostty = [g for g in groups if any("Ghostty" in f for f in g)]
        self.assertEqual(len(ghostty), 1)
        self.assertTrue(all("Ghostty" in f for f in ghostty[0]), ghostty)

    def test_random_trees_put_every_file_in_one_group_within_the_limit(self):
        rng = random.Random(216)
        for _ in range(300):
            weight = {f"{S}M{rng.randrange(6)}/D{rng.randrange(4)}/F{n}.swift": rng.randrange(1, 25)
                      for n in range(rng.randrange(1, 160))}
            owners = {f: (f"PL-{rng.randrange(3)}",) if rng.random() < 0.3 else () for f in weight}
            groups = q.pack(sorted(weight), weight, owners, S)
            flat = [f for g in groups for f in g]
            self.assertEqual(sorted(flat), sorted(weight))
            self.assertEqual(len(flat), len(set(flat)))
            for g in groups:
                self.assertLessEqual(sum(weight[f] for f in g), q.HIGH)

    def test_repack_holds_a_later_file_with_its_name_neighbor(self):
        weight = {f"{S}A/One.swift": 50, f"{S}A/Two.swift": 50, f"{S}B/Three.swift": 10}
        cut = q.PackedCut(weight, {f: () for f in weight})
        self.assertEqual([g.id for g in cut.groups], [300, 301])
        self.assertEqual(cut.group_of(f"{S}A/Ones.swift"), cut.group_of(f"{S}A/One.swift"))
        self.assertEqual(cut.group_of(f"{S}A/Zed.swift"), cut.group_of(f"{S}A/Two.swift"))
        self.assertIsNone(cut.group_of(f"{S}C/New.swift"))


class OwnerTests(unittest.TestCase):
    def test_the_most_specific_owners_row_wins_as_in_the_hook(self):
        guardrails, rows = owner_rows()
        self.assertEqual(q.owners_of(f"{S}CmuxNextSidebar/Views/RowCell.swift", rows, guardrails), ("PL-rows",))
        self.assertEqual(q.owners_of(f"{S}CmuxNextSidebar/Store/Feed.swift", rows, guardrails),
                         ("a590 (sidebar-owner agent)",))
        self.assertEqual(q.owners_of(f"{S}CmuxNextApp/Pane.swift", rows, guardrails), ())
        for path, owners in ((f"{S}CmuxNextSidebar/Views/RowCell.swift", "PL-rows"),
                             (f"{S}CmuxNextTerminal/View.swift", "PL-ghostty (session cmux-b6)")):
            self.assertIn(f"owner {owners}.", guardrails.owner_warnings([path], rows)[0])

    def test_the_repository_owners_file_parses(self):
        guardrails = q._load("guardrails")
        rows = guardrails.parse_owners((SOURCE / q.OWNERS).read_text())
        self.assertEqual(q.owners_of(f"{S}CmuxNextSidebar/Views/X.swift", rows, guardrails),
                         ("a590 (sidebar-owner agent)",))


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-p06-queue-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_NOSYSTEM="1", HOME=str(self.repo))
        self.git("init", "-q", "-b", "main")
        self.write(q.OWNERS, OWNERS_MD)
        self.write(q.PLAN, WORK_HEADER
                   + work_row(327, "Sidebar Views first half", f"{S}CmuxNextSidebar/Views/ (first half by file name)")
                   + work_row(328, "Sidebar Views second half", f"{S}CmuxNextSidebar/Views/ (second half by file name)")
                   + work_row(334, "CmuxNextTerminal", f"{S}CmuxNextTerminal/"))
        # Three queues (Q2 R-obs, Q4 R-notif, QA R-appear) hit RowCell.swift.
        self.write(f"{S}CmuxNextSidebar/Views/RowCell.swift", "\n".join([
            "final class RowCell: NSView {",
            "    let titles = ObservationStream(model) { $0.title }",
            "    func start() { NotificationCenter.default.addObserver(self, selector: #selector(s), name: n, object: nil) }",
            "    override func viewDidChangeEffectiveAppearance() { recolor() }",
            "}", ""]))
        self.write(f"{S}CmuxNextSidebar/Views/Avatar.swift", "func a() async { try? await Task.sleep(for: .seconds(1)) }\n")
        self.write(f"{S}CmuxNextTerminal/Surface.swift", "func s() async { await MainActor.run { draw() } }\n")
        self.write(f"{S}CmuxNextOther/Loose.swift", "override func viewDidChangeEffectiveAppearance() { relayout() }\n")
        self.commit("cut")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def run_main(self, *args, cut="HEAD"):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            code = q.main(["--repo", str(self.repo), "--cut", cut, *args], out=out)
        return code, out.getvalue(), err.getvalue()

    def groups(self):
        code, out, _ = self.run_main("--json")
        self.assertEqual(code, 0)
        return json.loads(out)["groups"]

    def test_a_file_three_queues_hit_is_in_one_group_with_three_recipes(self):
        rows = [(g["id"], f) for g in self.groups() for f in g["files"]
                if f["path"].endswith("/RowCell.swift")]
        self.assertEqual(len(rows), 1)
        _, row = rows[0]
        self.assertEqual(row["recipes"], ["R-obs", "R-notif", "R-appear"])
        self.assertEqual(row["queues"], {"Q2": 1, "Q4": 1, "QA": 1})

    def test_no_file_is_in_two_groups_and_a_file_no_row_covers_is_residual(self):
        paths = [f["path"] for g in self.groups() for f in g["files"]]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(len(paths), 3)
        code, out, _ = self.run_main("--residual")
        self.assertEqual((code, out), (0, f"{S}CmuxNextOther/Loose.swift:1: [QA R-appear] "
                                          "override func viewDidChangeEffectiveAppearance() { relayout() }\n"))
        code, out, err = self.run_main()
        self.assertIn("plan problem: 1 hits in 1 files at the cut are in no WORK.tsv row", err)
        self.assertIn(f"no row (1 hits at the cut, residual for task 347):\n  {S}CmuxNextOther/Loose.swift", out)

    def test_groups_name_the_owners_from_owners_md(self):
        by_id = {g["id"]: g for g in self.groups()}
        self.assertEqual(by_id[334]["owners_to_tell"], ["PL-ghostty (session cmux-b6)"])
        sidebar = [g for g in by_id.values() if any("/CmuxNextSidebar/" in f["path"] for f in g["files"])]
        self.assertEqual({o for g in sidebar for o in g["owners_to_tell"]}, {"PL-rows", "a590 (sidebar-owner agent)"})
        self.assertEqual({g["id"] for g in sidebar}, {327, 328})
        self.assertTrue(all(g["planned"] for g in by_id.values()))

    def test_the_text_report_prints_recipes_owner_and_check_command(self):
        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("group 334 [p06-scheduler-334]: CmuxNextTerminal", out)
        self.assertIn("check: python3 scripts/cmux-next/p06_queue.py --cut HEAD --check 334", out)
        self.assertIn("RowCell.swift: 3 hits, R-obs, R-notif, R-appear (Q2 1, Q4 1, QA 1); owner PL-rows", out)

    def test_check_fails_until_the_hits_are_gone_or_escaped(self):
        code, out, _ = self.run_main("--check", "334")
        self.assertEqual(code, 1)
        self.assertIn("Surface.swift:1: [Q7 R-hop] func s() async { await MainActor.run { draw() } }", out)
        self.write(f"{S}CmuxNextTerminal/Surface.swift",
                   "// main-hop-allow: the renderer callback must finish in this turn\n"
                   "func s() async { await MainActor.run { draw() } }\n")
        code, out, _ = self.run_main("--check", "334")
        self.assertEqual(code, 0, out)
        self.assertIn("group 334: 0 open hits at working tree, 1 escaped, 0 settled", out)
        self.write(f"{S}CmuxNextTerminal/Surface.swift", "func s() { draw() }\n")
        self.assertEqual(self.run_main("--check", "334")[0], 0)

    def test_a_hit_moved_to_a_new_file_in_the_groups_folder_still_fails_the_check(self):
        cut = self.git("rev-parse", "HEAD").strip()
        self.write(f"{S}CmuxNextTerminal/Surface.swift", "func s() { draw() }\n")
        self.write(f"{S}CmuxNextTerminal/Split/SurfaceDraw.swift", "func s() async { await MainActor.run { draw() } }\n")
        self.commit("split the file and keep its hit")
        code, out, _ = self.run_main("--check", "334", cut=cut)
        self.assertEqual(code, 1)
        self.assertIn("CmuxNextTerminal/Split/SurfaceDraw.swift:1: [Q7 R-hop]", out)

    def test_a_hit_moved_out_of_every_row_is_residual_and_the_check_says_so(self):
        cut = self.git("rev-parse", "HEAD").strip()
        self.write(f"{S}CmuxNextTerminal/Surface.swift", "func s() { draw() }\n")
        self.write(f"{S}CmuxNextNew/Surface.swift", "func s() async { await MainActor.run { draw() } }\n")
        self.commit("move the hit to a target no row covers")
        code, out, _ = self.run_main("--check", "334", cut=cut)
        self.assertEqual(code, 0)
        self.assertIn("note: 1 files that had no hits at the cut have hits now and are in no group (--residual): "
                      f"{S}CmuxNextNew/Surface.swift", out)
        code, out, _ = self.run_main("--residual", cut=cut)
        self.assertEqual(code, 0)
        self.assertIn("CmuxNextNew/Surface.swift:1: [Q7 R-hop]", out)

    def test_the_check_is_0_once_every_recipe_is_applied(self):
        self.write(f"{S}CmuxNextSidebar/Views/RowCell.swift", "\n".join([
            "final class RowCell: NSView {",
            "    let titles = VisibleObservation(model, owner: .sidebarRows) { $0.title }",
            "    func start() { events.window.didResize.subscribe(node: node) { [weak self] in self?.s() } }",
            "    override func viewDidChangeEffectiveAppearance() {",
            "        super.viewDidChangeEffectiveAppearance()",
            "        layer?.backgroundColor = Palette.row.cgColor",
            "    }",
            "    override func viewDidHide() { super.viewDidHide(); node.setHidden(true) }",
            "    override func mouseMoved(with event: NSEvent) { inputCoalescer.hover(event) }",
            '    let delivery = MainDelivery(class: .visible, owner: "rows")',
            "}", ""]))
        self.write(f"{S}CmuxNextSidebar/Views/Avatar.swift",
                   "func a() { deadline.arm(after: .seconds(1), class: .idle, alignment: .flexible) }\n")
        for group in (327, 328):
            with self.subTest(group):
                code, out, _ = self.run_main("--check", str(group))
                self.assertEqual(code, 0, out)
        listed = self.run_main("--group", "327")[1] + self.run_main("--group", "328")[1]
        for line, state in ((4, "QA R-appear"), (8, "Q5 R-hide"), (9, "Q8 R-input"), (10, "Q1c R-delivery")):
            self.assertIn(f"RowCell.swift:{line}: [{state} settled]", listed)

    def test_a_planned_row_over_the_limit_is_a_plan_problem(self):
        self.write(f"{S}CmuxNextTerminal/Big.swift", "".join(f"func f{n}() async {{ await MainActor.run {{ }} }}\n"
                                                             for n in range(q.HIGH)))
        self.commit("a heavy terminal")
        code, out, err = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn(f"plan problem: row 334 has {q.HIGH + 1} hits at the cut, over {q.HIGH}: split it in WORK.tsv", err)
        self.assertIn(f"{q.HIGH + 1} hits at the cut (over {q.HIGH}: split the row in WORK.tsv)", out)
        self.assertNotIn("--repack", out)
        self.assertTrue({g["id"]: g for g in self.groups()}[334]["over_limit"])

    def test_an_unknown_group_or_cut_exits_2(self):
        self.assertEqual(self.run_main("--check", "999")[0], 2)
        code, _, err = self.run_main(cut="no-such-rev")
        self.assertEqual(code, 2)
        self.assertIn("is --cut no-such-rev in this clone?", err)

    def test_repack_ignores_the_plan_and_its_check_says_repack(self):
        code, out, _ = self.run_main("--repack", "--json")
        self.assertEqual(code, 0)
        groups = json.loads(out)["groups"]
        self.assertEqual(sorted(f["path"] for g in groups for f in g["files"]),
                         sorted([f["path"] for g in self.groups() for f in g["files"]] + [f"{S}CmuxNextOther/Loose.swift"]))
        self.assertTrue(all(not g["planned"] for g in groups))
        self.assertEqual(groups[0]["id"], 300)
        self.assertEqual({g["check"] for g in groups},
                         {f"python3 scripts/cmux-next/p06_queue.py --cut HEAD --repack --check {g['id']}" for g in groups})

    def test_the_printed_check_names_a_plan_given_on_the_command_line(self):
        plan = self.repo / "other.tsv"
        plan.write_text((self.repo / q.PLAN).read_text())
        self.assertIn(f"check: python3 scripts/cmux-next/p06_queue.py --cut HEAD --plan {plan} --check 334",
                      self.run_main("--plan", str(plan))[1])


@unittest.skipUnless(subprocess.run(["git", "-C", str(SOURCE), "cat-file", "-e", f"{q.CUT_REV}^{{commit}}"],
                                    capture_output=True).returncode == 0, f"{q.CUT_REV} is not in this clone")
class RealCutTests(unittest.TestCase):
    """The spec's cut: every file with hits is in one planned group or in --residual, and the plan's gaps show."""

    @classmethod
    def setUpClass(cls):
        cls.report = q.build(SOURCE, q.CUT_REV, q.CUT_REV, SOURCE / q.PLAN)

    def test_every_file_with_hits_is_in_one_planned_group_or_residual(self):
        report = self.report
        hit_files = {f for f, hs in report.cut_hits.items() if q.open_lines(hs)}
        grouped = [f for g in report.groups for f in report.files(g.id) if f in hit_files]
        residual = {h.path for h in report.residual()}
        self.assertEqual(len(grouped), len(set(grouped)))
        self.assertEqual(set(grouped) | residual, hit_files)
        self.assertFalse(set(grouped) & residual)
        self.assertEqual(residual, set(report.unplanned_at_cut()))
        self.assertEqual([g.id for g in report.groups], list(range(300, 347)))
        self.assertTrue(all(report.files(g.id) for g in report.groups))

    def test_handlers_between_the_ranges_stay_with_handlers(self):
        self.assertEqual(self.report.group_of(f"{S}CmuxNextApp/Handlers/IconMenuVisibility.swift"), 305)

    def test_the_halves_keep_their_split_point_under_another_q1b_predicate(self):
        other = q.build(SOURCE, q.CUT_REV, q.CUT_REV, SOURCE / q.PLAN, predicate=(lambda path, text: [], "none"))
        paths = [f for f in self.report.cut_hits if "/CmuxNextSidebar/Views/" in f or "/CmuxNextAgentPane/" in f]
        self.assertTrue(paths)
        self.assertEqual({p: self.report.group_of(p) for p in paths}, {p: other.group_of(p) for p in paths})


class UndocumentedTests(unittest.TestCase):
    """The frozen Wakeups API lands with DocC on every public signature (task 205)."""

    def test_a_public_declaration_with_no_doc_comment_is_listed(self):
        text = ("public struct A {\n"
                "    /// Documented.\n"
                "    public var x = 0\n"
                "    public var y = 0\n"
                "    /// Past its attribute and a plain comment.\n"
                "    @MainActor\n"
                "    // perf-hot: 0.01ms frame-tick\n"
                "    public func f() {}\n"
                "    public static func == (lhs: A, rhs: A) -> Bool { true }\n"
                "    public var description: String { \"\" }\n"
                "    func internalOne() {}\n"
                "    func reset() {\n"
                "        open = nil\n"
                "    }\n"
                "}\n"
                "public extension A {}\n")
        files = {f"{q.WAKEUPS}A.swift": text, f"{S}CmuxNextApp/B.swift": "public struct B {}\n"}
        self.assertEqual([(p.rsplit("/", 1)[-1], n) for p, n, _ in q.undocumented(files)], [("A.swift", 1), ("A.swift", 4)])

    def test_the_wakeups_module_has_no_undocumented_public_declaration(self):
        self.assertEqual(q.undocumented(q.read_tree(q.ROOT, None)), [])


if __name__ == "__main__":
    unittest.main()
