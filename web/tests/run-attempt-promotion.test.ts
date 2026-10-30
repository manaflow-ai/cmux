import { describe, expect, mock, test } from "bun:test";
import type {
  AttemptPromotionDependencies,
  AttemptPromotionSource,
  AttemptPromotionStorePort,
  PromotionRuntimeInput,
  PromotionRuntimeResult,
  PromotionView,
} from "../services/runs/promotion";
import {
  PromotionAlreadyExistsError,
  PromotionIdempotencyConflictError,
  PromotionNotFoundError,
  PromotionNotReadyError,
  PromotionProviderHandlesMissingError,
  installRunAttemptPromotionDependencies,
  promoteRunAttempt,
} from "../services/runs/promotion";

type Reservation = { claimId: string };

class MemoryPromotionStore implements AttemptPromotionStorePort {
  private readonly byKey = new Map<string, PromotionView>();
  private readonly byAttempt = new Map<string, PromotionView>();
  private readonly pending = new Map<string, { userId: string; runId: string; attemptId: string }>();

  async findByRequestKey(input: { userId: string; requestKey: string }): Promise<PromotionView | null> {
    return this.byKey.get(`${input.userId}:${input.requestKey}`) ?? null;
  }

  async reserve(input: { userId: string; runId: string; attemptId: string; requestKey: string }) {
    const key = `${input.userId}:${input.requestKey}`;
    const attempt = `${input.userId}:${input.runId}:${input.attemptId}`;
    const existing = this.byKey.get(key);
    if (existing) {
      if (existing.runId !== input.runId || existing.attemptId !== input.attemptId) return { kind: "idempotency_conflict" as const };
      return { kind: "replay" as const, promotion: existing };
    }
    const pending = this.pending.get(key);
    if (pending) {
      if (pending.runId !== input.runId || pending.attemptId !== input.attemptId) return { kind: "idempotency_conflict" as const };
      return { kind: "in_progress" as const };
    }
    const duplicate = this.byAttempt.get(attempt);
    if (duplicate) return { kind: "duplicate" as const, promotion: duplicate };
    const reservation = { claimId: key };
    this.pending.set(key, input);
    return { kind: "reserved" as const, reservation };
  }

  async complete(input: { reservation: Reservation; promotion: PromotionView }) {
    const pending = this.pending.get(input.reservation.claimId);
    if (!pending) throw new Error("missing reservation");
    this.pending.delete(input.reservation.claimId);
    this.byKey.set(input.reservation.claimId, input.promotion);
    this.byAttempt.set(`${pending.userId}:${pending.runId}:${pending.attemptId}`, input.promotion);
    return input.promotion;
  }

  async release(reservation: Reservation) {
    this.pending.delete(reservation.claimId);
  }
}

function source(overrides: Partial<AttemptPromotionSource> = {}): AttemptPromotionSource {
  return {
    userId: "owner",
    runId: "run-1",
    attemptId: "attempt-1",
    status: "succeeded",
    provider: "cloud-vm",
    billingTeamId: "team-1",
    providerVmId: "vm-secret-id",
    providerWorkspaceId: "workspace-secret-id",
    providerTerminalId: "terminal-secret-id",
    terminalRetainUntil: new Date(Date.now() + 60_000),
    result: null,
    artifacts: [{ id: "artifact-1", digest: `sha256:${"a".repeat(64)}`, metadata: { verified: true } }],
    ...overrides,
  };
}

function makeDependencies(
  attempt: AttemptPromotionSource = source(),
  runtimeOverride?: (input: PromotionRuntimeInput) => Promise<PromotionRuntimeResult>,
): { dependencies: AttemptPromotionDependencies; calls: PromotionRuntimeInput[] } {
  const calls: PromotionRuntimeInput[] = [];
  const dependencies: AttemptPromotionDependencies = {
    source: { find: async ({ userId, runId, attemptId }) => userId === attempt.userId && runId === attempt.runId && attemptId === attempt.attemptId ? attempt : null },
    store: new MemoryPromotionStore(),
    runtime: {
      promote: async (input) => {
        calls.push(input);
        return runtimeOverride?.(input) ?? {
          runtimeId: "runtime-1",
          workspaceId: "workspace-1",
          state: "ready" as const,
          sessionId: input.sessionId,
          transport: "cmux-remote",
        };
      },
    },
  };
  return { dependencies, calls };
}

describe("run attempt promotion service", () => {
  test("promotes verified successful attempts and returns only a redacted runtime view", async () => {
    const { dependencies, calls } = makeDependencies();
    const promotion = await promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "promote-1", dependencies });
    expect(promotion.runtime).toMatchObject({ id: "runtime-1", state: "ready" });
    expect(promotion.runtime.sessionId).toMatch(/^session_[0-9a-f]{32}$/);
    expect(promotion.workspace).toMatchObject({ id: "workspace-1", kind: "persistent-devbox", sessionId: promotion.runtime.sessionId });
    expect(promotion.attach).toMatchObject({ transport: "cmux-remote", capability: "terminal.attach", reconnectable: true, sessionId: promotion.runtime.sessionId });
    expect(JSON.stringify(promotion)).not.toContain("vm-secret-id");
    expect(JSON.stringify(promotion)).not.toContain("terminal-secret-id");
    expect(calls[0]).toMatchObject({ providerVmId: "vm-secret-id", providerWorkspaceId: "workspace-secret-id", providerTerminalId: "terminal-secret-id" });
  });

  test("rejects attempts that are not terminal and evidence-ready", async () => {
    const { dependencies } = makeDependencies(source({ status: "running" }));
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "not-ready", dependencies })).rejects.toBeInstanceOf(PromotionNotReadyError);
    const noEvidence = makeDependencies(source({ artifacts: [], result: null })).dependencies;
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "not-ready-2", dependencies: noEvidence })).rejects.toBeInstanceOf(PromotionNotReadyError);
  });

  test("refuses a sandboxed run before reserving or touching the runtime (hq#3367)", async () => {
    const { dependencies, calls } = makeDependencies(source({ environment: "sandboxed" }));
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "sandboxed", dependencies })).rejects.toBeInstanceOf(PromotionNotReadyError);
    expect(calls).toEqual([]);
  });

  test("hides cross-tenant attempts as not found", async () => {
    const { dependencies } = makeDependencies(source({ userId: "other-tenant" }));
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "cross-tenant", dependencies })).rejects.toBeInstanceOf(PromotionNotFoundError);
  });

  test("replays the same request key and refuses a second promotion", async () => {
    const { dependencies } = makeDependencies();
    const first = await promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "same-key", dependencies });
    const replay = await promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "same-key", dependencies });
    expect(replay).toEqual(first);
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "different-key", dependencies })).rejects.toBeInstanceOf(PromotionAlreadyExistsError);
    const other = makeDependencies(source({ runId: "run-2", attemptId: "attempt-2" })).dependencies;
    const sharedStore = new MemoryPromotionStore();
    const firstForSharedStore = makeDependencies().dependencies;
    await promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "shared-key", dependencies: { ...firstForSharedStore, store: sharedStore } });
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-2", attemptId: "attempt-2", requestKey: "shared-key", dependencies: { ...other, store: sharedStore } })).rejects.toBeInstanceOf(PromotionIdempotencyConflictError);
  });

  test("rejects a completed attempt whose provider handles are incomplete", async () => {
    const { dependencies } = makeDependencies(source({ providerTerminalId: null }));
    await expect(promoteRunAttempt({ userId: "owner", runId: "run-1", attemptId: "attempt-1", requestKey: "missing-handles", dependencies })).rejects.toBeInstanceOf(PromotionProviderHandlesMissingError);
  });
});

// Keep one route test at the HTTP boundary. The production route wrapper is
// mocked here so the test remains independent of Stack Auth credentials.
mock.module("../services/vms/routeHelpers", () => ({
  withAuthedVmApiRoute: async (_request: Request, _route: string, _attrs: unknown, _failureLog: string, handler: (context: { user: { id: string } }) => Promise<Response>) => handler({ user: { id: "owner" } }),
}));
mock.module("../services/runs/http", () => ({
  RunRequestError: class RunRequestError extends Error {
    readonly code: string;
    readonly status: number;

    constructor(code: string, message: string, _action: string, status = 400) {
      super(message);
      this.code = code;
      this.status = status;
    }
  },
  runJson: (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } }),
  runError: (error: unknown) => new Response(JSON.stringify({ error: error instanceof Error && "code" in error ? String(error.code) : error instanceof Error ? error.constructor.name : "error" }), { status: error instanceof Error && "status" in error ? Number(error.status) : 500, headers: { "content-type": "application/json" } }),
}));
const promotionRoute = await import("../app/api/runs/[id]/attempts/[attemptId]/promote/route");

describe("run attempt promotion route", () => {
  test("requires an idempotency key before invoking promotion", async () => {
    const response = await promotionRoute.POST(new Request("https://cmux.test", { method: "POST" }), { params: Promise.resolve({ id: "run-1", attemptId: "attempt-1" }) });
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "run_promotion_idempotency_required" });
  });

  test("returns the redacted promotion view", async () => {
    const { dependencies } = makeDependencies();
    installRunAttemptPromotionDependencies(dependencies);
    try {
      const response = await promotionRoute.POST(new Request("https://cmux.test", { method: "POST", headers: { "idempotency-key": "route-key" } }), { params: Promise.resolve({ id: "run-1", attemptId: "attempt-1" }) });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ runtime: { id: "runtime-1" }, workspace: { kind: "persistent-devbox" }, attach: { capability: "terminal.attach" } });
    } finally {
      installRunAttemptPromotionDependencies(null);
    }
  });
});

