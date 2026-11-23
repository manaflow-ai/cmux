import { afterEach, expect, test } from "bun:test";
import {
  sizeStore,
  fitEffortWidth,
  fitMenuHeight,
  MODEL_MENU_MIN_HEIGHT,
  MODEL_MENU_MIN_WIDTH,
  modelMenuHeight,
  modelMenuWidth,
  setModelMenuHeight,
  setModelMenuWidth,
} from "./modelMenuWidth";

afterEach(() => {
  setModelMenuWidth(undefined);
  setModelMenuHeight(undefined);
});

test("a dragged width is kept, never under the floor, and a reset goes back to the default", () => {
  expect(modelMenuWidth()).toBeUndefined();
  setModelMenuWidth(512.4);
  expect(modelMenuWidth()).toBe(512);
  setModelMenuWidth(40);
  expect(modelMenuWidth()).toBe(MODEL_MENU_MIN_WIDTH);
  setModelMenuWidth(undefined);
  expect(modelMenuWidth()).toBeUndefined();
});

test("a dragged height is kept apart from the width, never under its floor, and a reset goes back", () => {
  expect(modelMenuHeight()).toBeUndefined();
  setModelMenuHeight(301.6);
  expect(modelMenuHeight()).toBe(302);
  expect(modelMenuWidth()).toBeUndefined();
  expect(globalThis.localStorage?.getItem("cmux.acpmux.modelMenuHeight.v2") ?? "302").toBe("302");
  setModelMenuHeight(20);
  expect(modelMenuHeight()).toBe(MODEL_MENU_MIN_HEIGHT);
  setModelMenuHeight(undefined);
  expect(modelMenuHeight()).toBeUndefined();
});

test("the effort column fits every level and Fast whole, a provider up to its most, and the heading", () => {
  // A level wider than the most still fits whole: a level is never cut ("Extra ...").
  expect(fitEffortWidth({ levels: 130, providers: 0, padding: 30, head: 80, most: 120 })).toBe(162);
  // A long provider name is held to the most width.
  expect(fitEffortWidth({ levels: 60, providers: 300, padding: 30, head: 80, most: 150 })).toBe(152);
  // A heading wider than every row widens the column to it.
  expect(fitEffortWidth({ levels: 40, providers: 0, padding: 30, head: 100 })).toBe(102);
});

test("the default height is the tallest effort column whole, search row to Fast, nothing more", () => {
  const metrics = { head: 41, line: 1, padding: 8, row: 28, caption: 22, foot: 37, around: 0 };
  // Low, Medium, High, Extra High, Max, Ultracode and Fast.
  expect(fitMenuHeight({ rows: 6, captions: 0, fast: true }, metrics)).toBe(41 + 1 + 8 + 6 * 28 + 37);
  // No Fast anywhere: no footer.
  expect(fitMenuHeight({ rows: 6, captions: 0, fast: false }, metrics)).toBe(41 + 1 + 8 + 6 * 28);
  // Providers: their caption and rows, and an update strip under the columns.
  expect(fitMenuHeight({ rows: 5, captions: 1, fast: true }, { ...metrics, around: 30 })).toBe(
    41 + 1 + 8 + 5 * 28 + 22 + 37 + 30,
  );
});

test("a size kept under a retired key is dropped once; the new key keeps the next drag", () => {
  const items = new Map<string, string>([
    ["old.width", "900"],
    ["new.width", "500"],
  ]);
  const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    },
  });
  try {
    // The old default's drag is gone; the new key's size is the person's.
    const store = sizeStore("new.width", 260, ["old.width"]);
    expect(items.has("old.width")).toBe(false);
    expect(store.get()).toBe(500);
    // With nothing under the new key, the default (undefined) shows, and a drag is kept from then on.
    items.delete("new.width");
    const fresh = sizeStore("new.width", 260, ["old.width"]);
    expect(fresh.get()).toBeUndefined();
    fresh.set(420);
    expect(items.get("new.width")).toBe("420");
    expect(sizeStore("new.width", 260, ["old.width"]).get()).toBe(420);
  } finally {
    if (saved) Object.defineProperty(globalThis, "localStorage", saved);
    else delete (globalThis as { localStorage?: unknown }).localStorage;
  }
});
