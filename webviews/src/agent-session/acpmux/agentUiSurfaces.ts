// Interactive cards from agents (forms, approvals, tables, charts, progress) are the opt-in Labs
// setting `labs.agentUiSurfaces` (Settings > Advanced > Labs), off by default. The host pushes it as
// the `agentUiSurfaces` event (old host: `cmuxAcpmuxBridge.applyAgentUiSurfaces`); a card reads it
// with `useAgentUiSurfaces()`. Kept here, not in App state only, so a push before the chat mounts is kept.
import { useSyncExternalStore } from "react";

let current = false;
const listeners = new Set<() => void>();

/// The host's value: anything but `true` is off.
export function setAgentUiSurfaces(value: unknown) {
  const next = value === true;
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

/// Whether interactive agent cards show right now (outside React).
export function agentUiSurfacesOn(): boolean {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// Whether interactive agent cards show; re-renders when the host flips the setting.
export function useAgentUiSurfaces(): boolean {
  return useSyncExternalStore(subscribe, () => current);
}
