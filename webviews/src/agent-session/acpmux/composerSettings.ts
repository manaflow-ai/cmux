// `agentPane.showContextUsage` and `agentPane.showDictation` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether the composer
// shows its context usage ring, and whether every composer (the chat's and the New Tab page's)
// shows its dictation mic. The ring's right-click hides it and the footer's shows it again; the
// mic's right-click hides it and Settings shows it again. The page sets the value at once and the
// host writes it (`pane.showContextUsage`, `pane.showDictation`), then pushes it back.
import { useSyncExternalStore } from "react";

export type ComposerSettings = { showContextUsage: boolean; showDictation: boolean };

export const DEFAULT_COMPOSER: ComposerSettings = { showContextUsage: true, showDictation: true };

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const flag = (key: keyof ComposerSettings) => (typeof raw[key] === "boolean" ? raw[key] : DEFAULT_COMPOSER[key]);
  return { showContextUsage: flag("showContextUsage"), showDictation: flag("showDictation") };
}

let current = DEFAULT_COMPOSER;
const listeners = new Set<() => void>();

/// The host's whole value, or a page change to some settings (the rest stay as they are).
export function setComposerSettings(value: unknown) {
  const next = readComposerSettings({ ...current, ...(value && typeof value === "object" ? value : {}) });
  if (next.showContextUsage === current.showContextUsage && next.showDictation === current.showDictation) return;
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
