// Presentation-only Labs state. The existing host setting owns persistence and defaults.
import { useSyncExternalStore } from "react";

let enabled = false;
const listeners = new Set<() => void>();

export function setStartRecoveryPreview(on: boolean): void {
  if (enabled === on) return;
  enabled = on;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useStartRecoveryPreview(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => enabled,
    () => false,
  );
}
