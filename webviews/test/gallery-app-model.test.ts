// l10n-allow-file: test fixture labels, not shipped UI.
// The whole app page (src/gallery/app): the window it draws around the live agent pane comes from
// the app's metrics (window.ts) and from the scene's own snapshot, so the sidebar names the chats the
// pane does, one row is selected, and only the pane that hosts the scene is live.
import { describe, expect, test } from "bun:test";
import entry from "../src/gallery/scenes/AppWindow.gallery";
import { appWindow } from "../src/gallery/app/model";
import { windowGeometry, windowSize } from "../src/gallery/window";

const metrics = {
  sidebarWidth: { compact: 220, comfortable: 260 },
  titlebarHeight: { compact: 34, comfortable: 40 },
  tabStripHeight: { compact: 32, comfortable: 36 },
  sidebarRowHeightWithSubtitle: { compact: 38, comfortable: 44 },
  columnGap: { compact: 6, comfortable: 8 },
};

describe("whole app window", () => {
  test("a chat scene: its chat is the one selected row, its title the live pane's tab", () => {
    const window = appWindow(entry.variants["chat-session-info"]!, {
      window: "pro14",
      layout: "agent-right",
      density: "comfortable",
      metrics,
    });
    expect([window.width, window.height]).toEqual([1512, 982]);
    expect(window.sidebar.width).toBe(260);
    expect(window.rowHeight).toBe(44);
    expect(window.rows.length).toBeGreaterThan(1);
    expect(window.rows.filter((row) => row.active).map((row) => row.title)).toEqual([
      "Add retries to the fetch helper",
    ]);
    expect(window.rows[0]!.folder).toBe("atlas-web");
    const live = window.panes.filter((pane) => pane.hostsEntry);
    expect(live.length).toBe(1);
    expect(live[0]!.tabs).toEqual([{ title: "Add retries to the fetch helper", kind: "agent", active: true }]);
    expect(window.panes.find((pane) => !pane.hostsEntry)!.tabs[0]!.kind).toBe("terminal");
  });

  test("the New Tab scene selects no row and names its tab New Tab", () => {
    const window = appWindow(entry.variants["new-tab"]!, {
      window: "air13",
      layout: "one",
      density: "compact",
      metrics,
    });
    expect(window.rows.length).toBe(12);
    expect(window.rows.some((row) => row.active)).toBe(false);
    expect(window.panes.map((pane) => pane.tabs[0]!.title)).toEqual(["New Tab"]);
  });

  test("the panes are window.ts's geometry, so the live pane is the size the gallery's window mode renders", () => {
    for (const layout of ["one", "two", "agent-right"] as const) {
      const window = appWindow(entry.variants["new-tab"]!, { window: "16x9", layout, density: "comfortable", metrics });
      const geometry = windowGeometry(windowSize("16x9"), layout, "comfortable", metrics);
      expect(window.panes.map(({ frame, content, hostsEntry }) => ({ frame, content, hostsEntry }))).toEqual(
        geometry.panes,
      );
    }
  });
});
