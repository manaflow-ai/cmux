import React, { type ReactNode } from "react";
import { openProcessTerminal } from "../processTerminal";
import { Counts } from "../changes/Counts";
import { changedByTools } from "../changes/turnCheckpoint";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { TurnFile } from "../diff";
import type { SessionSummary, SummaryBackgroundTask } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";
import { SummarySection } from "./SummarySection";

const ROW_ICON = rowIconSize(12);

/// The chat's summary, a section per kind of thing it produced. Outputs, Subagents and Sources
/// always show, in the Codex app's order, with "None" while empty; pull requests, background
/// tasks and wakeups follow when there are any.
/// Pull requests and sources are links, so they open, copy and open in a new tab as links do;
/// an output opens the changes view at that file. A file the last turn changed is listed under
/// Changes only. Following a link calls `onFollow`. A chat
/// with images or renders offers its gallery under Outputs (GalleryDialog.tsx). A chat whose
/// subagents acpmux reports lists them with their live state (SubagentStatusList.tsx) in the
/// Subagents place. The summary card (SummaryCard.tsx) draws it.
const TASK_STATES: Record<SummaryBackgroundTask["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
};

/// The last turn that edited files: its files as its diff shows them (the checkpoint's once
/// loaded) and their totals.
export type SummaryChanges = {
  additions: number;
  deletions: number;
  files?: readonly Pick<TurnFile, "path" | "displayPath" | "additions" | "deletions" | "created">[];
};

export function SummaryBody({
  summary,
  galleryCount = 0,
  changes,
  onOpenChanges,
  onOpenOutput,
  onOpenGallery,
  onFollow,
  onAttach,
  subagents,
}: {
  summary: SessionSummary;
  galleryCount?: number;
  changes?: SummaryChanges;
  /// The turn's diff; at `path`, that file's.
  onOpenChanges?: (path?: string) => void;
  onOpenOutput?: (path: string) => void;
  onOpenGallery?: () => void;
  onFollow?: () => void;
  /// Sources' +: files or folders on this computer for the next prompt (a local chat's).
  onAttach?: () => void;
  /// The Subagents section, when acpmux reports the chat's subagents.
  subagents?: ReactNode;
}) {
  const t = useT();
  // A file the last turn changed shows once, under Changes (as in Codex); Outputs keeps the rest.
  // A loaded checkpoint lists them under the repository root, outputs as the agent wrote them.
  const changed = changes?.files ?? [];
  const outputs =
    changed.length > 0
      ? summary.outputs.filter((output) => !changed.some((file) => changedByTools(file, [output])))
      : summary.outputs;
  return (
    <>
      <SummarySection
        title={t("summary.outputs")}
        fixed
        items={outputs}
        row={(file) => (
          <li key={file.path}>
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link"
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
      {subagents ?? (
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
      )}
      <SummarySection
        title={t("summary.sources")}
        fixed
        items={summary.sources}
        action={
          onAttach && (
            <button
              type="button"
              className="acpmux-summary-add"
              aria-label={t("summary.sources.attach")}
              title={t("summary.sources.attach")}
              onClick={onAttach}
            >
              <Icon name="action.add" size={ROW_ICON} />
            </button>
          )
        }
        row={(source) => (
          <li key={source.url ?? source.label}>
            {source.url ? (
              <a className="acpmux-summary-row acpmux-summary-link" href={source.url} onClick={onFollow}>
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
      {changes && (
        // The last turn that edited files: its totals open its diff, each of its files that file's.
        <SummarySection
          title={t("header.changes")}
          items={changes.files ?? []}
          lead={
            <li>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link"
                aria-label={t("header.changes")}
                disabled={!onOpenChanges}
                onClick={() => onOpenChanges?.()}
              >
                <Icon name="diff.file" size={ROW_ICON} row />
                <span className="acpmux-summary-text">{t("header.changes")}</span>
                <Counts additions={changes.additions} deletions={changes.deletions} />
              </button>
            </li>
          }
          row={(file) => (
            <li key={file.path}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link acpmux-summary-file"
                disabled={!onOpenChanges}
                onClick={() => onOpenChanges?.(file.path)}
              >
                <Icon name={file.created ? "file.new" : "file.text"} size={ROW_ICON} row />
                <span className="acpmux-summary-text">{file.displayPath}</span>
                <Counts additions={file.additions} deletions={file.deletions} />
              </button>
            </li>
          )}
        />
      )}
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
            >
              <Icon name="git.pullrequest" size={ROW_ICON} row />
              <span className="acpmux-summary-text">{pr.title ?? `${pr.repo}#${pr.number}`}</span>
              <span className="acpmux-summary-meta">#{pr.number}</span>
            </a>
          </li>
        )}
      />
      <SummarySection
        title={t("summary.backgroundTasks")}
        items={summary.backgroundTasks}
        row={(task) => (
          <li key={task.id}>
            {/* A click opens its terminal beside the chat (processTerminal.ts). */}
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link"
              data-state={task.state}
              title={t("bgTask.showOutput")}
              onClick={() => {
                onFollow?.();
                void openProcessTerminal(task.id);
              }}
            >
              <Icon name="terminal" size={ROW_ICON} row />
              <span className="acpmux-summary-text">{task.command}</span>
              <span className="acpmux-summary-meta">{t(TASK_STATES[task.state])}</span>
            </button>
          </li>
        )}
      />
      <SummarySection
        title={t("summary.scheduled")}
        items={summary.scheduled}
        row={(wakeup) => (
          <li key={wakeup.id} className="acpmux-summary-row">
            <Icon name="task.status.started" size={ROW_ICON} row />
            <span className="acpmux-summary-text">{wakeup.text}</span>
            {wakeup.cron && <span className="acpmux-summary-meta">{wakeup.cron}</span>}
          </li>
        )}
      />
    </>
  );
}
