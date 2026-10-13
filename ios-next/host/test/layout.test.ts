import { describe, expect, it } from "vitest";
import { checkDaemonCommand, PolicyError } from "../src/bridge/policy.ts";
import { layoutTab, mapDaemonLayout } from "../src/layout/index.ts";
import { paneRects } from "../src/layout/split.ts";
import { connectedCore, waitFor } from "./helpers.ts";

// The tree shape cmux-next's list-workspaces returns (trimmed from a live dump).
const tree = {
  workspaces: [
    {
      id: 1,
      name: "Home",
      color: null,
      active: true,
      screens: [
        {
          id: 4,
          active: true,
          active_pane: 12,
          layout: {
            type: "split",
            dir: "right",
            ratio: 0.4,
            split: 10,
            a: { type: "leaf", pane: 3 },
            b: { type: "split", dir: "down", ratio: 0.5, split: 13, a: { type: "leaf", pane: 9 }, b: { type: "leaf", pane: 12 } },
          },
          panes: [
            {
              id: 3,
              active_tab: 1,
              tabs: [
                { surface: 2, kind: "pty", name: null, title: "~" },
                { surface: 5, kind: "browser", title: "Example", url: "https://example.com/", browser_renderer: "frontend" },
              ],
            },
            { id: 9, active_tab: 0, tabs: [{ surface: 7, kind: "conversation", title: "codex", conversation: { agent_session: { host: null, session: "sess-1", harness: "codex", host_name: null } } }] },
            { id: 12, active_tab: 0, tabs: [{ surface: 8, kind: "pty", name: "build", title: "zsh" }] },
          ],
        },
      ],
    },
    { id: 2, name: null, title: "Second", active: false, screens: [{ id: 20, active: true, active_pane: 21, layout: { type: "leaf", pane: 21 }, panes: [{ id: 21, active_tab: 0, tabs: [] }] }] },
  ],
};

describe("layout mapping", () => {
  it("computes normalized pane rects from the split tree", () => {
    const rects = paneRects(tree.workspaces[0]!.screens[0]!.layout);
    expect(rects.get(3)).toEqual({ x: 0, y: 0, w: 0.4, h: 1 });
    expect(rects.get(9)).toEqual({ x: 0.4, y: 0, w: 0.6, h: 0.5 });
    expect(rects.get(12)).toEqual({ x: 0.4, y: 0.5, w: 0.6, h: 0.5 });
  });

  it("maps workspaces, panes, tabs and focus", () => {
    const layout = mapDaemonLayout(tree);
    expect(layout.workspaces.map((w) => [w.id, w.title, w.active, w.activePaneId])).toEqual([
      ["w1", "Home", true, "p12"],
      ["w2", "Second", false, "p21"],
    ]);
    const [p3, p9, p12] = layout.workspaces[0]!.panes;
    expect(p3).toMatchObject({ id: "p3", focusedTabId: "t5", active: false });
    expect(p3!.tabs).toEqual([
      { id: "t2", kind: "terminal", title: "~", refId: "s2", streamable: true, focused: false },
      { id: "t5", kind: "browser", title: "Example", url: "https://example.com/", streamable: false, focused: true, visibleOnMac: true, reason: expect.any(String) },
    ]);
    expect(p9!.tabs[0]).toEqual({ id: "t7", kind: "agent", title: "codex", refId: "sess-1", streamable: true, focused: true });
    expect(p12).toMatchObject({ id: "p12", active: true, tabs: [{ title: "build", refId: "s8" }] });
  });

  it("marks remote agent tabs and other kinds unstreamable, always with a reason", () => {
    expect(layoutTab({ surface: 1, kind: "conversation", conversation: { agent_session: { host: "mini2", session: "x" } } }, false)).toMatchObject({ kind: "agent", streamable: false, reason: "This agent runs on mini2" });
    // The Home conversation tab (rendered by the app's web view) stays a conversation.
    expect(layoutTab({ surface: 1, kind: "conversation", browser_renderer: "frontend", url: "about:blank", conversation: { conversation: "c" } } as any, false)).toMatchObject({ kind: "conversation", streamable: false, reason: expect.any(String) });
    expect(layoutTab({ surface: 1, kind: "diff" }, false)).toMatchObject({ kind: "other", streamable: false, reason: expect.any(String) });
  });

  it("classifies every cmux-next browser pane shape as a browser tab", () => {
    const shapes = [
      { surface: 1, kind: "browser", url: "https://a/" },
      { surface: 2, kind: "conversation", conversation: { page: { url: "https://b/" } }, url: "https://b/" },
      { surface: 3, kind: "frontend-browser", browser_renderer: "frontend", url: "https://c/" },
      { surface: 4, kind: "web", url: "https://d/" },
    ];
    for (const t of shapes) {
      const tab = layoutTab(t as any, true);
      expect(tab, JSON.stringify(t)).toMatchObject({ kind: "browser", streamable: false, reason: expect.any(String) });
    }
  });

  it("allows only the focus commands, with numeric ids", () => {
    expect(() => checkDaemonCommand("select-tab", { pane: 3, index: 1 })).not.toThrow();
    expect(() => checkDaemonCommand("focus-pane", { pane: 3 })).not.toThrow();
    for (const [cmd, p] of [
      ["select-tab", { pane: "pane_x", index: 1 }],
      ["select-tab", { pane: 3, delta: 1 }],
      ["select-workspace", { delta: -1 }],
      ["move-tab", { pane: 3 }],
      ["close-pane", { pane: 3 }],
      ["split", { pane: 3, dir: "right" }],
      ["set-split-ratio", { split: 10, ratio: 0.5 }],
    ] as const) {
      expect(() => checkDaemonCommand(cmd, p as Record<string, unknown>), cmd).toThrow(PolicyError);
    }
  });
});

describe("standalone layout", () => {
  it("synthesizes a terminals pane and a browser pane and tracks focus", async () => {
    const { core, client } = await connectedCore({ terminal: { shell: "/bin/sh", args: [] } });
    try {
      expect((await client.hello()).capabilities).toContain("layout.v1");
      const events: any[] = [];
      client.peer.on("event", (t, p) => t === "layout.changed" && events.push(p.layout));
      const { terminal: a } = await client.request("term.create", { cols: 80, rows: 24 });
      const { terminal: b } = await client.request("term.create", { cols: 80, rows: 24 });
      const { layout } = await client.request("layout.get");
      const [terms, browser] = layout.workspaces[0].panes;
      expect(terms).toMatchObject({ id: "p-terminals", rect: { x: 0, y: 0, w: 0.5, h: 1 }, active: true, focusedTabId: `t-${a.id}` });
      expect(terms.tabs.map((t: any) => [t.kind, t.refId])).toEqual([
        ["terminal", a.id],
        ["terminal", b.id],
      ]);
      expect(browser).toMatchObject({ id: "p-browser", tabs: [] });
      await client.request("layout.focusTab", { paneId: "p-terminals", tabId: `t-${b.id}` });
      await waitFor(() => events.some((l) => l.workspaces[0].panes[0].focusedTabId === `t-${b.id}`));
      await expect(client.request("layout.focusTab", { paneId: "p-terminals", tabId: "t-nope" })).rejects.toMatchObject({ code: "not_found" });
    } finally {
      core.shutdown();
    }
  });
});
