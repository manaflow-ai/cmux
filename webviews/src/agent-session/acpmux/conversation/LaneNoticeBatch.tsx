import { useContext, useId, useLayoutEffect, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { useT } from "../i18n";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { Icon } from "../icons/Icon";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { FindReveal } from "./chatFind";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import "./LaneNoticeBatch.css";

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
  const count =
    batch.kind === "report"
      ? t(
          Object.values(batch.verdicts).reduce((n, count) => n + (count ?? 0), 0) === batch.rows.length
            ? "message.reviewsEnded"
            : "message.reportsEnded",
          { n: batch.rows.length },
        )
      : t("message.inboxThreads", { n: batch.threads.length || batch.rows.length });
  const detail = batch.kind === "report" ? verdicts : names && t("message.inboxFrom", { names });
  return (
    <div className="cv-lane-batch" data-open={open || undefined}>
      <TranscriptActivityRow
        icon={<Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />}
        before={count}
        name={batch.kind === "inbox" && names ? names : undefined}
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
