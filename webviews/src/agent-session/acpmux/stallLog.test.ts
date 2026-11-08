// A chat whose live events stopped reaching the pane while it stayed connected (user, 2026-10-30,
// session claude-7: prompts on "Still sending" while acpmux had run them, replies missing). A release
// build shows no pane state, so when a send goes slow the pane asks acpmux for the first event after
// the one it holds: one that acpmux wrote a while ago and the pane never got is a stall, and the pane
// says so in the log (console.error reaches the error journal and the unified log in every build).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const settle = async (done: () => boolean, ms = 2_000) => {
  const deadline = performance.now() + ms;
  while (!done()) {
    if (performance.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  return true;
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

async function slowSend(acpmuxAhead: { ageMs: number } | undefined) {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20 });
  const errors: string[] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => void errors.push(args.map(String).join(" "));
  let sessionId = "";
  class Stalled extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "session/prompt") {
          sessionId = params.sessionId;
          return new Promise(() => undefined);
        }
        const result = (await answer(method, params)) as any;
        // acpmux holds events the pane never got (its stream stopped): the next one after the pane's.
        if (method === "_acpmux/events" && acpmuxAhead && params.limit === 1)
          return {
            events: [
              {
                seq: Number(params.afterSeq) + 7,
                sessionId: params.sessionId,
                at: Date.now() - acpmuxAhead.ageMs,
                dir: "in",
                kind: "agent_message_chunk",
                msg: {},
              },
            ],
            hasMore: true,
          };
        return result;
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new Stalled() as unknown as WebSocket,
  );
  try {
    void client.send("anyone there").catch(() => undefined);
    await settle(() => errors.some((line) => line.includes("agent pane stall")), 500);
    return { errors, sessionId };
  } finally {
    console.error = error;
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
}

test("a slow send in a chat whose events stopped reaching the pane logs the stall with the session id", async () => {
  const { errors, sessionId } = await slowSend({ ageMs: 60_000 });
  const line = errors.find((entry) => entry.includes("agent pane stall"));
  expect(line).toBeDefined();
  expect(line).toContain(sessionId);
  expect(line).toMatch(/pane at seq \d+, acpmux at seq \d+/);
});

test("a slow send with nothing missing, or with an event only just written, logs no stall", async () => {
  expect((await slowSend(undefined)).errors.filter((entry) => entry.includes("agent pane stall"))).toEqual([]);
  expect((await slowSend({ ageMs: 100 })).errors.filter((entry) => entry.includes("agent pane stall"))).toEqual([]);
});

/// A socket that stops carrying the chat's events once it goes deaf, while acpmux still answers every
/// request on it: what the pane saw after acpmux was replaced under the app's bridge (#32859). Its
/// `_acpmux/events` read finds the transcript record the pane missed (written a minute ago), or with
/// `rawOnly` only a raw harness line, which acpmux never streams to the pane.
async function stalledStream(options: {
  deafOn: "cancel" | "prompt" | "never";
  rawOnly?: boolean;
  liveBeforeRead?: boolean;
}) {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // The Stop check's wait, shortened (a build without it has none to shorten).
  const stallTiming: { stopMs?: number } =
    ((await import("./stallLog")) as { stallTiming?: { stopMs: number } }).stallTiming ?? {};
  const timing = { ...deliveryTiming };
  const stopTiming = { ...stallTiming };
  Object.assign(deliveryTiming, { slowMs: 20 });
  Object.assign(stallTiming, { stopMs: 30 });
  const errors: string[] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => void errors.push(args.map(String).join(" "));
  const eventReads: any[] = [];
  let sockets = 0;
  class Stalled extends MockAcpmuxSocket {
    deaf = false;
    stop = () => undefined as void;
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as Hooks & { deliver: (message: any) => void };
      const deliver = self.deliver.bind(this);
      self.deliver = (message) => {
        if (this.deaf && message?.id === undefined) return;
        deliver(message);
      };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        const transcript = Array.isArray(params.kinds) && params.kinds.includes("transcript");
        // The stall check's read (every record, or the transcript's); the client's other one-record
        // reads (a turn's opener) go to the mock.
        if (method === "_acpmux/events" && params.limit === 1 && (params.kinds === undefined || transcript)) {
          eventReads.push(params);
          // A slow read: the record it finds came live first (a healthy stream), written long ago.
          if (options.liveBeforeRead) {
            (this as unknown as { emit(target: string, step: unknown): void }).emit(String(params.sessionId), {
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "still here" } },
            });
            return {
              events: [
                {
                  seq: Number(params.afterSeq) + 1,
                  sessionId: params.sessionId,
                  at: Date.now() - 60_000,
                  dir: "in",
                  kind: "agent_message_chunk",
                  msg: {},
                },
              ],
              hasMore: true,
            };
          }
          // A raw line is never in a transcript read; a transcript record is in either.
          if (this.deaf && (options.rawOnly ? !transcript : true))
            return {
              events: [
                {
                  seq: Number(params.afterSeq) + 3,
                  sessionId: params.sessionId,
                  at: Date.now() - 60_000,
                  dir: options.rawOnly ? "out" : "mux",
                  kind: options.rawOnly ? "claude.stdin" : "user_message",
                  msg: {},
                },
              ],
              hasMore: true,
            };
          return { events: [], hasMore: false };
        }
        // A turn that runs until it is stopped: its echo and start, and its end only on Stop.
        if (method === "session/prompt") {
          if (options.deafOn === "prompt") this.deaf = true;
          const target = String(params.sessionId);
          const mock = this as unknown as {
            emit(target: string, step: unknown): void;
            touch(target: string, fields: unknown): void;
          };
          mock.touch(target, { status: "running", indicator: "working" });
          mock.emit(target, {
            mux: "user_message",
            msg: { text: params.prompt?.[0]?.text, promptId: params._meta?.acpmux?.promptId },
          });
          mock.emit(target, { mux: "turn_started" });
          return new Promise(
            (resolve) =>
              (this.stop = () => {
                mock.emit(target, { mux: "turn_result", msg: { status: "cancelled" } });
                mock.touch(target, { status: "idle", indicator: null });
                resolve({ stopReason: "cancelled" });
              }),
          );
        }
        return answer(method, params);
      };
    }
    override send(raw: string): void {
      if (JSON.parse(raw).method === "session/cancel") {
        if (options.deafOn === "cancel") this.deaf = true;
        // A turn that runs on past Stop (it ends after the check).
        if (!options.liveBeforeRead) this.stop();
        return;
      }
      super.send(raw);
    }
    override close(): void {
      super.close();
      (this as unknown as { onclose: null | ((event?: unknown) => void) }).onclose?.({ code: 1000 });
    }
  }
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next: any) => void (next?.type === "snapshot" && (snapshot = next)),
    undefined,
    () => {
      sockets += 1;
      return new Stalled() as unknown as WebSocket;
    },
  );
  return {
    client,
    errors,
    eventReads,
    sockets: () => sockets,
    snapshot: () => snapshot,
    done() {
      console.error = error;
      Object.assign(deliveryTiming, timing);
      Object.assign(stallTiming, stopTiming);
      client.close?.();
    },
  };
}

test("Stop in a chat whose events stopped reaching the pane connects again, and the chat stops stopping", async () => {
  const run = await stalledStream({ deafOn: "cancel" });
  try {
    void run.client.send("long job").catch(() => undefined);
    expect(await settle(() => run.snapshot()?.isWorking === true, 10_000)).toBe(true);
    await run.client.cancel();
    expect(run.snapshot()?.stopping).toBe(true);
    expect(await settle(() => run.sockets() > 1, 10_000)).toBe(true);
    expect(await settle(() => run.snapshot()?.connection === "connected" && run.snapshot()?.stopping !== true)).toBe(
      true,
    );
    expect(run.errors.some((line) => line.includes("agent pane stall") && line.includes("a Stop has not ended"))).toBe(
      true,
    );
    expect(run.eventReads.every((read) => Array.isArray(read.kinds) && read.kinds.includes("transcript"))).toBe(true);
    // One reconnect: the new connection carries the events, so nothing checks or drops it again.
    expect(run.sockets()).toBe(2);
  } finally {
    run.done();
  }
});

test("a send whose echo never reaches the pane connects again, so the chat catches up", async () => {
  const run = await stalledStream({ deafOn: "prompt" });
  try {
    void run.client.send("anyone there").catch(() => undefined);
    expect(await settle(() => run.sockets() > 1, 10_000)).toBe(true);
  } finally {
    run.done();
  }
});

test("acpmux holding only raw harness lines past the pane is no stall: the pane keeps its connection", async () => {
  const run = await stalledStream({ deafOn: "cancel", rawOnly: true });
  try {
    void run.client.send("long job").catch(() => undefined);
    expect(await settle(() => run.snapshot()?.isWorking === true, 10_000)).toBe(true);
    await run.client.cancel();
    expect(await settle(() => run.eventReads.length > 0)).toBe(true);
    // The read's reply and the client's handling of it are microtasks: a few turns of the loop end them.
    for (let turn = 0; turn < 3; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(run.sockets()).toBe(1);
    expect(run.errors.filter((line) => line.includes("agent pane stall"))).toEqual([]);
  } finally {
    run.done();
  }
});

test("a slow stall read whose record already came live keeps the connection: the stream works", async () => {
  const run = await stalledStream({ deafOn: "never", liveBeforeRead: true });
  try {
    void run.client.send("long job").catch(() => undefined);
    expect(await settle(() => run.snapshot()?.isWorking === true, 10_000)).toBe(true);
    await run.client.cancel();
    expect(await settle(() => run.eventReads.length > 0)).toBe(true);
    // The read's reply and the client's handling of it are microtasks: a few turns of the loop end them.
    for (let turn = 0; turn < 3; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(run.sockets()).toBe(1);
    expect(run.errors.filter((line) => line.includes("agent pane stall"))).toEqual([]);
  } finally {
    run.done();
  }
});

test("a Stop whose check came due while the pane was hidden runs it once the pane shows, and the chat stops stopping", async () => {
  const run = await stalledStream({ deafOn: "cancel" });
  const visibility = Object.getOwnPropertyDescriptor(dom.window.document, "visibilityState");
  let state: "hidden" | "visible" = "visible";
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => state });
  try {
    void run.client.send("long job").catch(() => undefined);
    expect(await settle(() => run.snapshot()?.isWorking === true, 10_000)).toBe(true);
    await run.client.cancel();
    state = "hidden";
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    // The check comes due (30 ms) while hidden: it is owed, nothing ran, the pane keeps its connection.
    expect(await settle(() => (run.client as unknown as { stopStallOwed?: string }).stopStallOwed !== undefined)).toBe(
      true,
    );
    expect(run.sockets()).toBe(1);
    expect(run.snapshot()?.stopping).toBe(true);
    state = "visible";
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    expect(await settle(() => run.sockets() > 1, 10_000)).toBe(true);
    expect(await settle(() => run.snapshot()?.connection === "connected" && run.snapshot()?.stopping !== true)).toBe(
      true,
    );
  } finally {
    if (visibility) Object.defineProperty(dom.window.document, "visibilityState", visibility);
    else delete (dom.window.document as unknown as Record<string, unknown>).visibilityState;
    run.done();
  }
});
