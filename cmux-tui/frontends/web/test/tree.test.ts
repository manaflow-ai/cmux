import { describe, expect, it } from "vitest";
import type { Tree } from "cmux/browser";
import { initialLocalSelectionState } from "../src/lib/localSelection";
import {
  activeScreen,
  applySurfaceTitles,
  screenSelection,
  SurfaceTitleReconciler,
  treeToViewModel,
} from "../src/lib/tree";

const tree: Tree = {
  workspaces: [{
    id: 1,
    name: "main",
    active: true,
    screens: [{
      id: 2,
      name: null,
      active: true,
      active_pane: 3,
      zoomed_pane: null,
      layout: { type: "leaf", pane: 3 },
      panes: [{
        id: 3,
        name: null,
        active_tab: 1,
        tabs: [
          { surface: 4, kind: "pty", browser_source: null, name: null, title: "shell", size: null, dead: false },
          { surface: 5, kind: "pty", browser_source: null, name: "logs", title: "tail", size: null, dead: false },
        ],
      }],
    }],
  }],
};

const localSelection = {
  ...initialLocalSelectionState,
  selectedWorkspaceId: 1,
  selectedScreenId: 2,
  selectedPaneId: 3,
};

describe("treeToViewModel", () => {
  it("maps the active pane and tab and carries unread state to its screen", () => {
    const view = treeToViewModel(tree, new Set([4]), localSelection);
    expect(view[0]?.screens[0]).toMatchObject({ label: "logs", active: true, unread: true });
    expect(activeScreen(view)?.tab?.surface).toBe(5);
  });

  it("uses local pane selection instead of a changed server active pane", () => {
    const changed = structuredClone(tree);
    changed.workspaces[0]!.screens[0]!.active_pane = 99;
    expect(treeToViewModel(changed, new Set(), localSelection)[0]?.screens[0]).toMatchObject({
      activePane: 3,
      tab: { surface: 5 },
    });
  });

  it("derives workspace and screen highlights only from local selection", () => {
    const changed = structuredClone(tree);
    changed.workspaces[0]!.active = false;
    changed.workspaces[0]!.screens[0]!.active = false;
    const foreignActive = structuredClone(tree.workspaces[0]!);
    foreignActive.id = 9;
    foreignActive.active = true;
    foreignActive.screens[0]!.id = 10;
    foreignActive.screens[0]!.active = true;
    changed.workspaces.push(foreignActive);

    const view = treeToViewModel(changed, new Set(), localSelection);
    expect(view.map(({ id, active }) => [id, active])).toEqual([[1, true], [9, false]]);
    expect(view[0]?.screens[0]?.active).toBe(true);
    expect(view[1]?.screens[0]?.active).toBe(false);
  });

  it("exposes every screen to the drawer and maps a screen to local ID selection", () => {
    const multipleScreens = structuredClone(tree);
    const secondScreen = structuredClone(multipleScreens.workspaces[0]!.screens[0]!);
    secondScreen.id = 6;
    secondScreen.active = false;
    secondScreen.active_pane = 7;
    secondScreen.layout = { type: "leaf", pane: 7 };
    secondScreen.panes = [{
      id: 7,
      name: null,
      active_tab: 0,
      tabs: [{ surface: 8, kind: "pty", browser_source: null, name: null, title: "editor", size: null, dead: false }],
    }];
    multipleScreens.workspaces[0]!.screens.push(secondScreen);

    const drawerWorkspaces = treeToViewModel(multipleScreens, new Set(), localSelection);

    expect(drawerWorkspaces[0]?.screens.map(({ id }) => id)).toEqual([2, 6]);
    expect(screenSelection(drawerWorkspaces[0]!.screens[1]!)).toEqual([1, 6, 8]);
  });
});

describe("applySurfaceTitles", () => {
  it("coalesces authoritative titles into matching tabs with structural sharing", () => {
    const updated = applySurfaceTitles(tree, new Map([[4, "editor"], [5, "logs"]]));

    expect(updated).not.toBe(tree);
    expect(updated.workspaces[0]?.screens[0]?.panes[0]).not.toBe(tree.workspaces[0]?.screens[0]?.panes[0]);
    expect("tabs" in updated.workspaces[0]!.screens[0]!.panes[0]!
      ? updated.workspaces[0]!.screens[0]!.panes[0]!.tabs.map(({ title }) => title)
      : []).toEqual(["editor", "logs"]);
    expect(applySurfaceTitles(tree, new Map([[99, "missing"]]))).toBe(tree);
  });

  it("keeps later title events across overlapping tree refreshes", () => {
    const reconciler = new SurfaceTitleReconciler();
    const olderRefresh = reconciler.beginRefresh();
    reconciler.record(4, "newest");
    const newerRefresh = reconciler.beginRefresh();

    const newerTree = structuredClone(tree);
    const committed = reconciler.commit(newerTree, newerRefresh);
    expect(committed).toEqual({ tree: newerTree, applied: true });

    const olderTree = structuredClone(tree);
    expect(reconciler.commit(olderTree, olderRefresh)).toEqual({ tree: newerTree, applied: false });

    const replay = new SurfaceTitleReconciler();
    const inFlight = replay.beginRefresh();
    replay.record(4, "newest");
    const staleTree = structuredClone(tree);
    const recovered = replay.commit(staleTree, inFlight).tree;
    expect("tabs" in recovered.workspaces[0]!.screens[0]!.panes[0]!
      ? recovered.workspaces[0]!.screens[0]!.panes[0]!.tabs[0]!.title
      : null).toBe("newest");
  });

  it("updates only the indexed title path", () => {
    const reconciler = new SurfaceTitleReconciler();
    const withSibling = structuredClone(tree);
    withSibling.workspaces.push({
      id: 9,
      name: "untouched",
      active: false,
      screens: [],
    });
    const untouched = withSibling.workspaces[1];
    reconciler.apply(withSibling);
    reconciler.record(4, "indexed");

    const updated = reconciler.apply(withSibling);

    expect(updated.workspaces[1]).toBe(untouched);
    expect(updated.workspaces[0]).not.toBe(withSibling.workspaces[0]);
  });
});

import { locateSurface } from "../src/lib/tree";

describe("locateSurface", () => {
  it("finds the workspace and screen containing a surface, or null", () => {
    const tree = {
      workspaces: [
        {
          id: 1, name: "a", active: false,
          screens: [
            { id: 10, workspace: 1, active: true, active_pane: 100, zoomed_pane: null, name: null,
              layout: { type: "pane", pane: 100 },
              panes: [{ id: 100, screen: 10, name: null, active_tab: 0, tabs: [{ surface: 7, pane: 100, kind: "pty", browser_source: null, name: null, title: "t", dead: false, cols: 80, rows: 24 }] }] },
          ],
        },
      ],
    } as never;
    expect(locateSurface(tree, 7)).toEqual({ workspaceId: 1, screenId: 10 });
    expect(locateSurface(tree, 99)).toBeNull();
  });
});
