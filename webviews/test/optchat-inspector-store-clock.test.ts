// The inspector's refresh: it rides the page's one clock, so it wakes only while
// the page shows, reads once on show for what fell due while hidden, and runs no timer while the
// page is hidden or nothing subscribes.
import { expect, test } from "bun:test";
import { ApiStore, MIN_REFRESH_MS } from "../src/optchat-inspector/store";
import { fakePage } from "./support/fakePageClock";

const START = 1_000_000_020_000; // on a minute boundary
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function countingFetcher(): { fetcher: (url: string) => Promise<unknown>; reads: (url: string) => number } {
  const counts = new Map<string, number>();
  return {
    fetcher: async (url) => {
      counts.set(url, (counts.get(url) ?? 0) + 1);
      return { url };
    },
    reads: (url) => counts.get(url) ?? 0,
  };
}

test("a refresh reads every minute while the page shows, nothing and no timer while hidden, once on show", async () => {
  const { doc, timers, clock } = fakePage(START);
  const { fetcher, reads } = countingFetcher();
  const store = new ApiStore(fetcher, clock);
  const stop = store.subscribe("/api/status", () => undefined, MIN_REFRESH_MS);
  expect(reads("/api/status")).toBe(1);
  expect(timers.live).toBe(1);

  timers.advance(5 * 60_000);
  expect(reads("/api/status")).toBe(6);

  doc.hide();
  expect(timers.live).toBe(0);
  timers.advance(5 * 60_000);
  expect(reads("/api/status")).toBe(6);
  expect(timers.live).toBe(0);

  doc.show();
  expect(reads("/api/status")).toBe(7);
  expect(timers.live).toBe(1);

  stop();
  expect(timers.live).toBe(0);
  timers.advance(60_000);
  expect(reads("/api/status")).toBe(7);
  await settle();
});

test("the Live tab's refresh wakes the page once a minute, and a shorter period is held to a minute", () => {
  for (const every of [MIN_REFRESH_MS, 2000]) {
    const { timers, clock } = fakePage(START);
    const { fetcher, reads } = countingFetcher();
    const store = new ApiStore(fetcher, clock);
    store.subscribe("/api/status", () => undefined, every);
    const armed = timers.armed;
    timers.advance(10 * 60_000);
    expect(timers.armed - armed).toBe(10);
    expect(reads("/api/status")).toBe(11);
  }
});

test("a refresh that starts on an answer already held reads it once at once", () => {
  const { timers, clock } = fakePage(START);
  const { fetcher, reads } = countingFetcher();
  const store = new ApiStore(fetcher, clock);
  const plain = store.subscribe("/api/status", () => undefined);
  expect(reads("/api/status")).toBe(1);
  timers.advance(30_000);
  plain();
  store.subscribe("/api/status", () => undefined, MIN_REFRESH_MS);
  expect(reads("/api/status")).toBe(2);
  timers.advance(30_000);
  expect(reads("/api/status")).toBe(2);
  timers.advance(60_000);
  expect(reads("/api/status")).toBe(3);
});

test("a show before the next read is due reads nothing", () => {
  const { doc, timers, clock } = fakePage(START);
  const { fetcher, reads } = countingFetcher();
  const store = new ApiStore(fetcher, clock);
  store.subscribe("/api/turns", () => undefined, 5 * 60_000);
  timers.advance(60_000);
  doc.hide();
  timers.advance(60_000);
  doc.show();
  expect(reads("/api/turns")).toBe(1);
  timers.advance(3 * 60_000);
  expect(reads("/api/turns")).toBe(2);
});

test("periods from a minute up wake the page once a minute, not once a second", () => {
  const { timers, clock } = fakePage(START);
  const { fetcher } = countingFetcher();
  const store = new ApiStore(fetcher, clock);
  store.subscribe("/api/turns", () => undefined, 60_000);
  const armed = timers.armed;
  timers.advance(2 * 60_000);
  expect(timers.armed - armed).toBe(2);
});

test("a subscription without a period reads once and arms nothing", () => {
  const { timers, clock } = fakePage(START);
  const { fetcher, reads } = countingFetcher();
  const store = new ApiStore(fetcher, clock);
  store.subscribe("/api/turn?key=now", () => undefined);
  timers.advance(5 * 60_000);
  expect(reads("/api/turn?key=now")).toBe(1);
  expect(timers.live).toBe(0);
});
