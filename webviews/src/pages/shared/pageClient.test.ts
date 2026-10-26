// The page client's side of the router hold (pane-protocol-decisions.md decisions 15 and 32):
// held events arrive as one `evs` envelope and are handled in order as if sent one by one, and a
// stream that lost events while the page was hidden passes `gap` to its subscriber so it reads again.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, RESTORE_NAME, takePageRestore, type PageEventMeta, type ReplyHandler } from "./pageClient";

/** A host that answers every subscribe with the next sub id, from 7. */
function makeClient(): BridgePageClient {
  let nextSub = 7;
  const handler: ReplyHandler = {
    postMessage: async (body) => {
      const envelope = body as { t: string; id: number };
      if (envelope.t === "sub") return { t: "ok", id: envelope.id, value: { sub: nextSub++ } };
      return { t: "ok", id: envelope.id, value: null };
    },
  };
  return new BridgePageClient(handler, {});
}

type Seen = { data: unknown; seq: number; meta?: PageEventMeta };

describe("pageClient held events", () => {
  test("an evs batch reaches each subscriber in order", async () => {
    const client = makeClient();
    const a: Seen[] = [];
    const b: Seen[] = [];
    await client.subscribe("cmux.test.a", (data, seq, meta) => a.push({ data, seq, meta }));
    await client.subscribe("cmux.test.b", (data, seq, meta) => b.push({ data, seq, meta }));
    client.receive({
      t: "evs",
      events: [
        { t: "ev", sub: 7, seq: 1, data: { n: 0 } },
        { t: "ev", sub: 8, seq: 1, data: { n: 1 } },
        { t: "ev", sub: 7, seq: 2, data: { n: 2 } },
      ],
    });
    expect(a.map((event) => [event.seq, event.data])).toEqual([
      [1, { n: 0 }],
      [2, { n: 2 }],
    ]);
    expect(b.map((event) => [event.seq, event.data])).toEqual([[1, { n: 1 }]]);
  });

  test("a gap reaches the subscriber so it reads its state again", async () => {
    const client = makeClient();
    let reads = 0;
    const applied: unknown[] = [];
    await client.subscribe("cmux.test.deltas", (data, _seq, meta) => {
      if (meta?.gap) reads += 1;
      else applied.push(data);
    });
    client.receive({ t: "ev", sub: 7, seq: 1, data: { d: 1 } });
    client.receive({ t: "evs", events: [{ t: "ev", sub: 7, seq: 2, data: { d: 4 }, gap: true }] });
    client.receive({ t: "ev", sub: 7, seq: 3, data: { d: 5 } });
    expect(reads).toBe(1);
    expect(applied).toEqual([{ d: 1 }, { d: 5 }]);
  });

  test("an event with no gap has no gap in its meta", async () => {
    const client = makeClient();
    const metas: (PageEventMeta | undefined)[] = [];
    await client.subscribe("cmux.test.state", (_data, _seq, meta) => metas.push(meta));
    client.receive({ t: "ev", sub: 7, seq: 1, data: {}, opid: "op-1" });
    expect(metas).toEqual([{ opid: "op-1" }]);
  });
});

// A document that comes back after a discard (PageWebView+Discard.swift) reads the state its page
// saved when it hid, once, before its first paint.
describe("takePageRestore", () => {
  test("a restored document gets its saved state once", () => {
    const target: Record<string, unknown> = {
      [RESTORE_NAME]: { wasDiscarded: true, state: { route: "#/a", scroll: 120 } },
    };
    expect(takePageRestore(target)).toEqual({ wasDiscarded: true, state: { route: "#/a", scroll: 120 } });
    expect(takePageRestore(target)).toBeNull();
    expect(RESTORE_NAME in target).toBe(false);
  });

  test("a restored page that saved nothing gets null state", () => {
    expect(takePageRestore({ [RESTORE_NAME]: { wasDiscarded: true, state: null } })).toEqual({
      wasDiscarded: true,
      state: null,
    });
  });

  test("the bridge client takes the restore when it is made, before the page renders", () => {
    const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 1 }) };
    const target: Record<string, unknown> = {
      [RESTORE_NAME]: { wasDiscarded: true, state: { draft: "hello" } },
    };
    const client = new BridgePageClient(handler, target);
    expect(client.restore).toEqual({ wasDiscarded: true, state: { draft: "hello" } });
    expect(RESTORE_NAME in target).toBe(false);
    expect(new BridgePageClient(handler, {}).restore).toBeNull();
  });

  test("a document that was not discarded gets nothing", () => {
    expect(takePageRestore({})).toBeNull();
    expect(takePageRestore({ [RESTORE_NAME]: { wasDiscarded: false, state: 1 } })).toBeNull();
  });
});
