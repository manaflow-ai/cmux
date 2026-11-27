// The Inbox's Reports tab (ReportsBasketView, Row, Detail): agent reports that wake no model, read
// from the acpmux mailbox by the daemon, with a direct reply to the sending session. A reply never
// changes the report; one that was not sent keeps its draft, and sent again keeps its id.
import { memo } from "react";
import { sameJson } from "../../agent-session/acpmux/sameJson";
import { Button } from "../../ui/Button";
import { cx } from "../../ui/cx";
import { rowActions, type FeedProps } from "./context";
import { FeedIcon } from "./icons";
import { longDateTime, shortTime } from "./model";
import type { FeedReport } from "./types";

export function ReportsView({ store, snap, strings }: FeedProps) {
  const { t } = strings;
  const report = snap.reports.find((r) => r.id === snap.reportSelection);
  return (
    <div className="feed-reports">
      <div className="feed-reports-column">
        <div className="feed-reports-header">
          <span className="feed-reports-title">{t("reports.title")}</span>
          <span className="feed-reports-subtitle">{t("reports.subtitle")}</span>
        </div>
        {!snap.reportsLoaded ? (
          <div className="feed-reports-list" />
        ) : snap.reports.length === 0 ? (
          <div className="feed-reports-empty">
            <FeedIcon name="inbox.empty" size={20} />
            <span className="feed-reports-empty-title">{t("reports.empty")}</span>
            <span className="feed-reports-empty-hint">{t("reports.emptyHint")}</span>
          </div>
        ) : (
          <div className="feed-reports-list">
            {snap.reports.map((item) => (
              <ReportRow
                key={item.id}
                report={item}
                selected={item.id === snap.reportSelection}
                language={strings.language}
                onSelect={rowActions(store).selectReport}
              />
            ))}
          </div>
        )}
      </div>
      <div className="feed-reports-side">
        {report ? (
          <ReportDetail store={store} snap={snap} strings={strings} report={report} />
        ) : (
          <div className="feed-reports-pick">{snap.reportsLoaded ? t("reports.select") : ""}</div>
        )}
      </div>
    </div>
  );
}

interface ReportRowProps {
  report: FeedReport;
  selected: boolean;
  language: string;
  /** Called with the report's id: the same function for every row. */
  onSelect: (id: string) => void;
}

/** One report: memo, its report compared by content (each read of the basket sends every report
 * again), so a selection renders the two rows whose state flipped and a new report renders no other. */
const ReportRow = memo(
  function ReportRow({ report, selected, language, onSelect }: ReportRowProps) {
    return (
      <button
        type="button"
        className={cx("feed-report-row", selected && "selected")}
        aria-pressed={selected}
        aria-label={report.sender}
        onClick={() => onSelect(report.id)}
      >
        <FeedIcon name="agent.chat" size={14} />
        <span className="feed-report-text">
          <span className="feed-report-top">
            <span className="feed-report-sender">{report.sender}</span>
            <time className="feed-report-time feed-num">{shortTime(report.created_at, language)}</time>
          </span>
          <span className="feed-report-body">{report.body}</span>
        </span>
      </button>
    );
  },
  (a, b) =>
    a.selected === b.selected && a.language === b.language && a.onSelect === b.onSelect && sameJson(a.report, b.report),
);

function ReportDetail({ store, snap, strings, report }: FeedProps & { report: FeedReport }) {
  const { t, format, language } = strings;
  const sending = snap.reportSending.has(report.id);
  const canSend = !sending && snap.reportDraft.trim() !== "";
  return (
    <div className="feed-report-detail">
      <div className="feed-report-detail-header">
        <span className="feed-report-detail-title">{report.sender}</span>
        <span className="feed-report-detail-from">
          {format("reports.from", report.sender, longDateTime(report.created_at, language))}
        </span>
      </div>
      <div className="feed-report-detail-body">
        <p className="feed-report-detail-text">{report.body || t("reports.emptyBody")}</p>
      </div>
      {snap.reportNotSent === report.id ? (
        <p className="feed-report-not-sent" role="alert">
          {/* retry-prompt-ok: "Try again" means sending the person's reply again, their call */}
          {t("reports.notSent")}
        </p>
      ) : null}
      <div className="feed-report-reply">
        <textarea
          className="feed-field feed-report-field"
          rows={1}
          value={snap.reportDraft}
          placeholder={t("reports.replyPlaceholder")}
          aria-label={t("reports.replyPlaceholder")}
          onChange={(event) => store.setReportDraft(event.target.value)}
        />
        <Button size="sm" variant="solid" disabled={!canSend} onClick={() => void store.sendReportReply()}>
          {t("reports.reply")}
        </Button>
      </div>
    </div>
  );
}
