#!/usr/bin/env python3
"""Negative coverage for the AppKit sidebar topology guard.

Verifies the guard reports "ok" on the real cmux repo and correctly *fails* on
every way the sidebar table boundary can regress. The negative cases are what
keep the guard from rotting into a no-op.

Cases:
  (a) Real cmux repo passes.
  (b) Renaming/removing the boundary function fails loudly (no silent skip).
  (c) Reintroducing a SwiftUI list container (ScrollView/LazyVStack/
      ScrollViewReader) in the boundary fails.
  (d) A resurrected LazyVStack-era function (workspaceRows etc.) fails.
  (e) A non-allowlisted per-row NSViewRepresentable fails; the inline rename
      field and GPU spinner allowlist passes.
  (f) A row GeometryReader / onGeometryChange / anchorPreference /
      force-measure fails (the historical livelock ingredients).
  (g) A custom Layout-conforming type applied to a row fails, under any name.
  (h) reloadData/reconfigure/rootView-assignment from an AppKit layout
      lifecycle callback fails.
  (i) Comment/string neutralization: prose naming forbidden tokens passes.
  (j) --file mode does not report missing sibling files.
  (k) The real --file CLI entrypoint (argparse, file read, basename scoping)
      passes a clean file and fails a layout-callback mutation.
"""

import contextlib
import importlib.util
import io
import os
import sys
import tempfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD_PATH = os.path.join(ROOT, "scripts", "check-sidebar-lazy-layout.py")


def load_guard():
    spec = importlib.util.spec_from_file_location("sidebar_guard", GUARD_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect(condition, label):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}")
    return 0 if condition else 1


def content_fixture(body):
    return f"""
import SwiftUI
struct Sidebar {{
    func workspaceScrollArea(renderContext: Context) -> some View {{
        {body}
    }}
}}
struct TabItemView: View {{
    var body: some View {{ Text(\"row\") }}
}}
"""


def main():
    guard = load_guard()
    failures = 0

    failures += expect(not guard.default_violations(ROOT), "real repository passes")

    clean = content_fixture("SidebarWorkspaceTableView()")
    failures += expect(not guard.check_content_view(clean), "table boundary passes")

    missing = "struct Sidebar { func renamed() {} }"
    failures += expect(
        any("could not locate" in item for item in guard.check_content_view(missing)),
        "renamed boundary fails loudly",
    )

    swiftui_list = content_fixture("ScrollView { LazyVStack { Text(\"x\") } }")
    failures += expect(
        any("SwiftUI container" in item for item in guard.check_content_view(swiftui_list)),
        "SwiftUI ScrollView/LazyVStack regression fails",
    )

    scroll_reader = content_fixture("ScrollViewReader { _ in SidebarWorkspaceTableView() }")
    failures += expect(
        any("ScrollViewReader" in item for item in guard.check_content_view(scroll_reader)),
        "ScrollViewReader regression fails",
    )

    obsolete = clean + "\nextension Sidebar { func workspaceRows() {} }\n"
    failures += expect(
        any("obsolete" in item for item in guard.check_content_view(obsolete)),
        "obsolete workspaceRows seam fails",
    )

    representables = {"BadRowPortal", "SidebarInlineRenameField", "GPUSpinner"}
    bad_row = """
struct TabItemView: View {
    var body: some View { BadRowPortal() }
}
"""
    failures += expect(
        any("BadRowPortal" in item for item in guard.check_row_source(
            bad_row, "TabItemView", representables, set()
        )),
        "per-row NSViewRepresentable fails",
    )

    allowed_row = """
struct TabItemView: View {
    var body: some View { SidebarInlineRenameField() }
}
"""
    failures += expect(
        not guard.check_row_source(allowed_row, "TabItemView", representables, set()),
        "inline rename allowlist passes",
    )

    geometry_row = """
struct TabItemView: View {
    var body: some View {
        GeometryReader { proxy in Text("h") }
    }
}
"""
    failures += expect(
        any("GeometryReader" in item for item in guard.check_row_source(
            geometry_row, "TabItemView", set(), set()
        )),
        "row GeometryReader fails",
    )

    probe_row = """
struct TabItemView: View {
    var body: some View {
        Text("row").onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in }
    }
}
"""
    failures += expect(
        any("onGeometryChange" in item for item in guard.check_row_source(
            probe_row, "TabItemView", set(), set()
        )),
        "row onGeometryChange fails (the #6556 shape)",
    )

    anchor_row = """
struct TabItemView: View {
    var body: some View {
        Text("row").anchorPreference(key: K.self, value: .bounds) { [id: $0] }
    }
}
"""
    failures += expect(
        any("anchorPreference" in item for item in guard.check_row_source(
            anchor_row, "TabItemView", set(), set()
        )),
        "row anchorPreference fails (the #5323 shape)",
    )

    layout_row = """
struct TabItemView: View {
    var body: some View {
        SneakyRowsFillLayout() { Text("row") }
    }
}
"""
    failures += expect(
        any("SneakyRowsFillLayout" in item for item in guard.check_row_source(
            layout_row, "TabItemView", set(), {"SneakyRowsFillLayout"}
        )),
        "renamed custom Layout in a row fails (the #6210 shape)",
    )

    layout_decl = """
struct SneakyRowsFillLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { .zero }
}
"""
    failures += expect(
        "SneakyRowsFillLayout" in guard.discovered_custom_layouts([layout_decl]),
        "custom Layout discovery finds renamed layouts",
    )

    bad_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reloadData()
    }
}
"""
    failures += expect(
        any("layout callback" in item for item in guard.check_appkit_sources({
            "SidebarWorkspaceTableViewImpl.swift": bad_lifecycle,
        }, require_all_files=False)),
        "reload from updateTrackingAreas fails",
    )

    comments_only = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // reloadData() and rootView = are forbidden, but this is prose.
        let note = \"noteHeightOfRows()\"
    }
}
"""
    lifecycle_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": comments_only,
    }, require_all_files=False)
    failures += expect(
        not any("layout callback" in item for item in lifecycle_violations),
        "comments and strings are neutralized",
    )

    single_file = guard.check_appkit_sources(
        {"SidebarWorkspaceTableHoverResolver.swift": "struct SidebarWorkspaceTableHoverResolver {}"},
        require_all_files=False,
    )
    failures += expect(
        not any("missing required" in item for item in single_file),
        "--file mode does not report missing sibling files",
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        clean_path = os.path.join(tmpdir, "SidebarWorkspaceTableHoverResolver.swift")
        with open(clean_path, "w", encoding="utf-8") as handle:
            handle.write("struct SidebarWorkspaceTableHoverResolver {}\n")
        violating_path = os.path.join(tmpdir, "SidebarWorkspaceTableClipView.swift")
        with open(violating_path, "w", encoding="utf-8") as handle:
            handle.write(
                "final class SidebarWorkspaceTableClipView: NSClipView {\n"
                "    override func layout() {\n"
                "        super.layout()\n"
                "        tableView.reloadData()\n"
                "    }\n"
                "}\n"
            )
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            clean_rc = guard.main(["--file", clean_path])
            violating_rc = guard.main(["--file", violating_path])
        failures += expect(clean_rc == 0, "--file CLI entrypoint passes a clean file")
        failures += expect(
            violating_rc == 1,
            "--file CLI entrypoint fails a layout-callback mutation",
        )

    if failures:
        print(f"test_ci_sidebar_lazy_layout_guard: {failures} case(s) failed", file=sys.stderr)
        return 1
    print("test_ci_sidebar_lazy_layout_guard: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
