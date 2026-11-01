import type { EnvironmentOpen } from "../../pages/cloud/environmentModel";

let current: (EnvironmentOpen & { request: number }) | undefined;
let sequence = 0;
const listeners = new Set<() => void>();

/** Shared entry point for the Session Info cog and startup checklist. One editor per agent page. */
export function openCloudEnvironment(options: EnvironmentOpen = {}) {
  current = { ...options, request: ++sequence };
  for (const listener of listeners) listener();
}
export const cloudEnvironmentRequest = () => current;
export function subscribeCloudEnvironment(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
export function closeCloudEnvironmentRequest(request: number) {
  if (current?.request !== request) return;
  current = undefined;
  for (const listener of listeners) listener();
}
