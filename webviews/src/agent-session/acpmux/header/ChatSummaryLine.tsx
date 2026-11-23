import { useT } from "../i18n";

/** A chat's rolling summary as the daemon keeps it (acpmux `rollingSummary`, hub/rolling_summary.rs). */
export type ChatSummary = { text: string; next?: string | null };

/**
 * Where the chat stands and its next action, one quiet line beside the chat's name in the header
 * ("Tests pass → Open the PR"). The daemon writes it after each turn a person started, from the
 * agent's own wrap-up when it made one, else from one small-model call (David Beyer, 2026-11-20:
 * rolling summaries of every chat with a next action for each). Cut to the room it has; the whole
 * text is its tooltip. `inline`: the tab-row header, where it leads the tools instead.
 */
export function ChatSummaryLine({ summary, inline }: { summary?: ChatSummary | null; inline?: boolean }) {
  const t = useT();
  const text = summary?.text?.trim();
  if (!text) return null;
  const next = summary?.next?.trim() || undefined;
  const full = next ? `${text}\n${t("header.summaryNext", { next })}` : text;
  return (
    <span
      className={inline ? "acpmux-chat-summary acpmux-chat-summary--inline" : "acpmux-chat-summary"}
      /* tooltip-allow: the summary's whole text, cut to one line here */ title={full}
      aria-label={full}
      data-chat-summary=""
    >
      <span className="acpmux-chat-summary__text">{text}</span>
      {next && (
        <>
          <span className="acpmux-chat-summary__arrow" aria-hidden="true">
            →
          </span>
          <span className="acpmux-chat-summary__next">{next}</span>
        </>
      )}
    </span>
  );
}
