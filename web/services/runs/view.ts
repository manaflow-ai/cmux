import { createHash } from "node:crypto";
import type { runArtifacts, runAttempts, runEvents, runs } from "../../db/schema";
import {
  type BackendProvider,
  type ExecutionProvider,
  type RunAdmissionLimits,
  type RunAdmissionView,
  type RunAccountClass,
  type RunRoutingRequest,
  type RunRoutingResult,
  type RunSnapshotView,
  type RunEventView,
  type RunAttemptView,
  type RunArtifactView,
  type RunPlacementView,
  type RunView,
  type RunStatus,
  type AttemptStatus,
  type RunEnvironment,
} from "./model";

export type RunSnapshotRow = {
  readonly run: typeof runs.$inferSelect;
  readonly attempts: readonly (typeof runAttempts.$inferSelect)[];
  readonly artifacts: readonly (typeof runArtifacts.$inferSelect)[];
};

export type RunViewOptions = {
  readonly routing?: RunRoutingRequest;
  readonly backendProvider?: BackendProvider;
  readonly accountClass?: RunAccountClass;
  readonly accountEligible?: boolean;
  readonly limits?: RunAdmissionLimits | null;
  readonly checkedAt?: Date | string;
};

const REDACTED_KEY = /^(?:leaseToken|cleanupLeaseToken|attachTicketHash|providerMetadata|providerVmId|providerWorkspaceId|providerTerminalId|_cmuxPromotion)$/i;
const SENSITIVE_KEY = /(?:credential|password|secret|authorization|cookie|dsn|api[_-]?key|access[_-]?token|refresh[_-]?token)/i;

function iso(value: Date | string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function requiredIso(value: Date | string): string {
  return iso(value) ?? new Date(0).toISOString();
}

function redactValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactValue);
  if (!value || typeof value !== "object") return value;
  const result: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    if (REDACTED_KEY.test(key) || SENSITIVE_KEY.test(key)) continue;
    result[key] = redactValue(child);
  }
  return result;
}

function redactedRecord(value: Record<string, unknown> | null | undefined): Record<string, unknown> | null {
  if (!value) return null;
  return redactValue(value) as Record<string, unknown>;
}

function safeSource(value: typeof runs.$inferSelect.source): RunView["source"] {
  return {
    ...(typeof value.repository === "string" ? { repository: value.repository } : {}),
    ...(typeof value.ref === "string" ? { ref: value.ref } : {}),
    ...(typeof value.commit === "string" ? { commit: value.commit } : {}),
    ...(typeof value.archiveDigest === "string" ? { archiveDigest: value.archiveDigest } : {}),
  };
}

function stableSessionId(attempt: typeof runAttempts.$inferSelect): string | null {
  if (!attempt.providerTerminalId) return null;
  const digest = createHash("sha256").update(attempt.providerTerminalId, "utf8").digest("hex").slice(0, 32);
  return `session_${digest}`;
}

function backendForExecutionProvider(provider: string): BackendProvider {
  return provider === "cloud-vm" ? "freestyle" : "unknown";
}

function checkedAt(value: Date | string | undefined): string {
  return requiredIso(value ?? new Date());
}

export type RunAdmissionInput = {
  readonly backendProvider: BackendProvider;
  readonly accountEligible?: boolean;
  readonly checkedAt?: Date | string;
  readonly limits?: RunAdmissionLimits | null;
};

/**
 * Build the public admission state without pretending an unconfigured adapter
 * is usable. This is deliberately pure so request and snapshot routes share
 * the same fail-closed vocabulary.
 */
export function runAdmissionFor(input: RunAdmissionInput): RunAdmissionView {
  const limits = input.limits ?? null;
  const at = checkedAt(input.checkedAt);
  if (input.accountEligible === false) {
    return { state: "denied", reasonCode: "account_ineligible", retryable: false, checkedAt: at, limits };
  }
  if (input.backendProvider === "huge-blue") {
    return { state: "unavailable", reasonCode: "adapter_not_configured", retryable: false, checkedAt: at, limits };
  }
  if (input.backendProvider === "unknown") {
    return { state: "unavailable", reasonCode: "provider_unknown", retryable: false, checkedAt: at, limits };
  }
  return { state: "admitted", reasonCode: "admitted", retryable: false, checkedAt: at, limits };
}

export function runRoutingFor(input: {
  readonly routing?: RunRoutingRequest;
  readonly backendProvider: BackendProvider;
  readonly accountClass?: RunAccountClass;
}): RunRoutingResult {
  const requestedProvider = input.routing?.requestedProvider ?? null;
  return {
    requestedProvider,
    selectedProvider: input.backendProvider,
    accountClass: input.routing?.accountClass ?? input.accountClass ?? "unknown",
  };
}

function placementFor(
  attempt: typeof runAttempts.$inferSelect,
  backendProvider: BackendProvider,
): RunPlacementView {
  return {
    executionProvider: "cloud-vm",
    backendProvider,
    sessionId: stableSessionId(attempt),
  };
}

function attemptView(
  attempt: typeof runAttempts.$inferSelect,
  backendProvider: BackendProvider,
  sandboxed: boolean,
  now = Date.now(),
): RunAttemptView {
  const retainedUntil = iso(attempt.terminalRetainUntil);
  // A sandboxed attempt's retained handle only waits for its destroy: never attachable.
  const attachable = !sandboxed
    && !!attempt.providerVmId
    && !!attempt.providerWorkspaceId
    && !!attempt.providerTerminalId
    && !!attempt.terminalRetainUntil
    && attempt.terminalRetainUntil.getTime() > now;
  return {
    id: attempt.id,
    ordinal: attempt.ordinal,
    status: attempt.status as AttemptStatus,
    runtimeId: attempt.runtimeId ?? null,
    placement: placementFor(attempt, backendProvider),
    attachable,
    retainedUntil,
    result: redactedRecord(attempt.result),
    exitCode: attempt.exitCode,
    error: attempt.error,
    startedAt: iso(attempt.startedAt),
    finishedAt: iso(attempt.finishedAt),
    createdAt: requiredIso(attempt.createdAt),
    updatedAt: requiredIso(attempt.updatedAt),
  };
}

function artifactView(artifact: typeof runArtifacts.$inferSelect): RunArtifactView {
  return {
    id: artifact.id,
    attemptId: artifact.attemptId,
    name: artifact.name,
    mediaType: artifact.mediaType,
    sizeBytes: artifact.sizeBytes,
    digest: artifact.digest,
    uri: artifact.uri,
    metadata: redactedRecord(artifact.metadata) ?? {},
    createdAt: requiredIso(artifact.createdAt),
  };
}

export function toRunSnapshotView(snapshot: RunSnapshotRow, options: RunViewOptions = {}): RunSnapshotView {
  const backendProvider = options.backendProvider
    ?? options.routing?.requestedProvider
    ?? backendForExecutionProvider(snapshot.run.provider);
  const routing = runRoutingFor({ routing: options.routing, backendProvider, accountClass: options.accountClass });
  const admission = runAdmissionFor({
    backendProvider,
    accountEligible: options.accountEligible,
    limits: options.limits,
    checkedAt: options.checkedAt,
  });
  const executionProvider: ExecutionProvider = "cloud-vm";
  const run: RunView = {
    id: snapshot.run.id,
    status: snapshot.run.status as RunStatus,
    environment: (snapshot.run.environment ?? "persistent") as RunEnvironment,
    image: snapshot.run.environment === "sandboxed" && snapshot.run.imageId
      ? { id: snapshot.run.imageId, version: snapshot.run.imageVersion ?? null }
      : null,
    recipe: snapshot.run.recipe,
    desiredAttempts: snapshot.run.desiredAttempts,
    source: safeSource(snapshot.run.source),
    provider: executionProvider,
    executionProvider,
    backendProvider,
    routing,
    admission,
    error: snapshot.run.error,
    cancelRequestedAt: iso(snapshot.run.cancelRequestedAt),
    completedAt: iso(snapshot.run.completedAt),
    createdAt: requiredIso(snapshot.run.createdAt),
    updatedAt: requiredIso(snapshot.run.updatedAt),
  };
  return {
    run,
    attempts: snapshot.attempts.map((attempt) => attemptView(attempt, backendProvider, snapshot.run.environment === "sandboxed")),
    artifacts: snapshot.artifacts.map(artifactView),
  };
}

export function toRunEventView(event: typeof runEvents.$inferSelect): RunEventView {
  return {
    id: event.id,
    runId: event.runId,
    attemptId: event.attemptId,
    sequence: event.sequence,
    attemptSequence: event.attemptSequence,
    externalId: event.externalId,
    kind: event.kind,
    payload: (redactValue(event.payload) ?? {}) as Record<string, unknown>,
    createdAt: requiredIso(event.createdAt),
  };
}

