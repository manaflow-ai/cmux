/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * What one change event costs the History, Feed and Home pages at Leo's scale (audit 2026-11-18
 * section 15; cmuxterm-hq docs/handbook/whole-list-reread-on-delta.md): whole-list reads, rows
 * decoded, reply bytes and page ms per event, through the real page stores against stand-in owners
 * that count (test/support/). The same file runs on base and on head.
 *
 * - History, no change (`history-changed` that moves no row): 1,000 entries, 4 events a second for
 *   5 s, shown (All), hidden, and filtered to Commands while the changes are agent ones.
 * - History, one entry per event: the same, but each event moves one entry to the top (the owner
 *   answers list follow, history_ops/follow.rs, to a page that sends its cursor), shown and hidden.
 * - Feed: 2,000 items (the view cap), 20 `feed-view-changed` events naming one item each.
 * - Home: 1,000 local conversations through the real DaemonHomeClient, a new message in one
 *   conversation 4 times a second for 5 s, shown and hidden ("on show" is the one read after).
 *
 * "ms" is the page's own time per event: from a read's call until its reply is in the snapshot
 * (decode, map, group), summed over the run and divided by the events.
 *
 *   bun bench/page-delta-reads.bench.ts
 */
import { JSDOM } from "jsdom";
import { CountingPageClient, settle } from "../test/support/countingPageClient";
import { FeedDaemon, historyAnswer, historyEntries } from "../test/support/deltaFixtures";
import { HistoryDaemon } from "../test/support/historyFollow";
import { HomeDaemon } from "../test/support/homeFixtures";

// The bench runs on the wall clock: 4 events a second against the page's real 1 s gap.
const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const scope = globalThis as Record<string, unknown>;
scope.window = dom.window;
scope.document = dom.window.document;
const show = (state: DocumentVisibilityState) => {
  visibility = state;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};

const { HistoryStore } = await import("../src/pages/history/store");
const { FeedStore } = await import("../src/pages/feed/store");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");

interface Row {
  page: string;
  case: string;
  events: number;
  /** Reads of the whole list. */
  whole: number;
  /** Rows (entries, items, conversations) the replies carried: what the page decoded and mapped. */
  rows: number;
  bytes: number;
  ms: number;
  /** Whole reads when a hidden page shows again. */
  onShow?: number;
}
const rows: Row[] = [];

interface Callable {
  call<R>(op: string, params: unknown): Promise<R>;
}

/** Times each read of `op` from its call until the store's next snapshot. */
function timed(client: Callable, op: string) {
  let started: number | undefined;
  let total = 0;
  const call = client.call.bind(client);
  client.call = (async (name: string, params: unknown) => {
    if (name === op) started = performance.now();
    return call(name, params);
  }) as Callable["call"];
  return {
    onSnapshot: () => {
      if (started === undefined) return;
      total += performance.now() - started;
      started = undefined;
    },
    total: () => total,
    reset: () => {
      total = 0;
    },
  };
}

const HISTORY_LIST = "cmux.history.entries.list";
const EVENTS = 20;

async function historyUnchanged(
  name: string,
  setup: (store: InstanceType<typeof HistoryStore>) => Promise<void>,
  hidden: boolean,
) {
  show("visible");
  const client = new CountingPageClient(historyAnswer(historyEntries(1000)));
  const timer = timed(client, HISTORY_LIST);
  const store = new HistoryStore(client, { newKey: () => "k" });
  const stop = store.subscribe(timer.onSnapshot);
  await settle();
  await setup(store);
  await settle();
  client.reset();
  timer.reset();
  if (hidden) show("hidden");
  for (let index = 0; index < EVENTS; index += 1) {
    client.emit("cmux.history.changed", { revision: index, kinds: ["agent"] });
    await sleep(250);
  }
  await sleep(1100);
  await settle();
  const read = client.count(HISTORY_LIST);
  const shown = (store.getSnapshot().entries.length || 0) * read.calls;
  rows.push({
    page: "History",
    case: `no row moved, ${name}`,
    events: EVENTS,
    whole: read.calls,
    rows: shown,
    bytes: read.bytes,
    ms: timer.total(),
  });
  stop();
}

async function historyMoved(hidden: boolean) {
  show("visible");
  const daemon = new HistoryDaemon(1000);
  const client = new CountingPageClient(daemon.answer);
  const timer = timed(client, HISTORY_LIST);
  const store = new HistoryStore(client, { newKey: () => "k" });
  const stop = store.subscribe(timer.onSnapshot);
  await settle();
  daemon.reset();
  client.reset();
  timer.reset();
  if (hidden) show("hidden");
  for (let index = 0; index < EVENTS; index += 1) {
    daemon.touch(100 + index * 7);
    client.emit("cmux.history.changed", { revision: index, kinds: ["agent"] });
    await sleep(250);
  }
  await sleep(1100);
  await settle();
  const row: Row = {
    page: "History",
    case: `one entry per event, ${hidden ? "hidden" : "shown"}`,
    events: EVENTS,
    whole: daemon.wholeReads,
    rows: daemon.sent,
    bytes: client.count(HISTORY_LIST).bytes,
    ms: timer.total(),
  };
  if (hidden) {
    daemon.reset();
    show("visible");
    await settle();
    row.onShow = daemon.wholeReads;
  }
  rows.push(row);
  stop();
}

async function feed() {
  show("visible");
  const op = "cmux.feed.view.read";
  const daemon = new FeedDaemon(2000);
  const client = new CountingPageClient(daemon.answer);
  const timer = timed(client, op);
  const store = new FeedStore(client, "#/list", { newKey: () => "k" });
  const stop = store.subscribe(timer.onSnapshot);
  await settle();
  client.reset();
  timer.reset();
  for (let index = 0; index < EVENTS; index += 1) {
    const id = daemon.touch((index * 97) % 2000);
    client.emit("cmux.feed.view.changed", { revision: daemon.revision, changed: [id] });
    await settle();
  }
  const read = client.count(op);
  rows.push({
    page: "Feed",
    case: "one item changed, shown",
    events: EVENTS,
    whole: read.calls,
    rows: Number.NaN,
    bytes: read.bytes,
    ms: timer.total(),
  });
  stop();
}

async function home(hidden: boolean) {
  show("visible");
  const daemon = new HomeDaemon(1000);
  const client = new DaemonHomeClient(daemon.socket);
  const timer = timed(client, "cmux.home.inbox");
  const store = new HomeChannelsStore(client);
  store.routed = false;
  const stop = store.subscribe(timer.onSnapshot);
  await store.start();
  await settle();
  daemon.reset();
  timer.reset();
  if (hidden) show("hidden");
  for (let index = 0; index < EVENTS; index += 1) {
    daemon.post((index * 37) % 1000);
    await sleep(250);
  }
  await settle();
  const reads = daemon.listReads();
  const row: Row = {
    page: "Home",
    case: `one message per event, ${hidden ? "hidden" : "shown"}`,
    events: EVENTS,
    whole: reads.whole,
    rows: reads.rows,
    bytes: reads.bytes,
    ms: timer.total(),
  };
  if (hidden) {
    daemon.reset();
    show("visible");
    await settle();
    row.onShow = daemon.listReads().whole;
  }
  rows.push(row);
  stop();
}

await historyUnchanged("shown, All", async () => undefined, false);
await historyUnchanged("hidden", async () => undefined, true);
await historyUnchanged("shown, Commands, agent changes", async (store) => store.setFilter("commands"), false);
await historyMoved(false);
await historyMoved(true);
await feed();
await home(false);
await home(true);

const fixed = (value: number, digits = 2) => (Number.isNaN(value) ? "-" : value.toFixed(digits));
console.log(
  "| Page | Case | Events | Whole reads/event | Rows decoded/event | KB/event | Page ms/event | Whole reads on show |",
);
console.log("|---|---|---:|---:|---:|---:|---:|---:|");
for (const row of rows) {
  console.log(
    `| ${row.page} | ${row.case} | ${row.events} | ${fixed(row.whole / row.events)} | ${fixed(row.rows / row.events, 1)} | ${fixed(row.bytes / row.events / 1024, 1)} | ${fixed(row.ms / row.events)} | ${row.onShow ?? "-"} |`,
  );
}
process.exit(0);
