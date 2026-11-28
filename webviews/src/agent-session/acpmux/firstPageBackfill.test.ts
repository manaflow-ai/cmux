// An open attaches a screenful (FIRST_PAGE_BYTES / FIRST_PAGE_RECORDS) and reads the older page under it
// once it painted (`backfillOpen`). Once that backfill lands the chat holds every row the old 128 KiB /
// 400-record open page drew, the same rows in the same order, and more history above them.
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

const TURNS = 2000;
const OLD_OPEN = { limit: 400, maxBytes: 128 * 1024 };

/// Opens a long mock chat. `old`: the attach is asked with the old open page's bounds instead.
async function open(old: boolean, turns = TURNS) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const attaches: Record<string, unknown>[] = [];
  const olderReads: Record<string, unknown>[] = [];
  class Host extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as {
        answer: (method: string, params: Record<string, unknown>) => Promise<unknown>;
      };
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          attaches.push({ ...params });
          if (old) params = { ...params, ...OLD_OPEN };
        }
        // The transcript's older reads (not the one-record command catalog read).
        if (
          method === "_acpmux/events" &&
          params.beforeSeq !== undefined &&
          Number(params.limit) > 1 &&
          params.promptIndex !== true
        )
          olderReads.push({ ...params });
        return answer(method, params);
      };
    }
  }
  let socket: Host | undefined;
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next: unknown) => {
      snapshot = next;
    },
    undefined,
    () => {
      socket = new Host();
      return socket as unknown as WebSocket;
    },
  );
  await client.select(socket!.seedLoadSession(turns));
  return { client, attaches, olderReads, snapshot: () => snapshot };
}

/// Lets the backfill (a frame, then idle) and its read land on the mock's immediate answers.
const drain = async () => {
  // fixed-wait: the backfill waits a frame and an idle slot, then one read; a few ticks end it.
  for (let tick = 0; tick < 20; tick++) await new Promise((resolve) => setTimeout(resolve, 5));
};

/// Each mock seeds its chat at its own clock, so the rows are compared without their times.
const TIMES = new Set(["at", "turnStartedAtMs", "startedAt", "endedAt"]);
const keys = (snapshot: any): string[] =>
  (snapshot?.rows ?? []).map((row: unknown) =>
    JSON.stringify(row, (key, value) => (TIMES.has(key) ? undefined : value)),
  );

test("an open attaches a screenful, and its backfill holds every row the old open page drew", async () => {
  const before = await open(true);
  const after = await open(false);
  try {
    // The old page's rows as the open drew them, before any read under it.
    const oldRows = keys(before.snapshot());
    expect(oldRows.length).toBeGreaterThan(0);
    const { FIRST_PAGE_BYTES, FIRST_PAGE_RECORDS } = await import("./direct");
    expect(after.attaches[0]).toMatchObject({ maxBytes: FIRST_PAGE_BYTES, limit: FIRST_PAGE_RECORDS });
    const firstRows = keys(after.snapshot()).length;
    expect(firstRows).toBeLessThan(oldRows.length);
    await drain();
    // One backfill read, the at-rest page, and none ahead.
    expect(after.olderReads).toHaveLength(1);
    expect(after.olderReads[0]).toMatchObject({ maxBytes: 256 * 1024, limit: 400 });
    const newRows = keys(after.snapshot());
    expect(newRows.length).toBeGreaterThan(oldRows.length);
    // The old page's rows from its first whole turn on are the newest rows now, unchanged and in order.
    // The turn its edge cut is drawn whole now (its summary counts the tools above that edge).
    // That cut turn's prompt is the attach's turn opener: the whole turns start after its summary.
    const tail = oldRows.slice(oldRows.findIndex((row) => row.includes('"kind":"turnSummary"')) + 1);
    expect(tail.length).toBeGreaterThan(oldRows.length / 2);
    expect(newRows.slice(-tail.length)).toEqual(tail);
    expect(after.snapshot().canLoadOlder).toBe(true);
  } finally {
    before.client.close();
    after.client.close();
  }
}, 60_000);

test("a full backfill holds every row the old open page held, through the chat's start", async () => {
  // Short enough to page to its start; still several open pages long.
  const before = await open(true, 300);
  const after = await open(false, 300);
  try {
    await drain();
    for (const side of [before, after]) {
      for (let pages = 0; side.snapshot().canLoadOlder && pages < 200; pages += 1) {
        await side.client.loadOlder(undefined, false, false);
        await drain();
      }
      expect(side.snapshot().canLoadOlder).toBe(false);
    }
    expect(keys(after.snapshot())).toEqual(keys(before.snapshot()));
  } finally {
    before.client.close();
    after.client.close();
  }
}, 120_000);

test("a first page cut inside a turn starts at its first whole turn, and a page with no older records stays whole", async () => {
  const { firstTurnOnward } = await import("./direct");
  const rec = (seq: number, kind: string, dir = "in") => ({ seq, kind, dir, sessionId: "s", msg: {} }) as never;
  const page = [
    rec(12, "tool_call"),
    rec(13, "turn_result", "mux"),
    rec(14, "user_message", "mux"),
    rec(15, "tool_call"),
  ];
  expect(firstTurnOnward(page, true).map((event: { seq: number }) => event.seq)).toEqual([14, 15]);
  expect(firstTurnOnward(page, false)).toBe(page);
  // No turn starts past the first record: the page is one turn's tail, kept whole.
  const inside = [rec(12, "tool_call"), rec(13, "tool_call")];
  expect(firstTurnOnward(inside, true)).toBe(inside);
});
