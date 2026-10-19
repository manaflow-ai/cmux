import { useSyncExternalStore } from "react";

/// Card state survives virtual remounts, with at most 200 saved values (Lucas 2026-10-18).
const states = new Map<string, unknown>();
const stopped = new Set<string>();
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

export const renderState = (key: string) => states.get(key) ?? null;
export function saveRenderState(key: string, value: unknown): void {
  states.set(key, value);
  if (states.size > 200) states.delete(states.keys().next().value!);
}

export function stopRender(key: string, stop: boolean): void {
  if (stop) stopped.add(key);
  else stopped.delete(key);
  for (const listener of listeners) listener();
}

export const useRenderStopped = (key: string) =>
  useSyncExternalStore(
    subscribe,
    () => stopped.has(key),
    () => false,
  );
