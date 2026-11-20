// The sidebar's chat history page hears the part of it on screen from the page's generic stream
// (`cmux.page.visibleSlice`, subscribed per surface: {surface, revision, top, height}) and still from the old
// `cmux.sidebarChats.slice`, so it windows its rows against a host that sends either. Once a generic slice arrives
// for a surface, old-wire slices for it are ignored; a slice windows only the block revision it names.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Event",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let view: Window & typeof globalThis;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  view = window as unknown as Window & typeof globalThis;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const { mountSidebarChats } = await import("../src/pages/sidebar-chats/mount");
const { blockHeight } = await import("../src/pages/sidebar-chats/model");
const { pageError } = await import("../src/pages/shared/pageClient");
const { FIXTURE_METRICS, FIXTURE_STRINGS, fixtureBlock, fixtureRows } =
  await import("../src/pages/sidebar-chats/fixtures");
type Block = ReturnType<typeof fixtureBlock>;

// The wire names, spelled out: a page without the slice stream never subscribes to it.
const BLOCK = "cmux.sidebarChats.block";
const SLICE = "cmux.sidebarChats.slice";
const VISIBLE = "cmux.page.visibleSlice";
const STRIDE = FIXTURE_METRICS.row + FIXTURE_METRICS.spacing;

const mounted: Array<{ unmount(): void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  view.document.body.replaceChildren();
});

type Wire = "visible" | "old" | "both";

/** Mounts the page on a host that admits `wire`: the generic stream, the old one, or both. A stream it does not
 * admit is refused with `unknown_op`, as the native router refuses one its descriptor does not list. */
async function mount(wire: Wire) {
  const host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  const streams = new Map<string, (data: unknown) => void>();
  const subscribed: string[] = [];
  const admits = (stream: string) =>
    stream === BLOCK || (stream === VISIBLE ? wire !== "old" : stream === SLICE ? wire !== "visible" : false);
  const client = {
    call: () => Promise.resolve(undefined),
    subscribe: async (stream: string, onEvent: (data: unknown) => void, filter?: Record<string, unknown>) => {
      if (!admits(stream)) throw pageError("cmux.protocol.unknown_op", stream);
      const key = filter?.surface ? `${stream} ${String(filter.surface)}` : stream;
      subscribed.push(key);
      streams.set(key, onEvent);
      return () => streams.delete(key);
    },
    handle: () => () => {},
  };
  let chats!: ReturnType<typeof mountSidebarChats>;
  await act(async () => {
    chats = mountSidebarChats(host, client as never, FIXTURE_STRINGS, { nextFrame: () => () => {} });
  });
  mounted.push(chats);
  // As off the wire: every event is new objects. The generic stream reaches only its surface's subscriber.
  const emit = (key: string, data: unknown) =>
    act(async () => streams.get(key)?.(JSON.parse(JSON.stringify(data)) as unknown));
  const rows = () => [...host.querySelectorAll<HTMLElement>(".sc-row[data-chat]")];
  return {
    host,
    subscribed,
    block: (block: Block) => emit(BLOCK, block),
    oldSlice: (slice: { revision: number; top: number; height: number }) => emit(SLICE, slice),
    visible: (surface: string, slice: { revision: number; top: number; height: number }) =>
      emit(`${VISIBLE} ${surface}`, { surface, ...slice }),
    rows,
    ids: () => rows().map((row) => row.dataset.chat),
    renders: mountedRowRenders(rows),
  };
}

/** The rows a slice must mount, from the geometry alone: row i spans [header + i * stride, + stride). */
function expected(count: number, top: number, height: number): string[] {
  const ids: string[] = [];
  if (height <= 0) return ids;
  for (let index = 0; index < count; index++) {
    const start = FIXTURE_METRICS.header + index * STRIDE;
    if (start < top + 2 * height && start + STRIDE > top - height) ids.push(`chat-${index}`);
  }
  return ids;
}

test("a host with only cmux.page.visibleSlice: each block is windowed by its own surface's slices", async () => {
  for (const part of ["pinned", "earlier"] as const) {
    const counts: number[] = [];
    for (const count of [1_000, 10_000]) {
      const page = await mount("visible");
      expect(page.subscribed).toEqual([BLOCK, `${VISIBLE} sidebar-chats:pinned`, `${VISIBLE} sidebar-chats:earlier`]);
      await page.block(fixtureBlock({ revision: 1, part, rows: fixtureRows(count) }));
      expect(page.rows().length).toBe(count);
      await page.visible(`sidebar-chats:${part}`, { revision: 1, top: 3_000, height: 300 });
      expect(page.ids()).toEqual(expected(count, 3_000, 300));
      counts.push(page.rows().length);
      // A scroll step mounts only the row entering; the rows that stay draw 0 times.
      const before = page.ids();
      page.renders.mark();
      await page.visible(`sidebar-chats:${part}`, { revision: 1, top: 3_000 + STRIDE, height: 300 });
      expect(page.ids()).toEqual(expected(count, 3_000 + STRIDE, 300));
      expect(page.renders.since()).toBe(page.ids().filter((id) => !before.includes(id)).length);
      // The other block's surface windows nothing here.
      const other = part === "pinned" ? "earlier" : "pinned";
      await page.visible(`sidebar-chats:${other}`, { revision: 1, top: 0, height: 0 });
      expect(page.ids()).toEqual(expected(count, 3_000 + STRIDE, 300));
      // A block push re-sends at the new revision; an older revision's slice changes nothing.
      await page.block(fixtureBlock({ revision: 2, part, rows: fixtureRows(count) }));
      await page.visible(`sidebar-chats:${part}`, { revision: 1, top: 9_000, height: 300 });
      expect(page.ids()).toEqual(expected(count, 3_000 + STRIDE, 300));
      await page.visible(`sidebar-chats:${part}`, { revision: 2, top: 6_000, height: 300 });
      expect(page.ids()).toEqual(expected(count, 6_000, 300));
      await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
    }
    expect(counts[0]).toBe(counts[1]!);
    expect(counts[0]).toBeLessThan(40);
  }
});

test("a generic slice sent before its block windows it once drawn; one naming another revision does not", async () => {
  const page = await mount("visible");
  await page.visible("sidebar-chats:earlier", { revision: 1, top: 3_000, height: 300 });
  await page.block(fixtureBlock({ revision: 1, part: "earlier", rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  // Sent ahead for the other surface: it does not window this block.
  const other = await mount("visible");
  await other.visible("sidebar-chats:pinned", { revision: 1, top: 3_000, height: 300 });
  await other.block(fixtureBlock({ revision: 1, part: "earlier", rows: fixtureRows(1_000) }));
  expect(other.rows().length).toBe(1_000);
});

// The page hears both surfaces until its first block names its part, so a slice for the other surface can
// arrive between its own slice and its block; it must not lose its own.
test("before the first block: a pinned slice then an earlier one, then the pinned block windows by the pinned", async () => {
  const page = await mount("visible");
  await page.visible("sidebar-chats:pinned", { revision: 1, top: 3_000, height: 300 });
  await page.visible("sidebar-chats:earlier", { revision: 1, top: 6_000, height: 300 });
  await page.block(fixtureBlock({ revision: 1, part: "pinned", rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
});

test("before the first block: an earlier slice then a pinned one, then the earlier block windows by the earlier", async () => {
  const page = await mount("visible");
  await page.visible("sidebar-chats:earlier", { revision: 1, top: 6_000, height: 300 });
  await page.visible("sidebar-chats:pinned", { revision: 1, top: 3_000, height: 300 });
  await page.block(fixtureBlock({ revision: 1, part: "earlier", rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 6_000, 300));
});

test("before the first block: an old-wire slice and a generic one for the other surface each window their block", async () => {
  // Each block is its own page and both hear the same events: the old wire's slice (no surface) and a generic
  // slice for earlier. The pinned page has no generic slice, so the old wire windows it; earlier takes its own.
  for (const part of ["pinned", "earlier"] as const) {
    const page = await mount("both");
    await page.oldSlice({ revision: 1, top: 3_000, height: 300 });
    await page.visible("sidebar-chats:earlier", { revision: 1, top: 6_000, height: 300 });
    await page.block(fixtureBlock({ revision: 1, part, rows: fixtureRows(1_000) }));
    expect(page.ids()).toEqual(expected(1_000, part === "pinned" ? 3_000 : 6_000, 300));
    await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  }
});

test("a host with only cmux.sidebarChats.slice: the old wire windows the rows as before", async () => {
  const page = await mount("old");
  expect(page.subscribed).toEqual([BLOCK, SLICE]);
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  expect(page.rows().length).toBe(1_000);
  await page.oldSlice({ revision: 1, top: 3_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  // It holds across a block until the next; an older revision's slice changes nothing; height 0 mounts none.
  await page.block(fixtureBlock({ revision: 2, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  await page.oldSlice({ revision: 1, top: 9_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  await page.oldSlice({ revision: 2, top: 0, height: 0 });
  expect(page.rows().length).toBe(0);
});

test("both wires: once a generic slice arrives for the block's surface, old-wire slices are ignored", async () => {
  const page = await mount("both");
  await page.block(fixtureBlock({ revision: 1, part: "earlier", rows: fixtureRows(1_000) }));
  // Before any generic slice the old wire windows the rows.
  await page.oldSlice({ revision: 1, top: 1_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 1_000, 300));
  // A generic slice for the other surface leaves the old wire in charge here.
  await page.visible("sidebar-chats:pinned", { revision: 1, top: 0, height: 0 });
  await page.oldSlice({ revision: 1, top: 2_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 2_000, 300));
  await page.visible("sidebar-chats:earlier", { revision: 1, top: 3_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  await page.oldSlice({ revision: 1, top: 9_000, height: 300 });
  await page.block(fixtureBlock({ revision: 2, part: "earlier", rows: fixtureRows(1_000) }));
  await page.oldSlice({ revision: 2, top: 9_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  await page.visible("sidebar-chats:earlier", { revision: 2, top: 6_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 6_000, 300));
});

test("both wires before the first block: the generic slice held for it wins over the old wire's", async () => {
  const page = await mount("both");
  await page.oldSlice({ revision: 1, top: 9_000, height: 300 });
  await page.visible("sidebar-chats:earlier", { revision: 1, top: 3_000, height: 300 });
  await page.oldSlice({ revision: 1, top: 9_000, height: 300 });
  await page.block(fixtureBlock({ revision: 1, part: "earlier", rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
});

test("a generic slice of height 0 (scrolled out) mounts no row; the block keeps its height", async () => {
  const block = fixtureBlock({ revision: 1, rows: fixtureRows(1_000) });
  const page = await mount("visible");
  await page.block(block);
  await page.visible(`sidebar-chats:${block.part}`, { revision: 1, top: 0, height: 0 });
  expect(page.rows().length).toBe(0);
  expect((page.host.querySelector(".sc-block") as HTMLElement).style.height).toBe(`${blockHeight(block)}px`);
  expect(page.host.querySelector(".sc-header")).not.toBeNull();
  expect(page.host.querySelector(".sc-tail")).not.toBeNull();
});
