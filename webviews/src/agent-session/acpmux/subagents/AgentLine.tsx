// One running or finished piece of the chat's work on one line: a subagent or a background
// command. The tray above the composer (SubagentTray.tsx) and the summary card's Subagents list
// (summary/SubagentStatusList.tsx) both draw their rows with it, so a subagent looks the same in
// either place (Leo 2026-10-20: one style for the tray, the chip and the popover). Its icon carries
// the status badge (summary.css `.acpmux-lineage__icon`) and is in the theme's accent while it runs,
// never a brand color; then its name, a dim detail (what it does now, or its kind), its time and
// its state. A click opens it.
import type { ReactNode } from "react";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SubagentStatus } from "../summary/SubagentStatusList";

const ROW_ICON = rowIconSize(12);

export function AgentLine({
  name,
  detail,
  status,
  state,
  time,
  icon = "agent.session",
  iconSize = ROW_ICON,
  depth = 0,
  current = false,
  title,
  label,
  onOpen,
  after,
}: {
  name: string;
  /// What it does now, or the kind of agent it is; dim after the name.
  detail?: string;
  status: SubagentStatus;
  /// Its state in words ("Running", "Waiting", "Done").
  state: string;
  /// How long it has run, or ran (formatDuration); none when unknown.
  time?: string;
  /// `agent.session` for a subagent, `terminal` for a background command.
  icon?: string;
  iconSize?: number;
  /// How far it sits under the agent that spawned it.
  depth?: number;
  /// The pane shows it now.
  current?: boolean;
  /// A tooltip with what the line cannot show (a subagent's whole task).
  title?: string;
  /// The accessible name, when the visible text is not enough ("Open Reviewer").
  label?: string;
  onOpen?: () => void;
  /// Drawn after the line, outside its button (a running subagent's stop button).
  after?: ReactNode;
}) {
  return (
    <div className="acpmux-agent-line" data-status={status}>
      <button
        type="button"
        className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-agent-line__button"
        style={depth > 0 ? { paddingLeft: 8 + Math.min(depth, 3) * 14 } : undefined}
        data-status={status}
        aria-current={current ? "true" : undefined}
        aria-label={label}
        /* tooltip-allow: the line shows the name; the task appears nowhere else */
        title={title}
        disabled={!onOpen}
        onClick={onOpen}
      >
        <span className="acpmux-lineage__icon" data-state={status}>
          <Icon name={icon} size={iconSize} row />
        </span>
        <span className="acpmux-summary-text">
          <span className="acpmux-summary-agent__name">{name}</span>
          {detail && detail !== name && <span className="acpmux-summary-agent__kind">{detail}</span>}
        </span>
        {time !== undefined && <span className="acpmux-summary-meta acpmux-agent-line__time">{time}</span>}
        <span className="acpmux-summary-meta acpmux-summary-agent__state">{state}</span>
      </button>
      {after}
    </div>
  );
}
