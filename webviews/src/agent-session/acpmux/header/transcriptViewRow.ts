// The chat menu's Transcript view submenu, as Claude Code desktop's chat menu has it (Leo,
// 2026-10-29: "i like these kinds of settings from claude code desktop..."): Normal, Thinking and
// Verbose with a check on this chat's view, then "Make <view> the default", which writes the
// setting every chat without a view of its own follows (conversation/transcriptView.ts). `more` ends
// the submenu (the chat's Text & Width…): the ··· menu is already full height, so the view takes no
// row of its own and Archive and Close stay on screen.
import type { StringKey, Translate } from "../i18n";
import {
  TRANSCRIPT_VIEWS,
  hasOwnTranscriptView,
  makeTranscriptViewDefault,
  setTranscriptView,
  transcriptViewOf,
  type TranscriptView,
} from "../conversation/transcriptView";
import { defaultTranscriptView } from "../chatDisplay";
import { blockWrapOf, setBlockWrap } from "../conversation/blockWrap";
import type { ChatMenuChild, ChatMenuItem } from "./ChatHeaderTools";

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
  normal: "chatMenu.transcriptView.normal",
  thinking: "chatMenu.transcriptView.thinking",
  verbose: "chatMenu.transcriptView.verbose",
};

export function transcriptViewRow(
  sessionId: string | undefined,
  t: Translate,
  more: readonly ChatMenuChild[] = [],
): Exclude<ChatMenuItem, "separator"> | undefined {
  if (!sessionId) return undefined;
  const view = transcriptViewOf(sessionId);
  return {
    key: "transcriptView",
    label: t("chatMenu.transcriptView"),
    icon: "text.description",
    children: [
      ...TRANSCRIPT_VIEWS.map((each) => ({
        key: `transcriptView.${each}`,
        label: t(TRANSCRIPT_VIEW_NAMES[each]),
        checked: each === view,
        onSelect: () => setTranscriptView(sessionId, each),
      })),
      {
        key: "transcriptView.default",
        separatorBefore: true,
        label: t("chatMenu.transcriptView.makeDefault", { view: t(TRANSCRIPT_VIEW_NAMES[view]) }),
        // Nothing to do only when the chat follows the default with no view of its own. A view of
        // its own that equals the default stays clearable here, so later defaults reach the chat.
        disabled: view === defaultTranscriptView() && !hasOwnTranscriptView(sessionId),
        onSelect: () => makeTranscriptViewDefault(sessionId, view),
      },
      ...more.map((child, index) => (index ? child : { ...child, separatorBefore: true })),
    ],
  };
}
