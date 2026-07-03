#!/usr/bin/env python3
"""Regression guard for the workspace-sidebar lazy-layout contract.

The workspace sidebar renders its rows as a `LazyVStack` inside a vertical
`ScrollView`. Keeping that stack lazy at *measure time* is load-bearing: the
sidebar is re-diffed on every workspace/telemetry update, so any code that
forces SwiftUI to realize and measure the whole row list on each layout pass
turns a routine update into a multi-second `GraphHost.flushTransactions()`
main-thread livelock once enough workspaces/surfaces are open.

This exact class of bug has regressed four times:

  * #2586  GeometryReader + PreferenceKey -> @State height feedback loop
  * #5764  per-row String id allocation in the ForEach diff
  * #5845  same livelock family, reintroduced
  * #6033 -> #6210  `SidebarRowsFillLayout`, a custom `Layout` that called
           `subview.sizeThatFits(ProposedViewSize(width:, height: nil))` on the
           `LazyVStack` in both `sizeThatFits` and `placeSubviews`, realizing
           every row each pass. Removed in #6188.

  * #6384  the user-reported ~1s beachball that #6188 fixed.

Until now the contract was defended only by inline comments, which CI cannot
enforce. This guard scans the two functions that define the sidebar's
steady-state scroll layout in `Sources/ContentView.swift`
(`workspaceScrollContent` and `workspaceRows`) and fails if either:

  1. reintroduces a whole-list measurement signature
     (`GeometryReader`, `ProposedViewSize(... nil ...)`, `.sizeThatFits(`, the
     deleted `SidebarRowsFillLayout`, or ANY custom `Layout`-conforming type
     discovered in the codebase being applied to the rows -- so renaming the
     force-measuring layout does not dodge the guard), or
  2. drops one of the lazy-fill primitives the fix relies on
     (`LazyVStack(` in `workspaceRows`, `.frame(minHeight:` in
     `workspaceScrollContent`).

Comments and string literals are neutralized before scanning, so the historical
explanatory comments in those functions (which deliberately name the very
anti-patterns this guard forbids) do not trip it.

The drag-only drop-target reader (`rowsWithGatedDropTargetReader`) is *not*
scanned: it intentionally uses a `GeometryReader` to resolve per-row drop
anchors and is gated behind an active drag (#5325), so it never runs during the
steady-state layout this guard protects.

Scope: the guard protects the rows layout *as expressed in*
`workspaceScrollContent` / `workspaceRows`. It deliberately does not chase a
force-measure that a future refactor relocates into some other
transitively-called helper function: tracking arbitrary call graphs in a
source-pattern lint is fragile, and extracting the rows layout into a new helper
is a large enough change that it should re-review this guard directly (the
"could not locate function" failure already trips on the most common such
rename). Custom `Layout` types are the exception that *is* chased across files,
because a renamed force-measuring layout is the concrete historical regression
(#6033).

Usage:
    scripts/check-sidebar-lazy-layout.py [--file PATH]

Exit codes:
    0  the scanned file satisfies the lazy-layout contract
    1  an anti-pattern was found, a required primitive is missing, or one of the
       guarded functions could not be located (treated as a failure so the guard
       cannot silently rot into a no-op when the code is renamed).
"""

import argparse
import os
import re
import sys

# Functions that define the sidebar's steady-state scroll layout. Both must
# exist; a rename should fail the guard loudly rather than silently skip.
GUARDED_FUNCTIONS = ("workspaceScrollContent", "workspaceRows")

# Tokens that mean "the whole row list is being measured/realized on every
# layout pass" if they appear in the guarded functions' code (not comments).
FORBIDDEN_PATTERNS = (
    (re.compile(r"\bGeometryReader\b"),
     "GeometryReader (reading the rows' size feeds the #2586 layout feedback "
     "loop / forces row realization at measure time)"),
    (re.compile(r"\bSidebarRowsFillLayout\b"),
     "SidebarRowsFillLayout (the custom Layout removed in #6188 that "
     "force-measured the LazyVStack every pass; do not reintroduce it)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call (measuring a subview by hand realizes the "
     "lazy rows; let SwiftUI size the stack)"),
    (re.compile(r"\bProposedViewSize\s*\([^)]*\bnil\b"),
     "ProposedViewSize(..., nil) (proposing nil on an axis asks the LazyVStack "
     "for its natural size, realizing every row -- the #6210 force-measure)"),
)

# Declaration of a type conforming to SwiftUI's `Layout` protocol. A custom
# Layout applied to the sidebar rows is the #6033/#6210 force-measure shape no
# matter what the type is named, so the guard discovers every such type in the
# codebase and bans ALL of their names from the guarded functions -- not just the
# literal `SidebarRowsFillLayout`. This closes the "rename the layout to dodge the
# guard" bypass (#6870 review).
CUSTOM_LAYOUT_DECL = re.compile(
    r"\b(?:struct|final\s+class|class|enum|extension)\s+([A-Z]\w*)\b[^{]*?\bLayout\b[^{]*?\{",
    re.DOTALL,
)

# Row-view regions guarded against per-row geometry feedback. Four of the five
# historical regressions in this class entered through the row views, not the
# container functions above: the #2586/#6556 GeometryReader -> @State row-height
# probes lived in `TabItemView` and `SidebarWorkspaceGroupHeaderView` (deleted
# by #6111, reintroduced by #4385, deleted by #7117 -- and the reintroduction
# shipped in stable v0.64.17, which livelocked in the wild on 2026-07-02). The
# per-row `.anchorPreference` aggregation of #5323 is the same shape: a row
# publishing its own geometry forces SwiftUI to realize every row per pass.
#
# Rows must not measure themselves, period. Row heights are implicit; the ONLY
# sanctioned geometry path is the container's drag-gated reader
# (`rowsWithGatedDropTargetReader` + `SidebarWorkspaceFrameAnchorModifier`),
# which lives outside these regions. A future legitimate need must extend this
# guard consciously rather than slip past it.
GUARDED_ROW_TYPES = ("TabItemView", "SidebarWorkspaceGroupHeaderView")

ROW_FORBIDDEN_PATTERNS = (
    (re.compile(r"\bGeometryReader\b"),
     "GeometryReader (a row measuring itself feeds the #2586/#6556 "
     "GeometryReader -> @State row-height livelock; row heights are implicit)"),
    (re.compile(r"\bonGeometryChange\b"),
     "onGeometryChange (geometry-driven state writes in a row re-trigger "
     "layout the same way the #6556 GeometryReader probes did)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call (measuring from a row realizes lazy "
     "siblings; let SwiftUI size the row)"),
    (re.compile(r"\bProposedViewSize\s*\([^)]*\bnil\b"),
     "ProposedViewSize(..., nil) (natural-size measurement realizes the lazy "
     "list -- the #6210 force-measure)"),
    (re.compile(r"\.anchorPreference\s*\("),
     ".anchorPreference( in a row (per-row frame publication aggregated by an "
     "ancestor is the #5323 virtualization defeat; only the container's "
     "drag-gated SidebarWorkspaceFrameAnchorModifier may collect row frames)"),
    (re.compile(r"\.overlayPreferenceValue\s*\("),
     ".overlayPreferenceValue( in a row (consuming aggregated row geometry "
     "inside a row is the #5323 feedback shape)"),
)

# Lazy-fill primitives the #6188 fix depends on. Each must remain present in the
# named function (after comments/strings are stripped).
REQUIRED_PRIMITIVES = (
    ("workspaceRows", re.compile(r"\bLazyVStack\s*\("),
     "LazyVStack( -- the rows must stay lazy; a plain VStack realizes every "
     "row on each pass and re-livelocks at scale"),
    ("workspaceScrollContent", re.compile(r"\.frame\s*\(\s*minHeight:"),
     ".frame(minHeight:) -- the measurement-free fill primitive that replaced "
     "SidebarRowsFillLayout; do not remove it"),
)


def neutralize_swift(source):
    """Return ``source`` with comment and string-literal *contents* replaced by
    spaces, preserving every character's position and all newlines.

    Token and brace scanning runs on this neutralized text so that tokens which
    appear only inside the explanatory comments (e.g. the words
    ``SidebarRowsFillLayout`` or ``sizeThatFits(height: nil)``) are invisible to
    the guard, and so braces/parens inside comments or strings never corrupt the
    function-body matching.
    """
    out = []
    i = 0
    n = len(source)
    LINE_COMMENT, BLOCK_COMMENT, STRING, MULTILINE_STRING = 1, 2, 3, 4
    state = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if state == 0:
            if ch == "/" and nxt == "/":
                out.append("  ")
                i += 2
                state = LINE_COMMENT
                continue
            if ch == "/" and nxt == "*":
                out.append("  ")
                i += 2
                state = BLOCK_COMMENT
                continue
            if source[i:i + 3] == '"""':
                # Swift multi-line string literal: only a closing `"""` ends it,
                # so a bare `"` inside must NOT toggle string state -- otherwise
                # the inner quote would close the literal early and expose the
                # rest (e.g. a forbidden token named in prose) as apparent code,
                # tripping the guard with a false positive. (#6870 review)
                out.append('"""')
                i += 3
                state = MULTILINE_STRING
                continue
            if ch == '"':
                out.append('"')
                i += 1
                state = STRING
                continue
            out.append(ch)
            i += 1
            continue
        if state == LINE_COMMENT:
            if ch == "\n":
                out.append("\n")
                state = 0
            else:
                out.append(" ")
            i += 1
            continue
        if state == BLOCK_COMMENT:
            if ch == "*" and nxt == "/":
                out.append("  ")
                i += 2
                state = 0
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue
        if state == STRING:
            if ch == "\\" and nxt != "":
                # Preserve the escape pair as spaces so positions stay aligned.
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                out.append('"')
                i += 1
                state = 0
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if state == MULTILINE_STRING:
            if source[i:i + 3] == '"""':
                out.append('"""')
                i += 3
                state = 0
                continue
            # A lone `"` does not close a multi-line string; only `"""` does.
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
    return "".join(out)


def extract_function_body(neutralized, func_name):
    """Return the brace-matched body text of ``func <func_name>(`` in the
    neutralized source, or ``None`` if the function is not found.

    Handles multi-line signatures by walking parenthesis depth until the
    parameter list closes, then brace-matching from the body's opening ``{``.
    """
    match = re.search(r"\bfunc\s+" + re.escape(func_name) + r"\s*\(", neutralized)
    if not match:
        return None
    i = match.end() - 1  # at the opening '(' of the parameter list
    n = len(neutralized)
    paren_depth = 0
    # Walk until the parameter-list parens balance back to zero.
    while i < n:
        ch = neutralized[i]
        if ch == "(":
            paren_depth += 1
        elif ch == ")":
            paren_depth -= 1
            if paren_depth == 0:
                i += 1
                break
        i += 1
    else:
        return None
    # Find the body's opening brace (skip the `-> some View` return clause).
    while i < n and neutralized[i] != "{":
        # A premature ';' or top-level '}' means there was no body.
        if neutralized[i] == "}":
            return None
        i += 1
    if i >= n:
        return None
    brace_depth = 0
    start = i
    while i < n:
        ch = neutralized[i]
        if ch == "{":
            brace_depth += 1
        elif ch == "}":
            brace_depth -= 1
            if brace_depth == 0:
                return neutralized[start:i + 1]
        i += 1
    return None


def extract_type_body(neutralized, type_name):
    """Return the brace-matched body text of ``struct/class <type_name>`` in the
    neutralized source, or ``None`` if the declaration is not found.

    Walks from the declaration keyword to the body's opening ``{`` (skipping
    generic parameters and the conformance list), then brace-matches.
    """
    match = re.search(
        r"\b(?:struct|final\s+class|class)\s+" + re.escape(type_name) + r"\b",
        neutralized,
    )
    if not match:
        return None
    i = match.end()
    n = len(neutralized)
    while i < n and neutralized[i] != "{":
        if neutralized[i] == ";":
            return None
        i += 1
    if i >= n:
        return None
    brace_depth = 0
    start = i
    while i < n:
        ch = neutralized[i]
        if ch == "{":
            brace_depth += 1
        elif ch == "}":
            brace_depth -= 1
            if brace_depth == 0:
                return neutralized[start:i + 1]
        i += 1
    return None


# Directory names that hold build artifacts, VCS data, or vendored third-party
# code. Pruned from the repo-owned Swift walk: a Layout pulled from an external
# dependency is out of scope (you would have to import it), and SwiftPM checkout
# trees under `.build` are huge.
EXCLUDED_DIR_NAMES = frozenset({
    ".build", ".git", "DerivedData", "Vendor", "vendor", "ThirdParty",
    "third_party", "Pods", "Carthage", "node_modules",
})


def repo_owned_swift_files(repo_root):
    """Yield every repo-owned Swift source path under ``Sources/`` and
    ``Packages/`` (where cmux migrates app code), pruning build/VCS/vendored
    directories. Scanning both keeps the custom-Layout discovery from being
    bypassed by defining the force-measuring layout in a package. (#6870 review)
    """
    for top in ("Sources", "Packages"):
        root = os.path.join(repo_root, top)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]
            for filename in filenames:
                if filename.endswith(".swift"):
                    yield os.path.join(dirpath, filename)


def find_custom_layout_type_names(paths):
    """Return the set of type names conforming to SwiftUI's `Layout` protocol
    across ``paths`` (comment/string-neutralized so a `: Layout` in prose is not
    counted). Cheap-filtered to files that mention ``Layout`` at all.
    """
    names = set()
    seen = set()
    for path in paths:
        try:
            real = os.path.realpath(path)
        except OSError:
            continue
        if real in seen:
            continue
        seen.add(real)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            continue
        if "Layout" not in text:
            continue
        for match in CUSTOM_LAYOUT_DECL.finditer(neutralize_swift(text)):
            names.add(match.group(1))
    return names


def check_source(
    source,
    custom_layout_names=None,
    require_functions=True,
    required_row_types=(),
    scan_all_rows=False,
    required_markers=(),
):
    """Return a list of human-readable violation strings (empty == clean).

    ``require_functions`` controls whether the two container functions must be
    present: True for ContentView.swift, False for row-view files like
    SidebarWorkspaceGroupHeaderView.swift (which do not contain them), or
    "auto" for ad-hoc ``--file`` runs -- container checks then apply only when
    at least one guarded function exists in the source, so a row-view file
    scans cleanly while a fixture that renamed ONE function still fails loudly.
    ``required_row_types`` names GUARDED_ROW_TYPES that must exist in this
    source -- a rename fails loudly instead of silently skipping the region.
    Row types that are merely present are always scanned.

    ``scan_all_rows`` applies the row-forbidden patterns to the ENTIRE
    neutralized source instead of extracted type regions. Used for row-wrapper
    files (e.g. VerticalTabsSidebar+WorkspaceGroups.swift) whose modifier
    sites wrap a row before it enters the LazyVStack: a GeometryReader or
    anchorPreference added around the header there defeats laziness exactly
    like one inside the row view. ``required_markers`` are substrings that
    must appear in the source so a rename/move fails loudly.
    """
    custom_layout_names = custom_layout_names or set()
    neutralized = neutralize_swift(source)
    violations = []
    bodies = {}
    if require_functions == "auto":
        require_functions = any(
            re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\(", neutralized)
            for name in GUARDED_FUNCTIONS
        )
    if require_functions:
        for func_name in GUARDED_FUNCTIONS:
            body = extract_function_body(neutralized, func_name)
            if body is None:
                violations.append(
                    "could not locate func {0}(...) in the source. The sidebar "
                    "lazy-layout guard must be updated to track the renamed "
                    "function (refusing to pass as a no-op).".format(func_name)
                )
                continue
            bodies[func_name] = body

    for func_name, body in bodies.items():
        for pattern, description in FORBIDDEN_PATTERNS:
            if pattern.search(body):
                violations.append(
                    "{0}(...) reintroduces a forbidden whole-list measurement: "
                    "{1}".format(func_name, description)
                )
        # A custom Layout (under ANY name) applied to the rows wraps the
        # LazyVStack and measures it every pass -- the #6210 shape. Banning the
        # whole discovered set, not just the deleted name, blocks the rename
        # dodge (#6870 review).
        for name in sorted(custom_layout_names):
            if re.search(r"\b" + re.escape(name) + r"\b", body):
                violations.append(
                    "{0}(...) applies the custom Layout `{1}` to the sidebar rows. "
                    "A custom Layout wrapping the LazyVStack measures it on every "
                    "pass (the #6210 force-measure shape, regardless of the type's "
                    "name); size the rows with .frame(minHeight:) instead.".format(
                        func_name, name
                    )
                )

    for func_name, pattern, description in REQUIRED_PRIMITIVES:
        body = bodies.get(func_name)
        if body is None:
            continue  # already reported as a missing-function violation
        if not pattern.search(body):
            violations.append(
                "{0}(...) is missing a required lazy-fill primitive: {1}".format(
                    func_name, description
                )
            )

    for marker in required_markers:
        if marker not in neutralized:
            violations.append(
                "could not locate `{0}` in the source. The sidebar lazy-layout "
                "guard must be updated to track the renamed/moved row wrapper "
                "(refusing to pass as a no-op).".format(marker)
            )

    if scan_all_rows:
        for pattern, description in ROW_FORBIDDEN_PATTERNS:
            if pattern.search(neutralized):
                violations.append(
                    "row-wrapper file contains forbidden per-row geometry "
                    "feedback: {0}".format(description)
                )
        for name in sorted(custom_layout_names):
            if re.search(r"\b" + re.escape(name) + r"\b", neutralized):
                violations.append(
                    "row-wrapper file applies the custom Layout `{0}` (the "
                    "#6210 force-measure shape); row wrappers must stay "
                    "measurement-free.".format(name)
                )

    # Row-view regions: rows must never measure or publish their own geometry.
    for type_name in GUARDED_ROW_TYPES:
        body = extract_type_body(neutralized, type_name)
        if body is None:
            if type_name in required_row_types:
                violations.append(
                    "could not locate type {0} in the source. The sidebar "
                    "lazy-layout guard must be updated to track the renamed "
                    "row view (refusing to pass as a no-op).".format(type_name)
                )
            continue
        for pattern, description in ROW_FORBIDDEN_PATTERNS:
            if pattern.search(body):
                violations.append(
                    "{0} contains forbidden per-row geometry feedback: "
                    "{1}".format(type_name, description)
                )
        for name in sorted(custom_layout_names):
            if re.search(r"\b" + re.escape(name) + r"\b", body):
                violations.append(
                    "{0} applies the custom Layout `{1}`. A custom Layout in a "
                    "sidebar row measures its subtree every pass (the #6210 "
                    "force-measure shape); rows must stay measurement-free.".format(
                        type_name, name
                    )
                )

    return violations


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_targets():
    """(path, require_functions, required_row_types, scan_all_rows,
    required_markers) per scanned file.

    ContentView.swift holds the container functions and TabItemView; the group
    header row view lives in its own file with neither container function; the
    group-header ROW WRAPPER (`sidebarWorkspaceGroupHeader(...)`) lives in a
    third file whose modifier sites wrap the header before it enters the
    LazyVStack, so the whole file is scanned for the row-forbidden shapes.
    """
    root = repo_root_dir()
    return (
        (
            os.path.join(root, "Sources", "ContentView.swift"),
            True,
            ("TabItemView",),
            False,
            (),
        ),
        (
            os.path.join(root, "Sources", "SidebarWorkspaceGroupHeaderView.swift"),
            False,
            ("SidebarWorkspaceGroupHeaderView",),
            False,
            (),
        ),
        (
            os.path.join(root, "Sources", "VerticalTabsSidebar+WorkspaceGroups.swift"),
            False,
            (),
            True,
            ("sidebarWorkspaceGroupHeader",),
        ),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        default=None,
        help="Swift source file to scan (defaults to Sources/ContentView.swift "
             "+ Sources/SidebarWorkspaceGroupHeaderView.swift).",
    )
    args = parser.parse_args(argv)

    if args.file:
        # "auto": ad-hoc scans of a row-view file (no container functions)
        # skip the container checks instead of failing on their absence; a
        # source containing any guarded function still has both enforced.
        targets = ((args.file, "auto", (), False, ()),)
    else:
        targets = default_targets()

    # Discover custom Layout type names from the target files plus every
    # repo-owned Swift source (Sources/ and Packages/), so a renamed
    # force-measuring layout defined in any app file or package is still banned
    # from the guarded regions.
    layout_scan_paths = [target[0] for target in targets]
    layout_scan_paths.extend(sorted(repo_owned_swift_files(repo_root_dir())))
    custom_layout_names = find_custom_layout_type_names(layout_scan_paths)

    exit_code = 0
    for target, require_functions, required_row_types, scan_all_rows, required_markers in targets:
        try:
            with open(target, "r", encoding="utf-8") as handle:
                source = handle.read()
        except OSError as error:
            print("check-sidebar-lazy-layout: cannot read {0}: {1}".format(target, error),
                  file=sys.stderr)
            exit_code = 1
            continue

        violations = check_source(
            source,
            custom_layout_names,
            require_functions=require_functions,
            required_row_types=required_row_types,
            scan_all_rows=scan_all_rows,
            required_markers=required_markers,
        )
        if violations:
            print("check-sidebar-lazy-layout: FAILED for {0}".format(target),
                  file=sys.stderr)
            for violation in violations:
                print("  - {0}".format(violation), file=sys.stderr)
            print(
                "\nThe workspace sidebar must keep its rows lazy at measure time "
                "and its rows measurement-free. See #6188 / #6210 / #6384 / #6556 "
                "and the comments in workspaceScrollContent / workspaceRows.",
                file=sys.stderr,
            )
            exit_code = 1
            continue

        print("check-sidebar-lazy-layout: ok ({0})".format(target))

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
