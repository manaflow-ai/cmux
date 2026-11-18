// A virtualized Combobox row's slot is its border box plus its vertical margins (Combobox.tsx
// `virtualRowSize`): a row with a section heading drawn in its margin-top gets a slot that fits it.
import { expect, test } from "bun:test";
import { virtualRowSize } from "../src/ui/Combobox";

test("a row with no margins keeps its border-box height", () => {
  expect(virtualRowSize(28, "0px", "0px")).toBe(28);
});

test("a row's vertical margins add to its slot", () => {
  expect(virtualRowSize(28, "20px", "0px")).toBe(48);
  expect(virtualRowSize(28, "18px", "4px")).toBe(50);
});

test("fractional sizes round as the virtualizer's own measurement does", () => {
  expect(virtualRowSize(27.6, "19.8px", "0px")).toBe(47);
});

test("a margin that does not parse counts as 0, so the size is never NaN", () => {
  expect(virtualRowSize(28, "", "auto")).toBe(28);
  expect(virtualRowSize(28, "nonsense", "4px")).toBe(32);
  expect(virtualRowSize(Number.NaN, "20px", "")).toBe(20);
});
