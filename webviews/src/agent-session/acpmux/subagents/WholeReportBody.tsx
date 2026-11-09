// A subagent's report in its card (wholeReport.ts): its Markdown and, when the card has only part
// of it, Show more under it, the transcript's one expand row (conversation/ExpandRow.tsx). Show more
// opens the rest in place, or, when only the subagent's own view holds it, opens that view.
import { useId } from "react";
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
      <div id={id} className={className} data-partial={report.cut || undefined}>
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
