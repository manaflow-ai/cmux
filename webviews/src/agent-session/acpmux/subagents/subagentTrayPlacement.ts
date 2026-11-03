import { useSyncExternalStore } from "react";

export type SubagentTrayPlacement = "tray" | "after-latest-message";

let current: SubagentTrayPlacement = "tray";
const listeners = new Set<() => void>();

/// Host/theme or a gallery fixture may select the alternate placement; the shipped default stays
/// above the composer until an explicit value arrives.
export function configureSubagentTrayPlacement(value: unknown): void {
  const next: SubagentTrayPlacement = value === "after-latest-message" ? value : "tray";
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

export const useSubagentTrayPlacement = (): SubagentTrayPlacement =>
  useSyncExternalStore(subscribe, snapshot, snapshot);
