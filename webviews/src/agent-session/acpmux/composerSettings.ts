// `agentPane.showContextUsage` and `agentPane.showDictation` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether every composer
// (the chat's and the New Tab page's) shows its context usage ring and its dictation mic. Each
// hides the macOS way (composerChrome.tsx): its right-click offers Hide, and a right-click on the
// composer's button row offers Show. The page sets the value at once and asks the host to write it
// (`pane.showContextUsage`, `pane.showDictation`), which pushes it back, also on the next launch.
// `agentPane.tileSubagentsAutomatically` rides along: the Subagents card's switch
// (subagents/subagentPanes.ts), also a Settings row, written by `pane.tileSubagentsAutomatically`.
import { useSyncExternalStore } from "react";

export type ComposerSettings = {
  showContextUsage: boolean;
  showDictation: boolean;
  tileSubagentsAutomatically: boolean;
};

export const DEFAULT_COMPOSER: ComposerSettings = {
  showContextUsage: true,
  showDictation: true,
  tileSubagentsAutomatically: false,
};

const KEYS = Object.keys(DEFAULT_COMPOSER) as (keyof ComposerSettings)[];

/// The host method that writes each setting.
const WRITE: Record<keyof ComposerSettings, ComposerMethod> = {
  showContextUsage: "pane.showContextUsage",
  showDictation: "pane.showDictation",
  tileSubagentsAutomatically: "pane.tileSubagentsAutomatically",
};

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const flag = (key: keyof ComposerSettings) => (typeof raw[key] === "boolean" ? raw[key] : DEFAULT_COMPOSER[key]);
  return Object.fromEntries(KEYS.map((key) => [key, flag(key)])) as ComposerSettings;
}

let current = DEFAULT_COMPOSER;
const listeners = new Set<() => void>();

/// The host's whole value, or a page change to some settings (the rest stay as they are).
export function setComposerSettings(value: unknown) {
  const next = readComposerSettings({ ...current, ...(value && typeof value === "object" ? value : {}) });
  if (KEYS.every((key) => next[key] === current[key])) return;
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

type ComposerMethod = "pane.showContextUsage" | "pane.showDictation" | "pane.tileSubagentsAutomatically";
/// The host's write of a setting: its `WRITE` method with `show`.
type ComposerHost = (method: ComposerMethod, show: boolean) => void;
let composerHost: ComposerHost | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerComposerHost(write: ComposerHost | undefined) {
  composerHost = write;
}

/// Turns a setting on or off in every page at once, and asks the host to persist it.
export function showComposerControl(key: keyof ComposerSettings, show: boolean) {
  setComposerSettings({ [key]: show });
  composerHost?.(WRITE[key], show);
}
