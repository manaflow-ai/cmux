// The summary card's Subagents section (SummaryCard.tsx): every subagent of the chat, nested ones
// indented under the agent that spawned them, with its live state (running, waiting on the user,
// done, failed) and its time. A row shows that subagent (`onOpen`): its pane when it has one. Its
// title opens the card's Subagents tab (`onShowAll`, SubagentsTab.tsx).
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
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

export const STATUS_LABEL: Record<SubagentStatus, StringKey> = {
  running: "subagents.state.running",
  waiting: "subagents.state.waiting",
  done: "subagents.state.completed",
  failed: "subagents.state.failed",
};

export function subagentStatus(agent: Subagent, waiting: ReadonlySet<string>): SubagentStatus {
  if (running(agent)) return waiting.has(agent.id) ? "waiting" : "running";
  return agent.state === "completed" ? "done" : "failed";
}

/// The tool calls the chat's open asks are about: the pending permission (`snapshot.permission`),
/// the pending items of permission groups, and permission rows still pending.
export function pendingToolCalls(
  snapshot: Pick<AcpmuxSnapshot, "rows" | "permission" | "permissionGroups">,
): Set<string> {
  const calls = new Set<string>();
  const add = (value: unknown) => {
    if (typeof value === "string" && value) calls.add(value);
  };
  if (snapshot.permission?.pending) add(snapshot.permission.toolCallId);
  for (const group of snapshot.permissionGroups?.groups ?? [])
    for (const item of group.items)
      if (item.state === "pending") add((item.request.toolCall as { toolCallId?: unknown } | undefined)?.toolCallId);
  for (const row of snapshot.rows)
    if (row.kind === "permission" && row.permission?.pending) add(row.permission.toolCallId);
  return calls;
}

/// The subagents that wait on the user: an open ask about one of their own tool calls (their
/// view's tool calls).
export function waitingSubagents(
  calls: ReadonlySet<string>,
  views: Record<string, AcpmuxRow[]> | undefined,
): Set<string> {
  const waiting = new Set<string>();
  if (calls.size === 0 || !views) return waiting;
  for (const [id, own] of Object.entries(views))
    if (own.some((row) => row.items?.some((item) => item.tool && calls.has(item.tool.id)))) waiting.add(id);
  return waiting;
}

/// Depth-first from the chat's own subagents; on each level the ones waiting on the user first, then
/// the running ones, then the ended ones, each newest first.
function ordered(agents: readonly Subagent[], waiting: ReadonlySet<string>): { agent: Subagent; depth: number }[] {
  const rank = (agent: Subagent) => ({ waiting: 0, running: 1, done: 2, failed: 2 })[subagentStatus(agent, waiting)];
  const known = new Set(agents.map((agent) => agent.id));
  const out: { agent: Subagent; depth: number }[] = [];
  const visit = (parent: string | null, depth: number) => {
    for (const agent of agents
      .filter((agent) => (agent.parent !== null && known.has(agent.parent) ? agent.parent : null) === parent)
      .sort((a, b) => rank(a) - rank(b) || b.startedAt - a.startedAt)) {
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
  autoOpen,
  onShowAll,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  /// The subagent this pane shows, if any.
  current?: string;
  onOpen?: (id: string) => void;
  /// The switch for opening new subagents in panes of their own (subagents/subagentPanes.ts).
  autoOpen?: { on: boolean; set: (on: boolean) => void };
  /// Opens the card's Subagents tab; the title is a button only with it.
  onShowAll?: () => void;
}) {
  const t = useT();
  const now = useNow(agents.some(running));
  const title = t("summary.subagents");
  const live = agents.filter((agent) => subagentStatus(agent, waiting) === "running").length;
  const heading = live > 0 ? `${title} · ${t("summary.subagents.running", { n: live })}` : title;
  return (
    <section className="acpmux-summary-section acpmux-summary-agents" aria-label={title}>
      <h3 className="acpmux-summary-title">
        {onShowAll ? (
          <button type="button" className="acpmux-summary-title__button" onClick={onShowAll}>
            {heading}
            <Icon name="disclosure.collapsed" size={10} />
          </button>
        ) : (
          heading
        )}
      </h3>
      <ul className="acpmux-summary-list">
        {agents.length === 0 && <li className="acpmux-summary-row acpmux-summary-none">{t("summary.none")}</li>}
        {ordered(agents, waiting).map(({ agent, depth }) => {
          const status = subagentStatus(agent, waiting);
          return (
            <li key={agent.id}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent"
                style={depth > 0 ? { paddingLeft: 8 + depth * 14 } : undefined}
                data-status={status}
                aria-current={agent.id === current ? "true" : undefined}
                /* tooltip-allow: the row shows the name; the task appears nowhere else */
                title={agent.task}
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
      {autoOpen && (
        <label className="acpmux-summary-row acpmux-summary-autoopen">
          <input
            type="checkbox"
            aria-label={t("summary.subagents.openPanes")}
            checked={autoOpen.on}
            onChange={(event) => autoOpen.set(event.currentTarget.checked)}
          />
          <span className="acpmux-summary-text">{t("summary.subagents.openPanes")}</span>
        </label>
      )}
    </section>
  );
}
