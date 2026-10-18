import { createHash, randomUUID } from "node:crypto";

import type { CloudVmRunAdapter } from "./cloudVmRunAdapter";
import type { PersistentWorkspaceEffectBroker } from "./lifecycleEffectBroker";
import { VmHostLeaseError, type VmHostLeaseProvider, type VmHostLeaseTransport } from "./hostLeaseTransport";
import type { AttemptPromotionRuntimePort, PromotionRuntimeInput } from "../runs/promotion";

/** States persisted by the runtime owner.  Provider status is only an input. */
export const PERSISTENT_WORKSPACE_LIFECYCLES = [
  "provisioning",
  "running",
  "suspended",
  "stopped",
  "failed",
] as const;
export type PersistentWorkspaceLifecycle = (typeof PERSISTENT_WORKSPACE_LIFECYCLES)[number];

export type PersistentWorkspaceProviderId = "freestyle";

/** Provider handles are opaque ids, never bearer tokens or endpoint URLs. */
export type PersistentWorkspaceProviderHandles = {
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId?: string | null;
};

export type PersistentWorkspaceRecord = {
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly tenantId: string;
  readonly ownerId: string;
  readonly provider: PersistentWorkspaceProviderId;
  readonly lifecycle: PersistentWorkspaceLifecycle;
  readonly providerVmId: string | null;
  readonly providerWorkspaceId: string | null;
  readonly providerTerminalId: string | null;
  readonly idempotencyKey: string;
  readonly requestDigest: string;
  readonly workspaceName: string;
  readonly failureCode?: string | null;
  readonly failureMessage?: string | null;
  readonly version?: number;
  readonly createdAt: string;
  readonly updatedAt: string;
};

/**
 * This is the persistence seam for the runtime registry.  The database lane
 * can implement these methods with its `createRuntime/getRuntime/updateRuntime`
 * operations without making the workspace lifecycle depend on a new schema.
 * `createRuntime` must reserve `(tenantId, idempotencyKey)` atomically and
 * return `created: false` with the existing row for a replay.
 */
export type PersistentWorkspaceStore = {
  createRuntime(input: {
    readonly record: PersistentWorkspaceRecord;
  }): Promise<{ readonly record: PersistentWorkspaceRecord; readonly created: boolean }>;
  getRuntime(input: { readonly runtimeId: string }): Promise<PersistentWorkspaceRecord | null>;
  updateRuntime(input: {
    readonly runtimeId: string;
    readonly patch: Partial<
      Pick<
        PersistentWorkspaceRecord,
        | "lifecycle"
        | "providerVmId"
        | "providerWorkspaceId"
        | "providerTerminalId"
        | "failureCode"
        | "failureMessage"
      >
    >;
    readonly expectedVersion?: number;
  }): Promise<PersistentWorkspaceRecord>;
};

export type PersistentWorkspaceProviderInput = {
  readonly image?: string;
  readonly imageVersion?: string | null;
  readonly memoryMb?: number;
  readonly providerMetadata?: Record<string, unknown>;
  readonly networkId?: string;
  readonly terminal?: {
    readonly agent?: "claude" | "codex" | "opencode" | "pi";
    readonly prompt?: string;
    readonly cwd?: string;
  };
};

export type PersistentWorkspaceProviderCreateInput = {
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly tenantId: string;
  readonly ownerId: string;
  /** Runtime version used as the host-lease fencing generation. */
  readonly generation: number;
  /** Stable lifecycle effect identity. */
  readonly effectKey: string;
  readonly workspaceName: string;
  readonly workspaceKey: string;
  readonly providerInput?: PersistentWorkspaceProviderInput;
};

export type PersistentWorkspaceProviderLifecycleInput = {
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly tenantId: string;
  readonly ownerId: string;
  readonly providerVmId: string;
  /** Runtime version used as the host-lease fencing generation. */
  readonly generation: number;
  /** Stable lifecycle effect identity. */
  readonly effectKey: string;
};

export type PersistentWorkspaceProviderAdoptInput = PersistentWorkspaceProviderLifecycleInput & {
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
  readonly sessionId: string;
};

export type PersistentWorkspaceProvider = {
  readonly create: (input: PersistentWorkspaceProviderCreateInput) => Promise<PersistentWorkspaceProviderHandles>;
  readonly resume: (input: PersistentWorkspaceProviderLifecycleInput) => Promise<void>;
  readonly suspend: (input: PersistentWorkspaceProviderLifecycleInput) => Promise<void>;
  readonly stop?: (input: PersistentWorkspaceProviderLifecycleInput) => Promise<void>;
  /** Verify/adopt retained provider handles during run-attempt promotion. */
  readonly adopt?: (input: PersistentWorkspaceProviderAdoptInput) => Promise<void>;
  /** Return an attach descriptor; it may contain a short-lived bearer token. */
  readonly attach?: (input: {
    readonly record: PersistentWorkspaceRecord;
  }) => Promise<unknown>;
};

/** Provider-independent response. Internal provider handles are deliberately absent. */
export type PersistentWorkspaceView = {
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly provider: PersistentWorkspaceProviderId;
  readonly lifecycle: PersistentWorkspaceLifecycle;
  readonly workspaceName: string;
  readonly attachable: boolean;
  readonly failureCode?: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly attachTarget?: PersistentWorkspaceAttachTarget | null;
};

/** Safe attach material. Values matching credentials are replaced recursively. */
export type PersistentWorkspaceAttachTarget = {
  readonly redacted: true;
  readonly provider: PersistentWorkspaceProviderId;
  readonly runtimeId: string;
  readonly workspaceId: string;
  readonly target: Record<string, unknown>;
};

export type PersistentWorkspaceCreateInput = {
  readonly tenantId: string;
  readonly ownerId: string;
  readonly idempotencyKey: string;
  readonly workspaceName?: string;
  readonly providerInput?: PersistentWorkspaceProviderInput;
};

export type PersistentWorkspaceLookupInput = {
  readonly tenantId: string;
  readonly ownerId: string;
  readonly runtimeId: string;
};

export type PersistentWorkspacePromoteInput = {
  readonly tenantId: string;
  readonly ownerId: string;
  readonly idempotencyKey: string;
  readonly workspaceName?: string;
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
  readonly sessionId: string;
};

export class PersistentWorkspaceError extends Error {
  readonly code: string;

  constructor(code: string, message: string, options?: { readonly cause?: unknown }) {
    super(message, options);
    this.name = "PersistentWorkspaceError";
    this.code = code;
  }
}

export class PersistentWorkspaceOwnershipError extends PersistentWorkspaceError {
  constructor() {
    super("workspace_forbidden", "The persistent workspace is not owned by this tenant and owner.");
    this.name = "PersistentWorkspaceOwnershipError";
  }
}

export class PersistentWorkspaceNotFoundError extends PersistentWorkspaceError {
  constructor(runtimeId: string) {
    super("workspace_not_found", `Persistent workspace ${runtimeId} was not found.`);
    this.name = "PersistentWorkspaceNotFoundError";
  }
}

export class PersistentWorkspaceIdempotencyConflictError extends PersistentWorkspaceError {
  constructor() {
    super("workspace_idempotency_conflict", "The idempotency key was already used for a different workspace request.");
    this.name = "PersistentWorkspaceIdempotencyConflictError";
  }
}

export class PersistentWorkspaceInvalidStateError extends PersistentWorkspaceError {
  constructor(lifecycle: PersistentWorkspaceLifecycle, operation: string) {
    super("workspace_invalid_state", `Cannot ${operation} a workspace in ${lifecycle} state.`);
    this.name = "PersistentWorkspaceInvalidStateError";
  }
}

export class PersistentWorkspaceProviderError extends PersistentWorkspaceError {
  constructor(operation: string, cause: unknown) {
    super("workspace_provider_error", `Persistent workspace provider ${operation} failed.`, { cause });
    this.name = "PersistentWorkspaceProviderError";
  }
}

function requiredText(value: string, label: string, max = 256): string {
  const text = value.trim();
  if (!text || text.length > max || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new PersistentWorkspaceError("workspace_input_invalid", `${label} must be a printable non-empty string.`);
  }
  return text;
}

function newIdentity(prefix: "runtime" | "workspace"): string {
  return `${prefix}_${randomUUID().replaceAll("-", "")}`;
}

/**
 * Production persistence uses UUIDs because the durable workspace table stores
 * both identities as UUID columns. Tests and dependency-only callers keep the
 * historical readable identities by using the default factory.
 */
export type PersistentWorkspaceIdentity = {
  readonly runtimeId: string;
  readonly workspaceId: string;
};

export type PersistentWorkspaceIdentityFactory = () => PersistentWorkspaceIdentity;

function defaultIdentity(): PersistentWorkspaceIdentity {
  return {
    runtimeId: newIdentity("runtime"),
    workspaceId: newIdentity("workspace"),
  };
}

function requestDigest(input: PersistentWorkspaceCreateInput): string {
  const canonical = JSON.stringify({
    tenantId: input.tenantId,
    ownerId: input.ownerId,
    workspaceName: input.workspaceName?.trim() ?? "",
    // Provider metadata may contain secrets. It participates in the request
    // identity only when it is explicitly supplied by the caller, but is never
    // persisted by this service.
    providerInput: input.providerInput ?? null,
  });
  return `sha256:${createHash("sha256").update(canonical).digest("hex")}`;
}

function ownedBy(record: PersistentWorkspaceRecord, input: { readonly tenantId: string; readonly ownerId: string }): boolean {
  return record.tenantId === input.tenantId && record.ownerId === input.ownerId;
}

function assertOwned(record: PersistentWorkspaceRecord, input: { readonly tenantId: string; readonly ownerId: string }): void {
  if (!ownedBy(record, input)) throw new PersistentWorkspaceOwnershipError();
}

const REDACTED = "[redacted]";
const SENSITIVE_KEY = /(?:token|secret|password|credential|authorization|cookie|private.?key|access.?key|invite|invitation)/i;

function redactString(value: string): string {
  try {
    const url = new URL(value);
    for (const key of [...url.searchParams.keys()]) {
      if (SENSITIVE_KEY.test(key)) url.searchParams.set(key, REDACTED);
    }
    if (url.username || url.password) {
      url.username = REDACTED;
      url.password = REDACTED;
    }
    return url.toString();
  } catch {
    return value;
  }
}

function redactMessage(value: string): string {
  return redactString(value).replace(
    /((?:token|secret|password|authorization|credential|private[_-]?key)=)[^&\s]+/gi,
    "$1[redacted]",
  );
}

function redactUnknown(value: unknown): unknown {
  if (typeof value === "string") return redactString(value);
  if (Array.isArray(value)) return value.map(redactUnknown);
  if (!value || typeof value !== "object") return value;
  const object = value as Record<string, unknown>;
  return Object.fromEntries(Object.entries(object).map(([key, child]) => [
    key,
    SENSITIVE_KEY.test(key) ? REDACTED : redactUnknown(child),
  ]));
}

export function redactedAttachTarget(
  record: Pick<PersistentWorkspaceRecord, "provider" | "runtimeId" | "workspaceId">,
  target: unknown,
): PersistentWorkspaceAttachTarget {
  const safeTarget = redactUnknown(target);
  return {
    redacted: true,
    provider: record.provider,
    runtimeId: record.runtimeId,
    workspaceId: record.workspaceId,
    target: safeTarget && typeof safeTarget === "object" && !Array.isArray(safeTarget)
      ? safeTarget as Record<string, unknown>
      : { value: safeTarget },
  };
}

function viewOf(record: PersistentWorkspaceRecord, attachTarget?: PersistentWorkspaceAttachTarget | null): PersistentWorkspaceView {
  return {
    runtimeId: record.runtimeId,
    workspaceId: record.workspaceId,
    provider: record.provider,
    lifecycle: record.lifecycle,
    workspaceName: record.workspaceName,
    attachable: record.lifecycle === "running" || record.lifecycle === "suspended",
    failureCode: record.failureCode ?? null,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    ...(attachTarget !== undefined ? { attachTarget } : {}),
  };
}

export type PersistentWorkspaceService = ReturnType<typeof createPersistentWorkspaceService>;

let configuredService: PersistentWorkspaceService | null = null;

/**
 * The application composition root installs the database-backed service at
 * startup. Keeping the setter here lets route tests and provider dogfood wire a
 * mocked store without importing database clients or provider credentials.
 */
export function configurePersistentWorkspaceService(service: PersistentWorkspaceService | null): void {
  configuredService = service;
}

export function persistentWorkspaceService(): PersistentWorkspaceService | null {
  return configuredService;
}

export function createPersistentWorkspaceService(input: {
  readonly store: PersistentWorkspaceStore;
  readonly provider: PersistentWorkspaceProvider;
  readonly now?: () => Date;
  /** Optional production identity source; defaults to test-friendly prefixes. */
  readonly identity?: PersistentWorkspaceIdentityFactory;
}): {
  readonly create: (request: PersistentWorkspaceCreateInput) => Promise<PersistentWorkspaceView>;
  readonly get: (request: PersistentWorkspaceLookupInput) => Promise<PersistentWorkspaceView>;
  readonly resume: (request: PersistentWorkspaceLookupInput) => Promise<PersistentWorkspaceView>;
  readonly suspend: (request: PersistentWorkspaceLookupInput) => Promise<PersistentWorkspaceView>;
  readonly stop: (request: PersistentWorkspaceLookupInput) => Promise<PersistentWorkspaceView>;
  readonly promote: (request: PersistentWorkspacePromoteInput) => Promise<PersistentWorkspaceView>;
  readonly attach: (request: PersistentWorkspaceLookupInput) => Promise<PersistentWorkspaceAttachTarget>;
} {
  const now = input.now ?? (() => new Date());

  async function readOwned(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceRecord> {
    const runtimeId = requiredText(request.runtimeId, "runtimeId", 160);
    const record = await input.store.getRuntime({ runtimeId });
    if (!record) throw new PersistentWorkspaceNotFoundError(runtimeId);
    assertOwned(record, request);
    return record;
  }

  async function update(record: PersistentWorkspaceRecord, patch: Parameters<PersistentWorkspaceStore["updateRuntime"]>[0]["patch"]): Promise<PersistentWorkspaceRecord> {
    try {
      return await input.store.updateRuntime({ runtimeId: record.runtimeId, patch, expectedVersion: record.version });
    } catch (cause) {
      throw new PersistentWorkspaceError("workspace_persistence_error", "Persistent workspace state could not be saved.", { cause });
    }
  }

  async function attachTarget(record: PersistentWorkspaceRecord): Promise<PersistentWorkspaceAttachTarget> {
    const fallback = {
      provider: record.provider,
      vmId: record.providerVmId,
      workspaceId: record.providerWorkspaceId,
      terminalId: record.providerTerminalId,
    };
    const raw = input.provider.attach ? await input.provider.attach({ record }) : fallback;
    return redactedAttachTarget(record, raw ?? fallback);
  }

  async function replayedWorkspaceView(
    reservation: { readonly record: PersistentWorkspaceRecord; readonly created: boolean },
    digest: string,
  ): Promise<PersistentWorkspaceView | null> {
    if (reservation.created) return null;
    if (reservation.record.requestDigest !== digest) throw new PersistentWorkspaceIdempotencyConflictError();
    const lifecycle = reservation.record.lifecycle;
    if (lifecycle !== "running" && lifecycle !== "suspended" && lifecycle !== "stopped") return null;
    const attach = lifecycle === "running" || lifecycle === "suspended" ? await attachTarget(reservation.record) : null;
    return viewOf(reservation.record, attach);
  }

  async function create(request: PersistentWorkspaceCreateInput): Promise<PersistentWorkspaceView> {
    const tenantId = requiredText(request.tenantId, "tenantId");
    const ownerId = requiredText(request.ownerId, "ownerId");
    const idempotencyKey = requiredText(request.idempotencyKey, "idempotencyKey", 128);
    const workspaceName = requiredText(request.workspaceName ?? "Persistent workspace", "workspaceName", 160);
    const identity = input.identity?.() ?? defaultIdentity();
    const runtimeId = identity.runtimeId;
    const workspaceId = identity.workspaceId;
    const digest = requestDigest({ ...request, tenantId, ownerId, idempotencyKey, workspaceName });
    const timestamp = now().toISOString();
    const provisional: PersistentWorkspaceRecord = {
      runtimeId,
      workspaceId,
      tenantId,
      ownerId,
      provider: "freestyle",
      lifecycle: "provisioning",
      providerVmId: null,
      providerWorkspaceId: null,
      providerTerminalId: null,
      idempotencyKey,
      requestDigest: digest,
      workspaceName,
      failureCode: null,
      failureMessage: null,
      version: 1,
      createdAt: timestamp,
      updatedAt: timestamp,
    };

    let reservation: { readonly record: PersistentWorkspaceRecord; readonly created: boolean };
    try {
      reservation = await input.store.createRuntime({ record: provisional });
    } catch (cause) {
      throw new PersistentWorkspaceError("workspace_persistence_error", "Persistent workspace could not be reserved.", { cause });
    }
    let record = reservation.record;
    assertOwned(record, { tenantId, ownerId });
    const replay = await replayedWorkspaceView(reservation, digest);
    if (replay) return replay;

    try {
      const handles = await input.provider.create({
        runtimeId: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        generation: Math.max(1, record.version ?? 1),
        effectKey: `cmux-runtime:${record.runtimeId}:create:v${Math.max(1, record.version ?? 1)}`,
        workspaceName: record.workspaceName,
        workspaceKey: `cmux-runtime:${record.runtimeId}:workspace`,
        providerInput: request.providerInput,
      });
      if (!handles.providerVmId || !handles.providerWorkspaceId) {
        throw new Error("provider returned incomplete workspace handles");
      }
      record = await update(record, {
        lifecycle: "running",
        providerVmId: handles.providerVmId,
        providerWorkspaceId: handles.providerWorkspaceId,
        providerTerminalId: handles.providerTerminalId ?? null,
        failureCode: null,
        failureMessage: null,
      });
      return viewOf(record, await attachTarget(record));
    } catch (cause) {
      try {
        await update(record, {
          lifecycle: "failed",
          failureCode: cause instanceof PersistentWorkspaceError ? cause.code : "provider_create_failed",
          failureMessage: redactMessage(cause instanceof Error ? cause.message.slice(0, 500) : String(cause).slice(0, 500)),
        });
      } catch {
        // Keep the provider failure as the response; the persistence lane will
        // reconcile a still-provisioning row on its next retry.
      }
      if (cause instanceof PersistentWorkspaceError) throw cause;
      throw new PersistentWorkspaceProviderError("create", cause);
    }
  }

  async function promote(request: PersistentWorkspacePromoteInput): Promise<PersistentWorkspaceView> {
    const tenantId = requiredText(request.tenantId, "tenantId");
    const ownerId = requiredText(request.ownerId, "ownerId");
    const idempotencyKey = requiredText(request.idempotencyKey, "idempotencyKey", 128);
    const workspaceName = requiredText(request.workspaceName ?? "Promoted workspace", "workspaceName", 160);
    const providerVmId = requiredText(request.providerVmId, "providerVmId", 256);
    const providerWorkspaceId = requiredText(request.providerWorkspaceId, "providerWorkspaceId", 256);
    const providerTerminalId = requiredText(request.providerTerminalId, "providerTerminalId", 256);
    const sessionId = requiredText(request.sessionId, "sessionId", 256);
    const digest = requestDigest({
      tenantId,
      ownerId,
      idempotencyKey,
      workspaceName,
      providerInput: { providerMetadata: { providerVmId, providerWorkspaceId, providerTerminalId, sessionId } },
    });
    const timestamp = now().toISOString();
    const identity = input.identity?.() ?? defaultIdentity();
    const provisional: PersistentWorkspaceRecord = {
      runtimeId: identity.runtimeId,
      workspaceId: identity.workspaceId,
      tenantId,
      ownerId,
      provider: "freestyle",
      lifecycle: "provisioning",
      providerVmId,
      providerWorkspaceId,
      providerTerminalId,
      idempotencyKey,
      requestDigest: digest,
      workspaceName,
      failureCode: null,
      failureMessage: null,
      version: 1,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    let reservation: { readonly record: PersistentWorkspaceRecord; readonly created: boolean };
    try {
      reservation = await input.store.createRuntime({ record: provisional });
    } catch (cause) {
      throw new PersistentWorkspaceError("workspace_persistence_error", "Promoted workspace could not be reserved.", { cause });
    }
    let record = reservation.record;
    assertOwned(record, { tenantId, ownerId });
    const replay = await replayedWorkspaceView(reservation, digest);
    if (replay) return replay;
    if (!input.provider.adopt) {
      throw new PersistentWorkspaceProviderError("promote", new Error("persistent workspace provider adoption is not configured"));
    }
    try {
      await input.provider.adopt({
        runtimeId: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        providerVmId: record.providerVmId ?? providerVmId,
        providerWorkspaceId: record.providerWorkspaceId ?? providerWorkspaceId,
        providerTerminalId: record.providerTerminalId ?? providerTerminalId,
        sessionId,
        generation: Math.max(1, record.version ?? 1),
        effectKey: `cmux-runtime:${record.runtimeId}:promote:v${Math.max(1, record.version ?? 1)}`,
      });
      record = await update(record, { lifecycle: "running", failureCode: null, failureMessage: null });
      return viewOf(record, await attachTarget(record));
    } catch (cause) {
      try {
        await update(record, {
          lifecycle: "failed",
          failureCode: "provider_promote_failed",
          failureMessage: redactMessage(cause instanceof Error ? cause.message.slice(0, 500) : String(cause).slice(0, 500)),
        });
      } catch {
        // Preserve the provider failure; reconciliation can retry the row.
      }
      if (cause instanceof PersistentWorkspaceError) throw cause;
      throw new PersistentWorkspaceProviderError("promote", cause);
    }
  }

  async function get(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceView> {
    return viewOf(await readOwned(request));
  }

  async function resume(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceView> {
    let record = await readOwned(request);
    if (record.lifecycle === "running") return viewOf(record, await attachTarget(record));
    if (record.lifecycle === "provisioning") throw new PersistentWorkspaceInvalidStateError(record.lifecycle, "resume");
    if (record.lifecycle === "failed" || !record.providerVmId) throw new PersistentWorkspaceInvalidStateError(record.lifecycle, "resume");
    try {
      await input.provider.resume({
        runtimeId: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        providerVmId: record.providerVmId,
        generation: Math.max(1, record.version ?? 1),
        effectKey: `cmux-runtime:${record.runtimeId}:resume:v${Math.max(1, record.version ?? 1)}`,
      });
      record = await update(record, { lifecycle: "running", failureCode: null, failureMessage: null });
      return viewOf(record, await attachTarget(record));
    } catch (cause) {
      try {
        record = await update(record, {
          lifecycle: "failed",
          failureCode: "provider_resume_failed",
          failureMessage: redactMessage(cause instanceof Error ? cause.message.slice(0, 500) : String(cause).slice(0, 500)),
        });
      } catch { /* preserve the provider error below */ }
      throw new PersistentWorkspaceProviderError("resume", cause);
    }
  }

  async function suspend(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceView> {
    let record = await readOwned(request);
    if (record.lifecycle === "suspended") return viewOf(record);
    if (record.lifecycle === "stopped" || record.lifecycle === "failed" || record.lifecycle === "provisioning" || !record.providerVmId) {
      throw new PersistentWorkspaceInvalidStateError(record.lifecycle, "suspend");
    }
    try {
      await input.provider.suspend({
        runtimeId: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        providerVmId: record.providerVmId,
        generation: Math.max(1, record.version ?? 1),
        effectKey: `cmux-runtime:${record.runtimeId}:suspend:v${Math.max(1, record.version ?? 1)}`,
      });
      record = await update(record, { lifecycle: "suspended" });
      return viewOf(record);
    } catch (cause) {
      throw new PersistentWorkspaceProviderError("suspend", cause);
    }
  }

  async function stop(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceView> {
    let record = await readOwned(request);
    if (record.lifecycle === "stopped") return viewOf(record);
    if (record.lifecycle === "suspended") {
      record = await update(record, { lifecycle: "stopped" });
      return viewOf(record);
    }
    if (record.lifecycle === "failed" || record.lifecycle === "provisioning" || !record.providerVmId) {
      throw new PersistentWorkspaceInvalidStateError(record.lifecycle, "stop");
    }
    try {
      const lifecycleInput = {
        runtimeId: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        providerVmId: record.providerVmId,
        generation: Math.max(1, record.version ?? 1),
        effectKey: `cmux-runtime:${record.runtimeId}:stop:v${Math.max(1, record.version ?? 1)}`,
      };
      if (input.provider.stop) await input.provider.stop(lifecycleInput);
      else await input.provider.suspend(lifecycleInput);
      record = await update(record, { lifecycle: "stopped" });
      return viewOf(record);
    } catch (cause) {
      throw new PersistentWorkspaceProviderError("stop", cause);
    }
  }

  async function attach(request: PersistentWorkspaceLookupInput): Promise<PersistentWorkspaceAttachTarget> {
    const record = await readOwned(request);
    if (record.lifecycle !== "running" && record.lifecycle !== "suspended") {
      throw new PersistentWorkspaceInvalidStateError(record.lifecycle, "attach");
    }
    try {
      return await attachTarget(record);
    } catch (cause) {
      throw new PersistentWorkspaceProviderError("attach", cause);
    }
  }

  return { create, get, resume, suspend, stop, promote, attach };
}

/**
 * Build the provider half from the existing VM provider and CloudVmRunAdapter.
 * The `provisionVm` callback is intentionally supplied by the route/workflow:
 * it must run `createVm` through the normal entitlement and admission checks.
 */
export function persistentWorkspaceProviderFromCloudVm(input: {
  readonly provisionVm: (request: PersistentWorkspaceProviderCreateInput) => Promise<{ readonly providerVmId: string }>;
  readonly vm: {
    readonly resume: (providerVmId: string) => Promise<unknown>;
    readonly pause: (providerVmId: string) => Promise<void>;
  };
  readonly runAdapter: Pick<CloudVmRunAdapter, "createWorkspace" | "createTerminal">;
  /** Durable host lease transport built from the configured adapter registry. */
  readonly hostLeaseTransport: VmHostLeaseTransport;
  /** Durable broker receipt executor for every provider effect. */
  readonly effectBroker: PersistentWorkspaceEffectBroker;
  /** Host class selected by the configured provider adapter (for example freestyle). */
  readonly hostLeaseProvider: VmHostLeaseProvider;
  readonly hostLeaseTtlMs?: number;
  readonly attach?: (record: PersistentWorkspaceRecord) => Promise<unknown>;
}): PersistentWorkspaceProvider {
  function assertHostAdapterConfigured(): void {
    if (!input.hostLeaseTransport.hasConfiguredProvider(input.hostLeaseProvider)) {
      throw new VmHostLeaseError("provider_mismatch", `no host lease adapter configured for ${input.hostLeaseProvider}`);
    }
  }

  function lifecyclePayload(operation: string, values: Record<string, unknown>): Record<string, unknown> {
    return { operation, ...values };
  }

  async function withHostLease<T extends Record<string, unknown>>(request: {
    readonly tenantId: string;
    readonly ownerId: string;
    readonly runtimeId: string;
    readonly workspaceId: string;
    readonly providerVmId: string;
    readonly generation: number;
    readonly effectKey: string;
    readonly payload: Record<string, unknown>;
    readonly run: () => Promise<T>;
  }): Promise<T> {
    assertHostAdapterConfigured();
    const nowMs = Date.now();
    const leaseId = `cmux-runtime:${request.runtimeId}`;
    const leaseEffectKey = `${request.effectKey}:lease-acquire`;
    const releaseEffectKey = `${request.effectKey}:lease-release`;
    const result = await input.effectBroker.execute({
      tenantId: request.tenantId,
      ownerId: request.ownerId,
      hostClass: input.hostLeaseProvider,
      effectKey: request.effectKey,
      payload: request.payload,
      run: async () => {
        const acquired = await input.hostLeaseTransport.acquire({
          provider: input.hostLeaseProvider,
          leaseId,
          hostId: request.providerVmId,
          ownerId: request.ownerId,
          generation: request.generation,
          effectKey: leaseEffectKey,
          ttlMs: input.hostLeaseTtlMs,
          nowMs,
        });
        if (acquired.state !== "active") {
          throw new VmHostLeaseError("receipt_mismatch", "host lease acquire did not return an active receipt");
        }
        try {
          return await request.run();
        } finally {
          await input.hostLeaseTransport.release({
            provider: input.hostLeaseProvider,
            leaseId,
            hostId: request.providerVmId,
            ownerId: request.ownerId,
            generation: request.generation,
            effectKey: releaseEffectKey,
            ttlMs: input.hostLeaseTtlMs,
            nowMs: Date.now(),
          });
        }
      },
    });
    return result.result as T;
  }

  return {
    async create(request) {
      assertHostAdapterConfigured();
      const result = await input.effectBroker.execute({
        tenantId: request.tenantId,
        ownerId: request.ownerId,
        hostClass: input.hostLeaseProvider,
        effectKey: request.effectKey,
        payload: lifecyclePayload("create", {
          runtimeId: request.runtimeId,
          workspaceId: request.workspaceId,
          workspaceName: request.workspaceName,
        }),
        run: async () => {
          const vm = await input.provisionVm(request);
          const acquired = await input.hostLeaseTransport.acquire({
            provider: input.hostLeaseProvider,
            leaseId: `cmux-runtime:${request.runtimeId}`,
            hostId: vm.providerVmId,
            ownerId: request.ownerId,
            generation: request.generation,
            effectKey: `${request.effectKey}:lease-acquire`,
            ttlMs: input.hostLeaseTtlMs,
            nowMs: Date.now(),
          });
          if (acquired.state !== "active") {
            throw new VmHostLeaseError("receipt_mismatch", "host lease acquire did not return an active receipt");
          }
          try {
            const workspace = await input.runAdapter.createWorkspace({
              runtimeId: request.runtimeId,
              vmId: vm.providerVmId,
              workspaceName: request.workspaceName,
              workspaceKey: request.workspaceKey,
            });
            let providerTerminalId: string | undefined;
            const terminal = request.providerInput?.terminal;
            if (terminal?.prompt) {
              const terminalRef = await input.runAdapter.createTerminal({
                runtimeId: request.runtimeId,
                vmId: vm.providerVmId,
                workspaceId: workspace.workspaceId,
                agent: terminal.agent ?? "codex",
                prompt: terminal.prompt,
                cwd: terminal.cwd,
              });
              providerTerminalId = terminalRef.terminalId;
            }
            return {
              providerVmId: vm.providerVmId,
              providerWorkspaceId: workspace.workspaceId,
              ...(providerTerminalId ? { providerTerminalId } : {}),
            };
          } finally {
            await input.hostLeaseTransport.release({
              provider: input.hostLeaseProvider,
              leaseId: `cmux-runtime:${request.runtimeId}`,
              hostId: vm.providerVmId,
              ownerId: request.ownerId,
              generation: request.generation,
              effectKey: `${request.effectKey}:lease-release`,
              ttlMs: input.hostLeaseTtlMs,
              nowMs: Date.now(),
            });
          }
        },
      });
      const value = result.result;
      if (typeof value.providerVmId !== "string" || typeof value.providerWorkspaceId !== "string") {
        throw new Error("broker receipt returned incomplete workspace handles");
      }
      return {
        providerVmId: value.providerVmId,
        providerWorkspaceId: value.providerWorkspaceId,
        ...(typeof value.providerTerminalId === "string" ? { providerTerminalId: value.providerTerminalId } : {}),
      };
    },
    async resume(request) {
      await withHostLease({
        ...request,
        payload: lifecyclePayload("resume", {
          runtimeId: request.runtimeId,
          workspaceId: request.workspaceId,
          providerVmId: request.providerVmId,
        }),
        run: async () => {
          await input.vm.resume(request.providerVmId);
          return { ok: true };
        },
      });
    },
    async suspend(request) {
      await withHostLease({
        ...request,
        payload: lifecyclePayload("suspend", {
          runtimeId: request.runtimeId,
          workspaceId: request.workspaceId,
          providerVmId: request.providerVmId,
        }),
        run: async () => {
          await input.vm.pause(request.providerVmId);
          return { ok: true };
        },
      });
    },
    async stop(request) {
      await withHostLease({
        ...request,
        payload: lifecyclePayload("stop", {
          runtimeId: request.runtimeId,
          workspaceId: request.workspaceId,
          providerVmId: request.providerVmId,
        }),
        run: async () => {
          // A provider may expose a true stop later; the current VM facade's
          // pause operation is the safe terminal fallback.
          await input.vm.pause(request.providerVmId);
          return { ok: true };
        },
      });
    },
    async adopt(request) {
      await withHostLease({
        ...request,
        payload: lifecyclePayload("promote", {
          runtimeId: request.runtimeId,
          workspaceId: request.workspaceId,
          providerVmId: request.providerVmId,
        }),
        run: async () => {
          // The retained handles are already provider-owned. The fenced lease
          // and durable broker receipt make adoption safe across retries while
          // keeping those handles out of broker payloads and public views.
          return { ok: true };
        },
      });
    },
    ...(input.attach ? { attach: async ({ record }: { readonly record: PersistentWorkspaceRecord }) => input.attach!(record) } : {}),
  };
}

/**
 * Reuses the persistent workspace lifecycle for run-attempt promotion. The
 * promotion port receives the source terminal's stable session id and keeps
 * it unchanged; provider handles stay inside the service/store boundary.
 */
export function createPersistentWorkspacePromotionRuntimePort(input: {
  readonly service: Pick<PersistentWorkspaceService, "promote">;
}): AttemptPromotionRuntimePort {
  return {
    async promote(request: PromotionRuntimeInput) {
      const workspace = await input.service.promote({
        tenantId: request.billingTeamId?.trim() || request.userId,
        ownerId: request.userId,
        idempotencyKey: request.requestKey,
        workspaceName: `Promoted ${request.runId}`,
        providerVmId: request.providerVmId,
        providerWorkspaceId: request.providerWorkspaceId,
        providerTerminalId: request.providerTerminalId,
        sessionId: request.sessionId,
      });
      return {
        runtimeId: workspace.runtimeId,
        workspaceId: workspace.workspaceId,
        state: workspace.lifecycle === "suspended" ? "paused" : "ready",
        sessionId: request.sessionId,
        transport: "cmux-remote",
        attachExpiresAt: null,
      };
    },
  };
}
