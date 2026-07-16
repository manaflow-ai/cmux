#!/usr/bin/env python3
"""Negative coverage for the AppKit sidebar topology guard.

Verifies the guard reports "ok" on the real cmux repo and correctly *fails* on
every way the AppKit list boundary can be broken. The negative cases are what
keep the guard from rotting into a no-op.
"""

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

    obsolete_fn = clean + "\nextension Sidebar { func workspaceRows() {} }\n"
    failures += expect(
        any("obsolete" in item for item in guard.check_content_view(obsolete_fn)),
        "obsolete workspaceRows seam fails",
    )

    obsolete_row = clean + "\nstruct TabItemView: View { var body: some View { Text(\"r\") } }\n"
    failures += expect(
        any("obsolete SwiftUI row type" in item for item in guard.check_content_view(obsolete_row)),
        "resurrected SwiftUI row type fails",
    )

    hosted = """
final class SidebarWorkspaceCellDetails: NSView {
    private let hosting = NSHostingView(rootView: Text("x"))
}
"""
    failures += expect(
        any("NSHostingView" in item for item in guard.check_appkit_sources(
            {"SidebarWorkspaceCellDetails.swift": hosted}, require_manifest=False
        )),
        "NSHostingView inside the list fails",
    )

    swiftui_import = """
import SwiftUI
final class SidebarWorkspaceCellDetails: NSView {}
"""
    failures += expect(
        any("imports SwiftUI" in item for item in guard.check_appkit_sources(
            {"SidebarWorkspaceCellDetails.swift": swiftui_import}, require_manifest=False
        )),
        "SwiftUI import inside the list fails",
    )

    representable_ok = """
import SwiftUI
struct SidebarWorkspaceTableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
"""
    failures += expect(
        not guard.check_appkit_sources(
            {"SidebarWorkspaceTableView.swift": representable_ok}, require_manifest=False
        ),
        "the single boundary representable may import SwiftUI",
    )

    observed = """
final class SidebarWorkspaceCellDetails: NSView {
    @ObservedObject var workspace: Workspace
}
"""
    failures += expect(
        any("@ObservedObject" in item for item in guard.check_appkit_sources(
            {"SidebarWorkspaceCellDetails.swift": observed}, require_manifest=False
        )),
        "observable reference inside the list fails",
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
        any("layout callback" in item for item in guard.check_appkit_sources(
            {"SidebarWorkspaceTableViewImpl.swift": bad_lifecycle}, require_manifest=False
        )),
        "reload from updateTrackingAreas fails",
    )

    comments_only = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // reloadData() is forbidden, but this is prose.
        let note = \"noteHeightOfRows()\"
    }
}
"""
    lifecycle_violations = guard.check_appkit_sources(
        {"SidebarWorkspaceTableViewImpl.swift": comments_only}, require_manifest=False
    )
    failures += expect(
        not any("layout callback" in item for item in lifecycle_violations),
        "comments and strings are neutralized",
    )

    manifest_violations = guard.check_appkit_sources({}, require_manifest=True)
    failures += expect(
        any("missing required AppKit-list file" in item for item in manifest_violations),
        "missing required files fail loudly",
    )

    if failures:
        print(f"test_ci_sidebar_lazy_layout_guard: {failures} case(s) failed", file=sys.stderr)
        return 1
    print("test_ci_sidebar_lazy_layout_guard: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
