import type { Tree } from "cmux/raw";
import { describe, expect, it } from "vitest";
import type { LocalSelectionState } from "./localSelection";
import { SurfaceTitleReconciler, treeToViewModel } from "./tree";

// A terminal tab shows its title's text (D2): the daemon announces no spinner
// frame of the same text, so a tab that showed the raw title would keep the
// first frame (`⠂ Task`) while the agent works.

const selection: LocalSelectionState = {
  selectedWorkspaceId: 1n,
  selectedScreenId: 2n,
  selectedPaneId: 3n,
  snapshot: null,
};

function treeWith(tab: Record<string, unknown>): Tree {
  return {
    workspaces: [
      {
        id: 1n,
        name: "1",
        active: true,
        screens: [{ id: 2n, active: true, active_pane: 3n, panes: [{ id: 3n, active_tab: 0n, tabs: [tab] }] }],
      },
    ],
  } as unknown as Tree;
}

function subtitleOf(tree: Tree): string | undefined {
  return treeToViewModel(tree, new Set(), selection)[0]?.subtitle;
}

describe("terminal tab titles", () => {
  it("shows a tree tab's title_text, not its raw spinner frame", () => {
    const tree = treeWith({ surface: 4n, kind: "pty", title: "⠐ Fix it", title_text: "Fix it" });
    expect(subtitleOf(tree)).toBe("Fix it");
  });

  it("keeps the raw title of a daemon from before the split", () => {
    expect(subtitleOf(treeWith({ surface: 4n, kind: "pty", title: "vim" }))).toBe("vim");
  });

  it("shows a title-changed event's text", () => {
    const reconciler = new SurfaceTitleReconciler();
    const tree = treeWith({ surface: 4n, kind: "pty", title: "zsh", title_text: "zsh" });
    reconciler.record(4n, "⠂ Fix the login bug", "Fix the login bug");
    expect(subtitleOf(reconciler.apply(tree))).toBe("Fix the login bug");
  });
});
