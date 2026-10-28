#!/usr/bin/env python3
"""Tests for the files gap fixtures (p15-oracle-082): each context against a fake app, and the sweep's use of them.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/files_test.py (stdlib unittest, git on PATH, no app, Linux
too). The fake app answers the socket calls the fixtures make the way the app's handlers do (FilePageOpener's
routes, the registry context of the focused page, the explorer rooted at the focused terminal's folder); the real
app is the fleet run of every-action-sweep.py --only <the closed ids>.
"""

from __future__ import annotations

import copy
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
    """The app as the fixtures see it through action_fixtures.Driver.

    Pages: a file page tab loads (subscribes, reads its config) right after file.open focused it. The code editor
    shows a script-opened file writable only under a `files.roots` folder the host has applied (FilePageProvider
    .inWorkspace); the Markdown page any file it may write. The registry context is published only when the focused
    tab's focus context changes (FocusEffectApplier.publish on a FocusMachine `.publishContext`: terminal, page...),
    and reads the Markdown page's read-only state as of that publish, so a page that loads read only after its open
    published shows markdownEditorFocused until a later focus change.
    """

    def __init__(self):
        self.context, self.pages, self.calls = {"terminalFocused"}, {}, []
        self.base = {"id": "tab_base", "kind": "terminal", "cwd": "/", "context": {"terminalFocused"}}
        self.tabs, self.focus, self.made = [self.base], "tab_base", 0
        self.live = {}  # page id -> the tab whose page debug.page reads
        self.settings, self.applied = {}, {}  # the settings file, and what the host read from it
        self.late = False  # the settings watcher applies a write only at the host's next config read
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
        if method == "action.run":
            return self.run(params["action"], {"target": params.get("target")})
        if method in self.refuse:
            return {"error": {"code": "refused", "message": f"{method} refused"}}
        if method == "action.describe":
            key = PROBES[params["action"]]
            held = key in self.context and key not in self.never
            return {"action": {"id": params["action"], "available": held, **({} if held else {"missing_context": [key]})}}
        if method == "debug.page":
            return self.debug_page(params)
        if method == "snapshot.get":
            panes = [{"id": "pane_1", "tabs": self.tabs}]
            workspace = {"id": "ws_1", "screens": [{"panes": panes}]}
            return {"topology": {"focus": {"tab": self.focus}, "workspaces": [workspace]}}
        if method == "debug.key":
            if params.get("key") == "escape" and self.editing:
                self.editing = False
                self.context.discard("fileExplorerFocused")  # the name edit ends; the keyboard leaves the tree
            return {}
        if method == "settings.get":
            (key,) = params["path"]
            return {"path": [key], "exists": key in self.settings, "value": copy.deepcopy(self.settings.get(key))}
        if method in ("settings.set", "settings.unset"):
            *head, last = params["path"]
            node = self.settings
            for key in head:
                node = node.setdefault(key, {})
            if method == "settings.set":
                node[last] = copy.deepcopy(params["value"])
            else:
                node.pop(last, None)
            if not self.late:
                self.applied = copy.deepcopy(self.settings)
            return {}
        raise AssertionError(f"unexpected rpc {method}")

    def debug_page(self, params):
        tab = self.live.get(params["page"])
        if tab is None:
            return {"error": "no live page"}
        action = params.get("action", "state")
        if action == "state":
            return {"page": params["page"], "subscriptions": self.pages[params["page"]]}
        if action == "query":
            root = {"cmux.editor": ".ed-page", "cmux.markdown": ".md-page"}[params["page"]]
            assert params["selector"] == f"html, {root}", params["selector"]
            html = {"cmuxEditorPhase": "ready"} if params["page"] == "cmux.editor" else {}
            return {"elements": [{"data": html}, {"data": {"readOnly": str(tab["read_only"]).lower()}}]}
        if action == "call":
            assert params["op"] == params["page"] + ".config", params["op"]
            self.applied = copy.deepcopy(self.settings)  # the watcher has caught up by now
            config = {"path": tab["file"], **({"readOnly": True} if self.read_only(tab) else {})}
            return {"t": "ok", "id": 1, "value": config}
        raise AssertionError(f"unexpected debug.page action {action}")

    def wait(self, predicate, seconds):
        return next((value for value in (predicate() for _ in range(3)) if value), None)

    def read_only(self, tab):
        """FileDocument.read for a page tab: not writable, or (code editor, script open) outside every root."""
        path = Path(tab["file"])
        if not os.access(path, os.W_OK):
            return True
        if tab["page"] == "cmux.markdown":
            return False
        roots = (self.applied.get("files") or {}).get("roots") or []
        return not any(str(path).startswith(os.path.realpath(root) + "/") for root in roots)

    def context_of(self, tab):
        if tab.get("page") == "cmux.markdown":
            return {"markdownFocused", "markdownReadOnlyFocused" if tab.get("read_only") else "markdownEditorFocused"}
        return set(tab["context"])

    # Actions, as their handlers answer
    def focus_tab(self, tab, context=None):
        if tab not in self.tabs:
            self.tabs.append(tab)
        if context is not None:
            tab["context"] = set(context)
        before = next((t for t in self.tabs if t["id"] == self.focus), None)
        self.focus = tab["id"]
        if before is not tab and (before is None or before.get("kind") != tab.get("kind")):
            self.context = self.context_of(tab)  # the focus context changed: publish

    def new_id(self):
        self.made += 1
        return f"tab_{self.made}"

    def do_file_open(self, args):
        path = Path(args["path"])
        tab = next((t for t in self.tabs if t.get("file") == str(path)), None)
        if tab is not None:
            self.focus_tab(tab)
            return {}
        page = "cmux.markdown" if path.suffix == ".md" else "cmux.editor"
        tab = {"id": self.new_id(), "kind": "page", "file": str(path), "page": page,
               "context": {"codeEditorFocused"} if page == "cmux.editor" else set()}
        self.focus_tab(tab)
        # The page loads after the open published the context: it subscribes and reads its config.
        self.pages[page] = 0 if page in self.silent else 1
        tab["read_only"] = self.read_only(tab)
        self.live[page] = tab
        return {}

    def do_tab_focus(self, args):
        self.focus_tab(next(t for t in self.tabs if "tab:" + t["id"] == args["target"]))
        return {}

    def do_closeTab(self, args):
        tab = next(t for t in self.tabs if "tab:" + t["id"] == args["target"])
        self.tabs.remove(tab)
        self.live = {page: t for page, t in self.live.items() if t is not tab}
        self.focus_tab(self.base)
        return {}

    def do_openDiffViewer(self, args):
        if not (Path(args["path"]) / ".git").is_dir():
            return {"error": {"code": "not_a_repository", "message": args["path"]}}
        tab = {"id": self.new_id(), "kind": "page", "page": "cmux.diff"}
        self.pages["cmux.diff"], self.live["cmux.diff"] = 1, tab
        self.focus_tab(tab, {"diffViewerFocused"})
        return {}

    def do_newSurface(self, args):
        self.focus_tab({"id": self.new_id(), "kind": "terminal", "cwd": args.get("cwd")}, {"terminalFocused"})
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
        # Holds before and after apply_gap_closures.py drops the closed ids from the baseline: each
        # closed id is still listed with its context's reason or gone, and no gap left needs only this family's contexts.
        needing = {ident for ident, why in GAPS.items()
                   if why.startswith(NEEDS) and set(why[len(NEEDS):].split(", ")) <= set(files.CONTEXTS)}
        self.assertLessEqual(needing, set(files.CLOSES))
        self.assertEqual(set(files.CLOSED_BY), set(files.CONTEXTS))
        for key, ids in files.CLOSED_BY.items():
            for ident in ids:
                self.assertEqual(GAPS.get(ident, NEEDS + key), NEEDS + key, ident)
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

    def test_a_script_opened_code_file_outside_every_root_is_read_only(self):
        # The FakeApp rule the code editor fixture answers (FilePageProvider.inWorkspace, FileDocument.read).
        scratch = files.Scratch()
        self.app.run("file.open", {"path": str(scratch.reset() / "sample.py")})
        self.assertTrue(self.app.live["cmux.editor"]["read_only"])
        self.assertEqual(files.page_shows(self.app, "cmux.editor"), "read only")

    def test_code_editor_opens_sample_writable_under_a_root_and_puts_the_roots_back(self):
        self.app.settings = {"files": {"roots": ["/Users/someone/project"]}, "appearance": "dark"}
        self.app.applied = copy.deepcopy(self.app.settings)
        before = copy.deepcopy(self.app.settings)
        context = self.enter(files.code_editor)
        path = Path(opened(self.app, "file.open")[0]["path"])
        self.assertEqual(self.app.settings["files"]["roots"], ["/Users/someone/project", str(path.parent)])
        self.assertFalse(self.app.live["cmux.editor"]["read_only"])
        self.assertEqual(files.page_shows(self.app, "cmux.editor"), "writable")
        self.assertIsNone(context.enter(self.app))  # the retry keeps the one grant
        self.assertEqual(self.app.settings["files"]["roots"], ["/Users/someone/project", str(path.parent)])
        self.assertIsNone(context.leave(self.app))
        self.assertEqual(self.app.settings, before)

    def test_code_editor_with_no_files_setting_unsets_it_on_leave(self):
        context = self.enter(files.code_editor)
        self.assertIn("files", self.app.settings)
        self.assertIsNone(context.leave(self.app))
        self.assertEqual(self.app.settings, {})

    def test_a_code_editor_page_loaded_before_the_roots_applied_is_opened_again(self):
        self.app.late = True  # the page reads its config before the settings watcher applied files.roots
        context = self.enter(files.code_editor)
        self.assertEqual(len(opened(self.app, "closeTab")), 1)
        self.assertEqual(len(opened(self.app, "file.open")), 2)
        self.assertFalse(self.app.live["cmux.editor"]["read_only"])
        self.assertIn("codeEditorFocused", self.app.context)
        self.assertIsNone(context.leave(self.app))

    def test_a_refused_roots_write_is_named(self):
        self.app.refuse.add("settings.set")
        self.assertEqual(files.code_editor().enter(self.app), "settings.set files.roots: refused: settings.set refused")
        self.assertEqual(opened(self.app, "file.open"), [])

    def test_read_only_markdown_publishes_its_context_by_a_focus_round_trip(self):
        # file.open publishes before the page loads, so the context first says the editor (the app's order).
        scratch = files.Scratch()
        self.app.run("file.open", {"path": str(scratch.reset() / "readonly.md")})
        self.assertTrue(self.app.live["cmux.markdown"]["read_only"])
        self.assertEqual(self.app.context, {"markdownFocused", "markdownEditorFocused"})
        self.app.run("file.open", {"path": str(scratch.root / "readonly.md")})  # selecting it again publishes nothing
        self.assertNotIn("markdownReadOnlyFocused", self.app.context)
        context = self.enter(files.markdown_read_only)
        page = self.app.focus
        self.assertEqual([a["target"] for a in opened(self.app, "tab.focus")], ["tab:tab_base", f"tab:{page}"])
        self.assertEqual(self.app.context, {"markdownFocused", "markdownReadOnlyFocused"})
        self.assertIsNone(context.leave(self.app))

    def test_read_only_markdown_with_no_tab_beside_it_is_named(self):
        self.app.tabs.remove(self.app.base)
        self.assertEqual(files.markdown_read_only().enter(self.app),
                         "no tab beside the cmux.markdown page to publish markdownReadOnlyFocused through")

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
        self.assertEqual([t["id"] for t in self.app.tabs], ["tab_base", "tab_1"])  # the open selected its tab

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
