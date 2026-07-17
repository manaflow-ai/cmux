#!/usr/bin/env python3
"""Guard the AppKit-owned default sidebar list boundary.

History: the workspace sidebar livelocked repeatedly while it was a SwiftUI
`LazyVStack` (#2586, #5323, #5764, #5845, #5970, #6210, #6556, #6707, #7136,
#8004). Every incident was some invalidation edge firing during the lazy
container's placement pass. The terminal fix (#8224) removed the lazy
container: the default workspace list is one container-level
`NSViewRepresentable` (`SidebarWorkspaceTableView`) wrapping an `NSTableView`;
each row is an isolated `NSHostingView` in a recycled cell, and all list
mutations funnel through `SidebarWorkspaceTableController.apply()`.

This guard keeps that topology from regressing:

  * `workspaceScrollArea` must mount `SidebarWorkspaceTableView` and must not
    reintroduce any SwiftUI list/scroll container.
  * The deleted LazyVStack-era functions must stay deleted.
  * Row types stay measurement-free and platform-view-free (per-cell hosting
    bounds the blast radius of a bad row, but geometry probes and stray
    representables are still per-cell waste and were the historical livelock
    ingredients).
  * AppKit-list sources must never reload/reconfigure the table from an AppKit
    layout lifecycle callback (`layout`, `updateTrackingAreas`,
    `viewDidMoveToWindow`); mutations enter only through `apply()`, input
    events, or scroll notifications.
  * Custom `Layout`-conforming types (under ANY name) may not wrap sidebar
    rows; a renamed `SidebarRowsFillLayout` is discovered project-wide.

The guard fails loudly when a required type/function/file is renamed so it
cannot silently become a no-op.
"""

import argparse
import os
import re
import sys


OLD_DEFAULT_LIST_FUNCTIONS = (
    "workspaceScrollContent",
    "workspaceRows",
    "rowsWithGatedDropTargetReader",
    "bonsplitWorkspaceDropOverlay",
    "workspaceReorderDropOverlay",
)
GUARDED_ROW_TYPES = (
    "TabItemView",
    "SidebarWorkspaceRowView",
    "SidebarWorkspaceGroupHeaderView",
    "SidebarWorkspaceGroupRowView",
)
REPRESENTABLE_ALLOWLIST = {"SidebarInlineRenameField", "GPUSpinner"}
LAYOUT_CALLBACKS = ("layout", "updateTrackingAreas", "viewDidMoveToWindow")
LAYOUT_MUTATION_PATTERNS = (
    re.compile(r"\breloadData\s*\("),
    re.compile(r"\bnoteHeightOfRows\s*\("),
    re.compile(r"\breconfigure(?:Visible)?Rows\s*\("),
    re.compile(r"\.rootView\s*="),
)
SWIFTUI_LIST_CONTAINERS = (
    "ScrollView",
    "ScrollViewReader",
    "LazyVStack",
    "LazyHStack",
    "List",
    "GeometryReader",
)
ROW_FORBIDDEN_PATTERNS = (
    (re.compile(r"\bGeometryReader\b"),
     "GeometryReader (a row measuring itself was the #2586/#6556 "
     "GeometryReader -> @State row-height livelock ingredient; row heights "
     "are owned by AppKit automatic row sizing)"),
    (re.compile(r"\bonGeometryChange\b"),
     "onGeometryChange (geometry-driven state writes in a row re-trigger "
     "layout the same way the #6556 GeometryReader probes did)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call (row measurement belongs to AppKit's live "
     "automatic row sizing, never a separate row-body measurement path)"),
    (re.compile(r"\bProposedViewSize\s*\([^)]*\bnil\b"),
     "ProposedViewSize(..., nil) (natural-size measurement -- the #6210 "
     "force-measure shape)"),
    (re.compile(r"\.anchorPreference\s*\("),
     ".anchorPreference( in a row (per-row frame publication was the #5323 "
     "virtualization defeat; the table controller owns row geometry)"),
    (re.compile(r"\.overlayPreferenceValue\s*\("),
     ".overlayPreferenceValue( in a row (consuming aggregated row geometry "
     "inside a row is the #5323 feedback shape)"),
)
# Declaration of a type conforming to SwiftUI's `Layout` protocol. A custom
# Layout applied to sidebar rows is the #6033/#6210 force-measure shape no
# matter what the type is called; discovery is project-wide so a rename
# cannot dodge the guard.
CUSTOM_LAYOUT_DECLARATION = re.compile(
    r"\b(?:struct|final\s+class|class|enum|extension)\s+([A-Z]\w*)\b[^{]*?\bLayout\b[^{]*?\{",
    re.DOTALL,
)


def neutralize_swift(source):
    """Blank comments and string contents while preserving source positions."""
    out = []
    i = 0
    state = "code"
    block_depth = 0
    while i < len(source):
        ch = source[i]
        pair = source[i:i + 2]
        triple = source[i:i + 3]
        if state == "code":
            if pair == "//":
                out.extend("  ")
                i += 2
                state = "line"
            elif pair == "/*":
                out.extend("  ")
                i += 2
                state = "block"
                block_depth = 1
            elif triple == '\"\"\"':
                out.extend('\"\"\"')
                i += 3
                state = "multiline"
            elif ch == '\"':
                out.append(ch)
                i += 1
                state = "string"
            else:
                out.append(ch)
                i += 1
        elif state == "line":
            out.append("\n" if ch == "\n" else " ")
            i += 1
            if ch == "\n":
                state = "code"
        elif state == "block":
            if pair == "/*":
                out.extend("  ")
                block_depth += 1
                i += 2
            elif pair == "*/":
                out.extend("  ")
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    state = "code"
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
        elif state == "string":
            if ch == "\\" and i + 1 < len(source):
                out.extend("  ")
                i += 2
            elif ch == '\"':
                out.append(ch)
                i += 1
                state = "code"
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
        else:
            if triple == '\"\"\"':
                out.extend('\"\"\"')
                i += 3
                state = "code"
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
    return "".join(out)


def extract_braced_declaration(source, pattern):
    match = re.search(pattern, source)
    if not match:
        return None
    opening = source.find("{", match.end())
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return None


def extract_function_body(source, name):
    return extract_braced_declaration(
        source,
        r"\bfunc\s+" + re.escape(name) + r"\s*\(",
    )


def extract_all_function_bodies(source, name):
    """Every body for `name` in the file, so a second type declaring the same
    lifecycle callback cannot hide behind the first."""
    bodies = []
    offset = 0
    pattern = re.compile(r"\bfunc\s+" + re.escape(name) + r"\s*\(")
    while True:
        match = pattern.search(source, offset)
        if not match:
            return bodies
        opening = source.find("{", match.end())
        if opening < 0:
            return bodies
        depth = 0
        end = None
        for index in range(opening, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None:
            return bodies
        bodies.append(source[opening:end])
        offset = end


def extract_type_body(source, name):
    return extract_braced_declaration(
        source,
        r"\b(?:struct|class|final\s+class)\s+" + re.escape(name) + r"\b",
    )


def discovered_representables(swift_sources):
    names = set()
    # Multiline declarations and `extension Foo: NSViewRepresentable` both
    # count; conformance position in the inheritance clause is irrelevant.
    pattern = re.compile(
        r"\b(?:struct|class|final\s+class|extension)\s+([A-Za-z_]\w*)\b[^{]*?\bNSViewRepresentable\b[^{]*?\{",
        re.DOTALL,
    )
    for source in swift_sources:
        clean = neutralize_swift(source)
        if "NSViewRepresentable" not in clean:
            continue
        names.update(pattern.findall(clean))
    return names


def discovered_custom_layouts(swift_sources):
    names = set()
    for source in swift_sources:
        if "Layout" not in source:
            continue
        names.update(CUSTOM_LAYOUT_DECLARATION.findall(neutralize_swift(source)))
    # SwiftUI's own protocols/types are not violations by themselves.
    return {name for name in names if name not in {"Layout", "AnyLayout"}}


def check_content_view(source):
    clean = neutralize_swift(source)
    violations = []
    body = extract_function_body(clean, "workspaceScrollArea")
    if body is None:
        return ["could not locate func workspaceScrollArea(...); update this guard for the renamed boundary"]
    if not re.search(r"\bSidebarWorkspaceTableView\s*\(", body):
        violations.append("workspaceScrollArea does not mount SidebarWorkspaceTableView")
    for token in SWIFTUI_LIST_CONTAINERS:
        if re.search(r"\b" + token + r"\s*[({]", body):
            violations.append("workspaceScrollArea reintroduces SwiftUI container: " + token)
    for name in OLD_DEFAULT_LIST_FUNCTIONS:
        if extract_function_body(clean, name) is not None:
            violations.append("obsolete LazyVStack-era default-list function still exists: " + name)
    return violations


def check_row_source(
    source,
    required_type,
    representable_names,
    custom_layout_names,
):
    clean = neutralize_swift(source)
    body = extract_type_body(clean, required_type)
    if body is None:
        return [f"could not locate row type {required_type}; update this guard for the rename"]
    violations = []
    for pattern, description in ROW_FORBIDDEN_PATTERNS:
        if pattern.search(body):
            violations.append(f"{required_type} contains forbidden {description}")
    forbidden = representable_names - REPRESENTABLE_ALLOWLIST - {"SidebarWorkspaceTableView"}
    for name in sorted(forbidden):
        if re.search(r"\b" + re.escape(name) + r"\b", body):
            violations.append(f"{required_type} mounts forbidden per-row NSViewRepresentable {name}")
    for name in sorted(custom_layout_names):
        if re.search(r"\b" + re.escape(name) + r"\s*[({]", body):
            violations.append(
                f"{required_type} applies the custom Layout `{name}` "
                "(the #6033/#6210 force-measure shape under any name)"
            )
    return violations


def check_appkit_sources(sources_by_name, require_all_files=True):
    violations = []
    required = {
        "SidebarWorkspaceTableView.swift": ("NSViewRepresentable", "makeNSView", "updateNSView"),
        "SidebarWorkspaceTableController.swift": ("@MainActor", "NSTableViewDataSource", "NSTableViewDelegate"),
        "SidebarWorkspaceTableCellView.swift": ("NSTableCellView", "NSHostingView", "rootView"),
        "SidebarWorkspaceTableViewImpl.swift": ("NSTableView", "updateTrackingAreas", "otherMouseDown"),
        "SidebarWorkspaceTableRowConfiguration.swift": ("hasEquivalentContent", "makeContent"),
    }
    for filename, markers in required.items():
        source = sources_by_name.get(filename)
        if source is None:
            if require_all_files:
                violations.append(f"missing required AppKit-list file {filename}")
            continue
        clean = neutralize_swift(source)
        for marker in markers:
            if marker not in clean:
                violations.append(f"{filename} is missing required marker {marker}")

    for filename, source in sources_by_name.items():
        clean = neutralize_swift(source)
        for callback in LAYOUT_CALLBACKS:
            for body in extract_all_function_bodies(clean, callback):
                for pattern in LAYOUT_MUTATION_PATTERNS:
                    if pattern.search(body):
                        violations.append(
                            f"{filename}.{callback} mutates/reconfigures the table from a layout callback"
                        )
        for pattern, label in (
            (r"\bObservableObject\b", "ObservableObject"),
            (r"@Published\b", "@Published"),
            (r"DispatchQueue\.main\.async", "DispatchQueue.main.async"),
            (r"\.asyncAfter\s*\(", "asyncAfter"),
        ):
            if re.search(pattern, clean):
                violations.append(f"{filename} introduces forbidden {label}")
    return violations


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def repo_owned_swift_sources(root):
    sources = []
    for base in ("Sources", os.path.join("Packages",)):
        top = os.path.join(root, base)
        for directory, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in {".build", "checkouts"}]
            for filename in filenames:
                if filename.endswith(".swift"):
                    try:
                        sources.append(read(os.path.join(directory, filename)))
                    except OSError:
                        pass
    return sources


def default_violations(root):
    appkit_dir = os.path.join(root, "Sources", "Sidebar", "AppKitList")
    try:
        appkit_sources = {
            name: read(os.path.join(appkit_dir, name))
            for name in os.listdir(appkit_dir)
            if name.endswith(".swift")
        }
        content = read(os.path.join(root, "Sources", "ContentView.swift"))
        row_view = read(os.path.join(root, "Sources", "SidebarWorkspaceRowView.swift"))
        group_header = read(os.path.join(root, "Sources", "SidebarWorkspaceGroupHeaderView.swift"))
        group_row = read(os.path.join(root, "Sources", "SidebarWorkspaceGroupRowView.swift"))
    except OSError as error:
        return [f"cannot read required sidebar source: {error}"]

    all_sources = repo_owned_swift_sources(root)
    representables = discovered_representables(all_sources)
    custom_layouts = discovered_custom_layouts(all_sources)
    row_checks = (
        (content, "TabItemView"),
        (row_view, "SidebarWorkspaceRowView"),
        (group_header, "SidebarWorkspaceGroupHeaderView"),
        (group_row, "SidebarWorkspaceGroupRowView"),
    )
    violations = check_content_view(content)
    for source, row_type in row_checks:
        violations += check_row_source(source, row_type, representables, custom_layouts)
    violations += check_appkit_sources(appkit_sources)
    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", help="scan one AppKit-list Swift file for layout-callback mutations")
    args = parser.parse_args(argv)
    if args.file:
        try:
            violations = check_appkit_sources(
                {os.path.basename(args.file): read(args.file)},
                require_all_files=False,
            )
        except OSError as error:
            violations = [f"cannot read {args.file}: {error}"]
    else:
        violations = default_violations(repo_root_dir())
    if violations:
        print("check-sidebar-lazy-layout: FAILED", file=sys.stderr)
        for violation in violations:
            print("  - " + violation, file=sys.stderr)
        return 1
    print("check-sidebar-lazy-layout: ok (AppKit NSTableView boundary)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
