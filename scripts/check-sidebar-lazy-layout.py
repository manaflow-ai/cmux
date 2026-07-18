#!/usr/bin/env python3
"""Guard the AppKit-owned default sidebar list boundary.

History: the workspace sidebar livelocked repeatedly while it was a SwiftUI
`LazyVStack` (#2586, #5323, #5764, #5845, #5970, #6210, #6556, #6707, #7136,
#8004). Every incident was some invalidation edge firing during the lazy
container's placement pass. The replacement path is one container-level
`NSViewRepresentable` (`SidebarWorkspaceTableView`) wrapping an `NSTableView`;
native AppKit workspace/header cells own each realized row, and all list
mutations are owned by `SidebarWorkspaceTableController`. `apply()` and
viewport notifications only stage immutable inputs; actual table mutations
flush after the originating SwiftUI/AppKit callback returns. The legacy
SwiftUI list remains behind the rollout kill switch while the AppKit path
soaks, so this guard checks the router and the AppKit helper independently.

This guard keeps that topology from regressing:

  * `workspaceScrollArea` must route the rollout flag to the AppKit and legacy
    helpers; `appKitWorkspaceScrollArea` must mount
    `SidebarWorkspaceTableView` without a SwiftUI list/scroll container.
  * Row types stay measurement-free and platform-view-free; geometry probes
    and stray representables are still per-cell waste and were the historical
    livelock ingredients.
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


GUARDED_ROW_TYPES = (
    "TabItemView",
    "SidebarWorkspaceRowView",
    "SidebarWorkspaceGroupHeaderView",
    "SidebarWorkspaceGroupRowView",
)
REPRESENTABLE_ALLOWLIST = {"SidebarInlineRenameField", "GPUSpinner"}
LAYOUT_CALLBACKS = ("layout", "updateTrackingAreas", "viewDidMoveToWindow")
TABLE_MUTATION_PATTERNS = (
    re.compile(r"\breloadData\s*\("),
    re.compile(r"\bnoteHeightOfRows\s*\("),
    re.compile(r"\breconfigure(?:Visible)?Rows\s*\("),
    re.compile(r"\bscrollRowToVisible\s*\("),
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
     "are owned by the table controller's explicit cache)"),
    (re.compile(r"\bonGeometryChange\b"),
     "onGeometryChange (geometry-driven state writes in a row re-trigger "
     "layout the same way the #6556 GeometryReader probes did)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call (row measurement belongs to AppKit's live "
     "table-height cache, never a separate row-body measurement path)"),
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


def closing_brace_offset(source, opening):
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def closing_parenthesis_offset(source, opening):
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def top_level_arguments(source, opening):
    """Split a neutralized Swift parameter/call list at top-level commas."""
    end = closing_parenthesis_offset(source, opening)
    if end is None:
        return None
    contents = source[opening + 1:end - 1]
    if not contents.strip():
        return []
    counts = {"(": 0, "[": 0, "{": 0}
    closers = {")": "(", "]": "[", "}": "{"}
    angle_depth = 0
    result = []
    start = 0
    for index, character in enumerate(contents):
        if character in counts:
            counts[character] += 1
        elif character in closers and counts[closers[character]] > 0:
            counts[closers[character]] -= 1
        elif character == "<" and not any(counts.values()):
            # Swift generic arguments are adjacent to their base (`Foo<Bar>`).
            # Requiring adjacency plus a later close avoids treating ordinary
            # spaced comparisons such as `a < b && c > d` as generic nesting.
            has_adjacent_base = index > 0 and not contents[index - 1].isspace()
            has_adjacent_argument = index + 1 < len(contents) and not contents[index + 1].isspace()
            if has_adjacent_base and has_adjacent_argument and ">" in contents[index + 1:]:
                angle_depth += 1
        elif character == ">" and angle_depth > 0 and not any(counts.values()):
            angle_depth -= 1
        elif character == "," and not any(counts.values()) and angle_depth == 0:
            result.append(contents[start:index])
            start = index + 1
    result.append(contents[start:])
    return result


def declaration_signature(source, opening):
    arguments = top_level_arguments(source, opening)
    if arguments is None:
        return None
    labels = []
    defaults = []
    variadic_index = None
    for argument in arguments:
        prefix = argument.split(":", 1)[0]
        tokens = re.findall(r"[A-Za-z_]\w*|_", prefix)
        if not tokens:
            return None
        labels.append(tokens[-2] if len(tokens) > 1 else tokens[-1])
        defaults.append(bool(re.search(r"(?<![<>=!])=(?!=)", argument)))
        if "..." in argument:
            variadic_index = len(labels) - 1
    final_parameter_is_closure = bool(
        arguments
        and re.search(
            r":\s*(?:(?:@escaping|@Sendable|@MainActor)\s+)*"
            r"\([^)]*\)\s*(?:async\s*)?(?:throws\s*)?->",
            arguments[-1],
        )
    )
    return tuple(labels), tuple(defaults), variadic_index, final_parameter_is_closure


def call_external_labels(source, opening):
    arguments = top_level_arguments(source, opening)
    if arguments is None:
        return None
    labels = []
    for argument in arguments:
        match = re.match(r"\s*([A-Za-z_]\w*)\s*:", argument)
        labels.append(match.group(1) if match else "_")
    return tuple(labels)


def extract_type_scoped_function_bodies(source):
    """Return method bodies by Swift type, merging same-type extensions."""
    scopes = []
    type_pattern = re.compile(
        r"\b(?:struct|class|final\s+class|enum|actor|extension)\s+([A-Za-z_]\w*)\b"
    )
    for match in type_pattern.finditer(source):
        opening = source.find("{", match.end())
        if opening < 0:
            continue
        end = closing_brace_offset(source, opening)
        if end is not None:
            scopes.append((match.group(1), opening, end))

    bodies = {}
    function_pattern = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*\(")
    for match in function_pattern.finditer(source):
        parameter_opening = match.end() - 1
        signature = declaration_signature(source, parameter_opening)
        parameter_end = closing_parenthesis_offset(source, parameter_opening)
        if signature is None or parameter_end is None:
            continue
        opening = source.find("{", parameter_end)
        if opening < 0:
            continue
        end = closing_brace_offset(source, opening)
        if end is None:
            continue
        owners = [scope for scope in scopes if scope[1] < match.start() < scope[2]]
        if not owners:
            continue
        owner = min(owners, key=lambda scope: scope[2] - scope[1])[0]
        key = (match.group(1), *signature)
        bodies.setdefault(owner, {}).setdefault(key, []).append(
            source[opening:end]
        )
    return bodies


def merge_type_scoped_function_bodies(scoped_bodies_by_file):
    """Merge method bodies for one Swift type across its declaration files."""
    merged = {}
    for scoped_bodies in scoped_bodies_by_file.values():
        for owner, function_bodies in scoped_bodies.items():
            owner_bodies = merged.setdefault(owner, {})
            for key, bodies in function_bodies.items():
                owner_bodies.setdefault(key, []).extend(bodies)
    return merged


def called_local_functions(body, local_names):
    """Find bare/self helper calls, excluding calls on other receivers."""
    result = set()
    parenthesized_pattern = re.compile(
        r"(?<![\w.])(?:self\s*\.\s*)?([A-Za-z_]\w*)\s*\("
    )
    for match in parenthesized_pattern.finditer(body):
        name = match.group(1)
        call_opening = match.end() - 1
        labels = call_external_labels(body, call_opening)
        call_end = closing_parenthesis_offset(body, call_opening)
        has_trailing_closure = bool(
            call_end is not None and re.match(r"\s*\{", body[call_end:])
        )
        prefix = body[max(0, match.start() - 12):match.start()]
        if re.search(r"\bfunc\s*$", prefix):
            continue
        for key in local_names:
            matches_parenthesized_arguments = not has_trailing_closure and call_matches_declaration(
                labels, key[1], key[2], key[3]
            )
            matches_trailing_closure = has_trailing_closure and call_with_trailing_closure_matches_declaration(
                labels, key[1], key[2], key[3], key[4]
            )
            if key[0] == name and (
                matches_parenthesized_arguments or matches_trailing_closure
            ):
                result.add(key)

    # Swift permits a single closure argument without parentheses (`refresh
    # { ... }`). Trace both bare and `self.` calls while retaining the same
    # receiver and declaration filtering as the parenthesized path.
    trailing_closure_pattern = re.compile(
        r"(?<![\w.])(?:self\s*\.\s*)?([A-Za-z_]\w*)\s*(?=\{)"
    )
    for match in trailing_closure_pattern.finditer(body):
        name = match.group(1)
        prefix = body[max(0, match.start() - 12):match.start()]
        if re.search(r"\bfunc\s*$", prefix):
            continue
        for key in local_names:
            if key[0] == name and trailing_closure_matches_declaration(
                key[1], key[2], key[3], key[4]
            ):
                result.add(key)
    return result


def trailing_closure_matches_declaration(
    declaration_labels,
    defaults,
    variadic_index,
    final_parameter_is_closure,
):
    """Match `helper {}` with Swift's omitted final closure label."""
    if not final_parameter_is_closure or not declaration_labels:
        return False
    return all(
        defaults[index] or variadic_index == index
        for index in range(len(declaration_labels) - 1)
    )


def call_with_trailing_closure_matches_declaration(
    call_labels,
    declaration_labels,
    defaults,
    variadic_index,
    final_parameter_is_closure,
):
    """Match `helper(arguments) {}` with an omitted final closure label."""
    if not final_parameter_is_closure or not declaration_labels:
        return False
    return call_matches_declaration(
        call_labels,
        declaration_labels[:-1],
        defaults[:-1],
        variadic_index,
    )


def call_matches_declaration(call_labels, declaration_labels, defaults, variadic_index):
    """Match Swift calls while allowing omitted defaults and variadic values."""
    if call_labels is None:
        return False
    call_index = 0
    declaration_index = 0
    while call_index < len(call_labels) and declaration_index < len(declaration_labels):
        if variadic_index == declaration_index:
            if any(label != declaration_labels[declaration_index] for label in call_labels[call_index:]):
                return False
            return True
        if call_labels[call_index] == declaration_labels[declaration_index]:
            call_index += 1
            declaration_index += 1
        elif defaults[declaration_index]:
            declaration_index += 1
        else:
            return False
    if call_index < len(call_labels):
        return False
    return all(
        defaults[index] or variadic_index == index
        for index in range(declaration_index, len(declaration_labels))
    )


def mutation_path(body, function_bodies, visited=None):
    """Return a local helper path to a table mutation, if one exists."""
    visited = set() if visited is None else visited
    if any(pattern.search(body) for pattern in TABLE_MUTATION_PATTERNS):
        return []
    for key in sorted(called_local_functions(body, set(function_bodies)), key=repr):
        if key in visited:
            continue
        next_visited = visited | {key}
        for helper_body in function_bodies[key]:
            path = mutation_path(helper_body, function_bodies, next_visited)
            if path is not None:
                return [key[0]] + path
    return None


def extract_type_body(source, name):
    return extract_braced_declaration(
        source,
        r"\b(?:struct|class|final\s+class)\s+" + re.escape(name) + r"\b",
    )


def extract_rollout_branch_bodies(source):
    """Return the explicit enabled/disabled sidebar rollout branch bodies."""
    condition = "CmuxFeatureFlags.shared.isAppKitSidebarListEnabled"
    match = re.search(r"\bif\s+" + re.escape(condition) + r"\s*\{", source)
    if match is None:
        return None
    enabled_opening = source.find("{", match.start())
    enabled_end = closing_brace_offset(source, enabled_opening)
    if enabled_end is None:
        return None
    else_match = re.match(r"\s*else\s*\{", source[enabled_end:])
    if else_match is None:
        return None
    disabled_opening = enabled_end + else_match.end() - 1
    disabled_end = closing_brace_offset(source, disabled_opening)
    if disabled_end is None:
        return None
    return (
        source[enabled_opening:enabled_end],
        source[disabled_opening:disabled_end],
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
    if "CmuxFeatureFlags.shared.isAppKitSidebarListEnabled" not in body:
        violations.append("workspaceScrollArea does not preserve the AppKit-sidebar rollout flag")
    rollout_branches = extract_rollout_branch_bodies(body)
    if rollout_branches is None:
        violations.append("workspaceScrollArea does not preserve explicit AppKit-sidebar rollout branches")
    else:
        enabled_body, disabled_body = rollout_branches
        if (
            not re.search(r"\bappKitWorkspaceScrollArea\s*\(", enabled_body)
            or re.search(r"\blegacyWorkspaceScrollArea\s*\(", enabled_body)
        ):
            violations.append("workspaceScrollArea reverses the enabled AppKit-sidebar rollout branch")
        if (
            not re.search(r"\blegacyWorkspaceScrollArea\s*\(", disabled_body)
            or re.search(r"\bappKitWorkspaceScrollArea\s*\(", disabled_body)
        ):
            violations.append("workspaceScrollArea reverses the disabled legacy-sidebar rollout branch")
    for helper in ("appKitWorkspaceScrollArea", "legacyWorkspaceScrollArea"):
        if not re.search(r"\b" + helper + r"\s*\(", body):
            violations.append(f"workspaceScrollArea does not route through {helper}")
    for token in SWIFTUI_LIST_CONTAINERS:
        if re.search(r"\b" + token + r"\s*[({]", body):
            violations.append("workspaceScrollArea reintroduces SwiftUI container: " + token)
    appkit_body = extract_function_body(clean, "appKitWorkspaceScrollArea")
    if appkit_body is None:
        violations.append("could not locate func appKitWorkspaceScrollArea(...); update this guard for the renamed AppKit boundary")
        return violations
    if not re.search(r"\bSidebarWorkspaceTableView\s*\(", appkit_body):
        violations.append("appKitWorkspaceScrollArea does not mount SidebarWorkspaceTableView")
    for token in SWIFTUI_LIST_CONTAINERS:
        if re.search(r"\b" + token + r"\s*[({]", appkit_body):
            violations.append("appKitWorkspaceScrollArea reintroduces SwiftUI container: " + token)
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
        "SidebarWorkspaceTableController.swift": (
            "@MainActor", "NSTableViewDataSource", "NSTableViewDelegate",
            "SidebarWorkspaceTableMutationScheduler", "SidebarWorkspaceRowTableCellView",
            "SidebarGroupHeaderTableCellView",
        ),
        "Cells/SidebarWorkspaceRowCellView.swift": (
            "SidebarWorkspaceRowTableCellView", "NSTableCellView", "beginInlineRename",
        ),
        "Cells/SidebarGroupHeaderRowView.swift": (
            "SidebarGroupHeaderTableCellView", "NSTableCellView",
        ),
        "SidebarWorkspaceTableViewImpl.swift": ("NSTableView", "updateTrackingAreas", "otherMouseDown"),
        "SidebarWorkspaceTableRowConfiguration.swift": (
            "hasEquivalentContent", "appKitWorkspaceRowModel", "appKitGroupHeaderModel",
        ),
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

    clean_sources = {
        filename: neutralize_swift(source)
        for filename, source in sources_by_name.items()
    }
    scoped_bodies_by_file = {
        filename: extract_type_scoped_function_bodies(clean)
        for filename, clean in clean_sources.items()
    }
    merged_bodies_by_type = merge_type_scoped_function_bodies(scoped_bodies_by_file)

    for filename, clean in clean_sources.items():
        for owner, local_function_bodies in scoped_bodies_by_file[filename].items():
            function_bodies = merged_bodies_by_type[owner]
            for callback in LAYOUT_CALLBACKS:
                callback_keys = [key for key in local_function_bodies if key[0] == callback]
                for callback_key in callback_keys:
                    for body in local_function_bodies[callback_key]:
                        path = mutation_path(body, function_bodies, visited={callback_key})
                        if path is not None:
                            via = " via " + " -> ".join(path) if path else ""
                            violations.append(
                                f"{filename}.{callback} mutates/reconfigures the table "
                                f"from a layout callback{via}"
                            )
            staging_callbacks = ()
            if filename == "SidebarWorkspaceTableView.swift":
                staging_callbacks = ("updateNSView",)
            elif filename == "SidebarWorkspaceTableController.swift":
                staging_callbacks = ("apply", "viewportDidChange")
            for callback in staging_callbacks:
                callback_keys = [key for key in local_function_bodies if key[0] == callback]
                for callback_key in callback_keys:
                    for body in local_function_bodies[callback_key]:
                        path = mutation_path(body, function_bodies, visited={callback_key})
                        if path is not None:
                            via = " via " + " -> ".join(path) if path else ""
                            violations.append(
                                f"{filename}.{callback} performs a table mutation before its "
                                f"callback returns{via}"
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
        appkit_sources = {}
        for directory, _, filenames in os.walk(appkit_dir):
            for name in filenames:
                if name.endswith(".swift"):
                    path = os.path.join(directory, name)
                    appkit_sources[os.path.relpath(path, appkit_dir)] = read(path)
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
