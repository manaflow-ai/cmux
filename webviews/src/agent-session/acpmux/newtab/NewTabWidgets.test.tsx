import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { WIDGET_OPS, type WidgetTilePlacement } from "../../../apps/scene/widgetsClient";
import { MockWidgetsHost } from "../../../apps/scene/widgetsMock";
import { teardownDom } from "../../../../test/support/domTeardown";
import { NewTabWidgets } from "./NewTabWidgets";
import { droppedCell, moveEdit, movedCell } from "./widgetEditingModel";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
/** The tiles IntersectionObserver watches, so a test can scroll one out of view. */
const observed: { element: Element; callback: (entries: { isIntersecting: boolean }[]) => void }[] = [];
class FakeIntersectionObserver {
  constructor(private readonly callback: (entries: { isIntersecting: boolean }[]) => void) {}
  observe(element: Element) {
    observed.push({ element, callback: this.callback });
  }
  disconnect() {}
}
(dom.window as unknown as Record<string, unknown>).IntersectionObserver = FakeIntersectionObserver;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
  requestAnimationFrame: (callback: (time: number) => void) => setTimeout(() => callback(Date.now()), 0),
  cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle),
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
// A loaded CI box renders a grid of live scenes slowly; no test here waits on a timer.
setDefaultTimeout(30_000);
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

async function settled(rounds = 8) {
  for (let i = 0; i < rounds; i++) await new Promise<void>((resolve) => queueMicrotask(resolve));
}

async function render(host: MockWidgetsHost, props: Parameters<typeof NewTabWidgets>[0] = {}) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(<NewTabWidgets client={host} {...props} />);
    await settled();
  });
  return {
    container,
    async unmount() {
      await act(async () => root.unmount());
      container.remove();
    },
  };
}

const placed: WidgetTilePlacement[] = [
  { instance: "w1", app: "cmux/clock", size: "small" },
  { instance: "w2", app: "cmux/weather", size: "medium" },
  { instance: "w3", app: "cmux/todo", size: "large" },
];

test("with no widget installed and none placed the page draws nothing and mounts nothing", async () => {
  const host = new MockWidgetsHost();
  host.widgets = [];
  const page = await render(host);
  expect(page.container.innerHTML).toBe("");
  expect(host.mountCalls).toBe(0);
  await page.unmount();
});

test("installed but unplaced widgets show only Edit Widgets, with no mount", async () => {
  const host = new MockWidgetsHost();
  const page = await render(host);
  expect(page.container.querySelector(".nt-widget-grid")).toBeNull();
  expect(page.container.querySelector('[data-edit="start"]')?.textContent).toBe("Edit Widgets");
  expect(host.mountCalls).toBe(0);
  await page.unmount();
});

test("the grid draws each tile at its size on one tile unit", async () => {
  const host = new MockWidgetsHost(placed);
  const page = await render(host);
  const tiles = [...page.container.querySelectorAll(".nt-widget-grid > .nt-widget-tile")];
  expect(tiles.map((tile) => [tile.getAttribute("data-app"), tile.getAttribute("data-size")])).toEqual([
    ["cmux/clock", "small"],
    ["cmux/weather", "medium"],
    ["cmux/todo", "large"],
  ]);
  // Each tile is a card around its widget's own scene.
  expect(
    page.container.querySelectorAll(".nt-widget-card .cmux-app-scene-root, .nt-widget-card [data-scene-node]").length,
  ).toBeGreaterThan(0);
  await page.unmount();
  expect(host.mounts.size).toBe(0);
});

test("edit mode removes and resizes through the daemon's edit op", async () => {
  const host = new MockWidgetsHost(placed);
  const page = await render(host, { editLook: "chips" });
  await act(async () => {
    page.container.querySelector<HTMLButtonElement>('[data-edit="start"]')!.click();
    await settled();
  });
  const frames = page.container.querySelectorAll(".nt-widget-frame");
  expect(frames.length).toBe(3);
  await act(async () => {
    frames[0]!.querySelector<HTMLButtonElement>(".nt-widget-remove")!.click();
    await settled();
  });
  await act(async () => {
    const medium = [
      ...page.container.querySelectorAll<HTMLButtonElement>('.nt-widget-frame[data-cell="w3"] .nt-widget-chip'),
    ].find((chip) => chip.textContent === "Medium")!;
    medium.click();
    await settled();
  });
  const edits = host.calls.filter((call) => call.op === WIDGET_OPS.edit).map((call) => call.params);
  expect(edits.map((edit) => edit.edit)).toEqual([
    { op: "remove", instance: "w1" },
    { op: "resize", instance: "w3", size: "medium" },
  ]);
  expect(edits.every((edit) => typeof edit.idempotency_key === "string" && edit.idempotency_key !== "")).toBe(true);
  expect(
    [...page.container.querySelectorAll(".nt-widget-frame")].map((frame) => frame.getAttribute("data-size")),
  ).toEqual(["medium", "medium"]);
  await page.unmount();
});

test("Add Widget lists the installed widgets with live previews at each size, and adds at the chosen one", async () => {
  const host = new MockWidgetsHost();
  const page = await render(host, { initialEditing: true });
  await act(async () => {
    page.container.querySelector<HTMLButtonElement>('[data-edit="add"]')!.click();
    await settled();
  });
  const previews = [...document.querySelectorAll<HTMLButtonElement>(".nt-widget-preview")];
  expect(previews.map((p) => `${p.dataset.app}:${p.dataset.size}`)).toEqual([
    "cmux/clock:small",
    "cmux/clock:medium",
    "cmux/clock:large",
    "cmux/weather:small",
    "cmux/weather:medium",
    "cmux/todo:medium",
    "cmux/todo:large",
  ]);
  const previewMounts = host.calls
    .filter((call) => call.op === "cmux.apps.panels.mount")
    .map((call) => call.params.context);
  expect(previewMounts.every((context) => (context as { preview?: boolean }).preview === true)).toBe(true);
  await act(async () => {
    previews.find((p) => p.dataset.app === "cmux/weather" && p.dataset.size === "medium")!.click();
    await settled();
  });
  const add = host.calls.find((call) => call.op === WIDGET_OPS.edit)!.params;
  expect(add.edit).toEqual({ op: "add", app: "cmux/weather", size: "medium" });
  // The sheet closed: its previews unmounted; the new tile mounted once.
  expect([...host.mounts.values()].filter((mount) => mount.context.preview).length).toBe(0);
  expect(page.container.querySelector('.nt-widget-frame[data-size="medium"]')).not.toBeNull();
  await page.unmount();
});

test("a stale tile keeps its scene, dimmed, with Updating...; the others draw on", async () => {
  const host = new MockWidgetsHost(placed);
  const page = await render(host);
  await act(async () => {
    host.health(host.mountOf("w2")!, true);
    await settled();
  });
  const cards = [...page.container.querySelectorAll(".nt-widget-card")];
  expect(cards.map((card) => card.hasAttribute("data-stale"))).toEqual([false, true, false]);
  expect(cards[1]!.querySelector(".nt-widget-stale")?.textContent).toBe("Updating…");
  expect(cards[1]!.textContent).toContain("19°");
  await act(async () => {
    host.health(host.mountOf("w2")!, false);
    await settled();
  });
  expect(page.container.querySelectorAll(".nt-widget-card[data-stale]").length).toBe(0);
  await page.unmount();
});

test("a tile scrolled out of view, or a hidden page, is reported hidden", async () => {
  observed.length = 0;
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  const page = await render(host);
  const id = host.mountOf("w1")!;
  // Shown on mount: nothing to send until it hides.
  expect(host.visible.get(id)).toBeUndefined();
  await act(async () => {
    observed.at(-1)!.callback([{ isIntersecting: false }]);
    await settled();
  });
  expect(host.visible.get(id)).toBe(false);
  await act(async () => {
    observed.at(-1)!.callback([{ isIntersecting: true }]);
    await settled();
  });
  expect(host.visible.get(id)).toBe(true);
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
  await act(async () => {
    document.dispatchEvent(new dom.window.Event("visibilitychange"));
    await settled();
  });
  expect(host.visible.get(id)).toBe(false);
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  await page.unmount();
});

test("drag and keyboard moves become the daemon's move before the next tile", () => {
  const order = ["w1", "w2", "w3"];
  expect(movedCell(order, "w1", 1)).toEqual(["w2", "w1", "w3"]);
  expect(droppedCell(order, "w3", "w1", false)).toEqual(["w3", "w1", "w2"]);
  expect(moveEdit(order, ["w2", "w1", "w3"], "w1")).toEqual({ op: "move", instance: "w1", before: "w3" });
  expect(moveEdit(order, ["w2", "w3", "w1"], "w1")).toEqual({ op: "move", instance: "w1" });
  expect(moveEdit(order, order, "w1")).toBeUndefined();
});
