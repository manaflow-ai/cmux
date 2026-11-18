// Older-history paging of a long chat over a daemon socket that takes a round trip per read, as a
// chat on another machine or a busy daemon does (Leo, 2026-11-10: "the infinite scrolling does kind
// of work, but it's too slow. It needs to do more. It needs to do a lot. Otherwise, the, like, jump
// to last read isn't very useful at all"). Two reader journeys over the real client and the mock
// daemon's paging (hub/paging.rs rules):
//
// - scroll to the first message: the reader reaches the top of what is loaded, asks, waits for the
//   page, then reads down through it before reaching the top again;
// - jump to a place far back (the unread line, a reopened chat's place): the row must be loaded
//   with the turns around it.
//
// Each prints one BENCH line (ms the reader waited, asks, daemon reads); the asserts hold the
// outcome (every turn once, in order; the target row loaded) and the round trips a jump may take.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
}, 120_000);
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
}, 120_000);

/// Turns in the chat, and the daemon's round trip for one older read.
const TURNS = 2000;
const RTT_MS = 25;
/// How long the reader takes to scroll through a page once it lands, before reaching the top again.
const READ_MS = 40;

type Snapshot = { sessionId?: string; rows: { id: string; kind: string; text?: string }[]; canLoadOlder: boolean };

async function openSlowChat(options: { pageBytes?: number; capabilities?: string[] } = {}) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // Older pages (bounded by `maxBytes`; not the tail other chats read ahead, at
  // `Number.MAX_SAFE_INTEGER`, nor a one-record probe): how many, how many asked for whole turns,
  // and the records their replies held above their oldest turn start with more before them, which
  // the client carries to its next ask (direct.ts `olderCarry`).
  const counts = { reads: 0, olderReads: 0, wholeTurnReads: 0, carried: 0 };
  const opens = (event: { dir?: string; kind?: string; msg?: any }) =>
    event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;
  class SlowHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as {
        answer: (method: string, params: Record<string, unknown>) => Promise<unknown>;
      };
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "_acpmux/events" && params.beforeSeq !== undefined && params.promptIndex !== true) {
          counts.reads += 1;
          // A daemon whose records are larger than the client's estimate ends pages short.
          if (options.pageBytes !== undefined && params.promptIndex !== true)
            params = { ...params, maxBytes: options.pageBytes };
          // fixed-wait: the simulated daemon round trip this bench measures against.
          await new Promise((resolve) => setTimeout(resolve, RTT_MS));
          if (Number(params.beforeSeq) < Number.MAX_SAFE_INTEGER && params.maxBytes !== undefined) {
            counts.olderReads += 1;
            if (params.wholeTurns === true) counts.wholeTurnReads += 1;
            const reply = (await answer(method, params)) as { events: any[]; hasMore: boolean };
            const start = reply.hasMore ? reply.events.findIndex(opens) : -1;
            if (start > 0) counts.carried += start;
            return reply;
          }
        }
        return answer(method, params);
      };
    }
  }
  // The capability ids the mock daemon's `initialize` names (none: an older daemon).
  const globals = globalThis as { cmuxAcpmuxMockCapabilities?: string[] };
  if (options.capabilities) globals.cmuxAcpmuxMockCapabilities = options.capabilities;
  else delete globals.cmuxAcpmuxMockCapabilities;
  let snapshot: Snapshot | undefined;
  let socket: SlowHost | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next as unknown as Snapshot;
    },
    undefined,
    () => {
      socket = new SlowHost();
      return socket as unknown as WebSocket;
    },
  );
  const session = socket!.seedLoadSession(TURNS);
  await client.select(session);
  Object.assign(counts, { reads: 0, olderReads: 0, wholeTurnReads: 0, carried: 0 });
  const events = (socket as unknown as { events: { sessionId: string; seq: number; kind: string; msg?: any }[] })
    .events;
  /// The seq of turn `turn`'s prompt in the daemon's log.
  const promptSeq = (turn: number) =>
    events.find(
      (event) =>
        event.sessionId === session &&
        event.kind === "user_message" &&
        JSON.stringify(event.msg ?? "").includes(`Turn ${turn}:`),
    )!.seq;
  return { client, counts, promptSeq, snapshot: () => snapshot };
}

const prompts = (snapshot: Snapshot | undefined) =>
  (snapshot?.rows ?? []).filter((row) => row.kind === "user").map((row) => row.text ?? "");

/// The reader scrolls from the open to the chat's first message; every turn lands once, in order.
/// Prints one BENCH line under `label` and returns the daemon's counts.
async function scrollToFirst(label: string, options: { capabilities?: string[] } = {}) {
  const { client, counts, snapshot } = await openSlowChat(options);
  try {
    let waited = 0;
    let worst = 0;
    let asks = 0;
    const turnsPerAsk: number[] = [];
    while (snapshot()?.canLoadOlder && asks < TURNS) {
      const before = prompts(snapshot()).length;
      const start = performance.now();
      // The reader is scrolling up through the chat: the ask a scroll makes (OlderAhead.rising).
      await client.loadOlder(undefined, false, true);
      const wait = performance.now() - start;
      waited += wait;
      worst = Math.max(worst, wait);
      asks += 1;
      turnsPerAsk.push(prompts(snapshot()).length - before);
      // fixed-wait: the reader scrolls through the page that landed before reaching the top again.
      await new Promise((resolve) => setTimeout(resolve, READ_MS));
    }
    const all = prompts(snapshot());
    expect(all.length).toBe(TURNS);
    all.forEach((text, turn) => expect(text).toStartWith(`Turn ${turn}:`));
    const medianTurns = [...turnsPerAsk].sort((a, b) => a - b)[Math.floor(turnsPerAsk.length / 2)];
    console.log(
      `BENCH ${label} turns=${TURNS} rtt=${RTT_MS}ms asks=${asks} reads=${counts.reads} olderReads=${counts.olderReads} wholeTurnReads=${counts.wholeTurnReads} carriedRecords=${counts.carried} waited=${Math.round(waited)}ms worstWait=${Math.round(worst)}ms medianTurnsPerAsk=${medianTurns}`,
    );
    return { asks, ...counts };
  } finally {
    client.close();
    delete (globalThis as { cmuxAcpmuxMockCapabilities?: string[] }).cmuxAcpmuxMockCapabilities;
  }
}

test("scrolling up a long chat to its first message: the reader's wait at the top", async () => {
  // An older daemon: no whole-turn pages, so the client keeps each turn whole by carrying the
  // records above a page's oldest turn start to its next ask.
  const counts = await scrollToFirst("scroll-to-first");
  expect(counts.wholeTurnReads).toBe(0);
}, 120_000);

test("a daemon that pages whole turns: each older page is one read that lands whole, nothing carried", async () => {
  const { WHOLE_TURN_PAGES_CAPABILITY } = await import("./direct");
  const counts = await scrollToFirst("scroll-to-first.whole-turns", { capabilities: [WHOLE_TURN_PAGES_CAPABILITY] });
  // Every older read asked for whole turns, and no reply held records for a later ask to land.
  expect(counts.olderReads).toBeGreaterThan(0);
  expect(counts.wholeTurnReads).toBe(counts.olderReads);
  expect(counts.carried).toBe(0);
  // One read per ask, plus at most the pages read ahead past the last one.
  expect(counts.olderReads).toBeLessThanOrEqual(counts.asks + 4);
}, 120_000);

test("jumping to a place far back in a long chat: one direct read, not a page walk", async () => {
  const { client, counts, promptSeq, snapshot } = await openSlowChat();
  try {
    const turn = Math.floor(TURNS / 4);
    const seq = promptSeq(turn);
    const has = () => (snapshot()?.rows ?? []).some((row) => row.id === `user-${seq}`);
    expect(has()).toBe(false);
    const start = performance.now();
    // The transcript's jump (the rail's tick, the unread line) reads through the place's seq.
    expect(await client.loadThrough(seq)).toBe(true);
    const ms = performance.now() - start;
    expect(has()).toBe(true);
    // Bound daemon work for this fixed ordinary-chat fixture as well as checking the result.
    expect(counts.reads).toBeLessThan(32);
    // The turns around the place are loaded with it: the turn before it, and every turn after.
    const loaded = prompts(snapshot());
    const at = loaded.findIndex((text) => text.startsWith(`Turn ${turn}:`));
    expect(at).toBeGreaterThan(0);
    loaded.slice(at).forEach((text, index) => expect(text).toStartWith(`Turn ${turn + index}:`));
    console.log(
      `BENCH jump-far-back turns=${TURNS} target=turn${turn} rtt=${RTT_MS}ms reads=${counts.reads} ms=${Math.round(ms)}`,
    );
  } finally {
    client.close();
  }
}, 120_000);

test("a jump whose pages end short of their stretch (byte caps) still lands every turn up to the latest", async () => {
  const { client, promptSeq, snapshot } = await openSlowChat({ pageBytes: 48 * 1024 });
  try {
    const turn = Math.floor(TURNS / 2);
    const seq = promptSeq(turn);
    expect(await client.loadThrough(seq)).toBe(true);
    const loaded = prompts(snapshot());
    const at = loaded.findIndex((text) => text.startsWith(`Turn ${turn}:`));
    expect(at).toBeGreaterThan(0);
    loaded.forEach((text, index) => expect(text).toStartWith(`Turn ${turn - at + index}:`));
    expect(loaded.at(-1)).toStartWith(`Turn ${TURNS - 1}:`);
    // Paging on from there still reaches the first message, each turn once.
    for (let asks = 0; snapshot()?.canLoadOlder && asks < TURNS; asks += 1) await client.loadOlder();
    const all = prompts(snapshot());
    expect(all.length).toBe(TURNS);
    all.forEach((text, index) => expect(text).toStartWith(`Turn ${index}:`));
  } finally {
    client.close();
  }
}, 120_000);
