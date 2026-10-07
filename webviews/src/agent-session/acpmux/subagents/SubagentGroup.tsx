// A batch of subagents inline in the transcript, after the ChatGPT and T3 Code apps: one line with
// their avatars, "4 subagents", how many are working or done, the time since the first started,
// and a chevron; opened, a bordered list with a row per subagent (SUBAGENT_ROW rows below it).
// Every line has a fixed height (model.ts), so a running clock or a changing status never moves
// the transcript.
import { useEffect, useState } from "react";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "../conversation/turns";
import type { Subagent } from "./subagentFold";

/// Avatars drawn before "+N".
const STACK = 3;

const running = (agent: Subagent) => agent.state === "running";

/// Each subagent state's label in an open group.
const STATE_LABEL = {
  running: "subagents.state.running",
  completed: "subagents.state.completed",
  failed: "subagents.state.failed",
  cancelled: "subagents.state.cancelled",
  disconnected: "subagents.state.disconnected",
} as const;

/// Milliseconds a subagent has run: until it ended, or until `now`.
export const elapsed = (agent: Subagent, now: number) => Math.max(0, (agent.endedAt ?? now) - agent.startedAt);

/// The group's time: from its first start to its last end, or to `now` while one runs.
export function groupElapsed(agents: readonly Subagent[], now: number): number {
  if (agents.length === 0) return 0;
  const start = Math.min(...agents.map((agent) => agent.startedAt));
  const end = agents.some(running) ? now : Math.max(...agents.map((agent) => agent.endedAt ?? agent.startedAt));
  return Math.max(0, end - start);
}

/// The current time, ticking each second only while `live`.
function useNow(live: boolean): number {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!live) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [live]);
  return now;
}

function Avatar({ agent, dot = false }: { agent: Subagent; dot?: boolean }) {
  return (
    <span className="cv-subagent-avatar" data-state={agent.state}>
      <Icon name="agent.session" size={14} />
      {dot && <span className="cv-subagent-avatar__dot" aria-hidden="true" />}
    </span>
  );
}

export function SubagentGroupHeader({
  row,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const agents = row.subagents ?? [];
  const live = agents.some(running);
  const now = useNow(live);
  const count = (state: string) => agents.filter((agent) => agent.state === state).length;
  const status = [
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("completed") > 0 && t("summary.subagents.done", { n: count("completed") }),
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <button type="button" className="cv-subagents" aria-expanded={expanded} onClick={onToggle}>
      <span className="cv-subagents__stack" aria-hidden="true">
        {agents.slice(0, STACK).map((agent) => (
          <Avatar key={agent.id} agent={agent} />
        ))}
        {agents.length > STACK && <span className="cv-subagents__more">+{agents.length - STACK}</span>}
      </span>
      <span className="cv-subagents__text">
        <span className="cv-subagents__title">{t("subagents.count", { n: agents.length })}</span>
        <span className="cv-subagents__status" data-live={live || undefined}>
          {status}
        </span>
      </span>
      <span className="cv-subagents__time">{formatDuration(groupElapsed(agents, now))}</span>
      <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
    </button>
  );
}

/// One subagent in an open group: its avatar with a status dot, name, state or current action,
/// and time. `edge` rounds the list's first and last rows.
export function SubagentListRow({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const agent = row.subagents?.[0];
  const now = useNow(agent ? running(agent) : false);
  if (!agent) return null;
  const label = STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed;
  const state = running(agent) ? (agent.action ?? t(label)) : t(label);
  return (
    <div className="cv-subagent" data-edge={row.status}>
      <Avatar agent={agent} dot />
      <span className="cv-subagent__text">
        <span className="cv-subagent__name">{agent.name}</span>
        <span className="cv-subagent__state">{state}</span>
      </span>
      <span className="cv-subagent__time">{formatDuration(elapsed(agent, now))}</span>
    </div>
  );
}
