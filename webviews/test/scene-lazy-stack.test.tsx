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
import { until } from "./support/until";
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
  // An open context menu's anchor is fixed (scene.css): out of the column's flow.
  const css = dom.window.document.createElement("style");
  css.textContent = ".cmux-app-scene-context-anchor { position: fixed; }";
  dom.window.document.head.append(css);
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
const { VisibleSliceInput } = await import("../src/ui/visibleSlice");
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

/** The stack's laid-out height as a flex column draws it: each flex item (a row or a spacer; a Group's,
 * ForEach's or context menu's `display: contents` wrapper gives its children) and the gaps between. */
function stackHeight(spacing: number): number {
  const stack = document.querySelector<HTMLElement>("[data-app-type=LazyVStack]")!;
  const items: HTMLElement[] = [];
  const walk = (parent: Element) => {
    for (const child of parent.children as HTMLCollectionOf<HTMLElement>) {
      // A hidden or out-of-flow (fixed, absolute) element is no flex item (no gap).
      if (child.hidden) continue;
      const position = getComputedStyle(child).position;
      if (position === "fixed" || position === "absolute") continue;
      if (child.matches(".cmux-app-scene-group, .cmux-app-scene-foreach, .cmux-app-scene-context")) walk(child);
      else items.push(child);
    }
  };
  walk(stack);
  return items.reduce((sum, child) => sum + sizes(child), 0) + Math.max(0, items.length - 1) * spacing;
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

test("a windowed stack keeps scene motion: a scroll enters nothing, an added row enters, a removed row leaves", async () => {
  const store = new SceneStore();
  const rows = Array.from({ length: 1_000 }, (_, index) => `r${index}`);
  const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: {} }];
  for (const id of rows) ops.push({ op: "create", id, type: "Row", props: { title: id, transition: "slide" } });
  ops.push({ op: "create", id: "each", type: "ForEach" }, { op: "children", id: "each", children: rows });
  ops.push({ op: "children", id: "list", children: ["each"] }, { op: "root", id: "list" });
  store.apply(ops, true);
  const scroller = await inScroller(store);
  const entering = () => document.querySelectorAll("[data-app-type=Row][data-entering]").length;
  // The first scene draws in place, and rows a scroll brings into the window draw in place too.
  expect(entering()).toBe(0);
  await scrollTo(scroller, 300 * ROW);
  expect(mountedIds()[0]).toBe("r280");
  expect(entering()).toBe(0);

  // A row a render adds in the window enters; the rest stay.
  await act(async () =>
    store.apply([
      { op: "create", id: "new", type: "Row", props: { title: "new", transition: "slide" } },
      { op: "children", id: "each", children: [...rows.slice(0, 305), "new", ...rows.slice(305)] },
    ]),
  );
  expect(document.querySelector('[data-app-node="new"]')!.hasAttribute("data-entering")).toBe(true);
  expect(entering()).toBe(1);

  // A removed row keeps its place, from its last props, while it leaves.
  await act(async () =>
    store.apply([
      { op: "children", id: "each", children: [...rows.slice(0, 305), "new", ...rows.slice(306)] },
      { op: "remove", id: "r305" },
    ]),
  );
  const leaving = document.querySelector<HTMLElement>('[data-app-node="r305"]')!;
  expect(leaving.hasAttribute("data-leaving")).toBe(true);
  expect(mountedIds().indexOf("r305")).toBe(mountedIds().indexOf("new") + 1);
  // Until its leave ends: each turn yields to the leave's timer and flushes the render it causes.
  await until(
    () => document.querySelector('[data-app-node="r305"]') === null,
    () => act(() => new Promise<void>((resolve) => setTimeout(resolve, 0))),
  );
  // A later scroll still enters nothing.
  await scrollTo(scroller, 400 * ROW);
  expect(entering()).toBe(0);
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
  // The scene drawn is revision 1, as the panels client reads it from the scene batch.
  visibleSlice.setDrawn(1);
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
  await act(async () => visibleSlice.show({ revision: 1, top: 0, height: VIEW }));
  expect(mountedIds()).toEqual(Array.from({ length: 35 }, (_, index) => `r${index}`));
  expect(stackHeight(spacing)).toBe(whole);

  // Scrolled out: nothing mounts, one spacer keeps the height.
  await act(async () => visibleSlice.show({ revision: 1, top: 0, height: 0 }));
  expect(mountedIds().length).toBe(0);
  expect(stackHeight(spacing)).toBe(whole);

  // The next scene batch is revision 2: a slice measured against revision 1 is dropped.
  await act(async () => {
    store.apply([{ op: "update", id: "r3", props: { title: "Changed" } }]);
    visibleSlice.setDrawn(2);
  });
  await act(async () => visibleSlice.show({ revision: 1, top: 3_400, height: VIEW }));
  expect(mountedIds().length).toBe(0);
  await act(async () => visibleSlice.show({ revision: 2, top: 3_400, height: VIEW }));
  expect(mountedIds()[0]).toBe("r88");
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

test("in a panel, a slice that arrives before the first scene windows it only when the revisions match", async () => {
  const store = new SceneStore();
  const visibleSlice = new VisibleSliceInput();
  // Sent before any scene is drawn: for revision 2, while the first batch (revision 1) is on its way.
  visibleSlice.show({ revision: 2, top: 2_800, height: VIEW });
  const container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  const mounted = {
    panel: { app: "local/test", section: "list", title: "List" },
    store,
    dispatch: () => {},
    reload: () => {},
    layout: () => {},
    resolveAsset: () => undefined,
    visibleSlice,
  };
  await act(async () => root!.render(<SceneMount mounted={mounted} />));
  const full = lazyScene(1_000);
  const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: {} }];
  for (const id of full.getNode("list")!.children)
    ops.push({ op: "create", id, type: "Row", props: { title: `Row ${id}` } });
  ops.push({ op: "children", id: "list", children: full.getNode("list")!.children }, { op: "root", id: "list" });
  await act(async () => {
    store.apply(ops, true);
    visibleSlice.setDrawn(1);
  });
  expect(mountedIds().length).toBe(1_000);
  // The second batch is revision 2: the waiting slice names it, so it applies now.
  await act(async () => {
    store.apply([{ op: "update", id: "r3", props: { title: "Changed" } }]);
    visibleSlice.setDrawn(2);
  });
  expect(mountedIds().length).toBe(60);
  expect(mountedIds()[0]).toBe("r80");
});

test("in a panel, a child focused while the stack draws whole stays mounted and focused when the first slice windows it", async () => {
  const store = lazyScene(1_000);
  store.apply([{ op: "update", id: "r5", props: { title: "Focused", onTap: true } }]);
  const { visibleSlice } = await inPanel(store);
  expect(mountedIds().length).toBe(1_000);
  await act(async () => document.querySelector<HTMLElement>("[data-app-node=r5]")!.focus());
  // The band [3400 - 560, 3400 + 1120] is far below row 5.
  await act(async () => visibleSlice.show({ revision: 1, top: 3_400, height: VIEW }));
  expect(mountedIds()[0]).toBe("r5");
  expect(mountedIds()[1]).toBe("r101");
  expect(document.activeElement?.getAttribute("data-app-node")).toBe("r5");
});

test("in a panel, a styled Group's rows keep their places: offsets, height and the slice's band", async () => {
  // 300 pairs: a Row, then a Group with a background (so not opened inline) of two Rows.
  const spacing = 4;
  const store = new SceneStore();
  const items: string[] = [];
  const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: { spacing } }];
  for (let index = 0; index < 300; index++) {
    const rows = [`g${index}a`, `g${index}b`];
    ops.push({ op: "create", id: `r${index}`, type: "Row", props: { title: `Row ${index}` } });
    for (const id of rows) ops.push({ op: "create", id, type: "Row", props: { title: id } });
    ops.push(
      { op: "create", id: `g${index}`, type: "Group", props: { background: "secondary" } },
      { op: "children", id: `g${index}`, children: rows },
    );
    items.push(`r${index}`, `g${index}`);
  }
  ops.push({ op: "children", id: "list", children: items }, { op: "root", id: "list" });
  store.apply(ops, true);
  const { visibleSlice } = await inPanel(store);
  const whole = stackHeight(spacing);
  // A Row is 28 px; a Group's two Rows and the gap between them, 60.
  expect(whole).toBe(300 * (28 + 60) + 599 * spacing);

  const top = 6_000;
  await act(async () => visibleSlice.show({ revision: 1, top, height: VIEW }));
  // Where the column lays each item out, and the Rows of those that meet [top - 560, top + 1120].
  const expected: string[] = [];
  let firstStart: number | undefined;
  let at = 0;
  for (const id of items) {
    const height = id.startsWith("g") ? 60 : 28;
    if (at + height > top - VIEW && at < top + 2 * VIEW) {
      firstStart ??= at;
      expected.push(...(id.startsWith("g") ? [`${id}a`, `${id}b`] : [id]));
    }
    at += height + spacing;
  }
  expect(mountedIds()).toEqual(expected);
  const lead = document.querySelector<HTMLElement>(".cmux-app-scene-lazy-spacer")!;
  expect(parseFloat(lead.style.height)).toBe(firstStart! - spacing);
  expect(stackHeight(spacing)).toBe(whole);
});

test("in a panel, a slice carried over to a shorter revision mounts the stack's last view, never a blank one", async () => {
  const store = lazyScene(1_000);
  const { visibleSlice } = await inPanel(store);
  await act(async () => visibleSlice.show({ revision: 1, top: 20_000, height: VIEW }));
  expect(mountedIds()[0]).toBe("r694");
  // Revision 2 keeps 200 rows (5600 px), all above the slice's top; the slice holds until the host's next.
  await act(async () => {
    store.apply([{ op: "children", id: "list", children: store.getNode("list")!.children.slice(0, 200) }]);
    visibleSlice.setDrawn(2);
  });
  // The host shows the end, [5040, 5600]: its band [4480, 6720] is rows 160 to 199.
  expect(mountedIds()).toEqual(Array.from({ length: 40 }, (_, index) => `r${160 + index}`));
  expect(stackHeight(0)).toBe(200 * ROW);
});

test("in a panel, an autofocus TextField stays mounted and focused when the first slice windows the stack", async () => {
  // r5 is a TextField with autofocus: it takes focus in its own passive effect, which runs before its stack's.
  const store = lazyScene(1_000);
  store.apply([
    { op: "create", id: "field", type: "TextField", props: { placeholder: "Filter", autofocus: true } },
    {
      op: "children",
      id: "list",
      children: store.getNode("list")!.children.map((id) => (id === "r5" ? "field" : id)),
    },
  ]);
  const { visibleSlice } = await inPanel(store);
  const field = () => document.querySelector<HTMLInputElement>("[data-app-node=field] input");
  expect(document.activeElement).toBe(field()!);
  // The band [3400 - 560, 3400 + 1120] is far below the field.
  await act(async () => visibleSlice.show({ revision: 1, top: 3_400, height: VIEW }));
  expect(field()).not.toBeNull();
  expect(document.activeElement).toBe(field()!);
  // The field (0 px under jsdom) is kept before the band: row i > 5 ends at 28 i, so the band starts at r102.
  const stack = document.querySelector<HTMLElement>("[data-app-type=LazyVStack]")!;
  const order = [...stack.querySelectorAll<HTMLElement>("[data-app-node]")].map((child) => child.dataset.appNode);
  expect(order.slice(0, 2)).toEqual(["field", "r102"]);
});

test("in a panel, an open context menu in a Group moves no row: the Group's height and later offsets hold", async () => {
  // 300 pairs: a Row, then a styled Group of two Rows with a context menu each.
  const spacing = 4;
  const scene = () => {
    const store = new SceneStore();
    const items: string[] = [];
    const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: { spacing } }];
    for (let index = 0; index < 300; index++) {
      const rows = [`g${index}a`, `g${index}b`];
      ops.push({ op: "create", id: `r${index}`, type: "Row", props: { title: `Row ${index}` } });
      for (const id of rows)
        ops.push({ op: "create", id, type: "Row", props: { title: id, menu: [{ title: "Open" }] } });
      ops.push(
        { op: "create", id: `g${index}`, type: "Group", props: { background: "secondary" } },
        { op: "children", id: `g${index}`, children: rows },
      );
      items.push(`r${index}`, `g${index}`);
    }
    ops.push({ op: "children", id: "list", children: items }, { op: "root", id: "list" });
    store.apply(ops, true);
    return store;
  };
  // The lead spacer and the rows a slice mounts, with the menu of an early Group's row open or not.
  const windowed = async (open: boolean) => {
    const { visibleSlice } = await inPanel(scene());
    if (open)
      await act(async () => {
        document
          .querySelector('[data-app-node="g3a"]')!
          .dispatchEvent(
            new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 40 }),
          );
        await Promise.resolve();
      });
    expect(document.querySelector(".cmux-app-scene-context-anchor") !== null).toBe(open);
    const whole = stackHeight(spacing);
    expect(whole).toBe(300 * (28 + 60) + 599 * spacing);
    await act(async () => visibleSlice.show({ revision: 1, top: 6_000, height: VIEW }));
    const lead = document.querySelector<HTMLElement>(".cmux-app-scene-lazy-spacer")!;
    const result = { lead: parseFloat(lead.style.height), ids: mountedIds(), height: stackHeight(spacing) };
    expect(result.height).toBe(whole);
    act(() => root!.unmount());
    root = undefined;
    document.body.replaceChildren();
    return result;
  };
  const closed = await windowed(false);
  const opened = await windowed(true);
  expect(opened).toEqual(closed);
});
