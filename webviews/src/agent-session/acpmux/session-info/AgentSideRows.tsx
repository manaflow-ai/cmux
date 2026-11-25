// What waits on the agent's side (agentSide.ts) at the foot of Background tasks: the held surge's
// counts and acpmux's own queued prompts, as plain text rows a wakeup's look takes, with no action
// (Leo, 2026-11-24: "maybe not even interactable?"). The person reads them here when they look for
// them; the composer's stack no longer carries them.
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { AGENT_SIDE_ICONS, type AgentSideRow } from "./agentSide";

const ROW_ICON = rowIconSize(12);

export function AgentSideRows({ rows }: { rows: readonly AgentSideRow[] }) {
  return (
    <ul className="acpmux-session-info-list" data-section="agent-side">
      {rows.map((row) => (
        <li key={row.id} className="acpmux-session-info-task" data-kind={row.kind} title={row.help}>
          <Icon name={AGENT_SIDE_ICONS[row.kind].web} size={ROW_ICON} row fit className="acpmux-row-glyph" />
          <span className="acpmux-session-info-task__command">{row.title}</span>
          {row.detail !== undefined && <span className="acpmux-session-info-task__state">{row.detail}</span>}
          {row.trailing !== undefined && <span className="acpmux-session-info-task__time">{row.trailing}</span>}
        </li>
      ))}
    </ul>
  );
}
