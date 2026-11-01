// The messages other sessions sent that the agent has not read yet, as one collapsed group at the
// transcript's end (pendingMessages.ts). Closed, it is one line: a chevron, how many messages from
// how many sessions, and the senders, muted and cut to the line. Opened, its messages sit under it
// grouped by sender: the sender's mark and name (a click opens its chat), then each of its messages
// as its own received line, whole when opened, with its actions. Whether the group is open lasts
// while the page does (incomingOpened.ts), so it survives the virtualized list and new arrivals,
// and the row estimator reads it; Find opens it for a match in one of its messages. It opens at
// once, never fading in.
import { useContext, useId, useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { FindReveal } from "./chatFind";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { bySender } from "./pendingMessages";
import { SenderName } from "./IncomingMessageCard";
import "./PendingMessagesCard.css";

const ROW_ICON = rowIconSize(12);

export function PendingMessagesCard({
  row,
  onOpen,
  renderMessage,
}: {
  row: AcpmuxRow;
  /// Opens a sender's chat by its acpmux id.
  onOpen(sessionId: string): void;
  /// Draws one of the group's messages as its own row draws it alone.
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
  const rows = row.pendingMessages?.rows;
  const displayRows = row.pendingMessages?.displayRows ?? rows;
  const flat = row.pendingMessages?.flat === true;
  const senders = useMemo(
    () => (flat ? [{ key: "flat", rows: [...(displayRows ?? [])] }] : bySender(displayRows ?? [])),
    [displayRows, flat],
  );
  const sources = useMemo(() => bySender(rows ?? []), [rows]);
  const reveal = useContext(FindReveal);
  // Find names the group's row for a match in one of its messages: the group opens, and only the
  // message holding the match (`matchRowId`) is asked as its own row would be, so it opens too.
  const holdsMatch = Boolean(reveal && reveal.rowId === row.id);
  useLayoutEffect(() => {
    if (!holdsMatch || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [holdsMatch, reveal]);
  if (!rows?.length) return null;
  const n = displayRows?.length ?? rows.length;
  const countSources = flat ? bySender(displayRows ?? []) : sources;
  const names = countSources.map((group) => {
    const first = group.rows[0]!;
    return first.incoming?.kind === "message" ? first.incoming.message.name : "";
  });
  const count =
    countSources.length === 1
      ? t("message.waitingFromOne", { n })
      : t("message.waitingFrom", { n, sessions: countSources.length });
  return (
    <div className="cv-pending" data-open={open || undefined}>
      {/* Find counts the messages' words, not the head's names. */}
      <div className="cv-pending__line" data-find-skip="">
        <button
          type="button"
          className="cv-pending__toggle"
          aria-expanded={open}
          aria-controls={open ? bodyId : undefined}
          title={names.join(", ")}
          onClick={() => show(!open)}
        >
          <span className="cv-pending__icon">
            <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </span>
          <span className="cv-pending__count">{count}</span>
          <span className="cv-pending__senders">{names.join(", ")}</span>
        </button>
      </div>
      {open && (
        <div id={bodyId} className="cv-pending__body">
          {senders.map((group) => {
            const first = group.rows[0]!;
            const message = first.incoming?.kind === "message" ? first.incoming.message : undefined;
            return (
              <section key={group.key} className={!flat && message ? "cv-pending__sender" : undefined}>
                {!flat && message && (
                  <div className="cv-pending__sender-head" data-find-skip="">
                    <SenderName message={message} onOpen={onOpen} />
                    {group.rows.length > 1 && <span className="cv-pending__sender-count">{group.rows.length}</span>}
                  </div>
                )}
                {group.rows.map((member) => (
                  // Each message is its own Find row: its matches are counted in it, and only the one
                  // holding the current match opens.
                  <div key={member.id} data-row-id={member.id} data-find-member="">
                    <FindReveal.Provider
                      value={
                        holdsMatch &&
                        reveal &&
                        (reveal.matchRowId === member.id || member.joined?.includes(reveal.matchRowId ?? ""))
                          ? { ...reveal, rowId: member.id }
                          : undefined
                      }
                    >
                      {renderMessage(member)}
                    </FindReveal.Provider>
                  </div>
                ))}
              </section>
            );
          })}
        </div>
      )}
    </div>
  );
}
