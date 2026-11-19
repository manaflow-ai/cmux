// Detector (cmuxterm-hq docs/handbook/whole-list-reread-on-delta.md): a change event costs a shown
// History or Home page only what changed, and a hidden Home page nothing until it shows.
//
// - History: a `history-changed` on a shown page reads with the owner's `follow` cursor and gets
//   only the changed entries (cmux-tui history_ops/follow.rs); the window stays the owner's.
// - Home: a new message in one conversation reads that row only (`home-inbox` with `only`), never
//   `conversation-list` or every row; a hidden page reads nothing per change, then once when shown.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { CountingPageClient, settle } from "./support/countingPageClient";
import { HistoryDaemon } from "./support/historyFollow";
import { HomeDaemon } from "./support/homeFixtures";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => Object.assign(scope, saved));

const { HistoryStore } = await import("../src/pages/history/store");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");

const show = (state: DocumentVisibilityState) => {
  visibility = state;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};

test("a history-changed on a shown History page does no whole-list read", async () => {
  visibility = "visible";
  const daemon = new HistoryDaemon(1000);
  const client = new CountingPageClient(daemon.answer);
  const store = new HistoryStore(client, { newKey: () => "k", changeReadGapMs: 0 });
  const stop = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().entries.length).toBe(1000);
  daemon.reset();
  const before = store.getSnapshot().entries;
  for (let index = 0; index < 4; index += 1) {
    daemon.touch(100 + index * 50);
    client.emit("cmux.history.changed", { revision: index, kinds: ["agent"] });
    await settle();
  }
  expect(daemon.wholeReads, "whole-list reads after a change").toBe(0);
  expect(daemon.deltaReads).toBeGreaterThan(0);
  expect(daemon.sent, "entries sent for 4 one-entry changes").toBeLessThanOrEqual(4);
  const entries = store.getSnapshot().entries;
  expect(entries.map((entry) => entry.id)).toEqual(daemon.entries.map((entry) => entry.id));
  expect(entries[0].at_ms).toBe(daemon.entries[0].at_ms);
  // Every row no change named keeps its object (its row does not render again).
  const kept = entries.filter((entry) => before.includes(entry)).length;
  expect(kept).toBe(996);
  stop();
});

async function openHome(daemon: HomeDaemon) {
  const client = new DaemonHomeClient(daemon.socket);
  const store = new HomeChannelsStore(client);
  store.routed = false;
  const stop = store.subscribe(() => undefined);
  await store.start();
  await settle();
  expect(store.getSnapshot().conversations.size).toBe(1000);
  daemon.reset();
  return { store, stop };
}

test("a new message on a shown Home page reads only its row, not the whole inbox", async () => {
  visibility = "visible";
  const daemon = new HomeDaemon(1000);
  const { store, stop } = await openHome(daemon);
  const before = store.getSnapshot().conversations;
  daemon.post(400);
  await settle();
  const reads = daemon.listReads();
  expect(reads.whole, "whole inbox reads").toBe(0);
  expect(reads.only).toBe(1);
  expect(reads.rows).toBe(1);
  const after = store.getSnapshot().conversations;
  expect(after.get(daemon.id(400))?.lastSeq).toBe(2);
  expect(after.get(daemon.id(401))).toBe(before.get(daemon.id(401)));
  stop();
});

test("a hidden Home page reads nothing per change, then exactly once when it shows", async () => {
  visibility = "visible";
  const daemon = new HomeDaemon(1000);
  const { store, stop } = await openHome(daemon);
  show("hidden");
  for (let index = 0; index < 20; index += 1) {
    daemon.post(index * 37);
    await settle(1);
  }
  await settle();
  expect(daemon.listReads().whole + daemon.listReads().only, "reads while hidden").toBe(0);
  show("visible");
  await settle();
  expect(daemon.listReads().whole + daemon.listReads().only, "reads on show").toBe(1);
  expect(store.getSnapshot().conversations.get(daemon.id(37))?.lastSeq).toBe(2);
  stop();
});
