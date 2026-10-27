// The page client's side of the router hold (pane-protocol-decisions.md decisions 15 and 32):
// held events arrive as one `evs` envelope and are handled in order as if sent one by one, and a
// stream that lost events while the page was hidden passes `gap` to its subscriber so it reads again.
import { describe, expect, test } from "bun:test";
import {
  BridgePageClient,
  KEEP_ALIVE_OP,
  LISTEN_NAME,
  PageKeepAlive,
  pageError,
  RECEIVE_MANY_NAME,
  RESTORE_NAME,
  takePageRestore,
  type PageClient,
  type PageEventMeta,
  type ReplyHandler,
} from "./pageClient";

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

describe("pageClient frame batches", () => {
  test("receiveMany handles one frame's envelopes in send order", async () => {
    const target: Record<string, unknown> = {};
    let nextSub = 7;
    const client = new BridgePageClient(
      {
        postMessage: async (body) => {
          const envelope = body as { t: string; id: number };
          if (envelope.t === "sub") return { t: "ok", id: envelope.id, value: { sub: nextSub++ } };
          return { t: "ok", id: envelope.id, value: null };
        },
      },
      target,
    );
    const seen: unknown[] = [];
    await client.subscribe("cmux.test.a", (data) => seen.push(data));
    const receiveMany = target[RECEIVE_MANY_NAME] as (messages: unknown) => void;
    receiveMany([
      { t: "ev", sub: 7, seq: 1, data: { n: 0 } },
      { t: "evs", events: [{ t: "ev", sub: 7, seq: 2, data: { n: 1 } }] },
      { t: "ev", sub: 7, seq: 3, data: { n: 2 } },
    ]);
    expect(seen).toEqual([{ n: 0 }, { n: 1 }, { n: 2 }]);
  });

  test("a listener that throws does not stop the envelopes after it", async () => {
    const client = makeClient();
    const seen: number[] = [];
    await client.subscribe("cmux.test.a", (data) => {
      const { n } = data as { n: number };
      if (n === 0) throw new Error("listener failed");
      seen.push(n);
    });
    const error = console.error;
    console.error = () => {};
    try {
      client.receiveMany([
        { t: "ev", sub: 7, seq: 1, data: { n: 0 } },
        { t: "ev", sub: 7, seq: 2, data: { n: 1 } },
      ]);
    } finally {
      console.error = error;
    }
    expect(seen).toEqual([1]);
  });

  test("a value that is not a list is ignored", () => {
    const client = makeClient();
    expect(() => client.receiveMany({ t: "ev" })).not.toThrow();
  });
});

describe("pageClient push channel", () => {
  test("the client registers its receiver once, and runs handed to it reach subscribers in order", async () => {
    const receivers: ((messages: unknown) => void)[] = [];
    const target: Record<string, unknown> = {
      [LISTEN_NAME]: (receiver: (messages: unknown) => void) => {
        receivers.push(receiver);
        return true;
      },
    };
    let nextSub = 7;
    const client = new BridgePageClient(
      {
        postMessage: async (body) => {
          const envelope = body as { t: string; id: number };
          if (envelope.t === "sub") return { t: "ok", id: envelope.id, value: { sub: nextSub++ } };
          return { t: "ok", id: envelope.id, value: null };
        },
      },
      target,
    );
    expect(receivers).toHaveLength(1);
    const seen: unknown[] = [];
    await client.subscribe("cmux.test.a", (data) => seen.push(data));
    receivers[0]?.([
      { t: "ev", sub: 7, seq: 1, data: { n: 0 } },
      { t: "ev", sub: 7, seq: 2, data: { n: 1 } },
    ]);
    receivers[0]?.([{ t: "ev", sub: 7, seq: 3, data: { n: 2 } }]);
    expect(seen).toEqual([{ n: 0 }, { n: 1 }, { n: 2 }]);
  });

  test("a host without the channel keeps the script globals only", () => {
    const target: Record<string, unknown> = {};
    void new BridgePageClient({ postMessage: async () => null }, target);
    expect(typeof target[RECEIVE_MANY_NAME]).toBe("function");
    expect(target[LISTEN_NAME]).toBeUndefined();
  });
});

describe("PageKeepAlive", () => {
  /** A client that records each call and answers with `answer`. */
  function recording(answer: (op: string) => Promise<unknown> = async () => ({})) {
    const calls: { op: string; params: unknown }[] = [];
    const client: PageClient = {
      call: async <R>(op: string, params: unknown) => {
        calls.push({ op, params });
        return (await answer(op)) as R;
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    };
    return { client, calls };
  }

  test("tells the host only when a reason starts or ends", () => {
    const { client, calls } = recording();
    const keep = new PageKeepAlive(client);
    keep.set("user_edits", false);
    keep.set("user_edits", true);
    keep.set("user_edits", true);
    keep.set("draft", true);
    keep.set("user_edits", false);
    keep.set("user_edits", false);
    expect(calls).toEqual([
      { op: KEEP_ALIVE_OP, params: { reason: "user_edits", on: true } },
      { op: KEEP_ALIVE_OP, params: { reason: "draft", on: true } },
      { op: KEEP_ALIVE_OP, params: { reason: "user_edits", on: false } },
    ]);
    expect(keep.has("draft")).toBe(true);
    expect(keep.has("user_edits")).toBe(false);
  });

  test("an older host without the op is not an error", async () => {
    const warnings: unknown[] = [];
    const warn = console.warn;
    console.warn = (...args: unknown[]) => warnings.push(args);
    try {
      const { client } = recording(async () => {
        throw pageError("cmux.protocol.unknown_op", KEEP_ALIVE_OP);
      });
      new PageKeepAlive(client).set("user_edits", true);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(warnings).toEqual([]);
    } finally {
      console.warn = warn;
    }
  });

  test("no client: the state is kept and nothing is sent", () => {
    const keep = new PageKeepAlive(null);
    keep.set("capture", true);
    expect(keep.has("capture")).toBe(true);
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
