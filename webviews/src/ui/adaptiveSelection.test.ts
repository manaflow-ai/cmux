// The selection fit (HIGHLIGHT-CONTRAST): a selection inside a field draws in the config's color,
// never in a fill fit to a bubble selected earlier (router-review follow-up on cmux#37649).
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SELECTION_FILL_PROPERTY, updateSelectionFill } from "./adaptiveSelection";

let dom: JSDOM | undefined;
afterEach(() => {
  dom?.window.close();
  dom = undefined;
});

test("selecting in a field after a bubble drops the bubble's fitted fill", () => {
  dom = new JSDOM(`<!doctype html><body><input id="field" value="library"></body>`, { pretendToBeVisual: true });
  const doc = dom.window.document;
  // The fill a bubble selection left on the root.
  doc.documentElement.style.setProperty(SELECTION_FILL_PROPERTY, "rgb(120 150 200 / 0.99)");
  const field = doc.getElementById("field") as HTMLInputElement;
  field.focus();
  field.select();
  updateSelectionFill(doc);
  expect(doc.documentElement.style.getPropertyValue(SELECTION_FILL_PROPERTY)).toBe("");
});
