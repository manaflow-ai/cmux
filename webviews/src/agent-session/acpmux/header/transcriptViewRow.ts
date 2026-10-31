// The chat menu's Transcript view submenu, as Claude Code desktop's chat menu has it (Leo,
// 2026-10-29: "i like these kinds of settings from claude code desktop..."): Normal, Thinking and
// Verbose with a check on this chat's view, then "Make <view> the default", which writes the
// setting every chat without a view of its own follows (conversation/transcriptView.ts).
import type { StringKey, Translate } from "../i18n";
import {
  TRANSCRIPT_VIEWS,
  makeTranscriptViewDefault,
  setTranscriptView,
  transcriptViewOf,
  type TranscriptView,
} from "../conversation/transcriptView";
import { defaultTranscriptView } from "../chatDisplay";
import type { ChatMenuItem } from "./ChatHeaderTools";

export const TRANSCRIPT_VIEW_NAMES: Record<TranscriptView, StringKey> = {
  normal: "chatMenu.transcriptView.normal",
  thinking: "chatMenu.transcriptView.thinking",
  verbose: "chatMenu.transcriptView.verbose",
};

export function transcriptViewRow(
  sessionId: string | undefined,
  t: Translate,
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
        // The chat already shows the default.
        disabled: view === defaultTranscriptView(),
        onSelect: () => makeTranscriptViewDefault(sessionId, view),
      },
    ],
  };
}
