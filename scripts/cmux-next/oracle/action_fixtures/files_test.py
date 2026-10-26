#!/usr/bin/env python3
"""Tests for the files gap fixtures (p15-oracle-082): each context against a fake app, and the sweep's use of them.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/files_test.py (stdlib unittest, git on PATH, no app, Linux
too). The fake app answers the socket calls the fixtures make the way the app's handlers do (FilePageOpener's
routes, the registry context of the focused page, the explorer rooted at the focused terminal's folder); the real
app is the fleet run of every-action-sweep.py --only <the closed ids>.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORACLE = HERE.parent
SCRIPTS = ORACLE.parent
sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402

CATALOG = SCRIPTS.parent / "fuzz" / "macos-matrix" / "fixtures" / "action-list.json"
SWEEP_ARGV = ["--plan-only", "--catalog", str(CATALOG), "--out", tempfile.mkdtemp(prefix="files-fixture-test-")]
sweep_mod = action_fixtures.load_sweep(SWEEP_ARGV)
files = sweep_mod.FAMILIES.families[[f.name for f in sweep_mod.FAMILIES.families].index("files")].module
GAPS = json.loads((SCRIPTS / "every-action-gaps.json").read_text())["gaps"]
NEEDS = "needs context the sweep does not set up: "
PROBES = {"fileEditorZoomIn": "codeEditorFocused", "markdownZoomIn": "markdownFocused",
          "markdownGoToTop": "markdownReadOnlyFocused", "diffViewerNextLine": "diffViewerFocused",
          "fileExplorerNewFile": "fileExplorerFocused"}


class FakeApp:
    """The app as the fixtures see it through action_fixtures.Driver."""

    def __init__(self):
        self.context, self.pages, self.calls = set(), {}, []
        self.tabs, self.focus = [], None
        self.sidebar = False
        self.root, self.selection, self.editing = None, None, False
        self.refuse, self.never, self.silent = set(), set(), set()
        self.root_elsewhere = None  # the explorer roots here instead of the focused terminal's folder

    # Driver
    def run(self, action, args=None):
        args = dict(args or {})
        self.calls.append((action, args))
        if action in self.refuse:
            return {"error": {"code": "refused", "message": f"{action} refused"}}
        return getattr(self, "do_" + action.replace(".", "_"))(args)

    def rpc(self, method, params=None):
        params = params or {}
        if method == "action.describe":
            key = PROBES[params["action"]]
            held = key in self.context and key not in self.never
            return {"action": {"id": params["action"], "available": held, **({} if held else {"missing_context": [key]})}}
        if method == "debug.page":
            count = self.pages.get(params["page"])
            return {"error": "no live page"} if count is None else {"page": params["page"], "subscriptions": count}
        if method == "snapshot.get":
            panes = [{"id": "pane_1", "tabs": self.tabs}]
            return {"topology": {"focus": {"tab": self.focus}, "workspaces": [{"screens": [{"panes": panes}]}]}}
        if method == "debug.key":
            if params.get("key") == "escape" and self.editing:
                self.editing = False
                self.context.discard("fileExplorerFocused")  # the name edit ends; the keyboard leaves the tree
            return {}
        raise AssertionError(f"unexpected rpc {method}")

    def wait(self, predicate, seconds):
        return next((value for value in (predicate() for _ in range(3)) if value), None)

    # Actions, as their handlers answer
    def focus_tab(self, tab, context):
        if tab not in self.tabs:
            self.tabs.append(tab)
        self.focus, self.context = tab["id"], set(context)

    def do_file_open(self, args):
        path = Path(args["path"])
        tab = next((t for t in self.tabs if t.get("file") == str(path)), None) \
            or {"id": f"tab_{len(self.tabs)}", "kind": "page", "file": str(path)}
        if path.suffix == ".md":
            page = "cmux.markdown"
            context = {"markdownFocused", "markdownEditorFocused" if os.access(path, os.W_OK) else "markdownReadOnlyFocused"}
        else:
            page, context = "cmux.editor", {"codeEditorFocused"}
        tab["page"] = page
        self.pages[page] = 0 if page in self.silent else 1
        self.focus_tab(tab, context)
        return {}

    def do_openDiffViewer(self, args):
        if not (Path(args["path"]) / ".git").is_dir():
            return {"error": {"code": "not_a_repository", "message": args["path"]}}
        self.pages["cmux.diff"] = 1
        self.focus_tab({"id": f"tab_{len(self.tabs)}", "kind": "page", "page": "cmux.diff"}, {"diffViewerFocused"})
        return {}

    def do_newSurface(self, args):
        self.focus_tab({"id": f"tab_{len(self.tabs)}", "kind": "terminal", "cwd": args.get("cwd")}, {"terminalFocused"})
        return {}

    def do_switchRightSidebarToFiles(self, args):
        self.sidebar = True
        tab = next(t for t in self.tabs if t["id"] == self.focus)
        if tab.get("kind") == "terminal":
            root = self.root_elsewhere or tab["cwd"]
            if root != self.root:
                self.root, self.selection = root, None
        self.context = {"fileExplorerFocused"}
        return {}

    def do_fileExplorerNewFile(self, args):
        assert "fileExplorerFocused" in self.context
        taken = set(os.listdir(self.root))
        name = next(n for n in ["untitled"] + [f"untitled {i}" for i in range(2, 99)] if n not in taken)
        (Path(self.root) / name).write_text("")
        self.selection, self.editing = str(Path(self.root) / name), True
        return {}

    def do_toggleRightSidebar(self, args):
        self.sidebar = not self.sidebar
        if not self.sidebar:
            self.context.discard("fileExplorerFocused")
        return {}


def opened(app, action):
    return [args for name, args in app.calls if name == action]


class FamilyTests(unittest.TestCase):
    def test_closes_every_gap_that_needs_one_of_its_contexts(self):
        needing = {ident for ident, why in GAPS.items()
                   if why.startswith(NEEDS) and set(why[len(NEEDS):].split(", ")) <= set(files.CONTEXTS)}
        self.assertEqual(set(files.CLOSES), needing)
        self.assertEqual(set(files.CLOSED_BY), set(files.CONTEXTS))
        for key, ids in files.CLOSED_BY.items():
            for ident in ids:
                self.assertEqual(GAPS[ident], NEEDS + key, ident)
        record = json.loads((action_fixtures.GAP_CLOSURES / "files.json").read_text())
        self.assertEqual(record["family"], "files")
        self.assertEqual(sorted(record["closed"]), list(files.CLOSES))

    def test_the_sweep_plans_each_closed_id_with_its_context(self):
        # The sweep's own FAMILIES loaded this module (scripts/cmux-next/every-action-sweep.py), not a copy.
        self.assertEqual(Path(files.__file__).resolve(), HERE / "files.py")
        self.assertEqual({k: v for k, v in sweep_mod.FAMILIES.owners.items() if v == "files"},
                         dict.fromkeys(files.CONTEXTS, "files"))
        sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base, sweep.fixtures = dict(sweep_mod.PLAN_BASE), sweep_mod.PLAN_FIXTURES
        for key, ids in files.CLOSED_BY.items():
            for ident in ids:
                arguments = [{"name": "text", "kind": "string", "required": True}] if ident == "fileEditorAction" else []
                plan, skipped = sweep.plan({"id": ident, "requires": [key], "arguments": arguments})
                self.assertIsNone(skipped, ident)
                self.assertEqual(plan["families"], [key], ident)


class PageContextTests(unittest.TestCase):
    def setUp(self):
        self.app = FakeApp()

    def enter(self, factory):
        context = factory()
        self.assertIsNone(context.enter(self.app))
        return context

    def test_code_editor_opens_scratch_sample(self):
        context = self.enter(files.code_editor)
        path = Path(opened(self.app, "file.open")[0]["path"])
        self.assertEqual(path.read_text(), (files.TEMPLATE / "sample.py").read_text())
        self.assertTrue(str(path).startswith(os.path.realpath(tempfile.gettempdir())))
        self.assertIn("codeEditorFocused", self.app.context)
        self.assertIsNone(context.leave(self.app))

    def test_markdown_is_writable_and_the_read_only_note_is_not(self):
        self.enter(files.markdown)
        self.assertEqual(self.app.context, {"markdownFocused", "markdownEditorFocused"})
        self.enter(files.markdown_read_only)
        self.assertEqual(self.app.context, {"markdownFocused", "markdownReadOnlyFocused"})
        path = Path(opened(self.app, "file.open")[-1]["path"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o222, 0)

    def test_a_second_enter_reopens_the_same_file_and_keeps_it(self):
        context = self.enter(files.markdown)
        path = Path(opened(self.app, "file.open")[0]["path"])
        path.write_text("edited by the sample\n")
        self.assertIsNone(context.enter(self.app))
        self.assertEqual([Path(a["path"]) for a in opened(self.app, "file.open")], [path, path])
        self.assertEqual(path.read_text(), "edited by the sample\n")
        self.assertEqual(len(self.app.tabs), 1)  # the open selected the tab that shows the file

    def test_after_leave_the_next_enter_copies_the_files_again(self):
        context = self.enter(files.markdown_read_only)
        path = Path(opened(self.app, "file.open")[0]["path"])
        path.chmod(0o644)
        path.write_text("saved by the sample\n")
        context.leave(self.app)
        self.assertIsNone(context.enter(self.app))
        self.assertEqual(path.read_text(), (files.TEMPLATE / "readonly.md").read_text())
        self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o222, 0)

    def test_diff_viewer_opens_a_repository_of_two_changed_files(self):
        context = self.enter(files.diff_viewer)
        work = opened(self.app, "openDiffViewer")[0]["path"]
        numstat = subprocess.run(["git", "-C", work, "diff", "--numstat"], capture_output=True, text=True, check=True)
        self.assertEqual([line.split("\t")[2] for line in numstat.stdout.splitlines()], ["src/alpha.txt", "src/beta.txt"])
        hunks = subprocess.run(["git", "-C", work, "diff", "-U3"], capture_output=True, text=True, check=True)
        self.assertEqual(hunks.stdout.count("\n@@ "), 4)
        context.leave(self.app)
        self.assertIsNone(context.enter(self.app))  # built once; a later cycle opens the same repository
        self.assertEqual(opened(self.app, "openDiffViewer")[1]["path"], work)

    def test_a_refused_open_says_which_action_and_why(self):
        self.app.refuse.add("file.open")
        why = files.code_editor().enter(self.app)
        self.assertIn("file.open sample.py", why)
        self.assertIn("file.open refused", why)

    def test_a_context_that_never_holds_is_named(self):
        self.app.never.add("markdownFocused")
        self.assertEqual(files.markdown().enter(self.app), "markdownFocused did not hold after file.open notes.md")

    def test_a_page_with_no_command_subscriber_does_not_hold(self):
        self.app.silent.add("cmux.editor")
        self.assertEqual(files.code_editor().enter(self.app), "the cmux.editor page has no command subscriber")


class ExplorerContextTests(unittest.TestCase):
    def setUp(self):
        self.app = FakeApp()
        self.context = files.ExplorerContext()

    def test_enter_selects_an_item_it_made_in_the_scratch_folder(self):
        self.assertIsNone(self.context.enter(self.app))
        folder = Path(opened(self.app, "newSurface")[0]["cwd"])
        self.assertEqual(folder.name, files.EXPLORER)
        self.assertEqual(self.app.selection, str(folder / "untitled"))
        self.assertEqual(self.context.selected, folder / "untitled")
        self.assertFalse(self.app.editing)
        self.assertTrue(self.app.sidebar)
        self.assertIn("fileExplorerFocused", self.app.context)  # given back to the tree after the name edit

    def test_a_second_enter_keeps_the_terminal_and_the_selection(self):
        self.context.enter(self.app)
        self.assertIsNone(self.context.enter(self.app))
        self.assertEqual(len(opened(self.app, "newSurface")), 1)
        self.assertEqual(len(opened(self.app, "fileExplorerNewFile")), 1)

    def test_leave_hides_the_sidebar_and_the_next_cycle_starts_from_a_fresh_folder(self):
        self.context.enter(self.app)
        folder = Path(opened(self.app, "newSurface")[0]["cwd"])
        self.assertIsNone(self.context.leave(self.app))
        self.assertFalse(self.app.sidebar)
        self.assertIsNone(self.context.enter(self.app))
        self.assertEqual(sorted(os.listdir(folder)), ["readme.txt", "untitled"])

    def test_a_tree_rooted_elsewhere_selects_nothing(self):
        self.app.root_elsewhere = tempfile.mkdtemp(prefix="files-elsewhere-")
        why = self.context.enter(self.app)
        self.assertEqual(why, "New File made nothing in explorer/: the tree is rooted elsewhere")
        self.assertIsNone(self.context.selected)

    def test_a_terminal_that_reports_no_folder_shows_no_sidebar(self):
        self.app.do_newSurface = lambda args: self.app.focus_tab({"id": "tab_t", "kind": "terminal", "cwd": None}, set()) or {}
        self.assertEqual(self.context.enter(self.app), "the focused terminal did not report explorer/ as its folder")
        self.assertIsNone(self.context.leave(self.app))
        self.assertEqual(opened(self.app, "toggleRightSidebar"), [])  # never shown, so never toggled

    def test_a_refused_terminal_is_named(self):
        self.app.refuse.add("newSurface")
        self.assertIn("newSurface at explorer/", self.context.enter(self.app))
        self.assertIsNone(self.context.leave(self.app))
        self.assertFalse(self.app.sidebar)


if __name__ == "__main__":
    unittest.main()
