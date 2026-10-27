// `agentPane.showContextUsage`, `agentPane.showDictation` and `agentPane.spellChecking` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether every composer
// (the chat's and the New Tab page's) shows its context usage ring and its dictation mic. Each
// hides the macOS way (composerChrome.tsx): its right-click offers Hide, and a right-click on the
// composer's button row offers Show. The page sets the value at once and asks the host to write it
// (`pane.showContextUsage`, `pane.showDictation`), which pushes it back, also on the next launch.
// `agentPane.attachmentView` rides the same event as `attachmentView`: how pictures and files show
// in every composer and in sent messages, "inline" (in the text where each was added, the default)
// or "strip" (in a row). It is only a look: a draft's text, its attachment marks and their order
// are the same in both, so switching never changes what is sent. Anything else reads as "inline".
// `agentPane.scrollToBottomOnSend` is on by default and preserves the existing send-to-latest
// behavior. When off, an up-scrolled reader stays anchored while new rows arrive below; a reader at
// the bottom continues following streaming output.
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
import { useSyncExternalStore } from "react";

export type ReasoningSliderStyle = "accent" | "minimal";
export type AttachmentView = "inline" | "strip";
export type ComposerSettings = {
  showContextUsage: boolean;
  showDictation: boolean;
  spellChecking: boolean;
  attachmentView: AttachmentView;
  scrollToBottomOnSend: boolean;
  reasoningSlider: boolean;
  reasoningSliderStyle: ReasoningSliderStyle;
  plainFooter: boolean;
  harnessSwitch: boolean;
  escapeDoublePress: boolean;
};

export const DEFAULT_COMPOSER: ComposerSettings = {
  showContextUsage: true,
  showDictation: true,
  spellChecking: false,
  attachmentView: "inline",
  scrollToBottomOnSend: true,
  reasoningSlider: false,
  reasoningSliderStyle: "accent",
  plainFooter: true,
  harnessSwitch: false,
  escapeDoublePress: true,
};
const KEYS = Object.keys(DEFAULT_COMPOSER) as (keyof ComposerSettings)[];
type ComposerFlag =
  | "showContextUsage"
  | "showDictation"
  | "spellChecking"
  | "reasoningSlider"
  | "plainFooter"
  | "harnessSwitch"
  | "scrollToBottomOnSend"
  | "escapeDoublePress";

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const flag = (key: ComposerFlag) => (typeof raw[key] === "boolean" ? raw[key] : DEFAULT_COMPOSER[key]);
  const reasoningSliderStyle: ReasoningSliderStyle = raw.reasoningSliderStyle === "minimal" ? "minimal" : "accent";
  const attachmentView: AttachmentView = raw.attachmentView === "strip" ? "strip" : "inline";
  return {
    showContextUsage: flag("showContextUsage"),
    showDictation: flag("showDictation"),
    spellChecking: flag("spellChecking"),
    attachmentView,
    scrollToBottomOnSend: flag("scrollToBottomOnSend"),
    reasoningSlider: flag("reasoningSlider"),
    reasoningSliderStyle,
    plainFooter: flag("plainFooter"),
    harnessSwitch: flag("harnessSwitch"),
    escapeDoublePress: flag("escapeDoublePress"),
  };
}

let current = DEFAULT_COMPOSER;
const listeners = new Set<() => void>();
let confirmedAttachmentView = current.attachmentView;
let attachmentWrite = 0;
let confirmedWrite = 0;
let pendingWrite = 0;
let confirmedScrollToBottomOnSend = current.scrollToBottomOnSend;
let scrollWrite = 0;

function publishComposerSettings(value: unknown) {
  const next = readComposerSettings({ ...current, ...(value && typeof value === "object" ? value : undefined) });
  if (KEYS.every((key) => next[key] === current[key])) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The host's whole value, or a page change to some settings (the rest stay as they are).
export function setComposerSettings(value: unknown) {
  if (value && typeof value === "object" && "scrollToBottomOnSend" in value) {
    confirmedScrollToBottomOnSend = readComposerSettings(value).scrollToBottomOnSend;
    // A host snapshot is authoritative. Invalidate an older bridge reply so a late success cannot
    // overwrite the value the host just confirmed (the legacy page bridge has no call context).
    scrollWrite += 1;
  }
  if (value && typeof value === "object" && "attachmentView" in value) {
    confirmedAttachmentView = readComposerSettings(value).attachmentView;
    // A host push is authoritative, including over replies from older writes.
    confirmedWrite = ++attachmentWrite;
    pendingWrite = 0;
  }
  publishComposerSettings(value);
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

/// The current page value for non-React bridges and focused persistence tests.
export function composerSettingsSnapshot(): ComposerSettings {
  return current;
}

declare global {
  interface Window {
    /// The old host's script for the `composer` event (CmuxNextAgentPane AgentPaneView).
    cmuxAcpmuxComposer?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxComposer = setComposerSettings;

/// The host's write of a composer setting with `show`.
type ComposerHost = (
  method: "pane.showContextUsage" | "pane.showDictation" | "pane.setScrollToBottomOnSend",
  show: boolean,
) => unknown;
let composerHost: ComposerHost | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerComposerHost(write: ComposerHost | undefined) {
  composerHost = write;
}

/// The host's write of `agentPane.attachmentView` (`pane.setAttachmentView {view}`).
let attachmentViewHost: ((view: AttachmentView) => unknown) | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerAttachmentViewHost(write: ((view: AttachmentView) => unknown) | undefined) {
  attachmentViewHost = write;
}

/// Shows attachments inline or in a strip in every composer and sent message, and asks the host to
/// persist it. Only the look changes; no draft or message is touched.
export function setAttachmentView(view: AttachmentView) {
  if (!attachmentViewHost) {
    setComposerSettings({ attachmentView: view });
    return;
  }
  const write = ++attachmentWrite;
  pendingWrite = write;
  publishComposerSettings({ attachmentView: view });
  const settle = (accepted: boolean) => {
    if (accepted && write > confirmedWrite) {
      confirmedAttachmentView = view;
      confirmedWrite = write;
    }
    if (pendingWrite === write) pendingWrite = 0;
    if (!pendingWrite) publishComposerSettings({ attachmentView: confirmedAttachmentView });
  };
  try {
    void Promise.resolve(attachmentViewHost(view)).then(
      () => settle(true),
      () => settle(false),
    );
  } catch {
    settle(false);
  }
}

/// Shows or hides a composer control in every composer, and asks the host to persist it.
export function showComposerControl(key: "showContextUsage" | "showDictation", show: boolean) {
  setComposerSettings({ [key]: show });
  composerHost?.(key === "showDictation" ? "pane.showDictation" : "pane.showContextUsage", show);
}

/// Controls whether sending a prompt moves the transcript to its latest row, and asks the host to
/// persist the choice. The page updates immediately so the context menu reflects the new state even
/// while the native settings write is in flight.
export function setScrollToBottomOnSend(show: boolean) {
  const write = ++scrollWrite;
  publishComposerSettings({ scrollToBottomOnSend: show });
  if (!composerHost) {
    confirmedScrollToBottomOnSend = show;
    return;
  }
  let result: unknown;
  try {
    result = composerHost("pane.setScrollToBottomOnSend", show);
  } catch {
    if (write === scrollWrite) publishComposerSettings({ scrollToBottomOnSend: confirmedScrollToBottomOnSend });
    return;
  }
  void Promise.resolve(result).then(
    () => {
      if (write === scrollWrite) confirmedScrollToBottomOnSend = show;
    },
    () => {
      if (write === scrollWrite) publishComposerSettings({ scrollToBottomOnSend: confirmedScrollToBottomOnSend });
    },
  );
}
