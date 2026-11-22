// A subagent's report in its card (wholeReport.ts): its Markdown and, when the card has only part
// of it, Show more under it, the transcript's one expand row (conversation/ExpandRow.tsx). Show more
// opens the rest in place, or, when only the subagent's own view holds it, opens that view. A whole
// report has the card's corner Copy (CardCopy.tsx), as another agent's message does; a cut one has
// none, since it would copy part of the report (Leo, 2026-11-06, on a subagent: "I should be able
// to, like, copy the stuff that it did").
import { useId } from "react";
import { CardCopy } from "../conversation/CardCopy";
import { Markdown } from "../conversation/Markdown";
import { ExpandRow } from "../conversation/ExpandRow";
import { useT } from "../i18n";
import type { WholeReport } from "./wholeReport";

export function WholeReportBody({
  report,
  className,
  onOpenView,
}: {
  report: WholeReport;
  /// The Markdown box's classes (`cv-subagent-done__markdown selectable`).
  className: string;
  /// Opens the subagent's own view: where Show more goes when the rest is only there.
  onOpenView?: () => void;
}) {
  const t = useT();
  const id = useId();
  const more = report.cut && (!report.away || onOpenView);
  return (
    <>
      {/* Inside the Markdown's block box: its card is a flex column, where a float would not hold the corner. */}
      <div id={id} className={`cv-whole-report ${className}`} data-partial={report.cut || undefined}>
        {!report.cut && !report.loading && <CardCopy text={report.text} />}
        <Markdown commits="quiet">{report.text}</Markdown>
      </div>
      {more && (
        <ExpandRow
          className="cv-subagent-done__more-row"
          open={false}
          controls={id}
          label={t("message.more")}
          onToggle={() => (report.away ? onOpenView?.() : report.more())}
        />
      )}
    </>
  );
}
