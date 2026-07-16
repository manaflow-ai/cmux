#!/usr/bin/env python3
"""Guard the AppKit-owned default sidebar list boundary.

The default workspace list is AppKit end to end: one container-level
NSViewRepresentable (SidebarWorkspaceTableView) mounts an NSTableView whose
cells, menus, rename field, and drag sources are plain AppKit views driven by
immutable row values. SwiftUI must not reappear below that boundary — no
NSHostingView, no SwiftUI imports outside the single representable file, no
observable references in the list — and table reload/reconfiguration is
forbidden from AppKit layout lifecycle callbacks; mutations enter through
render-context updates, input events, or scroll notifications.

History: the SwiftUI LazyVStack list livelocked repeatedly through distinct
mechanisms (#2586, #5764, #5845, #6210, #6556, #6707, #8004). This guard keeps
the replacement structural: a violation here reintroduces the class, not just
an instance.

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
)
OLD_ROW_TYPES = (
    "TabItemView",
    "SidebarWorkspaceRowView",
    "SidebarWorkspaceGroupRowView",
    "SidebarWorkspaceGroupHeaderView",
)
# The single sanctioned SwiftUI file: the container-level representable.
SWIFTUI_ALLOWLIST = {"SidebarWorkspaceTableView.swift"}
LAYOUT_CALLBACKS = ("layout", "updateTrackingAreas", "viewDidMoveToWindow")
LAYOUT_MUTATION_PATTERNS = (
    re.compile(r"\breloadData\s*\("),
    re.compile(r"\bnoteHeightOfRows\s*\("),
    re.compile(r"\breconfigure(?:Visible)?Rows\s*\("),
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


def extract_type_body(source, name):
    return extract_braced_declaration(
        source,
        r"\b(?:struct|class|final\s+class)\s+" + re.escape(name) + r"\b",
    )


def check_content_view(source):
    clean = neutralize_swift(source)
    violations = []
    body = extract_function_body(clean, "workspaceScrollArea")
    if body is None:
        return ["could not locate func workspaceScrollArea(...); update this guard for the renamed boundary"]
    if "SidebarWorkspaceTableView" not in body:
        violations.append("workspaceScrollArea does not mount SidebarWorkspaceTableView")
    for token in ("ScrollView", "LazyVStack", "LazyHStack", "List"):
        if re.search(r"\b" + token + r"\b", body):
            violations.append("workspaceScrollArea reintroduces SwiftUI list container: " + token)
    for name in OLD_DEFAULT_LIST_FUNCTIONS:
        if extract_function_body(clean, name) is not None:
            violations.append("obsolete SwiftUI default-list function still exists: " + name)
    for name in OLD_ROW_TYPES:
        if extract_type_body(clean, name) is not None:
            violations.append("obsolete SwiftUI row type still exists in ContentView.swift: " + name)
    return violations


def check_appkit_sources(sources_by_name, require_manifest=True):
    violations = []
    if require_manifest:
        required = {
            "SidebarWorkspaceTableView.swift": ("NSViewRepresentable", "makeNSView", "updateNSView"),
            "SidebarWorkspaceTableController.swift": ("@MainActor", "NSTableViewDataSource", "NSTableViewDelegate"),
            "SidebarWorkspaceTableCellView.swift": ("NSTableCellView",),
            "SidebarWorkspaceGroupHeaderCellView.swift": ("NSTableCellView",),
            "SidebarWorkspaceTableViewImpl.swift": ("NSTableView", "updateTrackingAreas", "otherMouseDown"),
        }
        for filename, markers in required.items():
            source = sources_by_name.get(filename)
            if source is None:
                violations.append(f"missing required AppKit-list file {filename}")
                continue
            clean = neutralize_swift(source)
            for marker in markers:
                if marker not in clean:
                    violations.append(f"{filename} is missing required marker {marker}")

    for filename, source in sorted(sources_by_name.items()):
        clean = neutralize_swift(source)
        if filename not in SWIFTUI_ALLOWLIST:
            if re.search(r"^\s*import\s+SwiftUI\b", clean, re.M):
                violations.append(f"{filename} imports SwiftUI inside the AppKit list boundary")
        for token in ("NSHostingView", "NSHostingController"):
            if re.search(r"\b" + token + r"\b", clean):
                violations.append(f"{filename} hosts SwiftUI content ({token}) inside the AppKit list")
        for callback in LAYOUT_CALLBACKS:
            body = extract_function_body(clean, callback)
            if body is None:
                continue
            for pattern in LAYOUT_MUTATION_PATTERNS:
                if pattern.search(body):
                    violations.append(
                        f"{filename}.{callback} mutates/reconfigures the table from a layout callback"
                    )
        for pattern, label in (
            (r"\bObservableObject\b", "ObservableObject"),
            (r"@Published\b", "@Published"),
            (r"@EnvironmentObject\b", "@EnvironmentObject"),
            (r"@ObservedObject\b", "@ObservedObject"),
            (r"@StateObject\b", "@StateObject"),
            (r"DispatchQueue\.main\.async", "DispatchQueue.main.async"),
            (r"DispatchQueue\.asyncAfter", "DispatchQueue.asyncAfter"),
        ):
            if re.search(pattern, clean):
                violations.append(f"{filename} introduces forbidden {label}")
    return violations


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def collect_appkit_sources(appkit_dir):
    sources = {}
    for directory, _, filenames in os.walk(appkit_dir):
        for filename in filenames:
            if filename.endswith(".swift"):
                sources[filename] = read(os.path.join(directory, filename))
    return sources


def default_violations(root):
    appkit_dir = os.path.join(root, "Sources", "Sidebar", "AppKitList")
    try:
        appkit_sources = collect_appkit_sources(appkit_dir)
        content = read(os.path.join(root, "Sources", "ContentView.swift"))
    except OSError as error:
        return [f"cannot read required sidebar source: {error}"]
    if not appkit_sources:
        return [f"no AppKit-list sources found under {appkit_dir}"]

    return (
        check_content_view(content)
        + check_appkit_sources(appkit_sources)
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", help="scan one AppKit-list Swift file in isolation")
    args = parser.parse_args(argv)
    if args.file:
        try:
            sources = {os.path.basename(args.file): read(args.file)}
        except OSError as error:
            print("check-sidebar-lazy-layout: FAILED", file=sys.stderr)
            print(f"  - cannot read {args.file}: {error}", file=sys.stderr)
            return 1
        # Single-file mode checks per-file rules only; the required-file
        # manifest needs the whole directory.
        violations = check_appkit_sources(sources, require_manifest=False)
    else:
        violations = default_violations(repo_root_dir())
    if violations:
        print("check-sidebar-lazy-layout: FAILED", file=sys.stderr)
        for violation in violations:
            print("  - " + violation, file=sys.stderr)
        return 1
    print("check-sidebar-lazy-layout: ok (AppKit NSTableView boundary, no hosted SwiftUI)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
