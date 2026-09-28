import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { makeTransportJournalHandler } from "../app/api/observability/transport/route";
import {
  parseTransportJournalEvent,
  type TransportJournalEvent,
} from "../services/observability/transportJournal";

const originalVercel = process.env.VERCEL;
const originalRuleId = process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID;

let authenticatedUser: { readonly id: string } | null = { id: "user-9" };
let emitError: unknown = null;
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const emitted: Array<{ readonly userId: string; readonly batch: readonly TransportJournalEvent[] }> = [];

const verifyRequest = mock(async () => authenticatedUser);
const POST = makeTransportJournalHandler({
  verifyRequest,
  checkRateLimit: async () => rateLimitResult,
  emitEvents: async (userId, batch) => {
    if (emitError) throw emitError;
    emitted.push({ userId, batch });
  },
  flushTraces: async () => true,
});

beforeEach(() => {
  delete process.env.VERCEL;
  process.env.CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID = "client-observability-test";
  authenticatedUser = { id: "user-9" };
  emitError = null;
  rateLimitResult = { rateLimited: false };
  emitted.length = 0;
  verifyRequest.mockClear();
});

afterAll(() => {
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_MOBILE_OBSERVABILITY_RATE_LIMIT_ID", originalRuleId);
});

function journalEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    timestamp: "2026-09-28T03:00:50.168Z",
    monoMs: 91_670_979,
    component: "v2-control",
    event: "cooldown-set",
    platform: "mac",
    clientChannel: "nightly",
    endpoint: "10533b43db35",
    deviceId: "device-9",
    buildTag: "default",
    attributes: { schema: "relay.request.v1", source: "rate_limited", delay_s: "60" },
    ...overrides,
  };
}

function journalRequest(batch: unknown): Request {
  return new Request("https://cmux.test/api/observability/transport", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer token" },
    body: JSON.stringify({ batch }),
  });
}

describe("transport journal observability route", () => {
  test("attributes an accepted batch to the authenticated user", async () => {
    const response = await POST(journalRequest([
      journalEvent(),
      journalEvent({ event: "credential-renewal-overdue", component: "v2-host" }),
    ]));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, accepted: 2 });
    expect(emitted).toHaveLength(1);
    expect(emitted[0]?.userId).toBe("user-9");
    expect(emitted[0]?.batch[0]?.endpoint).toBe("10533b43db35");
    expect(emitted[0]?.batch[1]?.event).toBe("credential-renewal-overdue");
  });

  test("rejects a batch containing an event outside the component allowlist", async () => {
    const response = await POST(journalRequest([
      journalEvent(),
      journalEvent({ component: "terminal-trace" }),
    ]));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_event" });
    expect(emitted).toHaveLength(0);
  });

  test("requires authentication", async () => {
    authenticatedUser = null;
    const response = await POST(journalRequest([journalEvent()]));
    expect(response.status).toBe(401);
    expect(emitted).toHaveLength(0);
  });

  test("reports emission failure without accepting the batch", async () => {
    emitError = new Error("sink down");
    const response = await POST(journalRequest([journalEvent()]));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "observability_unavailable" });
  });
});

describe("transport journal event validation", () => {
  test("accepts a complete event and floors the monotonic clock", () => {
    const parsed = parseTransportJournalEvent(journalEvent({ monoMs: 12.7 }));
    expect(parsed?.monoMs).toBe(12);
    expect(parsed?.attributes?.schema).toBe("relay.request.v1");
  });

  test.each([
    ["unknown component", journalEvent({ component: "not-a-component" })],
    ["uppercase event", journalEvent({ event: "Cooldown-Set" })],
    ["bad endpoint", journalEvent({ endpoint: "10533B43DB35" })],
    ["bad channel", journalEvent({ clientChannel: "beta" })],
    ["attribute key with dots", journalEvent({ attributes: { "a.b": "x" } })],
    ["oversized attribute value", journalEvent({ attributes: { schema: "x".repeat(161) } })],
    ["too many attributes", journalEvent({
      attributes: Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`k${index}`, "v"])),
    })],
    ["missing timestamp", journalEvent({ timestamp: undefined })],
    ["unparseable timestamp", journalEvent({ timestamp: "not-a-date" })],
    ["negative monotonic", journalEvent({ monoMs: -1 })],
  ])("rejects %s", (_name, value) => {
    expect(parseTransportJournalEvent(value)).toBeNull();
  });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}
