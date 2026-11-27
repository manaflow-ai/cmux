// Session Info's Background tasks (Claude Code desktop's; Codex has none): the chat's running
// background commands, newest first, each with how long it has run, then the wakeups and cron jobs
// it scheduled (each kind its own icon, session-info/taskIcons.ts, a cron job's schedule in words),
// then "N finished", folded, which opens into the ended commands and the wakeups and cron jobs whose
// time has passed (session-info/scheduled.ts), latest first, with how each ended.
// The commands are the registry's and the ones only the transcript knows (processes.ts
// `backgroundCommands`: Claude's background Bash, Ctrl-B's included). On this Mac a row opens the
// chat's Background tasks panel on that command's card, open with its command and output, Open in
// terminal inside it (backgroundTasks/openBackgroundTasks.ts); a host with no panel (Quick Chat, the
// gallery) opens the command's terminal beside the chat (processTerminal.ts). A peer's (SSH) or Cloud
// chat has neither, so there
// it shows the Bash call that started it in the transcript, and a row with neither is no button
// and says why. A command the registry lists also has Stop.
// Dev servers head the section in rows of their own (ServersSection.tsx). A running row's time ends
// it, and on the row's hover or focus Stop takes the time's place (sessionInfo.css). The panel's body
// scrolls, not the section; nothing is cut to a few rows. A command that starts while the list is drawn
// drops in at the top (ui/presence.ts `useArrivals`); the ones the list is drawn with are simply there.
import { useContext, useState, type ReactNode } from "react";
import { useArrivals } from "../../../ui/presence";
import { OpenBackgroundTasks } from "../backgroundTasks/openBackgroundTasks";
import { formatDuration, spanDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { openCommand } from "../processTerminal";
import { useNow } from "../subagents/subagentGroupModel";
import type { SummaryWakeup } from "../summary/sessionSummary";
import { arrivalKey, sendLabel, splitCommands, type BackgroundCommand } from "./processes";
import { scheduledTrailing, splitScheduled, useScheduledClock, type ScheduledEntry } from "./scheduled";
import { SessionInfoFold } from "./SessionInfoSection";
import { TASK_ICONS } from "./taskIcons";
import { useFoldMotion } from "./foldMotion";
import { COMMAND_STATE } from "./tasksSectionModel";
import { WindowedRows } from "./WindowedRows";
import { Clock } from "../../../ui/Typography";
import { WithFacts } from "../chips/FactsHoverCard";

const ROW_ICON = rowIconSize(12);

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
  const openTasks = useContext(OpenBackgroundTasks);
  const [showFinished, setShowFinished] = useState(false);
  // The finished row opens its list as one motion with the sections under it (foldMotion.ts).
  const finishedFold = useFoldMotion<HTMLDivElement>(showFinished, () => 0);
  const { running, finished } = splitCommands(commands);
  // Moves once, when the earliest wakeup or cron job still ahead ends (no per-second poll).
  const scheduledNow = useScheduledClock(scheduled);
  const { active, finished: ended } = splitScheduled(scheduled, scheduledNow);
  // Every command's id, so opening the finished fold, or a command finishing, replays nothing.
  const { arrived, played } = useArrivals(commands.map(arrivalKey));
  const row = (command: BackgroundCommand, time: ReactNode, state?: string, enters = false) => {
    const toolCallId = command.toolCallId;
    // What a click opens: the terminal on this Mac (else the call, when the host refuses), the call
    // elsewhere; with neither, the row is not a button and says why in its tooltip and to VoiceOver,
    // so the command keeps the row (as text the reason squeezed "bun test …" to "bun t…",
    // cmuxterm-hq#19495).
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
        data-closed={why !== undefined ? "" : undefined}
        // On the row, not the button: a disabled button takes no hover, so its own tooltip never shows.
        title={why && t(why)}
        data-enter={enters ? "top" : undefined}
        onAnimationEnd={
          enters ? (event) => event.target === event.currentTarget && played(arrivalKey(command)) : undefined
        }
      >
        <button
          type="button"
          className="acpmux-session-info-task__open"
          disabled={why !== undefined}
          aria-description={why && t(why)}
          onClick={() => {
            if (local && openTasks && toolCallId) openTasks(toolCallId);
            else void openCommand(toolCallId, { local, showCall: onShowCall });
          }}
        >
          <Icon name={TASK_ICONS.command.web} size={ROW_ICON} row fit className="acpmux-row-glyph" />
          <span className="acpmux-session-info-task__command">{sendLabel(t, command) ?? command.command}</span>
          {typeof time === "string" ? (
            <Clock className="acpmux-session-info-task__time" text={time} size={runningClockSize(time)} />
          ) : time}
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
    // A wakeup or cron job is the call that made it (sessionSummary `scheduled`, keyed by the call):
    // while the loaded transcript holds that call, a click shows it, and the row lights on hover as
    // a command's does (Leo, 2026-11-06: the "Fallback heartbeat ... doesn't get highlighted in the
    // same way that the other ones do"). With no call to show it stays plain text, as a command
    // with nothing to open does.
    const call = entry.item.id;
    const shows = !!onShowCall && (calls?.has(call) ?? false);
    const body = (
      <>
        <Icon name={TASK_ICONS[entry.item.kind].web} size={ROW_ICON} row fit className="acpmux-row-glyph" />
        <span className="acpmux-session-info-task__command">{entry.item.text}</span>
        {trailing !== undefined && (
          <span className={ended ? "acpmux-session-info-task__state" : "acpmux-session-info-task__time"}>
            {trailing}
          </span>
        )}
      </>
    );
    return (
      <WithFacts
        key={`scheduled:${entry.item.id}`}
        facts={[{ value: entry.item.cron && !ended ? `${entry.item.text} (${entry.item.cron})` : entry.item.text }]}
      >
        {(facts) => (
          <li
            {...facts}
            className={`acpmux-session-info-task${shows ? " acpmux-session-info-task--opens" : ""}`}
            data-kind={entry.item.kind}
            data-state={entry.status.state}
          >
            {shows ? (
              <button type="button" className="acpmux-session-info-task__open" onClick={() => onShowCall(call)}>
                {body}
              </button>
            ) : (
              body
            )}
          </li>
        )}
      </WithFacts>
    );
  };
  // The ended commands and scheduled items as one list, latest first.
  const finishedRows = [
    ...finished.map((command) => ({ at: command.endedAt ?? command.startedAt, command })),
    ...ended.map((entry) => ({ at: entry.status.endedAt, entry })),
  ].sort((a, b) => (b.at ?? -Infinity) - (a.at ?? -Infinity));
  return (
    <div data-section="tasks">
      {(running.length > 0 || active.length > 0) && (
        <ul className="acpmux-session-info-list">
          {running.map((command) =>
            row(
              command,
              // A task only the transcript knows may not say when it started.
              command.startedAt !== undefined ? (
                <RunningTaskElapsed startedAt={command.startedAt} />
              ) : (
                t(COMMAND_STATE.running)
              ),
              undefined,
              arrived.has(arrivalKey(command)),
            ),
          )}
          {active.map(scheduledRow)}
        </ul>
      )}
      {finishedRows.length > 0 && (
        <>
          <SessionInfoFold open={showFinished} onToggle={() => finishedFold.toggle(!showFinished, setShowFinished)}>
            <Icon name="disclosure.collapsed" size={12} />
            {t("rail.finished", { count: finishedRows.length })}
          </SessionInfoFold>
          {finishedFold.drawn && (
            <div ref={finishedFold.ref} className="acpmux-session-info-fold-box">
              <ul className="acpmux-session-info-list" data-finished="">
                {/* However many ended, the open draws the rows that can show (WindowedRows). */}
                <WindowedRows
                  items={finishedRows}
                  render={(entry) =>
                    "command" in entry
                      ? row(
                          entry.command,
                          entry.command.endedAt !== undefined && entry.command.startedAt !== undefined
                            ? spanDuration(t, entry.command.endedAt - entry.command.startedAt)
                            : undefined,
                          t(COMMAND_STATE[entry.command.state]),
                        )
                      : scheduledRow(entry.entry)
                  }
                />
              </ul>
            </div>
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

/// A running command's time: as `formatDuration` under an hour ("5m 41s"), to the minute past it
/// ("1h 2m"). Seconds on an hour-long watch say nothing, and their reserve ("00h 00m 00s") cut the
/// command it times: at 420 px "bun test test/session-info-tasks.test.tsx --watch"
/// read "bun test …tsx …" beside "1h 2m 1s" and a third of a box of nothing
/// (TaskRowReason.gallery.tsx, `commandKeepsTheRow`).
export function runningTime(ms: number): string {
  const total = Math.floor(ms / 1000);
  if (total < 3600) return formatDuration(ms);
  return `${Math.floor(total / 3600)}h ${Math.floor((total % 3600) / 60)}m`;
}

function RunningTaskElapsed({ startedAt }: { startedAt: number }) {
  const now = useNow(true);
  const text = runningTime(Math.max(0, now - startedAt));
  return <Clock className="acpmux-session-info-task__time" size={runningClockSize(text)} text={text} />;
}

/// The box a running command's time keeps: under an hour the steady "00m 00s" `Clock` reserves
/// itself, so a ticking count never moves the command's end; past it the time's own digits, which
/// change width once in ten minutes at most, so the hour form reserves no room it does not show.
function runningClockSize(time: string): string | undefined {
  return /^\d+h \d+m$/.test(time) ? time.replace(/\d/g, "0") : undefined;
}
