// l10n-allow-file: test fixture prompts and harness errors, not shipped UI.
// A turn whose harness retries a failed model request (acpmux `turn_retrying`, hub/turn_retry.rs):
// Leo's 2026-11-03 chat read "Thinking 7m 49s" while Claude Code retried a gateway that was down.
// The client keeps the retry on its TURN_RETRY row (direct.ts), the live line says the model
// cannot be reached (conversation/turns.ts `withRetry`, Thinking.tsx `retryParts`), and once the
// model answers the retries' time leaves the "Thinking" clock.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { TURN_RETRY, type AcpmuxRow } from "./model";
import { THINKING, withRetry } from "./conversation/turns";
import { retryParts } from "./conversation/Thinking";
import { readTurnRetry } from "./direct";

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

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
const T0 = Date.now() - 600_000;
const retrying = (attempt: number) => ({
  mux: "turn_retrying",
  msg: { attempt, maxRetries: 10, errorStatus: 503, error: "server_error", retryDelayMs: 75_000, source: "claude" },
});

/// The client's rows after `steps` (each with its offset from T0, in ms) in one chat.
async function rowsAfter(steps: Array<[number, unknown]>, ready: (rows: AcpmuxRow[]) => boolean) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  for (const [ms, step] of steps) daemon.record(mockHost.sessionId!, step, T0 + ms);
  let rows: AcpmuxRow[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as AcpmuxRow[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!ready(rows)) await new Promise<void>((resolve) => wakes.push(resolve));
    return rows;
  } finally {
    client.close?.();
  }
}

const opened: Array<[number, unknown]> = [
  [0, { mux: "user_message", msg: { text: "Fix the flaky upload test" } }],
  [0, { mux: "turn_started", msg: { turnId: "t1" } }],
];

test("each retry of the turn's model request goes on its TURN_RETRY row, timed from the first", async () => {
  const rows = await rowsAfter([...opened, [5_000, retrying(1)], [80_000, retrying(2)]], (rows) =>
    rows.some((row) => row.id === TURN_RETRY && row.retry?.attempt === 2),
  );
  const row = rows.find((row) => row.id === TURN_RETRY)!;
  expect(row.kind).toBe("typing");
  expect(row.at).toBe(T0 + 5_000);
  expect(row.retry).toEqual({ attempt: 2, maxRetries: 10, errorStatus: 503, error: "server_error" });
});

test("the model heard again ends the retry and keeps the time it took", async () => {
  const rows = await rowsAfter(
    [...opened, [5_000, retrying(1)], [80_000, retrying(2)], [155_000, { mux: "turn_heard", msg: { turnId: "t1" } }]],
    (rows) => rows.some((row) => row.id === TURN_RETRY && row.retriedMs !== undefined),
  );
  const row = rows.find((row) => row.id === TURN_RETRY)!;
  expect(row.retry).toBeUndefined();
  expect(row.retriedMs).toBe(150_000);
});

test("a turn that ends leaves no retry behind", async () => {
  const rows = await rowsAfter(
    [
      ...opened,
      [5_000, retrying(10)],
      [6_000, { mux: "turn_error", msg: { error: "API Error: Connection error." } }],
      [6_000, { mux: "turn_result", msg: { status: "failed", errorText: "API Error: Connection error." } }],
    ],
    (rows) => rows.some((row) => row.kind === "turnSummary"),
  );
  expect(rows.some((row) => row.id === TURN_RETRY)).toBe(false);
});

const line = (fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "thinking-live",
  version: 1,
  at: 1_000,
  kind: THINKING,
  below: true,
  ...fields,
});
const retryRow = (fields: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: TURN_RETRY,
  version: 1,
  at: 2_000,
  kind: "typing",
  ...fields,
});

test("the live line carries the retry, and leaves the retries' time out of its Thinking clock", () => {
  const retry = { attempt: 7, maxRetries: 10 };
  expect(withRetry([retryRow({ retry })], [line()]).at(-1)!.retry).toBe(retry);
  // Before the first output the clock times the turn from its prompt: it starts 9 m later.
  expect(withRetry([retryRow({ retriedMs: 540_000 })], [line()]).at(-1)!.at).toBe(541_000);
  // Past the first step the clock is the turn's total, which the retries are part of.
  expect(withRetry([retryRow({ retriedMs: 540_000 })], [line({ turnTotal: true })]).at(-1)!.at).toBe(1_000);
  const shaped = [line()];
  expect(withRetry([], shaped)).toBe(shaped);
});

test("the line says what is wrong, the retry's count and the harness's error", () => {
  const t = (key: string, values?: Record<string, unknown>) => `${key}${values ? JSON.stringify(values) : ""}`;
  const translate = t as Parameters<typeof retryParts>[0];
  expect(retryParts(translate, { attempt: 7, maxRetries: 10, errorStatus: 503, error: "server_error" })).toEqual({
    label: "turn.live.retry.unreachable",
    count: 'turn.live.retry.attempt{"attempt":7,"max":10}',
    error: "503 server error",
  });
  expect(retryParts(translate, { attempt: 2, errorStatus: 529 }).label).toBe("turn.live.retry.busy");
  expect(retryParts(translate, { error: "rate_limit" })).toEqual({
    label: "turn.live.retry.busy",
    count: "turn.live.retry.retrying",
    error: "rate limit",
  });
  // Claude's status-less error codes carry a trailing "_error".
  expect(retryParts(translate, { error: "rate_limit_error" }).label).toBe("turn.live.retry.busy");
  expect(retryParts(translate, { error: "overloaded_error" }).label).toBe("turn.live.retry.busy");
  expect(retryParts(translate, { error: "server_error" }).label).toBe("turn.live.retry.unreachable");
});

test("a turn_retrying record keeps only counts and words it can show", () => {
  expect(readTurnRetry({ attempt: 3, maxRetries: 10, errorStatus: 503, error: " overloaded ", turnId: "t" })).toEqual({
    attempt: 3,
    maxRetries: 10,
    errorStatus: 503,
    error: "overloaded",
  });
  expect(readTurnRetry({ attempt: 0, maxRetries: "10", error: "" })).toEqual({});
  expect(readTurnRetry({ attempt: 12, maxRetries: 10 })).toEqual({ attempt: 12 });
});
