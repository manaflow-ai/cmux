// A chat drawn from the row store (rows/chatSource.ts) takes its v1 attach as the hold
// (rows/holdKinds.ts): only page-state kinds stream on it (usage, status, commands, config), and
// none of them is a row. They must not pile up in the client's transcript log (`events`) or in the
// records held for a copy's check (`copyLive`): a chat left open for hours streams a usage or
// status record per step, and every chat page shares one renderer.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { listenForChatRows, resetChatRowsReceiver } from "./rows/receiver";
import type { Lanes } from "./schedule";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.cmuxAcpmuxMockCapabilities = ["attach-hold-v1"];
});
afterAll(async () => {
  resetChatRowsReceiver();
  delete scope.cmuxAcpmuxMockCapabilities;
  (await import("./native")).setNativeHost(undefined);
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});
beforeEach(() => {
  const slice = { timeLeft: () => Number.POSITIVE_INFINITY, shouldYield: () => false };
  const lanes: Lanes = {
    frame: (_key, fn) => void fn(slice),
    idle: (_key, fn) => void fn(slice),
    inputPending: () => false,
    yield: () => Promise.resolve(),
    flush: () => {},
    dispose: () => {},
  };
  listenForChatRows(lanes);
});

const settle = async (done: () => boolean) => {
  // timeout: a mock daemon and host answer in microtasks; past 2 s a wait names what it waited on, not a hang.
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

test("a held chat's streamed page-state records stay bounded however many arrive", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const a = mockSessions[0]!.sessionId;
  let attached = false;
  setNativeHost(async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : null));
  let socket: any;
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method !== "_acpmux/attach" || params.hold !== true) return answer(method, params);
        const page = (await answer(method, { sessionId: params.sessionId })) as any;
        attached = true;
        return { session: page.session, lastSeq: page.lastSeq, presence: {}, readThrough: null, hold: true };
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    () => {},
    undefined,
    () => new Held() as unknown as WebSocket,
  );
  const direct = client as any;
  try {
    await settle(() => attached && direct.attachedGeneration !== undefined);
    expect(direct.chatRows.holds(a)).toBe(true);
    // A day of a working chat's page-state stream: usage after every step, a status now and then,
    // and the harness's command list and config sent again (each a few KB).
    const commands = Array.from({ length: 40 }, (_, n) => ({ name: `command-${n}`, description: "x".repeat(80) }));
    let seq = direct.lastSeq as number;
    const push = (kind: string, update: Record<string, unknown>) =>
      socket.onmessage({
        data: JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/event",
          params: {
            sessionId: a,
            seq: ++seq,
            at: Date.now(),
            dir: "in",
            kind,
            msg: { method: "session/update", params: { sessionId: a, update: { sessionUpdate: kind, ...update } } },
          },
        }),
      });
    const N = 20_000;
    for (let index = 0; index < N; index++) {
      push("usage_update", { used: 1000 + index, size: 200_000 });
      if (index % 10 === 0) push("available_commands_update", { availableCommands: commands });
      if (index % 25 === 0) push("session_info_update", { title: `Step ${index}` });
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
    const held = direct.events.length as number;
    const live = (direct.copyLive?.size ?? 0) as number;
    console.log(`after ${N} steps: events=${held} copyLive=${live} lastSeq=${direct.lastSeq}`);
    // The newest few of each kind stay (`HOLD_RECORDS_PER_KIND`), whatever N is, and the page state
    // is still the newest record's.
    const { HOLD_RECORDS_PER_KIND } = await import("./rows/holdKinds");
    expect(held).toBeLessThanOrEqual(3 * HOLD_RECORDS_PER_KIND);
    expect(live).toBeLessThanOrEqual(3 * HOLD_RECORDS_PER_KIND);
    const kinds = new Map<string, number>();
    for (const event of direct.events as { kind: string }[]) kinds.set(event.kind, (kinds.get(event.kind) ?? 0) + 1);
    expect(Object.fromEntries(kinds)).toEqual({
      usage_update: HOLD_RECORDS_PER_KIND,
      available_commands_update: HOLD_RECORDS_PER_KIND,
      session_info_update: HOLD_RECORDS_PER_KIND,
    });
    const seqs = (direct.events as { seq: number }[]).map((event) => event.seq);
    expect(seqs).toEqual([...seqs].sort((left, right) => left - right));
    expect(direct.usage).toMatchObject({ used: 1000 + N - 1, size: 200_000 });
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});
