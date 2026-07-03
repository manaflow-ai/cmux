#!/usr/bin/env python3
"""CI guard for ./scripts/check-sidebar-lazy-layout.py.

Verifies the guard reports "ok" on the real cmux repo and correctly *fails* on
every way the workspace-sidebar lazy-layout contract can be broken. The negative
cases are what keep the guard from rotting into a no-op.

Cases:
  (a) Real cmux repo passes (Sources/ContentView.swift).
  (b) A fixture whose guarded functions are clean code but whose comments and
      string literals deliberately name every forbidden token still passes
      (comment/string neutralization works -- this mirrors the real source,
      which documents the anti-patterns it forbids).
  (c) Reintroducing the #6210 force-measure (`.sizeThatFits(ProposedViewSize(
      width:, height: nil))`) fails.
  (d) Reintroducing the deleted `SidebarRowsFillLayout` custom Layout fails.
  (e) A `GeometryReader` in the steady-state scroll content fails.
  (f) Downgrading the rows from `LazyVStack` to a plain eager `VStack` fails.
  (g) Dropping `.frame(minHeight:)` from `workspaceScrollContent` fails.
  (h) Renaming/removing a guarded function fails loudly (no silent skip).
  (j) A clean TabItemView row region passes.
  (k) The #6556 rowHeightProbe shape (GeometryReader + @State height in a row)
      fails — this exact code shipped in stable v0.64.17 and livelocked in the
      wild on 2026-07-02.
  (l) Per-row `.anchorPreference` (the #5323 virtualization defeat) fails.
  (m) A required row type missing from its file fails loudly (no silent skip).
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-sidebar-lazy-layout.py")


def load_guard_module():
    spec = importlib.util.spec_from_file_location("sidebar_lazy_layout_guard", GUARD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_text(path, contents):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)


def run_guard(path):
    return subprocess.run(
        [sys.executable, GUARD, "--file", path],
        cwd=ROOT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def run_guard_default():
    return subprocess.run(
        [sys.executable, GUARD],
        cwd=ROOT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def fixture(scroll_body, rows_body):
    """Assemble a minimal ContentView-shaped Swift source with the two guarded
    functions. ``scroll_body`` / ``rows_body`` are the function-body statements.
    """
    return (
        "import SwiftUI\n"
        "struct ContentBody {\n"
        "    private func workspaceScrollContent(\n"
        "        renderContext: WorkspaceListRenderContext,\n"
        "        minHeight: CGFloat\n"
        "    ) -> some View {\n"
        "        // History: SidebarRowsFillLayout measured it via\n"
        "        // sizeThatFits(ProposedViewSize(width: width, height: nil)) and a\n"
        "        // GeometryReader feedback loop. Those tokens live only in this\n"
        "        // comment and must not trip the guard.\n"
        + scroll_body
        + "\n    }\n"
        "    @ViewBuilder\n"
        "    private func workspaceRows(renderContext: WorkspaceListRenderContext) -> some View {\n"
        + rows_body
        + "\n    }\n"
        "}\n"
    )


# A clean scroll body and rows body that satisfy the contract.
GOOD_SCROLL = (
    "        workspaceRows(renderContext: renderContext)\n"
    "            .frame(minHeight: minHeight, alignment: .top)"
)
GOOD_ROWS = (
    "        let rows = LazyVStack(spacing: tabRowSpacing) {\n"
    "            ForEach(renderItems, id: \\.id) { item in workspaceRow(item) }\n"
    "        }\n"
    "        return rows"
)


def write_fixture(directory, name, contents):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)
    return path


def expect(result, should_pass, label):
    ok = (result.returncode == 0) if should_pass else (result.returncode != 0)
    state = "PASS" if ok else "FAIL"
    print("[{0}] {1} (exit={2}, expected {3})".format(
        state, label, result.returncode, "0" if should_pass else "non-zero"))
    if not ok:
        print("---- guard output ----")
        print(result.stdout.rstrip())
        print("----------------------")
    return ok


def main():
    failures = 0

    # (a) Real repo must pass.
    failures += 0 if expect(run_guard_default(), True, "real repo passes") else 1

    with tempfile.TemporaryDirectory() as workdir:
        # (b) Clean code + forbidden tokens only in comments/strings still passes.
        good_with_string = fixture(
            GOOD_SCROLL + "\n            .accessibilityLabel(\"GeometryReader sizeThatFits\")",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Good.swift", good_with_string)),
            True, "clean body, anti-patterns only in comments/strings",
        ) else 1

        # (b2) A Swift multi-line string literal that contains a bare `"` and
        # forbidden tokens must not trip the guard. A naive tokenizer closes the
        # literal at the inner quote and exposes `GeometryReader` as code. (#6870)
        good_multiline = fixture(
            GOOD_SCROLL
            + "\n            .help(\"\"\"\n"
            + "            Layout note: he said \"GeometryReader\" plus\n"
            + "            sizeThatFits(ProposedViewSize(width: w, height: nil)) and\n"
            + "            SidebarRowsFillLayout are all forbidden here.\n"
            + "            \"\"\")",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "GoodMultiline.swift", good_multiline)),
            True, "multi-line string with bare quote + forbidden tokens passes",
        ) else 1

        # (c) Force-measure reintroduced.
        bad_force = fixture(
            "        let h = subviews.first?.sizeThatFits(\n"
            "            ProposedViewSize(width: width, height: nil)).height ?? 0\n"
            "        return workspaceRows(renderContext: renderContext)\n"
            "            .frame(minHeight: max(h, minHeight), alignment: .top)",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Force.swift", bad_force)),
            False, "force-measure sizeThatFits(ProposedViewSize(height: nil)) fails",
        ) else 1

        # (d) SidebarRowsFillLayout reintroduced.
        bad_layout = fixture(
            "        SidebarRowsFillLayout(minHeight: minHeight) {\n"
            "            workspaceRows(renderContext: renderContext)\n"
            "        }",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Layout.swift", bad_layout)),
            False, "reintroduced SidebarRowsFillLayout fails",
        ) else 1

        # (d2) A *renamed* custom Layout (not the literal old name) applied to the
        # rows must fail, even when the force-measure lives in the layout type
        # outside the two guarded functions. The guard discovers Layout-conforming
        # types and bans all their names from the functions. (#6870 review)
        renamed_layout = (
            "import SwiftUI\n"
            "struct RowsFillLayout: Layout {\n"
            "    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {\n"
            "        subviews.first?.sizeThatFits(ProposedViewSize(width: 10, height: nil)) ?? .zero\n"
            "    }\n"
            "    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}\n"
            "}\n"
            + fixture(
                "        RowsFillLayout {\n"
                "            workspaceRows(renderContext: renderContext)\n"
                "        }\n"
                "        .frame(minHeight: minHeight, alignment: .top)",
                GOOD_ROWS,
            )
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "RenamedLayout.swift", renamed_layout)),
            False, "renamed custom Layout applied to rows fails",
        ) else 1

        # (e) GeometryReader in steady-state scroll content.
        bad_geo = fixture(
            "        GeometryReader { proxy in\n"
            "            workspaceRows(renderContext: renderContext)\n"
            "                .frame(minHeight: proxy.size.height, alignment: .top)\n"
            "        }",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Geo.swift", bad_geo)),
            False, "GeometryReader in scroll content fails",
        ) else 1

        # (f) Eager VStack instead of LazyVStack.
        bad_eager = fixture(
            GOOD_SCROLL,
            "        let rows = VStack(spacing: tabRowSpacing) {\n"
            "            ForEach(renderItems, id: \\.id) { item in workspaceRow(item) }\n"
            "        }\n"
            "        return rows",
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Eager.swift", bad_eager)),
            False, "eager VStack (no LazyVStack) fails",
        ) else 1

        # (g) Missing .frame(minHeight:).
        bad_nominheight = fixture(
            "        workspaceRows(renderContext: renderContext)\n"
            "            .frame(maxWidth: .infinity, alignment: .top)",
            GOOD_ROWS,
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "NoMinHeight.swift", bad_nominheight)),
            False, "missing .frame(minHeight:) fails",
        ) else 1

        # (h) A guarded function renamed away -> guard must fail loudly.
        renamed = (
            "import SwiftUI\n"
            "struct ContentBody {\n"
            "    private func workspaceScrollContent(\n"
            "        renderContext: WorkspaceListRenderContext, minHeight: CGFloat\n"
            "    ) -> some View {\n"
            + GOOD_SCROLL
            + "\n    }\n"
            "    @ViewBuilder\n"
            "    private func workspaceRowsRenamed(renderContext: WorkspaceListRenderContext) -> some View {\n"
            + GOOD_ROWS
            + "\n    }\n"
            "}\n"
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "Renamed.swift", renamed)),
            False, "renamed guarded function fails (no silent skip)",
        ) else 1

        # (j) Clean TabItemView row region passes.
        def row_fixture(row_body):
            return fixture(GOOD_SCROLL, GOOD_ROWS) + (
                "struct TabItemView: View, Equatable {\n"
                "    let tab: Tab\n"
                "    var body: some View {\n"
                + row_body
                + "\n    }\n"
                "}\n"
            )

        clean_row = row_fixture(
            "        HStack { Text(tab.title) }\n"
            "            .contentShape(Rectangle())"
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "CleanRow.swift", clean_row)),
            True, "clean TabItemView row region passes",
        ) else 1

        # (k) The #6556 rowHeightProbe shape: GeometryReader writing @State row
        # height from inside a row. This exact code shipped in stable v0.64.17
        # and livelocked in the wild (issue #2586, 2026-07-02 spindump).
        probe_row = row_fixture(
            "        HStack { Text(tab.title) }\n"
            "            .background {\n"
            "                GeometryReader { proxy in\n"
            "                    Color.clear.onAppear { rowHeight = proxy.size.height }\n"
            "                }\n"
            "            }"
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "ProbeRow.swift", probe_row)),
            False, "#6556 rowHeightProbe (GeometryReader in row) fails",
        ) else 1

        # (l) Per-row anchorPreference publication (the #5323 defeat).
        anchor_row = row_fixture(
            "        HStack { Text(tab.title) }\n"
            "            .anchorPreference(key: RowFrameKey.self, value: .bounds) { [tab.id: $0] }"
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "AnchorRow.swift", anchor_row)),
            False, "per-row .anchorPreference (#5323 shape) fails",
        ) else 1

        # (n) --file on a row-view source (no container functions) must not
        # emit false "could not locate func" violations; row scanning still
        # applies. (Greptile P2 on #7221.)
        header_like = (
            "import SwiftUI\n"
            "struct SidebarWorkspaceGroupHeaderView: View, Equatable {\n"
            "    var body: some View {\n"
            "        HStack { Text(\"group\") }\n"
            "    }\n"
            "}\n"
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "HeaderLike.swift", header_like)),
            True, "--file on row-view source without container functions passes",
        ) else 1

        header_like_bad = header_like.replace(
            "        HStack { Text(\"group\") }\n",
            "        HStack { Text(\"group\") }\n"
            "            .background { GeometryReader { p in Color.clear } }\n",
        )
        failures += 0 if expect(
            run_guard(write_fixture(workdir, "HeaderLikeBad.swift", header_like_bad)),
            False, "--file row-view source with GeometryReader still fails",
        ) else 1

        # (m) A required row type missing from its file must fail loudly.
        guard_mod = load_guard_module()
        missing_row_violations = guard_mod.check_source(
            "import SwiftUI\nstruct SomethingElse: View { var body: some View { Text(\"x\") } }\n",
            set(),
            require_functions=False,
            required_row_types=("SidebarWorkspaceGroupHeaderView",),
        )
        row_rename_ok = any("could not locate type" in v for v in missing_row_violations)
        print("[{0}] missing required row type fails loudly".format(
            "PASS" if row_rename_ok else "FAIL"))
        failures += 0 if row_rename_ok else 1

        # (i) Custom-Layout discovery must cover repo-owned Packages/ (where cmux
        # migrates app code) and exclude build/vendor trees. (#6870 review)
        guard = load_guard_module()
        fake_root = os.path.join(workdir, "fakerepo")
        write_text(os.path.join(fake_root, "Sources", "Z.swift"),
                   "struct SourcesLayout: Layout {}\n")
        write_text(os.path.join(fake_root, "Packages", "macOS", "CmuxSidebar",
                                "Sources", "X.swift"),
                   "struct PackagedRowsLayout: Layout {}\n")
        write_text(os.path.join(fake_root, "Packages", "macOS", "Dep", ".build",
                                "checkouts", "ext", "Y.swift"),
                   "struct VendoredLayout: Layout {}\n")
        scanned = list(guard.repo_owned_swift_files(fake_root))
        discovered = guard.find_custom_layout_type_names(scanned)
        cov_ok = (
            "SourcesLayout" in discovered
            and "PackagedRowsLayout" in discovered
            and "VendoredLayout" not in discovered
        )
        print("[{0}] discovery covers Sources/ + Packages/, excludes .build "
              "(found {1})".format("PASS" if cov_ok else "FAIL", sorted(discovered)))
        failures += 0 if cov_ok else 1

    if failures:
        print("\ntest_ci_sidebar_lazy_layout_guard: {0} case(s) FAILED".format(failures),
              file=sys.stderr)
        return 1
    print("\ntest_ci_sidebar_lazy_layout_guard: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
