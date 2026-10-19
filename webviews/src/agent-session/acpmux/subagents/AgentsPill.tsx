// The agents pill (after Codex's phone app): while any of the chat's subagents runs, a small pill
// right above the composer says how many run ("2 agents"). It opens a list of every subagent of
// the chat split into Active (running, or waiting on the user) and Completed, each with a dot in
// its color (agentTones.ts), which its name in the transcript shares. A click on an agent opens
// it: its pane, or its view in this pane (App.tsx `showSubagent`). The pill is a part of the
// bottom stack (bottomStack.css), not laid over the transcript, so it never hides the latest row.
import { memo, useId } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { usePopover } from "../summary/usePopover";
import { STATUS_LABEL, subagentStatus } from "../summary/SubagentStatusList";
import { elapsed, running, useNow } from "./SubagentGroup";
import type { Subagent } from "./subagentFold";

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
        <dialog ref={popover} id={listId} open className="acpmux-agents-list" aria-label={title}>
          {sections.map((section) => (
            <section key={section.key} className="acpmux-agents-list__section">
              <h3 className="acpmux-agents-list__heading">{section.title}</h3>
              <ul>
                {section.agents.map((agent) => {
                  const status = subagentStatus(agent, waiting);
                  const state = status === "running" && agent.action ? agent.action : t(STATUS_LABEL[status]);
                  return (
                    <li key={agent.id}>
                      <button
                        type="button"
                        className="acpmux-agents-list__row"
                        data-agent-tone={tones.get(agent.id)}
                        data-status={status}
                        onClick={() => {
                          // Focus goes back to the pill, not to the page, as the row goes.
                          setOpen(false);
                          button.current?.focus();
                          onOpen(agent.id);
                        }}
                      >
                        <span className="acpmux-agents-list__dot" aria-hidden="true" />
                        <span className="acpmux-agents-list__text">
                          <span className="acpmux-agents-list__name">{agent.name}</span>
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
