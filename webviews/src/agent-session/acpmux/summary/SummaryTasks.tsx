// The summary card's Background tasks (SummaryBody.tsx), with the Inspector off (Debug Settings
// `agent.inspector`; on, the Inspector's TasksSection.tsx lists them): the chat's background
// commands (inspector/processes.ts `backgroundCommands`), running ones first and newest first, each
// with how long it has run and a Stop button (inspector/TasksSection.tsx `StopButton`). The finished
// ones fold into one "N finished" row that opens them in place. A row opens the command's terminal
// beside the chat (processTerminal.ts).
import { useMemo, useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { openProcessTerminal } from "../processTerminal";
import { useNow } from "../subagents/SubagentGroup";
import { type BackgroundCommand, splitCommands } from "../inspector/processes";
import { COMMAND_STATE, StopButton } from "../inspector/TasksSection";

const ROW_ICON = rowIconSize(12);
/// Running rows shown before "View all".
const FOLDED = 5;

export function SummaryTasks({
  commands,
  onStop,
  onFollow,
}: {
  commands: readonly BackgroundCommand[];
  /// `_acpmux/process/kill`; without it, or for a command the registry does not list, no Stop.
  onStop?: (processId: string) => Promise<unknown>;
  /// Called when a row opens its terminal.
  onFollow?: () => void;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const [finishedOpen, setFinishedOpen] = useState(false);
  const { running, finished } = useMemo(() => splitCommands(commands), [commands]);
  const now = useNow(running.length > 0);
  if (commands.length === 0) return null;
  const title = t("summary.backgroundTasks");
  const row = (command: BackgroundCommand) => {
    const live = command.state === "running";
    const toolCallId = command.toolCallId;
    return (
      <li key={command.id} className="acpmux-summary-task" data-state={command.state}>
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link"
          disabled={!toolCallId}
          onClick={() => {
            if (!toolCallId) return;
            onFollow?.();
            void openProcessTerminal(toolCallId);
          }}
        >
          <Icon name="terminal" size={ROW_ICON} row />
          <span className="acpmux-summary-text">{command.command}</span>
          <span className="acpmux-summary-meta">
            {live && command.startedAt !== undefined
              ? formatDuration(Math.max(0, now - command.startedAt))
              : t(COMMAND_STATE[command.state])}
          </span>
        </button>
        {live && command.processId && onStop && (
          <StopButton id={command.processId} name={command.command} stop={onStop} />
        )}
      </li>
    );
  };
  return (
    <section className="acpmux-summary-section acpmux-summary-tasks" aria-label={title}>
      <h3 className="acpmux-summary-title">{title}</h3>
      <ul className="acpmux-summary-list">
        {(all ? running : running.slice(0, FOLDED)).map(row)}
        {running.length > FOLDED && (
          <li>
            <button type="button" className="acpmux-summary-more" onClick={() => setAll(!all)}>
              {all ? t("summary.showFewer") : t("summary.viewAll", { n: running.length })}
            </button>
          </li>
        )}
        {finished.length > 0 && (
          <li>
            <button
              type="button"
              className="acpmux-summary-more acpmux-summary-finished"
              aria-expanded={finishedOpen}
              onClick={() => setFinishedOpen(!finishedOpen)}
            >
              <Icon name={finishedOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
              {t("rail.finished", { count: finished.length })}
            </button>
          </li>
        )}
        {finishedOpen && finished.map(row)}
      </ul>
    </section>
  );
}
