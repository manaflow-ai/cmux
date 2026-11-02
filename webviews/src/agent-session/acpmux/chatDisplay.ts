// The chat's look (plans/cmux-next/chat-display-settings-DESIGN.md, user 2026-10-20: "make almost
// everything configurable in markdown viewer to be configurable in the [chat]... like max width,
// fonts, ... code fonts configurable separately"). The host pushes the `display` event: a flat map
// of the cmux.json keys it accepted, `agentPane.display.*` and the Markdown viewer keys the chat
// follows (Swift CmuxNextSettings AgentPaneDisplaySetting). This module resolves them, sets the
// conversation's CSS variables (conversation/conversation.css) and gives the row estimator
// (model.ts) the same metrics, so rows measured before paint match what draws.
//
// Resolution: the chat's own key, else the Markdown viewer's for the font preset, code font and
// code size, else the default. Sizes and width never follow the viewer: the two views have their
// own defaults, and an upgrade must not move anyone's chat. Code follows the terminal font
// (`--cmux-diff-code-font-family`) unless a code font is set.
import { useSyncExternalStore } from "react";
import { isArm } from "../../experiments/experiment";
import { threadMinimapLayout } from "./threadMinimap/layout.experiment";

/// An arm of the thread minimap experiment (`off`, `full`, `compact`, whatever its definition lists).
export type ThreadMinimapArm = keyof typeof threadMinimapLayout.arms;

export type ChatFontPreset = "system" | "serif" | "mono";
/// What the chat keys hold: `markdown` follows the Markdown viewer's font.
export type ChatFontChoice = ChatFontPreset | "markdown";
/// The Session Info chip setting a cmux.json may still hold (Left, Right, Off). The chat header no
/// longer draws a machine · folder label (Leo, 2026-10-26: "i thought we said to remove this?"), so
/// every value is accepted and none draws one; Session Info's Environment says where a chat runs.
export type EnvironmentPlacement = "left" | "right" | "off";

export interface ChatDisplay {
  /// The column's cap in px (the chat's text width); `fullWidth` fills the pane instead.
  width: number;
  fullWidth: boolean;
  font: ChatFontPreset;
  fontSize: number;
  /// Unitless, times `fontSize`.
  lineHeight: number;
  /// A CSS font family, or null for the terminal font.
  codeFamily: string | null;
  /// Code as a share of the text size, or null for the chat's own code sizes (13px inline and
  /// 12px blocks at 14px text, scaled with the text).
  codeScale: number | null;
  /// Where Session Info goes when open (session-info/SessionInfo.tsx): `overlay` (the default) floats
  /// in the chat's right gutter, so opening, closing or updating it never reflows the chat (Leo,
  /// 2026-10-20), and pushes the chat aside only when the gutter has no room for it, so it never
  /// lies over the transcript's text (Leo, 2026-10-21); `push` always moves the chat aside. Not a
  /// look: the Text & Width popover's Reset leaves it.
  sessionInfo: "push" | "overlay";
  /// The prompt rail edge; its context menu writes the same saved setting.
  railSide: "left" | "right";
  /// cmux's Minimal Mode (`sidebar.minimal`, the palette's Enable Minimal Mode), which the chat
  /// follows: another agent's message reads as one line until opened (IncomingMessageCard.tsx; Leo
  /// 2026-10-24: "in minimal mode ... one line is kind of enough sometimes for the ... preview of the
  /// message"). Not a look either: Reset leaves it.
  minimal: boolean;
  /// The saved Session Info chip setting (EnvironmentPlacement), kept for configuration
  /// compatibility; it draws nothing.
  environmentPlacement: EnvironmentPlacement;
}

/// Settings > Agent Chat > Session Info (Swift AgentPaneDisplaySettingsSchema has the same row).
/// The saved settings key keeps its old `inspector` name, so a saved Push or Overlay choice survives.
export const SESSION_INFO_PLACEMENT_KEY = "agentPane.display.inspector.placement";
export const RAIL_SIDE_KEY = "agentPane.display.rail.side";
/// Settings > Agent Chat: the machine · folder chip's placement below the tab row.
export const ENVIRONMENT_PLACEMENT_KEY = "agentPane.display.environment.placement";
/// cmux's Minimal Mode, which the host sends with the chat's keys (Swift AgentPaneDisplaySetting).
export const MINIMAL_MODE_KEY = "sidebar.minimal";
/// Settings > Agent Chat > VS Code Minimap (chatMinimap/ChatMinimap.tsx), off by default. Not part of
/// ChatDisplay: turning it on or off must not measure the transcript's rows again.
export const CHAT_MINIMAP_KEY = "agentPane.display.vscodeMinimap";
/// Settings > Agent Chat > Chat Minimap (Swift AgentPaneDisplaySettingsSchema has the same row).
export const MINIMAP_KEY = "agentPane.display.minimap";
/// Settings > Updates > Show Feature Tips (featureTips.tsx), on unless set false. The host sends it
/// with the chat's keys (Swift AgentPaneDisplaySetting.followedAppPaths). Not part of ChatDisplay.
export const FEATURE_TIPS_KEY = "updates.showFeatureTips";

/// Settings > Agent Chat > Transcript View (conversation/transcriptView.ts): how much of each turn a
/// chat without a view of its own shows. Not part of ChatDisplay: a switch measures no row again by
/// itself; the rows it opens measure as they draw.
export const TRANSCRIPT_VIEW_KEY = "agentPane.display.transcriptView";
/// Normal: the compact transcript. Thinking: thoughts open. Verbose: tool output open too.
export type TranscriptView = "normal" | "thinking" | "verbose";
export const TRANSCRIPT_VIEWS: readonly TranscriptView[] = ["normal", "thinking", "verbose"];
export const isTranscriptView = (value: unknown): value is TranscriptView =>
  value === "normal" || value === "thinking" || value === "verbose";

/// Settings > Agent Chat > Presentation (conversation/presentation.ts): whether a chat shows the
/// complete transcript or the Messages-style bubble view with tool rows hidden.
export const PRESENTATION_KEY = "agentPane.display.presentation";
export type Presentation = "transcript" | "messages";
export const PRESENTATIONS: readonly Presentation[] = ["transcript", "messages"];
export const isPresentation = (value: unknown): value is Presentation => value === "transcript" || value === "messages";

/// Each option: its cmux.json key, its range and default. The Swift schema has the same rows
/// (AgentPaneDisplaySettingsSchema).
export const CHAT_DISPLAY = {
  width: { key: "agentPane.display.width", min: 480, max: 4000, step: 10, fallback: 800 },
  fullWidth: { key: "agentPane.display.fullWidth", fallback: false },
  font: { key: "agentPane.display.font.preset", fallback: "markdown" as ChatFontChoice },
  fontSize: { key: "agentPane.display.font.size", min: 10, max: 28, step: 1, fallback: 14 },
  lineHeight: { key: "agentPane.display.font.lineHeight", min: 1.2, max: 2.4, step: 0.05, fallback: 1.625 },
  codeFamily: { key: "agentPane.display.code.family" },
  codeScale: { key: "agentPane.display.code.scale", min: 0.6, max: 1.25, step: 0.025, fallback: 0.875 },
} as const;
export type ChatDisplayOption = keyof typeof CHAT_DISPLAY;

/// The Markdown viewer keys the chat follows when its own is unset.
export const MARKDOWN_FOLLOWED = {
  font: "markdown.font.preset",
  codeFamily: "markdown.code.family",
  codeScale: "markdown.code.scale",
} as const;

export const DEFAULT_CHAT_DISPLAY: ChatDisplay = {
  width: CHAT_DISPLAY.width.fallback,
  fullWidth: false,
  font: "system",
  fontSize: CHAT_DISPLAY.fontSize.fallback,
  lineHeight: CHAT_DISPLAY.lineHeight.fallback,
  codeFamily: null,
  codeScale: null,
  sessionInfo: "overlay",
  railSide: "left",
  minimal: false,
  environmentPlacement: "left",
};

/// The body font stacks, as the Markdown viewer's presets (pages/markdown/settings.ts).
const FONT_STACKS: Record<ChatFontPreset, string> = {
  system: "var(--font-ui)",
  serif: '"New York", ui-serif, "Iowan Old Style", Georgia, serif',
  mono: "var(--cv-mono)",
};
/// What the estimator's canvas measures each preset as (a canvas can't read CSS variables).
const MEASURE_STACKS: Record<ChatFontPreset, string> = {
  system: '"Inter", system-ui, sans-serif',
  serif: '"New York", Georgia, serif',
  mono: '"SF Mono", Menlo, monospace',
};

type Values = Record<string, unknown>;
const isPreset = (value: unknown): value is ChatFontPreset =>
  value === "system" || value === "serif" || value === "mono";
const isEnvironmentPlacement = (value: unknown): value is EnvironmentPlacement =>
  value === "left" || value === "right" || value === "off";
const number = (value: unknown, range: { min: number; max: number }): number | null =>
  typeof value === "number" && Number.isFinite(value) ? Math.min(range.max, Math.max(range.min, value)) : null;
/// A font family name safe to put in a CSS value: no quotes, braces or semicolons.
const family = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || /[;{}"\\<>]/.test(trimmed)) return null;
  return trimmed;
};

/// The Chat Minimap key's arm, or null for the experiment to decide. The key was an on/off toggle
/// before it was this choice: on (`true`) was the full map, and off left the chat to the experiment,
/// as no value does now. The Swift bridge reads it the same way (AgentPaneDisplaySettingsSchema
/// `pageValue`).
export function resolveThreadMinimapArm(raw: unknown): ThreadMinimapArm | null {
  const value = raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Values)[MINIMAP_KEY] : undefined;
  const arm = value === true ? "full" : value;
  return isArm(threadMinimapLayout, arm) ? arm : null;
}

/// The host's map (or anything else: the defaults).
export function resolveChatDisplay(raw: unknown): ChatDisplay {
  const values = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Values;
  const own = values[CHAT_DISPLAY.font.key];
  const font = isPreset(own)
    ? own
    : isPreset(values[MARKDOWN_FOLLOWED.font])
      ? (values[MARKDOWN_FOLLOWED.font] as ChatFontPreset)
      : "system";
  return {
    width: number(values[CHAT_DISPLAY.width.key], CHAT_DISPLAY.width) ?? DEFAULT_CHAT_DISPLAY.width,
    fullWidth: values[CHAT_DISPLAY.fullWidth.key] === true,
    font,
    fontSize: number(values[CHAT_DISPLAY.fontSize.key], CHAT_DISPLAY.fontSize) ?? DEFAULT_CHAT_DISPLAY.fontSize,
    lineHeight: number(values[CHAT_DISPLAY.lineHeight.key], CHAT_DISPLAY.lineHeight) ?? DEFAULT_CHAT_DISPLAY.lineHeight,
    codeFamily: family(values[CHAT_DISPLAY.codeFamily.key]) ?? family(values[MARKDOWN_FOLLOWED.codeFamily]),
    codeScale:
      number(values[CHAT_DISPLAY.codeScale.key], CHAT_DISPLAY.codeScale) ??
      number(values[MARKDOWN_FOLLOWED.codeScale], CHAT_DISPLAY.codeScale),
    sessionInfo: values[SESSION_INFO_PLACEMENT_KEY] === "push" ? "push" : "overlay",
    railSide: values[RAIL_SIDE_KEY] === "right" ? "right" : "left",
    minimal: values[MINIMAL_MODE_KEY] === true,
    environmentPlacement: isEnvironmentPlacement(values[ENVIRONMENT_PLACEMENT_KEY])
      ? values[ENVIRONMENT_PLACEMENT_KEY]
      : DEFAULT_CHAT_DISPLAY.environmentPlacement,
  };
}

/// The sizes the conversation draws at, in px, for the estimator and the CSS.
export interface ChatMetrics {
  /// The canvas font the estimator measures prose with.
  measureFont: string;
  lineHeight: number;
  inlineCodeSize: number;
  blockCodeSize: number;
  /// A code block line (20px at 12px code).
  codeLineHeight: number;
  /// A monospace cell (7.3px at 12px code).
  codeCharWidth: number;
}

const round = (value: number) => Math.round(value * 100) / 100;

export function chatMetrics(display: ChatDisplay): ChatMetrics {
  const scale = display.fontSize / DEFAULT_CHAT_DISPLAY.fontSize;
  const inline = display.codeScale === null ? 13 * scale : display.fontSize * display.codeScale;
  const block = display.codeScale === null ? 12 * scale : display.fontSize * display.codeScale;
  return {
    measureFont: `${display.fontSize}px ${MEASURE_STACKS[display.font]}`,
    lineHeight: round(display.fontSize * display.lineHeight),
    inlineCodeSize: round(inline),
    blockCodeSize: round(block),
    codeLineHeight: round((block * 20) / 12),
    codeCharWidth: (block * 7.3) / 12,
  };
}

/// Whether the column differs from the default one (then Debug Settings' chat width stops applying).
export const ownsColumn = (display: ChatDisplay) => display.fullWidth || display.width !== DEFAULT_CHAT_DISPLAY.width;

/// The CSS variables for `display`; a null value removes the variable (the stylesheet's default).
export function chatDisplayVariables(display: ChatDisplay): Record<string, string | null> {
  const metrics = chatMetrics(display);
  const isDefault = (key: keyof ChatDisplay) => display[key] === DEFAULT_CHAT_DISPLAY[key];
  const codeFont = display.codeFamily ? `${quoteFamily(display.codeFamily)}, var(--cv-mono-default)` : null;
  return {
    "--cv-font": isDefault("font") ? null : FONT_STACKS[display.font],
    "--cv-font-size": isDefault("fontSize") ? null : `${display.fontSize}px`,
    "--cv-line-height": isDefault("fontSize") && isDefault("lineHeight") ? null : `${metrics.lineHeight}px`,
    "--cv-code-size": isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.inlineCodeSize}px`,
    "--cv-codeblock-size": isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.blockCodeSize}px`,
    "--cv-codeblock-line-height":
      isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.codeLineHeight}px`,
    "--cv-mono": codeFont,
    "--cv-column": !ownsColumn(display)
      ? null
      : display.fullWidth
        ? "100%"
        : `clamp(calc(${Math.min(720, display.width)}px / var(--cmux-ui-scale, 1)), 100%, calc(${display.width}px / var(--cmux-ui-scale, 1)))`,
  };
}

/// A family name with spaces quoted; a generic family or a stack stays as written.
const quoteFamily = (name: string) => (/[,\s]/.test(name) && !name.includes(",") ? `"${name}"` : name);

let current = DEFAULT_CHAT_DISPLAY;
let raw: Values = {};
let minimapOn = false;
let threadMinimapArm: ThreadMinimapArm | null = null;
let transcriptView: TranscriptView = "normal";
let presentation: Presentation = "transcript";
let featureTipsOn = true;
const listeners = new Set<() => void>();

/// Sets the variables on `root` (the document's root in the page).
export function applyChatDisplay(root: HTMLElement, display: ChatDisplay): void {
  for (const [name, value] of Object.entries(chatDisplayVariables(display))) {
    if (value === null) root.style.removeProperty(name);
    else root.style.setProperty(name, value);
  }
}

/// The host's `display` event: the page follows at once.
export function setChatDisplay(value: unknown): void {
  raw = (value && typeof value === "object" && !Array.isArray(value) ? { ...(value as Values) } : {}) as Values;
  const next = resolveChatDisplay(raw);
  const minimap = raw[CHAT_MINIMAP_KEY] === true;
  const threadMinimap = resolveThreadMinimapArm(raw);
  const stored = raw[TRANSCRIPT_VIEW_KEY];
  const view = isTranscriptView(stored) ? stored : "normal";
  const storedPresentation = raw[PRESENTATION_KEY];
  const nextPresentation = isPresentation(storedPresentation) ? storedPresentation : "transcript";
  const tips = raw[FEATURE_TIPS_KEY] !== false;
  const same = JSON.stringify(next) === JSON.stringify(current);
  if (
    same &&
    minimap === minimapOn &&
    threadMinimap === threadMinimapArm &&
    view === transcriptView &&
    nextPresentation === presentation &&
    tips === featureTipsOn
  )
    return;
  minimapOn = minimap;
  threadMinimapArm = threadMinimap;
  transcriptView = view;
  presentation = nextPresentation;
  featureTipsOn = tips;
  if (same) {
    for (const listener of listeners) listener();
    return;
  }
  current = next;
  if (typeof document !== "undefined") applyChatDisplay(document.documentElement, next);
  for (const listener of listeners) listener();
}

/// The host's write of one chat key (`pane.setDisplay {key, value}`); a page with none (a gallery,
/// a test) keeps the change in the page.
type DisplayHost = (key: string, value: unknown) => void;
let displayHost: DisplayHost | undefined;
const unsent = new Map<string, ReturnType<typeof setTimeout>>();
/// A slider drag writes once, this long after its last step.
const WRITE_DELAY_MS = 250;

/// App's route to the host.
export function registerChatDisplayHost(write: DisplayHost | undefined): void {
  displayHost = write;
}

/// A change from the page's own popover: shows at once (the host's event confirms it). `null`
/// removes the key, so the chat follows the Markdown viewer or the default again.
export function changeChatDisplay(key: string, value: unknown): void {
  const next = { ...raw };
  if (value === null || value === undefined) delete next[key];
  else next[key] = value;
  setChatDisplay(next);
  if (!displayHost) return;
  const pending = unsent.get(key);
  if (pending !== undefined) clearTimeout(pending);
  const write = displayHost;
  unsent.set(
    key,
    setTimeout(() => {
      unsent.delete(key);
      write(key, value ?? null);
    }, WRITE_DELAY_MS),
  );
}

/// Removes every chat key, so the chat shows its default look (and follows the Markdown viewer).
export function resetChatDisplay(): void {
  for (const option of Object.values(CHAT_DISPLAY)) changeChatDisplay(option.key, null);
}

/// The chat's keys the page set, as the host last sent them (the popover shows which follow the viewer).
export const chatDisplayValues = (): Readonly<Values> => raw;
export const chatDisplay = (): ChatDisplay => current;
export const currentChatMetrics = (): ChatMetrics => chatMetrics(current);

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;
const minimapSnapshot = () => minimapOn;
const threadMinimapSnapshot = () => threadMinimapArm;
const transcriptViewSnapshot = () => transcriptView;
const presentationSnapshot = () => presentation;
/// The Transcript View setting: the view of a chat without its own (conversation/transcriptView.ts).
export const defaultTranscriptView = (): TranscriptView => transcriptView;
export const useDefaultTranscriptView = (): TranscriptView =>
  useSyncExternalStore(subscribe, transcriptViewSnapshot, transcriptViewSnapshot);
/// The presentation setting for a chat without its own (conversation/presentation.ts).
export const defaultPresentation = (): Presentation => presentation;
export const useDefaultPresentation = (): Presentation =>
  useSyncExternalStore(subscribe, presentationSnapshot, presentationSnapshot);
const featureTipsSnapshot = () => featureTipsOn;
/// Whether the chat minimap is on (CHAT_MINIMAP_KEY).
export const useChatMinimap = (): boolean => useSyncExternalStore(subscribe, minimapSnapshot, minimapSnapshot);
/// The rail's arm, separate from the measured chat look so switching it remeasures no transcript row.
export const useThreadMinimapArm = (): ThreadMinimapArm | null =>
  useSyncExternalStore(subscribe, threadMinimapSnapshot, threadMinimapSnapshot);
/// Whether feature tips may show (FEATURE_TIPS_KEY).
export const useFeatureTipsOn = (): boolean =>
  useSyncExternalStore(subscribe, featureTipsSnapshot, featureTipsSnapshot);
/// The live look, so layouts measured at the old metrics are measured again.
export const useChatDisplay = (): ChatDisplay => useSyncExternalStore(subscribe, snapshot, snapshot);
