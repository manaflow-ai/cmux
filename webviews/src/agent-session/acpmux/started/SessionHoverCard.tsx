// The hover card of a session reference (a name chip or session id in a reply), as a row of Claude
// Code desktop's PR list reads: the title, then the status line (the status's glyph and word in its
// colour, then `· repo #N`; StartedSessionCard.tsx `SessionStatusLine`), then what it is doing now
// (its turn's step, what it waits on you for, else its latest reply's line, two lines at most),
// then the meta line (its folder and branch, then when it last changed, muted), as Claude desktop's
// session card ends (Leo, 2026-10-20; 2026-11-05: "the metadata.... ehh.."). A running
// session's status draws the pane's working spinner bare (Leo, 2026-10-19). The card's left edge
// meets the chip's, 6px off it: below the chip, or above it when more of the reply runs under the
// chip, so it never covers the next line (``hoverCardSide``). It waits for a short rest of the
// pointer, shows at once for keyboard focus (ArrowDown moves into it, Escape leaves it), and a
// click on it opens the session. Every reference to one of the reader's listed chats has it (a
// started chat's name chip, an agent link, a session name, a message sender's name); a chat the
// session list does not have (another person's, an unlisted one) shows no card.
import { type FocusEvent } from "react";
import { type SessionHoverInfo } from "./sessionHover";
import { SessionStatusLine } from "./SessionStatusLine";
import { usePaneLanguage, useT } from "../i18n";
import { relativeTime } from "../conversation/relativeTime";
import { waitingLine } from "../subagents/subsessions";
import "./sessionHover.css";

/// The card's content: the whole card is one button that opens the session.
export function SessionHoverContent({
  info,
  buttonRef,
  onOpen,
  onEscape,
  onBlur,
  onFocus,
}: {
  info: SessionHoverInfo;
  buttonRef?: { current: HTMLButtonElement | null };
  onOpen(): void;
  onEscape?(): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  onFocus?(): void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const now = info.waiting ? waitingLine(t, info.waiting) : (info.doing ?? info.preview);
  // The card reads the time when it opens: a card shows for seconds, so it never ticks.
  const changed = info.changedAt
    ? t("prCard.updated", { ago: relativeTime(info.changedAt, Date.now(), language) })
    : undefined;
  const meta = [...(info.meta ?? []), ...(changed ? [changed] : [])];
  return (
    <button
      ref={(element) => {
        if (buttonRef) buttonRef.current = element;
      }}
      type="button"
      className="acpmux-session-hover"
      onClick={onOpen}
      onBlur={onBlur}
      onFocus={onFocus}
      // ui-allow: Escape hands focus back to the reference the card belongs to.
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !onEscape) return;
        event.stopPropagation();
        onEscape();
      }}
    >
      <span className="acpmux-session-hover-title">{info.title}</span>
      <SessionStatusLine status={info.status} pullRequests={info.pullRequests} />
      {now && (
        <span
          className="acpmux-session-hover-now"
          data-kind={info.waiting ? "waiting" : info.doing ? "doing" : "reply"}
        >
          {now}
        </span>
      )}
      {meta.length > 0 && <span className="acpmux-session-hover-meta">{meta.join(" · ")}</span>}
    </button>
  );
}
