import { useSyncExternalStore } from "react";

export type TurnActionsPlacement = "left" | "right";

let current: TurnActionsPlacement = "left";
const listeners = new Set<() => void>();

/// The native host sends this with the AgentPaneTheme. The footer sits on the answer's side, its
/// left (Leo 2026-10-19); missing or invalid values keep that, and "right" opts into the column's
/// right edge (`:root[data-turn-actions-placement="right"]`, conversation.css).
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
