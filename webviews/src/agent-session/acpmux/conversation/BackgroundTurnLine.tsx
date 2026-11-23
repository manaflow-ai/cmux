// The one muted line of a turn the agent ran on its own (backgroundTurns.ts): "Background task
// finished", "Scheduled check" or "Background update". While the turn runs it leads with the working
// spinner and its words shimmer as a running tool row's do (ShimmerText.tsx RowShimmer; Leo,
// 2026-11-09: "this scheduled check thing isn't highlighted all the way through like other tool
// calls are"); once it ended quiet it leads with the clock. A click opens the turn's rows under it, which
// the transcript draws as its own rows (turns.ts), so the open state is the transcript's fold set,
// kept per chat like a "Worked for" fold, and survives virtualization. One with no row of its own
// yet has nothing to open, so it has no chevron and is no button. A run of
// background-task notifications folded under one line (backgroundRuns.ts) draws here too, the same
// line in the same look: "4 background tasks finished". A turn a subagent's report started draws as
// that report, "Report from …", under the subagent's "Subagent finished" line
// (subagents/SubagentReportLine.tsx).
//
// After its words the line cites its task (Leo, 2026-11-05: "cite the helper/add atribution (like how
// ive gradually pushed for more andd more of that a la deeplinks and communicating in acpmux) and
// display the actual code in the raw"): the helper that ran it, a link that opens that helper's
// transcript as the background task row's owner does (BackgroundTaskNote.tsx), then its command as
// typed, in the code face, cut at the line's end.
import { useContext, useId, type KeyboardEvent, type MouseEvent } from "react";
import { useT } from "../i18n";
import type { AcpmuxBackgroundSource, AcpmuxBackgroundTurn, AcpmuxRow } from "../model";
import { SubagentNavContext } from "../subagents/subagentGroupModel";
import { experimentArm } from "../../../experiments/experiment";
import { backgroundRunLabel } from "./backgroundRuns";
import { backgroundTurnLook, backgroundTurnsInline } from "./backgroundTurnLook.experiment";
import { backgroundTurnLabel, foldsBackground } from "./backgroundTurns";
import { Clock, Spinner } from "./icons";
import { RowShimmer } from "./ShimmerText";
import { ShellBlock } from "./ShellBlock";
import {
  backgroundTurnOpensTask,
  backgroundTurnTaskCard,
  useBackgroundTurnTask,
  type BackgroundTurnTask,
} from "./backgroundTurnTask";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { spanDuration } from "./turns";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { SubagentReportLine } from "../subagents/SubagentReportLine";
import { isSubagentReport, useReportRowLook } from "../subagents/subagentReportLineModel";

export function BackgroundTurnLine({
  row,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const reportLook = useReportRowLook();
  const run = row.backgroundRun;
  if (run) {
    const label = backgroundRunLabel(t, run);
    return (
      <TranscriptActivityRow
        icon={<Clock />}
        before={label}
        className={`cv-background-turn${run.failed > 0 ? " cv-background-turn--failed" : ""}`}
        ariaLabel={label}
        expanded={expanded}
        attributes={{
          "aria-expanded": String(expanded),
          "data-find-skip": "",
          "data-background-turn": "run",
        }}
        onClick={onToggle}
      />
    );
  }
  const turn = row.background;
  if (!turn) return null;
  // A subagent's report opens to the report itself, so it opens whether or not the turn drew a row.
  if (isSubagentReport(row) && reportLook !== "before")
    return <SubagentReportLine row={row} look={reportLook} expanded={expanded} onToggle={onToggle} />;
  const label = backgroundTurnLabel(t, turn);
  const source = turn.source;
  const cited = [label, source?.ownerTitle, source?.command].filter(Boolean).join(" · ");
  // Until a row of its own draws, there is nothing to open: a plain line, no chevron, no button.
  // A failure that said something heads its rows, which already show (headsBackground).
  // Inline its rows already draw where they ran (backgroundTurnLook.experiment.ts): the line names its task, opens nothing.
  // A turn a finished task started says so in its words ("Background task finished"): its mark is the
  // clock though the agent is still answering (the shimmering words say that), never a spinner on a
  // finished task (Leo, 2026-11-21: "this spinner is incredibly ugly").
  const taskEnded = turn.cause !== undefined && turn.cause.status !== "running";
  const opens =
    turn.hasRows === true && foldsBackground(row) && !backgroundTurnsInline(experimentArm(backgroundTurnLook));
  // A line with no rows to fold still names a task that ran and ended: it opens to that task, as a
  // command row opens to its command (backgroundTurnTask.ts; Leo, 2026-11-21, "background tasks not
  // expandable ... why shouldn't they get the same treatment?").
  if (!opens && backgroundTurnOpensTask(turn, label))
    return <BackgroundTurnTaskLine turn={turn} label={label} cited={cited} />;
  return (
    <TranscriptActivityRow
      icon={turn.running && !taskEnded ? <Spinner look="track" /> : <Clock />}
      before={<span className="cv-background-turn__label">{label}</span>}
      after={turn.running ? <RowShimmer>{label}</RowShimmer> : undefined}
      className={`cv-background-turn${turn.running ? " is-live" : ""}`}
      ariaLabel={cited}
      expanded={opens && expanded}
      chevron={opens}
      attributes={{
        ...(opens && { "aria-expanded": String(expanded) }),
        "data-find-skip": "",
        "data-background-turn": turn.running ? "running" : opens || turn.quiet ? "quiet" : "failed",
      }}
      onClick={opens ? onToggle : undefined}
    >
      {source && <BackgroundSource source={source} />}
    </TranscriptActivityRow>
  );
}

/// The helper and raw command a background turn's line cites. The helper opens its transcript; the
/// line stays one button, so the helper is a link inside it, never a second button.
function BackgroundSource({ source }: { source: AcpmuxBackgroundSource }) {
  const openSubagent = useContext(SubagentNavContext);
  const owner = source.ownerTitle?.trim();
  const ownerId = source.ownerId;
  const open = (event: MouseEvent | KeyboardEvent) => {
    event.preventDefault();
    event.stopPropagation();
    openSubagent?.(ownerId);
  };
  return (
    <span className="cv-background-turn__source">
      {owner &&
        (ownerId && openSubagent ? (
          <span
            className="cv-background-turn__owner"
            // An <a> may not sit inside the line's <button>; this opens a helper in the pane, not a URL.
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="link"
            tabIndex={0}
            data-deeplink={`#subagent:${ownerId}`}
            onClick={open}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") open(event);
            }}
          >
            {owner}
          </span>
        ) : (
          <span className="cv-background-turn__owner">{owner}</span>
        ))}
      {source.command && <code className="cv-background-turn__command">{source.command}</code>}
    </span>
  );
}

/// A finished background turn's line that opens to its task: the command, how it ended and the last
/// lines it printed, in the command card a command row opens to (ShellBlock.tsx). Its open state is
/// the transcript's fold set, so it survives virtualization as every other row's does.
function BackgroundTurnTaskLine({ turn, label, cited }: { turn: AcpmuxBackgroundTurn; label: string; cited: string }) {
  const [open, setOpen] = useTranscriptDisclosure(`bgturn:${turn.id}`);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const { task, request } = useBackgroundTurnTask(turn, label, open);
  const source = turn.source;
  return (
    <div className="cv-tools cv-background-turn__task">
      <TranscriptActivityRow
        icon={<Clock />}
        before={<span className="cv-background-turn__label">{label}</span>}
        className="cv-background-turn"
        ariaLabel={cited}
        expanded={open}
        chevron
        headerRef={fold.headerRef}
        attributes={{
          "aria-expanded": String(open),
          "data-find-skip": "",
          "data-background-turn": turn.quiet ? "quiet" : "failed",
          // It opens to its task, never to rows: those draw where they ran.
          "data-opens": "task",
        }}
        onClick={() => {
          void request();
          fold.toggle();
        }}
      >
        {source && <BackgroundSource source={source} />}
      </TranscriptActivityRow>
      {fold.present && (
        <div {...fold.bodyProps}>
          <BackgroundTurnTaskBody task={task} />
        </div>
      )}
    </div>
  );
}

/// The opened task: its command card, the end of its output and how it ended.
function BackgroundTurnTaskBody({ task }: { task: BackgroundTurnTask }) {
  const t = useT();
  const id = useId();
  const card = backgroundTurnTaskCard(task);
  const took = task.tookMs !== undefined ? spanDuration(t, task.tookMs) : undefined;
  const ended =
    card.ended === "completed"
      ? t("bgTask.state.completed")
      : card.ended === "failed"
        ? t("bgTask.state.failed")
        : card.ended === "stopped"
          ? t("bgTask.state.stopped")
          : undefined;
  const footer =
    task.description || ended ? (
      <div className="cv-bgtask__foot">
        {ended && <span className="cv-bgtask__state">{ended}</span>}
        {task.description && <span className="cv-bgtask__detail">{task.description}</span>}
      </div>
    ) : undefined;
  return (
    <ShellBlock
      id={id}
      command={card.command}
      output={card.output}
      cut={card.cut}
      exitCode={card.exitCode}
      took={took}
      footer={footer}
    />
  );
}
