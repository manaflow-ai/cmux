import { useContext, useId, useLayoutEffect, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { useT } from "../i18n";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { groupSender, MessageGroupHead } from "./MessageGroupHead";
import { Icon } from "../icons/Icon";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { FindReveal } from "./chatFind";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { messageRunSummary } from "./messageRuns";
import "./LaneNoticeBatch.css";

/// A received message waits for the agent (in the waiting group, PendingMessagesCard.tsx).
const isWaiting = (row: AcpmuxRow) => row.kind === "queuedMessage" || row.steer === "waiting";

/// A sender's short name for the row's hover: its name after the last `/` ("gcp-agent-lane-1/ux-owner"
/// reads "ux-owner").
const senderShortName = (name: string) => (name.split("/").at(-1) ?? "").trim();

/// Reports that arrived together keep their own message controls behind one disclosure.
export function LaneNoticeBatch({ row, renderMessage }: { row: AcpmuxRow; renderMessage(row: AcpmuxRow): ReactNode }) {
  const t = useT();
  const session = useContext(PromptMarksSession);
  const [open, setOpen] = useState(() => messageOpened(session, row.id));
  const show = (next: boolean) => {
    setMessageOpened(session, row.id, next);
    setOpen(next);
  };
  const bodyId = useId();
  const reveal = useContext(FindReveal);
  const match = reveal && (reveal.rowId === row.id || row.joined?.includes(reveal.matchRowId ?? reveal.rowId));
  useLayoutEffect(() => {
    if (!match || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- Find opens only its target batch.
  }, [match, reveal]);
  const batch = row.laneNoticeBatch;
  if (!batch) return null;
  const verdicts = Object.entries(batch.verdicts)
    .map(([verdict, n]) => `${n} ${verdict}`)
    .join(", ");
  const names = [...new Set(batch.threads.map(({ sender }) => sender).filter(Boolean))].join(", ");
  // Delivered messages read "Received N messages", N the messages, with no session names at rest:
  // the senders' short names are its hover (Leo, 2026-11-02: "can't we simply just display most of
  // these as recieved x messages and all of them get revealed then we can expand the messages").
  const received = batch.kind === "inbox" && !batch.rows.some(isWaiting);
  const count = received
    ? messageRunSummary(t, { sent: 0, received: batch.rows.length, work: [], failed: 0, running: false, rows: [] })
    : batch.kind === "report"
      ? t(
          Object.values(batch.verdicts).reduce((n, count) => n + (count ?? 0), 0) === batch.rows.length
            ? "message.reviewsEnded"
            : "message.reportsEnded",
          { n: batch.rows.length },
        )
      : t("message.inboxThreads", { n: batch.threads.length || batch.rows.length });
  const detail = batch.kind === "report" ? verdicts : names && t("message.inboxFrom", { names });
  const shortNames = received
    ? [...new Set(batch.threads.map(({ sender }) => senderShortName(sender)).filter(Boolean))].join(", ")
    : "";
  return (
    <div className="cv-lane-batch" data-kind={batch.kind} data-open={open || undefined}>
      {batch.kind === "inbox" ? (
        // Delivered messages from other sessions: a sibling of the tool rows (MessageGroupHead.tsx).
        <MessageGroupHead
          sender={groupSender(
            batch.rows.map((member) => (member.incoming?.kind === "message" ? member.incoming.message : undefined)),
          )}
          count={count}
          senders={received ? undefined : names}
          hint={received ? shortNames : undefined}
          open={open}
          bodyId={bodyId}
          onToggle={() => show(!open)}
          className="cv-lane-batch__toggle"
          ariaLabel={[count, received ? shortNames : detail].filter(Boolean).join(". ")}
        />
      ) : (
        <TranscriptActivityRow
          icon={<Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />}
          before={count}
          after={batch.kind === "report" && detail ? ` · ${detail}` : undefined}
          className="cv-lane-batch__toggle"
          ariaLabel={[count, detail].filter(Boolean).join(". ")}
          expanded={open}
          attributes={{
            "aria-expanded": String(open),
            "aria-controls": open ? bodyId : undefined,
            "data-find-skip": "",
          }}
          onClick={() => show(!open)}
        />
      )}
      {open && (
        <div className="cv-lane-batch__body" id={bodyId}>
          {batch.rows.map((member) => (
            <div key={member.id} data-row-id={member.id} data-find-member="">
              <FindReveal.Provider
                value={
                  match && (reveal?.matchRowId ?? reveal?.rowId) === member.id
                    ? { ...reveal!, rowId: member.id }
                    : undefined
                }
              >
                {renderMessage(member)}
              </FindReveal.Provider>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
