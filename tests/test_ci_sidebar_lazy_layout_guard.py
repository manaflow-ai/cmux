#!/usr/bin/env python3
"""Negative coverage for the AppKit sidebar topology guard."""

import importlib.util
import os
import sys


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
        any("SwiftUI list container" in item for item in guard.check_content_view(swiftui_list)),
        "SwiftUI ScrollView/LazyVStack regression fails",
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
            bad_row, "TabItemView", representables
        )),
        "per-row NSViewRepresentable fails",
    )

    allowed_row = """
struct TabItemView: View {
    var body: some View { SidebarInlineRenameField() }
}
"""
    failures += expect(
        not guard.check_row_source(allowed_row, "TabItemView", representables),
        "inline rename allowlist passes",
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
        })),
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
    })
    failures += expect(
        not any("layout callback" in item for item in lifecycle_violations),
        "comments and strings are neutralized",
    )

    if failures:
        print(f"test_ci_sidebar_lazy_layout_guard: {failures} case(s) failed", file=sys.stderr)
        return 1
    print("test_ci_sidebar_lazy_layout_guard: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
