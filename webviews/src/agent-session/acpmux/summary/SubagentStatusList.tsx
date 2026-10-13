// The summary card's Subagents section (SummaryCard.tsx): every subagent of the chat, nested ones
// indented under the agent that spawned them, with its live state (running, waiting on the user,
// done, failed) and its time. A row shows that subagent (`onOpen`): its pane when it has one.
import type { AcpmuxRow } from "../model";
import { formatDuration } from "../conversation/turns";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { elapsed, running, useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";

const ROW_ICON = rowIconSize(12);

/// What a row says of its subagent: a subagent that asks the user for a permission or an answer
/// is waiting on them, not running; a cancelled or lost one ended without its result.
export type SubagentStatus = "running" | "waiting" | "done" | "failed";

const STATUS_LABEL: Record<SubagentStatus, StringKey> = {
  running: "subagents.state.running",
  waiting: "subagents.state.waiting",
  done: "subagents.state.completed",
  failed: "subagents.state.failed",
};

export function subagentStatus(agent: Subagent, waiting: ReadonlySet<string>): SubagentStatus {
  if (running(agent)) return waiting.has(agent.id) ? "waiting" : "running";
  return agent.state === "completed" ? "done" : "failed";
}

/// The subagents that wait on the user: a pending permission row whose tool call is one of
/// theirs (their own view's tool calls).
export function waitingSubagents(
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> | undefined,
): Set<string> {
  const calls = new Set(
    rows.flatMap((row) =>
      row.kind === "permission" && row.permission?.pending && row.permission.toolCallId
        ? [row.permission.toolCallId]
        : [],
    ),
  );
  const waiting = new Set<string>();
  if (calls.size === 0 || !views) return waiting;
  for (const [id, own] of Object.entries(views))
    if (own.some((row) => row.items?.some((item) => item.tool && calls.has(item.tool.id)))) waiting.add(id);
  return waiting;
}

/// Depth-first from the chat's own subagents, each level newest first.
function ordered(agents: readonly Subagent[]): { agent: Subagent; depth: number }[] {
  const known = new Set(agents.map((agent) => agent.id));
  const out: { agent: Subagent; depth: number }[] = [];
  const visit = (parent: string | null, depth: number) => {
    for (const agent of agents
      .filter((agent) => (agent.parent !== null && known.has(agent.parent) ? agent.parent : null) === parent)
      .sort((a, b) => b.startedAt - a.startedAt)) {
      out.push({ agent, depth });
      visit(agent.id, depth + 1);
    }
  };
  visit(null, 0);
  return out;
}

export function SubagentStatusList({
  agents,
  waiting,
  current,
  onOpen,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  /// The subagent this pane shows, if any.
  current?: string;
  onOpen?: (id: string) => void;
}) {
  const t = useT();
  const now = useNow(agents.some(running));
  const title = t("summary.subagents");
  const live = agents.filter(running).length;
  return (
    <section className="acpmux-summary-section acpmux-summary-agents" aria-label={title}>
      <h3 className="acpmux-summary-title">
        {live > 0 ? `${title} · ${t("summary.subagents.running", { n: live })}` : title}
      </h3>
      <ul className="acpmux-summary-list">
        {agents.length === 0 && <li className="acpmux-summary-row acpmux-summary-none">{t("summary.none")}</li>}
        {ordered(agents).map(({ agent, depth }) => {
          const status = subagentStatus(agent, waiting);
          return (
            <li key={agent.id}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent"
                style={depth > 0 ? { paddingLeft: 8 + depth * 14 } : undefined}
                data-status={status}
                aria-current={agent.id === current ? "true" : undefined}
                aria-label={t("subagents.open", { name: agent.name })}
                title={agent.task ?? agent.name}
                disabled={!onOpen}
                onClick={() => onOpen?.(agent.id)}
              >
                <span className="acpmux-lineage__icon" data-state={status}>
                  <Icon name="agent.session" size={ROW_ICON} row />
                </span>
                <span className="acpmux-summary-text">
                  <span className="acpmux-summary-agent__name">{agent.name}</span>
                  {agent.kind && agent.kind !== agent.name && (
                    <span className="acpmux-summary-agent__kind">{agent.kind}</span>
                  )}
                </span>
                <span className="acpmux-summary-meta">{formatDuration(elapsed(agent, now))}</span>
                <span className="acpmux-summary-meta acpmux-summary-agent__state">{t(STATUS_LABEL[status])}</span>
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
