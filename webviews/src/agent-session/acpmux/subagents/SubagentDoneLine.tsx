// What a subagent leaves in the transcript once it ends (runningTray.ts `withSubagentLines`): one
// quiet line where it ended, "Subagent finished: Explore the daemon · 1m 20s". It is drawn as a
// tool row, in their font, height and rhythm, as a background shell's end is
// (conversation/BackgroundTaskNote.tsx). A failure says so in the danger color; a subagent the
// person stopped, or acpmux lost, says that. A click opens the subagent's view, its whole run.
import { useContext } from "react";
import { formatDuration } from "../conversation/turns";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { elapsed, SubagentNavContext, SubagentPaneContext } from "./SubagentGroup";

const DONE_LABEL: Record<string, StringKey> = {
  completed: "subagents.ended.completed",
  failed: "subagents.ended.failed",
  cancelled: "subagents.ended.cancelled",
  disconnected: "subagents.ended.disconnected",
};

export function SubagentDoneLine({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const open = pane ?? nav;
  const agent = row.subagents?.[0];
  if (!agent) return null;
  const label = t(DONE_LABEL[agent.state] ?? DONE_LABEL.completed!, { name: agent.name });
  const time = formatDuration(elapsed(agent, agent.endedAt ?? row.at));
  return (
    <div className="cv-tools">
      <button
        type="button"
        className="cv-tool cv-bgtask cv-subagent-done"
        data-state={agent.state}
        disabled={!open}
        onClick={() => open?.(agent.id)}
      >
        <span className="cv-tool__icon">
          <Icon name="agent.session" size={16} />
        </span>
        <span className="cv-tool__text">{`${label} · ${time}`}</span>
      </button>
    </div>
  );
}
