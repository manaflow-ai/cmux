// A chat whose stream stops while its socket stays open must fix itself (Leo, 2026-11-08: "we need
// to have, like, better automatic recovery as well. And I don't mean rollback. I mean, like, it
// fixes itself."). After an app restart the local acpmux kept the chat's replies, but the pane's
// socket carried none of them and nothing noticed for 30 minutes: no close, no lag notice, and no
// send or Stop to start the stall check. Here the mock daemon's store keeps adding turns while the
// pane's socket goes deaf, the first reconnect is refused and the next handshake answers slowly;
// the pane must say it is reconnecting, then show every turn exactly once, on its own.
import { afterAll, afterEach, beforeAll, expect, jest, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { HostRecoveringLine } from "./HostError";
import { RECONNECT_LINE_AFTER_MS, hostRecoveryLine, readHostRestoring } from "./hostRetry";
import type { AcpmuxSnapshot } from "./model";
import { stallTiming } from "./stallLog";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
// The page's timers are the test's fake ones (the client's reconnect uses `window.setTimeout`).
Object.assign(dom.window, {
  setTimeout: (handler: () => void, ms?: number) => setTimeout(handler, ms),
  clearTimeout: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
});
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
const timing = { ...stallTiming };
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});
afterEach(() => {
  Object.assign(stallTiming, timing);
  jest.useRealTimers();
  setSystemTime();
});

type Step = { update: Record<string, unknown> } | { mux: string; msg?: Record<string, unknown> };
type MockInternals = {
  emit(target: string, step: Step, at?: number): void;
  touch(target: string, fields: Record<string, unknown>, moved?: boolean): void;
  deliver(message: unknown): void;
  answer(method: string, params: Record<string, unknown>): Promise<unknown>;
};

/// One acpmux store behind every socket the pane opens, as one daemon serves every connection.
type Store = { events: unknown[]; sessions: unknown[]; seq: number; live?: MockInternals & { deaf: boolean } };

/// Lets the microtasks a timer queued (the mock's replies, the client's handling of them) run.
async function settle(): Promise<void> {
  for (let index = 0; index < 30; index++) await Promise.resolve();
}

/// The test's clock: fake timers and `Date.now` move together.
function clock(start: number) {
  let now = start;
  setSystemTime(new Date(now));
  return {
    now: () => now,
    async advance(ms: number) {
      now += ms;
      jest.advanceTimersByTime(ms);
      setSystemTime(new Date(now));
      await settle();
    },
  };
}

/// Sockets to the shared store: the first stays open but goes deaf when told (replies still come,
/// records and notices never do), the second is refused, the third answers its handshake only after
/// `slowHandshakeMs` (a host busy restoring), and every later one is healthy.
async function harness(options: { slowHandshakeMs: number }) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  const target = mockHost.sessionId!;
  forgetTail(target);
  const store: Store = { events: [], sessions: [], seq: 0 };
  let opened = 0;
  class SharedSocket extends MockAcpmuxSocket {
    deaf = false;
    constructor(slowMs: number) {
      super(() => Promise.resolve());
      const self = this as unknown as MockInternals & Record<string, unknown>;
      if (store.events.length === 0 && store.seq === 0) {
        store.events = self.events as unknown[];
        store.sessions = self.sessions as unknown[];
        store.seq = self.seq as number;
      }
      for (const key of ["events", "sessions", "seq"] as const)
        Object.defineProperty(this, key, {
          configurable: true,
          get: () => store[key],
          set: (value) => void ((store as Record<string, unknown>)[key] = value),
        });
      const deliver = self.deliver.bind(this);
      self.deliver = (message: unknown) => {
        if (this.deaf && (message as { id?: unknown } | null)?.id === undefined) return;
        deliver(message);
      };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        // fixed-wait: a host slow to answer its handshake is the behavior; the test's fake clock moves it.
        if (method === "initialize" && slowMs > 0) await new Promise((resolve) => setTimeout(resolve, slowMs));
        return answer(method, params);
      };
      store.live = this as unknown as MockInternals & { deaf: boolean };
    }
  }
  /// A connection the host refuses: it errors before it opens.
  class RefusedSocket {
    readyState = 0;
    onopen: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onclose: ((event?: unknown) => void) | null = null;
    onmessage: ((message: { data: string }) => void) | null = null;
    constructor() {
      setTimeout(() => {
        this.readyState = 3;
        this.onerror?.();
        this.onclose?.({ code: 1006, reason: "", wasClean: false });
      }, 0);
    }
    send(): void {}
    close(): void {}
  }
  let snapshot: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => void (snapshot = next),
    undefined,
    () => {
      opened += 1;
      if (opened === 2) return new RefusedSocket() as unknown as WebSocket;
      return new SharedSocket(opened === 3 ? options.slowHandshakeMs : 0) as unknown as WebSocket;
    },
  );
  const live = () => store.live!;
  /// Turn `k` as acpmux records it: the prompt, its start, the reply, its end; the chat runs on.
  const produce = (k: number, thoughts = 0) => {
    live().emit(target, { mux: "user_message", msg: { text: `ask-${k}`, promptId: `p-${k}` } });
    live().emit(target, { mux: "turn_started" });
    // A long turn's many records: more than the attach's page, so the reconnect reads a gap too.
    for (let index = 0; index < thoughts; index++)
      live().emit(target, {
        update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "." } },
      });
    live().emit(target, {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `answer-${k}.` } },
    });
    live().emit(target, { mux: "turn_result", msg: { status: "completed" } });
    live().touch(target, { status: "running", indicator: "working" });
  };
  /// How many times each turn's reply shows in the transcript.
  const shown = (turns: number[]) =>
    turns.map((k) =>
      (snapshot?.rows ?? []).reduce((sum, row) => sum + (row.text?.split(`answer-${k}.`).length ?? 1) - 1, 0),
    );
  return { client, target, live, produce, shown, snapshot: () => snapshot, sockets: () => opened };
}

/// The scenario: a working chat, its socket goes deaf, acpmux adds four turns, two more after the
/// pane is back. Returns when every turn shows, or after `limitMs` of the test's clock.
async function wedgedChat(limitMs: number) {
  jest.useFakeTimers();
  const time = clock(Date.UTC(2026, 10, 8, 12, 0, 0));
  const run = await harness({ slowHandshakeMs: 12_000 });
  const { target, live, produce, shown } = run;
  const turns = [1, 2, 3, 4, 5, 6];
  try {
    // The chat runs a turn, and the pane hears it start.
    live().touch(target, { status: "running", indicator: "working" });
    live().emit(target, { mux: "user_message", msg: { text: "ask-0", promptId: "p-0" } });
    live().emit(target, { mux: "turn_started" });
    await time.advance(100);
    expect(run.snapshot()?.isWorking).toBe(true);
    // The socket stays open but carries nothing more of the chat.
    live().deaf = true;
    const deafAt = time.now();
    let missedAt: number | undefined;
    let recoveredAt: number | undefined;
    let lostAt: number | undefined;
    let lineWhileWedged: string | undefined;
    const due = new Map([
      [1_000, 1],
      [3_000, 2],
      [5_000, 3],
      [7_000, 4],
    ]);
    let later = 5;
    while (time.now() - deafAt < limitMs) {
      const turn = due.get(time.now() - deafAt);
      if (turn !== undefined) {
        produce(turn, turn === 2 ? 420 : 0);
        missedAt ??= time.now();
      }
      await time.advance(100);
      // The pane gave the deaf socket up and connects again (App.tsx's line counts from here).
      if (recoveredAt === undefined && lostAt === undefined && run.sockets() > 1) lostAt = time.now();
      // What the pane's line says while it gets the chat back (App.tsx counts from its lost link).
      if (lostAt !== undefined && recoveredAt === undefined && time.now() - lostAt >= RECONNECT_LINE_AFTER_MS)
        lineWhileWedged ??= renderToStaticMarkup(<HostRecoveringLine relinkingSince={lostAt} now={time.now()} />);
      if (recoveredAt === undefined && shown([1])[0]! > 0) recoveredAt = time.now();
      // Back: acpmux's next turns come live on the new connection.
      if (recoveredAt !== undefined && later <= 6 && time.now() - recoveredAt >= (later - 4) * 1_000) produce(later++);
      if (recoveredAt !== undefined && later > 6 && shown(turns).every((count) => count > 0)) break;
    }
    const counts = shown(turns);
    return {
      recovered: recoveredAt !== undefined,
      timeToRecoverMs: recoveredAt !== undefined && missedAt !== undefined ? recoveredAt - missedAt : undefined,
      missed: counts.filter((count) => count === 0).length,
      duplicates: counts.reduce((sum, count) => sum + Math.max(0, count - 1), 0),
      lineWhileWedged,
      sockets: run.sockets(),
    };
  } finally {
    run.client.close();
  }
}

test("a working chat whose stream stops while its socket stays open gets every turn back on its own, once each", async () => {
  const result = await wedgedChat(10 * 60_000);
  console.log(
    `SELF_HEAL_PROBE web time_to_recover_ms=${result.timeToRecoverMs ?? -1} missed_turns=${result.missed} duplicate_turns=${result.duplicates}`,
  );
  expect(result.recovered).toBe(true);
  expect(result.missed).toBe(0);
  expect(result.duplicates).toBe(0);
  // Quiet 20 s, the check, a refused reconnect, then a 12 s handshake: well under a minute.
  expect(result.timeToRecoverMs!).toBeLessThan(60_000);
  // While it came back the pane said so, quietly.
  expect(result.lineWhileWedged).toContain("Reconnecting…");
  expect(result.lineWhileWedged).toContain('data-host-recovering="reconnecting"');
  // The deaf socket, the refused one, the slow one: no reconnect loop after it is back.
  expect(result.sockets).toBe(3);
});

test("before the quiet watch, the same chat never showed the missed turns (10 minutes of test clock)", async () => {
  // The quiet watch off: what the pane did before (no send or Stop, so no stall check ran).
  Object.assign(stallTiming, { quietChecks: 0 });
  const result = await wedgedChat(10 * 60_000);
  console.log(
    `SELF_HEAL_PROBE_BEFORE web recovered=${result.recovered} waited_ms=${10 * 60_000} missed_turns=${result.missed}`,
  );
  expect(result.recovered).toBe(false);
  expect(result.sockets).toBe(1);
});

test("an idle chat whose stream stopped catches up when its page is shown again", async () => {
  jest.useFakeTimers();
  const time = clock(Date.UTC(2026, 10, 8, 13, 0, 0));
  const run = await harness({ slowHandshakeMs: 0 });
  try {
    await time.advance(100);
    run.live().deaf = true;
    // A prompt sent from another tab runs a turn this pane never hears of.
    run.produce(1);
    run.live().touch(run.target, { status: "idle", indicator: "done" });
    await time.advance(60_000);
    // Idle as far as the pane knows: it watches nothing, and asks nothing on its own.
    expect(run.shown([1])).toEqual([0]);
    expect(run.sockets()).toBe(1);
    // The tab is switched back to: the page is shown again.
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    for (let step = 0; step < 100 && run.shown([1])[0] === 0; step++) await time.advance(100);
    expect(run.shown([1])).toEqual([1]);
  } finally {
    run.client.close();
  }
});

test("a quiet working chat whose acpmux holds nothing newer keeps its connection, and the checks back off", async () => {
  jest.useFakeTimers();
  const time = clock(Date.UTC(2026, 10, 8, 14, 0, 0));
  const run = await harness({ slowHandshakeMs: 0 });
  try {
    run.live().touch(run.target, { status: "running", indicator: "working" });
    run.live().emit(run.target, { mux: "turn_started" });
    await time.advance(100);
    // The model thinks for half an hour without a word; the stream is fine. The clock moves a
    // second at a time, so acpmux's answers (microtasks) land between timers as they do in a page:
    // one 30-minute jump would fire the request's liveness timers before its answer could arrive.
    for (let second = 0; second < 30 * 60; second++) await time.advance(1_000);
    expect(run.sockets()).toBe(1);
  } finally {
    run.client.close();
  }
});

test("the host's restore status reads as a quiet line with its elapsed time", () => {
  expect(readHostRestoring({ restoring: { waitedMs: 12_000 } }, 5)).toEqual({ waitedMs: 12_000, at: 5 });
  expect(readHostRestoring({ restoring: null }, 5)).toBeUndefined();
  expect(readHostRestoring({ restoring: { waitedMs: "soon" } }, 5)).toBeUndefined();
  expect(readHostRestoring(undefined, 5)).toBeUndefined();
  const restoring = { waitedMs: 12_000, at: 1_000 };
  expect(hostRecoveryLine({ restoring, now: 4_000 })).toEqual({ kind: "restoring", waitedMs: 15_000 });
  expect(renderToStaticMarkup(<HostRecoveringLine restoring={restoring} now={4_000} />)).toContain(
    "Restoring sessions… 0:15",
  );
  // A lost link says nothing for its first moment, and leaves the line to the failure past 25 s.
  expect(hostRecoveryLine({ relinkingSince: 0, now: 500 })).toBeUndefined();
  expect(hostRecoveryLine({ relinkingSince: 0, now: 2_000 })).toEqual({ kind: "reconnecting" });
  expect(hostRecoveryLine({ relinkingSince: 0, now: 30_000 })).toBeUndefined();
});
