"""Gap fixtures: the code editor, Markdown and diff pages and the Files explorer on scratch files (p15-oracle-082).

Spec: plans/cmux-next/chrome-parity/design-result.json, p15-oracle task 082; the family interface is
action_fixtures/__init__.py (task 046). Stdlib only, Python 3.9+, safe under `python3 -I`.

Each context below is one registry context key the sweep did not set up (every-action-gaps.json "needs context the
sweep does not set up: KEY"). Its fixture owns a scratch folder, a fresh copy of tests/oracle/fixtures/files/scratch
made in its first `enter` after a `leave`, and makes the focused page show a scratch file:

  codeEditorFocused        file.open of sample.py, writable: the code editor page (FilePageOpener routes other text
                           there). A script's open is not the user's choice, so the editor saves only inside a
                           `files.roots` folder (FilePageProvider.inWorkspace): the scratch folder is one for the
                           enter/leave cycle, and `leave` puts the setting back
  markdownFocused          file.open of notes.md, writable: the Markdown page with its editor
  markdownReadOnlyFocused  file.open of readonly.md, mode 0444: the Markdown page as a file it cannot save. The page
                           learns it is read only when it loads, after file.open published the registry context, and
                           nothing publishes it again (FocusEffectApplier.publish runs on a focus context change), so
                           `enter` focuses a terminal tab beside it and the page again once the page shows the file
                           read only
  diffViewerFocused        openDiffViewer on the repository tests/oracle/fixtures/files/diff.json describes, built by
                           tests/oracle/fixtures/git/make_repo.py: two changed files of two hunks each
  fileExplorerFocused      a terminal tab at scratch explorer/, the right sidebar's Files with the keyboard, and one
                           item New File made there selected (the explorer actions act on the selection)

`enter` holds only when `action.describe` of an action that needs the key no longer lists it in `missing_context`
(the registry context the action runs against) and, for a page, the page listens for commands (`debug.page`
`subscriptions`: PageWebView.send(command:) is false while nothing listens, and the page actions then refuse) and
shows the file as its context needs it (writable, or read only: the page root's data-read-only). A
second `enter` before `leave` opens the same file again, which selects the tab that shows it. What `enter` opens
is a tab the sweep's close_new closes; `leave` hides the right sidebar the explorer showed.

The explorer selects only an item it made itself: Move to Trash and Rename then act on that scratch item, never on
a row of a folder the tree might still show from before.

Chrome reference (chromium/src): base/files/scoped_temp_dir.h gives each test its own folder of files to open;
chrome/test/base/interactive_test_utils.h ui_test_utils::WaitForViewFocus waits for the focus a step needs instead
of sleeping, as `enter` waits for the registry context.
"""

from __future__ import annotations

import atexit
import os
import shutil
import stat
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from action_fixtures import Step, load_module

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
FIXTURES = REPO / "tests" / "oracle" / "fixtures" / "files"
TEMPLATE = FIXTURES / "scratch"
make_repo = load_module(REPO / "tests" / "oracle" / "fixtures" / "git" / "make_repo.py", "action_fixtures_make_repo")

FAMILY = "files"
DIFF_REPO = "diff"  # FIXTURES/diff.json
READ_ONLY = ("readonly.md",)  # scratch files the copy makes mode 0444
EXPLORER = "explorer"  # the scratch folder the explorer's terminal starts in
WAIT_S = 15.0  # a page's first load and the terminal's first cwd report
EDITOR_PAGE = "cmux.editor"
PAGE_ROOT = {EDITOR_PAGE: ".ed-page", "cmux.markdown": ".md-page"}  # the element with data-read-only
FOCUS_KINDS = ("terminal", "chromium", "browser", "chat")  # tab kinds with a focus context of their own
ROOTS = ["files", "roots"]  # FilePageTabHost.userChosenRoots: the folders the code editor saves in


def error_of(reply: Any) -> Optional[str]:
    """Why a socket reply is not a success: its error, its refusal, or no reply."""
    if not isinstance(reply, dict):
        return f"no reply ({type(reply).__name__})"
    error = reply.get("error")
    if error:
        return f"{error.get('code', '')}: {error.get('message', '')}" if isinstance(error, dict) else str(error)
    if reply.get("refused_action"):
        return f"refused: {reply['refused_action']}"
    return None


def context_holds(driver: Any, probe: str, key: str) -> bool:
    """True when `probe` (an action that needs `key` alone) is available: the registry context has `key`."""
    reply = driver.rpc("action.describe", {"action": probe})
    info = reply.get("action") if isinstance(reply, dict) else None
    return isinstance(info, dict) and info.get("available") is not False \
        and key not in (info.get("missing_context") or [])


def page_listens(driver: Any, page: str) -> bool:
    """True when the live `page` (the key window's first) has subscribers: a page command reaches its code."""
    reply = driver.rpc("debug.page", {"page": page, "action": "state"})
    return error_of(reply) is None and (reply.get("subscriptions") or 0) > 0


def focused_tab(topology: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """The tab `snapshot.get`'s topology focuses, or None."""
    tab = (topology.get("focus") or {}).get("tab")
    return next((t for w in topology.get("workspaces") or [] for s in w.get("screens") or []
                 for p in s.get("panes") or [] for t in p.get("tabs") or [] if tab and t.get("id") == tab), None)


def page_shows(driver: Any, page: str) -> Optional[str]:
    """`read only` or `writable`: the file the live `page` loaded, as its root element's data-read-only says
    (EditorPage.tsx, MarkdownPage.tsx). None before the code editor is ready (<html> data-cmux-editor-phase); the
    Markdown page has no phase, so only its `read only` says that it loaded."""
    reply = driver.rpc("debug.page", {"page": page, "action": "query", "selector": f"html, {PAGE_ROOT[page]}"})
    elements = reply.get("elements") if error_of(reply) is None else None
    if not isinstance(elements, list) or len(elements) < 2:
        return None
    html, root = ((e.get("data") or {}) if isinstance(e, dict) else {} for e in elements[:2])
    if page == EDITOR_PAGE and html.get("cmuxEditorPhase") != "ready":
        return None
    return {"true": "read only", "false": "writable"}.get(root.get("readOnly"))


def host_grants(driver: Any, page: str) -> bool:
    """True when the host now answers the live `page`'s config writable (`<page>.config` with no `readOnly`)."""
    reply = driver.rpc("debug.page", {"page": page, "action": "call", "op": f"{page}.config"})
    value = reply.get("value") if isinstance(reply, dict) and reply.get("t") == "ok" else None
    return isinstance(value, dict) and not value.get("readOnly")


def grant_root(driver: Any, root: Path) -> Tuple[Optional[List[Step]], Optional[str]]:
    """Adds `root` to the `files.roots` setting: (the calls that put the setting back, None), or (None, why)."""
    reply = driver.rpc("settings.get", {"path": ROOTS[:1]})
    error = error_of(reply)
    if error:
        return None, f"settings.get files: {error}"
    files = reply.get("value") if reply.get("exists", True) else None
    if files is None:
        undo: List[Step] = [("settings.unset", {"path": ROOTS[:1]})]
    elif not isinstance(files, dict):
        undo = [("settings.set", {"path": ROOTS[:1], "value": files})]
    elif "roots" in files:
        undo = [("settings.set", {"path": ROOTS, "value": files["roots"]})]
    else:
        undo = [("settings.unset", {"path": ROOTS})]
    roots = files.get("roots") if isinstance(files, dict) else None
    folders = [f for f in roots if isinstance(f, str)] if isinstance(roots, list) else []
    error = error_of(driver.rpc("settings.set", {"path": ROOTS, "value": folders + [str(root)]}))
    return (None, f"settings.set files.roots: {error}") if error else (undo, None)


def topology_of(driver: Any) -> Dict[str, Any]:
    reply = driver.rpc("snapshot.get")
    return (reply.get("topology") or {}) if isinstance(reply, dict) else {}


def neighbor_tab(topology: Dict[str, Any], tab: str) -> Optional[str]:
    """A tab of `tab`'s workspace with a focus context of its own (a terminal, else a browser or chat tab)."""
    for workspace in topology.get("workspaces") or []:
        tabs = [t for s in workspace.get("screens") or [] for p in s.get("panes") or [] for t in p.get("tabs") or []]
        if any(t.get("id") == tab for t in tabs):
            others = [t for t in tabs if t.get("id") != tab and t.get("kind") in FOCUS_KINDS]
            others.sort(key=lambda t: t.get("kind") != "terminal")
            return others[0]["id"] if others else None
    return None


def focus_tab(driver: Any, tab: str) -> Optional[str]:
    return error_of(driver.rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True}))


def focused_cwd(driver: Any) -> Optional[str]:
    """The real path of the focused terminal tab's folder, or None."""
    reply = driver.rpc("snapshot.get")
    tab = focused_tab(reply.get("topology") or {}) if isinstance(reply, dict) else None
    cwd = (tab or {}).get("cwd") if (tab or {}).get("kind") == "terminal" else None
    return os.path.realpath(cwd) if cwd else None


@dataclass
class Scratch:
    """One context's scratch folder: made at the first `reset`, removed when the process exits."""

    root: Optional[Path] = None

    def reset(self) -> Path:
        """The folder with a fresh copy of TEMPLATE (read-only files made so); anything else in it stays."""
        if self.root is None:
            self.root = Path(tempfile.mkdtemp(prefix="oracle-files-")).resolve()
            atexit.register(shutil.rmtree, self.root, True)
        for entry in TEMPLATE.iterdir():
            target = self.root / entry.name
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            elif target.exists() or target.is_symlink():
                target.unlink()
            (shutil.copytree if entry.is_dir() else shutil.copyfile)(entry, target)
        for name in READ_ONLY:
            (self.root / name).chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
        return self.root


def file_target(name: str) -> Callable[[Scratch], Path]:
    def target(scratch: Scratch) -> Path:
        return scratch.reset() / name
    return target


def diff_target(scratch: Scratch) -> Path:
    """The diff repository's work folder, built the first time (make_repo builds a repository once)."""
    root = scratch.reset()
    work = root / make_repo.REPOS_DIR / DIFF_REPO
    if not work.exists():
        fixture = make_repo.RepoFixture.load(DIFF_REPO, FIXTURES)
        work = make_repo.build(fixture, root, dict(os.environ)).work
    return work


@dataclass
class PageContext:
    """`key` holds while the focused page `page` shows the scratch file `target` makes, opened by `opener`."""

    key: str
    page: str  # the page descriptor id (KeyRouter.markdownPageID, diffPageID, codeEditorPageID)
    probe: str  # an action that requires `key` alone
    opener: str  # the action that opens `path` as a focused tab
    target: Callable[[Scratch], Path]
    shows: Optional[str] = None  # `writable` or `read only`: how the loaded page must show the file (None: unchecked)
    scratch: Scratch = field(default_factory=Scratch)
    path: Optional[Path] = None  # what this enter/leave cycle opens
    undo: Optional[List[Step]] = None  # the calls that put `files.roots` back while this cycle's grant stands

    def enter(self, driver: Any) -> Optional[str]:
        if self.path is None:
            try:
                self.path = self.target(self.scratch)
            except (OSError, make_repo.FixtureError) as error:
                return f"scratch files not made: {error}"
        if self.shows == "writable" and self.undo is None:
            self.undo, why = grant_root(driver, self.path.parent)
            if why:
                return why
        why = self.open(driver)
        if not why and self.shows == "writable":
            why = self.writable(driver)
        elif not why and self.shows == "read only":
            why = self.read_only(driver)
        if why:
            return why
        if not driver.wait(lambda: context_holds(driver, self.probe, self.key), WAIT_S):
            return f"{self.key} did not hold after {self.opener} {self.path.name}"
        return None

    def open(self, driver: Any) -> Optional[str]:
        error = error_of(driver.run(self.opener, {"path": str(self.path)}))
        if error:
            return f"{self.opener} {self.path.name}: {error}"
        if not driver.wait(lambda: page_listens(driver, self.page), WAIT_S):
            return f"the {self.page} page has no command subscriber"
        return None

    def writable(self, driver: Any) -> Optional[str]:
        """The page shows the file writable. A page asks for its grant once, as it loads (the editor's store.start),
        so a page that loaded before the settings watcher applied `files.roots` is closed and the file opened again
        once the host grants it."""
        shown = driver.wait(lambda: page_shows(driver, self.page), WAIT_S)
        if shown == "read only":
            if not driver.wait(lambda: host_grants(driver, self.page), WAIT_S):
                return f"files.roots did not make {self.path.name} writable"
            tab = focused_tab(topology_of(driver))
            error = error_of(driver.rpc("action.run", {"action": "closeTab", "target": f"tab:{(tab or {}).get('id')}",
                                                       "origin": "script"}))
            why = f"closeTab of the read-only {self.page} page: {error}" if error else self.open(driver)
            if why:
                return why
            shown = driver.wait(lambda: page_shows(driver, self.page), WAIT_S)
        return None if shown == "writable" else f"the {self.page} page shows {self.path.name} {shown or 'never'}"

    def read_only(self, driver: Any) -> Optional[str]:
        """The page shows the file read only, and the registry context says so. The page learns that as it loads,
        after the open published the context; a focus round trip through a tab with another focus context publishes
        it again (focusing the page tab alone changes no focus context, so publishes nothing)."""
        if not driver.wait(lambda: page_shows(driver, self.page) == "read only", WAIT_S):
            return f"the {self.page} page does not show {self.path.name} read only"
        if context_holds(driver, self.probe, self.key):
            return None
        topology = topology_of(driver)
        page_tab = (focused_tab(topology) or {}).get("id")
        other = neighbor_tab(topology, page_tab) if page_tab else None
        if not other:
            return f"no tab beside the {self.page} page to publish {self.key} through"
        error = focus_tab(driver, other) or focus_tab(driver, page_tab)
        return f"tab.focus to publish {self.key}: {error}" if error else None

    def leave(self, driver: Any) -> Optional[str]:
        self.path = None  # the next enter copies the files again: a sample's save or edit does not carry over
        undo, self.undo = self.undo or [], None
        errors = [error for error in (error_of(driver.rpc(method, params)) for method, params in undo) if error]
        return f"put files.roots back: {errors[0]}" if errors else None


@dataclass
class ExplorerContext:
    """`fileExplorerFocused` with one selected item: the Files tree rooted at scratch explorer/ has the keyboard."""

    key: str = "fileExplorerFocused"
    probe: str = "fileExplorerNewFile"
    scratch: Scratch = field(default_factory=Scratch)
    folder: Optional[Path] = None  # the terminal tab's folder, made this enter/leave cycle
    shown: bool = False  # this cycle showed the right sidebar
    selected: Optional[Path] = None

    def enter(self, driver: Any) -> Optional[str]:
        if self.folder is None:
            try:
                folder = self.scratch.reset() / EXPLORER
            except OSError as error:
                return f"scratch files not made: {error}"
            self.folder = folder
            error = error_of(driver.run("newSurface", {"cwd": str(folder)}))
            if error:
                return f"newSurface at {EXPLORER}/: {error}"
            if not driver.wait(lambda: focused_cwd(driver) == str(folder), WAIT_S):
                return f"the focused terminal did not report {EXPLORER}/ as its folder"
        why = self.focus_tree(driver)
        if why or self.selected is not None:
            return why
        before = set(os.listdir(self.folder))
        error = error_of(driver.run("fileExplorerNewFile", {}))
        made = sorted(set(os.listdir(self.folder)) - before)
        if error or len(made) != 1:
            return f"New File made {made or 'nothing'} in {EXPLORER}/: {error or 'the tree is rooted elsewhere'}"
        self.selected = self.folder / made[0]
        driver.rpc("debug.key", {"key": "escape"})  # ends New File's name edit; the item stays selected
        return self.focus_tree(driver)

    def focus_tree(self, driver: Any) -> Optional[str]:
        error = error_of(driver.run("switchRightSidebarToFiles", {}))
        if error:
            return f"switchRightSidebarToFiles: {error}"
        self.shown = True
        if not driver.wait(lambda: context_holds(driver, self.probe, self.key), WAIT_S):
            return f"{self.key} did not hold after switchRightSidebarToFiles"
        return None

    def leave(self, driver: Any) -> Optional[str]:
        shown, self.folder, self.shown, self.selected = self.shown, None, False, None
        if not shown:
            return None
        # A launch's right sidebar starts hidden (RightSidebarModel, hermetic defaults); enter showed it.
        error = error_of(driver.run("toggleRightSidebar", {}))
        return f"hide the right sidebar: {error}" if error else None


def code_editor() -> PageContext:
    return PageContext("codeEditorFocused", EDITOR_PAGE, "fileEditorZoomIn", "file.open", file_target("sample.py"),
                       shows="writable")


def markdown() -> PageContext:
    return PageContext("markdownFocused", "cmux.markdown", "markdownZoomIn", "file.open", file_target("notes.md"))


def markdown_read_only() -> PageContext:
    return PageContext("markdownReadOnlyFocused", "cmux.markdown", "markdownGoToTop", "file.open",
                       file_target("readonly.md"), shows="read only")


def diff_viewer() -> PageContext:
    return PageContext("diffViewerFocused", "cmux.diff", "diffViewerNextLine", "openDiffViewer", diff_target)


CONTEXTS = {"codeEditorFocused": code_editor, "markdownFocused": markdown,
            "markdownReadOnlyFocused": markdown_read_only, "diffViewerFocused": diff_viewer,
            "fileExplorerFocused": ExplorerContext}

# The gap ids each context closes (every-action-gaps.json: "needs context the sweep does not set up: KEY").
CLOSED_BY: Dict[str, Tuple[str, ...]] = {
    "codeEditorFocused": ("fileEditorAction", "fileEditorGotoLine", "fileEditorReplace", "fileEditorZoomIn",
                          "fileEditorZoomOut", "fileEditorZoomReset", "saveFilePreview", "toggleFileEditorWordWrap"),
    "markdownFocused": ("markdownBack", "markdownForward", "markdownLink", "markdownReload",
                        "markdownResetTableWidths", "markdownSave", "markdownZoomIn", "markdownZoomOut",
                        "markdownZoomReset"),
    "markdownReadOnlyFocused": ("markdownGoToTop",),
    "diffViewerFocused": ("diffViewerGoToBottom", "diffViewerGoToTop", "diffViewerHalfPageDown",
                          "diffViewerHalfPageUp", "diffViewerNextFile", "diffViewerNextHunk", "diffViewerNextLine",
                          "diffViewerPreviousFile", "diffViewerPreviousHunk", "diffViewerPreviousLine",
                          "diffViewerSearch"),
    "fileExplorerFocused": ("fileExplorerCopyPath", "fileExplorerCopyRelativePath", "fileExplorerMoveToTrash",
                            "fileExplorerNewFile", "fileExplorerNewFolder", "fileExplorerOpenAsText",
                            "fileExplorerOpenSelection", "fileExplorerRename"),
}
CLOSES = tuple(sorted(ident for ids in CLOSED_BY.values() for ident in ids))
