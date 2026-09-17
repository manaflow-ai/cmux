/**
 * Paid plans include 50 independent machines per seat. CPU, memory, and disk
 * describe each machine; there is no aggregate resource quota. This module is
 * dependency-free so provider sizing does not import the billing graph.
 */
export const PAID_MAX_ACTIVE_VMS_DEFAULT = 50;
export const PLAN_MACHINE_MEMORY_MB = 8192;
export const VM_MEMORY_MB_PER_VCPU = 4096;

/** New machines start with this disk. Freestyle resizes disks grow-only. */
export const VM_DISK_MB_DEFAULT = 32768;
/** Freestyle Pro's documented per-VM disk ceiling. */
export const VM_DISK_MB_MAX = 262144;
/** User-facing disk sizes are aligned to whole GiB steps. */
export const VM_DISK_MB_STEP = 4096;

export type VmResourceReservation = {
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly diskMb: number;
};

export type VmResourceName = keyof VmResourceReservation;

/**
 * Bounds for provider-reported machine dimensions. CPU and memory match the
 * supported image ladder; disk also permits the grow-only resize ceiling.
 * Callers must use their conservative fallback when a provider value is
 * outside these bounds instead of treating it as a real machine shape.
 */
export const VM_PROVIDER_RESOURCE_BOUNDS = {
  vcpus: { min: 1, max: 32 },
  memoryMb: { min: 4 * 1024, max: 64 * 1024 },
  diskMb: { min: 16 * 1024, max: VM_DISK_MB_MAX },
} as const satisfies Record<VmResourceName, { min: number; max: number }>;

/** Read one provider dimension only when it is a supported machine shape. */
export function vmProviderResourceSize(
  resource: VmResourceName,
  value: unknown,
): number | null {
  const bounds = VM_PROVIDER_RESOURCE_BOUNDS[resource];
  return typeof value === "number" && Number.isSafeInteger(value) &&
      value >= bounds.min && value <= bounds.max
    ? value
    : null;
}

export type VmImageResourceShape = {
  readonly cpu: number;
  readonly memoryMb: number;
  readonly storageMb: number;
};

/** Historical default shape for legacy rows, not a quota on new machines. */
export const DEFAULT_VM_RESOURCE_RESERVATION: VmResourceReservation = {
  vcpus: 5,
  memoryMb: 20 * 1024,
  diskMb: VM_DISK_MB_DEFAULT,
};

export const VM_RESOURCE_RESERVATION_METADATA_KEY = "cmuxResourceReservation";
/** Internal marker for a resize whose provider call is still pending.
 * The reservation remains valid while this marker is present, so reconciliation
 * cannot lower the claim during the provider call.
 */
export const VM_RESOURCE_RESIZE_PENDING_METADATA_KEY = "cmuxResourceResizePending";
/** Internal marker for a completed resize whose provider size is not confirmed yet. */
export const VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY = "cmuxResourceResizeUnconfirmed";
/** Internal marker that postpones a legacy resource read until a later pass. */
export const VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY = "cmuxResourceReconcileRetry";
/** Internal marker for a native fork claim awaiting provider-confirmed shape. */
export const VM_RESOURCE_FORK_PENDING_METADATA_KEY = "cmuxResourceForkPending";

/** Read the minimum source shape stored on a pending native fork marker. */
export function vmResourceForkPendingFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
): VmResourceReservation | null {
  return resourceReservationFromValue(metadata?.[VM_RESOURCE_FORK_PENDING_METADATA_KEY]);
}

/** vCPUs a machine of `memoryMb` gets: one per 4 GB, rounded up. */
export function vcpusForMemoryMb(memoryMb: number): number {
  return Math.max(1, Math.ceil(memoryMb / VM_MEMORY_MB_PER_VCPU));
}

/**
 * The provider shape represented by a machine reservation.
 */
export function vmResourceReservationForCreate(input: {
  readonly memoryMb?: number;
  readonly imageSize?: VmImageResourceShape | null;
  readonly env?: Record<string, string | undefined>;
} = {}): VmResourceReservation {
  if (input.imageSize) {
    const configuredDiskMb = vmDiskMb(input.env);
    const imageReservation = normalizeResourceReservation({
      vcpus: input.imageSize.cpu,
      memoryMb: input.imageSize.memoryMb,
      diskMb: input.imageSize.storageMb,
    });
    // A resolver can provide both the caller's requested memory and the baked
    // image selected to satisfy it. CPU and memory retain the requested machine dimensions. The provider grows a small baked image to the documented starting
    // disk, or the operator override, so the reservation must include the
    // effective provider disk size.
    if (input.memoryMb !== undefined) {
      return normalizeResourceReservation({
        vcpus: vcpusForMemoryMb(input.memoryMb),
        memoryMb: input.memoryMb,
        diskMb: Math.max(configuredDiskMb, imageReservation.diskMb),
      });
    }
    return {
      ...imageReservation,
      diskMb: Math.max(configuredDiskMb, imageReservation.diskMb),
    };
  }
  const memoryMb = input.memoryMb ?? PLAN_MACHINE_MEMORY_MB;
  return normalizeResourceReservation({
    vcpus: vcpusForMemoryMb(memoryMb),
    memoryMb,
    diskMb: vmDiskMb(input.env),
  });
}

export type VmResourceResizePending = {
  /** Unique request generation used to protect confirmation and rollback. */
  readonly operationId: string;
  readonly requestedDiskMb: number;
  readonly previousDiskMb: number;
  /** Millisecond timestamp used to recover a worker that died before provider I/O. */
  readonly createdAtMs?: number;
};

/** Read a validated in-flight resize marker from provider metadata. */
export function vmResourceResizePendingFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
): VmResourceResizePending | null {
  const raw = metadata?.[VM_RESOURCE_RESIZE_PENDING_METADATA_KEY];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const candidate = raw as Record<string, unknown>;
  const operationId = candidate.operationId;
  const requestedDiskMb = candidate.requestedDiskMb;
  const previousDiskMb = candidate.previousDiskMb;
  const createdAtMs = candidate.createdAtMs;
  if (
    typeof operationId !== "string" ||
    operationId.trim().length === 0 ||
    operationId.length > 200 ||
    !isPositiveSafeInteger(requestedDiskMb) ||
    !isPositiveSafeInteger(previousDiskMb) ||
    (createdAtMs !== undefined && !isPositiveSafeInteger(createdAtMs))
  ) return null;
  return {
    operationId: operationId.trim(),
    requestedDiskMb,
    previousDiskMb,
    ...(createdAtMs === undefined ? {} : { createdAtMs }),
  };
}

export type VmResourceResizeUnconfirmed = {
  /** Unique request generation used to protect reconciliation from stale reads. */
  readonly operationId: string;
  /** Minimum provider size expected after the completed resize. */
  readonly requestedDiskMb: number;
  /** Disk claim to restore when the provider never reaches the request. */
  readonly previousDiskMb?: number;
  /** Millisecond timestamp at which conservative recovery started. */
  readonly markedAtMs?: number;
};

/** Read a validated completed-resize marker awaiting provider stats. */
export function vmResourceResizeUnconfirmedFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
): VmResourceResizeUnconfirmed | null {
  const raw = metadata?.[VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const candidate = raw as Record<string, unknown>;
  const operationId = candidate.operationId;
  const requestedDiskMb = candidate.requestedDiskMb;
  const previousDiskMb = candidate.previousDiskMb;
  const markedAtMs = candidate.markedAtMs;
  if (
    typeof operationId !== "string" ||
    operationId.trim().length === 0 ||
    operationId.length > 200 ||
    !isPositiveSafeInteger(requestedDiskMb) ||
    (previousDiskMb !== undefined && !isPositiveSafeInteger(previousDiskMb)) ||
    (markedAtMs !== undefined && !isPositiveSafeInteger(markedAtMs))
  ) return null;
  return {
    operationId: operationId.trim(),
    requestedDiskMb,
    ...(previousDiskMb === undefined ? {} : { previousDiskMb }),
    ...(markedAtMs === undefined ? {} : { markedAtMs }),
  };
}

export type VmResourceReconcileRetry = {
  /** Unix epoch milliseconds at which the row may be attempted again. */
  readonly nextAttemptAtMs: number;
};

/** Read a validated retry marker for background resource reconciliation. */
export function vmResourceReconcileRetryFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
): VmResourceReconcileRetry | null {
  const raw = metadata?.[VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const candidate = raw as Record<string, unknown>;
  const nextAttemptAtMs = candidate.nextAttemptAtMs;
  if (!isPositiveSafeInteger(nextAttemptAtMs)) return null;
  return { nextAttemptAtMs };
}

function isPositiveSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

/** Read a persisted reservation, falling back safely for legacy VM rows. */
export function vmResourceReservationFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
  fallback: VmResourceReservation = DEFAULT_VM_RESOURCE_RESERVATION,
): VmResourceReservation {
  const raw = metadata?.[VM_RESOURCE_RESERVATION_METADATA_KEY];
  return resourceReservationFromValue(raw) ?? fallback;
}

/** Whether a row has a complete, validated reservation marker. */
export function hasVmResourceReservationMetadata(
  metadata: Record<string, unknown> | null | undefined,
): boolean {
  return resourceReservationFromValue(metadata?.[VM_RESOURCE_RESERVATION_METADATA_KEY]) !== null;
}

/** Merge a reservation into provider metadata without exposing mutable input. */
export function withVmResourceReservationMetadata(
  metadata: Record<string, unknown> | null | undefined,
  reservation: VmResourceReservation,
): Record<string, unknown> {
  return {
    ...(metadata ?? {}),
    [VM_RESOURCE_RESERVATION_METADATA_KEY]: { ...reservation },
  };
}

function normalizeResourceReservation(input: VmResourceReservation): VmResourceReservation {
  for (const [name, value] of Object.entries(input)) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new Error(`${name} must be a positive integer`);
    }
  }
  return input;
}

function resourceReservationFromValue(value: unknown): VmResourceReservation | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  const vcpus = candidate.vcpus;
  const memoryMb = candidate.memoryMb;
  const diskMb = candidate.diskMb;
  if (
    typeof vcpus !== "number" || !Number.isSafeInteger(vcpus) || vcpus <= 0 ||
    typeof memoryMb !== "number" || !Number.isSafeInteger(memoryMb) || memoryMb <= 0 ||
    typeof diskMb !== "number" || !Number.isSafeInteger(diskMb) || diskMb <= 0
  ) return null;
  return { vcpus, memoryMb, diskMb };
}

/** Disk every machine is grown to at create, in MB. Env-overridable. */
export function vmDiskMb(env: Record<string, string | undefined> = process.env): number {
  const raw = (env.CMUX_VM_DISK_MB ?? String(VM_DISK_MB_DEFAULT)).trim();
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value <= 0 || String(value) !== raw) {
    throw new Error(`CMUX_VM_DISK_MB must be a positive integer, got: ${raw}`);
  }
  return value;
}
