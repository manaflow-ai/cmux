// The Inbox's Reports tab (ReportsBasketView, Row, Detail): agent reports that wake no model, read
// from the acpmux mailbox by the daemon, with a direct reply to the sending session. A reply never
// changes the report; one that was not sent keeps its draft, and sent again keeps its id.
import { Button } from "../../ui/Button";
import { cx } from "../../ui/cx";
import type { FeedProps } from "./context";
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
                onSelect={() => store.selectReport(item.id)}
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

function ReportRow({
  report,
  selected,
  language,
  onSelect,
}: {
  report: FeedReport;
  selected: boolean;
  language: string;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      className={cx("feed-report-row", selected && "selected")}
      aria-pressed={selected}
      aria-label={report.sender}
      onClick={onSelect}
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
}

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
