// A reply's bookkeeping costs the same however many requests wait (goal chats-flat-at-any-length).
// A chat grown live to 100k rows idled at 16x an empty chat's renderer CPU (chat-100k-flat.bench.ts,
// 2026-11-15): the page was still draining a queue of reads, and 27% of the "idle" window went to
// RequestBudget.settled (a scan of the whole queue per reply) and the client's noteRequestSettled
// (a copy of every pending request per reply). Both made draining N requests cost N².
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { RequestBudget } from "./requestBudget";
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

const READ = "_acpmux/events";

/// Milliseconds to admit `count` reads past a 64-slot budget and answer every one, oldest first.
function drain(count: number): number {
  const budget = new RequestBudget(64);
  const sent: number[] = [];
  const began = performance.now();
  for (let id = 0; id < count; id++) budget.admit(id, READ, () => sent.push(id));
  for (let answered = 0; answered < count; answered++) budget.settled(sent[answered]!);
  const elapsed = performance.now() - began;
  expect(sent.length).toBe(count);
  expect(budget.inFlight).toBe(0);
  expect(budget.queued).toBe(0);
  return elapsed;
}

test("draining the budget's queue costs time in proportion to its length, not its square", () => {
  // Sizes well above timer noise: at 2,000 the small drain took under a millisecond on a CI runner.
  drain(8_000); // warm the JIT
  const best = (count: number) => Math.min(drain(count), drain(count), drain(count));
  const small = best(8_000);
  const large = best(64_000);
  // 8x the requests: about 8x the time when each answer costs the same, 64x when each scans the queue.
  console.error(
    `[budget] drain 8,000: ${small.toFixed(1)} ms; 64,000: ${large.toFixed(1)} ms (${(large / small).toFixed(1)}x)`,
  );
  expect(large / small).toBeLessThan(24);
});

/// A Map that counts the entries every values() walk visits.
class CountingMap<K, V> extends Map<K, V> {
  visited = 0;
  override values(): MapIterator<V> {
    const inner = super.values();
    const counted = Object.create(Object.getPrototypeOf(inner)) as MapIterator<V>;
    return Object.assign(counted, {
      next: () => {
        const step = inner.next();
        if (!step.done) this.visited += 1;
        return step;
      },
      [Symbol.iterator]: () => counted,
    });
  }
}

test("a reply walks none of the other pending requests", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const held: (() => void)[] = [];
  class HeldHost extends MockAcpmuxSocket {
    override send(raw: string): void {
      const request = JSON.parse(raw) as { id?: number; method: string };
      if (request.method !== READ || request.id === undefined) return super.send(raw);
      held.push(() =>
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { events: [] } }) }),
      );
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new HeldHost() as unknown as WebSocket,
  );
  try {
    const internals = client as unknown as {
      pending: Map<unknown, unknown>;
      request(method: string, params: object): Promise<unknown>;
    };
    const counting = new CountingMap<unknown, unknown>(internals.pending);
    internals.pending = counting;
    const count = 2_000;
    const replies = Array.from({ length: count }, () => internals.request(READ, {}));
    // Answer every read as it goes out; each answer lets the next queued one go.
    for (let answered = 0; answered < count; answered++) {
      expect(held.length).toBeGreaterThan(0);
      held.shift()!();
    }
    await Promise.all(replies);
    console.error(`[budget] ${count} replies walked ${counting.visited} pending entries`);
    // A walk of the pending requests per reply visits about count² / 2 entries.
    expect(counting.visited).toBeLessThan(count * 4);
  } finally {
    client.close?.();
  }
});
