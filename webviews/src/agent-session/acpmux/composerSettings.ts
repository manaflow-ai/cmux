// `agentPane.showContextUsage` and `agentPane.showDictation` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether every composer
// (the chat's and the New Tab page's) shows its context usage ring and its dictation mic. Each
// hides the macOS way (composerChrome.tsx): its right-click offers Hide, and a right-click on the
// composer's button row offers Show. The page sets the value at once and asks the host to write it
// (`pane.showContextUsage`, `pane.showDictation`), which pushes it back, also on the next launch.
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

/// The host's write of a composer setting: `pane.showContextUsage` or `pane.showDictation` with `show`.
type ComposerHost = (method: "pane.showContextUsage" | "pane.showDictation", show: boolean) => void;
let composerHost: ComposerHost | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerComposerHost(write: ComposerHost | undefined) {
  composerHost = write;
}

/// Shows or hides a composer control in every composer, and asks the host to persist it.
export function showComposerControl(key: keyof ComposerSettings, show: boolean) {
  setComposerSettings({ [key]: show });
  composerHost?.(key === "showDictation" ? "pane.showDictation" : "pane.showContextUsage", show);
}
