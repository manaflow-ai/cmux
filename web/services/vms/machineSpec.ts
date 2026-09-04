/**
 * The provider sizing profile applied to each paid Cloud VM. Paid plans allow
 * up to PAID_MAX_ACTIVE_VMS_DEFAULT machines. Pricing separately advertises
 * 5 vCPU, 20 GB memory, and 200 GB disk as one pool shared across that
 * allowance. This module does not enforce an aggregate provider resource
 * quota. The provider starts each disk at 32 GB and supports grow-only resize.
 *
 * Kept dependency-free so the provider drivers can size a machine without
 * pulling the billing graph into their module.
 */
export const PAID_MAX_ACTIVE_VMS_DEFAULT = 50;
export const PLAN_MACHINE_MEMORY_MB = 20480;
export const VM_MEMORY_MB_PER_VCPU = 4096;
/** New machines start with this disk. Freestyle resizes disks grow-only. */
export const VM_DISK_MB_DEFAULT = 32768;
/** Freestyle Pro's documented per-VM disk ceiling. */
export const VM_DISK_MB_MAX = 262144;
/** User-facing disk sizes are aligned to whole GiB steps. */
export const VM_DISK_MB_STEP = 4096;

/** vCPUs a machine of `memoryMb` gets: one per 4 GB, rounded up (20 GB → 5). */
export function vcpusForMemoryMb(memoryMb: number): number {
  return Math.max(1, Math.ceil(memoryMb / VM_MEMORY_MB_PER_VCPU));
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
