#!/usr/bin/env python3
"""scripts/cmux-next/p06_queue.py: the p06 scheduler sweep's queues, file groups, recipes, owners and --check.

Acceptance of task p06-scheduler-216: a file three queues hit is in one group with three recipes, no file is
in two groups, and a file's owner is the OWNERS.md row guardrails.py picks. The end-to-end tests commit a
small Sources tree, OWNERS.md and WORK.tsv into a throwaway repository and run main() on it.

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

    def test_an_explicit_main_actor_task_is_q1_not_q1b(self):
        text = "@MainActor final class M {\n    func go() { Task { @MainActor in work() } }\n}\n"
        self.assertEqual([h.queue for h in self.hits(f"{S}A/M.swift", text)], ["Q1"])

    def test_the_queue_rule_escape_marks_a_hit_reviewed(self):
        same = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // main-hop-allow: the C callback needs it\n")
        above = self.hits(f"{S}A/F.swift", "// main-hop-allow: the C callback needs it\nawait MainActor.run { x() }\n")
        wrong_rule = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // timer-class-allow: no\n")
        no_reason = self.hits(f"{S}A/F.swift", "await MainActor.run { x() } // main-hop-allow:\n")
        self.assertEqual([h.escaped for h in same + above + wrong_rule + no_reason], [True, True, False, False])

    def test_union_weight_counts_a_line_two_queues_hit_once(self):
        text = "let s = ObservationStream(store) { $0.workspaces.count }\n"
        hits = self.hits(f"{S}A/F.swift", text)
        self.assertEqual({h.queue for h in hits}, {"Q2", "Q11"})
        self.assertEqual(q.file_weights(hits), {f"{S}A/F.swift": 1})


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

    def test_a_root_file_glob_matches_root_files_in_its_range_only(self):
        spec = f"{S}CmuxNextApp/[B-M]*.swift"
        self.assertTrue(q.spec_match(f"{S}CmuxNextApp/Browser.swift", spec))
        self.assertFalse(q.spec_match(f"{S}CmuxNextApp/Pane.swift", spec))
        self.assertFalse(q.spec_match(f"{S}CmuxNextApp/Cloud/Move.swift", spec))

    def test_rows_naming_the_same_folder_split_it_by_path_into_balanced_halves(self):
        files = {f"{S}CmuxNextSidebar/Views/{c}.swift": 10 for c in "ABCDEFGH"}
        rows = [q.PlanRow(327, "first", (f"{S}CmuxNextSidebar/Views/",)),
                q.PlanRow(328, "second", (f"{S}CmuxNextSidebar/Views/",))]
        groups = {g.id: [Path(f).stem for f in g.files] for g in q.cut(files, {f: () for f in files}, rows)}
        self.assertEqual(groups, {327: list("ABCD"), 328: list("EFGH")})


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

    def test_unplanned_files_get_groups_after_the_planned_ones(self):
        weight = {f"{S}Planned/A.swift": 3, f"{S}Loose/B.swift": 4}
        rows = [q.PlanRow(300, "planned", (f"{S}Planned/",))]
        groups = q.cut(weight, {f: () for f in weight}, rows)
        self.assertEqual([(g.id, g.planned, g.files) for g in groups],
                         [(300, True, [f"{S}Planned/A.swift"]), (350, False, [f"{S}Loose/B.swift"])])
        self.assertEqual([g.id for g in q.cut(weight, {f: () for f in weight}, None)], [300])


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
        self.write(f"{S}CmuxNextOther/Loose.swift", "override func viewDidChangeEffectiveAppearance() {}\n")
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

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            code = q.main(["--repo", str(self.repo), "--cut", "HEAD", *args], out=out)
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

    def test_no_file_is_in_two_groups(self):
        paths = [f["path"] for g in self.groups() for f in g["files"]]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(len(paths), 4)

    def test_groups_name_the_owners_from_owners_md(self):
        by_id = {g["id"]: g for g in self.groups()}
        self.assertEqual(by_id[334]["owners_to_tell"], ["PL-ghostty (session cmux-b6)"])
        sidebar = [g for g in by_id.values() if any("/CmuxNextSidebar/" in f["path"] for f in g["files"])]
        self.assertEqual({o for g in sidebar for o in g["owners_to_tell"]}, {"PL-rows", "a590 (sidebar-owner agent)"})
        self.assertEqual({g["id"] for g in sidebar}, {327, 328})
        loose = [g for g in by_id.values() if not g["planned"]]
        self.assertEqual([(g["id"], g["owners_to_tell"]) for g in loose], [(350, [])])

    def test_the_text_report_prints_recipes_owner_and_check_command(self):
        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("group 334 [p06-scheduler-334]: CmuxNextTerminal", out)
        self.assertIn("check: python3 scripts/cmux-next/p06_queue.py --check 334", out)
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
        self.assertIn("group 334: 0 hits at working tree, 1 escaped", out)
        self.write(f"{S}CmuxNextTerminal/Surface.swift", "func s() { draw() }\n")
        self.assertEqual(self.run_main("--check", "334")[0], 0)

    def test_membership_is_frozen_at_the_cut_and_new_hits_are_residual(self):
        cut = self.git("rev-parse", "HEAD").strip()
        self.write(f"{S}CmuxNextTerminal/New.swift", "func n() async { await MainActor.run { } }\n")
        self.commit("new code after the cut")
        out = io.StringIO()
        self.assertEqual(q.main(["--repo", str(self.repo), "--cut", cut, "--check", "334"], out=out), 1)
        self.assertNotIn("New.swift", out.getvalue())
        out = io.StringIO()
        self.assertEqual(q.main(["--repo", str(self.repo), "--cut", cut, "--residual"], out=out), 0)
        self.assertIn("CmuxNextTerminal/New.swift:1: [Q7 R-hop]", out.getvalue())

    def test_an_unknown_group_or_cut_exits_2(self):
        self.assertEqual(self.run_main("--check", "999")[0], 2)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            code = q.main(["--repo", str(self.repo), "--cut", "no-such-rev"], out=io.StringIO())
        self.assertEqual(code, 2)
        self.assertIn("is --cut no-such-rev in this clone?", err.getvalue())

    def test_repack_ignores_the_plan(self):
        code, out, _ = self.run_main("--repack", "--json")
        self.assertEqual(code, 0)
        groups = json.loads(out)["groups"]
        self.assertEqual(sorted(f["path"] for g in groups for f in g["files"]),
                         sorted(f["path"] for g in self.groups() for f in g["files"]))
        self.assertTrue(all(not g["planned"] for g in groups))
        self.assertEqual(groups[0]["id"], 300)


if __name__ == "__main__":
    unittest.main()
