#!/usr/bin/env python3
"""Negative coverage for the AppKit sidebar topology guard.

Verifies the guard reports "ok" on the real cmux repo and correctly *fails* on
every way the sidebar table boundary can regress. The negative cases are what
keep the guard from rotting into a no-op.

Cases:
  (a) Real cmux repo passes.
  (b) Renaming/removing the router or AppKit boundary fails loudly.
  (c) Reintroducing a SwiftUI list container (ScrollView/LazyVStack/
      ScrollViewReader) in the AppKit boundary fails.
  (d) Bypassing either rollout branch fails.
  (e) A non-allowlisted per-row NSViewRepresentable fails; the inline rename
      field and GPU spinner allowlist passes.
  (f) A row GeometryReader / onGeometryChange / anchorPreference /
      force-measure fails (the historical livelock ingredients).
  (g) A custom Layout-conforming type applied to a row fails, under any name.
  (h) reloadData/reconfigure/rootView-assignment from an AppKit layout
      lifecycle callback fails, including through recursive local helpers.
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


def content_fixture(appkit_body):
    return f"""
import SwiftUI
struct Sidebar {{
    func workspaceScrollArea(renderContext: Context) -> some View {{
        Group {{
            if CmuxFeatureFlags.shared.isAppKitSidebarListEnabled {{
                appKitWorkspaceScrollArea(renderContext: renderContext)
            }} else {{
                legacyWorkspaceScrollArea(renderContext: renderContext)
            }}
        }}
    }}
    func appKitWorkspaceScrollArea(renderContext: Context) -> some View {{
        {appkit_body}
    }}
    func legacyWorkspaceScrollArea(renderContext: Context) -> some View {{
        Text("legacy")
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

    bypassed_legacy = clean.replace(
        "legacyWorkspaceScrollArea(renderContext: renderContext)",
        "appKitWorkspaceScrollArea(renderContext: renderContext)",
        1,
    )
    failures += expect(
        any("legacyWorkspaceScrollArea" in item for item in guard.check_content_view(bypassed_legacy)),
        "rollout router bypassing the legacy branch fails",
    )

    reversed_rollout = clean.replace(
        """if CmuxFeatureFlags.shared.isAppKitSidebarListEnabled {
                appKitWorkspaceScrollArea(renderContext: renderContext)
            } else {
                legacyWorkspaceScrollArea(renderContext: renderContext)
            }""",
        """if CmuxFeatureFlags.shared.isAppKitSidebarListEnabled {
                legacyWorkspaceScrollArea(renderContext: renderContext)
            } else {
                appKitWorkspaceScrollArea(renderContext: renderContext)
            }""",
    )
    failures += expect(
        any("reverses" in item for item in guard.check_content_view(reversed_rollout)),
        "rollout router rejects reversed branches even when both helpers remain",
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

    hidden_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        self.refreshVisibleGeometry()
    }
    private func refreshVisibleGeometry() {
        commitVisibleGeometry()
    }
    private func commitVisibleGeometry() {
        noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }
}
"""
    hidden_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": hidden_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any(
            "layout callback" in item
            and "refreshVisibleGeometry -> commitVisibleGeometry" in item
            for item in hidden_violations
        ),
        "table mutation hidden behind recursive local helpers fails",
    )

    receiver_scoped_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    let model = SidebarWorkspaceTableModel()
    override func layout() {
        super.layout()
        model.refresh()
    }
}
final class SidebarWorkspaceTableModel {
    func refresh() {}
}
final class UnrelatedTableOwner {
    func refresh() {
        tableView.reloadData()
    }
}
"""
    receiver_scoped_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": receiver_scoped_lifecycle,
    }, require_all_files=False)
    failures += expect(
        not any("layout callback" in item for item in receiver_scoped_violations),
        "other-receiver and unrelated same-name helpers do not create a false mutation path",
    )

    overloaded_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        self.refresh(safely: true)
    }
    private func refresh(safely: Bool) {}
    private func refresh(force: Bool) {
        tableView.reloadData()
    }
}
"""
    overloaded_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": overloaded_lifecycle,
    }, require_all_files=False)
    failures += expect(
        not any("layout callback" in item for item in overloaded_violations),
        "same-type same-arity overloads with different labels are not conflated",
    )

    cross_extension_lifecycle = {
        "SidebarWorkspaceTableViewImpl.swift": """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        self.refresh(safely: true)
    }
}
""",
        "SidebarWorkspaceTableViewImpl+Refresh.swift": """
extension SidebarWorkspaceTableViewImpl {
    func refresh(safely: Bool) {
        tableView.reloadData()
    }
    func refresh(force: Bool) {}
}
""",
    }
    cross_extension_violations = guard.check_appkit_sources(
        cross_extension_lifecycle,
        require_all_files=False,
    )
    failures += expect(
        any(
            item.startswith("SidebarWorkspaceTableViewImpl.swift.layout ")
            and "layout callback via refresh" in item
            for item in cross_extension_violations
        ),
        "layout callbacks trace same-type helpers across extension files with callback attribution",
    )

    cross_extension_overload = dict(cross_extension_lifecycle)
    cross_extension_overload["SidebarWorkspaceTableViewImpl+Refresh.swift"] = """
extension SidebarWorkspaceTableViewImpl {
    func refresh(safely: Bool) {}
    func refresh(force: Bool) {
        tableView.reloadData()
    }
}
"""
    cross_extension_overload_violations = guard.check_appkit_sources(
        cross_extension_overload,
        require_all_files=False,
    )
    failures += expect(
        not any("layout callback" in item for item in cross_extension_overload_violations),
        "cross-extension same-arity overload labels are not conflated",
    )

    defaulted_helper_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh()
    }
    private func refresh(_ force: Bool = true) {
        tableView.reloadData()
    }
}
"""
    defaulted_helper_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": defaulted_helper_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in defaulted_helper_violations),
        "a helper reached through an omitted default argument still fails",
    )

    trailing_closure_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh {
            finishRefresh()
        }
    }
    private func refresh(completion: () -> Void) {
        reloadData()
        completion()
    }
    private func finishRefresh() {}
}
"""
    trailing_closure_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": trailing_closure_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in trailing_closure_violations),
        "a bare trailing-closure helper call still fails",
    )

    self_trailing_closure_lifecycle = trailing_closure_lifecycle.replace(
        "refresh {", "self.refresh {", 1
    )
    self_trailing_closure_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": self_trailing_closure_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in self_trailing_closure_violations),
        "a self-qualified trailing-closure helper call still fails",
    )

    argumented_trailing_closure_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh(mode: .visible) {
            finishRefresh()
        }
    }
    private func refresh(mode: RefreshMode, completion: () -> Void) {
        reloadData()
        completion()
    }
    private func finishRefresh() {}
}
"""
    argumented_trailing_closure_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": argumented_trailing_closure_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in argumented_trailing_closure_violations),
        "an argumented trailing-closure helper call still fails",
    )

    argumented_trailing_closure_overload = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh(mode: .visible) {
            finishRefresh()
        }
    }
    private func refresh(mode: RefreshMode) {
        reloadData()
    }
    private func refresh(mode: RefreshMode, completion: () -> Void) {
        completion()
    }
    private func finishRefresh() {}
}
"""
    argumented_trailing_closure_overload_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": argumented_trailing_closure_overload,
    }, require_all_files=False)
    failures += expect(
        not any("layout callback via refresh" in item for item in argumented_trailing_closure_overload_violations),
        "an argumented trailing closure does not match a non-closure overload",
    )

    variadic_helper_lifecycle = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh()
    }
    private func refresh(_ force: Bool...) {
        tableView.reloadData()
    }
}
"""
    variadic_helper_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": variadic_helper_lifecycle,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in variadic_helper_violations),
        "a zero-value variadic helper call still fails",
    )

    fixed_and_variadic_overloads = """
final class SidebarWorkspaceTableViewImpl: NSTableView {
    override func layout() {
        super.layout()
        refresh(true)
    }
    private func refresh(_ force: Bool) {}
    private func refresh(_ force: Bool...) {
        tableView.reloadData()
    }
}
"""
    mixed_overload_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableViewImpl.swift": fixed_and_variadic_overloads,
    }, require_all_files=False)
    failures += expect(
        any("layout callback via refresh" in item for item in mixed_overload_violations),
        "fixed and variadic overload keys remain sortable and conservatively traced",
    )

    bad_staging_boundary = """
final class SidebarWorkspaceTableController {
    func apply(rows: [Int]) {
        applyImmediately()
    }
    private func applyImmediately() {
        tableView.reloadData()
    }
}
"""
    staging_violations = guard.check_appkit_sources({
        "SidebarWorkspaceTableController.swift": bad_staging_boundary,
    }, require_all_files=False)
    failures += expect(
        any(
            "before its callback returns via applyImmediately" in item
            for item in staging_violations
        ),
        "apply mutation hidden behind a local helper fails the staging boundary",
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
