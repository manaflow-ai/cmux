// The hover card of a session reference (a name chip or session id in a reply), as a row of Claude
// Code desktop's PR list reads: the title, then the status line (the status's glyph and word in its
// colour, then `· repo #N`; StartedSessionCard.tsx `SessionStatusLine`), then the meta line (its
// folder and branch, muted), as Claude desktop's session card ends (Leo, 2026-10-20). A running
// session's status draws the pane's working spinner bare (Leo, 2026-10-19). The card's left edge
// meets the chip's, 6px off it: below the chip, or above it when more of the reply runs under the
// chip, so it never covers the next line (``hoverCardSide``). It waits for a short rest of the
// pointer, shows at once for keyboard focus (ArrowDown moves into it, Escape leaves it), and a
// click on it opens the session. Behind the `started-session-cards` experiment.
import { type FocusEvent } from "react";
import { type SessionHoverInfo } from "./sessionHover";
import { SessionStatusLine } from "./SessionStatusLine";
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
      {info.meta && <span className="acpmux-session-hover-meta">{info.meta.join(" · ")}</span>}
    </button>
  );
}
