import React from "react";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SessionSummary } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";
import { SummarySection } from "./SummarySection";

const ROW_ICON = rowIconSize(12);

/// The chat's summary, a section per kind of thing it produced. Outputs, Subagents and Sources
/// always show, in the Codex app's order, with "None" while empty; pull requests and wakeups
/// follow when there are any.
/// Pull requests and sources are links, so they open, copy and open in a new tab as links do;
/// an output opens the changes view at that file. Following a link calls `onFollow`. A chat
/// with images or renders offers its gallery under Outputs (GalleryDialog.tsx).
export function SummaryPopover({
  summary,
  galleryCount = 0,
  onOpenOutput,
  onOpenGallery,
  onFollow,
}: {
  summary: SessionSummary;
  galleryCount?: number;
  onOpenOutput?: (path: string) => void;
  onOpenGallery?: () => void;
  onFollow?: () => void;
}) {
  const t = useT();
  return (
    <>
      <SummarySection
        title={t("summary.outputs")}
        fixed
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
        footer={
          galleryCount > 0 &&
          onOpenGallery && (
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link acpmux-summary-gallery"
              onClick={onOpenGallery}
            >
              <Icon name="view.grid" size={ROW_ICON} row />
              <span className="acpmux-summary-text">{t("summary.gallery")}</span>{" "}
              <span className="acpmux-summary-meta">{galleryCount}</span>
            </button>
          )
        }
      />
      <section className="acpmux-summary-section" aria-label={t("summary.subagents")}>
        <h3 className="acpmux-summary-title">{t("summary.subagents")}</h3>
        <ul className="acpmux-summary-list">
          {summary.subagents.length > 0 ? (
            <SubagentStack subagents={summary.subagents} />
          ) : (
            <li className="acpmux-summary-row acpmux-summary-none">{t("summary.none")}</li>
          )}
        </ul>
      </section>
      <SummarySection
        title={t("summary.sources")}
        fixed
        items={summary.sources}
        row={(source) => (
          <li key={source.url ?? source.label}>
            {source.url ? (
              <a
                className="acpmux-summary-row acpmux-summary-link"
                href={source.url}
                title={source.url}
                onClick={onFollow}
              >
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
      <SummarySection
        title={t("summary.pullRequests")}
        items={summary.pullRequests}
        row={(pr) => (
          <li key={pr.url}>
            <a
              className="acpmux-summary-row acpmux-summary-link"
              href={pr.url}
              onClick={onFollow}
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
    </>
  );
}
