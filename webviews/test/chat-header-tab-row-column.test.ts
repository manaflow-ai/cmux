// #37412: a chat's pane has no native "…" at its tab row's end (trailingInset 0), so the chat header's tools ended
// flush with the pane's edge and the ••• menu's pressed fill was cut by the pane's rounded corner. The App offers the
// pane's trailing control column (Metrics.paneTrailingControlCenter) with the row; the page centers its last tool on it
// while no native "…" keeps the row's end. test/chat-header-tab-row-surface.test.ts measures the layout in a browser.
import { expect, test } from "bun:test";
import { tabRowStyle } from "../src/agent-session/acpmux/header/tabRow";

test("the offered row keeps the pane's trailing control column", () => {
  const style = tabRowStyle({ height: 28, trailingInset: 0, trailingColumn: 15 }) as Record<string, string>;
  expect(style["--acpmux-tab-row-column"]).toBe("15px");
  expect(style["--acpmux-tab-row-inset"]).toBe("0px");
});

test("a native … at the row's end keeps the edge gap, so the tools add none", () => {
  const style = tabRowStyle({ height: 28, trailingInset: 40, trailingColumn: 15 }) as Record<string, string>;
  expect(style["--acpmux-tab-row-column"]).toBe("0px");
  expect(style["--acpmux-tab-row-inset"]).toBe("40px");
});

test("an App that sends no column keeps the old layout", () => {
  const style = tabRowStyle({ height: 28, trailingInset: 0 }) as Record<string, string>;
  expect(style["--acpmux-tab-row-column"]).toBe("0px");
});
