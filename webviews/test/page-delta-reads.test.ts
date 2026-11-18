// Detector for the audit of 2026-11-18, section 15 ("History, Feed and Home re-read everything per
// event and ignore the delta the event carries"; docs/handbook/whole-list-reread-on-delta.md in
// cmuxterm-hq): a change event costs a page only what it changed.
//
// - History: a `history-changed` for a hidden page, or for a kind its filter does not show, reads
//   nothing (a hidden page reads once when it shows again); a burst reads at most once per gap.
// - Feed: a `feed-view-changed` that names its items reads only those in full (`only`); every
//   other row keeps the object the page already had.
//
// The stand-in host counts each op's calls and reply bytes (test/support/countingPageClient.ts).
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { CountingPageClient, settle } from "./support/countingPageClient";
import { FeedDaemon, historyAnswer, historyEntries } from "./support/deltaFixtures";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => Object.assign(scope, saved));

const { HistoryStore } = await import("../src/pages/history/store");
const { FeedStore } = await import("../src/pages/feed/store");

const LIST = "cmux.history.entries.list";
const CHANGED = "cmux.history.changed";
const show = (state: DocumentVisibilityState) => {
  visibility = state;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};

async function openHistory(gap = 50) {
  const client = new CountingPageClient(historyAnswer(historyEntries()));
  const store = new HistoryStore(client, { newKey: () => "k", changeReadGapMs: gap });
  const stop = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().entries.length).toBe(1000);
  client.reset();
  return { client, store, stop };
}

test("a hidden History page reads nothing per history-changed, and once when it shows", async () => {
  const { client, stop } = await openHistory();
  show("hidden");
  for (let index = 0; index < 20; index += 1) client.emit(CHANGED, { revision: index, kinds: ["agent"] });
  await settle();
  expect(client.count(LIST).calls, "reads while hidden").toBe(0);
  show("visible");
  await settle();
  expect(client.count(LIST).calls, "reads on show").toBe(1);
  stop();
});

test("a history-changed of a kind the filter does not show reads nothing", async () => {
  const { client, store, stop } = await openHistory();
  store.setFilter("commands");
  await settle();
  client.reset();
  for (let index = 0; index < 20; index += 1) client.emit(CHANGED, { revision: index, kinds: ["agent", "closed"] });
  await settle();
  expect(client.count(LIST).calls).toBe(0);
  client.emit(CHANGED, { revision: 99, kinds: ["command"] });
  await settle();
  expect(client.count(LIST).calls, "a shown kind still reads").toBe(1);
  stop();
});

test("a burst of history-changed reads once now and once after the gap", async () => {
  const { client, stop } = await openHistory(60);
  for (let index = 0; index < 8; index += 1) client.emit(CHANGED, { revision: index, kinds: ["agent"] });
  await settle();
  expect(client.count(LIST).calls, "the first change reads at once").toBe(1);
  // The gap itself is under test: this timer is due after the store's 60 ms one, so it always
  // fires second, however late a loaded runner wakes both.
  // fixed-wait: the 60 ms gap between two reads is the behavior under test
  await new Promise((resolve) => setTimeout(resolve, 120));
  await settle();
  expect(client.count(LIST).calls, "one trailing read takes the rest").toBe(2);
  stop();
});

test("a feed-view-changed with ids reads only those items in full", async () => {
  const daemon = new FeedDaemon(2000);
  const client = new CountingPageClient(daemon.answer);
  const store = new FeedStore(client, "#/list", { newKey: () => "k" });
  const stop = store.subscribe(() => undefined);
  await settle();
  const before = store.getSnapshot().view!;
  expect(before.total).toBe(2000);
  const whole = client.count("cmux.feed.view.read").bytes;
  client.reset();

  const changed = daemon.touch(3);
  client.emit("cmux.feed.view.changed", { revision: daemon.revision, changed: [changed] });
  await settle();
  const read = client.count("cmux.feed.view.read");
  expect(read.calls).toBe(1);
  expect((read.params[0] as { only?: string[] }).only, "the read names only the changed item").toEqual([changed]);
  expect(read.bytes, "a delta read carries a small part of the view").toBeLessThan(whole / 4);
  const after = store.getSnapshot().view!;
  const rest = after.groups[1].entries;
  expect(rest[3].item.title).toContain(`revision ${daemon.revision}`);
  expect(rest[4].item, "an unchanged row keeps its object").toBe(before.groups[1].entries[4].item);
  expect(rest.every((entry) => !("same" in entry.item))).toBe(true);

  // A change without ids (the connection) reads the whole view.
  client.reset();
  client.emit("cmux.feed.view.changed", { revision: daemon.revision, changed: [] });
  await settle();
  expect((client.count("cmux.feed.view.read").params[0] as { only?: string[] }).only).toBeUndefined();
  stop();
});
