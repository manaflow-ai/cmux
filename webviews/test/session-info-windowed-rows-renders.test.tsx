// Session Info's long lists (WindowedRows.tsx) mount the rows in view and a viewport of overscan each
// side, the same number at 1,000 rows as at 10,000, and remove rows the scroll leaves; a scroll step,
// a change to one item and a parent's render with unchanged data render no row that did not change.
// Tab past the last mounted row and Shift-Tab into the list from below mount the row focus goes to,
// never every row (Leo, 2026-11-18: "we draw the visible area, right? Like, that's what we're supposed
// to do"). Counted from React's commits (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, memo, useState } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

/// The layout jsdom lacks: rows 24 px tall from the scroller's top, a scroller 480 px tall.
const ROW = 24;
const VIEW = 480;
const offsets = new WeakMap<Element, number>();

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get(this: Element) {
      return offsets.get(this) ?? 0;
    },
    set(this: Element, value: number) {
      offsets.set(this, value);
    },
  });
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const box = (top: number, height: number) =>
      ({ top, bottom: top + height, height, left: 0, right: 300, width: 300, x: 0, y: top }) as DOMRect;
    if (this.hasAttribute("data-scroller")) return box(0, VIEW);
    const place = this.getAttribute("data-i");
    if (place !== null) {
      const scroller = this.closest("[data-scroller]")!;
      return box(Number(place) * ROW - (offsets.get(scroller) ?? 0), ROW);
    }
    return box(0, 0);
  };
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Item = { id: string; i: number; label: string };
const itemsOf = (n: number): Item[] => Array.from({ length: n }, (_, i) => ({ id: `r${i}`, i, label: `Row ${i}` }));

const ProbeRow = memo(function ProbeRow({ item, onOpen }: { item: Item; onOpen: (id: string) => void }) {
  return (
    <li data-i={item.i}>
      <button type="button" onClick={() => onOpen(item.id)}>
        {item.label}
      </button>
    </li>
  );
});

const open = (_id: string) => {};

async function mount(n: number) {
  const { WindowedRows } = await import("../src/agent-session/acpmux/session-info/WindowedRows");
  let setItems: (items: Item[]) => void = () => {};
  let bump: () => void = () => {};
  function Host({ first }: { first: Item[] }) {
    const [items, set] = useState(first);
    const [, setTick] = useState(0);
    setItems = set;
    bump = () => setTick((tick) => tick + 1);
    return (
      <div>
        <button type="button" data-before>
          before
        </button>
        <div data-scroller style={{ overflowY: "auto", height: VIEW }}>
          <ul>
            <WindowedRows items={items} render={(item) => <ProbeRow key={item.id} item={item} onOpen={open} />} />
          </ul>
        </div>
        <button type="button" data-after>
          after
        </button>
      </div>
    );
  }
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root: Root = createRoot(host);
  await act(async () => root.render(<Host first={itemsOf(n)} />));
  const scroller = host.querySelector<HTMLElement>("[data-scroller]")!;
  const mounted = () => [...host.querySelectorAll("li[data-i]")].map((row) => Number(row.getAttribute("data-i")));
  const scrollTo = async (top: number) => {
    scroller.scrollTop = top;
    await act(async () => scroller.dispatchEvent(new dom.window.Event("scroll")));
  };
  return {
    host,
    mounted,
    scrollTo,
    setItems: (items: Item[]) => act(async () => setItems(items)),
    bump: () => act(async () => bump()),
    unmount: () => act(async () => root.unmount()).then(() => host.remove()),
  };
}

/// Rows in the 480 px view (20), one viewport of overscan each side (20 + 20), and a row of rounding
/// at each edge.
const BOUND = 3 * (VIEW / ROW) + 2;

test("mounted rows are the same at 1,000 and 10,000 rows, at the top and mid-list", async () => {
  const counts: Record<number, number[]> = {};
  for (const n of [1_000, 10_000]) {
    const list = await mount(n);
    const atTop = list.mounted().length;
    await list.scrollTo(500 * ROW);
    const mid = list.mounted();
    // The window is the rows around the view, not the rows from the top to it.
    expect(Math.min(...mid)).toBeGreaterThan(400);
    expect(Math.max(...mid)).toBeLessThan(600);
    counts[n] = [atTop, mid.length];
    const nodes = list.host.querySelectorAll("*").length;
    console.log(`WINDOWED-ROWS n=${n} mounted top=${atTop} mid=${mid.length} dom-nodes(mid)=${nodes} (jsdom)`);
    await list.unmount();
  }
  expect(counts[1_000]).toEqual(counts[10_000]!);
  expect(counts[10_000]![1]).toBeLessThanOrEqual(BOUND);
});

test("a scroll step renders only the rows it mounts, and removes the rows that leave", async () => {
  const list = await mount(10_000);
  await list.scrollTo(500 * ROW);
  for (let step = 1; step <= 5; step += 1) {
    const before = new Set(list.mounted());
    rowRenders.reset();
    await list.scrollTo((500 + step) * ROW);
    const after = list.mounted();
    const entered = after.filter((i) => !before.has(i)).length;
    const left = [...before].filter((i) => !after.includes(i)).length;
    console.log(
      `WINDOWED-ROWS scroll step ${step}: ProbeRow renders=${rowRenders.count("ProbeRow")} entered=${entered} left=${left}`,
    );
    // Every render is a row that came into the window; the rows that stay render 0 times.
    expect(rowRenders.count("ProbeRow")).toBe(entered);
    expect(entered).toBeGreaterThan(0);
    expect(left).toBe(entered);
    expect(after.length).toBeLessThanOrEqual(BOUND);
  }
  await list.unmount();
});

test("one item's change renders that row only; a parent render with unchanged data renders none", async () => {
  const list = await mount(10_000);
  await list.scrollTo(500 * ROW);
  const items = itemsOf(10_000);
  await list.setItems(items);
  rowRenders.reset();
  const changed = items.slice();
  changed[505] = { ...changed[505]!, label: "Row 505, renamed" };
  await list.setItems(changed);
  console.log(`WINDOWED-ROWS one-item change: ProbeRow renders=${rowRenders.count("ProbeRow")}`);
  expect(rowRenders.count("ProbeRow")).toBe(1);
  rowRenders.reset();
  await list.bump();
  console.log(`WINDOWED-ROWS parent render, same data: ProbeRow renders=${rowRenders.count("ProbeRow")}`);
  expect(rowRenders.count("ProbeRow")).toBe(0);
  await list.unmount();
});

test("rows carry their place in the whole list for a screen reader", async () => {
  const list = await mount(10_000);
  await list.scrollTo(500 * ROW);
  const row = list.host.querySelector('li[data-i="500"]')!;
  expect(row.getAttribute("aria-posinset")).toBe("501");
  expect(row.getAttribute("aria-setsize")).toBe("10000");
  // The rows above and under the window are held as room, hidden from a screen reader.
  for (const box of list.host.querySelectorAll("li[data-rows-rest]"))
    expect(box.getAttribute("aria-hidden")).toBe("true");
  await list.unmount();
});

test("Tab from the last mounted row mounts and focuses the next; the focused row stays mounted", async () => {
  const list = await mount(10_000);
  const last = Math.max(...list.mounted());
  const button = list.host.querySelector<HTMLElement>(`li[data-i="${last}"] button`)!;
  await act(async () => button.focus());
  const press = new dom.window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  await act(async () => button.dispatchEvent(press));
  expect(press.defaultPrevented).toBe(true);
  expect(dom.window.document.activeElement?.closest("li")?.getAttribute("data-i")).toBe(String(last + 1));
  // The focused row stays mounted when the scroll goes far from it.
  await list.scrollTo(5_000 * ROW);
  expect(list.mounted()).toContain(last + 1);
  expect(list.mounted().length).toBeLessThanOrEqual(BOUND + 1);
  await list.unmount();
});

test("Shift-Tab into the list from below lands on its true last row without mounting every row", async () => {
  const list = await mount(10_000);
  const after = list.host.querySelector<HTMLElement>("[data-after]")!;
  await act(async () => after.focus());
  // The browser's Shift-Tab moves focus to the last focusable before the button: the last mounted row.
  const lastMounted = Math.max(...list.mounted());
  await act(async () => list.host.querySelector<HTMLElement>(`li[data-i="${lastMounted}"] button`)!.focus());
  expect(dom.window.document.activeElement?.closest("li")?.getAttribute("data-i")).toBe("9999");
  console.log(`WINDOWED-ROWS shift-tab from below: mounted=${list.mounted().length}`);
  expect(list.mounted().length).toBeLessThanOrEqual(BOUND + 1);
  await list.unmount();
});

test("a list that is itself the scroller moves its window with its own scroll", async () => {
  const { WindowedRows } = await import("../src/agent-session/acpmux/session-info/WindowedRows");
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const items = itemsOf(10_000);
  await act(async () =>
    root.render(
      <ul data-scroller style={{ overflowY: "auto", height: VIEW }}>
        <WindowedRows items={items} render={(item) => <ProbeRow key={item.id} item={item} onOpen={open} />} />
      </ul>,
    ),
  );
  const list = host.querySelector<HTMLElement>("ul")!;
  list.scrollTop = 5_000 * ROW;
  await act(async () => list.dispatchEvent(new dom.window.Event("scroll")));
  const mounted = [...host.querySelectorAll("li[data-i]")].map((row) => Number(row.getAttribute("data-i")));
  console.log(
    `WINDOWED-ROWS list is its own scroller: mounted=${mounted.length} range=${Math.min(...mounted)}..${Math.max(...mounted)}`,
  );
  expect(mounted).toContain(5_000);
  expect(mounted.length).toBeLessThanOrEqual(BOUND);
  await act(async () => root.unmount());
  host.remove();
});

test("Tab from a row before the windowed rows in the same list lands on their true first row", async () => {
  const { WindowedRows } = await import("../src/agent-session/acpmux/session-info/WindowedRows");
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const items = itemsOf(10_000);
  await act(async () =>
    root.render(
      <div data-scroller style={{ overflowY: "auto", height: VIEW }}>
        <ul>
          <li data-before>
            <button type="button">before</button>
          </li>
          <WindowedRows items={items} render={(item) => <ProbeRow key={item.id} item={item} onOpen={open} />} />
        </ul>
      </div>,
    ),
  );
  const scroller = host.querySelector<HTMLElement>("[data-scroller]")!;
  scroller.scrollTop = 5_000 * ROW;
  await act(async () => scroller.dispatchEvent(new dom.window.Event("scroll")));
  const before = host.querySelector<HTMLElement>("li[data-before] button")!;
  const firstMounted = host.querySelector<HTMLElement>("li[data-rows-rest] + li[data-i] button")!;
  expect(Number(firstMounted.closest("li")!.getAttribute("data-i"))).toBeGreaterThan(1_000);
  // The browser's Tab from the row before: focus moves to the first mounted row, from inside the list.
  await act(async () => {
    firstMounted.focus();
    firstMounted.dispatchEvent(new dom.window.FocusEvent("focusin", { bubbles: true, relatedTarget: before }));
  });
  const landed = dom.window.document.activeElement?.closest("li")?.getAttribute("data-i");
  console.log(`WINDOWED-ROWS Tab from a row before, same list: landed on row ${landed}`);
  expect(landed).toBe("0");
  await act(async () => root.unmount());
  host.remove();
});
