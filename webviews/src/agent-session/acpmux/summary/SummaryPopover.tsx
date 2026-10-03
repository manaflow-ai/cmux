import React from "react";
import { Counts } from "../changes/Counts";
import { t } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { isEmptySummary, type SessionSummary } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";
import { SummarySection } from "./SummarySection";

const ROW_ICON = rowIconSize(12);

/// The chat's summary, a section per kind of thing it produced. Empty sections are left out.
/// Pull requests and sources are links, so they open, copy and open in a new tab as links do;
/// an output opens the changes view at that file.
export function SummaryPopover({
  summary,
  onOpenOutput,
}: {
  summary: SessionSummary;
  onOpenOutput?: (path: string) => void;
}) {
  if (isEmptySummary(summary)) return <p className="acpmux-summary-empty">{t("summary.empty")}</p>;
  return (
    <>
      <SummarySection
        title={t("summary.scheduled")}
        items={summary.scheduled}
        row={(wakeup) => (
          <li key={wakeup.id} className="acpmux-summary-row">
            <Icon name="task.status.started" size={ROW_ICON} row />
            <span className="acpmux-summary-text" title={wakeup.text}>
              {wakeup.text}
            </span>
            {wakeup.cron && <span className="acpmux-summary-meta">{wakeup.cron}</span>}
          </li>
        )}
      />
      <SummarySection
        title={t("summary.pullRequests")}
        items={summary.pullRequests}
        row={(pr) => (
          <li key={pr.url}>
            <a
              className="acpmux-summary-row acpmux-summary-link"
              href={pr.url}
              data-state={pr.state}
              title={`${pr.repo}#${pr.number}${pr.state === "open" ? "" : ` · ${t(`summary.pr.${pr.state}`)}`}`}
            >
              <Icon name="git.pullrequest" size={ROW_ICON} row />
              <span className="acpmux-summary-text">{pr.title ?? `${pr.repo}#${pr.number}`}</span>
              <span className="acpmux-summary-meta">#{pr.number}</span>
            </a>
          </li>
        )}
      />
      <SummarySection
        title={t("summary.outputs")}
        items={summary.outputs}
        row={(file) => (
          <li key={file.path}>
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link"
              title={file.path}
              disabled={!onOpenOutput}
              onClick={() => onOpenOutput?.(file.path)}
            >
              <Icon name={file.created ? "file.new" : "file.text"} size={ROW_ICON} row />
              <span className="acpmux-summary-text">{file.displayPath}</span>
              <Counts additions={file.additions} deletions={file.deletions} />
            </button>
          </li>
        )}
      />
      {summary.subagents.length > 0 && (
        <section className="acpmux-summary-section" aria-label={t("summary.subagents")}>
          <h3 className="acpmux-summary-title">{t("summary.subagents")}</h3>
          <ul className="acpmux-summary-list">
            <SubagentStack subagents={summary.subagents} />
          </ul>
        </section>
      )}
      <SummarySection
        title={t("summary.sources")}
        items={summary.sources}
        row={(source) => (
          <li key={source.url ?? source.label}>
            {source.url ? (
              <a className="acpmux-summary-row acpmux-summary-link" href={source.url} title={source.url}>
                <Icon name="link.web" size={ROW_ICON} row />
                <span className="acpmux-summary-text">{source.label}</span>
              </a>
            ) : (
              <span className="acpmux-summary-row">
                <Icon name="search.files" size={ROW_ICON} row />
                <span className="acpmux-summary-text">{source.label}</span>
              </span>
            )}
          </li>
        )}
      />
    </>
  );
}
