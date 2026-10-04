// IntentStore rules (a)-(h) of plans/cmux-next/zero-latency.md, including the races: a slow ack
// after a newer intent, a refused middle intent, a reconnect with intents in flight, duplicates.
import { describe, expect, test } from "bun:test";
import { createMockPair } from "../adapters/mock";
import { ProtocolError, ProtocolErrorCode } from "../errors";
import { PrefetchCache } from "../intents/prefetch";
import { runChunked } from "../intents/schedule";
import { IntentStore, defineIntent, isOpid, type IntentSender } from "../intents/store";
import { OpidLedger } from "../opid-ledger";
import { Session } from "../session";

interface Call {
  op: string;
  params: unknown;
  opid: string | undefined;
  signal: AbortSignal | undefined;
  resolve(value: unknown): void;
  reject(error: unknown): void;
}

/** A sender whose calls the test answers by hand. */
function manualSender() {
  const calls: Call[] = [];
  const sender: IntentSender = {
    call(op, params, options) {
      return new Promise((resolve, reject) => {
        calls.push({ op, params, opid: options?.opid, signal: options?.signal, resolve, reject });
      });
    },
  };
  return { sender, calls };
}

const flush = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

interface Doc {
  viewed: Record<string, boolean>;
  log: string[];
  pref: string;
}

const initial: Doc = { viewed: {}, log: [], pref: "split" };

const kinds = {
  setViewed: defineIntent<Doc, { path: string; viewed: boolean }>({
    op: "cmux.diff.viewed.set",
    resource: (p) => `viewed:${p.path}`,
    apply: (s, p) => ({ ...s, viewed: { ...s.viewed, [p.path]: p.viewed } }),
  }),
  append: defineIntent<Doc, { doc: string; text: string }>({
    op: "cmux.doc.append",
    resource: (p) => `doc:${p.doc}`,
    apply: (s, p) => ({ ...s, log: [...s.log, p.text] }),
  }),
  appendStrict: defineIntent<Doc, { doc: string; text: string }>({
    op: "cmux.doc.append",
    resource: (p) => `doc:${p.doc}`,
    apply: (s, p) => ({ ...s, log: [...s.log, p.text] }),
    onPriorRefused: "cancel",
  }),
  appendEvent: defineIntent<Doc, { doc: string; text: string }>({
    op: "cmux.doc.append",
    resource: (p) => `doc:${p.doc}`,
    apply: (s, p) => ({ ...s, log: [...s.log, p.text] }),
    confirm: "event",
  }),
  setPref: defineIntent<Doc, { value: string }>({
    op: "cmux.prefs.set",
    resource: () => "pref",
    apply: (s, p) => ({ ...s, pref: p.value }),
    supersede: true,
  }),
  readPref: defineIntent<Doc, { value: string }>({
    op: "cmux.prefs.read",
    resource: () => "pref-read",
    apply: (s, p) => ({ ...s, pref: p.value }),
    supersede: true,
    abortSuperseded: true,
  }),
  local: defineIntent<Doc, { value: string }>({
    op: null,
    resource: () => "local",
    apply: (s, p) => ({ ...s, pref: p.value }),
  }),
};

function makeStore(sender: IntentSender | null = manualSender().sender) {
  return new IntentStore<Doc, typeof kinds>({ initial, kinds, sender, opidPrefix: "t" });
}

describe("(a) local-first", () => {
  test("dispatch applies and notifies before it returns", () => {
    const { sender } = manualSender();
    const store = makeStore(sender);
    const seen: boolean[] = [];
    store.subscribe(() => seen.push(store.getState().viewed["a.ts"] === true));
    store.dispatch("setViewed", { path: "a.ts", viewed: true });
    expect(store.getState().viewed["a.ts"]).toBe(true);
    expect(seen).toEqual([true]);
    expect(store.getBase().viewed["a.ts"]).toBeUndefined();
  });

  test("getState is stable between changes (safe for useSyncExternalStore)", () => {
    const store = makeStore();
    store.dispatch("setViewed", { path: "a.ts", viewed: true });
    expect(store.getState()).toBe(store.getState());
    expect(store.getMeta()).toBe(store.getMeta());
  });

  test("a local intent settles into the base at once and sends nothing", () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("local", { value: "unified" });
    expect(store.getBase().pref).toBe("unified");
    expect(store.pending()).toEqual([]);
    expect(calls).toEqual([]);
  });
});

describe("(b) operation ids", () => {
  test("every intent gets a distinct valid opid, sent with the call", () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const a = store.dispatch("setViewed", { path: "a.ts", viewed: true });
    const b = store.dispatch("setViewed", { path: "b.ts", viewed: true });
    expect(a).not.toBe(b);
    expect(isOpid(a) && isOpid(b)).toBe(true);
    expect(calls.map((call) => call.opid)).toEqual([a, b]);
    expect(calls[0].op).toBe("cmux.diff.viewed.set");
    expect(calls[0].params).toEqual({ path: "a.ts", viewed: true });
  });

  test("the session puts opid on the call envelope and providers echo it on events", async () => {
    const [a, b] = createMockPair();
    const client = new Session(a, { role: "client" });
    const server = new Session(b, { role: "server" });
    const emits: Array<(data: unknown, meta?: { opid?: string }) => void> = [];
    server.provide("cmux.doc.changed", (ctx) => emits.push(ctx.emit));
    server.register("cmux.doc.append", (params, ctx) => {
      emits[0]?.({ text: (params as { text: string }).text }, { opid: ctx.opid });
      return { ok: true };
    });
    const events: Array<{ data: unknown; opid?: string }> = [];
    await client.subscribe("cmux.doc.changed", { onEvent: (data, _seq, meta) => events.push({ data, ...meta }) });
    await client.call("cmux.doc.append", { text: "x" }, { opid: "t-9" });
    await flush();
    const sentCall = a.sent
      .map((m) => JSON.parse(m as string))
      .find((m) => m.t === "call" && m.op === "cmux.doc.append");
    expect(sentCall.opid).toBe("t-9");
    expect(events).toEqual([{ data: { text: "x" }, opid: "t-9" }]);
  });

  test("an invalid opid is refused before it is sent", async () => {
    const [a] = createMockPair();
    const client = new Session(a, { role: "client" });
    await expect(client.call("cmux.doc.append", {}, { opid: "has space" })).rejects.toMatchObject({
      code: ProtocolErrorCode.badMessage,
    });
  });
});

describe("(c) ordering", () => {
  test("one in flight per resource, in input order; resources run in parallel", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("append", { doc: "d", text: "1" });
    store.dispatch("append", { doc: "d", text: "2" });
    store.dispatch("append", { doc: "e", text: "x" });
    expect(calls.map((call) => (call.params as { text: string }).text)).toEqual(["1", "x"]);
    expect(store.getState().log).toEqual(["1", "2", "x"]);
    calls[0].resolve(null);
    await flush();
    expect(calls.map((call) => (call.params as { text: string }).text)).toEqual(["1", "x", "2"]);
  });

  test("a later intent builds on the optimistic state", () => {
    const store = makeStore();
    store.dispatch("append", { doc: "d", text: "1" });
    store.dispatch("append", { doc: "d", text: "2" });
    expect(store.getState().log).toEqual(["1", "2"]);
    expect(store.getBase().log).toEqual([]);
  });
});

describe("(d) reconciliation", () => {
  test("ok folds the intent into the base with no visible change", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const states: string[][] = [];
    store.subscribe(() => states.push(store.getState().log));
    store.dispatch("append", { doc: "d", text: "1" });
    calls[0].resolve(null);
    await flush();
    expect(store.getBase().log).toEqual(["1"]);
    expect(store.pending()).toEqual([]);
    // Never flickered back to [].
    expect(states.every((log) => log.length === 1)).toBe(true);
  });

  test("event-confirmed intents stay optimistic after ok until the event echoes the opid", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const states: string[][] = [];
    store.subscribe(() => states.push(store.getState().log));
    const opid = store.dispatch("appendEvent", { doc: "d", text: "1" });
    calls[0].resolve(null);
    await flush();
    expect(store.getState().log).toEqual(["1"]);
    expect(store.pending()[0].phase).toBe("acked");
    store.receive((base) => ({ ...base, log: ["1"] }), opid);
    expect(store.pending()).toEqual([]);
    expect(store.getState().log).toEqual(["1"]);
    expect(states.every((log) => log.join() === "1")).toBe(true);
  });

  test("an event that confirms an in-flight intent frees the resource; the late ok is ignored", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const first = store.dispatch("appendEvent", { doc: "d", text: "1" });
    store.dispatch("appendEvent", { doc: "d", text: "2" });
    store.receive((base) => ({ ...base, log: ["1"] }), first);
    await flush();
    expect(calls.length).toBe(2);
    calls[0].resolve(null);
    await flush();
    expect(store.getState().log).toEqual(["1", "2"]);
    expect(store.trace().some((entry) => entry.type === "duplicate" && entry.opid === first)).toBe(true);
  });

  test("race: a slow load that started before an intent cannot undo it", async () => {
    const { sender } = manualSender();
    const store = makeStore(sender);
    let answer!: (doc: Doc) => void;
    const loading = store.load(() => new Promise<Doc>((resolve) => (answer = resolve)));
    store.dispatch("setViewed", { path: "a.ts", viewed: true });
    answer({ ...initial, viewed: { "a.ts": false, "b.ts": true } });
    await loading;
    expect(store.getState().viewed).toEqual({ "a.ts": true, "b.ts": true });
  });

  test("a read started after an ok retires the acked event intent; one started before does not", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("appendEvent", { doc: "d", text: "1" });
    const before = store.beginRead();
    calls[0].resolve(null);
    await flush();
    store.resync({ ...initial, log: [] }, before);
    expect(store.getState().log).toEqual(["1"]);
    const after = store.beginRead();
    store.resync({ ...initial, log: ["1"] }, after);
    expect(store.pending()).toEqual([]);
    expect(store.getState().log).toEqual(["1"]);
  });
});

describe("(e) rollback", () => {
  test("race: a refused middle intent reverts exactly and the later one is rebased", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("append", { doc: "d", text: "1" });
    const middle = store.dispatch("append", { doc: "d", text: "2" });
    store.dispatch("append", { doc: "d", text: "3" });
    calls[0].resolve(null);
    await flush();
    calls[1].reject(new ProtocolError("cmux.doc.read_only", "the file is read only"));
    await flush();
    expect(store.getState().log).toEqual(["1", "3"]);
    expect(calls.length).toBe(3);
    expect(store.errors).toEqual([
      {
        opid: middle,
        kind: "append",
        op: "cmux.doc.append",
        resource: "doc:d",
        code: "cmux.doc.read_only",
        message: "the file is read only",
        params: { doc: "d", text: "2" },
      },
    ]);
    calls[2].resolve(null);
    await flush();
    expect(store.getBase().log).toEqual(["1", "3"]);
    expect(store.status("doc:d")).toBe("refused");
    store.dismissError(middle);
    expect(store.status("doc:d")).toBe("idle");
  });

  test("dependent intents with onPriorRefused cancel are cancelled with their own error", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const first = store.dispatch("appendStrict", { doc: "d", text: "1" });
    const second = store.dispatch("appendStrict", { doc: "d", text: "2" });
    const outcome = store.settledOutcome(second);
    calls[0].reject(new ProtocolError("cmux.doc.conflict", "the file changed on disk"));
    await flush();
    expect(store.getState().log).toEqual([]);
    expect(calls.length).toBe(1);
    expect(store.errors.map((error) => [error.opid, error.code])).toEqual([
      [first, "cmux.doc.conflict"],
      [second, "cmux.intent.cancelled"],
    ]);
    expect((await outcome).status).toBe("cancelled");
  });
});

describe("(f) prefetch", () => {
  test("peek reads a prefetched value synchronously; fetches deduplicate; LRU evicts and aborts", async () => {
    const cache = new PrefetchCache<string>({ limit: 2 });
    let fetches = 0;
    const signals: AbortSignal[] = [];
    const fetch = (value: string) => (signal: AbortSignal) => {
      fetches += 1;
      signals.push(signal);
      return Promise.resolve(value);
    };
    expect(cache.peek("a")).toBeUndefined();
    await Promise.all([cache.prefetch("a", fetch("A")), cache.prefetch("a", fetch("A"))]);
    expect(fetches).toBe(1);
    expect(cache.peek("a")).toBe("A");
    const pendingC = new Promise<string>(() => {});
    void cache.prefetch("b", fetch("B"));
    void cache.prefetch("c", (signal) => {
      signals.push(signal);
      return pendingC;
    });
    await flush();
    // The limit keeps the 2 newest entries: "a" is evicted (and aborted) when "c" arrives.
    expect(cache.size).toBe(2);
    expect(cache.peek("a")).toBeUndefined();
    cache.invalidate("c");
    expect(signals.at(-1)?.aborted).toBe(true);
  });
});

describe("(g) work off the input path", () => {
  test("runChunked yields when a chunk exceeds its budget and stops on abort", async () => {
    let time = 0;
    let yields = 0;
    const controller = new AbortController();
    const done: number[] = [];
    const finished = await runChunked(
      [1, 2, 3, 4, 5, 6],
      (item) => {
        done.push(item);
        time += 5;
        if (item === 4) controller.abort();
      },
      {
        budgetMs: 8,
        now: () => time,
        signal: controller.signal,
        yieldToHost: async () => {
          yields += 1;
        },
      },
    );
    expect(finished).toBe(false);
    expect(done).toEqual([1, 2, 3, 4]);
    expect(yields).toBe(2);
  });
});

describe("(h) by construction", () => {
  test("loading and saving flags are derived from the queue", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    expect(store.status("doc:d")).toBe("idle");
    store.dispatch("append", { doc: "d", text: "1" });
    expect(store.status("doc:d")).toBe("pending");
    calls[0].resolve(null);
    await flush();
    expect(store.status("doc:d")).toBe("idle");
    let answer!: (doc: Doc) => void;
    const loading = store.load(() => new Promise<Doc>((resolve) => (answer = resolve)));
    expect(store.getMeta().loading).toBe(true);
    answer(initial);
    await loading;
    expect(store.getMeta().loading).toBe(false);
  });

  test("race: a slow ack for an older intent after a newer one never loses the newer one", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("setViewed", { path: "a.ts", viewed: true });
    store.dispatch("setViewed", { path: "a.ts", viewed: false });
    expect(store.getState().viewed["a.ts"]).toBe(false);
    calls[0].resolve(null);
    await flush();
    expect(store.getState().viewed["a.ts"]).toBe(false);
    calls[1].resolve(null);
    await flush();
    expect(store.getBase().viewed["a.ts"]).toBe(false);
  });

  test("supersede drops a queued older set; abortSuperseded aborts the one in flight", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    store.dispatch("setPref", { value: "a" });
    const dropped = store.dispatch("setPref", { value: "b" });
    const outcome = store.settledOutcome(dropped);
    store.dispatch("setPref", { value: "c" });
    expect((await outcome).status).toBe("superseded");
    calls[0].resolve(null);
    await flush();
    expect(calls.map((call) => (call.params as { value: string }).value)).toEqual(["a", "c"]);
    store.dispatch("readPref", { value: "x" });
    store.dispatch("readPref", { value: "y" });
    const reads = calls.filter((call) => call.op === "cmux.prefs.read");
    expect(reads.map((call) => call.signal?.aborted)).toEqual([true, false]);
    reads[0].resolve(null);
    await flush();
    expect(store.getState().pref).toBe("y");
  });

  test("a newer load aborts the older one and its answer is ignored", async () => {
    const store = makeStore();
    const signals: AbortSignal[] = [];
    const answers: Array<(doc: Doc) => void> = [];
    const loader = (signal: AbortSignal) => {
      signals.push(signal);
      return new Promise<Doc>((resolve) => answers.push(resolve));
    };
    const older = store.load(loader);
    const newer = store.load(loader);
    expect(signals[0].aborted).toBe(true);
    answers[1]({ ...initial, pref: "new" });
    answers[0]({ ...initial, pref: "old" });
    expect(await older).toBeNull();
    await newer;
    expect(store.getState().pref).toBe("new");
  });

  test("race: a reconnect resends unanswered intents with the same opid, applied once", async () => {
    const ledger = new OpidLedger();
    let applied = 0;
    const serve = (opid: string | undefined) =>
      ledger.run("page-1", opid, () => {
        applied += 1;
        return { applied };
      });
    // The first link applies the call but drops before answering.
    const first: IntentSender = {
      call: (_op, _params, options) =>
        serve(options?.opid).then(() => Promise.reject(new ProtocolError(ProtocolErrorCode.closed, "link lost"))),
    };
    const store = makeStore(first);
    const opid = store.dispatch("append", { doc: "d", text: "1" });
    await flush();
    expect(store.pending()[0].phase).toBe("waiting");
    expect(store.status("doc:d")).toBe("waiting");
    expect(store.getState().log).toEqual(["1"]);
    const seen: Array<string | undefined> = [];
    const second: IntentSender = {
      call: (_op, _params, options) => {
        seen.push(options?.opid);
        return serve(options?.opid);
      },
    };
    store.setSender(second);
    await flush();
    expect(seen).toEqual([opid]);
    expect(applied).toBe(1);
    expect(store.getBase().log).toEqual(["1"]);
  });

  test("a reconnect with an intent still in flight resends it; the old link's answer is ignored", async () => {
    const one = manualSender();
    const two = manualSender();
    const store = makeStore(one.sender);
    const opid = store.dispatch("append", { doc: "d", text: "1" });
    store.setSender(two.sender);
    expect(one.calls[0].signal?.aborted).toBe(true);
    expect(two.calls[0].opid).toBe(opid);
    one.calls[0].reject(new ProtocolError("cmux.doc.read_only", "stale"));
    await flush();
    expect(store.errors).toEqual([]);
    two.calls[0].resolve(null);
    await flush();
    expect(store.getBase().log).toEqual(["1"]);
  });

  test("duplicates: a second event for a settled opid retires nothing; the ledger answers a duplicate call once", async () => {
    const { sender, calls } = manualSender();
    const store = makeStore(sender);
    const opid = store.dispatch("appendEvent", { doc: "d", text: "1" });
    calls[0].resolve(null);
    await flush();
    store.receive((base) => ({ ...base, log: ["1"] }), opid);
    store.dispatch("appendEvent", { doc: "d", text: "2" });
    store.receive((base) => ({ ...base, log: ["1"] }), opid);
    expect(store.getState().log).toEqual(["1", "2"]);
    expect(store.trace().filter((entry) => entry.type === "duplicate").length).toBe(1);
    const ledger = new OpidLedger();
    let runs = 0;
    const answers = await Promise.all([
      ledger.run("p", "x-1", () => ++runs),
      ledger.run("p", "x-1", () => ++runs),
      ledger.run("q", "x-1", () => ++runs),
    ]);
    expect(answers).toEqual([1, 1, 2]);
  });

  test("dispose reverts pending intents and resolves their waiters", async () => {
    const store = makeStore();
    const opid = store.dispatch("append", { doc: "d", text: "1" });
    const outcome = store.settledOutcome(opid);
    store.dispose();
    expect(store.getState().log).toEqual([]);
    expect((await outcome).status).toBe("superseded");
  });

  test("the trace records every step with its opid", async () => {
    const { sender, calls } = manualSender();
    const traced: string[] = [];
    const store = new IntentStore<Doc, typeof kinds>({
      initial,
      kinds,
      sender,
      opidPrefix: "t",
      onTrace: (entry) => traced.push(`${entry.type}:${entry.opid ?? ""}`),
    });
    const opid = store.dispatch("append", { doc: "d", text: "1" });
    calls[0].resolve(null);
    await flush();
    expect(traced).toEqual([`dispatch:${opid}`, `send:${opid}`, `ok:${opid}`]);
  });
});
