import { useSyncExternalStore } from "react";

// The existing Advanced > Labs > Preview features switch. Off until the host sends it.
let enabled = false;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
export function setEarnedAccessLabs(on: boolean): void {
  if (enabled === on) return;
  enabled = on;
  for (const listener of listeners) listener();
}
export function useEarnedAccessLabs(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => enabled,
    () => false,
  );
}
