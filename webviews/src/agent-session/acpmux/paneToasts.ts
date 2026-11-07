// Where the agent pane says something back. Two routes:
//
// - `transcript`: a line in the shown chat, for what belongs to the conversation (a prompt that was
//   not sent, a resume that failed). It stays with the rows it is about.
// - `transient`: feedback on a click or an action (a sender with no chat, an action the app did not
//   run). It belongs to the moment, not the chat.
import type { NoticeQueue } from "../../ui/NoticeStack";
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
  transient(text: string): void;
  /** A sender chip whose name acpmux resolves to no chat. */
  senderMissing(name: string): void;
}

export function paneNotices(sinks: PaneNoticeSinks): PaneNotices {
  const transcript = (text: string) => void sinks.transcript()?.notice(text);
  const transient = (text: string) => transcript(text);
  return {
    transcript,
    transient,
    senderMissing: (name) => transient(translate("message.senderNotFound", { name })),
  };
}
