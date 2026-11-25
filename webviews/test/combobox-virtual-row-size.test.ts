// A virtualized Combobox row's slot is its border box plus its vertical margins (Combobox.tsx
// `virtualRowSize`): a row with a section heading drawn in its margin-top gets a slot that fits it.
import { expect, test } from "bun:test";
import { virtualRowKey, virtualRowSize, virtualRowSlot } from "../src/ui/Combobox";

test("without a size key a virtual row's key is its item", () => {
  expect(virtualRowKey("/Users/me/app")).toBe("/Users/me/app");
});

test("with a size key a row's key changes with it, and differs from another item's", () => {
  const headings = new Map([["/Users/me/app", "This Mac"]]);
  const sizeKey = (item: string) => headings.get(item) ?? "";
  const headed = virtualRowKey("/Users/me/app", sizeKey);
  expect(headed).not.toBe(virtualRowKey("/Users/me/notes", sizeKey));
  headings.delete("/Users/me/app");
  expect(virtualRowKey("/Users/me/app", sizeKey)).not.toBe(headed);
  headings.set("/Users/me/app", "This Mac");
  expect(virtualRowKey("/Users/me/app", sizeKey)).toBe(headed);
});

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

test("a row mounted again keeps the slot measured with its heading's margin (#46018)", () => {
  // The GitHub heading row was measured at 48 (28 + 20 margin); remounted, it must not shrink to its 28 border box.
  let measured = 0;
  expect(virtualRowSlot(48, () => (measured++, 28))).toBe(48);
  expect(measured).toBe(0);
  expect(virtualRowSlot(undefined, () => virtualRowSize(28, "20px", "0px"))).toBe(48);
});
