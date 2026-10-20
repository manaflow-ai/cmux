// The session rail's Background tasks card body (Claude Code desktop's Background tasks): the
// chat's running background processes, newest first, each with how long it has run and a Stop
// button, then how many finished. Five show and the rest wait behind Show more.
import { useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useNow } from "../subagents/SubagentGroup";
import type { RailProcess } from "./sessionProcesses";

const SHOWN = 5;
const ROW_ICON = rowIconSize(12);

export const isRunning = (process: RailProcess) => process.state === "running";

export function RailTasks({
  processes,
  onStop,
}: {
  processes: readonly RailProcess[];
  /// `_acpmux/process/kill`; without it there is no Stop.
  onStop?: (id: string) => Promise<unknown>;
}) {
  const t = useT();
  const [expanded, setExpanded] = useState(false);
  const running = processes.filter(isRunning).sort((a, b) => b.startedAt - a.startedAt);
  const finished = processes.length - running.length;
  const now = useNow(running.length > 0);
  const visible = expanded ? running : running.slice(0, SHOWN);
  return (
    <>
      {running.length > 0 && (
        <ul className="acpmux-rail-list">
          {visible.map((process) => (
            <li key={process.id} className="acpmux-rail-task">
              <Icon name="terminal" size={ROW_ICON} row />
              <span className="acpmux-rail-task__command" title={process.command}>
                {process.command}
              </span>
              <span className="acpmux-rail-task__time">{formatDuration(Math.max(0, now - process.startedAt))}</span>
              {onStop && <StopButton process={process} stop={onStop} />}
            </li>
          ))}
        </ul>
      )}
      {running.length > SHOWN && (
        <button
          type="button"
          className="acpmux-rail-more"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? t("prDock.less") : t("prDock.more", { count: running.length - SHOWN })}
        </button>
      )}
      {finished > 0 && <p className="acpmux-rail-tasks__finished">{t("rail.finished", { count: finished })}</p>}
    </>
  );
}

/// Stop: off once sent, until the registry's update ends the row; when acpmux or the harness
/// refuses, it says so and can be tried again (as a subagent's Stop, SubagentGroup.tsx).
function StopButton({ process, stop }: { process: RailProcess; stop: (id: string) => Promise<unknown> }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const label = t(state === "failed" ? "subagents.stopFailed" : "subagents.stop", { name: process.command });
  return (
    <button
      type="button"
      className="acpmux-rail-task__stop"
      data-state={state}
      disabled={state === "stopping"}
      aria-label={label}
      title={label}
      onClick={() => {
        setState("stopping");
        stop(process.id).catch(() => setState("failed"));
      }}
    >
      <Icon name="action.stop" size={12} />
    </button>
  );
}
