// The full-height map's marks at any length of chat (ScrollMap.tsx, mapGeometry.ts): it draws as
// many marks at 10,000 rows as at 1,000, since a band of the rail draws one prompt and one reply; a
// streamed reply renders only the marks it moves a px; a layout change reads the marks' rows by
// binary search, not every row; and the arrows still reach each prompt, drawn or not.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
import { geometryFromArrays, type LayoutGeometry } from "../src/agent-session/acpmux/conversationGeometry";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(async () => {
  acpmuxPerf.enabled = false;
  await teardownDom(saved, { window: dom.window, scope });
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ScrollMap } = await import("../src/agent-session/acpmux/threadMinimap/ScrollMap");
const { minimapTurns } = await import("../src/agent-session/acpmux/threadMinimap/model");
const geometry = await import("../src/agent-session/acpmux/threadMinimap/mapGeometry");
const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");
const document = dom.window.document;

/// The rail is 776 px: an 800 px view less MAP_MARGIN above and below.
const VIEW = 800;
const row = (id: string, kind: string, text = id): AcpmuxRow => ({ id, kind, version: 1, at: 0, text });
/// `rows` rows, a prompt then a reply per turn, the replies of three heights.
function chat(rows: number) {
  const list = Array.from({ length: rows }, (_, index) =>
    index % 2 === 0 ? row(`user-${index / 2 + 1}`, "user", `Question ${index / 2}`) : row(`a${index}`, "assistant"),
  );
  return {
    rows: list,
    layout: layoutOf(Array.from(list, (_, index) => (index % 2 === 0 ? 80 : [200, 480, 1200][index % 3]!))),
  };
}
function layoutOf(sizes: number[]): ConversationLayout {
  const heights = Float64Array.from(sizes);
  const tops = new Float64Array(heights.length);
  for (let index = 1; index < heights.length; index += 1) tops[index] = tops[index - 1]! + heights[index - 1]!;
  return { tops, heights, totalHeight: tops.at(-1)! + heights.at(-1)! } as ConversationLayout;
}

type Props = Parameters<typeof ScrollMap>[0];
async function mount(rows: readonly AcpmuxRow[], layout: ConversationLayout) {
  const host = document.getElementById("root")!;
  host.replaceChildren();
  const pane = document.createElement("div");
  const scroller = document.createElement("div");
  host.append(pane, scroller);
  const root = createRoot(pane);
  const props = (next: Partial<Props>): Props => ({
    rows,
    turns: minimapTurns(rows).turns,
    layout,
    scroller: { current: scroller },
    viewportHeight: VIEW,
    scrolls: true,
    placement: { left: 0, width: 120, overlapsText: false, gutter: 0, reserve: 0 },
    marks: { has: () => false, can: () => false, toggle: () => {} } as unknown as Props["marks"],
    jump: () => undefined,
    ...next,
  });
  let current = props({});
  await act(async () => root.render(<ScrollMap {...current} />));
  const nav = () => pane.querySelector<HTMLElement>(".acpmux-scrollmap")!;
  return {
    nav,
    marks: () => nav().querySelectorAll(".acpmux-scrollmap__mark").length,
    nodes: () => nav().querySelectorAll("*").length,
    current: () => current,
    update: async (next: Partial<Props>) => {
      current = props({ ...current, ...next });
      await act(async () => root.render(<ScrollMap {...current} />));
    },
    unmount: () => act(async () => root.unmount()),
  };
}

const rendersOf = () => acpmuxPerf.renders.get("ScrollMap.Mark") ?? 0;

test("the map mounts as many marks and nodes at 10,000 rows as at 1,000", async () => {
  const counts: Record<number, { marks: number; nodes: number }> = {};
  for (const size of [1_000, 10_000]) {
    const { rows, layout } = chat(size);
    const map = await mount(rows, layout);
    counts[size] = { marks: map.marks(), nodes: map.nodes() };
    await map.unmount();
  }
  console.log("mounted", JSON.stringify(counts));
  // One prompt and one reply per 3 px band of the 776 px rail, at most.
  expect(counts[10_000]!.marks).toBeLessThanOrEqual(2 * (Math.ceil(776 / 3) + 1));
  expect(Math.abs(counts[10_000]!.marks - counts[1_000]!.marks)).toBeLessThanOrEqual(0.1 * counts[1_000]!.marks);
  expect(Math.abs(counts[10_000]!.nodes - counts[1_000]!.nodes)).toBeLessThanOrEqual(0.1 * counts[1_000]!.nodes);
});

test("a streamed reply renders only the marks it moves; a scroll step and a hover render none it leaves", async () => {
  const { rows, layout } = chat(10_000);
  const map = await mount(rows, layout);
  acpmuxPerf.enabled = true;
  try {
    // Every mark drawn rendered once as it mounted (the counter sees each mark).
    acpmuxPerf.resetRenders();
    await map.update({ rows: [...rows] });
    const mounted = map.marks();
    expect(mounted).toBeGreaterThan(0);

    // A token on the last reply: its row is new, and the layout's last row is 24 px taller.
    const before = geometry.mapMarks(map.current().rows, map.current().turns, layout, 776);
    const last = rows.length - 1;
    const grown = [...map.current().rows];
    grown[last] = { ...grown[last]!, text: `${grown[last]!.text} more`, version: 2 };
    const sizes = Array.from(layout.heights);
    sizes[last] = sizes[last]! + 24;
    const taller = layoutOf(sizes);
    const after = geometry.mapMarks(grown, minimapTurns(grown).turns, taller, 776);
    const was = new Map(before.map((mark) => [mark.row, mark]));
    const moved = after.filter((mark) => {
      const old = was.get(mark.row);
      return !old || old.y !== mark.y || old.turn !== mark.turn;
    }).length;
    acpmuxPerf.resetRenders();
    await map.update({
      rows: grown,
      turns: minimapTurns(grown).turns,
      layout: taller,
      change: { base: map.current().rows, rows: grown, from: last },
    });
    const streamed = rendersOf();
    console.log("streamed token", JSON.stringify({ mounted, moved, renders: streamed }));
    expect(streamed).toBeLessThanOrEqual(moved);

    // A scroll of 2 px mid-chat moves the bar by a fraction of a px: no mark changes, none renders.
    const scroller = map.current().scroller.current!;
    const scroll = (top: number) =>
      act(async () => {
        scroller.scrollTop = top;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      });
    await scroll(1_000_000);
    acpmuxPerf.resetRenders();
    await scroll(1_000_002);
    expect(rendersOf()).toBe(0);

    // A pointer on the rail grows the marks within the fisheye's reach and renders no other.
    const nav = map.nav();
    nav.getBoundingClientRect = () => ({ top: 0, left: 0, bottom: 776, right: 36, width: 36, height: 776 }) as DOMRect;
    const at = after[Math.floor(after.length / 2)]!.y;
    const reach = after.filter((mark) => Math.abs(mark.y - at) <= 36).length;
    acpmuxPerf.resetRenders();
    await act(
      async () => void nav.dispatchEvent(new dom.window.MouseEvent("pointermove", { clientY: at, bubbles: true })),
    );
    console.log("hover", JSON.stringify({ reach, renders: rendersOf() }));
    expect(rendersOf()).toBeGreaterThan(0);
    // (and the prompt pointed at, which draws on its own, lit, while its band draws another).
    expect(rendersOf()).toBeLessThanOrEqual(reach + 1);
  } finally {
    acpmuxPerf.enabled = false;
    await map.unmount();
  }
});

test("the counter sees each mark mount (it counts on this tree)", async () => {
  const { rows, layout } = chat(1_000);
  acpmuxPerf.enabled = true;
  acpmuxPerf.resetRenders();
  try {
    const map = await mount(rows, layout);
    // Each mark rendered as it mounted; those under the view bar again as they took its tone.
    expect(rendersOf()).toBeGreaterThanOrEqual(map.marks());
    await map.unmount();
  } finally {
    acpmuxPerf.enabled = false;
  }
});

/// What a layout change reads: rows (a read of `rows[i]` or of a row's place on the layout), and
/// binary searches of the layout (each one descent of its index).
function visitsFor(size: number): { rows: number; searches: number } {
  const { rows, layout } = chat(size);
  const turns = minimapTurns(rows).turns;
  let visits = 0;
  let searches = 0;
  const counted = new Proxy(rows, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) visits += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  // The marks' rows index is built once per rows snapshot, not per layout (the next test).
  const index = (geometry as { mapRows?: (rows: readonly AcpmuxRow[]) => unknown }).mapRows?.(counted);
  visits = 0;
  const base = geometryFromArrays(layout.tops, layout.heights, layout.totalHeight);
  const places: LayoutGeometry = {
    ...base,
    topAt: (at) => ((visits += 1), base.topAt(at)),
    upperBoundTop: (target) => ((searches += 1), base.upperBoundTop(target)),
    scan: (from, to, visit) => base.scan(from, to, (at, top, height) => ((visits += 1), visit(at, top, height))),
  };
  // The layout changes (a row was measured): the rows are the same snapshot, so its index holds.
  const marks = geometry.mapMarks(
    counted,
    turns,
    { geometry: places, totalHeight: layout.totalHeight },
    776,
    index as never,
  );
  expect(marks.length).toBeGreaterThan(0);
  expect(searches).toBeLessThanOrEqual(marks.length);
  return { rows: visits, searches };
}

test("a layout change reads as many rows at 100,000 rows as at 1,000, far fewer than all", () => {
  const counts = { 1000: visitsFor(1_000), 10000: visitsFor(10_000), 100000: visitsFor(100_000) };
  console.log("visits per layout change", JSON.stringify(counts));
  expect(counts[100000].rows).toBeLessThan(100_000 / 20);
  expect(counts[100000].rows).toBeLessThanOrEqual(1.2 * counts[1000].rows);
  expect(counts[10000].rows).toBeLessThanOrEqual(1.2 * counts[1000].rows);
});

test("a streamed token reads only the rows from where they changed into the marks' rows index", () => {
  const { rows } = chat(10_000);
  const mapRows = (geometry as { mapRows?: typeof geometry.mapRows }).mapRows;
  expect(typeof mapRows).toBe("function");
  const first = mapRows!(rows);
  const grown = [...rows];
  grown[rows.length - 1] = { ...grown.at(-1)!, text: "more", version: 2 };
  let reads = 0;
  const counted = new Proxy(grown, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  const next = mapRows!(counted, first, { base: rows, rows: counted, from: rows.length - 1 });
  expect(reads).toBeLessThanOrEqual(2);
  expect(next.users).toBe(5_000);
  expect(next.agents).toBe(5_000);
  // And it agrees with an index built from nothing.
  const fresh = mapRows!(grown);
  expect(next.lists.users.slice(0, next.users)).toEqual(fresh.lists.users.slice(0, fresh.users));
  expect(next.lists.agents.slice(0, next.agents)).toEqual(fresh.lists.agents.slice(0, fresh.agents));
});

test("on a dense map the arrows still walk every prompt, drawn or not", async () => {
  const { rows, layout } = chat(10_000);
  const map = await mount(rows, layout);
  const tick = (turn: number) => map.nav().querySelector<HTMLElement>(`[data-tick="${turn}"]`);
  // Prompt 2 shares its band with prompt 1, so it is not drawn until the arrows reach it.
  expect(tick(1)).toBeNull();
  await act(async () => tick(0)!.focus());
  for (let turn = 0; turn < 5; turn += 1) {
    expect((document.activeElement as HTMLElement | null)?.dataset.tick).toBe(String(turn));
    await act(
      async () =>
        void document.activeElement!.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
        ),
    );
  }
  await act(
    async () =>
      void document.activeElement!.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "End", bubbles: true }),
      ),
  );
  expect((document.activeElement as HTMLElement | null)?.dataset.tick).toBe(String(5_000 - 1));
  // Still as many marks as the bands, with the focused one.
  expect(map.marks()).toBeLessThanOrEqual(2 * (Math.ceil(776 / 3) + 1) + 1);
  await map.unmount();
});

/// Each prompt's own place on a 776 px rail (unrounded), by its row.
function promptPlaces(rows: readonly AcpmuxRow[], layout: ConversationLayout) {
  const places: Array<{ row: number; turn: number; y: number }> = [];
  for (let at = 0; at < rows.length; at += 1)
    if (rows[at]!.kind === "user")
      places.push({ row: at, turn: places.length, y: geometry.mapY(layout.tops[at]!, layout.totalHeight, 776) });
  return places;
}
const nearest = (places: ReturnType<typeof promptPlaces>, y: number) =>
  places.reduce((best, place) => (Math.abs(place.y - y) < Math.abs(best.y - y) ? place : best));

test("a point on the rail finds the prompt nearest it, drawn or not", () => {
  const { rows, layout } = chat(10_000);
  const turns = minimapTurns(rows).turns;
  const places = promptPlaces(rows, layout);
  const index = geometry.mapRows(rows);
  for (let y = 0; y <= 776; y += 0.37) {
    const found = geometry.promptAt(index, turns, layout, 776, y)!;
    const want = nearest(places, y);
    expect(found.distance).toBeCloseTo(Math.abs(want.y - y), 6);
    expect(turns[found.turn]!.index).toBe(found.row);
  }
});

test("hovering or clicking a merged mark points at the prompt nearest the pointer, not the band's first", async () => {
  const { rows, layout } = chat(10_000);
  const places = promptPlaces(rows, layout);
  const jumps: number[] = [];
  const map = await mount(rows, layout);
  await map.update({ jump: (turn) => (jumps.push(turn), undefined) });
  const drawn = new Set(
    [...map.nav().querySelectorAll<HTMLElement>('[data-kind="user"]')].map((node) => Number(node.dataset.tick)),
  );
  // Prompts mid-chat that their band does not draw, and a point right on each.
  const hidden = places.filter((place) => !drawn.has(place.turn) && place.turn % 97 === 0).slice(0, 8);
  expect(hidden.length).toBeGreaterThan(4);
  for (const place of hidden) {
    const want = nearest(places, place.y);
    await act(
      async () =>
        void map.nav().dispatchEvent(new dom.window.MouseEvent("pointermove", { clientY: place.y, bubbles: true })),
    );
    const lit = map.nav().querySelector<HTMLElement>('.acpmux-scrollmap__mark[data-tone="active"]');
    expect(lit?.dataset.tick).toBe(String(want.turn));
    await act(async () => {
      map.nav().dispatchEvent(new dom.window.MouseEvent("pointerdown", { clientY: place.y, button: 0, bubbles: true }));
      map.nav().dispatchEvent(new dom.window.MouseEvent("pointerup", { clientY: place.y, button: 0, bubbles: true }));
    });
    expect(jumps.at(-1)).toBe(want.turn);
  }
  await map.unmount();
});

test("each drawn prompt names its place among all of them, and the focused one is drawn", async () => {
  const { rows, layout } = chat(10_000);
  const map = await mount(rows, layout);
  const list = map.nav().querySelector("ol")!;
  const items = () => [...list.querySelectorAll<HTMLElement>("li:not([aria-hidden])")];
  const check = () => {
    let last = 0;
    for (const item of items()) {
      expect(item.getAttribute("aria-setsize")).toBe("5000");
      const tick = item.querySelector<HTMLElement>("[data-tick]")!;
      const place = Number(item.getAttribute("aria-posinset"));
      expect(place).toBe(Number(tick.dataset.tick) + 1);
      expect(tick.getAttribute("aria-label")).toContain(`${place}`);
      // Top to bottom is first to last, as a reader hears them.
      expect(place).toBeGreaterThan(last);
      last = place;
    }
  };
  check();
  expect(items().length).toBeLessThan(300);
  // The replies' marks are drawn only: no item of the list.
  for (const reply of list.querySelectorAll('[data-kind="agent"]'))
    expect(reply.closest("li")?.getAttribute("aria-hidden")).toBe("true");
  const first = items()[0]!.querySelector<HTMLElement>("button")!;
  await act(async () => first.focus());
  await act(
    async () =>
      void document.activeElement!.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
      ),
  );
  const focused = document.activeElement as HTMLElement;
  expect(focused.dataset.tick).toBe("1");
  expect(focused.closest("li")?.getAttribute("aria-posinset")).toBe("2");
  // It stays drawn while focused, through a layout change that moves every band.
  const sizes = Array.from(layout.heights);
  sizes[3] = sizes[3]! + 5_000;
  await map.update({ layout: layoutOf(sizes) });
  expect(map.nav().contains(document.activeElement)).toBe(true);
  expect((document.activeElement as HTMLElement).dataset.tick).toBe("1");
  check();
  await map.unmount();
});
