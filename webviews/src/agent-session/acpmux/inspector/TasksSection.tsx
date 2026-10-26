// The Inspector's Background tasks (Claude Code desktop's; Codex has none): the chat's running
// background commands, newest first, each with how long it has run, then the wakeups and cron jobs
// it scheduled, then "N finished", folded, which opens into the ended commands with how each ended.
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
import { formatDuration } from "../conversation/turns";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { openCommand } from "../processTerminal";
import { useNow } from "../subagents/SubagentGroup";
import type { SummaryWakeup } from "../summary/sessionSummary";
import { arrivalKey, sendLabel, splitCommands, type BackgroundCommand } from "./processes";
import { InspectorFold } from "./InspectorSection";

const ROW_ICON = rowIconSize(12);

/// What a command's state says (the summary card's rows say the same, summary/SummaryTasks.tsx).
export const COMMAND_STATE: Record<BackgroundCommand["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
  lost: "chatInspector.tasks.lost",
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
  const [showFinished, setShowFinished] = useState(false);
  const { running, finished } = splitCommands(commands);
  const now = useNow(running.length > 0);
  // Every command's id, so opening the finished fold, or a command finishing, replays nothing.
  const { arrived, played } = useArrivals(commands.map(arrivalKey));
  const row = (command: BackgroundCommand, time: string | undefined, state?: string, enters = false) => {
    const toolCallId = command.toolCallId;
    // What a click opens: the terminal on this Mac (else the call, when the host refuses), the call
    // elsewhere; with neither, the row is not a button and its tooltip says why.
    const shows = !!toolCallId && !!onShowCall && (calls?.has(toolCallId) ?? false);
    const why: StringKey | undefined = !toolCallId
      ? "chatInspector.tasks.noTerminal.noCall"
      : local || shows
        ? undefined
        : "chatInspector.tasks.noTerminal.remote";
    return (
      // Keyed by the call that started it: when the registry lists a command only the transcript
      // knew, its id turns into the registry's, and a key by id remounted the row (Leo: "why does
      // it FLICKER").
      <li
        key={arrivalKey(command)}
        className="acpmux-chat-inspector-task acpmux-chat-inspector-task--command"
        data-state={command.state}
        data-enter={enters ? "top" : undefined}
        title={why && t(why)}
        onAnimationEnd={
          enters ? (event) => event.target === event.currentTarget && played(arrivalKey(command)) : undefined
        }
      >
        <button
          type="button"
          className="acpmux-chat-inspector-task__open"
          disabled={why !== undefined}
          onClick={() => {
            void openCommand(toolCallId, { local, showCall: onShowCall });
          }}
        >
          <Icon name="terminal" size={ROW_ICON} row />
          <span className="acpmux-chat-inspector-task__command">{sendLabel(t, command) ?? command.command}</span>
          {time !== undefined && <span className="acpmux-chat-inspector-task__time">{time}</span>}
          {state !== undefined && <span className="acpmux-chat-inspector-task__state">{state}</span>}
        </button>
        {command.state === "running" && command.processId && onStop && (
          <StopButton id={command.processId} name={command.command} stop={onStop} />
        )}
      </li>
    );
  };
  return (
    <div className="acpmux-chat-inspector-scroll" data-section="tasks">
      {(running.length > 0 || scheduled.length > 0) && (
        <ul className="acpmux-chat-inspector-list">
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
          {scheduled.map((wakeup) => (
            <li key={wakeup.id} className="acpmux-chat-inspector-task">
              <Icon name="task.status.started" size={ROW_ICON} row />
              <span className="acpmux-chat-inspector-task__command">{wakeup.text}</span>
              {wakeup.cron && <span className="acpmux-chat-inspector-task__time">{wakeup.cron}</span>}
            </li>
          ))}
        </ul>
      )}
      {finished.length > 0 && (
        <>
          <InspectorFold open={showFinished} onToggle={() => setShowFinished(!showFinished)}>
            <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
            {t("rail.finished", { count: finished.length })}
          </InspectorFold>
          {showFinished && (
            <ul className="acpmux-chat-inspector-list" data-finished="">
              {finished.map((command) =>
                row(
                  command,
                  command.endedAt !== undefined && command.startedAt !== undefined
                    ? formatDuration(Math.max(0, command.endedAt - command.startedAt))
                    : undefined,
                  t(COMMAND_STATE[command.state]),
                ),
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
}: {
  id: string;
  name: string;
  /// What it says before a failed stop, in place of "Stop <name>" (the tray: "Stop only this command").
  label?: string;
  stop: (id: string) => Promise<unknown>;
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
      className="acpmux-chat-inspector-icon-button acpmux-chat-inspector-stop"
      data-state={state}
      disabled={state === "stopping"}
      aria-label={label}
      title={label}
      onClick={() => {
        setState("stopping");
        stop(id).catch(() => setState("failed"));
      }}
    >
      <Icon name="action.stop" size={12} />
    </button>
  );
}
