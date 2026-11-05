import { useContext, useId, useLayoutEffect, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { useT } from "../i18n";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { groupSender, MessageGroupHead } from "./MessageGroupHead";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { FindReveal } from "./chatFind";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { messageRunSummary } from "./messageRuns";
import { NoticeMark } from "./NoticeMark";
import { useFold } from "./fold";
import { foldPlays } from "./transcriptView";
import type { NoticeSeverity } from "./agentNotice";
import "./LaneNoticeBatch.css";

const ROW_ICON = rowIconSize(12);

/// A received message waits for the agent (in the waiting group, PendingMessagesCard.tsx).
const isWaiting = (row: AcpmuxRow) => row.kind === "queuedMessage" || row.steer === "waiting";

/// A sender's short name for the row's hover: its name after the last `/` ("gcp-agent-lane-1/ux-owner"
/// reads "ux-owner").
const senderShortName = (name: string) => (name.split("/").at(-1) ?? "").trim();

/// The strongest severity among a fold's tools' notices (agentNotice.ts) that its head shows: a fire
/// whenever one is in it, else, when every member is a notice, the strongest of theirs; undefined
/// for a fold whose head keeps the sender's mark. Also whether every member is a notice.
export function foldSeverity(rows: readonly AcpmuxRow[]): { severity?: NoticeSeverity; allNotices: boolean } {
  const severities = rows.map((row) =>
    row.incoming?.kind === "message" ? row.incoming.message.notice?.severity : undefined,
  );
  const allNotices = severities.length > 0 && severities.every(Boolean);
  if (severities.includes("fire")) return { severity: "fire", allNotices };
  if (!allNotices) return { allNotices };
  return { severity: severities.includes("warn") ? "warn" : "info", allNotices };
}

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
  // The messages open and close with the transcript's fold (fold.ts), as a tool group's steps do; at
  // the very bottom the text above glides up with it (App.tsx `beginBottomStackFold`). Leo,
  // 2026-11-04: "how come there aren't animatiosn for expanding/collapsing tool calls anymore???"
  const fold = useFold(open, foldPlays);
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
  // Tools' notices alone read "Received N notices"; mixed with messages, they count as messages.
  const folded = foldSeverity(batch.rows);
  // A report batch whose every report gave a verdict is a batch of reviews.
  const reviews =
    batch.kind === "report" &&
    Object.values(batch.verdicts).reduce((n, count) => n + (count ?? 0), 0) === batch.rows.length;
  const count =
    received && folded.allNotices
      ? batch.rows.length === 1
        ? t("notice.received.one")
        : t("notice.received.other", { n: batch.rows.length })
      : received
        ? messageRunSummary(t, { sent: 0, received: batch.rows.length, work: [], failed: 0, running: false, rows: [] })
        : batch.kind === "report"
          ? t(reviews ? "message.reviewsEnded" : "message.reportsEnded", { n: batch.rows.length })
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
          mark={folded.severity && <NoticeMark severity={folded.severity} />}
        />
      ) : (
        // Reports and reviews: their kind's glyph in the icon column, and the one trailing chevron
        // (cmux#28749 drew a disclosure chevron there too, two chevrons on one line).
        <TranscriptActivityRow
          icon={<Icon name={reviews ? "action.review" : "agent.chat"} size={ROW_ICON} row />}
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
      {fold.present && (
        <div
          ref={fold.ref}
          className="cv-fold cv-lane-batch__body"
          id={bodyId}
          aria-hidden={open ? undefined : true}
          inert={open ? undefined : true}
        >
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
