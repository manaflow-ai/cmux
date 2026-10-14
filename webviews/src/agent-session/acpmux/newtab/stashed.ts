// How many tabs are stashed (`stashedCount`, CmuxNextAgentPane AgentPageEvent+Stashed): the New Tab
// page shows its Stashed link while it is above zero. A module store like recentlyClosed.ts, so a
// push that arrives before the New Tab screen mounts is kept.
import { useSyncExternalStore } from "react";

let count = 0;
const listeners = new Set<() => void>();

/// Replaces the count from a host push; anything but a non-negative number is zero.
export function setStashedCount(value: unknown): void {
  const next = typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  if (next === count) return;
  count = next;
  for (const listener of listeners) listener();
}

export function stashedCount(): number {
  return count;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useStashedCount(): number {
  return useSyncExternalStore(subscribe, stashedCount, stashedCount);
}
