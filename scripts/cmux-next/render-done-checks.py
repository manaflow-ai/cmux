#!/usr/bin/env python3
"""Rendering done checks and machine queues (plans/cmux-next/chrome-parity/p03-rendering.md, sections 5 and 6).

Runs the static parts of the done checks (DC1, DC6 and DC8b rg parts, DC11) and every MQ count as the rg/comm
queries the plan writes, and prints, per row, the query, the count and the threshold. A fleet and local tool, not a
CI gate (Lawrence 2026-10-23: no new CI tests). Run it at the branch tip at the start and at the end of the push.

  python3 scripts/cmux-next/render-done-checks.py [--repo DIR] [--verbose] [--json OUT] [--pin-window HOURS]
      [--motion J] [--hitches J] [--idle J] [--typing J] [--cef J]
  python3 scripts/cmux-next/render-done-checks.py --frameclients
  python3 scripts/cmux-next/render-done-checks.py --invalidate [PATH ...]

Rows:
  DC*  done checks: PASS or FAIL; any FAIL exits 1.
  MQ*  machine queues: DONE when the unannotated count reaches the threshold, else OPEN (does not fail the run;
       DC11 fails on the queues it names). INFO rows have no threshold (a count to compare across runs).

ghostty-next queries need the submodule initialized at the gitlink the checkout pins, and that gitlink must be the
commit the pinned GhosttyNextKit was built from (the release tag xcframework-<sha>-<flavor> in
Packages/Shared/CmuxGhosttyKit/Package.swift); otherwise the GHOSTTY or GHOSTTY-kit row FAILs (the run exits 1) and
the ghostty rows print SKIP: an uninitialized submodule makes rg print nothing, which would read as done, and a
gitlink off the kit counts source the app does not link.

LANE-ghostty-pins (task 079, the ghostty-next integrator lane) lists the commits that moved the gitlink in the
--pin-window hours before HEAD's commit (default 72), one pin per new gitlink value: DONE at <= 3 pins that each
name a ghostty-next PR (`ghostty-next#N`) in the commit or, for a merge, in a commit it brings that moves the
gitlink, else OPEN.

Annotations (on the hit's line or on the line directly above it, comment-only or the trailing comment of a code
line: the plan's "on the line or the line above", the same rule as task 066's sync-layout guardrail):
`// sync-layout: <why>` (DC11, MQ-sync-layout), `// input-driven: <why>` (MQ-springs, MQ-frameclients),
`// frame-client: <why>` (MQ-frameclients; a hit inside an `#if DEBUG` or `#if DEBUG || CMUX_BENCH_HOOKS` branch
counts as marked too), `// invalidate: <why>` (--invalidate, which also accepts `!= oldValue`, `guard ... !=` and
`if ... !=`), `// tracking-area: <why>` (MQ-tracking-areas), `// draw: <why>` (MQ-draw), `// decode: <why>`
(MQ-image-decode), `LoopVisibility` (MQ-loops). MQ-shadow-path takes `shadowPath` or `// shadow: alpha-derived <why>`
anywhere in the file, as the plan's comm query does.

A scope path that is gone (a renamed directory, a glob that matches nothing) FAILs its row, and an --invalidate PATH
that is in neither the working directory nor the checkout is a usage error: rg prints nothing for a missing path,
which would read as done.

Bench JSON (each optional). Every criterion is its own row; a criterion with no value in the report FAILs, so a wrong
or partial report is never a pass. SKIP rows name the criteria that no report carries (check them by hand).
  --motion   motion-main-work.py (DC2, DC13): per pass with counts, no error and not noisy, counts.frames_2_n
             frame_sets = layouts = window_calls = 0 and update_visibility <= 2; every session, scenario and phase
             needs one such pass. SKIP: MotionClock 'layout' frames.
  --hitches  motion-hitches.py (DC2t, DC3): hitches|hitch_count = 0; main_work_p99_ms <= 0.5;
             max_interval_ms <= 12.5 (1.5 x 8.33 ms)
  --idle     bench_idle.py (DC7r, DC7j): app + daemon wakeups/s <= 1 per scenario, and no app or daemon row that
             is partial (it came or went in the window); render-attributed ledger wakeups (frame clients, display
             links, VSyncHub, Ghostty renderer) = 0
  --typing   typing-frame-bench.py (DC5): key_to_frame_ms p50 <= 8.3, p99 <= 16.7
  --cef      cef-layer-ab.py summary.json (DC10), mode on only: validity.on show.again ok; switch rows
             input_to_commit_ms p95 < 8.3 and longest_frame_ms max <= 8.33; tabs rows e2e p95 < 8.3.
             SKIP: viewDidMoveToWindow on switch-in.

Exit: 0 every DC row passes, 1 a DC row fails (or --frameclients / --invalidate lists a hit), 2 a usage or tool
error (no rg, unreadable JSON, not a cmux checkout).
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Iterator

SOURCES = "Packages/macOS/CmuxNext/Sources"
GHOSTTY = "ghostty-next"
GHOSTTY_KIT = "Packages/Shared/CmuxGhosttyKit/Package.swift"
# The release tag names the ghostty-next commit the xcframework was built from (guardrails.py GHOSTTY_PIN).
GHOSTTY_KIT_PIN = re.compile(r"ghostty-next/releases/download/xcframework-([0-9a-f]{40})-")
# A pin commit names the ghostty-next PRs it brings: `ghostty-next#88` or `manaflow-ai/ghostty-next#88`.
GHOSTTY_PR = re.compile(r"ghostty-next#(\d+)")
PIN_LIMIT = 3
PIN_WINDOW_HOURS = 72


class CheckError(Exception):
    """A tool or input problem: the run cannot say pass or fail."""


# ---------------------------------------------------------------------------------------------------------------
# rg queries


@dataclass(frozen=True)
class Hit:
    path: str
    line: int  # 0 for a file-level (rg -l) hit
    text: str = ""

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.text.strip()}" if self.line else self.path


@dataclass(frozen=True)
class Query:
    pattern: str
    paths: tuple[str, ...] = (SOURCES,)
    globs: tuple[str, ...] = ()
    files: bool = False

    def shell(self) -> str:
        parts = ["rg", "-l" if self.files else "-n", shlex.quote(self.pattern), *self.paths]
        parts += [f"--glob {shlex.quote(g)}" for g in self.globs]
        return " ".join(parts)


class Tree:
    """One checkout: runs queries with rg and reads files for annotations."""

    def __init__(self, root: Path, rg: str) -> None:
        self.root = root
        self.rg = rg
        self._lines: dict[str, list[str]] = {}

    def missing(self, query: Query) -> list[str]:
        """The query's scope paths that do not exist (a glob: that match nothing). A renamed or mistyped scope
        makes rg print nothing, which would read as done."""
        return [p for p in query.paths if not any((self.root / m).exists() for m in self._expand((p,)))]

    def run(self, query: Query) -> list[Hit]:
        paths = [p for p in self._expand(query.paths) if (self.root / p).exists()]
        if not paths:
            return []
        command = [self.rg, "--no-config", "--no-messages", "--with-filename", "--null", "--color=never"]
        command += ["-l"] if query.files else ["-n", "--no-heading"]
        for g in query.globs:
            command += ["--glob", g]
        command += ["-e", query.pattern, "--", *paths]
        done = subprocess.run(command, cwd=self.root, capture_output=True, text=True, errors="replace")
        if done.returncode not in (0, 1):
            raise CheckError(f"rg failed ({done.returncode}) on {query.shell()}: {done.stderr.strip()}")
        hits: list[Hit] = []
        if query.files:
            for path in done.stdout.split("\0"):
                if path.strip():
                    hits.append(Hit(_norm(path.strip()), 0))
        else:
            for row in done.stdout.splitlines():
                path, _, rest = row.partition("\0")
                number, _, text = rest.partition(":")
                if number.isdigit():
                    hits.append(Hit(_norm(path), int(number), text))
        return sorted(hits, key=lambda h: (h.path, h.line))

    def lines(self, path: str) -> list[str]:
        if path not in self._lines:
            try:
                self._lines[path] = (self.root / path).read_text(errors="replace").splitlines()
            except OSError:
                self._lines[path] = []
        return self._lines[path]

    def _expand(self, paths: tuple[str, ...]) -> Iterator[str]:
        for p in paths:
            if any(c in p for c in "*?["):
                yield from sorted(str(m.relative_to(self.root)) for m in self.root.glob(p))
            else:
                yield p


def _norm(path: str) -> str:
    return path[2:] if path.startswith("./") else path


# ---------------------------------------------------------------------------------------------------------------
# annotations

Marker = Callable[[Tree, Hit], bool]


def near(*patterns: str) -> Marker:
    """A hit is marked when its line or the line above matches one of `patterns` (a change check in code)."""
    compiled = [re.compile(p) for p in patterns]

    def marked(tree: Tree, hit: Hit) -> bool:
        lines = tree.lines(hit.path)
        window = lines[max(0, hit.line - 2):hit.line]
        return any(c.search(text) for c in compiled for text in window)

    return marked


def comment(*tags: str) -> Marker:
    """A hit is marked by `// <tag>: <why>` on its line or on the line directly above it, a comment-only line or
    the trailing comment of a code line. This is the plan's rule ("on the line or the line above", DC11 and
    MQ-damage-owners) and the one task 066's sync-layout guardrail applies to added lines."""
    return near(*(rf"//\s*{re.escape(tag)}:\s*\S" for tag in tags))


_IF = re.compile(r"^\s*#if\s+(.*)$")
_ELSEIF = re.compile(r"^\s*#elseif\b")
_ELSE = re.compile(r"^\s*#else\b")
_ENDIF = re.compile(r"^\s*#endif\b")
_DEBUG_CONDITION = re.compile(r"^\(?\s*(DEBUG|CMUX_BENCH_HOOKS)(\s*\|\|\s*(DEBUG|CMUX_BENCH_HOOKS))*\s*\)?$")


def debug_only(tree: Tree, hit: Hit) -> bool:
    """The hit sits in the first branch of an `#if DEBUG` / `#if DEBUG || CMUX_BENCH_HOOKS` block."""
    stack: list[bool] = []  # per open #if: is the current branch a debug-only branch
    for text in tree.lines(hit.path)[:hit.line - 1]:
        code = text.split("//", 1)[0].strip()
        if m := _IF.match(code):
            stack.append(bool(_DEBUG_CONDITION.match(m.group(1).strip())))
        elif (_ELSEIF.match(code) or _ELSE.match(code)) and stack:
            stack[-1] = False
        elif _ENDIF.match(code) and stack:
            stack.pop()
    return any(stack)


def either(*markers: Marker) -> Marker:
    return lambda tree, hit: any(m(tree, hit) for m in markers)


FRAME_CLIENT_MARK = either(comment("input-driven", "frame-client"), debug_only)
INVALIDATE_MARK = either(near(r"!=\s*oldValue", r"\bguard\b.*!=", r"\bif\b.*!="), comment("invalidate"))
SYNC_LAYOUT_MARK = comment("sync-layout")


def file_marked(pattern: str, marker: Marker) -> Callable[[Tree, str], bool]:
    """A file is marked when every line matching `pattern` in it is marked."""
    compiled = re.compile(pattern)

    def marked(tree: Tree, path: str) -> bool:
        lines = tree.lines(path)
        hits = [Hit(path, i + 1, t) for i, t in enumerate(lines) if compiled.search(t)]
        return bool(hits) and all(marker(tree, h) for h in hits)

    return marked


# ---------------------------------------------------------------------------------------------------------------
# rows


@dataclass
class Row:
    id: str
    kind: str  # "done" | "queue" | "info"
    query: str
    count: int | None
    threshold: str  # human form, e.g. "0", "<= 2", "-"
    ok: bool | None  # None for info rows
    note: str = ""
    items: list[str] = field(default_factory=list)
    skipped: bool = False
    broken: bool = False  # the row cannot be counted (a scope path is gone): FAIL whatever its kind

    @property
    def status(self) -> str:
        if self.skipped:
            return "SKIP"
        if self.broken:
            return "FAIL"
        if self.kind == "info" or self.ok is None:
            return "INFO"
        if self.kind == "done":
            return "PASS" if self.ok else "FAIL"
        return "DONE" if self.ok else "OPEN"

    def as_json(self) -> dict:
        return {"id": self.id, "status": self.status, "query": self.query, "count": self.count,
                "threshold": self.threshold, "note": self.note, "items": self.items}


@dataclass(frozen=True)
class LineCheck:
    """Hits of one or more queries; unmarked hits are counted against the threshold."""
    id: str
    kind: str
    queries: tuple[Query, ...]
    threshold: int | None = 0
    marker: Marker | None = None
    note: str = ""
    by_file: bool = False  # count files, not lines (the hit list is still per line when the query is -n)
    allowed: tuple[str, ...] = ()  # file paths (relative to SOURCES or the repo) that may hit
    ghostty: bool = False

    def evaluate(self, tree: Tree) -> Row:
        query = " ; ".join(q.shell() for q in self.queries)
        if broken := scope_row(self.id, self.kind, self.queries, query, tree):
            return broken
        hits = [h for q in self.queries for h in tree.run(q)]
        if self.allowed:
            hits = [h for h in hits if not any(h.path.endswith("/" + a) or h.path == a for a in self.allowed)]
        if self.marker is not None:
            hits = [h for h in hits if not self.marker(tree, h)]
        count = len({h.path for h in hits}) if self.by_file else len(hits)
        ok = None if self.threshold is None else count <= self.threshold
        threshold = "-" if self.threshold is None else str(self.threshold)
        return Row(self.id, self.kind if self.threshold is not None else "info", query, count, threshold, ok,
                   self.note, [str(h) for h in hits])


@dataclass(frozen=True)
class CommCheck:
    """`comm -23` (left minus right) or `comm -12` (both) of two rg -l lists."""
    id: str
    kind: str
    left: Query
    right: Query
    mode: str  # "-23" or "-12"
    file_marker: Callable[[Tree, str], bool] | None = None
    note: str = ""

    def evaluate(self, tree: Tree) -> Row:
        query = f"comm {self.mode} <({self.left.shell()} | sort) <({self.right.shell()} | sort)"
        if broken := scope_row(self.id, self.kind, (self.left, self.right), query, tree):
            return broken
        left = {h.path for h in tree.run(self.left)}
        right = {h.path for h in tree.run(self.right)}
        files = sorted(left - right if self.mode == "-23" else left & right)
        if self.file_marker is not None:
            files = [f for f in files if not self.file_marker(tree, f)]
        return Row(self.id, self.kind, query, len(files), "0", not files, self.note, files)


@dataclass(frozen=True)
class GuardrailListed:
    id: str
    rule: str

    def evaluate(self, tree: Tree) -> Row:
        script = tree.root / "scripts/cmux-next/guardrails.py"
        query = f"python3 scripts/cmux-next/guardrails.py --list | grep '^{self.rule}:'"
        if not script.exists():
            return Row(self.id, "done", query, 0, "1", False, "guardrails.py missing")
        done = subprocess.run([sys.executable, str(script), "--list"], cwd=tree.root, capture_output=True,
                              text=True, timeout=120)
        found = len(re.findall(rf"^{re.escape(self.rule)}:", done.stdout, re.M))
        return Row(self.id, "done", query, found, ">= 1", found >= 1, f"guardrail `{self.rule}` (task 066)")


def scope_row(id: str, kind: str, queries: tuple[Query, ...], query: str, tree: Tree) -> Row | None:
    """A FAIL row when a query's scope path is missing, else None."""
    gone = sorted({p for q in queries for p in tree.missing(q)})
    if not gone:
        return None
    return Row(id, kind, query, None, "-", False, "scope path missing: " + ", ".join(gone), gone, broken=True)


def q(pattern: str, *paths: str, globs: tuple[str, ...] = (), files: bool = False) -> Query:
    return Query(pattern, paths or (SOURCES,), globs, files)


SYNC_LAYOUT = r"layoutSubtreeIfNeeded|displayIfNeeded|\.display\(\)|CATransaction\.flush"
FRAME_CLIENT = r"FrameClient\(owner:"
INVALIDATE = r"needsLayout = true|needsDisplay = true"
DISPLAY_LINK = r"displayLink\(target:|CADisplayLink\(|CVDisplayLink"
TRACKING = r"override (public |open )?func updateTrackingAreas"
CHILD_WINDOW_FALLBACK = "!**/ChildWindowPageFallback.swift"
DISPLAY_LINK_OWNERS = ("CmuxNextWakeups/DisplayClock.swift", "CmuxNextWakeups/VSyncHub.swift")  # one link per display
APP = f"{SOURCES}/CmuxNextApp"
# Views the pane-chrome queue (tasks 071-073, 111) leaves on Auto Layout: none sits in a pane, so a pane
# resized every frame of a drag lays none of them out.
PANE_AUTOLAYOUT_KEPT = (
    "CmuxNextTabs/Groups/Editor/TabGroupEditorControls.swift",  # the group editor bubble, laid out once per open
    "CmuxNextTabs/Groups/Editor/TabGroupEditorPanel.swift",  # its panel
    "CmuxNextTabs/Demo/DemoContentView.swift",  # the tab strip demo's stand-in content, never in a cmux pane
    "CmuxNextBrowser/UI/SidePanelHeaderView.swift",  # Chromium's side panel header, beside the page, not in its chrome
    "CmuxNextBrowser/UI/BrowserCookieImportCard.swift",  # a one-time offer card over the page
    "CmuxNextBrowser/UI/BrowserMediaRowView.swift",  # a card in the media hub menu, laid out once per open, never in a pane
)

REDRAW_POLICY = CommCheck("MQ-redraw-policy", "queue", q(r"override (public |open )?func updateLayer", files=True),
                          q("layerContentsRedrawPolicy", files=True), "-23", note="baseline 59 files")
SHADOW_PATH = CommCheck("MQ-shadow-path", "queue", q("shadowOpacity", files=True),
                        q(r"shadowPath|shadow: alpha-derived", files=True), "-23", note="baseline 11 files")
TRACKING_AREAS = CommCheck("MQ-tracking-areas", "queue", q(TRACKING, files=True), q("inVisibleRect", files=True),
                           "-12", file_marked(TRACKING, comment("tracking-area")),
                           note="files without // tracking-area:; baseline 39 files")
DRAW = LineCheck("MQ-draw", "queue", (q(r"override (public |open )?func draw\(_ "),), 0, comment("draw"),
                 note="without // draw:; baseline 23")
SYNC_LAYOUTS = LineCheck("MQ-sync-layout", "queue", (q(SYNC_LAYOUT),), 0, SYNC_LAYOUT_MARK,
                         note="without // sync-layout: on the line or above; baseline 80")


def as_done_check(check: LineCheck | CommCheck, id: str) -> LineCheck | CommCheck:
    """The DC11 form of a machine queue: the same query, a failing row."""
    return replace(check, id=id, kind="done")


CHECKS = (
    # Done checks (section 5).
    LineCheck("DC1", "done", (q(DISPLAY_LINK, files=True),), 0, allowed=DISPLAY_LINK_OWNERS,
              note="files outside CmuxNextWakeups/DisplayClock.swift and VSyncHub.swift"),
    LineCheck("DC1-ghostty", "info", (q("createWithActiveCGDisplays", f"{GHOSTTY}/src"),), None, ghostty=True,
              note="reached only when vsync_external is off (task 082's test)"),
    LineCheck("DC6-ghostty", "done", (q(r"dispatch_async|queue.getMain",
                                        f"{GHOSTTY}/src/renderer/metal/IOSurfaceLayer.zig"),), 0, ghostty=True),
    LineCheck("DC8b", "done", (q(r"cmuxClipPath|cmuxOcclusionRects|browserChildWindowPagesNeedUpdate",
                                 globs=(CHILD_WINDOW_FALLBACK,)),), 0, note="Track B, after task 045"),
    as_done_check(SYNC_LAYOUTS, "DC11-sync-layout"),
    as_done_check(REDRAW_POLICY, "DC11-redraw-policy"),
    GuardrailListed("DC11-guardrail", "sync-layout"),
    as_done_check(SHADOW_PATH, "DC11-shadow-path"),
    as_done_check(TRACKING_AREAS, "DC11-tracking-areas"),
    as_done_check(DRAW, "DC11-draw"),
    # Machine queues (section 6).
    LineCheck("MQ-springs", "queue", (q(r"SpringValue|AnimatedFrame|advanceUnsettled\(|\.advance\(dt",
                                        globs=("!**/CmuxNextDesign/Motion/**", "!**/CmuxNextDesignTokens/**",
                                               "!**/MotionParityCorpus.swift")),),
              0, comment("input-driven"), by_file=True, note="files; baseline 18"),
    LineCheck("MQ-appkit-frame-animators", "queue",
              (q(r"Motion\.animator\(|animator\(\)\.(frame|setFrame|setBoundsOrigin)"),
               q(r"Motion\.[a-zA-Z]+\.animate\(")), 0, note="both queries; baseline 21 + 36"),
    LineCheck("MQ-frameclients", "queue", (q(FRAME_CLIENT),), 0, FRAME_CLIENT_MARK,
              note="unmarked; baseline 24 sites"),
    LineCheck("MQ-displaylinks", "queue", (q(DISPLAY_LINK),), 0, allowed=DISPLAY_LINK_OWNERS,
              note="cmux side, outside DisplayClock.swift and VSyncHub.swift (DC1's pair)"),
    LineCheck("MQ-displaylinks-ghostty", "info",
              (q(r"createWithActiveCGDisplays|DisplayLink", f"{GHOSTTY}/src/renderer/generic.zig"),), None,
              ghostty=True, note="the DisplayLink path stays for vsync_external off (task 082's test); a count"),
    SYNC_LAYOUTS,
    LineCheck("MQ-damage-owners", "info", (q(INVALIDATE),), None, INVALIDATE_MARK,
              note="unguarded invalidations (--invalidate PATH lists an owner's); the blanket rewrite is out of scope"),
    REDRAW_POLICY,
    LineCheck("MQ-frame-observers", "queue",
              (q(r"frameDidChangeNotification|boundsDidChangeNotification|postsFrameChangedNotifications"),), 0,
              # The DEBUG/bench probe counts frame changes of WebKit's own views: AppKit-only, no hook of ours.
              allowed=("CmuxNextApp/Control/DebugWebInspector.swift",),
              note="baseline 22"),
    LineCheck("MQ-loops", "queue", (q(r"repeatCount = \.infinity"),), 0, near("LoopVisibility"),
              note="not through LoopVisibility; baseline 10"),
    LineCheck("MQ-child-window-pages", "queue",
              (q(r"cmuxClipPath|cmuxOcclusionRects|browserChildWindowPagesNeedUpdate|postGeometryChange|cutouts",
                 globs=(CHILD_WINDOW_FALLBACK,)),), 0),
    LineCheck("MQ-child-windows", "info", (q("addChildWindow"),), None,
              note="classify each: page ordering (delete) or out-of-window popup (keep); baseline 27"),
    LineCheck("MQ-window-per-frame", "queue",
              (q(r"(window|panel|Window|Panel)\??\.alphaValue = |self\.alphaValue = "),
               q(r"(panel|window|bubble)\??\.animator\(\)\.(alphaValue|setFrame)|animator\(\)\.setFrame")), 0,
              note="baseline 13 + 7"),
    LineCheck("MQ-pane-autolayout", "queue",
              (q("translatesAutoresizingMaskIntoConstraints = false",
                 *(f"{SOURCES}/{d}" for d in ("CmuxNextLayout", "CmuxNextTabs", "CmuxNextTerminal",
                                             "CmuxNextBrowser/UI", "CmuxNextBrowser/CEF")),
                 f"{APP}/PaneContentView*.swift", f"{APP}/Screens", f"{APP}/WindowRootView*.swift",
                 f"{APP}/TitlebarView.swift", f"{APP}/EmptyWorkspaceView.swift", files=True),), 0,
              allowed=PANE_AUTOLAYOUT_KEPT, note="files; kept on Auto Layout: PANE_AUTOLAYOUT_KEPT"),
    LineCheck("MQ-ghostty-main-hops", "queue",
              (q(r"dispatch_async|queue.getMain|isMainThread", f"{GHOSTTY}/src/renderer"),), 0, ghostty=True),
    LineCheck("MQ-terminal-contents", "info", (q(r"layer\?\.contents|presentedFrame", f"{SOURCES}/CmuxNextTerminal"),),
              None, note="MQ-ghostty-main-hops, cmux side"),
    LineCheck("MQ-producer-main-hops", "queue", (q("contents = surface", globs=("!**/CmuxNextTerminal/**",)),), 0,
              note="baseline 3"),
    LineCheck("MQ-labels", "info", (q(r"ChromeLabel\("),), None, note="sites sharing one cache; baseline 136"),
    SHADOW_PATH,
    TRACKING_AREAS,
    DRAW,
    LineCheck("MQ-occlusion", "queue",
              (q(r"occlusionState|didChangeOcclusionStateNotification",
                 globs=("!**/WindowOcclusionFamily*.swift", "!**/Debug*.swift"), files=True),), 0,
              note="files outside WindowOcclusionFamily and Debug*; baseline 27"),
    LineCheck("MQ-image-decode", "queue", (q(r"NSImage\(data:|NSImage\(contentsOf"),), 0,
              comment("decode"), note="baseline 19"),
    LineCheck("MQ-web-loops", "info", (q("infinite", "webviews/src"),), None, note="baseline 26"),
    LineCheck("MQ-web-raf", "info", (q(r"requestAnimationFrame\(", "webviews/src"),), None, note="baseline 98"),
)


# ---------------------------------------------------------------------------------------------------------------
# ghostty-next pin


@dataclass(frozen=True)
class GhosttyState:
    pin: str | None  # the gitlink at HEAD
    head: str | None  # the initialized submodule's HEAD
    kit: str | None = None  # the ghostty-next commit HEAD's GhosttyNextKit release was built from

    @property
    def initialized(self) -> bool:
        return self.pin is not None and self.pin == self.head

    @property
    def kit_ok(self) -> bool:
        return self.pin is not None and self.pin == self.kit

    @property
    def ok(self) -> bool:
        return self.initialized and self.kit_ok

    def describe(self) -> str:
        if self.pin is None:
            return f"no {GHOSTTY} gitlink at HEAD"
        if self.head is None:
            return f"{GHOSTTY} is not initialized (pin {self.pin[:12]}): git submodule update --init {GHOSTTY}"
        if self.head != self.pin:
            return (f"{GHOSTTY} is at {self.head[:12]}, the checkout pins {self.pin[:12]}: "
                    f"git submodule update {GHOSTTY}")
        return f"{GHOSTTY} at the pinned {self.pin[:12]}"

    def describe_kit(self) -> str:
        if self.pin is None:
            return f"no {GHOSTTY} gitlink at HEAD"
        if self.kit is None:
            return f"no GhosttyNextKit release url in {GHOSTTY_KIT} at HEAD"
        if self.kit != self.pin:
            return (f"GhosttyNextKit is built from {self.kit[:12]}, the {GHOSTTY} gitlink is {self.pin[:12]}: "
                    "move both in one pin commit")
        return f"GhosttyNextKit built from the gitlink {self.pin[:12]}"


def _git(cwd: Path, *args: str) -> str | None:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def gitlink_at(root: Path, rev: str) -> str | None:
    """The ghostty-next gitlink in REV's tree, or None when REV has none."""
    fields = (_git(root, "ls-tree", rev, GHOSTTY) or "").split()
    return fields[2] if len(fields) >= 3 and fields[0] == "160000" else None


def ghostty_state(root: Path) -> GhosttyState:
    pin = gitlink_at(root, "HEAD")
    module = root / GHOSTTY
    head = None
    if (module / ".git").exists():
        top = _git(module, "rev-parse", "--show-toplevel")
        # Without its own .git the directory resolves to the parent checkout: that is not initialized.
        if top and Path(top).resolve() == module.resolve():
            head = _git(module, "rev-parse", "HEAD")
    kit = GHOSTTY_KIT_PIN.search(_git(root, "show", f"HEAD:{GHOSTTY_KIT}") or "")
    return GhosttyState(pin, head, kit.group(1) if kit else None)


@dataclass(frozen=True)
class PinCommit:
    sha: str
    subject: str
    prs: tuple[int, ...]

    def describe(self) -> str:
        named = ", ".join(f"ghostty-next#{n}" for n in self.prs) or "names no ghostty-next PR"
        return f"{self.sha[:11]} {named}: {self.subject}"


def _named_prs(*messages: str) -> tuple[int, ...]:
    return tuple(dict.fromkeys(int(n) for message in messages for n in GHOSTTY_PR.findall(message)))


def pin_commits(root: Path, hours: int) -> list[PinCommit]:
    """The first-parent commits that moved the ghostty-next gitlink in the HOURS before HEAD's commit time (HEAD's
    time, not the clock, so a checkout gives the same answer whenever it runs), one per new gitlink value.

    A pin usually lands in a merge (`Merge cp/...`), so a merge names its own message's PRs and those of every
    non-merge commit it brings that touches the gitlink (`git log --no-merges C^1..C -- ghostty-next`)."""
    now = _git(root, "log", "-1", "--format=%ct", "HEAD")
    if not now:
        return []
    since = int(now) - hours * 3600
    out = _git(root, "log", "--first-parent", f"--since={since}", "--format=%H%x00%P%x00%B%x01", "HEAD", "--",
               GHOSTTY)
    pins: dict[str, PinCommit] = {}
    for record in (out or "").split("\x01"):
        sha, _, rest = record.strip().partition("\x00")
        value = gitlink_at(root, sha) if sha else None
        if value is None:  # no commit, or one that removes the gitlink: not a pin
            continue
        parents, _, message = rest.partition("\x00")
        message = message.strip()
        brought = ""
        if len(parents.split()) > 1:
            brought = _git(root, "log", "--no-merges", f"{sha}^1..{sha}", "--format=%B", "--", GHOSTTY) or ""
        prs = _named_prs(message, brought)
        if value in pins:  # the same gitlink value again: one pin, naming the PRs of both commits
            seen = pins[value]
            pins[value] = PinCommit(seen.sha, seen.subject, tuple(dict.fromkeys(seen.prs + prs)))
        else:
            pins[value] = PinCommit(sha, message.splitlines()[0] if message else "", prs)
    return list(pins.values())


def pin_lane_row(root: Path, hours: int) -> Row:
    """Task 079: at most PIN_LIMIT GhosttyNextKit pins in the window, each naming the ghostty-next PRs it lands."""
    pins = pin_commits(root, hours)
    unnamed = sum(1 for p in pins if not p.prs)
    note = f"{len(pins)} pins in {hours} h" + (f", {unnamed} naming no ghostty-next PR" if unnamed else "")
    return Row("LANE-ghostty-pins", "queue",
               f"git log --first-parent --since=HEAD-{hours}h HEAD -- {GHOSTTY} ; per merge C: "
               f"git log --no-merges C^1..C -- {GHOSTTY}",
               len(pins), f"<= {PIN_LIMIT}, each names ghostty-next#N", len(pins) <= PIN_LIMIT and not unnamed, note,
               [p.describe() for p in pins])


# ---------------------------------------------------------------------------------------------------------------
# bench JSON


@dataclass(frozen=True)
class Limit:
    op: str  # "<=" or "<"
    value: float

    def holds(self, number: float) -> bool:
        return number < self.value if self.op == "<" else number <= self.value

    def __str__(self) -> str:
        return f"{self.op} {self.value:g}"


Sample = tuple[str, "float | None"]  # (where in the report, the value); None: the report has no value there


def limit_row(id: str, path: str, query: str, limit: Limit, samples: list[Sample], missing: str) -> Row:
    """One done-check criterion: FAIL when a sample breaks the limit or has no value, or there is no sample, so a
    partial report never passes."""
    bad = [f"{where} = {value:g}" for where, value in samples if value is not None and not limit.holds(value)]
    bad += [f"{where}: no value" for where, value in samples if value is None]
    return Row(id, "done", f"{path}: {query}", len(bad), f"{limit} (of {len(samples)})", bool(samples) and not bad,
               "" if samples else missing, bad)


def not_reported(id: str, path: str, criterion: str, why: str) -> Row:
    """A criterion that no bench report carries: printed as SKIP, never a pass."""
    return Row(id, "done", f"{path}: {criterion}", None, "-", None, why, skipped=True)


def _number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _stat(entry: object, key: str, stat: str) -> float | None:
    value = entry.get(key) if isinstance(entry, dict) else None
    return _number(value.get(stat)) if isinstance(value, dict) else None


def walk(node: object, path: str = "") -> Iterator[tuple[str, str, object]]:
    """(json path, key, value) for every dict entry in `node`."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else str(key)
            yield here, str(key), value
            yield from walk(value, here)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from walk(value, f"{path}[{i}]")


@dataclass(frozen=True)
class KeyRule:
    """A criterion read from every key named one of `keys` in the report (motion-hitches.py, typing-frame-bench.py:
    each run or scenario is its own object that holds the key)."""
    dc: str
    keys: tuple[str, ...]  # other names of the same value
    stat: str | None  # None: the number itself, or its `max`
    limit: Limit

    def label(self) -> str:
        return "|".join(self.keys) + (f".{self.stat}" if self.stat else "")

    def samples(self, data: object) -> list[Sample]:
        found: list[Sample] = []
        for path, key, value in walk(data):
            if key not in self.keys:
                continue
            if value is None:
                found.append((path, None))
            elif isinstance(value, dict):
                found.append((path, _number(value.get(self.stat or "max"))))
            elif self.stat is None and _number(value) is not None:
                found.append((path, _number(value)))
        return found


KEY_RULES: dict[str, tuple[KeyRule, ...]] = {
    "hitches": (KeyRule("DC3", ("hitches", "hitch_count"), None, Limit("<=", 0)),
                KeyRule("DC2t", ("main_work_p99_ms",), None, Limit("<=", 0.5)),
                KeyRule("DC3", ("max_interval_ms",), None, Limit("<=", 12.5))),
    "typing": (KeyRule("DC5", ("key_to_frame_ms",), "p50", Limit("<=", 8.3)),
               KeyRule("DC5", ("key_to_frame_ms",), "p99", Limit("<=", 16.7))),
}


def key_rows(name: str, path: str, data: object) -> list[Row]:
    return [limit_row(f"{rule.dc} {rule.label()}", path, f"every {rule.label()}", rule.limit, rule.samples(data),
                      f"no {rule.label()} in the file: not a --{name} report, or a run that did not measure it")
            for rule in KEY_RULES[name]]


MOTION_SCHEMA = "motion-main-work/"
FRAMES_2_N = (("DC2", "frame_sets"), ("DC2", "layouts"), ("DC13", "window_calls"))
QUIET = "passes[] with counts, no error, not noisy"


def motion_rows(path: str, data: object) -> list[Row]:
    """motion-main-work.py: per (session, scenario, phase), the passes whose step ran and whose idle pre-roll had no
    structural work (the script's own `zero_frames_2_n` reads the same passes). Frame 1 is the step's own turn, so
    only `counts.frames_2_n` is judged. A group with no such pass has no evidence, and fails."""
    passes = data.get("passes") if isinstance(data, dict) else None
    if not isinstance(passes, list) or not str(data.get("schema", "")).startswith(MOTION_SCHEMA):
        return [Row("DC2 motion", "done", f"{path}: schema, passes", None, "present", False,
                    f"no {MOTION_SCHEMA}* schema with passes: not a motion-main-work.py report")]
    groups: dict[str, list[dict]] = {}
    for record in passes:
        if isinstance(record, dict):
            name = f"{record.get('session')} {record.get('scenario')} {record.get('phase')}"
            groups.setdefault(name, []).append(record)
    counters: dict[str, list[Sample]] = {key: [] for _, key in FRAMES_2_N}
    visibility: list[Sample] = []
    uncovered = []
    for name, records in groups.items():
        counted = [r for r in records if isinstance(r.get("counts"), dict) and not r.get("error")]
        quiet = [r for r in counted if not r["counts"].get("noisy")]
        if not quiet:
            errors = sorted({str(r["error"]) for r in records if r.get("error")})
            uncovered.append(f"{name}: no quiet counted pass of {len(records)} ({len(counted)} noisy"
                             + "".join(f"; {e}" for e in errors) + ")")
        for record in quiet:
            where = f"{name} #{record.get('round')}"
            after = record["counts"].get("frames_2_n")
            for _, key in FRAMES_2_N:
                counters[key].append((where, _number(after.get(key)) if isinstance(after, dict) else None))
            visibility.append((where, _number(record.get("update_visibility"))))
    rows = [Row("DC2 passes", "done", f"{path}: one or more {QUIET} per session, scenario and phase", len(uncovered),
                "0", bool(groups) and not uncovered, "" if groups else "no pass in the report", uncovered)]
    rows += [limit_row(f"{dc} frames_2_n.{key}", path, f"{QUIET}: counts.frames_2_n.{key}", Limit("<=", 0),
                       counters[key], "no quiet counted pass") for dc, key in FRAMES_2_N]
    rows.append(limit_row("DC2 update_visibility", path, f"{QUIET}: update_visibility", Limit("<=", 2), visibility,
                          "no quiet counted pass"))
    rows.append(not_reported("DC2 MotionClock layout frames", path, "MotionClock 'layout' frames during a spring",
                             "motion-main-work.py does not report them: check by hand"))
    return rows


def _bench(mode: dict, bench: str) -> dict:
    entry = mode.get(bench)
    rows = entry.get("rows") if isinstance(entry, dict) else None
    return rows if isinstance(rows, dict) else {}


TAB_INPUTS = ("ctrl_tab", "cmd_shift_bracket", "click")


def cef_rows(path: str, data: object) -> list[Row]:
    """cef-layer-ab.py summary.json, mode `on` (layer hosting) only: `off` is the child-window baseline. The switch
    rows are sidebar-stress-bench.py switch_matrix entries. The tabs rows are tab-switch-matrix.py's report: its
    end-to-end time (`e2e`: input age + intent to commit) is the input to commit. tab-switch-matrix.py writes no
    frame length, so the longest frame comes from the switch bench only."""
    modes = data.get("modes") if isinstance(data, dict) else None
    on = modes.get("on") if isinstance(modes, dict) else None
    if not isinstance(on, dict):
        return [Row("DC10 cef", "done", f"{path}: modes.on", None, "present", False,
                    "no modes.on: not a cef-layer-ab.py summary.json, or a run without --modes on")]
    validity = data.get("validity") if isinstance(data.get("validity"), dict) else {}
    checks = validity.get("on", {}).get("rows") if isinstance(validity.get("on"), dict) else None
    again = [r for r in checks or [] if isinstance(r, dict) and r.get("check") == "show.again"]
    not_shown = [f"show.again: {json.dumps(r.get('observed'))[:200]}" for r in again if r.get("ok") is not True]
    rows = [Row("DC10 show.again", "done", f"{path}: validity.on.rows[check=show.again].ok", len(not_shown),
                f"true (of {len(again)})", bool(again) and not not_shown,
                "" if again else "no show.again row in validity.on", not_shown)]
    switch = [(key, entry) for key, entry in _bench(on, "switch").items()
              if isinstance(entry, dict) and "input_to_idle_ms" in entry]
    missing = "no modes.on.switch rows (sidebar-stress-bench.py switch_matrix)"
    rows.append(limit_row("DC10 switch input_to_commit_ms.p95", path, "modes.on.switch.rows.*.input_to_commit_ms.p95",
                          Limit("<", 8.3), [(f"switch {k}", _stat(e, "input_to_commit_ms", "p95")) for k, e in switch],
                          missing))
    rows.append(limit_row("DC10 switch longest_frame_ms.max", path, "modes.on.switch.rows.*.longest_frame_ms.max",
                          Limit("<=", 8.33), [(f"switch {k}", _stat(e, "longest_frame_ms", "max")) for k, e in switch],
                          missing))
    tabs: list[Sample] = []
    for scenario in _bench(on, "tabs").get("scenarios") or []:
        if not isinstance(scenario, dict):
            continue
        kind = scenario.get("kind")
        for how in TAB_INPUTS:
            part = scenario.get(how)
            if isinstance(part, dict):
                table = part.get("table") if isinstance(part.get("table"), dict) else {}
                tabs.append((f"tabs {kind} {scenario.get('count')} {how}", _stat(table.get(kind), "e2e", "p95")))
    rows.append(limit_row("DC10 tabs e2e.p95", path, "modes.on.tabs.rows.scenarios[].<input>.table[kind].e2e.p95",
                          Limit("<", 8.3), tabs, "no modes.on.tabs scenarios (tab-switch-matrix.py)"))
    rows.append(not_reported("DC10 viewDidMoveToWindow", path, "viewDidMoveToWindow calls on switch-in",
                             "no bench report counts them: check by hand"))
    return rows


RENDER_OWNER = re.compile(r"DisplayClock|VSyncHub|DisplayLink|FrameScheduler|Ghostty.*([Rr]ender|[Ff]rame|tick)")
RENDER_REASONS = {"frame", "stalled frame"}


def idle_rows(path: str, data: object) -> list[Row]:
    scenarios = data.get("scenarios") if isinstance(data, dict) else None
    if not isinstance(scenarios, dict):
        return [Row("DC7 idle", "done", f"{path}: scenarios", None, "present", False,
                    "no scenarios: not a bench_idle.py report")]
    total_bad, render_bad, measured = [], [], 0
    for name, result in scenarios.items():
        if not isinstance(result, dict) or "processes" not in result:
            continue
        measured += 1
        judged = [r for r in result["processes"] if isinstance(r, dict) and r.get("kind") in ("app", "daemon")]
        # A process that came or went in the window has no rate: bench_idle.py's criteria fail it, and so does this.
        total_bad += [f"{name}: {r['kind']} {r.get('pid')} {r.get('note') or 'partial'}" for r in judged
                      if r.get("partial")]
        wakeups = sum(_number(r.get("wakeups_per_s")) or 0.0 for r in judged if not r.get("partial"))
        if wakeups > 1.0:
            total_bad.append(f"{name}: app + daemon {wakeups:g}/s")
        for entry in result.get("ledger") or []:
            owner, reason = str(entry.get("owner", "")), str(entry.get("reason", ""))
            rate = _number(entry.get("per_second")) or 0.0
            if rate > 0 and (reason in RENDER_REASONS or RENDER_OWNER.search(owner)):
                render_bad.append(f"{name}: {owner} {reason} {rate:g}/s")
    if not measured:
        return [Row("DC7 idle", "done", f"{path}: scenarios.*.processes", None, "present", False,
                    "no measured scenario")]
    return [
        Row("DC7j app+daemon", "done", f"{path}: sum wakeups_per_s of kind app, daemon per scenario; no partial row",
            len(total_bad), f"<= 1/s (of {measured})", not total_bad, "", total_bad),
        Row("DC7r render wakeups", "done", f"{path}: ledger per_second of render owners", len(render_bad), "0",
            not render_bad, "frame clients, display links, VSyncHub, Ghostty renderer", render_bad),
    ]


def load_json(path: str) -> object:
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise CheckError(f"cannot read bench JSON {path}: {error}") from error


def bench_rows(name: str, path: str) -> list[Row]:
    data = load_json(path)
    if name == "idle":
        return idle_rows(path, data)
    if name == "motion":
        return motion_rows(path, data)
    if name == "cef":
        return cef_rows(path, data)
    return key_rows(name, path, data)


# ---------------------------------------------------------------------------------------------------------------
# driver


def evaluate(tree: Tree, ghostty: GhosttyState) -> list[Row]:
    rows = [Row("GHOSTTY", "done", f"git submodule status {GHOSTTY}", None, "pinned", ghostty.initialized,
                ghostty.describe()),
            Row("GHOSTTY-kit", "done", f"git ls-tree HEAD {GHOSTTY} ; GhosttyNextKit url in {GHOSTTY_KIT}", None,
                "same sha", ghostty.kit_ok, ghostty.describe_kit())]
    for check in CHECKS:
        if isinstance(check, LineCheck) and check.ghostty and not ghostty.ok:
            query = " ; ".join(query.shell() for query in check.queries)
            rows.append(Row(check.id, check.kind, query, None, "-", None,
                            "needs ghostty-next initialized at the GhosttyNextKit pin", skipped=True))
            continue
        rows.append(check.evaluate(tree))
    return rows


def failed(rows: list[Row]) -> list[Row]:
    return [r for r in rows if r.status == "FAIL"]


def print_rows(rows: list[Row], verbose: bool, limit: int = 10) -> None:
    for row in rows:
        count = "-" if row.count is None else str(row.count)
        status = row.status
        note = f"  ({row.note})" if row.note else ""
        print(f"{row.id:<28} {status:<5} count {count:<5} threshold {row.threshold}{note}")
        print(f"    query: {row.query}")
        shown = row.items if verbose else (row.items[:limit] if status == "FAIL" else [])
        for item in shown:
            print(f"      {item}")
        if not verbose and status == "FAIL" and len(row.items) > limit:
            print(f"      ... {len(row.items) - limit} more (--verbose)")


def listing(tree: Tree, check: LineCheck, title: str) -> int:
    """--frameclients and --invalidate: the unmarked hits, exit 1 when there is one."""
    row = check.evaluate(tree)
    print(f"{title}: {row.count} (threshold 0)")
    print(f"    query: {row.query}")
    for item in row.items:
        print(f"      {item}")
    return 0 if not row.items else 1


def repo_path(root: Path, path: str) -> str:
    """`path` relative to `root`: read against the working directory first, then against the checkout. A path that
    is in neither, or only outside the checkout, is a usage error (rg would print nothing, which reads as clean)."""
    found = [c.resolve() for c in (Path.cwd() / path, root / path) if c.exists()]
    inside = [c for c in found if c == root or root in c.parents]
    if inside:
        return str(inside[0].relative_to(root))
    if found:
        raise CheckError(f"{path} is outside the checkout {root}")
    raise CheckError(f"{path}: no such file or directory (in {Path.cwd()} or {root})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]), help="cmux checkout root")
    parser.add_argument("--verbose", action="store_true", help="list every hit of every row")
    parser.add_argument("--json", metavar="OUT", help="also write the rows as JSON")
    parser.add_argument("--pin-window", type=int, default=PIN_WINDOW_HOURS, metavar="HOURS",
                        help=f"LANE-ghostty-pins counts gitlink moves in the HOURS before HEAD (default "
                             f"{PIN_WINDOW_HOURS})")
    parser.add_argument("--frameclients", action="store_true",
                        help="only list FrameClient(owner: sites that are neither DEBUG-only nor marked")
    parser.add_argument("--invalidate", nargs="*", metavar="PATH",
                        help="only list needsLayout/needsDisplay = true hits without a change check (in PATHs)")
    for name in ("motion", "hitches", "idle", "typing", "cef"):
        parser.add_argument(f"--{name}", metavar="JSON", help=f"{name} bench report to check")
    args = parser.parse_args(argv)

    root = Path(args.repo).resolve()
    rg = shutil.which("rg")
    try:
        if rg is None:
            raise CheckError("rg (ripgrep) is not on PATH")
        if not (root / SOURCES).is_dir():
            raise CheckError(f"{root} has no {SOURCES}: pass --repo with a cmux checkout")
        tree = Tree(root, rg)
        if args.frameclients:
            check = LineCheck("frameclients", "done", (q(FRAME_CLIENT),), 0, FRAME_CLIENT_MARK)
            return listing(tree, check, "FrameClient sites neither DEBUG-only nor marked")
        if args.invalidate is not None:
            paths = [repo_path(root, p) for p in args.invalidate] or [SOURCES]
            check = LineCheck("invalidate", "done", (q(INVALIDATE, *paths),), 0, INVALIDATE_MARK)
            return listing(tree, check, "invalidations without a change check or // invalidate:")
        rows = evaluate(tree, ghostty_state(root)) + [pin_lane_row(root, args.pin_window)]
        for name in ("motion", "hitches", "idle", "typing", "cef"):
            if getattr(args, name):
                rows += bench_rows(name, getattr(args, name))
    except CheckError as error:
        print(f"render-done-checks: {error}", file=sys.stderr)
        return 2
    print_rows(rows, args.verbose)
    bad = failed(rows)
    if args.json:
        Path(args.json).write_text(json.dumps({"repo": str(root), "rows": [r.as_json() for r in rows]}, indent=2))
    opened = sum(1 for r in rows if r.status == "OPEN")
    print(f"render-done-checks: {len(bad)} failing, {opened} open queues, {len(rows)} rows")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
