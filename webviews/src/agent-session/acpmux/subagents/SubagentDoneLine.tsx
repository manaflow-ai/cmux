// What a subagent leaves in the transcript once it ends (runningTray.ts `withSubagentLines`): one
// quiet line where it ended, "Subagent finished: Explore the daemon · 1m 20s". It is drawn as a
// tool row, in their font, height and rhythm, as a background shell's end is
// (conversation/BackgroundTaskNote.tsx). A failure says so in the danger color; a subagent the
// person stopped, or acpmux lost, says that, and a stopped one says why when the pane knows
// ("stopped by you", "interrupted by Send now"; subagentFold.ts `stopReasonOf`), nothing when it
// does not. A click opens the subagent's view, its whole run. On hover, a subagent that did not
// finish offers Restart, which asks the chat to run it again with its prompt (restart.ts), in the
// hover row's buttons (conversation/MessageActions.tsx).
//
// While acpmux waits to retry it (retryState.ts), the line reads "Retrying (2/4) after a capacity
// error" with the turning ring. A failed one offers Retry, inline and in its ⋯ menu: acpmux runs
// it again, or, where acpmux cannot, the line asks the chat's agent to ("Ask parent to retry").
// A refusal leaves a short note after the line until the row next changes.
import { createContext, useContext, useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { formatDuration } from "../conversation/turns";
import { Retry, Spinner } from "../conversation/icons";
import { TurnActionsContext } from "../conversation/turnActions";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { canRestart, STOP_REASON_LABEL } from "./restart";
import { retryLabel, subagentRetry, type RetryAction, type RetryNote, type SessionRetryFields } from "./retryState";
import { elapsed, SubagentNavContext, SubagentPaneContext } from "./SubagentGroup";
import { useSubsessionInfo } from "./subsessions";

const DONE_LABEL: Record<string, StringKey> = {
  completed: "subagents.ended.completed",
  failed: "subagents.ended.failed",
  cancelled: "subagents.ended.cancelled",
  disconnected: "subagents.ended.disconnected",
};

/// Where a failed line's Retry sits: an inline button (the default), a link after the line's
/// time, or only in the ⋯ menu. The gallery compares them (SubagentRetry.gallery.tsx).
export type RetryAffordance = "button" | "link" | "menu";
export const RetryAffordanceContext = createContext<RetryAffordance>("button");

const ACTION_LABEL: Record<RetryAction, StringKey> = { daemon: "retry.action", ask: "retry.askParent" };

export function SubagentDoneLine({ row }: { row: AcpmuxRow }) {
  // Only a sub-session's line reads the session list (its retry is on its own session row): the
  // other lines never subscribe to it, so a session update wakes no line but its own.
  const child = row.subagents?.[0]?.child;
  return child ? <SubsessionDoneLine row={row} child={child} /> : <DoneLine row={row} />;
}

function SubsessionDoneLine({ row, child }: { row: AcpmuxRow; child: string }) {
  return <DoneLine row={row} child={useSubsessionInfo(child)} />;
}

/// `child`: a sub-session's own session row, where acpmux keeps its retry.
function DoneLine({ row, child }: { row: AcpmuxRow; child?: SessionRetryFields }) {
  const t = useT();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const affordance = useContext(RetryAffordanceContext);
  const { restartSubagent, retryAgent, retryCapabilities } = useContext(TurnActionsContext);
  const agent = row.subagents?.[0];
  // A refusal's note lasts until the row changes. A Retry that went keeps the row's Retry disabled
  // until the row changes (acpmux's next word on it), so it can't go twice; acpmux refuses a second
  // one of its own as `retry.busy` meanwhile.
  const [note, setNote] = useState<{ version: number; key?: RetryNote; busy?: boolean }>();
  const open = pane ?? nav;
  if (!agent) return null;
  // The row's retry, as every surface reads it (retryState.ts ``subagentRetry``).
  const phase = subagentRetry(agent, retryCapabilities, child);
  const waiting = phase.kind === "retrying" ? phase.retry : undefined;
  const action = retryAgent && phase.kind === "failed" ? phase.action : undefined;
  const label = t(DONE_LABEL[agent.state] ?? DONE_LABEL.completed!, { name: agent.name });
  const reasonKey = agent.state === "cancelled" && agent.stopReason ? STOP_REASON_LABEL[agent.stopReason] : undefined;
  const time = formatDuration(elapsed(agent, agent.endedAt ?? row.at));
  // While acpmux retries it, or settles whether it will, Restart would run it a second time.
  const restart =
    restartSubagent && canRestart(agent) && phase.kind !== "retrying" && phase.kind !== "settling"
      ? restartSubagent
      : undefined;
  const parts = waiting
    ? [agent.name, retryLabel(t, waiting)]
    : [
        label,
        ...(reasonKey ? [t(reasonKey)] : []),
        ...(phase.kind === "failed" && phase.gaveUp ? [t("retry.retriedOut", { of: phase.gaveUp.of })] : []),
        time,
        // Why it failed, as acpmux recorded it, last: the line cuts it first.
        ...(agent.state === "failed" && agent.error ? [agent.error] : []),
      ];
  const shown = note?.version === row.version ? note : undefined;
  const run = () => {
    if (!retryAgent || shown?.busy) return;
    setNote({ version: row.version, busy: true });
    void retryAgent(agent).then(
      (key) => setNote(key ? { version: row.version, key } : { version: row.version, busy: true }),
      () => setNote({ version: row.version, key: "retry.failed" }),
    );
  };
  const inline = action && affordance !== "menu" && (
    <button
      type="button"
      className={affordance === "link" ? "cv-subagent-retry-link" : "cv-subagent-retry"}
      disabled={shown?.busy}
      onClick={run}
    >
      {affordance === "button" && <Retry size={12} />}
      {t(ACTION_LABEL[action])}
    </button>
  );
  return (
    <div className="cv-tools cv-subagent-done-row">
      <button
        type="button"
        className="cv-tool cv-bgtask cv-subagent-done"
        data-state={waiting ? "retrying" : agent.state}
        {...(agent.stopReason && { "data-reason": agent.stopReason })}
        disabled={!open}
        onClick={() => open?.(agent.id)}
      >
        <span className="cv-tool__icon">
          {waiting ? <Spinner size={16} loading /> : <Icon name="agent.session" size={16} />}
        </span>
        {/* tooltip-allow: the line is cut at the pane's width; its whole text, the failure included */}
        <span className="cv-tool__text" title={parts.join(" · ")}>
          {parts.join(" · ")}
        </span>
      </button>
      {inline}
      {shown?.key && <output className="cv-subagent-done__note">{t(shown.key)}</output>}
      {(restart || action) && (
        <span className="cv-subagent-done__actions">
          {restart && (
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
          )}
          {action && (
            <Menu>
              <MenuButton
                className="cv-iconbtn cv-iconbtn--compact"
                data-menu="subagent-done"
                label={t("retry.menu")}
                title={t("retry.menu")}
                aria-haspopup="menu"
              >
                <Icon name="action.more" size={14} />
              </MenuButton>
              <MenuPopup side="bottom" align="end" className="acpmux-quick-menu" label={t("retry.menu")}>
                {/* The one Retry the row offers: acpmux's, or asking the chat's agent where acpmux can't. */}
                <MenuItem className="acpmux-quick-item" onSelect={run}>
                  {t(ACTION_LABEL[action])}
                </MenuItem>
              </MenuPopup>
            </Menu>
          )}
        </span>
      )}
    </div>
  );
}
