import { describe, expect, test } from "bun:test";
import type { RunSnapshotRow } from "../services/runs/view";
import { toRunEventView, toRunSnapshotView } from "../services/runs/view";
import { SANDBOX_SCRUBBED_FROM_KEY, sandboxPayloadDigest, sandboxReceiptFor, sandboxReply, SANDBOX_REPLY_MAX_CHARS } from "../services/runs/sandbox";

// A sandboxed Run's receipt (hq#3367): what it ran, how it ended, what it cost, and whether its
// VM is gone. It never carries provider handles, lease tokens or token-shaped output.

describe("sandbox receipt", () => {
  test("the reply drops terminal escapes and token-shaped strings and keeps the tail", () => {
    expect(sandboxReply("\u001b[32mdone\u001b[0m\r\n")).toBe("done");
    expect(sandboxReply("key sk-abcdefghijklmnopqrstuvwxyz and ghp_abcdefghijklmnopqrstuvwxyz0123")).toBe("key [redacted] and [redacted]");
    expect(sandboxReply("   ")).toBeNull();
    const long = sandboxReply(`${"a".repeat(SANDBOX_REPLY_MAX_CHARS)}END`);
    expect(long?.endsWith("END")).toBe(true);
    expect(long?.length).toBe(SANDBOX_REPLY_MAX_CHARS + 1);
  });

  const createdAt = new Date("2026-10-25T10:00:00.000Z");
  const startedAt = new Date("2026-10-25T10:00:30.000Z");
  const finishedAt = new Date("2026-10-25T10:02:00.000Z");

  function snapshot(overrides: { status?: string; environment?: string; providerVmId?: string | null } = {}): RunSnapshotRow {
    return {
      run: {
        id: "run-1",
        userId: "user-1",
        billingTeamId: "team-1",
        idempotencyKey: "key",
        requestDigest: "sha256:x",
        source: {},
        recipe: "sandbox-task",
        provider: "cloud-vm",
        desiredAttempts: 1,
        environment: overrides.environment ?? "sandboxed",
        imageId: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
        imageVersion: "freestyle-cmux-devbox-20260902a",
        receipt: { reply: "hello", exitCode: 0, signal: null, timedOut: false, bootMs: 30_000 },
        status: overrides.status ?? "succeeded",
        cancelRequestedAt: null,
        completedAt: finishedAt,
        error: null,
        createdAt,
        updatedAt: finishedAt,
      },
      attempts: [{
        id: "attempt-1",
        runId: "run-1",
        runtimeId: null,
        ordinal: 0,
        status: "succeeded",
        providerVmId: overrides.providerVmId === undefined ? null : overrides.providerVmId,
        providerWorkspaceId: null,
        providerTerminalId: null,
        terminalRetainUntil: null,
        attachTicketHash: null,
        attachTicketExpiresAt: null,
        attachTicketConsumedAt: null,
        cleanupLeaseToken: null,
        cleanupLeaseExpiresAt: null,
        leaseToken: "lease-token-secret",
        leaseGeneration: 1,
        leaseExpiresAt: null,
        sourceDigest: null,
        result: null,
        exitCode: null,
        error: null,
        startedAt,
        finishedAt,
        createdAt,
        updatedAt: finishedAt,
      }],
      artifacts: [],
    } as RunSnapshotRow;
  }

  test("a finished sandboxed run has a receipt with status, reply, timings, cost and cleanup", () => {
    const vm = { createdAt: new Date("2026-10-25T10:00:00.000Z"), destroyedAt: new Date("2026-10-25T10:02:00.000Z"), live: false };
    const receipt = sandboxReceiptFor({ ...snapshot(), sandboxVms: [vm] } as RunSnapshotRow);
    expect(receipt).toMatchObject({
      schema: "cmux.run.receipt/v1",
      runId: "run-1",
      environment: "sandboxed",
      status: "succeeded",
      image: { id: "sh-08be343bf2b54b4bb0e5226b97eaa6c4", version: "freestyle-cmux-devbox-20260902a" },
      exitCode: 0,
      reply: "hello",
      timings: { bootMs: 30_000, runMs: 90_000, totalMs: 120_000 },
      cost: { vmSeconds: 120 },
      cleanup: "destroyed",
    });
  });

  test("cleanup reads pending while an attempt still holds a VM or a VM row is still up", () => {
    expect(sandboxReceiptFor(snapshot({ providerVmId: "vm-1" }))?.cleanup).toBe("pending");
    expect(sandboxReceiptFor({ ...snapshot(), sandboxVmLive: true })?.cleanup).toBe("pending");
  });

  test("a running or persistent run has no receipt", () => {
    expect(sandboxReceiptFor(snapshot({ status: "running" }))).toBeNull();
    expect(sandboxReceiptFor(snapshot({ environment: "persistent" }))).toBeNull();
  });

  test("the public snapshot carries the receipt and the pinned image, never provider handles or leases", () => {
    const view = toRunSnapshotView(snapshot({ providerVmId: "vm-private-handle" }));
    expect(view.run.environment).toBe("sandboxed");
    expect(view.run.image).toEqual({ id: "sh-08be343bf2b54b4bb0e5226b97eaa6c4", version: "freestyle-cmux-devbox-20260902a" });
    expect(view.receipt?.status).toBe("succeeded");
    const text = JSON.stringify(view);
    expect(text).not.toContain("vm-private-handle");
    expect(text).not.toContain("lease-token-secret");
  });
});


describe("sandbox journal events", () => {
  const event = (payload: Record<string, unknown>) => ({
    id: "event-1", runId: "run-1", attemptId: "attempt-1", sequence: 2, attemptSequence: 1, externalId: "output-1",
    kind: "attempt.output", payload, createdAt: new Date("2026-10-25T10:00:00.000Z"),
  }) as never;

  test("a sandboxed Run's events are served with its provider handles redacted out of text", () => {
    const view = toRunEventView(event({ text: "task ran on vm-private-0123456789" }), "sandboxed", ["vm-private-0123456789"]);
    expect(JSON.stringify(view)).not.toContain("vm-private-0123456789");
    expect(view.payload).toEqual({ text: "task ran on [redacted]" });
  });

  test("cleanup's record of what the worker sent ignores key order and is never served", () => {
    expect(sandboxPayloadDigest({ a: 1, b: { c: [1, { d: 2, e: 3 }] } })).toBe(sandboxPayloadDigest({ b: { c: [1, { e: 3, d: 2 }] }, a: 1 }));
    expect(sandboxPayloadDigest({ a: 1 })).not.toBe(sandboxPayloadDigest({ a: 2 }));
    const view = toRunEventView(event({ text: "ran on [redacted]", [SANDBOX_SCRUBBED_FROM_KEY]: sandboxPayloadDigest({ text: "ran on vm-1" }) }), "sandboxed");
    expect(view.payload).toEqual({ text: "ran on [redacted]" });
  });
});
