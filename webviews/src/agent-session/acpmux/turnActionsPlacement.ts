import { useSyncExternalStore } from "react";

export type TurnActionsPlacement = "left" | "right";

let current: TurnActionsPlacement = "right";
const listeners = new Set<() => void>();

/// The native host sends this with the AgentPaneTheme. Missing or invalid values preserve the
/// existing right-aligned footer until a host opts into the left placement.
export function configureTurnActionsPlacement(value: unknown): void {
  const next: TurnActionsPlacement = value === "left" ? "left" : "right";
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === "left") document.documentElement.dataset.turnActionsPlacement = next;
    else delete document.documentElement.dataset.turnActionsPlacement;
  }
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;
export const turnActionsPlacementSnapshot = snapshot;

export const useTurnActionsPlacement = (): TurnActionsPlacement => useSyncExternalStore(subscribe, snapshot, snapshot);
