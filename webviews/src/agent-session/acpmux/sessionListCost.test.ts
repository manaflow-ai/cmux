// l10n-allow-file: test fixtures.
// What the agent pane reads of the session list costs the same at any list size (Leo, 2026-11-04:
// "never ... acceptable ... linear time growth degradation"). A trace on a Mac with about 10,000
// chats saw one pane receive 217 session-list replies of about 1 MB in 7.7 min: every pane mount
// read every page, a chat linked past the first page read the whole list, and a missing chat or a
// lagged watch read it again. Here a stand-in acpmux with `session-list-follow-v1` lists 1,000 and
// then 10,000 chats, and the bytes of its list replies (`_acpmux/watch`, `_acpmux/sessions`,
// `_acpmux/resolve`) are counted for a pane mount, a second mount in the same page, a lagged watch
// and a lookup of one chat older than the first page. Each must cost what it costs at 1,000.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.cmuxAcpmuxMockCapabilities = ["session-list-follow-v1"];
});
afterAll(async () => {
  delete scope.cmuxAcpmuxMockCapabilities;
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const turns = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const LISTS = new Set(["_acpmux/watch", "_acpmux/sessions", "_acpmux/resolve", "_acpmux/info"]);

type Row = Record<string, unknown> & { sessionId: string; updatedAt: number };

/// acpmux's list as a row log (hub/row_log.rs): rows newest first, each with the `listSeq` it last
/// changed at; a watch with `afterSeq` in the same epoch answers only the rows changed since.
class ListDaemon {
  rows: Row[];
  private changedAt = new Map<string, number>();
  seq = 1;
  readonly epoch = "e1";
  constructor(own: Row[], count: number) {
    const filler = Array.from({ length: count }, (_, n) => ({
      sessionId: `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`,
      name: `chat-${n}`,
      title: `Chat ${n} about the build`,
      cwd: `/Users/me/code/project-${n % 40}`,
      harness: "claude",
      family: "claude",
      status: "idle",
      createdAt: 1_000_000 - n,
      updatedAt: 1_000_000 - n,
      lastSeq: 3,
    }));
    this.rows = [...own, ...filler];
    for (const row of this.rows) this.changedAt.set(row.sessionId, 1);
  }
  answer(method: string, params: Record<string, any>): unknown {
    if (method === "_acpmux/resolve" || method === "_acpmux/info") {
      const query = String(params.query ?? params.sessionId ?? "");
      const row = this.rows.find((r) => r.sessionId === query || r.name === query);
      if (!row) throw Object.assign(new Error(`no session ${query}`), { code: -32001 });
      return { session: { ...row, host: null, peer: null, link: null }, matches: [row], link: null };
    }
    const at = { listSeq: this.seq, listEpoch: this.epoch };
    if (method === "_acpmux/watch" && typeof params.afterSeq === "number" && params.listEpoch === this.epoch) {
      const changed = this.rows.filter((row) => (this.changedAt.get(row.sessionId) ?? 0) > params.afterSeq);
      return { follow: true, ...at, more: false, gone: [], sessions: changed };
    }
    if (params.limit === undefined) return { sessions: this.rows, ...at };
    const start = typeof params.cursor === "string" ? Number(params.cursor.slice(1)) : 0;
    const page = this.rows.slice(start, start + Number(params.limit));
    const end = start + page.length;
    return { sessions: page, nextCursor: end < this.rows.length ? `o${end}` : null, ...at };
  }
}

/// A page whose pane connects to the mock daemon, with its session list served by a `ListDaemon`
/// of `count` chats, counting the bytes of every list reply.
async function page(count: number) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // A page of its own: nothing held from the size before (sessionPages.ts `heldLists`).
  (
    (await import("./sessionPages")) as {
      forgetHeldLists?: () => void;
    }
  ).forgetHeldLists?.();
  let daemon: ListDaemon | undefined;
  let bytes = 0;
  let inflight = 0;
  let asked = 0;
  const sockets: InstanceType<typeof MockAcpmuxSocket>[] = [];
  async function connect(host: Record<string, unknown> = {}) {
    const socket = new MockAcpmuxSocket(() => Promise.resolve());
    await turns();
    sockets.push(socket);
    const raw = socket as unknown as {
      send: (raw: string) => void;
      onopen: (() => void) | null;
      onmessage: ((message: { data: string }) => void) | null;
      sessions: Row[];
    };
    daemon ??= new ListDaemon(raw.sessions, count);
    const passOn = raw.send.bind(socket);
    raw.send = (text) => {
      const request = JSON.parse(text) as { id?: number; method: string; params?: Record<string, any> };
      if (request.id === undefined || !LISTS.has(request.method)) return passOn(text);
      inflight += 1;
      asked += 1;
      setTimeout(() => {
        let reply: string;
        try {
          reply = JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            result: daemon!.answer(request.method, request.params ?? {}),
          });
        } catch (error) {
          const message = (error as Error).message;
          reply = JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: -32001, message } });
        }
        bytes += reply.length;
        inflight -= 1;
        raw.onmessage?.({ data: reply });
      }, 0);
    };
    let last: { listedSessions?: boolean; sessions?: unknown[]; sessionId?: string } = {};
    const client = await AcpmuxDirectClient.connect(
      { ...mockHost, ...host },
      (snapshot) => {
        last = snapshot as typeof last;
      },
      undefined,
      () => {
        queueMicrotask(() => raw.onopen?.());
        return socket as unknown as WebSocket;
      },
    );
    return {
      client,
      state: () => last,
      notify: (method: string, params: Record<string, unknown>) =>
        raw.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) }),
    };
  }
  /// Every list reply asked so far has come, and nothing more was asked for a while.
  async function quiet() {
    let still = 0;
    let seen = -1;
    for (let round = 0; round < 20_000 && still < 50; round += 1) {
      await turns();
      if (inflight === 0 && asked === seen) still += 1;
      else still = 0;
      seen = asked;
    }
  }
  /// The list bytes `run` costs once it and everything it led to are done.
  async function cost(run: () => Promise<unknown>): Promise<number> {
    await quiet();
    const before = bytes;
    await run();
    await quiet();
    return bytes - before;
  }
  return { connect, cost, daemon: () => daemon!, close: () => sockets.forEach((s) => s.close()) };
}

type Costs = { mount: number; secondMount: number; lagged: number; oldChat: number };

async function costs(count: number): Promise<Costs> {
  const at = await page(count);
  let first: Awaited<ReturnType<typeof at.connect>> | undefined;
  const mount = await at.cost(async () => {
    first = await at.connect();
  });
  // Another pane client in the same page (a reconnect makes a new one): it follows the list held.
  first!.client.close();
  let second: Awaited<ReturnType<typeof at.connect>> | undefined;
  const secondMount = await at.cost(async () => {
    second = await at.connect();
  });
  // The watch dropped notices: the pane reads what changed since its cursor.
  const lagged = await at.cost(async () => second!.notify("_acpmux/lagged", { watch: true, dropped: 3 }));
  second!.client.close();
  // A tab linked to a chat far past the first page.
  const old = at.daemon().rows[Math.floor(count * 0.9)]!.sessionId;
  let linked: Awaited<ReturnType<typeof at.connect>> | undefined;
  const oldChat = await at.cost(async () => {
    linked = await at.connect({ sessionId: old, sessionMustExist: true }).catch(() => undefined);
  });
  linked?.client.close();
  at.close();
  return { mount, secondMount, lagged, oldChat };
}

test("a pane mount, a second mount, a lagged watch and one old chat cost the same at 10,000 chats as at 1,000", async () => {
  const small = await costs(1_000);
  const large = await costs(10_000);
  const kb = (n: number) => `${(n / 1024).toFixed(1)} KB`;
  for (const key of ["mount", "secondMount", "lagged", "oldChat"] as const)
    console.log(`session list bytes, ${key}: ${kb(small[key])} at 1,000 chats, ${kb(large[key])} at 10,000`);
  for (const key of ["mount", "secondMount", "lagged", "oldChat"] as const)
    // Flat: what 10x the chats adds is at most a fifth more (a resolve's card, a longer cursor).
    expect(large[key]).toBeLessThanOrEqual(small[key] * 1.2 + 2048);
  // And bounded by what the pane shows: the first page, not the list.
  expect(large.mount).toBeLessThan(200 * 1024);
}, 120_000);
