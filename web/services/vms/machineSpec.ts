/**
 * The plan machine, as sold on /pricing: every paid plan gets up to
 * PAID_MAX_ACTIVE_VMS_DEFAULT machines of PLAN_MACHINE_MEMORY_MB memory, with
 * vCPUs derived from memory at VM_MEMORY_MB_PER_VCPU and a VM_DISK_MB_DEFAULT
 * disk. The pricing copy is pinned to these constants by test, so a change
 * here that forgets the copy (or vice versa) fails CI.
 *
 * Kept dependency-free so the provider drivers can size a machine without
 * pulling the billing graph into their module.
 */
export const PAID_MAX_ACTIVE_VMS_DEFAULT = 50;
export const PLAN_MACHINE_MEMORY_MB = 20480;
export const VM_MEMORY_MB_PER_VCPU = 4096;
export const VM_DISK_MB_DEFAULT = 204800;

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
