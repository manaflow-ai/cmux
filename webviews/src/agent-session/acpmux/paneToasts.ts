// Where the agent pane says something back. Two routes:
//
// - `transcript`: a line in the shown chat, for what belongs to the conversation (a prompt that was
//   not sent, a resume that failed). It stays with the rows it is about.
// - `transient`: feedback on a click or an action (a sender with no chat, an action the app did not
//   run). It belongs to the moment, not the chat: a toast in the pane's stack over the transcript's
//   foot, by the composer where the person is looking (Leo, 2026-11-07: "it should have sent, like,
//   that bottom toast area"). The same text twice is one toast with a count (NoticeStack).
import { anchorMemory } from "../../ui/anchors";
import { createNoticeQueue, type NoticeQueue } from "../../ui/NoticeStack";
import { translate } from "./i18n";

/** The shown chat's notice lines (DirectClient.notice). */
export interface TranscriptNotices {
  notice(text: string): unknown;
}

export interface PaneNoticeSinks {
  /** The client of the shown chat, when there is one. */
  transcript(): TranscriptNotices | null | undefined;
  /** The pane's toast queue. */
  toasts: NoticeQueue;
}

export interface PaneNotices {
  transcript(text: string): void;
  /** `group`: the kind of toast, which a drag's anchor is remembered under. */
  transient(text: string, group?: string): void;
  /** A sender chip whose name acpmux resolves to no chat. */
  senderMissing(name: string): void;
}

/** The pane's toasts: at most three in the deck, the oldest leaving for a fourth. */
export const PANE_TOAST_LIMIT = 3;

/** Where each kind of toast was last dragged (anchors.ts), in the page's localStorage. */
export const PANE_TOAST_ANCHOR_PREFIX = "cmux.agentPane.toastAnchor.";

export function createPaneToasts(): NoticeQueue {
  return createNoticeQueue(PANE_TOAST_LIMIT, { anchors: anchorMemory(PANE_TOAST_ANCHOR_PREFIX) });
}

export function paneNotices(sinks: PaneNoticeSinks): PaneNotices {
  const transcript = (text: string) => void sinks.transcript()?.notice(text);
  const transient = (text: string, group = "feedback") => {
    if (text) sinks.toasts.show({ message: text, group });
  };
  return {
    transcript,
    transient,
    senderMissing: (name) => transient(translate("message.senderNotFound", { name }), "senderMissing"),
  };
}
