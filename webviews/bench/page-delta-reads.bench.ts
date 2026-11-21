/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * What one change event costs the History and Feed pages at Leo's scale (audit 2026-11-18 section
 * 15): reads, reply bytes and page ms per event, through the real page stores against a stand-in host
 * that counts (test/support/countingPageClient.ts). The same file runs on base and on head.
 *
 * - History: 1,000 entries (the first window), `history-changed` at 4 a second for 5 s with the
 *   page shown (All), hidden, and filtered to Commands while the changes are agent ones.
 * - Feed: 2,000 items (the view cap), 20 `feed-view-changed` events naming one item each.
 *
 * "ms" is the page's own time per event: from a read's call until its reply is in the snapshot
 * (decode, map, group), summed over the run and divided by the events.
 *
 *   bun bench/page-delta-reads.bench.ts
 */
import { JSDOM } from "jsdom";
import { CountingPageClient, settle } from "../test/support/countingPageClient";
import { FeedDaemon, historyAnswer, historyEntries } from "../test/support/deltaFixtures";

// The bench runs on the wall clock: 4 events a second against the page's real 1 s gap.
const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const scope = globalThis as Record<string, unknown>;
scope.window = dom.window;
scope.document = dom.window.document;

const { HistoryStore } = await import("../src/pages/history/store");
const { FeedStore } = await import("../src/pages/feed/store");

interface Row {
  page: string;
  case: string;
  events: number;
  reads: number;
  bytes: number;
  ms: number;
}
const rows: Row[] = [];

/** Times each read from its call until the store's next snapshot. */
function timed(client: CountingPageClient, op: string) {
  let started: number | undefined;
  let total = 0;
  const call = client.call.bind(client);
  client.call = (async (name: string, params: unknown) => {
    if (name === op) started = performance.now();
    return call(name, params);
  }) as CountingPageClient["call"];
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

async function history(
  name: string,
  setup: (store: InstanceType<typeof HistoryStore>) => Promise<void>,
  hidden: boolean,
) {
  visibility = "visible";
  const op = "cmux.history.entries.list";
  const client = new CountingPageClient(historyAnswer(historyEntries(1000)));
  const timer = timed(client, op);
  const store = new HistoryStore(client, { newKey: () => "k" });
  const stop = store.subscribe(timer.onSnapshot);
  await settle();
  await setup(store);
  await settle();
  client.reset();
  timer.reset();
  if (hidden) visibility = "hidden";
  const events = 20;
  for (let index = 0; index < events; index += 1) {
    client.emit("cmux.history.changed", { revision: index, kinds: ["agent"] });
    await sleep(250);
  }
  await sleep(1100);
  await settle();
  const read = client.count(op);
  rows.push({ page: "History", case: name, events, reads: read.calls, bytes: read.bytes, ms: timer.total() });
  stop();
}

async function feed() {
  const op = "cmux.feed.view.read";
  const daemon = new FeedDaemon(2000);
  const client = new CountingPageClient(daemon.answer);
  const timer = timed(client, op);
  const store = new FeedStore(client, "#/list", { newKey: () => "k" });
  const stop = store.subscribe(timer.onSnapshot);
  await settle();
  client.reset();
  timer.reset();
  const events = 20;
  for (let index = 0; index < events; index += 1) {
    const id = daemon.touch((index * 97) % 2000);
    client.emit("cmux.feed.view.changed", { revision: daemon.revision, changed: [id] });
    await settle();
  }
  const read = client.count(op);
  rows.push({
    page: "Feed",
    case: "one item changed",
    events,
    reads: read.calls,
    bytes: read.bytes,
    ms: timer.total(),
  });
  stop();
}

await history("shown, All", async () => undefined, false);
await history("hidden", async () => undefined, true);
await history("shown, Commands, agent changes", async (store) => store.setFilter("commands"), false);
await feed();

const fixed = (value: number, digits = 2) => value.toFixed(digits);
console.log("| Page | Case | Events | Reads/event | KB/event | Page ms/event |");
console.log("|---|---|---:|---:|---:|---:|");
for (const row of rows) {
  console.log(
    `| ${row.page} | ${row.case} | ${row.events} | ${fixed(row.reads / row.events)} | ${fixed(row.bytes / row.events / 1024, 1)} | ${fixed(row.ms / row.events)} |`,
  );
}
process.exit(0);
