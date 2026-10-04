import { describe, expect, test } from "bun:test";
import { MockHistoryProvider, sampleEntries } from "./mockProvider";
import { HistoryStore } from "./store";
import { ACTION_RUN, CLIPBOARD_WRITE, HistoryOps, type HistoryEntry } from "./types";

const now = new Date(2026, 9, 4, 12, 0, 0).getTime();

function setup(entries: HistoryEntry[] = sampleEntries(now)) {
  const provider = new MockHistoryProvider(entries, () => now);
  let keys = 0;
  const store = new HistoryStore(provider, { newKey: () => `k${++keys}` });
  return { provider, store };
}

async function started(entries?: HistoryEntry[]) {
  const ctx = setup(entries);
  const unsubscribe = ctx.store.subscribe(() => undefined);
  await ctx.store.start();
  await settle();
  return { ...ctx, unsubscribe };
}

/** Lets queued promise callbacks run. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("HistoryStore", () => {
  test("first subscriber subscribes to changes and loads the newest entries", async () => {
    const { provider, store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.loading).toBe(false);
    expect(snap.entries.length).toBe(sampleEntries(now).length);
    expect(snap.entries[0].id).toBe("page:default:1");
    expect(provider.subscriberCount).toBe(1);
    expect(provider.calls[0]).toEqual({ op: HistoryOps.list, params: { kinds: [], text: "", limit: 1000 } });
  });

  test("the last unsubscribe stops the change subscription", async () => {
    const { provider, unsubscribe } = await started();
    unsubscribe();
    expect(provider.subscriberCount).toBe(0);
  });

  test("filter and text become the list params; grouping needs no reload", async () => {
    const { provider, store } = await started();
    store.setFilter("agents");
    await settle();
    expect(store.getSnapshot().entries.every((e) => e.kind === "agent")).toBe(true);
    store.setText("codex");
    await settle();
    expect(provider.calls.at(-1)).toEqual({
      op: HistoryOps.list,
      params: { kinds: ["agent"], text: "codex", limit: 1000 },
    });
    expect(store.getSnapshot().entries.map((e) => e.id)).toEqual(["agent:mini:s2"]);
    const calls = provider.calls.length;
    store.setGrouping("machine");
    expect(provider.calls.length).toBe(calls);
    expect(store.getSnapshot().groups.map((g) => g.name)).toEqual(["build-mini"]);
  });

  test("search folds case and diacritics", async () => {
    const { store } = await started();
    store.setText("RESUME");
    await settle();
    expect(store.getSnapshot().entries.map((e) => e.title)).toEqual(["Résumé draft"]);
  });

  test("a late reply for an older query never replaces a newer one", async () => {
    const { provider, store } = await started();
    const slow = provider.call.bind(provider);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    let first = true;
    provider.call = async (op, params) => {
      if (op === HistoryOps.list && first) {
        first = false;
        await gate;
      }
      return slow(op, params);
    };
    store.setText("github");
    store.setText("rust");
    await settle();
    release();
    await settle();
    expect(store.getSnapshot().entries.map((e) => e.id)).toEqual(["page:default:2"]);
  });

  test("a change event from the owner re-reads", async () => {
    const { provider, store } = await started();
    provider.push({ id: "page:default:new", kind: "page", at_ms: now + 1, title: "New", available: true });
    await settle();
    expect(store.getSnapshot().entries[0].id).toBe("page:default:new");
  });

  test("remove sends the id with an idempotency key, then shows the owner's state", async () => {
    const { provider, store } = await started();
    const target = store.getSnapshot().entries[1];
    store.select(target.id);
    await store.remove(target);
    expect(provider.calls.find((c) => c.op === HistoryOps.remove)?.params).toEqual({
      ids: [target.id],
      idempotency_key: "k1",
    });
    const snap = store.getSnapshot();
    expect(snap.entries.some((e) => e.id === target.id)).toBe(false);
    expect(snap.selection).toBe(snap.entries[0].id);
  });

  test("remove site sends the host and profile; clear sends the range", async () => {
    const { provider, store } = await started();
    const github = store.getSnapshot().entries.find((e) => e.id === "page:default:3")!;
    await store.removeSite(github);
    expect(provider.calls.find((c) => c.op === HistoryOps.removeSite)?.params).toEqual({
      host: "github.com",
      profile: "default",
      idempotency_key: "k1",
    });
    expect(store.getSnapshot().entries.some((e) => e.url?.startsWith("https://github.com"))).toBe(false);
    await store.clear("today");
    expect(provider.calls.find((c) => c.op === HistoryOps.clear)?.params).toEqual({
      range: "today",
      idempotency_key: "k2",
    });
    expect(store.getSnapshot().entries.every((e) => e.at_ms < new Date(2026, 9, 4).getTime())).toBe(true);
  });

  test("open runs the app's history.open action with the entry id", async () => {
    const { provider, store } = await started();
    const entry = store.getSnapshot().entries[0];
    await store.open(entry, true);
    expect(provider.calls.at(-1)).toEqual({
      op: ACTION_RUN,
      params: { action: "history.open", args: { id: entry.id, new_tab: true } },
    });
  });

  test("copy uses the page clipboard, and the host op when that fails", async () => {
    const provider = new MockHistoryProvider([], () => now);
    const written: string[] = [];
    const ok = new HistoryStore(provider, { writeClipboard: async (text) => void written.push(text) });
    await ok.copy("a");
    expect(written).toEqual(["a"]);
    expect(provider.calls.some((c) => c.op === CLIPBOARD_WRITE)).toBe(false);
    const failing = new HistoryStore(provider, { writeClipboard: async () => Promise.reject(new Error("denied")) });
    await failing.copy("b");
    expect(provider.calls.at(-1)).toEqual({ op: CLIPBOARD_WRITE, params: { text: "b" } });
  });

  test("an owner without the change stream still lists, without live updates", async () => {
    const provider = new MockHistoryProvider(sampleEntries(now), () => now);
    provider.subscribe = async () => {
      throw Object.assign(new Error("cmux.history.changed"), { code: "cmux.protocol.unknown_op", retryable: false });
    };
    const store = new HistoryStore(provider);
    store.subscribe(() => undefined);
    await store.start();
    await settle();
    expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
    expect(store.getSnapshot().entries.length).toBe(sampleEntries(now).length);
  });

  test("no client: disconnected and nothing is sent", async () => {
    const store = new HistoryStore(null);
    store.subscribe(() => undefined);
    await store.start();
    expect(store.getSnapshot()).toMatchObject({ connection: "disconnected", loading: false });
  });

  test("a lost host shows disconnected; the next success clears it", async () => {
    const { provider, store } = await started();
    provider.offline = true;
    await store.reload();
    expect(store.getSnapshot().connection).toBe("disconnected");
    provider.offline = false;
    await store.reload();
    expect(store.getSnapshot()).toMatchObject({ connection: "connected", error: undefined });
  });
});
