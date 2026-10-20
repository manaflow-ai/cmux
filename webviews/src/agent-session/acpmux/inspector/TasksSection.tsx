// The Inspector's Background tasks (Claude Code desktop's; Codex has none): the chat's running
// background commands, newest first, each with how long it has run and a Stop button, then the
// wakeups and cron jobs it scheduled, then "N finished", folded, which opens into the ended
// commands with how each ended. Dev servers are listed under Servers instead (ServersSection.tsx).
// The list scrolls inside the section; nothing is cut to a few rows.
import { useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { SummaryWakeup } from "../summary/sessionSummary";
import type { InspectorProcess } from "./processes";

const ROW_ICON = rowIconSize(12);

export const isRunning = (process: InspectorProcess) => process.state === "running";

const ENDED: Record<string, StringKey> = {
  exited: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  killed: "bgTask.state.stopped",
  lost: "chatInspector.tasks.lost",
};

export function TasksSection({
  processes,
  scheduled = [],
  onStop,
}: {
  processes: readonly InspectorProcess[];
  /// Wakeups and cron jobs the agent scheduled for itself (sessionSummary `scheduled`).
  scheduled?: readonly SummaryWakeup[];
  /// `_acpmux/process/kill`; without it there is no Stop.
  onStop?: (id: string) => Promise<unknown>;
}) {
  const t = useT();
  const [showFinished, setShowFinished] = useState(false);
  const running = processes.filter(isRunning).sort((a, b) => b.startedAt - a.startedAt);
  const finished = processes.filter((process) => !isRunning(process)).sort((a, b) => b.startedAt - a.startedAt);
  const now = useNow(running.length > 0);
  return (
    <div className="acpmux-inspector-scroll" data-section="tasks">
      {(running.length > 0 || scheduled.length > 0) && (
        <ul className="acpmux-inspector-list">
          {running.map((process) => (
            <li key={process.id} className="acpmux-inspector-task">
              <Icon name="terminal" size={ROW_ICON} row />
              <span className="acpmux-inspector-task__command">{process.command}</span>
              <span className="acpmux-inspector-task__time">
                {formatDuration(Math.max(0, now - process.startedAt))}
              </span>
              {onStop && <StopButton id={process.id} name={process.command} stop={onStop} />}
            </li>
          ))}
          {scheduled.map((wakeup) => (
            <li key={wakeup.id} className="acpmux-inspector-task">
              <Icon name="task.status.started" size={ROW_ICON} row />
              <span className="acpmux-inspector-task__command">{wakeup.text}</span>
              {wakeup.cron && <span className="acpmux-inspector-task__time">{wakeup.cron}</span>}
            </li>
          ))}
        </ul>
      )}
      {finished.length > 0 && (
        <>
          <button
            type="button"
            className="acpmux-inspector-fold"
            aria-expanded={showFinished}
            onClick={() => setShowFinished(!showFinished)}
          >
            <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
            {t("rail.finished", { count: finished.length })}
          </button>
          {showFinished && (
            <ul className="acpmux-inspector-list" data-finished="">
              {finished.map((process) => (
                <li key={process.id} className="acpmux-inspector-task" data-state={process.state}>
                  <Icon name="terminal" size={ROW_ICON} row />
                  <span className="acpmux-inspector-task__command">{process.command}</span>
                  <span className="acpmux-inspector-task__time">
                    {process.endedAt !== undefined && formatDuration(Math.max(0, process.endedAt - process.startedAt))}
                  </span>
                  <span className="acpmux-inspector-task__state">
                    {t(ENDED[process.state] ?? "bgTask.state.completed")}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

/// Stop: off once sent, until the registry's update ends the row; when acpmux or the harness
/// refuses, it says so and can be tried again (as a subagent's Stop, SubagentGroup.tsx).
export function StopButton({ id, name, stop }: { id: string; name: string; stop: (id: string) => Promise<unknown> }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const label = t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", { name });
  return (
    <button
      type="button"
      className="acpmux-inspector-icon-button acpmux-inspector-stop"
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
