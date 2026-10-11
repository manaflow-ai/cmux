// `agentPane.showContextUsage` in cmux.json (Swift CmuxNextSettings AgentPaneComposerSetting),
// pushed by the host as the `composer` event: whether the composer shows its context usage ring.
// The ring's right-click hides it and the footer's shows it again; the page sets the value at once
// and the host writes it (`pane.showContextUsage`), then pushes it back.
import { useSyncExternalStore } from "react";

export type ComposerSettings = { showContextUsage: boolean };

export const DEFAULT_COMPOSER: ComposerSettings = { showContextUsage: true };

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  return {
    showContextUsage:
      typeof raw.showContextUsage === "boolean" ? raw.showContextUsage : DEFAULT_COMPOSER.showContextUsage,
  };
}

let current = DEFAULT_COMPOSER;
const listeners = new Set<() => void>();

export function setComposerSettings(value: unknown) {
  const next = readComposerSettings(value);
  if (next.showContextUsage === current.showContextUsage) return;
  current = next;
  for (const listener of listeners) listener();
}

export function useComposerSettings(): ComposerSettings {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current,
  );
}

declare global {
  interface Window {
    /// The old host's script for the `composer` event (CmuxNextAgentPane AgentPaneView).
    cmuxAcpmuxComposer?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxComposer = setComposerSettings;
