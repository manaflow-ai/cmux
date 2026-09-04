/**
 * The provider sizing profile and the plan-wide Cloud VM resource policy.
 *
 * The count allowance and the resource pool are separate limits. Postgres
 * records each machine's reservation, and the VM repository checks the live
 * claims while holding the billing-team lock. CPU and memory are shared
 * ceilings, so the largest claim wins; disk is persistent storage, so claims
 * add. Keeping the policy here gives pricing tests, workflows, and provider
 * sizing one source of truth.
 *
 * This module stays dependency-free so provider drivers can size a machine
 * without pulling the billing graph into their module.
 */
export const PAID_MAX_ACTIVE_VMS_DEFAULT = 50;
export const PLAN_MACHINE_MEMORY_MB = 20480;
export const VM_MEMORY_MB_PER_VCPU = 4096;
export const PLAN_SHARED_VCPU = 5;
export const PLAN_SHARED_MEMORY_MB = 20 * 1024;
export const PLAN_SHARED_DISK_MB = 200 * 1024;

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

export type VmSharedResourceName = keyof VmResourceReservation;

export type VmImageResourceShape = {
  readonly cpu: number;
  readonly memoryMb: number;
  readonly storageMb: number;
};

export const PLAN_SHARED_RESOURCE_CAPACITY: VmResourceReservation = {
  vcpus: PLAN_SHARED_VCPU,
  memoryMb: PLAN_SHARED_MEMORY_MB,
  diskMb: PLAN_SHARED_DISK_MB,
};

/** The reservation used for rows written before resource metadata existed. */
export const DEFAULT_VM_RESOURCE_RESERVATION: VmResourceReservation = {
  vcpus: PLAN_SHARED_VCPU,
  memoryMb: PLAN_SHARED_MEMORY_MB,
  diskMb: VM_DISK_MB_DEFAULT,
};

export const VM_RESOURCE_RESERVATION_METADATA_KEY = "cmuxResourceReservation";

/** vCPUs a machine of `memoryMb` gets: one per 4 GB, rounded up (20 GB → 5). */
export function vcpusForMemoryMb(memoryMb: number): number {
  return Math.max(1, Math.ceil(memoryMb / VM_MEMORY_MB_PER_VCPU));
}

/**
 * The resources reserved for a newly-created machine. A sized image carries
 * its provider shape; a size-less image uses the requested plan profile. The
 * create workflow intentionally omits `imageSize` when claiming the shared
 * plan pool because provider snapshots can be overprovisioned to a catalog
 * shape.
 */
export function vmResourceReservationForCreate(input: {
  readonly memoryMb?: number;
  readonly imageSize?: VmImageResourceShape | null;
  readonly env?: Record<string, string | undefined>;
} = {}): VmResourceReservation {
  if (input.imageSize) {
    return normalizeResourceReservation({
      vcpus: input.imageSize.cpu,
      memoryMb: input.imageSize.memoryMb,
      diskMb: input.imageSize.storageMb,
    });
  }
  const memoryMb = input.memoryMb ?? PLAN_MACHINE_MEMORY_MB;
  return normalizeResourceReservation({
    vcpus: vcpusForMemoryMb(memoryMb),
    memoryMb,
    diskMb: vmDiskMb(input.env),
  });
}

/**
 * Team plans multiply both the VM allowance and its shared pool by paid seat.
 * Operator limits below one base allowance still keep the base pool, while a
 * larger allowance gets one pool per 50-machine block.
 */
export function sharedResourceCapacityForMaxActiveVms(
  maxActiveVms: number | null | undefined,
): VmResourceReservation {
  const blocks = maxActiveVms !== null && maxActiveVms !== undefined && maxActiveVms > 0
    ? Math.max(1, Math.ceil(maxActiveVms / PAID_MAX_ACTIVE_VMS_DEFAULT))
    : 1;
  return {
    vcpus: PLAN_SHARED_VCPU * blocks,
    memoryMb: PLAN_SHARED_MEMORY_MB * blocks,
    diskMb: PLAN_SHARED_DISK_MB * blocks,
  };
}

/** Return the first resource for which a shared claim would exceed the pool. */
export function firstExceededSharedResource(input: {
  readonly used: VmResourceReservation;
  readonly requested: VmResourceReservation;
  readonly capacity: VmResourceReservation;
}): {
  readonly resource: VmSharedResourceName;
  readonly used: number;
  readonly requested: number;
  readonly limit: number;
} | null {
  for (const resource of ["vcpus", "memoryMb", "diskMb"] as const) {
    const used = input.used[resource];
    const requested = input.requested[resource];
    const limit = input.capacity[resource];
    const projected = sharedResourceUsage(resource, used, requested);
    if (projected > limit) return { resource, used, requested, limit };
  }
  return null;
}

/** CPU and memory are one shared ceiling; persistent disk is additive. */
export function sharedResourceUsage(
  resource: VmSharedResourceName,
  used: number,
  requested: number,
): number {
  return resource === "diskMb" ? used + requested : Math.max(used, requested);
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
