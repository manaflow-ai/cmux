// The in-session status cards (Claude Code desktop's live plan card and recap card) are a Debug
// Settings toggle, `agent.sessionStatus` (Swift AgentPaneTunables), off by default. The host pushes
// it as the `sessionStatus` event (old host: `cmuxAcpmuxBridge.applySessionStatus`); a card reads it
// with `useSessionStatus()`. Kept here, not in App state only, so a push before the chat mounts is kept.
import { useSyncExternalStore } from "react";

let current = false;
const listeners = new Set<() => void>();

/// The host's value: anything but `true` is off.
export function setSessionStatus(value: unknown) {
  const next = value === true;
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

/// Whether the in-session status cards show right now.
export function sessionStatusOn(): boolean {
  return current;
}

/// Whether the in-session status cards show; re-renders when the host flips the toggle.
function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useSessionStatus(): boolean {
  return useSyncExternalStore(subscribe, () => current);
}
