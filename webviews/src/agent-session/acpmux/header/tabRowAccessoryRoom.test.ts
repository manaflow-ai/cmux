// https://github.com/manaflow-ai/cmux/issues/53314: "its many tabs crammed into 1/3 of the space ... one tab is crammed
// and need to scroll". A chat's rolling summary (an accessory of the tab row, TAB_ROW_ACCESSORY) took up to half of the
// pane's row, and the tabs shrank and scrolled beside it. The App now offers the accessories only the room its tabs
// leave at their full width (`tabRow.accessoryRoom`, PaneContentView / TabRowAccessoryFit), and the summary keeps to it.
import { expect, test } from "bun:test";
import { TAB_ROW_ACCESSORY_MIN, TAB_ROW_GAP, tabRowToolsFit } from "./tabRow";

test("with no limit, the summary may take the half of the row the tools leave", () => {
  const fit = tabRowToolsFit(400, 300, 1200);
  expect(fit.need).toBe(400 + TAB_ROW_GAP - 300);
  expect(fit.room).toBe(Math.floor(600 - fit.need));
});

test("the tabs' free room caps the summary", () => {
  expect(tabRowToolsFit(400, 300, 1200, 220).room).toBe(220);
  // Under the narrowest summary, it hides whole: the tabs keep the row.
  expect(tabRowToolsFit(400, 300, 1200, TAB_ROW_ACCESSORY_MIN - 1).room).toBe(0);
  expect(tabRowToolsFit(400, 300, 1200, 0).room).toBe(0);
});

test("the limit never widens past the half of the row", () => {
  const fit = tabRowToolsFit(100, 0, 800, 10_000);
  expect(fit.room).toBe(Math.floor(400 - fit.need));
});
