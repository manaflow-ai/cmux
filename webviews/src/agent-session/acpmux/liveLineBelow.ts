import { useSyncExternalStore } from "react";

/// Where a running turn's status line draws (Debug Settings `agentPane.debug.liveLineBelow`;
/// conversation/turns.ts `liveTurn`): its last row, ticking until the turn ends, as Claude desktop
/// draws it, or (off) the older line over its work. On unless a host turns it off: a browser host
/// or an older app that sends no value gets the line at the bottom.
let current = true;
const listeners = new Set<() => void>();

/// The host pushed the theme: the transcript follows at once.
export function configureLiveLineBelow(value: unknown): void {
  const next = value !== false;
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// Whether the line draws at the bottom now.
export const useLiveLineBelow = (): boolean => useSyncExternalStore(subscribe, snapshot, snapshot);
