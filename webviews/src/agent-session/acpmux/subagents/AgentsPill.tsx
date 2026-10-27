import { subagentName, type OpenSubagent } from "./subagentNavigation";
// The agents pill (after Codex's phone app): while any of the chat's subagents runs, a small pill
// right above the composer says how many run ("2 agents"). It opens a list of every subagent of
// the chat split into Active (running, or waiting on the user) and Completed, each with a dot in
// its color (agentTones.ts), which its name in the transcript shares. An agent another one spawned
// sits right under it, moved in (`nestAgents`). A click on an agent opens
// it: its pane, or its view in this pane (App.tsx `showSubagent`). The pill is a part of the
// bottom stack (bottomStack.css), not laid over the transcript, so it never hides the latest row.
import { memo, useId } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { usePopover } from "../summary/usePopover";
import { subagentStatus, subagentStatusLabel } from "../summary/SubagentStatusList";
import { elapsed, running, useNow } from "./SubagentGroup";
import type { Subagent } from "./subagentFold";

/// A section's agents in its order, each nested agent moved right under the agent that spawned it
/// when that one is in the section too, with how deep it then sits. An agent whose parent is in
/// another section, or unknown, stays at the top level.
export function nestAgents(agents: readonly Subagent[]): { agent: Subagent; depth: number }[] {
  const ids = new Set(agents.map((agent) => agent.id));
  const under = new Map<string | null, Subagent[]>();
  for (const agent of agents) {
    const parent = agent.parent !== null && ids.has(agent.parent) ? agent.parent : null;
    under.set(parent, [...(under.get(parent) ?? []), agent]);
  }
  const rows: { agent: Subagent; depth: number }[] = [];
  const placed = new Set<string>();
  const visit = (parent: string | null, depth: number) => {
    for (const agent of under.get(parent) ?? []) {
      if (placed.has(agent.id)) continue;
      placed.add(agent.id);
      rows.push({ agent, depth });
      visit(agent.id, depth + 1);
    }
  };
  visit(null, 0);
  // A parent loop never reaches the top level: list those agents flat rather than drop them.
  for (const agent of agents) if (!placed.has(agent.id)) rows.push({ agent, depth: 0 });
  return rows;
}

/// Memoized: App.tsx keeps its props the same while text streams.
export const AgentsPill = memo(function AgentsPill({
  agents,
  waiting,
  tones,
  onOpen,
}: {
  /// Every subagent of the chat, nested ones included.
  agents: readonly Subagent[];
  /// The subagents waiting on the user (summary/SubagentStatusList.tsx `waitingSubagents`).
  waiting: ReadonlySet<string>;
  tones: ReadonlyMap<string, number>;
  onOpen: OpenSubagent;
}) {
  const t = useT();
  const { open, setOpen, button, popover, toggle } = usePopover();
  const listId = useId();
  const live = agents.filter(running);
  const now = useNow(open && live.length > 0);
  if (live.length === 0) return null;
  const byStart = (a: Subagent, b: Subagent) => a.startedAt - b.startedAt || a.id.localeCompare(b.id);
  const sections = [
    { key: "active", title: t("subagents.pill.active"), agents: [...live].sort(byStart) },
    {
      key: "completed",
      title: t("subagents.pill.completed"),
      // The latest to end first.
      agents: agents
        .filter((agent) => !running(agent))
        .sort((a, b) => (b.endedAt ?? b.startedAt) - (a.endedAt ?? a.startedAt)),
    },
  ].filter((section) => section.agents.length > 0);
  const title = t("subagents.pill.list");
  return (
    <div className="acpmux-agents-pill-anchor">
      <button
        ref={button}
        type="button"
        className="acpmux-agents-pill"
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-controls={open ? listId : undefined}
        onClick={toggle}
      >
        <Icon name="agent.session" size={14} />
        <span>{t("subagents.pill", { n: live.length })}</span>
      </button>
      {open && (
        <dialog ref={popover} id={listId} open className="ui-popup ui-glass acpmux-agents-list" aria-label={title}>
          {sections.map((section) => (
            <section key={section.key} className="acpmux-agents-list__section">
              <h3 className="acpmux-agents-list__heading">{section.title}</h3>
              <ul>
                {nestAgents(section.agents).map(({ agent, depth }) => {
                  const status = subagentStatus(agent, waiting);
                  const state =
                    status === "running" && agent.action ? agent.action : t(subagentStatusLabel(agent, waiting));
                  return (
                    <li key={agent.id}>
                      <button
                        type="button"
                        className="acpmux-agents-list__row"
                        // Past three levels the rows stop moving in, so a name keeps its room.
                        data-depth={depth > 0 ? Math.min(depth, 3) : undefined}
                        data-agent-tone={tones.get(agent.id)}
                        data-status={status}
                        onClick={(event) => {
                          // Focus goes back to the pill, not to the page, as the row goes.
                          setOpen(false);
                          button.current?.focus();
                          onOpen(agent.id, event);
                        }}
                      >
                        <span className="acpmux-agents-list__dot" aria-hidden="true" />
                        <span className="acpmux-agents-list__text">
                          <span className="acpmux-agents-list__name">{subagentName(agent)}</span>
                          <span className="acpmux-agents-list__state">{state}</span>
                        </span>
                        <span className="acpmux-agents-list__time">{formatDuration(elapsed(agent, now))}</span>
                        <Icon name="disclosure.collapsed" size={12} />
                      </button>
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
        </dialog>
      )}
    </div>
  );
});
