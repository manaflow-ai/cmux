// A rail jump far back reads the target's page directly (`indexedPage`), below the held tail. The
// turns between that page and the tail then read forward in the background (`fillIndexedGaps`), so
// reading down from the target reaches the tail through whole turns, not prompt-only placeholders
// (review of #42200: "about 1,500 prompt-only placeholders with no replies or tools, then the tail").
import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
import { connectClient, FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";

const SESSION = "indexed-gap";
let clock: VirtualClock | undefined;

afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

test("a distant rail jump fills every turn between its target and the held tail", async () => {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 300 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const { client, rows } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  const tailStart: number = internal.firstSeq;
  const prompts = events.filter((event: EventRecord) => event.kind === "user_message" && event.seq < tailStart);
  expect(prompts.length).toBeGreaterThan(100);
  // The index names every earlier prompt, as `loadPromptIndex` would.
  internal.promptIndex = {
    sessionId: SESSION,
    generation: internal.selectionGeneration,
    tries: 1,
    retryAt: 0,
    heads: PromptHeads.fromRows(
      prompts.map((event): AcpmuxRow => ({
        id: `user-${event.seq}`,
        version: 1,
        at: event.at,
        kind: "user",
        text: "p",
      })),
    ),
  };
  const target = prompts[Math.floor(prompts.length / 10)]!.seq;

  const jumped = client.loadThrough(target);
  await clock.advance(60_000);
  expect(await jumped).toBe(true);
  // The jump took the indexed path, not the page walker.
  expect(internal.indexedPages.size).toBeGreaterThan(0);

  const held = new Set<number>(internal.events.map((event: EventRecord) => event.seq));
  const missing = events.filter((event: EventRecord) => event.seq >= target && !held.has(event.seq));
  expect(missing.map((event: EventRecord) => event.seq)).toEqual([]);
  expect(internal.indexedGaps).toEqual([]);
  expect(internal.indexedPlaceholders.size).toBe(0);
  // Every prompt from the target down is a real turn in the drawn rows, in order.
  const drawn = rows()
    .filter((row) => row.kind === "user" && typeof row.seq === "number" && row.seq >= target)
    .map((row) => row.seq);
  expect(drawn).toEqual(drawn.slice().sort((a, b) => a! - b!));
  client.close();
});

test("a gap read that fails is read again, and a fill that went stale starts again for newer gaps", async () => {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 300 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const { client } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  const tailStart: number = internal.firstSeq;
  const typed = internal.typed.bind(internal);
  let failures = 1;
  internal.typed = (method: string, params: any, ...rest: unknown[]) => {
    if (method === "_acpmux/events" && params?.beforeSeq === undefined && failures > 0) {
      failures -= 1;
      return Promise.reject(new Error("dropped"));
    }
    return typed(method, params, ...rest);
  };
  internal.indexedGaps = [{ after: 0, before: tailStart }];
  internal.startIndexedGapFill();
  await clock.advance(60_000);
  const held = new Set<number>(internal.events.map((event: EventRecord) => event.seq));
  expect(events.filter((event: EventRecord) => !held.has(event.seq)).map((event: EventRecord) => event.seq)).toEqual(
    [],
  );
  expect(internal.indexedGaps).toEqual([]);

  // A fill whose read is out when the held history goes ends stale; a gap queued meanwhile still fills.
  internal.historyEpoch += 1;
  internal.indexedGaps = [{ after: 0, before: 50 }];
  internal.startIndexedGapFill();
  internal.historyEpoch += 1;
  internal.indexedGaps.push({ after: 0, before: 60 });
  await clock.advance(60_000);
  expect(internal.indexedGaps).toEqual([]);
  expect(internal.indexedGapFill).toBeUndefined();
  client.close();
});

test("dropping the held history drops the gaps still queued to fill", async () => {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 300 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const { client } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  internal.indexedGaps = [{ after: 1, before: internal.firstSeq }];
  internal.clearIndexedHistory();
  expect(internal.indexedGaps).toEqual([]);
  expect(internal.indexedPages.size).toBe(0);
  client.close();
});

// Leo 2026-11-22: "clicking along the scroll rail sometimes delayed/didn't load". A local daemon answers a gap page in
// about a millisecond, so the fill's reads, merges and redraws ran back to back and the jump that started it painted
// its target only after them (0.5 s for a prompt 1,300 back in a 1,500-turn chat, bench/chat-fast-scroll.bench.ts).
// Each read now waits for a painted frame: none before the first frames, at most one per frame after.
test("a gap fill reads at most one page per painted frame and none before the jump paints", async () => {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 300 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const { client } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  const scope = globalThis as any;
  const saved = { raf: scope.requestAnimationFrame, caf: scope.cancelAnimationFrame };
  let frames: Array<(at: number) => void> = [];
  scope.requestAnimationFrame = (run: (at: number) => void) => frames.push(run);
  scope.cancelAnimationFrame = () => {};
  const paint = async () => {
    const due = frames;
    frames = [];
    for (const run of due) run(clock!.now);
    await clock!.advance(1);
  };
  try {
    const typed = internal.typed.bind(internal);
    let reads = 0;
    internal.typed = (method: string, params: any, ...rest: unknown[]) => {
      if (method === "_acpmux/events" && params?.beforeSeq === undefined) reads += 1;
      return typed(method, params, ...rest);
    };
    internal.indexedGaps = [{ after: 0, before: internal.firstSeq }];
    internal.startIndexedGapFill();
    // Time passes but no frame paints: the fill must not read.
    await clock.advance(1_000);
    expect(reads).toBe(0);
    let frame = 0;
    while (internal.indexedGaps.length > 0 && frame < 2_000) {
      const before = reads;
      await paint();
      frame += 1;
      expect(reads - before).toBeLessThanOrEqual(1);
    }
    expect(internal.indexedGaps).toEqual([]);
    expect(reads).toBeGreaterThan(1);
  } finally {
    scope.requestAnimationFrame = saved.raf;
    scope.cancelAnimationFrame = saved.caf;
    client.close();
  }
});
