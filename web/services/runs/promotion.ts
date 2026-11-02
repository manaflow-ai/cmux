import { createHash, randomUUID } from "node:crypto";
import type { RunSnapshot } from "./repository";
import type { AttemptStatus } from "./model";

/**
 * The promotion route deliberately depends on these small ports instead of
 * importing either the Runtime repository or the Freestyle SDK. The runtime
 * lane can implement `runtime.promote` by looking up the provider VM and
 * attaching the attempt to a persistent Runtime/workspace. Provider handles
 * stay inside that adapter and are never part of a `PromotionView`.
 */

export type PromotionArtifact = {
  readonly id: string;
  readonly name?: string;
  readonly digest: string;
  readonly uri?: string;
  readonly metadata?: Record<string, unknown> | null;
  /** Adapters may provide this after verifying the artifact bytes. */
  readonly verified?: boolean;
};

export type AttemptPromotionSource = {
  readonly userId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly status: AttemptStatus | string;
  readonly provider: string;
  /** `sandboxed` Runs (hq#3367) never become persistent. */
  readonly environment?: string;
  readonly billingTeamId?: string | null;
  readonly providerVmId?: string | null;
  readonly providerWorkspaceId?: string | null;
  readonly providerTerminalId?: string | null;
  readonly terminalRetainUntil?: Date | string | null;
  readonly result?: Record<string, unknown> | null;
  readonly artifacts: readonly PromotionArtifact[];
};

export type AttemptPromotionSourcePort = {
  /** Return null for an unknown run, attempt, or tenant. */
  readonly find: (input: { userId: string; runId: string; attemptId: string }) => Promise<AttemptPromotionSource | null>;
};

export type PromotionRuntimeInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly runId: string;
  readonly attemptId: string;
  readonly provider: string;
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
  /** Stable, opaque identity derived from the original terminal handle. */
  readonly sessionId: string;
  readonly requestKey: string;
};

export type PromotionRuntimeState = "ready" | "running" | "paused";

export type PromotionRuntimeResult = {
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly state: PromotionRuntimeState;
  readonly sessionId: string;
  readonly transport?: string;
  readonly attachExpiresAt?: Date | string | null;
};

export type AttemptPromotionRuntimePort = {
  /**
   * Reuse the existing provider VM/workspace/terminal handles. Implementations
   * must make this operation idempotent for `requestKey` and preserve
   * `sessionId`; they may call Runtime persistence and the Freestyle workspace
   * service internally.
   */
  readonly promote: (input: PromotionRuntimeInput) => Promise<PromotionRuntimeResult>;
};

export type PromotionAttachView = {
  readonly transport: string;
  readonly capability: "terminal.attach";
  readonly sessionId: string;
  readonly reconnectable: true;
  readonly expiresAt: string | null;
};

export type PromotionWorkspaceView = {
  readonly id: string;
  readonly kind: "persistent-devbox";
  readonly state: PromotionRuntimeState;
  readonly sessionId: string;
};

export type PromotionRuntimeView = {
  readonly id: string;
  readonly state: PromotionRuntimeState;
  readonly sessionId: string;
};

export type PromotionView = {
  readonly id: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly runtime: PromotionRuntimeView;
  readonly workspace: PromotionWorkspaceView;
  readonly attach: PromotionAttachView;
  readonly createdAt: string;
};

export type PromotionReservation = {
  readonly claimId: string;
};

export type PromotionReserveResult =
  | { readonly kind: "reserved"; readonly reservation: PromotionReservation }
  | { readonly kind: "replay"; readonly promotion: PromotionView }
  | { readonly kind: "duplicate"; readonly promotion: PromotionView }
  | { readonly kind: "idempotency_conflict" }
  | { readonly kind: "in_progress" };

export type AttemptPromotionStorePort = {
  /** Optional fast path so an idempotent replay survives terminal retention expiry. */
  readonly findByRequestKey?: (input: { userId: string; requestKey: string }) => Promise<PromotionView | null>;
  /**
   * Atomically reserve `(userId, requestKey)` and `(userId, attemptId)`.
   * Implementations should persist both uniqueness constraints so retries and
   * concurrent requests cannot create two persistent runtimes.
   */
  readonly reserve: (input: {
    userId: string;
    runId: string;
    attemptId: string;
    requestKey: string;
  }) => Promise<PromotionReserveResult>;
  readonly complete: (input: {
    reservation: PromotionReservation;
    promotion: PromotionView;
  }) => Promise<PromotionView>;
  readonly release: (reservation: PromotionReservation) => Promise<void>;
};

export type AttemptPromotionDependencies = {
  readonly source: AttemptPromotionSourcePort;
  readonly store: AttemptPromotionStorePort;
  readonly runtime: AttemptPromotionRuntimePort;
};

export class PromotionNotFoundError extends Error {}
export class PromotionNotReadyError extends Error {}
export class PromotionProviderHandlesMissingError extends Error {}
export class PromotionAlreadyExistsError extends Error {}
export class PromotionInProgressError extends Error {}
export class PromotionIdempotencyConflictError extends Error {}
export class PromotionRuntimeUnavailableError extends Error {}

function iso(value: Date | string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function nonEmpty(value: string | null | undefined): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function stableSessionId(providerTerminalId: string): string {
  const digest = createHash("sha256").update(providerTerminalId, "utf8").digest("hex").slice(0, 32);
  return `session_${digest}`;
}

function metadataVerified(metadata: Record<string, unknown> | null | undefined): boolean {
  if (!metadata) return false;
  if (metadata.verified === true || metadata.evidenceVerified === true) return true;
  return metadata.verification === "verified" || metadata.verificationState === "verified";
}

function artifactVerified(artifact: PromotionArtifact): boolean {
  return /^sha256:[0-9a-f]{64}$/i.test(artifact.digest)
    && (artifact.verified === true || metadataVerified(artifact.metadata));
}

/** Evidence may be a verifier's explicit result bit or a fully verified manifest. */
export function promotionEvidenceReady(source: Pick<AttemptPromotionSource, "result" | "artifacts">): boolean {
  const result = source.result;
  if (result?.evidenceReady === true || result?.evidenceVerified === true || result?.verificationState === "verified") return true;
  const evidence = result?.evidence;
  if (evidence && typeof evidence === "object" && !Array.isArray(evidence)) {
    const verified = (evidence as Record<string, unknown>).verified;
    const state = (evidence as Record<string, unknown>).state;
    if (verified === true || state === "verified") return true;
  }
  return source.artifacts.length > 0 && source.artifacts.every(artifactVerified);
}

function terminalRetained(source: AttemptPromotionSource, now = Date.now()): boolean {
  const retainedUntil = iso(source.terminalRetainUntil);
  return !!retainedUntil && Date.parse(retainedUntil) > now;
}

function assertPromotable(source: AttemptPromotionSource, now = Date.now()): {
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
  readonly sessionId: string;
} {
  if (source.environment === "sandboxed") {
    throw new PromotionNotReadyError("a sandboxed run's machine is destroyed when the run ends and can't be promoted");
  }
  if (source.status !== "succeeded") {
    throw new PromotionNotReadyError("the winning attempt has not completed successfully");
  }
  if (!promotionEvidenceReady(source)) {
    throw new PromotionNotReadyError("verified run evidence is required before promotion");
  }
  if (!terminalRetained(source, now)) {
    throw new PromotionProviderHandlesMissingError("the completed terminal is no longer retained");
  }
  if (!nonEmpty(source.providerVmId) || !nonEmpty(source.providerWorkspaceId) || !nonEmpty(source.providerTerminalId)) {
    throw new PromotionProviderHandlesMissingError("the winning attempt has no retained provider handles");
  }
  return {
    providerVmId: source.providerVmId,
    providerWorkspaceId: source.providerWorkspaceId,
    providerTerminalId: source.providerTerminalId,
    sessionId: stableSessionId(source.providerTerminalId),
  };
}

function viewFromRuntime(input: {
  runId: string;
  attemptId: string;
  runtime: PromotionRuntimeResult;
  createdAt?: Date | string;
}): PromotionView {
  if (!nonEmpty(input.runtime.runtimeId) || !nonEmpty(input.runtime.workspaceId) || !nonEmpty(input.runtime.sessionId)) {
    throw new PromotionRuntimeUnavailableError("runtime promotion returned an incomplete redacted view");
  }
  const createdAt = iso(input.createdAt ?? new Date()) ?? new Date(0).toISOString();
  const expiresAt = iso(input.runtime.attachExpiresAt);
  const transport = nonEmpty(input.runtime.transport) ? input.runtime.transport : "cmux-remote";
  return {
    id: randomUUID(),
    runId: input.runId,
    attemptId: input.attemptId,
    runtime: {
      id: input.runtime.runtimeId,
      state: input.runtime.state,
      sessionId: input.runtime.sessionId,
    },
    workspace: {
      id: input.runtime.workspaceId,
      kind: "persistent-devbox",
      state: input.runtime.state,
      sessionId: input.runtime.sessionId,
    },
    attach: {
      transport,
      capability: "terminal.attach",
      sessionId: input.runtime.sessionId,
      reconnectable: true,
      expiresAt,
    },
    createdAt,
  };
}

/**
 * Promote a tenant-owned, successful, evidence-ready attempt. All ownership,
 * readiness, uniqueness, and redaction checks live here so HTTP and future
 * internal callers share exactly one mutation path.
 */
// oxlint-disable-next-line complexity -- Promotion keeps ownership, evidence, idempotency, and runtime fencing in one atomic boundary.
export async function promoteRunAttempt(input: {
  readonly userId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly requestKey: string;
  readonly dependencies: AttemptPromotionDependencies;
  readonly now?: number;
}): Promise<PromotionView> {
  const requestKey = input.requestKey.trim();
  if (!requestKey || requestKey.length > 128) throw new PromotionIdempotencyConflictError("Idempotency-Key is required and must be at most 128 characters");
  const existing = await input.dependencies.store.findByRequestKey?.({ userId: input.userId, requestKey });
  if (existing) {
    if (existing.runId !== input.runId || existing.attemptId !== input.attemptId) {
      throw new PromotionIdempotencyConflictError("Idempotency-Key was already used for a different run attempt");
    }
    return existing;
  }
  const source = await input.dependencies.source.find({ userId: input.userId, runId: input.runId, attemptId: input.attemptId });
  if (!source || source.userId !== input.userId || source.runId !== input.runId || source.attemptId !== input.attemptId) {
    throw new PromotionNotFoundError("run attempt not found");
  }
  const handles = assertPromotable(source, input.now ?? Date.now());
  const reserved = await input.dependencies.store.reserve({ userId: input.userId, runId: input.runId, attemptId: input.attemptId, requestKey });
  if (reserved.kind === "replay") {
    if (reserved.promotion.runId !== input.runId || reserved.promotion.attemptId !== input.attemptId) {
      throw new PromotionIdempotencyConflictError("Idempotency-Key was already used for a different run attempt");
    }
    return reserved.promotion;
  }
  if (reserved.kind === "idempotency_conflict") throw new PromotionIdempotencyConflictError("Idempotency-Key was already used for a different run attempt");
  if (reserved.kind === "duplicate") {
    if (reserved.promotion.runId !== input.runId || reserved.promotion.attemptId !== input.attemptId) {
      throw new PromotionIdempotencyConflictError("the stored promotion belongs to a different run attempt");
    }
    throw new PromotionAlreadyExistsError("this attempt has already been promoted");
  }
  if (reserved.kind === "in_progress") throw new PromotionInProgressError("promotion is already in progress");
  try {
    const runtime = await input.dependencies.runtime.promote({
      userId: input.userId,
      billingTeamId: source.billingTeamId,
      runId: input.runId,
      attemptId: input.attemptId,
      provider: source.provider,
      providerVmId: handles.providerVmId,
      providerWorkspaceId: handles.providerWorkspaceId,
      providerTerminalId: handles.providerTerminalId,
      sessionId: handles.sessionId,
      requestKey,
    });
    if (runtime.sessionId !== handles.sessionId) throw new PromotionRuntimeUnavailableError("runtime promotion changed the terminal session identity");
    const promotion = viewFromRuntime({ runId: input.runId, attemptId: input.attemptId, runtime });
    return await input.dependencies.store.complete({ reservation: reserved.reservation, promotion });
  } catch (error) {
    await input.dependencies.store.release(reserved.reservation).catch(() => undefined);
    if (error instanceof PromotionRuntimeUnavailableError) throw error;
    throw error;
  }
}

/** Convert the existing Run repository snapshot to the promotion source port. */
export function runSnapshotPromotionSource(snapshot: RunSnapshot, attemptId: string, userId: string): AttemptPromotionSource | null {
  if (snapshot.run.userId !== userId) return null;
  const attempt = snapshot.attempts.find((candidate) => candidate.id === attemptId);
  if (!attempt) return null;
  return {
    userId,
    runId: snapshot.run.id,
    attemptId: attempt.id,
    status: attempt.status,
    provider: snapshot.run.provider,
    environment: snapshot.run.environment,
    billingTeamId: snapshot.run.billingTeamId,
    providerVmId: attempt.providerVmId,
    providerWorkspaceId: attempt.providerWorkspaceId,
    providerTerminalId: attempt.providerTerminalId,
    terminalRetainUntil: attempt.terminalRetainUntil,
    result: attempt.result,
    artifacts: snapshot.artifacts.filter((artifact) => artifact.attemptId === attempt.id).map((artifact) => ({
      id: artifact.id,
      name: artifact.name,
      digest: artifact.digest,
      uri: artifact.uri,
      metadata: artifact.metadata,
    })),
  };
}

export function runRepositoryPromotionSource(): AttemptPromotionSourcePort {
  return {
    find: async ({ userId, runId, attemptId }) => {
      try {
        // Keep the pure promotion service importable in dependency-only tests;
        // the database-backed source is loaded only when the app composes it.
        const { getRun } = await import("./repository");
        return runSnapshotPromotionSource(await getRun(runId, userId), attemptId, userId);
      } catch {
        return null;
      }
    },
  };
}

let configuredDependencies: AttemptPromotionDependencies | null = null;

/**
 * Application composition installs the Runtime/Freestyle adapter once during
 * startup. Keeping this registration outside the route makes the promotion
 * path usable by jobs and tests without importing provider lifecycle code.
 */
export function installRunAttemptPromotionDependencies(dependencies: AttemptPromotionDependencies | null): void {
  configuredDependencies = dependencies;
}

export function runAttemptPromotionDependencies(): AttemptPromotionDependencies {
  if (!configuredDependencies) {
    throw new PromotionRuntimeUnavailableError("run attempt promotion is not configured");
  }
  return configuredDependencies;
}

