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
import {
  DEFAULT_RAIL_SHOW,
  isRailShow,
  RAIL_CONTROL_KEY,
  RAIL_SHOW_KEY,
  type RailShow,
} from "./threadMinimap/railShow";
import { useSyncExternalStore } from "react";
import { configureSenderIconLook } from "./subagents/senderIconLook";
import { HARNESS_PLACEMENT_KEY, harnessPlacement, type HarnessPlacement } from "../../ui/harnessPlacement";
import { isArm, experimentArm } from "../../experiments/experiment";
import { readingLook, readingLookValues } from "./readingLook.experiment";
import {
  HIGH_CONTRAST_CHAT_VARIABLES,
  highContrastLook,
  highContrastLookValues,
  type HighContrastChatVariable,
} from "./highContrastLook.experiment";
import { threadMinimapLayout } from "./threadMinimap/layout.experiment";
import {
  CHAT_UI_FONT_KEY,
  chatUiFontVariables,
  chatUiMeasureStack,
  DEFAULT_CHAT_UI_FONT,
  isChatUiFont,
  loadChatUiFont,
  type ChatUiFont,
} from "./chatUiFont";
import {
  applyChatFontFaces,
  CHAT_FONT_FACES_KEY,
  chatFontFacesKey,
  measurableStack,
  quoteFamilyStack,
  declaresFirstFamily,
  resolveChatFontFaces,
} from "./chatFontFaces";
import { configureStatusVerbs } from "./statusVerbs";
import { configureChatLayout } from "./chatLayout";
import { configureThinkingLook } from "./conversation/thinkingLook";
import { isUnreadBannerMode, type UnreadBannerMode } from "./conversation/unreadState";
import {
  DEFAULT_RESOLVED_TRANSCRIPT_LOOK,
  gapScaleOf,
  resolveTranscriptLook,
  transcriptLookAttributes,
  transcriptLookDisplayFallbacks,
  transcriptLookVariables,
  transcriptPartType,
  transcriptPartTypeFromTokens,
  type ResolvedTranscriptLook,
  type TranscriptPartType,
} from "./conversation/transcriptLook";

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
  /** Null preserves the existing Debug placement until an ordinary preference is saved. */
  harnessPlacement: HarnessPlacement | null;
  managedHarnessPlacement: HarnessPlacement | null;
  /// The column's cap in px (the chat's text width); `fullWidth` fills the pane instead.
  width: number;
  fullWidth: boolean;
  font: ChatFontPreset;
  /// The face of the whole chat (chatUiFont.ts): `--font-ui`, which the System preset's text follows.
  uiFont: ChatUiFont;
  /// A font pack's interface family or stack (UI_FAMILY_KEY), which wins over `uiFont`; null for none.
  uiFamily: string | null;
  /// A font pack's family or stack for the agent's reply prose (PROSE_FAMILY_KEY), which wins over
  /// `font` there and only there; null for none.
  proseFamily: string | null;
  fontSize: number;
  /// Unitless, times `fontSize`.
  lineHeight: number;
  /// A CSS font family, or null for the terminal font.
  codeFamily: string | null;
  /// Code as a share of the text size, or null for the chat's own code sizes (13px inline and
  /// 12px blocks at 14px text, scaled with the text).
  codeScale: number | null;
  /// False when the code family is a font pack's own face (its first family is in the faces map):
  /// code then draws without ligatures, so `=>` and `===` read as typed, as in the default chat's
  /// code font. A code family set to an installed font keeps its ligatures.
  codeLigatures: boolean;
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
  /// The transcript's look (conversation/transcriptLook.ts: `agentPane.display.transcriptLook` and
  /// its token overrides). Part of the measured look: its bubble padding, share and gaps move rows.
  transcriptLook: ResolvedTranscriptLook;
  /// The agent's reply prose apart from the chat's text (the look's `reply.font` and
  /// `reply.fontSize`; Claude's replies are a serif): null for the chat's face or size.
  replyFont: ChatFontPreset | null;
  replyFontSize: number | null;
  /// The person's prompts apart from the chat's text (`userMessage.font`, `userMessage.fontSize`).
  promptFont: ChatFontPreset | null;
  promptFontSize: number | null;
}

/// Settings > Agent Chat > Session Info (Swift AgentPaneDisplaySettingsSchema has the same row).
/// The host sends a value saved under the row's old key under this one (Swift RenamedSettingKeys).
export const SESSION_INFO_PLACEMENT_KEY = "agentPane.display.sessionInfo.placement";
export const RAIL_SIDE_KEY = "agentPane.display.rail.side";
/// Settings > Agent Chat: the machine · folder chip's placement below the tab row.
export const ENVIRONMENT_PLACEMENT_KEY = "agentPane.display.environment.placement";
/// cmux's Minimal Mode, which the host sends with the chat's keys (Swift AgentPaneDisplaySetting).
export const MINIMAL_MODE_KEY = "sidebar.minimal";
/// Settings > Agent Chat > VS Code Minimap (chatMinimap/ChatMinimap.tsx), off by default. Not part of
/// ChatDisplay: turning it on or off must not measure the transcript's rows again.
export const CHAT_MINIMAP_KEY = "agentPane.display.vscodeMinimap";
/// Settings > Agent Chat > Pin Task List in Chat, off by default: the running turn's todo list pinned
/// under its latest message (conversation/turns.ts). Off, the composer's hat shows it
/// (subagents/SubagentTray.tsx `plan`; Leo, 2026-11-03: "we said earlier the composer hat is kinda ok?").
/// Not part of ChatDisplay: switching it measures no transcript row again.
export const PINNED_PLAN_KEY = "agentPane.display.pinnedPlan";
/// Settings > Agent Chat > Tuck Away Running Tray, off by default: the hat over the composer
/// (subagents/SubagentTray.tsx) tucks away to a chevron at the top middle of the composer, shown on
/// hover, which brings it back (subagents/TrayPullTab.tsx; Leo, 2026-11-04: "what if you wanted to
/// collapse that one line?"). The hat's own chevron, the palette, the CLI and MCP write the same key.
/// Not part of ChatDisplay: switching it measures no transcript row again.
export const TRAY_TUCKED_KEY = "agentPane.display.trayTucked";
/// Settings > Agent Chat > Pop In Sent Prompts, off by default: a sent prompt pops in and settles
/// where it lands (conversation.css SEND-POP). On, the page's root carries `data-send-pop="claude"`,
/// the rule's gate. Off by default because Leo, 2026-11-22: "hm im not necessarily sure if people
/// will be wanting to do the send pop by default". Not part of ChatDisplay: no row is measured again.
export const SEND_POP_KEY = "agentPane.display.sendPop";
/// Settings > Agent Chat > Running Tray Handle, the middle by default: where along the composer's top
/// edge the hat's tuck chevron and, tucked, its pull tab sit (subagents/TrayPullTab.tsx; Leo,
/// 2026-11-04: "I also wonder if we'd want the grabber/dogear/whatever design thing on maybe the left…
/// or the right…"). Not part of ChatDisplay: switching it measures no transcript row again.
export const TRAY_HANDLE_KEY = "agentPane.display.trayHandle";
export type TrayHandleSide = "left" | "middle" | "right";
/// Settings > Agent Chat > Unread Banner, off by default (Lawrence, 2026-11-11 standup: the "where
/// you left off" arrow "I don't think that's good", match Codex): the floating "3 new turns since 3:42"
/// banner at the transcript's top start while the "New" line is off screen
/// (conversation/SinceDivider.tsx UnreadBanner; Leo, 2026-11-10: "you can have the collapsed view.
/// You can have the expanded view. You can have, like, right click to just hide it completely").
/// The banner's chevron and both right-click menus write it. Not part of ChatDisplay: switching it
/// measures no transcript row again.
export const UNREAD_BANNER_KEY = "agentPane.display.unreadBanner";
/// Settings > Agent Chat > Chat Minimap (Swift AgentPaneDisplaySettingsSchema has the same row).
export const MINIMAP_KEY = "agentPane.display.minimap";
/// Settings > Updates > Show Feature Tips (featureTips.tsx), off unless set true. The host sends it
/// with the chat's keys (Swift AgentPaneDisplaySetting.followedAppPaths). Not part of ChatDisplay.
export const FEATURE_TIPS_KEY = "updates.showFeatureTips";
/// AutoCloud (autoCloud.ts): hidden in cmux-next.json, off unless set true. The host sends it with the
/// chat's keys (Swift AgentPaneDisplaySetting.followedAppPaths). Not part of ChatDisplay.
export const AUTO_CLOUD_KEY = "cloud.autoCloud";
/// cmux-next.json only: the command rules and presets the running tray names background commands
/// with (session-info/commandLabelSettings.ts; Swift CommandLabelsSetting). Not part of ChatDisplay.
export const COMMAND_LABELS_KEY = "agentPane.display.commandLabels";
/// Settings > Agent Chat > Prompt Coach, on unless set false: after a chat that took several
/// corrections, a card shows how its first prompt could have said it all at once
/// (conversation/PromptCoachCard.tsx). Off, the page asks acpmux for no rewrite and draws no card.
/// Not part of ChatDisplay.
export const PROMPT_COACH_KEY = "agentPane.display.promptCoach";
/// Settings > Agent Chat > Environment Card, off by default: a floating card at the chat's top right
/// with its changes, branch or worktree, Commit or push and Create PR (session-info/EnvironmentCard.tsx),
/// after the Codex app's Environment panel. A look turns it on. Not part of ChatDisplay: switching it
/// measures no transcript row again.
export const ENVIRONMENT_CARD_KEY = "agentPane.display.environmentCard";
/// Settings > Agent Chat > Changes Pill, off by default: "1 file changed +2 -2" over the composer
/// (session-info/EnvironmentCard.tsx ChangesPill), which opens the diff beside the chat. Not part of
/// ChatDisplay.
export const CHANGES_PILL_KEY = "agentPane.display.changesPill";
/// Settings > Agent Chat > Model Logo in Composer (modelChipIcon.ts), on unless set false; the model
/// chip's right-click writes it. The agent pages' storage ends with the launch
/// (AgentPaneView.sharedDataStore and Chromium's off-the-record profile), so a pick kept only there
/// was lost at every restart, as the composer's look was (Leo, 2026-11-14: "if i picked the claude
/// style composer it should remember it after restart instead of always only going to the codex
/// mode"). Not part of ChatDisplay.
export const MODEL_CHIP_ICON_KEY = "agentPane.display.modelChipIcon";
/// Settings > Agent Chat > Queue Prompts During a Turn (queueing.ts), on unless set false; a queued
/// row's menu and the composer's button row write it. Not part of ChatDisplay.
export const QUEUEING_KEY = "agentPane.display.queueing";
/// The viewer's picks the page makes and the host keeps (`pane.setDisplay`): the modules that own
/// them read them with `pickedDisplayValue` and follow `subscribeChatDisplay`.
const PICKED_KEYS = [MODEL_CHIP_ICON_KEY, QUEUEING_KEY] as const;

/// A font pack's families (a community typography theme from the app store; Swift
/// AgentPaneDisplaySetting sends them with the chat's keys): a CSS family or comma stack without
/// quotes. The interface family wins over the Interface Font (`--font-ui`, chatUiFont.ts); the prose
/// family over the Chat Font for the agent's replies (`--cv-reply-font`, conversation.css), not the
/// person's prompts, cards or chrome. Their faces come in `CHAT_FONT_FACES_KEY` (chatFontFaces.ts).
/// Not in CHAT_DISPLAY: the popover's Reset leaves a pack's keys to the pack.
export const UI_FAMILY_KEY = "agentPane.display.font.uiFamily";
export const PROSE_FAMILY_KEY = "agentPane.display.font.proseFamily";
export { CHAT_FONT_FACES_KEY };

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

/// Settings > Agent Chat > Working Status Verbs. The mode is `thinking` by default; `rotate` opts
/// into the per-turn -ing verbs and `custom` reads the comma-separated list in `STATUS_VERB_CUSTOM_KEY`.
export const STATUS_VERB_MODE_KEY = "agentPane.display.statusVerbs.mode";
export const STATUS_VERB_CUSTOM_KEY = "agentPane.display.statusVerbs.custom";

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
  harnessPlacement: null,
  managedHarnessPlacement: null,
  width: CHAT_DISPLAY.width.fallback,
  fullWidth: false,
  font: "system",
  uiFont: DEFAULT_CHAT_UI_FONT,
  uiFamily: null,
  proseFamily: null,
  fontSize: CHAT_DISPLAY.fontSize.fallback,
  lineHeight: CHAT_DISPLAY.lineHeight.fallback,
  codeFamily: null,
  codeScale: null,
  codeLigatures: true,
  sessionInfo: "overlay",
  railSide: "left",
  minimal: false,
  environmentPlacement: "left",
  transcriptLook: DEFAULT_RESOLVED_TRANSCRIPT_LOOK,
  replyFont: null,
  replyFontSize: null,
  promptFont: null,
  promptFontSize: null,
};

/// The body font stacks, as the Markdown viewer's presets (pages/markdown/settings.ts).
const FONT_STACKS: Record<ChatFontPreset, string> = {
  system: "var(--font-ui)",
  serif: '"New York", ui-serif, "Iowan Old Style", Georgia, serif',
  mono: "var(--cv-mono)",
};
/// What the estimator's canvas measures each preset as (a canvas can't read CSS variables).
const MEASURE_STACKS: Record<ChatFontPreset, string> = {
  system: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
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
/// The person's own width (a named width or px), or null when unset so a look's width stands in.
function transcriptWidth(value: unknown): number | null {
  switch (value) {
    case "narrow":
      return 640;
    case "medium":
      return CHAT_DISPLAY.width.fallback;
    case "wide":
      return 960;
    default:
      return number(value, CHAT_DISPLAY.width);
  }
}

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
  // The look's width, font and sizes stand in for the defaults; the person's own key still wins
  // (an explicit `markdown` font too: it follows the viewer).
  const transcriptLook = resolveTranscriptLook(values);
  const lookFallback = transcriptLookDisplayFallbacks(transcriptLook);
  const own = values[CHAT_DISPLAY.font.key];
  const font = isPreset(own)
    ? own
    : own !== "markdown" && lookFallback.font
      ? lookFallback.font
      : isPreset(values[MARKDOWN_FOLLOWED.font])
        ? (values[MARKDOWN_FOLLOWED.font] as ChatFontPreset)
        : "system";
  const codeFamily = family(values[CHAT_DISPLAY.codeFamily.key]) ?? family(values[MARKDOWN_FOLLOWED.codeFamily]);
  // The reply's and the prompt's own face and size: the person's tokens, else the look's unless the
  // person set the chat's font or size themselves (then their whole-chat choice wins over a look's).
  const partType = transcriptPartType(transcriptLook);
  const partFromTokens = transcriptPartTypeFromTokens(values);
  const ownFont = isPreset(own) || own === "markdown";
  const ownSize = number(values[CHAT_DISPLAY.fontSize.key], CHAT_DISPLAY.fontSize) !== null;
  const part = <K extends keyof TranscriptPartType>(key: K, personSet: boolean) =>
    (partFromTokens[key] || !personSet ? partType[key] : undefined) ?? null;
  return {
    harnessPlacement: harnessPlacement(values[HARNESS_PLACEMENT_KEY]),
    managedHarnessPlacement: harnessPlacement(values[`${HARNESS_PLACEMENT_KEY}.managed`]),
    width: transcriptWidth(values[CHAT_DISPLAY.width.key]) ?? lookFallback.width ?? DEFAULT_CHAT_DISPLAY.width,
    fullWidth: values[CHAT_DISPLAY.fullWidth.key] === true,
    font,
    uiFont: isChatUiFont(values[CHAT_UI_FONT_KEY]) ? values[CHAT_UI_FONT_KEY] : DEFAULT_CHAT_UI_FONT,
    uiFamily: family(values[UI_FAMILY_KEY]),
    proseFamily: family(values[PROSE_FAMILY_KEY]),
    fontSize:
      number(values[CHAT_DISPLAY.fontSize.key], CHAT_DISPLAY.fontSize) ??
      lookFallback.fontSize ??
      DEFAULT_CHAT_DISPLAY.fontSize,
    lineHeight:
      number(values[CHAT_DISPLAY.lineHeight.key], CHAT_DISPLAY.lineHeight) ??
      lookFallback.lineHeight ??
      DEFAULT_CHAT_DISPLAY.lineHeight,
    codeFamily,
    codeScale:
      number(values[CHAT_DISPLAY.codeScale.key], CHAT_DISPLAY.codeScale) ??
      number(values[MARKDOWN_FOLLOWED.codeScale], CHAT_DISPLAY.codeScale),
    codeLigatures: !declaresFirstFamily(values[CHAT_FONT_FACES_KEY], codeFamily),
    sessionInfo: values[SESSION_INFO_PLACEMENT_KEY] === "push" ? "push" : "overlay",
    railSide: values[RAIL_SIDE_KEY] === "right" ? "right" : "left",
    minimal: values[MINIMAL_MODE_KEY] === true,
    environmentPlacement: isEnvironmentPlacement(values[ENVIRONMENT_PLACEMENT_KEY])
      ? values[ENVIRONMENT_PLACEMENT_KEY]
      : DEFAULT_CHAT_DISPLAY.environmentPlacement,
    transcriptLook,
    replyFont: part("replyFont", ownFont),
    replyFontSize: part("replyFontSize", ownSize),
    promptFont: part("promptFont", ownFont),
    promptFontSize: part("promptFontSize", ownSize),
  };
}

/// One part of the transcript's text as the estimator measures it.
export interface PartMetrics {
  measureFont: string;
  lineHeight: number;
}

/// The sizes the conversation draws at, in px, for the estimator and the CSS.
export interface ChatMetrics {
  /// The canvas font the estimator measures prose with.
  measureFont: string;
  /// The canvas font of the agent's replies: `measureFont` unless a font pack's prose family or the
  /// look's reply face or size is set.
  replyMeasureFont: string;
  /// The reply's and the prompt's text: their canvas font and line, the chat's unless the look sets
  /// their own (`reply.*`, `userMessage.font*`). model.ts measures each row kind with its own.
  reply: PartMetrics;
  prompt: PartMetrics;
  lineHeight: number;
  inlineCodeSize: number;
  blockCodeSize: number;
  /// A code block line (20px at 12px code).
  codeLineHeight: number;
  /// A monospace cell (7.3px at 12px code).
  codeCharWidth: number;
}

const round = (value: number) => Math.round(value * 100) / 100;

/// The chat's text scale (the host's `--cmux-chat-text-scale`, Typography+PageDensity.swift): Default's at and below
/// Default, so Compact draws the chat as Default does (user 2026-11-16: "make it so compact and default density have
/// same size of both imessage and chat trajectory"), and the page's above it; Text Size grows it at every density.
/// A page without the host's value (the gallery, a test) draws at 1. The person's own font size is kept as stored and
/// drawn at it.
const readDensityTextScale = (): number => {
  if (typeof document === "undefined") return 1;
  const parsed = Number.parseFloat(document.documentElement?.style?.getPropertyValue?.("--cmux-chat-text-scale") ?? "");
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
};
let densityTextScale = readDensityTextScale();

/// The chat's drawn font size: the person's, at the density's text scale, in quarter pixels.
export const drawnFontSize = (display: ChatDisplay, scale: number = densityTextScale): number =>
  drawnSize(display.fontSize, scale);
const drawnSize = (size: number, scale: number): number => Math.round(size * scale * 4) / 4;

export function chatMetrics(display: ChatDisplay, density: number = densityTextScale): ChatMetrics {
  const fontSize = drawnFontSize(display, density);
  const scale = fontSize / DEFAULT_CHAT_DISPLAY.fontSize;
  const inline = display.codeScale === null ? 13 * scale : fontSize * display.codeScale;
  const block = display.codeScale === null ? 12 * scale : fontSize * display.codeScale;
  // The System preset's text is the interface font, whichever it is.
  const stack =
    display.font === "system" ? chatUiMeasureStack(display.uiFont, display.uiFamily) : MEASURE_STACKS[display.font];
  // A reply in a pack's prose family falls back to the chat's font (`--cv-reply-font`); its family
  // counts once its face has loaded.
  const prose = display.proseFamily ? measurableStack(display.proseFamily) : "";
  const faceStack = (face: ChatFontPreset | null) =>
    face === null
      ? stack
      : face === "system"
        ? chatUiMeasureStack(display.uiFont, display.uiFamily)
        : MEASURE_STACKS[face];
  const sized = (size: number | null) => (size === null ? fontSize : drawnSize(size, density));
  const replySize = sized(display.replyFontSize);
  const replyStack = faceStack(display.replyFont);
  const replyMeasureFont = `${replySize}px ${prose ? `${prose}, ${replyStack}` : replyStack}`;
  const promptSize = sized(display.promptFontSize);
  return {
    measureFont: `${fontSize}px ${stack}`,
    replyMeasureFont,
    reply: { measureFont: replyMeasureFont, lineHeight: round(replySize * display.lineHeight) },
    prompt: {
      measureFont: `${promptSize}px ${faceStack(display.promptFont)}`,
      lineHeight: round(promptSize * display.lineHeight),
    },
    lineHeight: round(fontSize * display.lineHeight),
    inlineCodeSize: round(inline),
    blockCodeSize: round(block),
    codeLineHeight: round((block * 20) / 12),
    codeCharWidth: (block * 7.3) / 12,
  };
}

/// The CSS variables for `display`; a null value removes the variable (the stylesheet's default).
export function chatDisplayVariables(
  display: ChatDisplay,
  density: number = densityTextScale,
): Record<string, string | null> {
  const metrics = chatMetrics(display, density);
  const fontSize = drawnFontSize(display, density);
  const isDefault = (key: keyof ChatDisplay) =>
    key === "fontSize" ? fontSize === DEFAULT_CHAT_DISPLAY.fontSize : display[key] === DEFAULT_CHAT_DISPLAY[key];
  const codeFont = display.codeFamily ? `${quoteFamily(display.codeFamily)}, var(--cv-mono-default)` : null;
  return {
    ...chatUiFontVariables(display.uiFont, display.uiFamily),
    "--cv-font": isDefault("font") ? null : FONT_STACKS[display.font],
    // The agent's reply prose (conversation.css `.cv-reply`), the chat's font unless a pack or the
    // look's `reply.font` sets one (a pack's family first, the look's face behind it).
    "--cv-reply-font": display.proseFamily
      ? `${quoteFamilyStack(display.proseFamily)}, ${display.replyFont ? FONT_STACKS[display.replyFont] : "var(--cv-font)"}`
      : display.replyFont
        ? FONT_STACKS[display.replyFont]
        : null,
    // At its designed spacing, as a pack's interface family is, whatever the Interface Font tracks.
    "--cv-reply-tracking": display.proseFamily || (display.replyFont && display.replyFont !== "system") ? "0px" : null,
    // The reply's own size and line (conversation.css `:root[data-transcript-reply-size] .cv-reply`).
    "--cv-reply-font-size": display.replyFontSize === null ? null : `${drawnSize(display.replyFontSize, density)}px`,
    "--cv-reply-line-height": display.replyFontSize === null ? null : `${metrics.reply.lineHeight}px`,
    // Your prompts' own face, size and line (conversation.css `.cv-user__bubble`).
    "--cv-prompt-font": display.promptFont ? FONT_STACKS[display.promptFont] : null,
    "--cv-prompt-tracking": display.promptFont && display.promptFont !== "system" ? "0px" : null,
    "--cv-prompt-font-size": display.promptFontSize === null ? null : `${drawnSize(display.promptFontSize, density)}px`,
    "--cv-prompt-line-height": display.promptFontSize === null ? null : `${metrics.prompt.lineHeight}px`,
    // A pack's code face draws as typed (conversation.css `.cv-code`, `.cv-codeblock__body`).
    "--cv-code-ligatures": display.codeLigatures ? null : "none",
    "--cv-code-features": display.codeLigatures ? null : '"calt" 0, "liga" 0',
    "--cv-font-size": isDefault("fontSize") ? null : `${fontSize}px`,
    // New Tab applies density with zoom, so its prompt needs the unscaled preference.
    "--cv-base-font-size": display.fontSize === DEFAULT_CHAT_DISPLAY.fontSize ? null : `${display.fontSize}px`,
    "--cv-base-line-height":
      display.fontSize === DEFAULT_CHAT_DISPLAY.fontSize && isDefault("lineHeight")
        ? null
        : `${round(display.fontSize * display.lineHeight)}px`,
    "--cv-line-height": isDefault("fontSize") && isDefault("lineHeight") ? null : `${metrics.lineHeight}px`,
    "--cv-code-size": isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.inlineCodeSize}px`,
    "--cv-codeblock-size": isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.blockCodeSize}px`,
    "--cv-codeblock-line-height":
      isDefault("fontSize") && isDefault("codeScale") ? null : `${metrics.codeLineHeight}px`,
    "--cv-mono": codeFont,
    // The stylesheet's default is the default width's column, so only another width or Full Width
    // sets it; chatWidth.ts displayColumn mirrors both for the row estimator.
    "--cv-column": display.fullWidth
      ? "100%"
      : isDefault("width")
        ? null
        : `clamp(calc(${Math.min(720, display.width)}px / var(--cmux-ui-scale, 1)), 100%, calc(${display.width}px / var(--cmux-ui-scale, 1)))`,
    // The transcript look's primitives (conversation/transcriptLook.ts); every one null for cmux.
    ...transcriptLookVariables(display.transcriptLook),
  };
}

/// A family name with spaces quoted; a generic family or a stack stays as written.
const quoteFamily = (name: string) => (/[,\s]/.test(name) && !name.includes(",") ? `"${name}"` : name);

let current = DEFAULT_CHAT_DISPLAY;
let raw: Values = {};
let minimapOn = false;
let pinnedPlanOn = false;
let trayTuckedOn = false;
let sendPopOn = false;
let trayHandle: TrayHandleSide = "middle";
let railShow: RailShow = DEFAULT_RAIL_SHOW;
let railControlOn = false;
let unreadBanner: UnreadBannerMode = "off";
let threadMinimapArm: ThreadMinimapArm | null = null;
let transcriptView: TranscriptView = "normal";
let presentation: Presentation = "transcript";
let featureTipsOn = false;
let autoCloudOn = false;
let commandLabels = "null";
let promptCoachOn = true;
let environmentCardOn = false;
let changesPillOn = false;
/// The PICKED_KEYS values as JSON, so a change to one of them alone reaches its listeners.
let picked = "[]";
/// Whether a `display` value came (the host's, or the page's own change): until then the picks are
/// unknown, and their modules keep the page's copy.
let received = false;
let highContrastArm: keyof typeof highContrastLook.arms = "off";
/// The faces value last applied (CHAT_FONT_FACES_KEY), by its cheap key (chatFontFacesKey).
let appliedFacesKey = "";
const listeners = new Set<() => void>();

/// Sets the variables on `root` (the document's root in the page).
export function applyChatDisplay(
  root: HTMLElement,
  display: ChatDisplay,
  look: keyof typeof highContrastLook.arms = highContrastArm,
): void {
  for (const [name, value] of Object.entries(chatDisplayVariables(display))) {
    if (value === null) root.style.removeProperty(name);
    else root.style.setProperty(name, value);
  }
  for (const name of Object.keys(HIGH_CONTRAST_CHAT_VARIABLES) as HighContrastChatVariable[]) {
    if (look === "high") root.style.setProperty(name, HIGH_CONTRAST_CHAT_VARIABLES[name]);
    else root.style.removeProperty(name);
  }
  // The look's choices the stylesheet draws by selector (data-transcript-*); none for cmux. A
  // style-only root (a test's shim) has no attributes to set.
  if (typeof root.setAttribute !== "function") return;
  for (const [name, value] of Object.entries({
    ...transcriptLookAttributes(display.transcriptLook),
    ...chatPartAttributes(display),
  })) {
    if (value === null) root.removeAttribute(name);
    else root.setAttribute(name, value);
  }
}

/// The root attributes that rebind the chat's type inside the reply or the prompt
/// (conversation.css `:root[data-transcript-reply-size] .cv-md.cv-reply`, `data-transcript-prompt-*`):
/// each only while the look sets that part apart, so the cmux look sets none.
export function chatPartAttributes(display: ChatDisplay): Record<string, string | null> {
  return {
    "data-transcript-reply-size": display.replyFontSize === null ? null : "",
    "data-transcript-prompt-font": display.promptFont === null ? null : display.promptFont,
    "data-transcript-prompt-size": display.promptFontSize === null ? null : "",
  };
}

/// The host's `display` event: the page follows at once.
export function setChatDisplay(value: unknown): void {
  raw = (value && typeof value === "object" && !Array.isArray(value) ? { ...(value as Values) } : {}) as Values;
  configureStatusVerbs(raw);
  configureChatLayout(raw);
  configureThinkingLook(raw);
  configureSenderIconLook(raw);
  const readingValues = readingLookValues(raw, experimentArm(readingLook));
  const nextHighContrastArm = experimentArm(highContrastLook);
  const next = resolveChatDisplay(highContrastLookValues(readingValues, nextHighContrastArm));
  const minimap = raw[CHAT_MINIMAP_KEY] === true;
  const pinnedPlan = raw[PINNED_PLAN_KEY] === true;
  const trayTucked = raw[TRAY_TUCKED_KEY] === true;
  // The pop's gate: written only when the setting changes, so a page that set its own
  // `data-send-pop` (the gallery's variants, the benches' arms) keeps it.
  const sendPop = raw[SEND_POP_KEY] === true;
  if (sendPop !== sendPopOn) {
    sendPopOn = sendPop;
    if (typeof document !== "undefined") {
      if (sendPop) document.documentElement.setAttribute("data-send-pop", "claude");
      else document.documentElement.removeAttribute("data-send-pop");
    }
  }
  const storedBanner = raw[UNREAD_BANNER_KEY];
  const banner: UnreadBannerMode = isUnreadBannerMode(storedBanner) ? storedBanner : "off";
  const show = isRailShow(raw[RAIL_SHOW_KEY]) ? (raw[RAIL_SHOW_KEY] as RailShow) : DEFAULT_RAIL_SHOW;
  const railControl = raw[RAIL_CONTROL_KEY] === true;
  const handle = raw[TRAY_HANDLE_KEY] === "left" || raw[TRAY_HANDLE_KEY] === "right" ? raw[TRAY_HANDLE_KEY] : "middle";
  const threadMinimap = resolveThreadMinimapArm(raw);
  const stored = raw[TRANSCRIPT_VIEW_KEY];
  const view = isTranscriptView(stored) ? stored : "normal";
  const storedPresentation = raw[PRESENTATION_KEY];
  const nextPresentation = isPresentation(storedPresentation) ? storedPresentation : "transcript";
  const tips = raw[FEATURE_TIPS_KEY] === true;
  const autoCloud = raw[AUTO_CLOUD_KEY] === true;
  const labels = JSON.stringify(raw[COMMAND_LABELS_KEY] ?? null);
  const coach = raw[PROMPT_COACH_KEY] !== false;
  const environmentCard = raw[ENVIRONMENT_CARD_KEY] === true;
  const changesPill = raw[CHANGES_PILL_KEY] === true;
  const pickedNow = JSON.stringify(PICKED_KEYS.map((key) => raw[key] ?? null));
  const first = !received;
  received = true;
  const same = JSON.stringify(next) === JSON.stringify(current);
  const sameLook = nextHighContrastArm === highContrastArm;
  // A font pack's faces (chatFontFaces.ts): a new map replaces the declared faces, and once they
  // have loaded the estimate measures them (the measure stacks change), under a new look that has
  // the transcript measure every row again, as a bundled face's load does below.
  // An unchanged map (the same key; a host push brings a new object each time) applies nothing.
  const rawFaces = raw[CHAT_FONT_FACES_KEY];
  const facesKey = chatFontFacesKey(rawFaces);
  const facesChanged =
    facesKey !== appliedFacesKey &&
    applyChatFontFaces(resolveChatFontFaces(rawFaces), () => {
      current = { ...current };
      for (const listener of listeners) listener();
    });
  appliedFacesKey = facesKey;
  if (
    same &&
    !first &&
    pickedNow === picked &&
    sameLook &&
    !facesChanged &&
    minimap === minimapOn &&
    pinnedPlan === pinnedPlanOn &&
    trayTucked === trayTuckedOn &&
    handle === trayHandle &&
    show === railShow &&
    railControl === railControlOn &&
    banner === unreadBanner &&
    threadMinimap === threadMinimapArm &&
    view === transcriptView &&
    nextPresentation === presentation &&
    tips === featureTipsOn &&
    autoCloud === autoCloudOn &&
    labels === commandLabels &&
    coach === promptCoachOn &&
    environmentCard === environmentCardOn &&
    changesPill === changesPillOn
  )
    return;
  picked = pickedNow;
  commandLabels = labels;
  promptCoachOn = coach;
  environmentCardOn = environmentCard;
  changesPillOn = changesPill;
  minimapOn = minimap;
  pinnedPlanOn = pinnedPlan;
  trayTuckedOn = trayTucked;
  trayHandle = handle;
  railShow = show;
  railControlOn = railControl;
  unreadBanner = banner;
  threadMinimapArm = threadMinimap;
  transcriptView = view;
  presentation = nextPresentation;
  featureTipsOn = tips;
  autoCloudOn = autoCloud;
  if (same) {
    // The faces changed what the measure stacks name until they load.
    if (facesChanged) current = { ...current };
    highContrastArm = nextHighContrastArm;
    if (typeof document !== "undefined") applyChatDisplay(document.documentElement, current, nextHighContrastArm);
    for (const listener of listeners) listener();
    return;
  }
  current = next;
  highContrastArm = nextHighContrastArm;
  // A bundled face loads after this event: once it has, the estimate measures it (its measure
  // stack changes), and a new look (the same values) makes the transcript measure every row again,
  // offscreen ones too, as a new font does (App.tsx `measuredLook`).
  const uiFont = next.uiFont;
  loadChatUiFont(uiFont, () => {
    if (current.uiFont !== uiFont) return;
    current = { ...current };
    for (const listener of listeners) listener();
  });
  if (typeof document !== "undefined") applyChatDisplay(document.documentElement, next, nextHighContrastArm);
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
  changeChatDisplay(CHAT_UI_FONT_KEY, null);
}

/// The chat's keys the page set, as the host last sent them (the popover shows which follow the viewer).
export const chatDisplayValues = (): Readonly<Values> => raw;
export const chatDisplay = (): ChatDisplay => current;
export const currentChatMetrics = (): ChatMetrics => chatMetrics(current);
/// The chat's text scale it draws at now (`drawnFontSize`, `--cmux-chat-text-scale`); the bubble's padding follows it too.
export const chatDensityTextScale = (): number => densityTextScale;
/// The factor on every gap between the transcript's rows now: the look's density times its row
/// spacing (conversation/transcriptLook.ts gapScaleOf), 1 at cmux. model.ts places them with it.
export const transcriptGapScale = (): number => gapScaleOf(current.transcriptLook);

/// The host changed the density or Text Size (its scale script ends with `cmux-ui-scale-change`): the chat draws its text at the
/// new size, and a new look (the same values) makes the transcript measure every row again, as a new font does.
if (typeof window !== "undefined") {
  // The host can set the scale before this module runs, and a chat on the default look never writes its variables
  // (setChatDisplay returns while the look is unchanged): draw the host's size from the start.
  if (densityTextScale !== 1 && typeof document !== "undefined") applyChatDisplay(document.documentElement, current);
  window.addEventListener("cmux-ui-scale-change", () => {
    const next = readDensityTextScale();
    if (next === densityTextScale) return;
    densityTextScale = next;
    current = { ...current };
    if (typeof document !== "undefined") applyChatDisplay(document.documentElement, current);
    for (const listener of listeners) listener();
  });
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
/// Calls `listener` on every change to the chat's keys (a pick's module re-reads its value).
export const subscribeChatDisplay = subscribe;
/// A pick the host keeps (PICKED_KEYS): its value as the host last sent it or the page last set it,
/// null when the file has none (the default), undefined while no `display` value came yet.
export function pickedDisplayValue(key: (typeof PICKED_KEYS)[number]): unknown {
  if (!received) return undefined;
  return raw[key] ?? null;
}
/// Another page of this launch picked (its `storage` event): this page shows the pick at once, as the
/// host's push of it will say, without writing it again (that page's write does). `null` is the default.
export function notePickedElsewhere(key: (typeof PICKED_KEYS)[number], value: unknown): void {
  if (!received) return;
  const next = { ...raw };
  if (value === null || value === undefined) delete next[key];
  else next[key] = value;
  setChatDisplay(next);
}
/// Tests: the page starts again as a new page does, with no `display` value yet.
export function resetChatDisplayForTests(): void {
  for (const pending of unsent.values()) clearTimeout(pending);
  unsent.clear();
  displayHost = undefined;
  raw = {};
  picked = "[]";
  received = false;
}
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
const autoCloudSnapshot = () => autoCloudOn;
/// Whether `cloud.autoCloud` is on in cmux-next.json (AUTO_CLOUD_KEY): the Where menu's Auto chevron
/// and its Cloud leg (autoCloud.ts) show only with it and the plan.
export const useAutoCloudKey = (): boolean => useSyncExternalStore(subscribe, autoCloudSnapshot, autoCloudSnapshot);
/// Whether the prompt coach is on (PROMPT_COACH_KEY): the client reads it before it asks for or
/// draws a rewrite (direct.ts), and a card already drawn hides when it goes off (rows/PromptCoachRow.tsx).
export const promptCoachEnabled = (): boolean => promptCoachOn;
const promptCoachSnapshot = () => promptCoachOn;
export const usePromptCoachOn = (): boolean =>
  useSyncExternalStore(subscribe, promptCoachSnapshot, promptCoachSnapshot);
const environmentCardSnapshot = () => environmentCardOn;
/// Whether the chat draws its Environment card at its top right (ENVIRONMENT_CARD_KEY).
export const useEnvironmentCardOn = (): boolean =>
  useSyncExternalStore(subscribe, environmentCardSnapshot, environmentCardSnapshot);
const changesPillSnapshot = () => changesPillOn;
/// Whether the chat draws its changes pill over the composer (CHANGES_PILL_KEY).
export const useChangesPillOn = (): boolean =>
  useSyncExternalStore(subscribe, changesPillSnapshot, changesPillSnapshot);
const pinnedPlanSnapshot = () => pinnedPlanOn;
/// Whether the running turn's todo list is pinned in the transcript (PINNED_PLAN_KEY) instead of the hat.
export const useChatPinnedPlan = (): boolean => useSyncExternalStore(subscribe, pinnedPlanSnapshot, pinnedPlanSnapshot);
const trayTuckedSnapshot = () => trayTuckedOn;
/// Whether a sent prompt pops in, read when a row enters (VirtualTranscript.tsx): the root's gate,
/// which SEND_POP_KEY sets and a bench's arm may set by hand, as the CSS rule reads it.
export const sendPopEnabled = (): boolean => {
  const gate = typeof document === "undefined" ? null : document.documentElement.getAttribute("data-send-pop");
  return gate !== null && gate !== "none";
};
/// Whether the hat over the composer is tucked away to its pull tab (TRAY_TUCKED_KEY).
export const useTrayTucked = (): boolean => useSyncExternalStore(subscribe, trayTuckedSnapshot, trayTuckedSnapshot);
/// Tucks the hat away or brings it back, at once in the page; the host writes the setting.
export const setTrayTucked = (tucked: boolean): void => changeChatDisplay(TRAY_TUCKED_KEY, tucked || null);
const unreadBannerSnapshot = () => unreadBanner;
/// How the unread banner shows (UNREAD_BANNER_KEY): expanded, collapsed, or off.
export const useUnreadBannerMode = (): UnreadBannerMode =>
  useSyncExternalStore(subscribe, unreadBannerSnapshot, unreadBannerSnapshot);
/// Expands, collapses or turns off the unread banner, at once in the page; the host writes the
/// setting. Off, the default, removes the key.
export const setUnreadBannerMode = (mode: UnreadBannerMode): void =>
  changeChatDisplay(UNREAD_BANNER_KEY, mode === "off" ? null : mode);
const trayHandleSnapshot = () => trayHandle;
/// Where the hat's tuck chevron and pull tab sit along the composer's top edge (TRAY_HANDLE_KEY).
export const useTrayHandle = (): TrayHandleSide =>
  useSyncExternalStore(subscribe, trayHandleSnapshot, trayHandleSnapshot);
const railShowSnapshot = () => railShow;
const railControlSnapshot = () => railControlOn;
/// What the prompt rail shows (RAIL_SHOW_KEY), separate from the measured look: a change remeasures no row.
export const useRailShow = (): RailShow => useSyncExternalStore(subscribe, railShowSnapshot, railShowSnapshot);
/// Whether the prompt rail draws its head control (RAIL_CONTROL_KEY).
export const useRailControl = (): boolean => useSyncExternalStore(subscribe, railControlSnapshot, railControlSnapshot);
/// Shows `show` on every rail at once; the default removes the key.
export const setRailShow = (show: RailShow): void =>
  changeChatDisplay(RAIL_SHOW_KEY, show === DEFAULT_RAIL_SHOW ? null : show);
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
