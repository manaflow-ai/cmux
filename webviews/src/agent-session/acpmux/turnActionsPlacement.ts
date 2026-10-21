import { useSyncExternalStore } from "react";

export type TurnActionsPlacement = "left" | "right";

let current: TurnActionsPlacement = "left";
const listeners = new Set<() => void>();

/// The native host sends this with the AgentPaneTheme. The answer's row sits on the left under its
/// text, as Claude Code desktop's; only "right" moves it to the column's right edge.
export function configureTurnActionsPlacement(value: unknown): void {
  const next: TurnActionsPlacement = value === "right" ? "right" : "left";
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === "right") document.documentElement.dataset.turnActionsPlacement = next;
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
