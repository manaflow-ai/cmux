import { describe, expect, test } from "bun:test";
import { runAdmissionFor, toRunEventView, toRunSnapshotView } from "../services/runs/view";

const createdAt = new Date("2026-01-01T00:00:00.000Z");

function snapshot() {
  const run = {
    id: "run-1",
    provider: "cloud-vm",
    status: "running",
    recipe: "parallel-review",
    desiredAttempts: 1,
    source: { repository: "manaflow-ai/cmux", commit: "a".repeat(40) },
    error: null,
    cancelRequestedAt: null,
    completedAt: null,
    createdAt,
    updatedAt: createdAt,
  };
  const attempt = {
    id: "attempt-1",
    ordinal: 0,
    status: "running",
    providerVmId: "vm-private-address",
    providerWorkspaceId: "workspace-private-address",
    providerTerminalId: "terminal-stable-id",
    terminalRetainUntil: new Date("2099-01-01T00:00:00.000Z"),
    result: { output: "ok", providerMetadata: { secret: "hidden" } },
    exitCode: null,
    error: null,
    startedAt: createdAt,
    finishedAt: null,
    createdAt,
    updatedAt: createdAt,
    leaseToken: "lease-secret",
    cleanupLeaseToken: "cleanup-secret",
    attachTicketHash: "ticket-hash",
  };
  return { run, attempts: [attempt], artifacts: [] } as never;
}

describe("Run public views", () => {
  test("maps Freestyle and removes lease, ticket, and provider handles", () => {
    const view = toRunSnapshotView(snapshot());
    expect(view.run.executionProvider).toBe("cloud-vm");
    expect(view.run.backendProvider).toBe("freestyle");
    expect(view.run.admission.state).toBe("admitted");
    expect(view.attempts[0]).not.toHaveProperty("leaseToken");
    expect(view.attempts[0]).not.toHaveProperty("providerVmId");
    expect(view.attempts[0]?.placement.sessionId).toBeTruthy();
    expect(view.attempts[0]?.attachable).toBe(true);
    expect(view.attempts[0]?.result).toEqual({ output: "ok" });
  });

  test("keeps Huge Blue explicitly unavailable until its adapter is configured", () => {
    const view = toRunSnapshotView(snapshot(), {
      routing: { requestedProvider: "huge-blue", accountClass: "team" },
    });
    expect(view.run.backendProvider).toBe("huge-blue");
    expect(view.run.routing.selectedProvider).toBe("huge-blue");
    expect(view.run.admission).toMatchObject({ state: "unavailable", reasonCode: "adapter_not_configured", retryable: false });
  });

  test("denies an ineligible account without revealing account identity", () => {
    const view = toRunSnapshotView(snapshot(), { accountEligible: false, accountClass: "personal" });
    expect(view.run.admission).toMatchObject({ state: "denied", reasonCode: "account_ineligible", retryable: false });
    expect(view.run).not.toHaveProperty("userId");
    expect(view.run).not.toHaveProperty("billingTeamId");
  });

  test("uses a stable opaque session identity", () => {
    const first = toRunSnapshotView(snapshot());
    const second = toRunSnapshotView(snapshot());
    expect(first.attempts[0]?.placement.sessionId).toBe(second.attempts[0]?.placement.sessionId);
    expect(first.attempts[0]?.placement.sessionId).not.toContain("terminal-stable-id");
  });

  test("redacts sensitive event payload keys while preserving output", () => {
    const view = toRunEventView({
      id: "event-1",
      runId: "run-1",
      attemptId: "attempt-1",
      sequence: 2,
      attemptSequence: 1,
      externalId: "output-1",
      kind: "attempt.output",
      payload: { text: "hello", providerVmId: "private", credentials: { token: "private" } },
      createdAt,
    } as never);
    expect(view.payload).toEqual({ text: "hello" });
  });

  test("reports adapter and account admission states as typed values", () => {
    expect(runAdmissionFor({ backendProvider: "huge-blue" }).reasonCode).toBe("adapter_not_configured");
    expect(runAdmissionFor({ backendProvider: "freestyle", accountEligible: false }).state).toBe("denied");
  });
});

