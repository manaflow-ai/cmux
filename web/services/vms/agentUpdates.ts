/**
 * A machine's coding-agent update setting. "image" (the default, stored as
 * null) keeps the versions its image baked; "latest" updates the baked agents
 * to the newest GitHub release that has been public for 3 days, on attach, at
 * most once a day (services/vms/guestAgentUpdates.ts).
 */
export type VmAgentUpdatesSetting = "latest" | "image";

export const VM_AGENT_UPDATES_SETTINGS: readonly VmAgentUpdatesSetting[] = ["latest", "image"];

export function isVmAgentUpdatesSetting(value: unknown): value is VmAgentUpdatesSetting {
  return value === "latest" || value === "image";
}

/** The column value: only an opt-in is stored, so existing rows stay image-pinned. */
export function storedAgentUpdates(setting: VmAgentUpdatesSetting | undefined): "latest" | null {
  return setting === "latest" ? "latest" : null;
}

/** The setting a row carries; anything but "latest" is the image default. */
export function vmAgentUpdatesFromRow(row: { readonly agentUpdates?: string | null }): VmAgentUpdatesSetting {
  return row.agentUpdates === "latest" ? "latest" : "image";
}
