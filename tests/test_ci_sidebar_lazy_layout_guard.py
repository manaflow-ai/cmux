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
"""

import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-sidebar-lazy-layout.py")


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

    if failures:
        print("\ntest_ci_sidebar_lazy_layout_guard: {0} case(s) FAILED".format(failures),
              file=sys.stderr)
        return 1
    print("\ntest_ci_sidebar_lazy_layout_guard: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
