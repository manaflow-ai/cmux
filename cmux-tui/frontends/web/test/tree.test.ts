import { describe, expect, it } from "vitest";
import type { Tree } from "cmux/browser";
import { activeScreen, treeToViewModel } from "../src/lib/tree";

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

describe("treeToViewModel", () => {
  it("maps the active pane and tab and carries unread state to its screen", () => {
    const view = treeToViewModel(tree, new Set([4]));
    expect(view[0]?.screens[0]).toMatchObject({ label: "logs", active: true, unread: true });
    expect(activeScreen(view)?.tab?.surface).toBe(5);
  });

  it("tolerates a missing active pane", () => {
    const missing = structuredClone(tree);
    missing.workspaces[0]!.screens[0]!.active_pane = 99;
    expect(treeToViewModel(missing, new Set())[0]?.screens[0]?.tab).toBeNull();
  });
});
