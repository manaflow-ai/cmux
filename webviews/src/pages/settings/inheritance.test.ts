// A surface's opacity rests on the window's while unset; the split divider is a line at its own
// opacity (Swift SplitDividerLineTests), so its row never shows the window's value as its own.
import { expect, test } from "bun:test";
import { inheritsWindowColor, parentKey, WINDOW_OPACITY_KEY } from "./inheritance";

test("a surface's opacity inherits the window's", () => {
  expect(parentKey("appearance.surfaces.sidebar.opacity")).toBe(WINDOW_OPACITY_KEY);
});

test("the split divider's opacity and color are its own", () => {
  expect(parentKey("appearance.surfaces.splitDivider.opacity")).toBeNull();
  expect(inheritsWindowColor("appearance.surfaces.splitDivider.color")).toBe(false);
  expect(inheritsWindowColor("appearance.surfaces.sidebar.color")).toBe(true);
});
