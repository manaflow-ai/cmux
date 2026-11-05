import type { HeaderQuickTool } from "./headerQuickTools";
import { HEADER_ACTIONS } from "./headerActions";

/// Which of the chat header's top-right icons show (Debug Settings `agentChat.headerIcons.contextual`,
/// pushed with the header state; the top-right thunderdome's contextual direction, 2026-11-05).
///
/// - `standard`: today's row, unchanged (the default).
/// - `contextual`: an icon shows only while it is relevant to this chat; the rest wait in "..." (and keep
///   their shortcuts). A new chat's row is the panel toggle and "..." alone.
/// - `contextualPeek`: the same calm row at rest; the icons that are not relevant fade in at the row's
///   leading end while the pointer is over the tools or focus is in them, so nothing at rest moves.
///
/// Relevance, one rule per icon:
/// - Changes: the chat has edited files, or its diff is open (already so in `standard`).
/// - Preview: the chat named a local page, or its page is open (already so in `standard`).
/// - Terminal: its terminal beside the chat is open (the button is then the way to close it).
/// - Browser: the chat named a local page (the globe opens it), or its browser beside the chat is open.
/// - Split Down, Files, [+] New tab: always, since a person added them to the row on purpose.
/// - Needs You: one or more open asks (the App passes `inboxRelevant`).
/// - The panel toggle, the worktree pill, the pull request chip and "..." are not quick actions: the
///   toggle and "..." always show, the pill and chip already show only while there is one.
export type HeaderIconsStyle = "standard" | "contextual" | "contextualPeek";

const STYLES: readonly HeaderIconsStyle[] = ["standard", "contextual", "contextualPeek"];

/// The wire value as a style, or undefined (the header state keeps the one it has).
export function readHeaderIconsStyle(value: unknown): HeaderIconsStyle | undefined {
  return STYLES.includes(value as HeaderIconsStyle) ? (value as HeaderIconsStyle) : undefined;
}

export interface HeaderRelevanceInput {
  style: HeaderIconsStyle;
  tools: readonly HeaderQuickTool[];
  lit: readonly string[];
  previewUrl?: string;
}

export interface HeaderRelevance {
  /// The buttons drawn at rest, in their order.
  shown: HeaderQuickTool[];
  /// The buttons that are not relevant now: in "..." (`contextual`) or drawn hidden until the pointer
  /// reaches the tools (`contextualPeek`). Empty in `standard`.
  dormant: HeaderQuickTool[];
}

/// Whether `tool` is relevant to the chat now (see ``HeaderIconsStyle``).
export function isRelevant(tool: HeaderQuickTool, input: Omit<HeaderRelevanceInput, "tools" | "style">): boolean {
  const open = (action: string) => input.lit.includes(action);
  switch (tool.id) {
    case "terminal":
      return open(HEADER_ACTIONS.terminal);
    case "browser":
      return open(HEADER_ACTIONS.browser) || input.previewUrl !== undefined || open(HEADER_ACTIONS.preview);
    // Changes and Preview are only in the list while they apply (headerQuickTools.ts).
    case "changes":
    case "preview":
    // Added to the row by the person: their choice stands.
    case "splitDown":
    case "files":
    case "newTab":
      return true;
  }
}

/// The header's quick tools split into the ones drawn at rest and the dormant ones.
export function headerRelevance(input: HeaderRelevanceInput): HeaderRelevance {
  if (input.style === "standard") return { shown: [...input.tools], dormant: [] };
  const shown: HeaderQuickTool[] = [];
  const dormant: HeaderQuickTool[] = [];
  for (const tool of input.tools) (isRelevant(tool, input) ? shown : dormant).push(tool);
  return { shown, dormant };
}
