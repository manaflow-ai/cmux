// The selection bar's Ask in side chat (#40948, SelectionReply.tsx): `/side <prompt>`'s path with
// the selection quoted as its prompt. It forks the chat as it is now (live while a turn runs), not
// the row the text sits in, so it is offered on every selection: the right-click menu's Open in
// Side Chat shows only on a row of a finished turn the chat can fork from (messageMenu.ts
// `messageMenuTarget`). Where no side chat can open, it says why instead of doing nothing.
import { sideChatRefusal, type SideChatPlace } from "../header/sideChatRow";
import { type Translate } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import { CmuxCommandRefused } from "../cmuxCommands";
import { errorMessage } from "../transportErrors";
import { forkToTarget } from "./messageMenu";
import { quoteMarkdown } from "./selectionReplyModel";

export type SelectionSideChatHost = {
  /** The page's `chat.side` (App.tsx), which forks, opens the split and sends the prompt. */
  side: (params: Record<string, unknown>) => Promise<unknown>;
  /** A transient notice in the pane. */
  notice: (text: string) => void;
  t: Translate;
};

/// Asks `text` in a new side chat of `chat`; false when it said why none can open.
export function askSelectionInSideChat(
  text: string,
  chat: AcpmuxSnapshot,
  place: SideChatPlace | undefined,
  host: SelectionSideChatHost,
): boolean {
  const { t, notice } = host;
  if (!chat.sessionId || place === undefined) {
    notice(t("composer.cmuxSideUnavailable"));
    return false;
  }
  const refusal = sideChatRefusal(chat, place);
  const target = forkToTarget(chat);
  if (refusal !== undefined || !target) {
    notice(t(refusal === "unavailable" ? "composer.cmuxForkBusy" : "notice.forkNothingYet"));
    return false;
  }
  const prompt = quoteMarkdown(text) + t("message.selectionAskPrompt");
  host.side({ ...target, splitRight: true, prompt }).catch((error: unknown) => {
    // The side chat opened but its prompt was not sent: that refusal says so itself.
    if (error instanceof CmuxCommandRefused) return notice(error.message);
    const reason = errorMessage(error);
    notice(reason ? t("notice.forkFailedReason", { reason }) : t("notice.forkFailed"));
  });
  return true;
}
