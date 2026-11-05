// Session Info's Background tasks (Claude Code desktop's; Codex has none): the chat's running
// background commands, newest first, each with how long it has run, then the wakeups and cron jobs
// it scheduled (each kind its own icon, session-info/taskIcons.ts, a cron job's schedule in words),
// then "N finished", folded, which opens into the ended commands and the wakeups and cron jobs whose
// time has passed (session-info/scheduled.ts), latest first, with how each ended.
// The commands are the registry's and the ones only the transcript knows (processes.ts
// `backgroundCommands`: Claude's background Bash, Ctrl-B's included). A row opens the command's
// terminal beside the chat (processTerminal.ts); a peer's (SSH) or Cloud chat has none, so there
// it shows the Bash call that started it in the transcript, and a row with neither is no button
// and says why. A command the registry lists also has Stop.
// Dev servers are listed under Servers instead (ServersSection.tsx). The list scrolls inside the
// section; nothing is cut to a few rows. A command that starts while the list is drawn drops in at
// the top (ui/presence.ts `useArrivals`); the ones the list is drawn with are simply there.
import { useState } from "react";
import { useArrivals } from "../../../ui/presence";
import { useScrollEdges } from "../../../ui/scrollEdges";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { openCommand } from "../processTerminal";
import { useNow } from "../subagents/SubagentGroup";
import type { SummaryWakeup } from "../summary/sessionSummary";
import { arrivalKey, sendLabel, splitCommands, type BackgroundCommand } from "./processes";
import { scheduledTrailing, splitScheduled, useScheduledClock, type ScheduledEntry } from "./scheduled";
import { SessionInfoFold } from "./SessionInfoSection";
import { TASK_ICONS } from "./taskIcons";

const ROW_ICON = rowIconSize(12);

/// What a command's state says (the summary card's rows say the same, summary/SummaryTasks.tsx).
export const COMMAND_STATE: Record<BackgroundCommand["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
  lost: "sessionInfo.tasks.lost",
};

export function TasksSection({
  commands,
  scheduled = [],
  onStop,
  local = true,
  calls,
  onShowCall,
}: {
  commands: readonly BackgroundCommand[];
  /// Wakeups and cron jobs the agent scheduled for itself (sessionSummary `scheduled`).
  scheduled?: readonly SummaryWakeup[];
  /// `_acpmux/process/kill`; without it, or for a command the registry does not list, no Stop.
  onStop?: (id: string) => Promise<unknown>;
  /// The chat runs on this Mac, so a command's terminal can open (processTerminal.ts
  /// `opensProcessTerminal`).
  local?: boolean;
  /// The tool calls the loaded transcript holds: a row whose call is among them can show it.
  calls?: ReadonlySet<string>;
  /// Shows the call that started a command in the transcript (App.tsx `showToolRow`); false when no
  /// loaded row holds it.
  onShowCall?: (toolCallId: string) => boolean;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const [showFinished, setShowFinished] = useState(false);
  const listEdges = useScrollEdges();
  const { running, finished } = splitCommands(commands);
  const now = useNow(running.length > 0);
  // Moves once, when the earliest wakeup or cron job still ahead ends (no per-second poll).
  const scheduledNow = useScheduledClock(scheduled);
  const { active, finished: ended } = splitScheduled(scheduled, Math.max(now, scheduledNow));
  // Every command's id, so opening the finished fold, or a command finishing, replays nothing.
  const { arrived, played } = useArrivals(commands.map(arrivalKey));
  const row = (command: BackgroundCommand, time: string | undefined, state?: string, enters = false) => {
    const toolCallId = command.toolCallId;
    // What a click opens: the terminal on this Mac (else the call, when the host refuses), the call
    // elsewhere; with neither, the row is not a button and its tooltip says why.
    const shows = !!toolCallId && !!onShowCall && (calls?.has(toolCallId) ?? false);
    const why: StringKey | undefined = !toolCallId
      ? "sessionInfo.tasks.noTerminal.noCall"
      : local || shows
        ? undefined
        : "sessionInfo.tasks.noTerminal.remote";
    return (
      // Keyed by the call that started it: when the registry lists a command only the transcript
      // knew, its id turns into the registry's, and a key by id remounted the row (Leo: "why does
      // it FLICKER").
      <li
        key={arrivalKey(command)}
        className="acpmux-session-info-task acpmux-session-info-task--command"
        data-state={command.state}
        data-enter={enters ? "top" : undefined}
        title={why && t(why)}
        onAnimationEnd={
          enters ? (event) => event.target === event.currentTarget && played(arrivalKey(command)) : undefined
        }
      >
        <button
          type="button"
          className="acpmux-session-info-task__open"
          disabled={why !== undefined}
          onClick={() => {
            void openCommand(toolCallId, { local, showCall: onShowCall });
          }}
        >
          <Icon name={TASK_ICONS.command.web} size={ROW_ICON} row className="acpmux-row-glyph" />
          <span className="acpmux-session-info-task__command">{sendLabel(t, command) ?? command.command}</span>
          {time !== undefined && <span className="acpmux-session-info-task__time">{time}</span>}
          {state !== undefined && <span className="acpmux-session-info-task__state">{state}</span>}
        </button>
        {command.state === "running" && command.processId && onStop && (
          <StopButton id={command.processId} name={command.command} stop={onStop} solid />
        )}
      </li>
    );
  };
  const scheduledRow = (entry: ScheduledEntry) => {
    const trailing = scheduledTrailing(t, language, entry);
    const ended = entry.status.state !== "scheduled";
    return (
      <li
        key={`scheduled:${entry.item.id}`}
        className="acpmux-session-info-task"
        data-kind={entry.item.kind}
        data-state={entry.status.state}
        title={entry.item.cron && !ended ? `${entry.item.text} (${entry.item.cron})` : entry.item.text}
      >
        <Icon name={TASK_ICONS[entry.item.kind].web} size={ROW_ICON} row className="acpmux-row-glyph" />
        <span className="acpmux-session-info-task__command">{entry.item.text}</span>
        {trailing !== undefined && (
          <span className={ended ? "acpmux-session-info-task__state" : "acpmux-session-info-task__time"}>
            {trailing}
          </span>
        )}
      </li>
    );
  };
  // The ended commands and scheduled items as one list, latest first.
  const finishedRows = [
    ...finished.map((command) => ({ at: command.endedAt ?? command.startedAt, command })),
    ...ended.map((entry) => ({ at: entry.status.endedAt, entry })),
  ].sort((a, b) => (b.at ?? -Infinity) - (a.at ?? -Infinity));
  return (
    <div ref={listEdges} className="acpmux-session-info-scroll ui-scroll-edge-fade" data-section="tasks">
      {(running.length > 0 || active.length > 0) && (
        <ul className="acpmux-session-info-list">
          {running.map((command) =>
            row(
              command,
              // A task only the transcript knows may not say when it started.
              command.startedAt !== undefined
                ? formatDuration(Math.max(0, now - command.startedAt))
                : t(COMMAND_STATE.running),
              undefined,
              arrived.has(arrivalKey(command)),
            ),
          )}
          {active.map(scheduledRow)}
        </ul>
      )}
      {finishedRows.length > 0 && (
        <>
          <SessionInfoFold open={showFinished} onToggle={() => setShowFinished(!showFinished)}>
            <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
            {t("rail.finished", { count: finishedRows.length })}
          </SessionInfoFold>
          {showFinished && (
            <ul className="acpmux-session-info-list" data-finished="">
              {finishedRows.map((entry) =>
                "command" in entry
                  ? row(
                      entry.command,
                      entry.command.endedAt !== undefined && entry.command.startedAt !== undefined
                        ? formatDuration(Math.max(0, entry.command.endedAt - entry.command.startedAt))
                        : undefined,
                      t(COMMAND_STATE[entry.command.state]),
                    )
                  : scheduledRow(entry.entry),
              )}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

/// Stop: off once sent, until the registry's update ends the row; when acpmux or the harness
/// refuses, it says so and can be tried again (as a subagent's Stop, SubagentGroup.tsx).
export function StopButton({
  id,
  name,
  label: idleLabel,
  stop,
  solid = false,
}: {
  id: string;
  name: string;
  /// What it says before a failed stop, in place of "Stop <name>" (the tray: "Stop only this command").
  label?: string;
  stop: (id: string) => Promise<unknown>;
  /// A filled square, as Claude Desktop's running rows draw it (Background tasks and the tray).
  solid?: boolean;
}) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const label =
    state !== "failed" && idleLabel
      ? idleLabel
      : t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", { name });
  return (
    <button
      type="button"
      className="acpmux-session-info-icon-button acpmux-session-info-stop"
      data-state={state}
      disabled={state === "stopping"}
      aria-label={label}
      title={label}
      onClick={() => {
        setState("stopping");
        stop(id).catch(() => setState("failed"));
      }}
    >
      <Icon name="action.stop" size={12} selected={solid} />
    </button>
  );
}
