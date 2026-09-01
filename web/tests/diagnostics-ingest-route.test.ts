import { afterEach, describe, expect, mock, spyOn, test } from "bun:test";

import {
  MAX_DIAGNOSTICS_BATCH_EVENTS,
  makeDiagnosticsIngestHandler,
} from "../app/api/diagnostics/ingest/route";
import { VERBOSE_DIAGNOSTICS_LOG_MARKER } from "../services/observability/verboseDiagnostics";

type VerifiedUser = { readonly id: string; readonly verboseDiagnostics?: boolean };

function ingestRequest(body: unknown): Request {
  return new Request("https://cmux.example/api/diagnostics/ingest", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function handlerReturning(user: VerifiedUser | null) {
  const verifyRequest = mock(async () => user);
  return { POST: makeDiagnosticsIngestHandler({ verifyRequest }), verifyRequest };
}

function markerPayloads(spy: ReturnType<typeof spyOn>): Array<Record<string, unknown>> {
  return spy.mock.calls
    .map((call) => String(call[0]))
    .filter((line) => line.startsWith(VERBOSE_DIAGNOSTICS_LOG_MARKER))
    .map((line) =>
      JSON.parse(line.slice(VERBOSE_DIAGNOSTICS_LOG_MARKER.length + 1)) as Record<string, unknown>,
    );
}

afterEach(() => {
  mock.restore();
});

describe("diagnostics ingest route", () => {
  test("rejects unauthenticated uploads", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const { POST } = handlerReturning(null);
    const response = await POST(ingestRequest({ batch: [{ code: 1 }] }));
    expect(response.status).toBe(401);
    expect(markerPayloads(log)).toHaveLength(0);
  });

  test("rejects authenticated uploads from accounts without the server flag", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    for (const user of [
      { id: "user-unflagged" },
      { id: "user-unflagged", verboseDiagnostics: false },
    ] satisfies VerifiedUser[]) {
      const { POST } = handlerReturning(user);
      const response = await POST(ingestRequest({ batch: [{ code: 1 }] }));
      expect(response.status).toBe(403);
      expect(await response.json()).toEqual({ error: "diagnostics_not_enabled" });
    }
    // The double gate rejected before anything reached the log sink.
    expect(markerPayloads(log).filter((p) => p.kind === "client_event")).toHaveLength(0);
  });

  test("accepts a flagged upload and emits one marker line per event", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const { POST } = handlerReturning({ id: "user-flagged", verboseDiagnostics: true });
    const response = await POST(
      ingestRequest({
        buildStamp: "cmux 1.0 (42)",
        clientId: "install-abc",
        batch: [
          {
            at: "2026-08-31T01:02:03.456Z",
            code: 12,
            name: "transportDialFailed",
            summary: "Transport dial failed (relay)",
            ms: 250,
            b: 3,
          },
          { code: 4, summary: "line\nsplittingattempt" },
        ],
      }),
    );
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ ok: true, accepted: 2 });

    const payloads = markerPayloads(log);
    const events = payloads.filter((p) => p.kind === "client_event");
    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({
      userId: "user-flagged",
      deviceId: "install-abc",
      clientAt: "2026-08-31T01:02:03.456Z",
      code: 12,
      name: "transportDialFailed",
      summary: "Transport dial failed (relay)",
      ms: 250,
      b: 3,
      buildStamp: "cmux 1.0 (42)",
    });
    // Control characters can never split or style a log line.
    expect(events[1]?.summary).toBe("linesplittingattempt");
    const batchLine = payloads.find((p) => p.kind === "client_batch");
    expect(batchLine).toMatchObject({ received: 2, accepted: 2 });
  });

  test("bounds the batch and drops shapeless events", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const { POST } = handlerReturning({ id: "user-flagged", verboseDiagnostics: true });

    const oversized = await POST(
      ingestRequest({
        batch: Array.from({ length: MAX_DIAGNOSTICS_BATCH_EVENTS + 1 }, () => ({ code: 1 })),
      }),
    );
    expect(oversized.status).toBe(400);

    const missingBatch = await POST(ingestRequest({}));
    expect(missingBatch.status).toBe(400);

    const mixed = await POST(
      ingestRequest({
        batch: [
          { code: 7 },
          { code: "not-a-number" },
          "just-a-string",
          { summary: "no code" },
        ],
      }),
    );
    expect(mixed.status).toBe(202);
    expect(await mixed.json()).toEqual({ ok: true, accepted: 1 });
    const events = markerPayloads(log).filter((p) => p.kind === "client_event");
    expect(events).toHaveLength(1);
    expect(events[0]?.code).toBe(7);
  });
});
