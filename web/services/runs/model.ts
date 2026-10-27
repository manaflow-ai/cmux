import { createHash, randomUUID } from "node:crypto";

export const RUN_STATUSES = ["queued", "running", "cancelling", "succeeded", "failed", "cancelled"] as const;
export type RunStatus = (typeof RUN_STATUSES)[number];

export const ATTEMPT_STATUSES = ["queued", "leased", "running", "succeeded", "failed", "cancelled", "expired"] as const;
export type AttemptStatus = (typeof ATTEMPT_STATUSES)[number];

export type RunEventKind =
  | "run.created"
  | "attempt.queued"
  | "attempt.started"
  | "attempt.heartbeat"
  | "attempt.output"
  | "attempt.artifact"
  | "attempt.succeeded"
  | "attempt.failed"
  | "run.cancel_requested"
  | "run.completed";

export const RUN_EVENT_KINDS = ["run.created", "attempt.queued", "attempt.started", "attempt.heartbeat", "attempt.output", "attempt.artifact", "attempt.succeeded", "attempt.failed", "run.cancel_requested", "run.completed"] as const;

/** The execution surface exposed by the Run API. */
export const EXECUTION_PROVIDERS = ["cloud-vm"] as const;
export type ExecutionProvider = (typeof EXECUTION_PROVIDERS)[number];

/** Provider adapters are intentionally narrower than the execution surface. */
export const BACKEND_PROVIDERS = ["freestyle", "huge-blue", "unknown"] as const;
export type BackendProvider = (typeof BACKEND_PROVIDERS)[number];

export const RUN_ADMISSION_STATES = ["admitted", "denied", "pending", "unavailable"] as const;
export type RunAdmissionState = (typeof RUN_ADMISSION_STATES)[number];

export const RUN_ADMISSION_REASON_CODES = [
  "admitted",
  "account_ineligible",
  "adapter_not_configured",
  "provider_unavailable",
  "provider_unknown",
] as const;
export type RunAdmissionReasonCode = (typeof RUN_ADMISSION_REASON_CODES)[number];

export const RUN_ACCOUNT_CLASSES = ["personal", "team", "unknown"] as const;
export type RunAccountClass = (typeof RUN_ACCOUNT_CLASSES)[number];

/** Safe provider-selection input. Account and machine identifiers never belong here. */
export type RunRoutingRequest = {
  readonly requestedProvider?: BackendProvider;
  readonly accountClass?: RunAccountClass;
};

export type RunAdmissionLimits = {
  readonly maxAttempts?: number | null;
  readonly maxActiveSessions?: number | null;
};

export type RunAdmissionView = {
  readonly state: RunAdmissionState;
  readonly reasonCode: RunAdmissionReasonCode;
  readonly retryable: boolean;
  readonly checkedAt: string;
  readonly limits: RunAdmissionLimits | null;
};

export type RunRoutingResult = {
  readonly requestedProvider: BackendProvider | null;
  readonly selectedProvider: BackendProvider;
  readonly accountClass: RunAccountClass;
};

export type RunPlacementView = {
  readonly executionProvider: ExecutionProvider;
  readonly backendProvider: BackendProvider;
  /** Opaque and stable across snapshots; never a provider machine address. */
  readonly sessionId: string | null;
};

export type RunAttemptView = {
  readonly id: string;
  readonly ordinal: number;
  readonly status: AttemptStatus;
  /** Opaque durable runtime identity; provider handles remain private. */
  readonly runtimeId: string | null;
  readonly placement: RunPlacementView;
  readonly attachable: boolean;
  readonly retainedUntil: string | null;
  readonly result: Record<string, unknown> | null;
  readonly exitCode: number | null;
  readonly error: string | null;
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type RunArtifactView = {
  readonly id: string;
  readonly attemptId: string;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
  readonly digest: string;
  readonly uri: string;
  readonly metadata: Record<string, unknown>;
  readonly createdAt: string;
};

/**
 * Where a Run executes (hq#3367). `persistent` is the existing fan-out path. `sandboxed` boots
 * one VM from a pinned manifest image, runs one task and destroys the VM on every exit path; it
 * is never promoted, paused or retained for attach.
 */
export const RUN_ENVIRONMENTS = ["persistent", "sandboxed"] as const;
export type RunEnvironment = (typeof RUN_ENVIRONMENTS)[number];

/** A sandbox attempt whose lease lapsed this long ago lost its controller; the reaper fails it. */
export const SANDBOX_ABANDONED_GRACE_MS = 2 * 60_000;
/**
 * After a sandbox's terminal event, how long its launcher has to record the outcome and hand the
 * VM to the reaper (which makes it due at once) before the reaper takes it anyway.
 */
export const SANDBOX_HANDOFF_GRACE_MS = 2 * 60_000;
/** A queued sandbox attempt never leased within this window never will be. */
export const SANDBOX_QUEUED_ABANDON_MS = 16 * 60_000;

/** Every sandbox VM's create key starts with this; the VM workflows refuse pause, snapshot and fork on it. */
export const SANDBOX_VM_IDEMPOTENCY_PREFIX = "sandbox-run:";

export function sandboxVmIdempotencyKey(runId: string, attemptId: string): string {
  return `${SANDBOX_VM_IDEMPOTENCY_PREFIX}${runId}:attempt:${attemptId}`;
}

/**
 * The providerMetadata key the sandbox launcher sets on its VM (to its create key). Only the
 * server writes providerMetadata, so a VM is a sandbox's when this and its create key agree; a
 * row that only happens to carry the key prefix stays an ordinary machine.
 */
export const SANDBOX_VM_MARKER_KEY = "cmuxSandboxRun";

/**
 * Set on a sandbox VM's row once a strict destroy confirmed the provider no longer has it. A
 * `destroyed` status alone is not proof (status reconciliation writes it from what the provider
 * answers), so the reaper keeps looking for a marked machine until this is set.
 */
export const SANDBOX_VM_DESTROY_CONFIRMED_KEY = "cmuxSandboxDestroyConfirmed";

export function isSandboxRunVm(vm: { readonly idempotencyKey: string | null; readonly providerMetadata?: Readonly<Record<string, unknown>> | null }): boolean {
  const key = vm.idempotencyKey;
  return !!key && key.startsWith(SANDBOX_VM_IDEMPOTENCY_PREFIX) && vm.providerMetadata?.[SANDBOX_VM_MARKER_KEY] === key;
}

export type RunView = {
  readonly id: string;
  readonly status: RunStatus;
  readonly environment: RunEnvironment;
  /** The pinned manifest image of a sandboxed Run; null for persistent Runs. */
  readonly image: { readonly id: string; readonly version: string | null } | null;
  readonly recipe: string;
  readonly desiredAttempts: number;
  readonly source: ImmutableRunSource;
  /** Kept as an alias for existing clients; always `cloud-vm` today. */
  readonly provider: ExecutionProvider;
  readonly executionProvider: ExecutionProvider;
  readonly backendProvider: BackendProvider;
  readonly routing: RunRoutingResult;
  readonly admission: RunAdmissionView;
  readonly error: string | null;
  readonly cancelRequestedAt: string | null;
  readonly completedAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type RunSnapshotView = {
  readonly run: RunView;
  readonly attempts: readonly RunAttemptView[];
  readonly artifacts: readonly RunArtifactView[];
};

export type RunEventView = {
  readonly id: string;
  readonly runId: string;
  readonly attemptId: string | null;
  readonly sequence: number;
  readonly attemptSequence: number | null;
  readonly externalId: string | null;
  readonly kind: RunEventKind;
  readonly payload: Record<string, unknown>;
  readonly createdAt: string;
};

export function isRunEventKind(value: unknown): value is RunEventKind {
  return typeof value === "string" && (RUN_EVENT_KINDS as readonly string[]).includes(value);
}

export type ImmutableRunSource = {
  readonly repository?: string;
  readonly ref?: string;
  readonly commit?: string;
  readonly archiveDigest?: string;
};

export type RunCursor = { readonly sequence: number; readonly eventId?: string };

export const DEFAULT_LEASE_TTL_MS = 60_000;
/** Completed cloud terminals stay available for a bounded attach window. */
export const DEFAULT_TERMINAL_RETENTION_MS = 10 * 60_000;
/** Attach tickets are deliberately shorter lived than the retained terminal. */
export const DEFAULT_ATTACH_TICKET_TTL_MS = 2 * 60_000;
/** Reaper workers fence one another while provider teardown is in flight. */
export const TERMINAL_CLEANUP_LEASE_MS = 60_000;
export const MAX_EVENT_PAYLOAD_BYTES = 256 * 1024;
export const MAX_ARTIFACT_BYTES = 512 * 1024 * 1024;
export const ALLOWED_RUN_RECIPES = ["parallel-review"] as const;
export type RunRecipe = (typeof ALLOWED_RUN_RECIPES)[number];

export function newId(): string {
  return randomUUID();
}

export function encodeRunCursor(cursor: RunCursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

export function decodeRunCursor(value: string | null | undefined): RunCursor | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    const sequence = (parsed as { sequence?: unknown }).sequence;
    const eventId = (parsed as { eventId?: unknown }).eventId;
    if (!Number.isSafeInteger(sequence) || (eventId !== undefined && typeof eventId !== "string")) return null;
    return { sequence: sequence as number, ...(eventId ? { eventId } : {}) };
  } catch {
    return null;
  }
}

export function artifactDigest(bytes: Uint8Array): string {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

export function isArtifactDigest(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[0-9a-f]{64}$/i.test(value);
}

export function verifyArtifactDigest(bytes: Uint8Array, expected: string): boolean {
  return isArtifactDigest(expected) && artifactDigest(bytes).toLowerCase() === expected.toLowerCase();
}

export function assertArtifactDigest(bytes: Uint8Array, expected: string): void {
  if (!verifyArtifactDigest(bytes, expected)) throw new Error("artifact digest mismatch");
}

export function leaseIsValid(leaseUntil: Date | null | undefined, now = Date.now()): boolean {
  return leaseUntil !== null && leaseUntil !== undefined && leaseUntil.getTime() > now;
}

export function jsonByteLength(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

export function boundedLimit(value: string | null | undefined, fallback = 100): number {
  const parsed = value === null || value === undefined || value === "" ? fallback : Number(value);
  return Number.isSafeInteger(parsed) ? Math.max(1, Math.min(parsed, 500)) : fallback;
}

