// The summary card's Background tasks (SummaryBody.tsx), with the Inspector off (Debug Settings
// `agent.inspector`; on, the Inspector's TasksSection.tsx lists them): the chat's background
// commands (inspector/processes.ts `backgroundCommands`), running ones first and newest first, each
// with its description, state, elapsed time and a Stop button (inspector/TasksSection.tsx
// `StopButton`). Finished work stays visible as compact cards so a completed or failed task does
// not disappear behind an aggregate count; long lists keep the same bounded View all affordance.
// A row opens the command's terminal beside the chat (processTerminal.ts). A command that starts
// while the card is drawn drops in at the top (ui/presence.ts `useArrivals`); the ones the card is
// drawn with are simply there.
import { useMemo, useState } from "react";
import { useArrivals } from "../../../ui/presence";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { openProcessTerminal } from "../processTerminal";
import { useNow } from "../subagents/SubagentGroup";
import { arrivalKey, type BackgroundCommand, sendLabel, splitCommands } from "../inspector/processes";
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
  const shown = all ? running : running.slice(0, FOLDED);
  const shownFinished = finishedOpen ? finished : finished.slice(0, FOLDED);
  const { arrived, played } = useArrivals(commands.map(arrivalKey), [...shown, ...shownFinished].map(arrivalKey));
  if (commands.length === 0) return null;
  const title = t("summary.backgroundTasks");
  const row = (command: BackgroundCommand) => {
    const live = command.state === "running";
    const toolCallId = command.toolCallId;
    const key = arrivalKey(command);
    const enters = live && arrived.has(key);
    const detail = command.description && command.description !== command.command ? command.description : undefined;
    // A background `acpmux send` names who it goes to, as Session Info's tasks and the tray do.
    const sent = sendLabel(t, command);
    return (
      // Keyed as it arrives, by the call that started it, so the registry listing it keeps the row.
      <li
        key={key}
        className="acpmux-summary-task"
        data-state={command.state}
        data-enter={enters ? "top" : undefined}
        onAnimationEnd={enters ? (event) => event.target === event.currentTarget && played(key) : undefined}
      >
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
          <span className="acpmux-summary-text acpmux-summary-task__body">
            <span className="acpmux-summary-task__description">{sent ?? detail ?? command.command}</span>
            {(sent || detail) && <span className="acpmux-summary-task__command">{command.command}</span>}
          </span>
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
  // Keep every card and overflow control in one keyed child list. A task can move from running to
  // finished without remounting, so a focused card keeps its DOM node and terminal affordance.
  const cards = [
    ...shown.map(row),
    ...(running.length > FOLDED
      ? [
          <li key="running-overflow">
            <button type="button" className="acpmux-summary-more" onClick={() => setAll(!all)}>
              {all ? t("summary.showFewer") : t("summary.viewAll", { n: running.length })}
            </button>
          </li>,
        ]
      : []),
    ...shownFinished.map(row),
    ...(finished.length > FOLDED
      ? [
          <li key="finished-overflow">
            <button
              type="button"
              className="acpmux-summary-more acpmux-summary-finished"
              aria-expanded={finishedOpen}
              onClick={() => setFinishedOpen(!finishedOpen)}
            >
              <Icon name={finishedOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
              {finishedOpen ? t("summary.showFewer") : t("summary.viewAll", { n: finished.length })}
            </button>
          </li>,
        ]
      : []),
  ];
  return (
    <section className="acpmux-summary-section acpmux-summary-tasks" aria-label={title}>
      <h3 className="acpmux-summary-title">{title}</h3>
      <ul className="acpmux-summary-list">{cards}</ul>
    </section>
  );
}
