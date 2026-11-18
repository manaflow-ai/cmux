// An app scene's LazyVStack draws what is visible (the visible-only rule). Inside a scroller the page owns
// (New Tab), it mounts the same children at 1,000 and 4,000 (a scene holds at most 4,096 nodes), a change
// to one child draws only that child again and a scroll step draws only the children it brings in. In an
// app panel the host scrolls outside the page: the stack draws whole up to its cap of 100, logs once and
// still draws whole above it, and once the host sends a visible slice mounts only the slice's band (one
// slice height each side), between spacers that keep the scene exactly as tall. Before, a LazyVStack drew
// every child, as a VStack does.
import { afterAll, afterEach, beforeAll, expect, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { SceneOp, SceneStore as SceneStoreType } from "../src/apps/scene/store";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;

// Each Row is ROW px (the stack's estimate before it learns a type: TanStack measures nothing at mount under
// jsdom); the page's scroller is VIEW px (20 rows) tall; a spacer is its own height.
const ROW = 28;
const VIEW = 560;
const sizes = (element: HTMLElement) => {
  if (element.classList.contains("scroller")) return VIEW;
  if (element.classList.contains("cmux-app-scene-lazy-spacer")) return parseFloat(element.style.height) || 0;
  return element.dataset.appType === "Row" ? ROW : 0;
};

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/", pretendToBeVisual: true });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  installVirtualSizes(dom.window, sizes);
  // Every box starts at its scroller's top, moved up by what its ancestors scrolled (jsdom has no layout).
  dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    let top = 0;
    for (let parent = this.parentElement; parent; parent = parent.parentElement) top -= parent.scrollTop;
    return { top, bottom: top, left: 0, right: 0, width: 0, height: 0, x: 0, y: top, toJSON: () => ({}) } as DOMRect;
  };
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  document.body.replaceChildren();
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { SceneRenderer } = await import("../src/apps/scene/SceneRenderer");
const { SceneMount } = await import("../src/apps/scene/panels");
const { VisibleSliceInput } = await import("../src/apps/scene/panelsClient");
const { SceneStore } = await import("../src/apps/scene/store");

/** A LazyVStack of `n` Rows (`r0`...), `spacing` apart, optionally inside a ForEach. */
function lazyScene(n: number, { spacing = 0, forEach = false } = {}): SceneStoreType {
  const store = new SceneStore();
  const rows = Array.from({ length: n }, (_, index) => `r${index}`);
  const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: { spacing } }];
  for (const id of rows) ops.push({ op: "create", id, type: "Row", props: { title: `Row ${id}` } });
  if (forEach) {
    ops.push({ op: "create", id: "each", type: "ForEach" }, { op: "children", id: "each", children: rows });
    ops.push({ op: "children", id: "list", children: ["each"] });
  } else ops.push({ op: "children", id: "list", children: rows });
  ops.push({ op: "root", id: "list" });
  store.apply(ops, true);
  return store;
}

const mountedIds = () =>
  [...document.querySelectorAll<HTMLElement>("[data-app-type=Row]")].map((row) => row.dataset.appNode!);
// A store update draws a memo SceneNodeView again with the same props object, so count its Row content
// (SceneRow, not memoized, takes a new props object on each SceneNodeView render).
const renders = () => mountedRowRenders(() => document.querySelectorAll(".cmux-app-scene-row-title"), "SceneRow");

/** The stack's laid-out height as a flex column draws it: each child (a row or a spacer) and the gaps between. */
function stackHeight(spacing: number): number {
  const stack = document.querySelector<HTMLElement>("[data-app-type=LazyVStack]")!;
  // A hidden element is no flex item (no gap).
  const children = ([...stack.children] as HTMLElement[]).filter((child) => !child.hidden);
  return children.reduce((sum, child) => sum + sizes(child), 0) + Math.max(0, children.length - 1) * spacing;
}

/** The scene in a scroller the page owns, as New Tab's `.nt-app-page`. */
async function inScroller(store: SceneStoreType): Promise<HTMLElement> {
  const scroller = document.createElement("div");
  scroller.className = "scroller";
  scroller.style.overflowY = "auto";
  document.body.append(scroller);
  root = createRoot(scroller);
  await act(async () => root!.render(<SceneRenderer store={store} dispatch={() => {}} />));
  return scroller;
}

async function scrollTo(scroller: HTMLElement, top: number) {
  await act(async () => {
    scroller.scrollTo({ top });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("in a scroller the page owns, 1,000 and 4,000 children mount the same children", async () => {
  const counts: number[] = [];
  for (const n of [1_000, 4_000]) {
    const scroller = await inScroller(lazyScene(n));
    await scrollTo(scroller, 300 * ROW);
    counts.push(mountedIds().length);
    act(() => root!.unmount());
    root = undefined;
    document.body.replaceChildren();
  }
  // One viewport (20 rows) in sight and one each side.
  expect(counts).toEqual([60, 60]);
});

test("in a scroller the page owns, one changed child and one scroll step draw only their children", async () => {
  const store = lazyScene(4_000);
  const scroller = await inScroller(store);
  await scrollTo(scroller, 300 * ROW);
  const counter = renders();

  counter.mark();
  await act(async () => store.apply([{ op: "update", id: "r310", props: { title: "Changed" } }]));
  expect(counter.since()).toBe(1);

  for (let step = 1; step <= 5; step++) {
    const before = new Set(mountedIds());
    counter.mark();
    await scrollTo(scroller, (300 + step) * ROW);
    const entering = mountedIds().filter((id) => !before.has(id)).length;
    expect(entering).toBeGreaterThan(0);
    expect(counter.since()).toBe(entering);
  }
});

test("a LazyVStack over a ForEach windows the ForEach's rows", async () => {
  const scroller = await inScroller(lazyScene(1_000, { forEach: true }));
  await scrollTo(scroller, 300 * ROW);
  expect(mountedIds().length).toBe(60);
  expect(mountedIds()[0]).toBe("r280");
});

test("in a scroller the page owns, the focused child stays mounted when it scrolls far away", async () => {
  const store = lazyScene(1_000);
  store.apply([{ op: "update", id: "r5", props: { title: "Focused", onTap: true } }]);
  const scroller = await inScroller(store);
  await act(async () => document.querySelector<HTMLElement>("[data-app-node=r5]")!.focus());
  await scrollTo(scroller, 500 * ROW);
  expect(mountedIds()).toContain("r5");
  expect(document.activeElement?.getAttribute("data-app-node")).toBe("r5");
});

/** The scene in an app panel (the host scrolls it): the mount with its slice input. */
async function inPanel(store: SceneStoreType) {
  const layouts: number[] = [];
  const visibleSlice = new VisibleSliceInput();
  const container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <SceneMount
        mounted={{
          panel: { app: "local/test", section: "list", title: "List" },
          store,
          dispatch: () => {},
          reload: () => {},
          layout: (height) => layouts.push(height),
          resolveAsset: () => undefined,
          visibleSlice,
        }}
      />,
    ),
  );
  return { layouts, visibleSlice };
}

test("in a panel with no slice, a LazyVStack of up to 100 children draws whole and logs nothing", async () => {
  const warn = spyOn(console, "warn").mockImplementation(() => {});
  try {
    await inPanel(lazyScene(100));
    expect(mountedIds().length).toBe(100);
    expect(warn).not.toHaveBeenCalled();
  } finally {
    warn.mockRestore();
  }
});

test("in a panel with no slice, a LazyVStack over 100 children logs once per scene and still draws whole", async () => {
  const warn = spyOn(console, "warn").mockImplementation(() => {});
  try {
    const store = lazyScene(150);
    await inPanel(store);
    expect(mountedIds().length).toBe(150);
    await act(async () => store.apply([{ op: "update", id: "r3", props: { title: "Changed" } }]));
    await act(async () =>
      store.apply([
        { op: "create", id: "r150", type: "Row", props: { title: "Row r150" } },
        { op: "children", id: "list", children: [...store.getNode("list")!.children, "r150"] },
      ]),
    );
    expect(mountedIds().length).toBe(151);
    expect(warn).toHaveBeenCalledTimes(1);
    act(() => root!.unmount());
    root = undefined;
    // Another scene logs its own.
    await inPanel(lazyScene(120));
    expect(warn).toHaveBeenCalledTimes(2);
  } finally {
    warn.mockRestore();
  }
});

test("in a panel, a slice mounts the slice's band and the scene keeps its height", async () => {
  const spacing = 4;
  const store = lazyScene(1_000, { spacing });
  const { visibleSlice } = await inPanel(store);
  expect(mountedIds().length).toBe(1_000);
  const whole = stackHeight(spacing);
  expect(whole).toBe(1_000 * ROW + 999 * spacing);

  // Row i spans [32 i, 32 i + 28); the band is [3400 - 560, 3400 + 1120]: rows 88 (ends at 2844) to 141
  // (starts at 4512).
  await act(async () => visibleSlice.show({ revision: 1, top: 3_400, height: VIEW }));
  const ids = mountedIds();
  expect(ids.length).toBe(141 - 88 + 1);
  expect(ids[0]).toBe("r88");
  expect(ids.at(-1)).toBe("r141");
  expect(stackHeight(spacing)).toBe(whole);

  // The top of the scene: no leading spacer, rows 0 to 34 (those that start above 1120).
  await act(async () => visibleSlice.show({ revision: 2, top: 0, height: VIEW }));
  expect(mountedIds()).toEqual(Array.from({ length: 35 }, (_, index) => `r${index}`));
  expect(stackHeight(spacing)).toBe(whole);

  // Scrolled out: nothing mounts, one spacer keeps the height.
  await act(async () => visibleSlice.show({ revision: 3, top: 0, height: 0 }));
  expect(mountedIds().length).toBe(0);
  expect(stackHeight(spacing)).toBe(whole);

  // An older slice is dropped.
  await act(async () => visibleSlice.show({ revision: 2, top: 3_400, height: VIEW }));
  expect(mountedIds().length).toBe(0);
});

test("in a panel, a slice over a stack of up to 100 children changes nothing", async () => {
  const { visibleSlice } = await inPanel(lazyScene(100));
  await act(async () => visibleSlice.show({ revision: 1, top: 0, height: 60 }));
  expect(mountedIds().length).toBe(100);
});

test("in a panel, a slice windows a LazyVStack's ForEach rows too", async () => {
  const { visibleSlice } = await inPanel(lazyScene(1_000, { forEach: true }));
  expect(mountedIds().length).toBe(1_000);
  // Rows 1 apart by 28 px: the band [2800 - 560, 2800 + 1120] meets rows 80 to 139.
  await act(async () => visibleSlice.show({ revision: 1, top: 2_800, height: VIEW }));
  expect(mountedIds().length).toBe(60);
  expect(mountedIds()[0]).toBe("r80");
});
