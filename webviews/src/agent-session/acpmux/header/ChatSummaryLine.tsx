import { useT } from "../i18n";

/** A chat's rolling summary as the daemon keeps it (acpmux `rollingSummary`, hub/rolling_summary.rs). */
export type ChatSummary = { text: string; next?: string | null };

/**
 * Where the chat stands and its next action, one quiet line beside the chat's name in the header
 * ("Tests pass → Open the PR"). The daemon writes it after each turn a person started, from the
 * agent's own wrap-up when it made one, else from one small-model call (David Beyer, 2026-11-20:
 * rolling summaries of every chat with a next action for each). One phrase, cut once to the room it has, and dropped whole when the room is under ~12 characters (Leo, 2026-11-23: no
 * line cut off twice); the whole text is its tooltip. It sits in the header's own row only: the tab row's tools slot measures what it holds
 * for the native strip (header/tabRow.ts), and a line in it widens the tools until the pane drops them to a second row.
 */
export function ChatSummaryLine({ summary }: { summary?: ChatSummary | null }) {
  const t = useT();
  const text = summary?.text?.trim();
  if (!text) return null;
  const next = summary?.next?.trim() || undefined;
  const full = next ? `${text}\n${t("header.summaryNext", { next })}` : text;
  return (
    <span
      className="acpmux-chat-summary"
      /* tooltip-allow: the summary's whole text, cut to one line here */ title={full}
      aria-label={full}
      data-chat-summary=""
    >
      <span className="acpmux-chat-summary__text">{next ? `${text} → ${next}` : text}</span>
    </span>
  );
}
