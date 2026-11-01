import React, { type ReactNode } from "react";
import { Counts } from "../changes/Counts";
import { changedByTools } from "../changes/turnCheckpoint";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { TurnFile } from "../diff";
import { type BackgroundCommand, backgroundCommands } from "../session-info/processes";
import { projectPathAllowed, type SessionSummary } from "./sessionSummary";
import { SourcesAddMenu, type ChatToolsControl } from "./SourcesAddMenu";
import { SubagentStack } from "./SubagentStack";
import { SummarySection } from "./SummarySection";
import { SummaryTasks } from "./SummaryTasks";
import { WorkflowSummaries, WorkflowSummaryRow, type WorkflowActions } from "./WorkflowSummary";
import type { WorkflowSummary } from "./workflow";
import type { WorkflowCapacitySignal } from "./foldWorkflows";

const ROW_ICON = rowIconSize(12);

/// The chat's summary, a section per kind of thing it produced: its background tasks first (they
/// are live, SummaryTasks.tsx), then Outputs, Subagents and Sources in the Codex app's order, then
/// Changes, pull requests and wakeups. A section with nothing is not drawn; a chat with nothing
/// at all says so in one quiet line. Sources' + (Attach files or folders) stays: with no sources
/// it is a row at the end.
/// Pull requests and sources are links, so they open, copy and open in a new tab as links do;
/// an output opens the changes view at that file. Outputs lists every file the chat changed, once
/// (hq#2569 item 4, cx-0h4xq). A file the last turn changed, by a tool or as only its checkpoint
/// knows (a shell command or formatter edited it), opens that turn's diff at the file; Changes is one row
/// that opens the last turn's diff with its totals.
/// Following a link calls `onFollow`. A chat
/// with images or renders offers its gallery under Outputs (GalleryDialog.tsx). A chat whose
/// subagents acpmux reports lists them with their live state (SubagentStatusList.tsx) in the
/// Subagents place. The summary card (SummaryCard.tsx) draws it.
/// The last turn that edited files: its files as its diff shows them (the checkpoint's once
/// loaded) and their totals.
export type SummaryChanges = {
  additions: number;
  deletions: number;
  files?: readonly Pick<TurnFile, "path" | "displayPath" | "canonical" | "additions" | "deletions" | "created">[];
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
  tools,
  subagents,
  commands,
  onStopCommand,
  onOpenTasksInPane,
  workflow,
  workflowActions,
  workflows,
  workflowActionsFor,
  workflowCapacity,
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
  /// Sources' + also offers Use tools: the chat's tools, when acpmux can change them and it has some.
  tools?: ChatToolsControl;
  /// The Subagents section, when the card draws it (SubagentStatusList.tsx).
  subagents?: ReactNode;
  /// The chat's background commands, the registry's merged in (session-info/processes.ts); without them,
  /// the transcript's.
  commands?: readonly BackgroundCommand[];
  /// Stop for a running command the registry lists.
  onStopCommand?: (processId: string) => Promise<unknown>;
  /// Opens Session Info's complete Background tasks section beside the chat.
  onOpenTasksInPane?: () => void;
  /// Labs-only workflow data; absent until acpmux sends the typed workflow event.
  workflow?: WorkflowSummary;
  workflowActions?: WorkflowActions;
  workflows?: readonly WorkflowSummary[];
  workflowActionsFor?: (workflow: WorkflowSummary) => WorkflowActions;
  workflowCapacity?: WorkflowCapacitySignal;
}) {
  const t = useT();
  // With tools to offer, Sources' + is a menu (Attach files or folders, Use tools), and Sources
  // draws with no sources so the menu has a place.
  const toolsMenu = tools && tools.rows.length > 0 ? tools : undefined;
  const tasks = commands ?? backgroundCommands([], summary.backgroundTasks, false);
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
    // When the session has a project root, reject checkpoint paths outside it before matching by
    // display suffix. Otherwise an unrelated `outside/src/index.ts` could replace the allowed
    // `project/src/index.ts` output merely because both display as `src/index.ts`.
    const inProject = summary.cwd === undefined || projectPathAllowed(file.canonical ?? file.path, summary.cwd);
    if (!inProject) continue;
    const output = outputOf(file);
    if (output === undefined) {
      checkpointOnly.push(file);
    } else if (!turnOf.has(output)) turnOf.set(output, file);
  }
  const outputs = [
    ...summary.outputs.map((output) => {
      const turn = turnOf.get(output.path);
      return turn ? { file: turn, inTurnDiff: true } : { file: output, inTurnDiff: false };
    }),
    ...checkpointOnly.map((file) => ({ file, inTurnDiff: true })),
  ];
  const empty =
    !subagents &&
    !workflow &&
    !workflows?.length &&
    tasks.length === 0 &&
    outputs.length === 0 &&
    galleryCount === 0 &&
    !changes &&
    summary.subagents.length === 0 &&
    summary.sources.length === 0 &&
    summary.pullRequests.length === 0 &&
    summary.scheduled.length === 0;
  return (
    <>
      <SummaryTasks commands={tasks} onStop={onStopCommand} onFollow={onFollow} onOpenInPane={onOpenTasksInPane} />
      <WorkflowSummaryRow workflow={workflow} actions={workflowActions} />
      <WorkflowSummaries
        key={workflows?.[0]?.sessionId}
        workflows={workflows}
        actionsFor={workflowActionsFor}
        daemonCapacity={workflowCapacity}
      />
      <SummarySection
        title={t("summary.outputs")}
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
      {subagents ??
        (summary.subagents.length > 0 && (
          <section className="acpmux-summary-section" aria-label={t("summary.subagents")}>
            <h3 className="acpmux-summary-title">{t("summary.subagents")}</h3>
            <ul className="acpmux-summary-list">
              <SubagentStack subagents={summary.subagents} />
            </ul>
          </section>
        ))}
      <SummarySection
        title={t("summary.sources")}
        items={summary.sources}
        keep={toolsMenu !== undefined}
        action={
          toolsMenu ? (
            <SourcesAddMenu attach={onAttach} tools={toolsMenu} />
          ) : (
            onAttach && (
              <button
                type="button"
                className="acpmux-summary-add"
                aria-label={t("summary.sources.attach")}
                onClick={onAttach}
              >
                <Icon name="action.add" size={ROW_ICON} />
              </button>
            )
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
      {empty && <p className="acpmux-summary-empty">{t("summary.empty")}</p>}
      {onAttach && !toolsMenu && summary.sources.length === 0 && (
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link acpmux-summary-attach"
          onClick={onAttach}
        >
          <Icon name="action.add" size={ROW_ICON} row />
          <span className="acpmux-summary-text">{t("summary.sources.attach")}</span>
        </button>
      )}
    </>
  );
}
