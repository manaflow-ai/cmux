import { subagentName } from "./subagentNavigation";
// What a subagent leaves in the transcript once it ends (runningTray.ts `withSubagentLines`): one
// quiet line where it ended, "Subagent finished: Explore the daemon · 1m 20s". It is drawn as a
// tool row, in their font, height and rhythm, as a background shell's end is
// (conversation/BackgroundTaskNote.tsx). A failure says so in the danger color; a subagent the
// person stopped, or acpmux lost, says that, and a stopped one says why when the pane knows
// ("stopped by you", "interrupted by Send now"; subagentFold.ts `stopReasonOf`), nothing when it
// does not. A click opens the subagent's view, its whole run. On hover, a subagent that did not
// finish offers Restart, which asks the chat to run it again with its prompt (restart.ts), in the
// hover row's buttons (conversation/MessageActions.tsx).
import { useContext } from "react";
import { formatDuration } from "../conversation/turns";
import { Retry } from "../conversation/icons";
import { TurnActionsContext } from "../conversation/turnActions";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { canRestart, STOP_REASON_LABEL } from "./restart";
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
  const { restartSubagent } = useContext(TurnActionsContext);
  const open = pane ?? nav;
  const agent = row.subagents?.[0];
  if (!agent) return null;
  const label = t(DONE_LABEL[agent.state] ?? DONE_LABEL.completed!, { name: subagentName(agent) });
  const reasonKey = agent.state === "cancelled" && agent.stopReason ? STOP_REASON_LABEL[agent.stopReason] : undefined;
  const time = formatDuration(elapsed(agent, agent.endedAt ?? row.at));
  const restart = restartSubagent && canRestart(agent) ? restartSubagent : undefined;
  return (
    <div className="cv-tools cv-subagent-done-row">
      <button
        type="button"
        className="cv-tool cv-bgtask cv-subagent-done"
        data-state={agent.state}
        {...(agent.stopReason && { "data-reason": agent.stopReason })}
        disabled={!open}
        onClick={(event) => open?.(agent.id, event)}
      >
        <span className="cv-tool__icon">
          <Icon name="agent.session" size={16} />
        </span>
        <span className="cv-tool__text">{[label, ...(reasonKey ? [t(reasonKey)] : []), time].join(" · ")}</span>
      </button>
      {restart && (
        <span className="cv-subagent-done__actions">
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact cv-subagent-restart"
            aria-label={t("subagents.restart")}
            title={t("subagents.restart")}
            data-tooltip-detail={t("subagents.restartDetail")}
            onClick={() => restart(agent)}
          >
            <Retry size={14} />
          </button>
        </span>
      )}
    </div>
  );
}
