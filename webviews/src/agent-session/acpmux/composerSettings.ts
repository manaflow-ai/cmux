// `agentPane.showContextUsage`, `agentPane.showDictation` and `agentPane.spellChecking` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether every composer
// (the chat's and the New Tab page's) shows its context usage ring and its dictation mic. Each
// hides the macOS way (composerChrome.tsx): its right-click offers Hide, and a right-click on the
// composer's button row offers Show. The page sets the value at once and asks the host to write it
// (`pane.showContextUsage`, `pane.showDictation`), which pushes it back, also on the next launch.
// The same event carries `reasoningSlider`, the Debug Settings toggle `agent.reasoningSlider`
// (DEV and NIGHTLY, off by default; not a cmux.json key): the reasoning menu draws a stepped
// slider instead of its list of levels. Only Debug Settings changes it. The model chip always opens
// the compact menu (Leo 2026-10-20: one "Opus 5.5  Medium" button in every composer); the full
// picker is its More models row, so the host's old `modelMenu` value is ignored.
// `plainFooter` is no cmux.json key either: Debug Settings' "Agent composer: plain footer" (Swift
// AgentPaneTunables.composerPlainFooter, DEV and NIGHTLY builds) rides the same event and draws the
// footer's chips as plain text at rest (composerLocation.css, [data-footer-look="plain"]).
// `harnessSwitch` is Debug Settings' "Allow switching harness in a started chat" (Swift
// AgentPaneTunables.harnessSwitchInStartedChat, off by default; no cmux.json key): off, a chat with
// a message keeps its harness and its model menu lists that harness's models alone (ComposerPickers).
// `escapeDoublePress` is Debug Settings' "Esc stops a turn on a double press" (Swift
// AgentPaneTunables.escapeStopDoublePress, on by default; no cmux.json key): on, Esc on an empty
// composer stops a running turn only on the second press inside the window (escapeStop.ts).
// `subagentPanes` is `agentPane.subagentPanes` in cmux.json (off by default): subagents open in panes
// of their own right of the chat (subagents/subagentPanes.ts). The summary card's switch sets it
// at once and asks the host to write it (`pane.subagentPanes`), which pushes it back.
import { useSyncExternalStore } from "react";

export type ReasoningSliderStyle = "accent" | "minimal";
export type ComposerSettings = {
  showContextUsage: boolean;
  showDictation: boolean;
  spellChecking: boolean;
  reasoningSlider: boolean;
  reasoningSliderStyle: ReasoningSliderStyle;
  plainFooter: boolean;
  harnessSwitch: boolean;
  escapeDoublePress: boolean;
  subagentPanes: boolean;
};

export const DEFAULT_COMPOSER: ComposerSettings = {
  showContextUsage: true,
  showDictation: true,
  spellChecking: false,
  reasoningSlider: false,
  reasoningSliderStyle: "accent",
  plainFooter: true,
  harnessSwitch: false,
  escapeDoublePress: true,
  subagentPanes: false,
};
const KEYS = Object.keys(DEFAULT_COMPOSER) as (keyof ComposerSettings)[];
type ComposerFlag =
  | "showContextUsage"
  | "showDictation"
  | "spellChecking"
  | "reasoningSlider"
  | "plainFooter"
  | "harnessSwitch"
  | "escapeDoublePress"
  | "subagentPanes";

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const flag = (key: ComposerFlag) => (typeof raw[key] === "boolean" ? raw[key] : DEFAULT_COMPOSER[key]);
  const reasoningSliderStyle: ReasoningSliderStyle = raw.reasoningSliderStyle === "minimal" ? "minimal" : "accent";
  return {
    showContextUsage: flag("showContextUsage"),
    showDictation: flag("showDictation"),
    spellChecking: flag("spellChecking"),
    reasoningSlider: flag("reasoningSlider"),
    reasoningSliderStyle,
    plainFooter: flag("plainFooter"),
    harnessSwitch: flag("harnessSwitch"),
    escapeDoublePress: flag("escapeDoublePress"),
    subagentPanes: flag("subagentPanes"),
  };
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

/// The host's write of a composer setting: `pane.showContextUsage`, `pane.showDictation` or
/// `pane.subagentPanes` with `show`.
type ComposerHost = (
  method: "pane.showContextUsage" | "pane.showDictation" | "pane.subagentPanes",
  show: boolean,
) => void;
let composerHost: ComposerHost | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerComposerHost(write: ComposerHost | undefined) {
  composerHost = write;
}

/// Shows or hides a composer control in every composer, and asks the host to persist it.
export function showComposerControl(key: "showContextUsage" | "showDictation", show: boolean) {
  setComposerSettings({ [key]: show });
  composerHost?.(key === "showDictation" ? "pane.showDictation" : "pane.showContextUsage", show);
}

/// Turns opening subagents in panes on or off in every page, and asks the host to persist it
/// (`agentPane.subagentPanes`).
export function setSubagentPanes(on: boolean) {
  setComposerSettings({ subagentPanes: on });
  composerHost?.("pane.subagentPanes", on);
}
