import { afterEach, expect, test } from "bun:test";
import {
  DEFAULT_ORDER,
  MORE_LINE,
  MORE_SECTIONS,
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
  expect(sectionOrder([]).slice(5, 9)).toEqual(["sources", "outputs", "alsoHere", MORE_LINE]);
});

test("new app sections follow Sources, above the Show more line, and never tuck", () => {
  const order = sectionOrder([], [prs, session]);
  const inView = order.filter((id) => !tuckedSections(order).includes(id) && id !== MORE_LINE);
  expect(inView).toEqual([
    ...PRIORITY_SECTIONS.slice(0, PRIORITY_SECTIONS.indexOf("sources") + 1),
    prs,
    session,
    "outputs",
    "alsoHere",
  ]);
  expect(order.indexOf(prs)).toBe(order.indexOf("sources") + 1);
});

test("the Show more line is an item of the order: what is under it tucks, a drag across it pins or tucks", () => {
  const order = sectionOrder([]);
  expect(tuckedSections(order)).toEqual([...MORE_SECTIONS]);
  // Usage dragged above the line is in view; Sources dragged under it tucks.
  const moved = moveTo(moveTo(order, "usage", order.indexOf(MORE_LINE)), "sources", order.length - 1);
  expect(tuckedSections(moved)).toContain("sources");
  expect(tuckedSections(moved)).not.toContain("usage");
});

test("an order saved before the line keeps its less-used sections under it, in the person's order", () => {
  const old = parseOrder(
    JSON.stringify(["context", "environment", "usage", "subagents", "tasks", "sources", "connectors", "outputs"]),
  );
  const order = sectionOrder(old);
  // Environment is pinned first (sectionOrder.ts PINNED_TOP); the rest keep the person's order.
  expect(order[0]).toBe("environment");
  expect(order[1]).toBe("context");
  expect(order.indexOf(MORE_LINE)).toBe(order.indexOf("alsoHere") + 1);
  expect(tuckedSections(order)).toEqual(["changes", "usage", "connectors"]);
});

test("dragging an app wins, and new app ids do not reorder saved positions", () => {
  const full = sectionOrder([], [prs, session]);
  const shown = full.filter((id) => !tuckedSections(full).includes(id));
  // A drop above Environment lands right under it: Environment stays first.
  setSectionOrder(moveTo(shown, prs, 0), full);
  const saved = sectionOrder();
  expect(saved[0]).toBe("environment");
  expect(saved[1]).toBe(prs);
  expect(sectionOrder(saved, [prs, session])).toEqual(saved);
});

test("an uninstalled app keeps its saved slot through other drags and reinstall", () => {
  const original = sectionOrder(["environment", prs, session, "context"], [prs, session]);
  const installed = original.filter((id) => id !== prs);
  const changed = mergeShown(original, moveTo(installed, session, installed.length - 1));
  const loaded = parseOrder(JSON.stringify(changed));
  expect(loaded).toContain(prs);
  expect(loaded[0]).toBe("environment");
  expect(loaded[1]).toBe(prs);
  expect(sectionOrder(loaded, [prs, session])[1]).toBe(prs);
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
    // Environment stays first; the other pane's app keeps its slot right under it.
    expect(restored[0]).toBe("environment");
    expect(restored[1]).toBe(session);
    expect(restored.indexOf(prs)).toBeLessThan(restored.indexOf("context"));
    expect(restored.filter((id) => dropped.includes(id))).toEqual(dropped);
    expect(restored).toContain(added);
    expect(restored).toHaveLength(DEFAULT_ORDER.length + 3);
    expect(new Set(restored).size).toBe(restored.length);
  } finally {
    if (originalStorage) Object.defineProperty(globalThis, "localStorage", originalStorage);
    else Reflect.deleteProperty(globalThis, "localStorage");
  }
});
