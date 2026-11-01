/** Persisted at VM reservation time so a same-key retry can report the
 * original fork mechanism even when its snapshot ID is unavailable. */
export const VM_FORK_METHOD_METADATA_KEY = "cmuxForkMethod";
export type VmForkMethod = "native-live" | "snapshot-create" | "unknown";
export type PersistedVmForkMethod = Exclude<VmForkMethod, "unknown">;
export function readVmForkMethod(metadata: Readonly<Record<string, unknown>> | null | undefined): VmForkMethod {
  const value = metadata?.[VM_FORK_METHOD_METADATA_KEY];
  return value === "native-live" || value === "snapshot-create" ? value : "unknown";
}
