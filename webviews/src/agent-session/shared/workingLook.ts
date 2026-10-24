import { useSyncExternalStore } from "react";
import type { AgentSessionTheme } from "./types";

// How agent work shows on running rows (Debug Settings `status.working`), as one value React and
// CSS both follow. applyAgentTheme (theme.ts) sets it in the same step that writes
// `data-working-look` on the root, so a component that mounts layers only one look shows (the
// shimmer's lit copy in ToolText.tsx) mounts them exactly when the stylesheet would show them, and
// every other look keeps one copy of the row's words in the DOM.

/// The look a theme names; undefined is the stylesheet default (the breathing dot).
export type WorkingLook = NonNullable<AgentSessionTheme["workingLook"]>;

let current: WorkingLook | undefined;
const listeners = new Set<() => void>();

/// The look the last theme push named.
export function currentWorkingLook(): WorkingLook | undefined {
  return current;
}

/// Sets the look (applyAgentTheme only); subscribers hear a change, not a repeat.
export function setWorkingLook(look: WorkingLook | undefined): void {
  if (look === current) return;
  current = look;
  for (const listener of [...listeners]) listener();
}

/// Calls `listener` after each look change; the returned function stops it.
export function subscribeWorkingLook(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The current look; the component renders again when a theme push changes it.
export function useWorkingLook(): WorkingLook | undefined {
  return useSyncExternalStore(subscribeWorkingLook, currentWorkingLook, currentWorkingLook);
}
