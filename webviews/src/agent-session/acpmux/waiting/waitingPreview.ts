// Waiting on me ships dark behind Labs (Settings > Advanced > Labs, off by default). The host's
// preview setting owns persistence; this holds the pane's copy, set from paneSnapshot's applyPreview.
import { useSyncExternalStore } from "react";

let enabled = false;
const listeners = new Set<() => void>();

export function setWaitingPreview(on: boolean): void {
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

export function useWaitingPreview(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => enabled,
    () => false,
  );
}
