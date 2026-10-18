import { createContext, useSyncExternalStore } from "react";

/// A reader's toggle anchors the transcript to that button (Lucas 2026-10-18).
export const PromptToggleAnchor = createContext<((button: HTMLButtonElement) => void) | undefined>(undefined);

/// Open prompts survive virtual rows remounting (Lucas 2026-10-18).
export const PROMPT_LINES = 8;
const expanded = new Set<string>();
const revisions = new Map<string, number>();
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

const key = (id: string, sessionId: string) => JSON.stringify([sessionId, id]);
export const promptExpanded = (id: string, sessionId = "") => expanded.has(key(id, sessionId));

export function expandPrompt(id: string, open: boolean, sessionId = ""): void {
  if (promptExpanded(id, sessionId) === open) return;
  if (open) expanded.add(key(id, sessionId));
  else expanded.delete(key(id, sessionId));
  revisions.set(sessionId, (revisions.get(sessionId) ?? 0) + 1);
  for (const listener of listeners) listener();
}

export const usePromptExpanded = (id: string, sessionId = "") =>
  useSyncExternalStore(
    subscribe,
    () => promptExpanded(id, sessionId),
    () => false,
  );

/// A transcript remeasures folded prompts even while those rows are offscreen.
export const usePromptRevision = (sessionId: string) =>
  useSyncExternalStore(
    subscribe,
    () => revisions.get(sessionId) ?? 0,
    () => 0,
  );
