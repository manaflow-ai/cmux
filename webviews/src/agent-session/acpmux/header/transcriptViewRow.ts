// The chat menu's Transcript view submenu, as Claude Code desktop's chat menu has it (Leo,
// 2026-10-29: "i like these kinds of settings from claude code desktop..."), is the chat's detail
// ladder now (chatDetailRow.ts): Messages, Normal, Thinking, Verbose. This file keeps the submenu's
// Wrap lines and the view names.
import type { StringKey, Translate } from "../i18n";
import type { TranscriptView } from "../chatDetail";
import { CHAT_DETAIL_NAMES, chatDetailRow } from "./chatDetailRow";
import { blockWrapOf, setBlockWrap } from "../conversation/blockWrap";
import type { ChatMenuChild } from "./chatHeaderToolsModel";

/// The submenu's Wrap lines: whether every command's output wraps (blockWrap.ts "output", one
/// choice for every Shell block). Verbose opens every Shell block, so the choice lives here once
/// and each block shows its own Wrap lines only on hover or focus (conversation.css .cv-shell__wrap).
export function wrapOutputRow(t: Translate): ChatMenuChild {
  const on = blockWrapOf("output");
  return {
    key: "transcriptView.wrap",
    label: t("changes.wrapLines"),
    on,
    onSelect: () => setBlockWrap("output", !blockWrapOf("output")),
  };
}

export const TRANSCRIPT_VIEW_NAMES: Record<TranscriptView, StringKey> = {
  normal: CHAT_DETAIL_NAMES.normal,
  thinking: CHAT_DETAIL_NAMES.thinking,
  verbose: CHAT_DETAIL_NAMES.verbose,
};

/// The submenu is the chat's detail ladder now (chatDetailRow.ts); the name stays for its galleries.
export const transcriptViewRow = chatDetailRow;
