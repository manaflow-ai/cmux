import React, { type ReactNode } from "react";
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
/// an output opens the changes view at that file. Outputs lists every file the chat changed, once
/// (hq#2569 item 4, cx-0h4xq). A file the last turn changed, by a tool or as only its checkpoint
/// knows (a shell command or formatter edited it), opens that turn's diff at the file; Changes is one row
/// that opens the last turn's diff with its totals.
/// Following a link calls `onFollow`. A chat
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
  /// The Subagents section, when acpmux reports the chat's subagents.
  subagents?: ReactNode;
}) {
  const t = useT();
  // A loaded checkpoint lists its files under the repository root, outputs as the agent wrote them.
  // A file the last turn changed opens that turn's diff, also when an earlier turn's edit tool made
  // it an output: its last change is the one to show.
  const lastTurn = changes?.files ?? [];
  const named = new Set(summary.outputs.map((output) => output.path));
  // The output a last-turn file is: the one with its path, else (a checkpoint file, under the repository
  // root) the shortest output path ending in its path, so `index.ts` in one folder never takes another
  // folder's `index.ts`, nor a root `package.json` a package's.
  const outputOf = (file: (typeof lastTurn)[number]) =>
    named.has(file.path)
      ? file.path
      : summary.outputs
          .filter((output) => changedByTools(file, [output]))
          .reduce<string | undefined>(
            (best, output) => (!best || output.path.length < best.length ? output.path : best),
            undefined,
          );
  const turnOf = new Map<string, (typeof lastTurn)[number]>();
  const checkpointOnly: (typeof lastTurn)[number][] = [];
  for (const file of lastTurn) {
    const output = outputOf(file);
    if (output === undefined) checkpointOnly.push(file);
    else if (!turnOf.has(output)) turnOf.set(output, file);
  }
  const outputs = [
    ...summary.outputs.map((output) => {
      const turn = turnOf.get(output.path);
      return turn ? { file: turn, inTurnDiff: true } : { file: output, inTurnDiff: false };
    }),
    ...checkpointOnly.map((file) => ({ file, inTurnDiff: true })),
  ];
  return (
    <>
      <SummarySection
        title={t("summary.outputs")}
        fixed
        items={outputs}
        row={({ file, inTurnDiff }) => {
          const open = inTurnDiff ? onOpenChanges : onOpenOutput;
          return (
            <li key={file.path}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link acpmux-summary-file"
                disabled={!open}
                onClick={() => open?.(file.path)}
              >
                <Icon name={file.created ? "file.new" : "file.text"} size={ROW_ICON} row />
                <span className="acpmux-summary-text">{file.displayPath}</span>
                <Counts additions={file.additions} deletions={file.deletions} />
              </button>
            </li>
          );
        }}
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
        // The last turn that edited files: its totals open its diff (its files are under Outputs).
        <SummarySection
          title={t("header.changes")}
          items={[]}
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
          row={() => null}
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
          <li key={task.id} className="acpmux-summary-row" data-state={task.state}>
            <Icon name="terminal" size={ROW_ICON} row />
            <span className="acpmux-summary-text">{task.command}</span>
            <span className="acpmux-summary-meta">{t(TASK_STATES[task.state])}</span>
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
