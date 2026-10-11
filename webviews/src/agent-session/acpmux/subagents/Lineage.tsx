// The summary popover's Lineage section, after the T3 Code app: where the shown view sits among
// the chat's subagents. In a subagent's own view it starts at the agent that spawned it; then
// the shown agent's running subagents, newest first, and the ended ones folded under "Previous
// agents (N)". A row opens that agent's view.
import { useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { STATE_LABEL, elapsed, running, useNow } from "./SubagentGroup";
import type { Subagent } from "./subagentFold";

const ROW_ICON = rowIconSize(12);

/// `current` is the subagent whose view is shown, or undefined for the chat's own (`chat` names
/// it); `onOpen` opens an agent's view, the chat's with undefined.
export function Lineage({
  agents,
  current,
  chat,
  onOpen,
}: {
  agents: readonly Subagent[];
  current: string | undefined;
  chat: string;
  onOpen: (id: string | undefined) => void;
}) {
  const t = useT();
  const [previous, setPrevious] = useState(false);
  const shown = current === undefined ? undefined : agents.find((agent) => agent.id === current);
  const parent = shown?.parent ? agents.find((agent) => agent.id === shown.parent) : undefined;
  const children = agents
    .filter((agent) => agent.parent === (shown?.id ?? null))
    .sort((a, b) => b.startedAt - a.startedAt);
  const live = children.filter(running);
  const ended = children.filter((agent) => !running(agent));
  const now = useNow(live.length > 0 || (parent ? running(parent) : false));
  const title = t("summary.lineage");
  const row = (agent: Subagent) => (
    <li key={agent.id}>
      <button type="button" className="acpmux-summary-row acpmux-summary-link" onClick={() => onOpen(agent.id)}>
        <span className="acpmux-lineage__icon" data-state={agent.state}>
          <Icon name="agent.session" size={ROW_ICON} row />
        </span>
        <span className="acpmux-summary-text acpmux-lineage__name">{agent.name}</span>
        <span className="acpmux-summary-meta">{formatDuration(elapsed(agent, now))}</span>
        <span className="acpmux-summary-meta acpmux-lineage__state">
          {t(STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed)}
        </span>
      </button>
    </li>
  );
  return (
    <section className="acpmux-summary-section acpmux-lineage" aria-label={title}>
      <h3 className="acpmux-summary-title">
        {live.length > 0 ? `${title} · ${t("summary.subagents.running", { n: live.length })}` : title}
      </h3>
      <ul className="acpmux-summary-list">
        {shown && (
          <li>
            <button type="button" className="acpmux-summary-row acpmux-summary-link" onClick={() => onOpen(parent?.id)}>
              <Icon name="nav.back" size={ROW_ICON} row />
              <span className="acpmux-summary-text acpmux-lineage__name">{parent?.name ?? chat}</span>
              {parent && (
                <span className="acpmux-summary-meta acpmux-lineage__state">
                  {t(STATE_LABEL[parent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed)}
                </span>
              )}
            </button>
          </li>
        )}
        {live.map(row)}
        {ended.length > 0 && (
          <li>
            <button
              type="button"
              className="acpmux-summary-more acpmux-lineage__previous"
              aria-expanded={previous}
              onClick={() => setPrevious((open) => !open)}
            >
              <span>{t("summary.lineage.previous", { n: ended.length })}</span>
              <Icon name={previous ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
            </button>
          </li>
        )}
        {previous && ended.map(row)}
      </ul>
    </section>
  );
}
