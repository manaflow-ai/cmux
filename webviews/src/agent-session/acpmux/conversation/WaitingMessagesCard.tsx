// Several other sessions' messages that wait for the agent, as one card (waitingMessages.ts; Leo,
// 2026-10-27: "i also feel like there should be better batching for messages from other sessions
// so you can get to things faster/more efficiently"). Its head is one line in the received line's
// place: a chevron, how many messages from how many sessions, the senders cut with an ellipsis, and
// the quiet delivery note ("Read after this step" or "Read after this turn") at the end. A click
// on the line opens it; open, each message is its received card under it, oldest first, with its
// own actions (Send now, or the queued card's Steer, Edit message, Move, Delete). Whether it is open
// lasts while the page does (incomingOpened.ts), so it survives the virtualized list, and the row
// estimator reads it; Find opens it for a match in one of its messages. It never animates in.
import { useContext, useId, useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { FindReveal } from "./chatFind";
import { ChevronRight } from "./icons";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import "./WaitingMessagesCard.css";

/// The senders of `rows`, each once, in the order they first wrote.
export function waitingSenders(rows: readonly AcpmuxRow[]): string[] {
  const names: string[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.incoming?.kind !== "message") continue;
    const { name, sessionId } = row.incoming.message;
    const key = sessionId ?? name;
    if (seen.has(key)) continue;
    seen.add(key);
    names.push(name);
  }
  return names;
}

export function WaitingMessagesCard({
  row,
  renderMessage,
}: {
  row: AcpmuxRow;
  /// Draws one of the card's messages as its own row draws it alone.
  renderMessage(message: AcpmuxRow): ReactNode;
}) {
  const t = useT();
  const session = useContext(PromptMarksSession);
  const [open, setOpen] = useState(() => messageOpened(session, row.id));
  const show = (next: boolean) => {
    setMessageOpened(session, row.id, next);
    setOpen(next);
  };
  const bodyId = useId();
  const waiting = row.waiting;
  const reveal = useContext(FindReveal);
  // Find names the card's row for a match in one of its messages (chatFind.ts `findRowIndex`), and
  // that message (`member`), which it opens in turn as that message's own row would.
  const holdsMatch = Boolean(reveal && reveal.rowId === row.id);
  const memberReveal = useMemo(
    () => (reveal?.member && reveal.rowId === row.id ? { ...reveal, rowId: reveal.member } : undefined),
    [reveal, row.id],
  );
  useLayoutEffect(() => {
    if (!holdsMatch || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [holdsMatch, reveal]);
  if (!waiting) return null;
  const senders = waitingSenders(waiting.rows);
  const n = waiting.rows.length;
  const count =
    senders.length === 1
      ? t("message.waitingFromOne", { n })
      : t("message.waitingFrom", { n, sessions: senders.length });
  const isChat = waiting.delivery === "chat";
  return (
    <div className="cv-waiting" data-open={open || undefined} data-delivery={waiting.delivery}>
      {/* Find counts the messages' text, not the head's names. */}
      <div className="cv-received__line cv-waiting__line" data-find-skip="">
        <button
          type="button"
          className="cv-received__toggle cv-waiting__toggle"
          aria-expanded={open}
          aria-controls={bodyId}
          title={senders.join(", ")}
          onClick={() => show(!open)}
        >
          <span className="cv-waiting__icon">
            <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
          </span>
          <span className="cv-waiting__count">{count}</span>
          <span className="cv-waiting__senders">
            {senders.map((name, index) => (
              <span key={`${index}:${name}`} className="cv-waiting__sender">
                {name}
              </span>
            ))}
          </span>
        </button>
        {!isChat && (
          <span className="cv-received__queued">
            {t(waiting.delivery === "step" ? "message.readAfterStep" : "message.readAfterTurn")}
          </span>
        )}
      </div>
      <div id={bodyId} className="cv-waiting__messages" hidden={!open}>
        {open &&
          waiting.rows.map((message) => (
            <div key={message.id} data-find-member={message.id}>
              <FindReveal.Provider value={memberReveal?.rowId === message.id ? memberReveal : reveal}>
                {renderMessage(message)}
              </FindReveal.Provider>
            </div>
          ))}
      </div>
    </div>
  );
}
