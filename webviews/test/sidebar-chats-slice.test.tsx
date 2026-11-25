// The sidebar's chat history page mounts only the rows near the part of it the sidebar shows. The host
// streams that part (`cmux.sidebarChats.slice`: {revision, top, height} in CSS px); the page mounts the
// rows that meet [top - height, top + 2 * height] between two spacers, so the block keeps its height.
// Before the first slice every row mounts, as before the stream existed.
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
const { FIXTURE_METRICS, FIXTURE_STRINGS, fixtureBlock, fixtureRows } =
  await import("../src/pages/sidebar-chats/fixtures");
type Block = ReturnType<typeof fixtureBlock>;

// The wire names, spelled out: a page without the slice stream never subscribes to it.
const BLOCK = "cmux.sidebarChats.block";
const SLICE = "cmux.sidebarChats.slice";
const READY = "cmux.sidebarChats.ready";
const MORE = "cmux.sidebarChats.more";
const FOLD = "cmux.sidebarChats.fold";
const STRIDE = FIXTURE_METRICS.row + FIXTURE_METRICS.spacing;

const mounted: Array<{ unmount(): void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  view.document.body.replaceChildren();
});

async function mount() {
  const host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  const streams = new Map<string, (data: unknown) => void>();
  const calls: Array<{ op: string; params: Record<string, unknown> }> = [];
  const frames: Array<() => void> = [];
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      return Promise.resolve(undefined);
    },
    subscribe: async (stream: string, onEvent: (data: unknown) => void) => {
      streams.set(stream, onEvent);
      return () => {};
    },
    handle: () => () => {},
  };
  let chats!: ReturnType<typeof mountSidebarChats>;
  await act(async () => {
    chats = mountSidebarChats(host, client as never, FIXTURE_STRINGS, {
      nextFrame: (run) => {
        frames.push(run);
        return () => {};
      },
    });
  });
  mounted.push(chats);
  // As off the wire: every event is new objects.
  const emit = (stream: string, data: unknown) =>
    act(async () => streams.get(stream)?.(JSON.parse(JSON.stringify(data)) as unknown));
  const rows = () => [...host.querySelectorAll<HTMLElement>(".sc-row[data-chat]")];
  return {
    host,
    calls,
    block: (block: Block) => emit(BLOCK, block),
    slice: (slice: unknown) => emit(SLICE, slice),
    flushFrames: () => act(async () => frames.splice(0).forEach((run) => run())),
    rows,
    ids: () => rows().map((row) => row.dataset.chat),
    renders: mountedRowRenders(rows),
    /** The block's laid-out height: the header, the spacers' and rows' heights, the tail. */
    laidOut: () => {
      let height = 0;
      for (const child of host.querySelector(".sc-block")!.children) {
        if (child.classList.contains("sc-header")) height += FIXTURE_METRICS.header;
        else if (child.classList.contains("sc-spacer")) height += parseFloat((child as HTMLElement).style.height);
        else if (child.classList.contains("sc-row")) height += STRIDE;
      }
      return height;
    },
    styledHeight: () => (host.querySelector(".sc-block") as HTMLElement).style.height,
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

test("without a slice every row mounts, as before the stream", async () => {
  const page = await mount();
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  expect(page.rows().length).toBe(1_000);
  expect(page.host.querySelector(".sc-spacer")).toBeNull();
});

test("a slice mounts the rows in [top - height, top + 2 * height], the same count at 1k and 10k rows", async () => {
  const counts: number[] = [];
  for (const count of [1_000, 10_000]) {
    const page = await mount();
    await page.block(fixtureBlock({ revision: 3, rows: fixtureRows(count) }));
    await page.slice({ revision: 3, top: 3_000, height: 300 });
    const want = expected(count, 3_000, 300);
    // In DOM order, between the header and the tail.
    expect(page.ids()).toEqual(want);
    expect(page.host.querySelector(".sc-block")!.firstElementChild!.classList.contains("sc-header")).toBe(true);
    expect(page.host.querySelector(".sc-block")!.lastElementChild!.classList.contains("sc-tail")).toBe(true);
    counts.push(page.rows().length);
    await act(async () => mounted.splice(0).forEach((chats) => chats.unmount()));
  }
  expect(counts[0]).toBe(counts[1]!);
  expect(counts[0]).toBeLessThan(40);
});

test("the block's height, and so ready's, is the same with and without a slice", async () => {
  const block = fixtureBlock({ revision: 1, rows: fixtureRows(1_000) });
  const page = await mount();
  await page.block(block);
  await page.flushFrames();
  const before = { styled: page.styledHeight(), laidOut: page.laidOut() };
  await page.slice({ revision: 1, top: 9_000, height: 400 });
  await page.flushFrames();
  expect(page.rows().length).toBeLessThan(1_000);
  expect({ styled: page.styledHeight(), laidOut: page.laidOut() }).toEqual(before);
  expect(before).toEqual({ styled: `${blockHeight(block)}px`, laidOut: blockHeight(block) });
  // A slice asks for no ready of its own: one per drawn revision, as before.
  expect(page.calls.filter((call) => call.op === READY).map((call) => call.params.revision)).toEqual([1]);
});

test("a slice of height 0 (scrolled out) mounts no row; the spacers keep the full height", async () => {
  const block = fixtureBlock({ revision: 1, rows: fixtureRows(1_000) });
  const page = await mount();
  await page.block(block);
  await page.slice({ revision: 1, top: 0, height: 0 });
  expect(page.rows().length).toBe(0);
  expect(page.laidOut()).toBe(blockHeight(block));
  expect(page.host.querySelector(".sc-header")).not.toBeNull();
  expect(page.host.querySelector(".sc-tail")).not.toBeNull();
});

test("a one-row scroll of the slice draws only the row entering; the rest draw 0 times", async () => {
  const page = await mount();
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  await page.slice({ revision: 1, top: 3_000, height: 300 });
  const before = page.ids();
  page.renders.mark();
  await page.slice({ revision: 1, top: 3_000 + STRIDE, height: 300 });
  const after = page.ids();
  expect(after).toEqual(expected(1_000, 3_000 + STRIDE, 300));
  const entering = after.filter((id) => !before.includes(id));
  const leaving = before.filter((id) => !after.includes(id));
  expect([entering.length, leaving.length]).toEqual([1, 1]);
  // Only the entering row rendered (mounted); every row that stayed drew 0 times.
  expect(page.renders.since()).toBe(entering.length);
});

test("a slice older than the drawn block, or a malformed one, changes nothing", async () => {
  const page = await mount();
  await page.block(fixtureBlock({ revision: 5, rows: fixtureRows(1_000) }));
  await page.slice({ revision: 4, top: 3_000, height: 300 });
  expect(page.rows().length).toBe(1_000);
  await page.slice({ revision: 5, top: 3_000, height: 300 });
  const windowed = page.ids();
  expect(windowed).toEqual(expected(1_000, 3_000, 300));
  await page.slice({ revision: 4, top: 0, height: 300 });
  for (const bad of [null, {}, { revision: 6, top: "0", height: 300 }, { revision: 6, top: 0, height: -1 }])
    await page.slice(bad);
  await page.slice({ revision: 6, top: Number.NaN, height: 300 });
  expect(page.ids()).toEqual(windowed);
});

test("the slice holds across a new block; Show More and the fold still work under it", async () => {
  const page = await mount();
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(20) }));
  await page.slice({ revision: 1, top: 0, height: 300 });
  expect(page.ids()).toEqual(expected(20, 0, 300));
  await act(async () => {
    page.host.querySelector(".sc-tail")!.dispatchEvent(new view.MouseEvent("click", { bubbles: true }));
  });
  expect(page.calls.filter((call) => call.op === MORE)).toEqual([{ op: MORE, params: { revision: 1 } }]);
  // The host's next page arrives before its next slice: the last slice still windows it.
  await page.block(fixtureBlock({ revision: 2, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 0, 300));
  await act(async () => {
    page.host.querySelector(".sc-header")!.dispatchEvent(new view.MouseEvent("click", { bubbles: true }));
  });
  expect(page.calls.filter((call) => call.op === FOLD)).toEqual([{ op: FOLD, params: { revision: 2 } }]);
  await page.block(fixtureBlock({ revision: 3, rows: fixtureRows(1_000), folded: true }));
  expect(page.rows().length).toBe(0);
  expect(page.host.querySelector(".sc-spacer")).toBeNull();
});

test("a slice that arrives before the first block and names another revision does not window it", async () => {
  const page = await mount();
  // Measured on no block the page has drawn (the host's revision 0): a stale viewport for block 1.
  await page.slice({ revision: 0, top: 9_000, height: 300 });
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  expect(page.rows().length).toBe(1_000);
  expect(page.host.querySelector(".sc-spacer")).toBeNull();
  // Block 1's own slice then windows it.
  await page.slice({ revision: 1, top: 3_000, height: 300 });
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
});

test("a slice that names block 1's revision, sent before block 1, windows it once it is drawn", async () => {
  const page = await mount();
  await page.slice({ revision: 1, top: 3_000, height: 300 });
  expect(page.rows()).toEqual([]);
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
});

test("a slice that names a newer block does not window the drawn one; it waits for exactly that block", async () => {
  const page = await mount();
  await page.block(fixtureBlock({ revision: 1, rows: fixtureRows(1_000) }));
  await page.slice({ revision: 2, top: 3_000, height: 300 });
  expect(page.rows().length).toBe(1_000);
  await page.block(fixtureBlock({ revision: 2, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  // One held for revision 4 is dropped when revision 3 comes next instead; 3 keeps 2's drawn slice.
  await page.slice({ revision: 4, top: 9_000, height: 300 });
  await page.block(fixtureBlock({ revision: 3, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
  await page.block(fixtureBlock({ revision: 4, rows: fixtureRows(1_000) }));
  expect(page.ids()).toEqual(expected(1_000, 3_000, 300));
});
