// A page never meets acpmux's per-connection work limit from its own requests (requestBudget.ts).
// Leo, 2026-10-29, with "connection request limit reached" above the composer: "i dont fucking know
// why the cmux next app is fuckign chugging along". The daemon here answers at most 64 work requests
// of the connection at a time and refuses the next with `connection.busy`, like acpmux
// (`REQUEST_WORK_LIMIT`); a request the page stopped waiting for keeps its slot until it is answered.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { BUSY_MAX_MS, busyDelay, countsAgainstBudget, RequestBudget, WORK_LIMIT } from "./requestBudget";

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
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const DAEMON_LIMIT = 64;
const PROBE = "_acpmux/storm_probe";

type Daemon = { inFlight: number; peak: number; refused: number; latencyMs: number };

async function connectBusyDaemon(daemon: Daemon) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class LimitedHost extends MockAcpmuxSocket {
    override send(raw: string): void {
      const request = JSON.parse(raw) as { id?: number; method: string };
      if (request.method !== PROBE || request.id === undefined) return super.send(raw);
      const reply = (message: Record<string, unknown>) =>
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: request.id, ...message }) });
      if (daemon.inFlight >= DAEMON_LIMIT) {
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
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new LimitedHost() as unknown as WebSocket,
  );
  const request = (deadline?: number) =>
    (client as unknown as { request(method: string, params: object, deadline?: number): Promise<unknown> }).request(
      PROBE,
      {},
      deadline,
    );
  return { client, request };
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

test("reads the page gave up on keep their slot until answered, so the next reads are not refused", async () => {
  // Each read waits 10 ms; the daemon answers in 150 ms. The first 64 time out and still hold the
  // daemon's slots; the next burst used to be refused whole.
  const daemon: Daemon = { inFlight: 0, peak: 0, refused: 0, latencyMs: 150 };
  const { client, request } = await connectBusyDaemon(daemon);
  try {
    const first = await burst(request, 64, 10);
    const second = await burst(request, 64);
    console.error(`[storm] abandoned: ${JSON.stringify({ first, second, refused: daemon.refused })}`);
    expect(first.timedOut).toBe(64);
    expect(second.busy).toBe(0);
    expect(second.ok).toBe(64);
    expect(daemon.refused).toBe(0);
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
