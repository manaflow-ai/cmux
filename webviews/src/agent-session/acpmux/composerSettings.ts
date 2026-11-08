// `agentPane.showContextUsage`, `agentPane.showDictation` and `agentPane.spellChecking` in cmux.json (Swift CmuxNextSettings
// AgentPaneComposerSetting), pushed by the host as the `composer` event: whether every composer
// (the chat's and the New Tab page's) shows its context usage ring and its dictation mic. Each
// hides the macOS way (composerChrome.tsx): its right-click offers Hide, and a right-click on the
// composer's button row offers Show. The page sets the value at once and asks the host to write it
// (`pane.showContextUsage`, `pane.showDictation`), which pushes it back, also on the next launch.
// `agentPane.attachmentView` rides the same event as `attachmentView`: how pictures and files show
// in every composer and in sent messages, "inline" (in the text where each was added, the default),
// "strip" (in a row) or "both" (in the text and in the row, so every attachment shows in one place
// with its remove; Leo 2026-10-24: "ALSO show the top displayed attachments alongside the inline
// attachments ... so you can see it all and close aka delete"). Sent messages draw "both" as
// "inline". It is only a look: a draft's text, its attachment marks and their order are the same
// in every view, so switching never changes what is sent. Anything else reads as "inline".
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
// `showMachineLoadWarnings` is the user setting for the Computer menu's cached host-health detail.
// `composerRing` is `agentPane.composerRing` ("context" by default): what the ring at the end of the
// quiet row shows, the chat's context window or the account's plan usage limits (5-hour, weekly;
// PlanUsageCard.tsx), picked from the ring's right-click (Leo 2026-11-04: "i guess we can turn that
// into a 5h/weekly usage type thing instead as well for some people"). The page sets it at once and
// asks the host to write it (`pane.setComposerRing {ring}`). Anything else reads as "context".
// `dictationSource` is `agentPane.dictationSource` ("cmux" by default): what the mic dictates with,
// cmux's own dictation or the dictation app the person already uses, whose shortcut the host sends
// (dictationSources.ts, design/composer-dictation.md). The mic's right-click picks it
// (`pane.setDictationSource {source}`). `dictationShortcut` (`agentPane.dictationShortcut`) is only
// read: the chord the host sends, empty for the app's own. Anything else reads as "cmux".
// `newChatsIn` is `agentPane.newChatsIn` ("Start New Chats In", "local" by default): "cloud" makes a
// new chat's run location Cloud unless its composer picks another (runLocationDefault.ts).
// `cloudEnvironments` is the launch flag CLOUD_ENVIRONMENTS_ENABLED (Swift
// AgentPaneTunables.cloudEnvironmentsEnabled, read from the bundle's LSEnvironment or the launch
// environment as CMUX_NEXT_CLOUD_NATIVE_LINK is; no cmux.json key): on, picking Cloud in a new
// chat's strip adds the Environment chip (CloudEnvironmentChip.tsx), on Auto. On by default, as the
// host's flag is: only the host's `false` (CLOUD_ENVIRONMENTS_ENABLED=0 or false) hides it.
import { useSyncExternalStore } from "react";

// `symbols`: one row of harness symbols at the top of the model picker, each name on hover (Leo
// 2026-10-30: "honestly we had a pretty good thing going with teh symbols of the harneses at the
// top :("). The others stay as choices.
export type { HarnessPlacement } from "../../ui/harnessPlacement";
import type { HarnessPlacement } from "../../ui/harnessPlacement";
export type ReasoningSliderStyle = "accent" | "minimal";
export type AttachmentView = "inline" | "strip" | "both";
export type NewChatPlace = "local" | "cloud";
export type ComposerRing = "context" | "planUsage";
export const DICTATION_SOURCES = ["cmux", "macos", "chatgpt", "claude", "gemini", "wisprFlow", "superwhisper"] as const;
export type DictationSource = (typeof DICTATION_SOURCES)[number];
export type ComposerSettings = {
  showContextUsage: boolean;
  showDictation: boolean;
  dictationSource: DictationSource;
  dictationShortcut: string;
  spellChecking: boolean;
  attachmentView: AttachmentView;
  scrollToBottomOnSend: boolean;
  reasoningSlider: boolean;
  reasoningSliderStyle: ReasoningSliderStyle;
  plainFooter: boolean;
  harnessPlacement: HarnessPlacement;
  harnessSwitch: boolean;
  showMachineLoadWarnings: boolean;
  newChatsIn: NewChatPlace;
  composerRing: ComposerRing;
  cloudEnvironments: boolean;
};

export const DEFAULT_COMPOSER: ComposerSettings = {
  showContextUsage: true,
  showDictation: true,
  dictationSource: "cmux",
  dictationShortcut: "",
  spellChecking: false,
  attachmentView: "inline",
  scrollToBottomOnSend: true,
  reasoningSlider: false,
  reasoningSliderStyle: "accent",
  plainFooter: true,
  harnessPlacement: "symbols",
  harnessSwitch: false,
  showMachineLoadWarnings: true,
  newChatsIn: "local",
  composerRing: "context",
  cloudEnvironments: true,
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
  | "showMachineLoadWarnings"
  | "cloudEnvironments";

/// The host's value; anything it does not know keeps the default.
export function readComposerSettings(value: unknown): ComposerSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const flag = (key: ComposerFlag) => (typeof raw[key] === "boolean" ? raw[key] : DEFAULT_COMPOSER[key]);
  const reasoningSliderStyle: ReasoningSliderStyle = raw.reasoningSliderStyle === "minimal" ? "minimal" : "accent";
  const attachmentView: AttachmentView =
    raw.attachmentView === "strip" || raw.attachmentView === "both" ? raw.attachmentView : "inline";
  return {
    showContextUsage: flag("showContextUsage"),
    showDictation: flag("showDictation"),
    dictationSource: DICTATION_SOURCES.includes(raw.dictationSource as DictationSource)
      ? (raw.dictationSource as DictationSource)
      : "cmux",
    dictationShortcut: typeof raw.dictationShortcut === "string" ? raw.dictationShortcut : "",
    spellChecking: flag("spellChecking"),
    attachmentView,
    scrollToBottomOnSend: flag("scrollToBottomOnSend"),
    reasoningSlider: flag("reasoningSlider"),
    reasoningSliderStyle,
    plainFooter: flag("plainFooter"),
    harnessPlacement:
      raw.harnessPlacement === "left" || raw.harnessPlacement === "top" || raw.harnessPlacement === "compact"
        ? raw.harnessPlacement
        : "symbols",
    harnessSwitch: flag("harnessSwitch"),
    showMachineLoadWarnings: flag("showMachineLoadWarnings"),
    newChatsIn: raw.newChatsIn === "cloud" ? "cloud" : "local",
    composerRing: raw.composerRing === "planUsage" ? "planUsage" : "context",
    cloudEnvironments: flag("cloudEnvironments"),
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
    // A static render (a sent bubble's markup, renderToStaticMarkup) reads the same page value.
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

/// The host's write of `agentPane.composerRing` (`pane.setComposerRing {ring}`).
let composerRingHost: ((ring: ComposerRing) => unknown) | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerComposerRingHost(write: ((ring: ComposerRing) => unknown) | undefined) {
  composerRingHost = write;
}

/// Shows the context window or the plan usage limits in every composer's ring, and asks the host
/// to persist it. The page changes at once and keeps the choice even when the write fails (an older
/// host without the setting): it is only a look, and the host's next value is authoritative.
export function setComposerRing(ring: ComposerRing) {
  setComposerSettings({ composerRing: ring });
  try {
    void Promise.resolve(composerRingHost?.(ring)).catch(() => undefined);
  } catch {
    // The page keeps its choice (above).
  }
}

/// The host's write of `agentPane.dictationSource` (`pane.setDictationSource {source}`).
let dictationSourceHost: ((source: DictationSource) => unknown) | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps its choice in the page.
export function registerDictationSourceHost(write: ((source: DictationSource) => unknown) | undefined) {
  dictationSourceHost = write;
}

/// Picks what every composer's mic dictates with, and asks the host to persist it. The page changes
/// at once, as the ring's pick does; the host's next value is authoritative.
export function setDictationSource(source: DictationSource) {
  setComposerSettings({ dictationSource: source });
  try {
    void Promise.resolve(dictationSourceHost?.(source)).catch(() => undefined);
  } catch {
    // The page keeps its choice (above).
  }
}
