import { useSyncExternalStore } from "react";

/// Open prompts survive virtual rows remounting (Lucas 2026-10-18).
export const PROMPT_LINES = 8;
const expanded = new Set<string>();
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

export const promptExpanded = (id: string) => expanded.has(id);

export function expandPrompt(id: string, open: boolean): void {
  if (expanded.has(id) === open) return;
  if (open) expanded.add(id);
  else expanded.delete(id);
  for (const listener of listeners) listener();
}

export const usePromptExpanded = (id: string) =>
  useSyncExternalStore(
    subscribe,
    () => promptExpanded(id),
    () => false,
  );
