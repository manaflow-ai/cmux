import { expect, test } from "bun:test";
import { SHELF_VIEWPORTS, shelfLine, shelvedHeight, shelvedRow } from "./shelvedRows";

test("a row shelves only when it ends past the line above a followed view", () => {
  const line = 5_000 - 800 * SHELF_VIEWPORTS;
  expect(shelvedHeight(100, 300, line)).toBe(300);
  // Ends at the line or below it: drawn.
  expect(shelvedHeight(line - 300, 300, line)).toBe(0);
  expect(shelvedHeight(line - 10, 300, line)).toBe(0);
  // Nothing to skip in a row placed 0 high.
  expect(shelvedHeight(100, 0, line)).toBe(0);
  // No line, no shelf.
  expect(shelvedHeight(100, 300, -Infinity)).toBe(0);
});

test("a view scrolled up, or not yet laid out, shelves nothing", () => {
  expect(shelfLine(false, 5_000, 800)).toBe(-Infinity);
  expect(shelfLine(true, 5_000, 0)).toBe(-Infinity);
});

test("a shelved row says so on its node", () => {
  const node = { dataset: { shelved: "true" } } as unknown as HTMLElement;
  expect(shelvedRow(node)).toBe(true);
  expect(shelvedRow({ dataset: {} } as unknown as HTMLElement)).toBe(false);
});
