// A page never meets acpmux's per-connection work limit from its own requests (requestBudget.ts).
// Leo, 2026-10-29, with "connection request limit reached" above the composer: "i dont fucking know
// why the cmux next app is fuckign chugging along". The daemon here answers at most 64 work requests
// of the connection at a time and refuses the next with `connection.busy`, like acpmux
// (`REQUEST_WORK_LIMIT`); a request the page stopped waiting for keeps its slot until it is answered.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { BUSY_MAX_MS, busyDelay, countsAgainstBudget, RequestBudget, WORK_LIMIT, waitsForSlot } from "./requestBudget";
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
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const DAEMON_LIMIT = 64;
/// A read: the requests that wait for a slot.
const PROBE = "_acpmux/events";
/// A click-authorized answer: the native host passes it only on a fresh gesture.
const ANSWER = "_acpmux/permission_respond";

type Daemon = {
  inFlight: number;
  peak: number;
  refused: number;
  latencyMs: number;
  /// Answers sent, each refused as busy, and when (ms since connect).
  answers?: number[];
  /// A frame carrying this text throws in the socket's send.
  throwOn?: string;
};

async function connectBusyDaemon(daemon: Daemon, onSnapshot: (snapshot: unknown) => void = () => undefined) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class LimitedHost extends MockAcpmuxSocket {
    override send(raw: string): void {
      const request = JSON.parse(raw) as { id?: number; method: string };
      if (daemon.throwOn && raw.includes(daemon.throwOn)) throw new Error("socket send failed");
      if ((request.method !== PROBE && request.method !== ANSWER) || request.id === undefined) return super.send(raw);
      const reply = (message: Record<string, unknown>) =>
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: request.id, ...message }) });
      if (request.method === ANSWER) daemon.answers?.push(performance.now() - started);
      if (request.method === ANSWER || daemon.inFlight >= DAEMON_LIMIT) {
        daemon.refused += 1;
        reply({
          error: {
            code: -32000,
            message: "connection request limit reached",
            data: { reason: "connection.busy", retryable: true },
          },
        });
        return;
      }
      daemon.inFlight += 1;
      daemon.peak = Math.max(daemon.peak, daemon.inFlight);
      setTimeout(() => {
        daemon.inFlight -= 1;
        reply({ result: { version: "test" } });
      }, daemon.latencyMs);
    }
  }
  const started = performance.now();
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    onSnapshot,
    undefined,
    () => new LimitedHost() as unknown as WebSocket,
  );
  const call = (method: string, params: object, deadline?: number) =>
    (client as unknown as { request(method: string, params: object, deadline?: number): Promise<unknown> }).request(
      method,
      params,
      deadline,
    );
  const request = (deadline?: number) => call(PROBE, {}, deadline);
  return { client, request, call };
}

async function burst(request: (deadline?: number) => Promise<unknown>, count: number, deadline?: number) {
  const outcomes = await Promise.allSettled(Array.from({ length: count }, () => request(deadline)));
  const failures = outcomes.filter((o): o is PromiseRejectedResult => o.status === "rejected");
  return {
    ok: outcomes.length - failures.length,
    busy: failures.filter((f) => (f.reason as { reason?: string })?.reason === "connection.busy").length,
    timedOut: failures.filter((f) => (f.reason as { code?: string })?.code === "native.timed_out").length,
  };
}

test("a burst of 200 reads on a slow daemon meets no busy refusal", async () => {
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 20 };
  const { client, request } = await connectBusyDaemon(daemon);
  try {
    const result = await burst(request, 200);
    console.error(`[storm] burst: ${JSON.stringify({ ...result, daemonPeak: daemon.peak, refused: daemon.refused })}`);
    expect(result.busy).toBe(0);
    expect(result.ok).toBe(200);
    expect(daemon.refused).toBe(0);
    expect(daemon.peak).toBeLessThanOrEqual(WORK_LIMIT);
  } finally {
    client.close?.();
  }
});

test("a slow but alive daemon keeps reads pending and shows progress", async () => {
  // Each read crosses the old 10 ms cutoff; the daemon answers in 150 ms while the socket stays open.
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 150 };
  const snapshots: unknown[] = [];
  const { client, request } = await connectBusyDaemon(daemon, (snapshot) => snapshots.push(snapshot));
  try {
    const first = await burst(request, 64, 10);
    const second = await burst(request, 64);
    console.error(`[storm] abandoned: ${JSON.stringify({ first, second, refused: daemon.refused })}`);
    expect(first.timedOut).toBe(0);
    expect(first.ok).toBe(64);
    expect(second.busy).toBe(0);
    expect(second.ok).toBe(64);
    expect(daemon.refused).toBe(0);
    expect(snapshots.some((snapshot: any) => snapshot.daemonWaitingSince !== undefined)).toBe(true);
  } finally {
    client.close?.();
  }
});

test("the budget queues past its limit in order and frees a slot per answer", () => {
  const budget = new RequestBudget(2);
  const sent: number[] = [];
  for (const id of [1, 2, 3, 4]) budget.admit(id, PROBE, () => sent.push(id));
  expect(sent).toEqual([1, 2]);
  expect(budget.queued).toBe(2);
  budget.settled(2);
  expect(sent).toEqual([1, 2, 3]);
  // A request that waited and was given up never goes.
  budget.settled(4);
  budget.settled(1);
  expect(sent).toEqual([1, 2, 3]);
  expect(budget.inFlight).toBe(1);
});

test("uncounted methods go out at once, as the daemon does not count them", () => {
  const budget = new RequestBudget(1);
  const sent: string[] = [];
  budget.admit(1, PROBE, () => sent.push("probe"));
  for (const method of ["session/prompt", "_acpmux/attach", "_acpmux/wait", "session/new"]) {
    expect(countsAgainstBudget(method)).toBe(false);
    budget.admit(2, method, () => sent.push(method));
  }
  expect(sent).toEqual(["probe", "session/prompt", "_acpmux/attach", "_acpmux/wait", "session/new"]);
});

test("a busy retry waits with jitter, and closing the connection cancels it", () => {
  const timers = new Map<number, () => void>();
  let next = 0;
  const budget = new RequestBudget(4, {
    set: (run) => {
      timers.set(++next, run);
      return next as unknown as ReturnType<typeof setTimeout>;
    },
    clear: (timer) => timers.delete(timer as unknown as number),
  });
  let sends = 0;
  budget.admit(1, PROBE, () => sends++);
  budget.retryLater(1, () => sends++, 100);
  expect(sends).toBe(1);
  expect(budget.inFlight).toBe(0);
  expect(timers.size).toBe(1);
  expect(budget.reset()).toEqual([1]);
  expect(timers.size).toBe(0);
  // Full jitter between half and all of the doubled wait, capped.
  expect(busyDelay(1, () => 0)).toBe(125);
  expect(busyDelay(1, () => 1)).toBe(250);
  expect(busyDelay(20, () => 1)).toBe(BUSY_MAX_MS);
});

test("a click-authorized answer goes past a full budget at once and is never sent again after a busy refusal", async () => {
  // The host's grant for the click lasts moments and is spent when the frame passes: an Allow that
  // waited behind 48 slow reads, or went again after a refusal, would be refused for want of a click.
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 300, answers: [] };
  const { client, request, call } = await connectBusyDaemon(daemon);
  try {
    const reads = burst(request, WORK_LIMIT);
    const answer = call(ANSWER, { permissionId: "p1", optionId: "allow" });
    const refusal = await answer.then(
      () => undefined,
      (error: { reason?: string }) => error,
    );
    expect(refusal?.reason).toBe("connection.busy");
    expect(daemon.answers).toHaveLength(1);
    expect(daemon.answers![0]!).toBeLessThan(daemon.latencyMs);
    expect((await reads).ok).toBe(WORK_LIMIT);
    expect(daemon.answers).toHaveLength(1);
  } finally {
    client.close?.();
  }
});

test("a waiting request whose send throws fails alone and frees its slot", async () => {
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 30, throwOn: "boom" };
  const { client, request, call } = await connectBusyDaemon(daemon);
  try {
    const reads = burst(request, WORK_LIMIT);
    const doomed = call(PROBE, { note: "boom" }).then(
      () => "sent",
      (error: Error) => error.message,
    );
    expect((await reads).ok).toBe(WORK_LIMIT);
    expect(await doomed).toBe("socket send failed");
    expect((await burst(request, WORK_LIMIT)).ok).toBe(WORK_LIMIT);
    expect(daemon.refused).toBe(0);
  } finally {
    client.close?.();
  }
});

test("only reads wait for a slot; a write, a click's answer or a Stop goes at once, counted, and never again", () => {
  const budget = new RequestBudget(1);
  const sent: string[] = [];
  budget.admit(1, PROBE, () => sent.push("read"));
  budget.admit(2, PROBE, () => sent.push("waits"));
  const others = [
    ANSWER,
    "_acpmux/bookmark_set",
    "_acpmux/memory_resolve",
    "_acpmux/permission_chat_revoke",
    "_acpmux/kill",
    "acp.session.fork",
  ];
  for (const [index, method] of others.entries()) {
    expect(waitsForSlot(method)).toBe(false);
    budget.admit(3 + index, method, () => sent.push(method));
  }
  expect(sent).toEqual(["read", ...others]);
  expect(budget.inFlight).toBe(1 + others.length);
  expect(waitsForSlot(PROBE)).toBe(true);
  expect(waitsForSlot("git.status")).toBe(true);
});

test("a preset read waits for a slot; a preset approval card's answer goes at once and never again", () => {
  expect(waitsForSlot("_acpmux/presets", { name: "lane" })).toBe(true);
  expect(waitsForSlot("_acpmux/presets")).toBe(true);
  const approve = { name: "lane", approveMode: true, approveDigest: "d1", sessionId: "s1" };
  expect(waitsForSlot("_acpmux/presets", approve)).toBe(false);
  expect(waitsForSlot("_acpmux/presets", { ...approve, approveMode: false })).toBe(false);
  expect(waitsForSlot("_acpmux/presets", { name: "lane", set: { model: "m" } })).toBe(false);
  const budget = new RequestBudget(1);
  const sent: string[] = [];
  budget.admit(1, PROBE, () => sent.push("read"));
  budget.admit(2, "_acpmux/presets", () => sent.push("preset read"), { name: "lane" });
  budget.admit(3, "_acpmux/presets", () => sent.push("approve"), approve);
  expect(sent).toEqual(["read", "approve"]);
});

test("a write refused as busy is never sent again, so a later write is not undone", async () => {
  // A bookmark refused as busy, then its removal answered: sending the bookmark again would put it back.
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 30, answers: [] };
  const { client, call } = await connectBusyDaemon(daemon);
  try {
    const refusal = await call(ANSWER, { permissionId: "p1", optionId: "allow" }).then(
      () => undefined,
      (error: { reason?: string }) => error,
    );
    // A retried request reaches its caller only after its last try: the error after one send means none.
    expect(refusal?.reason).toBe("connection.busy");
    expect(daemon.answers).toHaveLength(1);
  } finally {
    client.close?.();
  }
});
