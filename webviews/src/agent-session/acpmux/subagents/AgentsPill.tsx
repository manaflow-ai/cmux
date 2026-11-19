// The agents pill (after Codex's phone app): while any of the chat's subagents runs, a small pill
// right above the composer says how many run ("2 agents"). It opens a list of every subagent of
// the chat split into Active (running, or waiting on the user) and Completed, each with a dot in
// its color (agentTones.ts), which its name in the transcript shares. An agent another one spawned
// sits right under it, moved in (`nestAgents`). A click on an agent opens
// it: its pane, or its view in this pane (App.tsx `showSubagent`). The pill is a part of the
// bottom stack (bottomStack.css), not laid over the transcript, so it never hides the latest row.
import { memo, useCallback, useId } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { usePopover } from "../summary/usePopover";
import { subagentStatus, subagentStatusLabel } from "../summary/subagentStatusListModel";
import { elapsed, running, useNow } from "./subagentGroupModel";
import type { Subagent } from "./subagentFold";
import { AgentIdentity } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { subagentDisplayName } from "./subsessions";
import { nestAgents } from "./agentsPillModel";
import { namedAction } from "./trayDetail";
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
  onOpen: (id: string) => void;
}) {
  const t = useT();
  const { open, setOpen, button, popover, toggle } = usePopover();
  const listId = useId();
  const live = agents.filter(running);
  // A row picked: focus goes back to the pill, not to the page, as the row goes.
  const pick = useCallback(
    (id: string) => {
      setOpen(false);
      button.current?.focus();
      onOpen(id);
    },
    [setOpen, button, onOpen],
  );
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
                {nestAgents(section.agents).map(({ agent, depth }) => (
                  <AgentsPillRow
                    key={agent.id}
                    agent={agent}
                    depth={depth}
                    waits={waiting.has(agent.id)}
                    tone={tones.get(agent.id)}
                    onPick={pick}
                  />
                ))}
              </ul>
            </section>
          ))}
        </dialog>
      )}
    </div>
  );
});

const NO_WAITING: ReadonlySet<string> = new Set();

/// One agent of the open list. Memoized on its agent and plain values: its time is a leaf that keeps
/// its own clock (PillElapsed), so a tick draws no row.
const AgentsPillRow = memo(function AgentsPillRow({
  agent,
  depth,
  waits,
  tone,
  onPick,
}: {
  agent: Subagent;
  depth: number;
  /// It waits on the user (the pill's `waiting` holds it).
  waits: boolean;
  tone?: number;
  onPick: (id: string) => void;
}) {
  const t = useT();
  const waiting = waits ? new Set([agent.id]) : NO_WAITING;
  const status = subagentStatus(agent, waiting);
  const state =
    (status === "running" && namedAction(t, agent.action, agent.actionShell)) || t(subagentStatusLabel(agent, waiting));
  return (
    <li>
      <button
        type="button"
        className="acpmux-agents-list__row"
        // Past three levels the rows stop moving in, so a name keeps its room.
        data-depth={depth > 0 ? Math.min(depth, 3) : undefined}
        data-agent-tone={tone}
        data-status={status}
        onClick={() => onPick(agent.id)}
      >
        {/* The harness's mark when it has one, else the agent's dot in its own tone. */}
        <AgentIdentity
          className="acpmux-agents-list__mark"
          harness={agent.harness}
          tone={tone ?? agentTone(agent.id)}
          size={9}
          fallbackNode={<span className="acpmux-agents-list__dot" />}
        />
        <span className="acpmux-agents-list__text">
          <span className="acpmux-agents-list__name">{subagentDisplayName(t, agent)}</span>
          <span className="acpmux-agents-list__state">{state}</span>
        </span>
        <PillElapsed agent={agent} />
        <Icon name="disclosure.collapsed" size={12} />
      </button>
    </li>
  );
});

/// A row's time, on its own clock: it ticks while the agent runs, and nothing else draws for it.
function PillElapsed({ agent }: { agent: Subagent }) {
  const now = useNow(running(agent));
  return <span className="acpmux-agents-list__time">{formatDuration(elapsed(agent, now))}</span>;
}
