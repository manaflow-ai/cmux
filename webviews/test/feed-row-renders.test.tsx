// l10n-allow-file: test fixtures.
// The Feed's rows, request cards and report rows render only when what they draw changed. The owner
// sends the whole view again on every change (every item a new object) and the page's clock moves on
// each read and action, so: a selection renders the rows whose selected state flipped, one item's
// change renders that row, a draft typed in one card renders that card, a read that changes nothing
// and a clock that leaves every time's text as it was render none. Counted from React's commits
// (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { MockItem } from "../src/pages/feed/mockProvider";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><main id=root></main>", {
    url: "http://localhost/feed/",
    pretendToBeVisual: true,
  });
  window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // jsdom has no layout: every element is a 400 by 800 box, so the lines (a virtual list at any
  // length) have a viewport, as in a window.
  const box = { x: 0, y: 0, top: 0, left: 0, right: 400, bottom: 800, width: 400, height: 800 };
  Object.defineProperties(window.HTMLElement.prototype, {
    getBoundingClientRect: { configurable: true, value: () => ({ ...box, toJSON: () => box }) },
    offsetHeight: { configurable: true, get: () => box.height },
    offsetWidth: { configurable: true, get: () => box.width },
    clientHeight: { configurable: true, get: () => box.height },
  });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLInputElement: window.HTMLInputElement,
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const NOW = new Date(2026, 10, 18, 15, 30).getTime();

async function mount(hash: string, items?: (now: number) => MockItem[]) {
  const { FeedPage } = await import("../src/pages/feed/FeedPage");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/feed/generated/strings.json")).default as Record<
    string,
    Record<string, string>
  >;
  const { MockFeedProvider, sampleFeed } = await import("../src/pages/feed/mockProvider");
  const { FeedStore } = await import("../src/pages/feed/store");
  let now = NOW;
  const provider = new MockFeedProvider((items ?? sampleFeed)(NOW), { now: () => now });
  const strings = createStrings(table, ["en"]);
  const store = new FeedStore(provider, hash, { clock: () => now });
  act(() => root?.unmount());
  rowRenders.clear();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host}>
        <FeedPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => {
    await store.start();
  });
  const rows = () => [...host.querySelectorAll<HTMLElement>(".feed-row")];
  // A selection marks the item read (the owner sends it again with its dot off): pick read rows.
  const readRows = () => rows().filter((row) => !row.hasAttribute("data-unread"));
  const times = (selector = ".feed-row") =>
    [...host.querySelectorAll<HTMLElement>(selector)].map((row) => row.querySelector("time")?.textContent);
  return {
    provider,
    store,
    rows,
    readRows,
    times,
    tick: (ms: number) => {
      now += ms;
    },
    run: (work: () => unknown) =>
      act(async () => {
        await work();
      }),
  };
}

const rowItem = (row: HTMLElement) => row.id.replace(/^feed-row-/, "");

test("the list: a selection renders the rows whose selected state flipped, and no card", async () => {
  const feed = await mount("#/list");
  const [first, second] = feed.readRows().map(rowItem);
  expect(feed.rows().length).toBeGreaterThan(3);
  rowRenders.reset();
  await feed.run(() => feed.store.select(first));
  expect(rowRenders.count("FeedRow")).toBe(1);
  expect(rowRenders.count("RequestCard")).toBe(0);
  rowRenders.reset();
  await feed.run(() => feed.store.select(second));
  expect(rowRenders.count("FeedRow")).toBe(2);
  expect(rowRenders.count("RequestCard")).toBe(0);
});

test("the list: a read that changes nothing renders nothing; a later clock renders the times it moved", async () => {
  const feed = await mount("#/list");
  rowRenders.reset();
  await feed.run(() => feed.store.reload());
  expect(rowRenders.count("FeedRow")).toBe(0);
  expect(rowRenders.count("RequestCard")).toBe(0);
  const changed = (before: unknown[], after: unknown[]) => after.filter((text, index) => text !== before[index]).length;
  for (const step of [1_000, 60_000]) {
    const rows = feed.times();
    const cards = feed.times(".feed-card");
    rowRenders.reset();
    feed.tick(step);
    await feed.run(() => feed.store.reload());
    expect(rowRenders.count("FeedRow")).toBe(changed(rows, feed.times()));
    expect(rowRenders.count("RequestCard")).toBe(changed(cards, feed.times(".feed-card")));
    expect(rowRenders.count("FeedRow")).toBeLessThan(rows.length);
  }
});

test("the list: one item's change renders that row alone", async () => {
  const feed = await mount("#/list");
  const id = rowItem(feed.rows()[2]!);
  const item = feed.provider.items.find((other) => other.id === id)!;
  rowRenders.reset();
  await feed.run(async () => {
    feed.provider.items = feed.provider.items.map((other) =>
      other.id === id ? { ...item, title: "Renamed", body: "Renamed" } : other,
    );
    await feed.store.reload();
  });
  expect(rowRenders.count("FeedRow")).toBe(1);
  expect(rowRenders.count("RequestCard")).toBe(0);
});

test("the list: a draft typed in one card renders that card alone", async () => {
  const feed = await mount("#/list");
  const cards = [...host.querySelectorAll<HTMLElement>(".feed-card")];
  expect(cards.length).toBeGreaterThan(2);
  const question = cards.find((card) => card.dataset.item === "fi_codex_question")!;
  expect(question).toBeDefined();
  rowRenders.reset();
  await feed.run(() => feed.store.setReply("fi_codex_question", "yes"));
  expect(rowRenders.count("RequestCard")).toBe(1);
  expect(rowRenders.count("FeedRow")).toBe(0);
  expect(question.querySelector<HTMLInputElement>("input.feed-field")?.value).toBe("yes");
});

test("the Inbox: a selection renders the rows whose selected state flipped", async () => {
  const feed = await mount("#/inbox");
  const ids = feed.readRows().map(rowItem);
  expect(ids.length).toBeGreaterThan(3);
  await feed.run(() => feed.store.select(ids[1]));
  rowRenders.reset();
  await feed.run(() => feed.store.select(ids[3]));
  // The two list rows, and the detail's thread rows when the new item has a thread (none here).
  expect(rowRenders.count("FeedRow")).toBe(2);
});

test("reports: a selection renders the two report rows whose state flipped", async () => {
  const feed = await mount("#/inbox");
  await feed.run(() => feed.store.setConnection("reports"));
  const reports = feed.store.getSnapshot().reports;
  if (reports.length < 3 || feed.store.getSnapshot().filter.connection !== "reports") {
    throw new Error(`reports tab not shown (${feed.store.getSnapshot().filter.connection}, ${reports.length})`);
  }
  await feed.run(() => feed.store.selectReport(reports[0]!.id));
  rowRenders.reset();
  await feed.run(() => feed.store.selectReport(reports[2]!.id));
  expect(rowRenders.count("ReportRow")).toBe(2);
});

test("at any length only the window's rows are mounted (a short feed too), and a selection renders two", async () => {
  const { manyNotices } = await import("../src/pages/feed/mockProvider");
  const counts: Record<number, { rows: number; nodes: number }> = {};
  for (const n of [50, 150, 1_000, 10_000]) {
    const feed = await mount("#/list", (now) => manyNotices(now, n));
    counts[n] = { rows: feed.rows().length, nodes: host.querySelectorAll("*").length };
    if (n === 1_000) {
      const ids = feed.readRows().map(rowItem);
      expect(ids.length).toBeGreaterThan(2);
      await feed.run(() => feed.store.select(ids[1]));
      rowRenders.reset();
      await feed.run(() => feed.store.select(ids[2]));
      expect(rowRenders.count("FeedRow")).toBe(2);
    }
  }
  console.log(
    `[jsdom] feed mounted rows / DOM nodes: ${[50, 150, 1_000, 10_000].map((n) => `N=${n} ${JSON.stringify(counts[n])}`).join(", ")}`,
  );
  // An 800 px viewport holds about 14 lines; the window adds a few on each side, whatever the length.
  expect(counts[1_000]!.rows).toBeGreaterThan(5);
  expect(counts[50]!.rows).toBeLessThan(40);
  expect(counts[150]!.rows).toBe(counts[1_000]!.rows);
  expect(counts[10_000]!.rows).toBe(counts[1_000]!.rows);
});

test("a scroll step in a short feed mounts the rows coming into view and renders no other", async () => {
  const { manyNotices } = await import("../src/pages/feed/mockProvider");
  const feed = await mount("#/list", (now) => manyNotices(now, 150));
  const scroller = host.querySelector<HTMLElement>(".feed-list-scroll")!;
  // The list's space moves up as its scroller scrolls (the stubbed boxes do not move by themselves).
  const space = host.querySelector<HTMLElement>(".ui-virtual-space")!;
  Object.defineProperty(space, "getBoundingClientRect", {
    configurable: true,
    value: () => {
      const top = -scroller.scrollTop;
      return { x: 0, y: top, top, left: 0, right: 400, bottom: top + 800, width: 400, height: 800 };
    },
  });
  const before = new Set(feed.rows().map(rowItem));
  rowRenders.reset();
  await feed.run(async () => {
    Object.defineProperty(scroller, "scrollTop", { configurable: true, writable: true, value: 600 });
    scroller.dispatchEvent(new window.Event("scroll"));
    // Until the window has moved: a row it did not hold before is mounted (one frame at a time).
    for (let frame = 0; frame < 60 && feed.rows().every((row) => before.has(rowItem(row))); frame++)
      await new Promise((resolve) => window.requestAnimationFrame(resolve));
  });
  const after = feed.rows().map(rowItem);
  const entered = after.filter((id) => !before.has(id)).length;
  expect(entered).toBeGreaterThan(0);
  expect(after.length).toBeLessThan(40);
  expect(rowRenders.count("FeedRow")).toBe(entered);
});
