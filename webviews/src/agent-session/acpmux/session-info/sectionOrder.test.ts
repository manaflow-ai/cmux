import { afterEach, expect, test } from "bun:test";
import {
  DEFAULT_ORDER,
  ORDER_KEY,
  PRIORITY_SECTIONS,
  mergeShown,
  moveTo,
  parseOrder,
  resetSectionOrderForTests,
  sectionOrder,
  setSectionOrder,
  tuckedSections,
} from "./sectionOrder";

const prs = "app:local/customize#prs" as const;
const session = "app:session-tools#summary" as const;
afterEach(resetSectionOrderForTests);

test("built-in order is unchanged without installed apps", () => {
  expect(sectionOrder([])).toEqual([...DEFAULT_ORDER]);
});

test("new app sections follow Leo's four in the default view and never tuck", () => {
  const order = sectionOrder([], [prs, session]);
  expect(order.filter((id) => !tuckedSections(order).includes(id))).toEqual([...PRIORITY_SECTIONS, prs, session]);
  expect(order.indexOf(prs)).toBe(order.indexOf("sources") + 1);
});

test("dragging an app wins, and new app ids do not reorder saved positions", () => {
  const full = sectionOrder([], [prs, session]);
  const shown = full.filter((id) => !tuckedSections(full).includes(id));
  setSectionOrder(moveTo(shown, prs, 0), full);
  const saved = sectionOrder();
  expect(saved.indexOf(prs)).toBeLessThan(saved.indexOf("environment"));
  expect(sectionOrder(saved, [prs, session])).toEqual(saved);
});

test("an uninstalled app keeps its saved slot through other drags and reinstall", () => {
  const original = sectionOrder([prs, "environment", session, "context"], [prs, session]);
  const installed = original.filter((id) => id !== prs);
  const changed = mergeShown(original, moveTo(installed, session, installed.length - 1));
  const loaded = parseOrder(JSON.stringify(changed));
  expect(loaded).toContain(prs);
  expect(loaded[0]).toBe(prs);
  expect(sectionOrder(loaded, [prs, session])[0]).toBe(prs);
});

test("stored app IDs are validated and deduplicated without a current catalog", () => {
  expect(parseOrder(JSON.stringify([prs, prs, "app:bad", "unknown", "environment"]))).toEqual([prs, "environment"]);
  expect(ORDER_KEY).toBe("cmux.agentPane.inspector.order");
});

test("a drop keeps another pane's uninstalled app and an app added during the drag", () => {
  const originalStorage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  const values = new Map<string, string>();
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      values.set(key, value);
    },
  };
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: storage });
  resetSectionOrderForTests();
  try {
    const atDragStart = sectionOrder([], [prs]);
    // Another pane saves a section this pane no longer has installed. Deliberately send no
    // storage event: the drop must read the system of record, not depend on a React render.
    storage.setItem(ORDER_KEY, JSON.stringify([session, ...atDragStart]));
    const added = "app:local/customize#notes" as const;
    const visible = atDragStart.filter((id) => !tuckedSections(atDragStart).includes(id));
    const dropped = [...moveTo(visible, prs, 0), added];
    setSectionOrder(dropped, atDragStart);
    resetSectionOrderForTests();
    const restored = sectionOrder();
    expect(restored[0]).toBe(session);
    expect(restored.indexOf(prs)).toBeLessThan(restored.indexOf("environment"));
    expect(restored.filter((id) => dropped.includes(id))).toEqual(dropped);
    expect(restored).toContain(added);
    expect(restored).toHaveLength(DEFAULT_ORDER.length + 3);
    expect(new Set(restored).size).toBe(restored.length);
  } finally {
    if (originalStorage) Object.defineProperty(globalThis, "localStorage", originalStorage);
    else Reflect.deleteProperty(globalThis, "localStorage");
  }
});
