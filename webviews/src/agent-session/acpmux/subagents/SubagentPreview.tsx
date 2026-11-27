// A subagent's hover preview: what its chip cuts (Leo, 2026-11-14, on a grouped "started working"
// row whose nine name chips were cut to a letter or two: "there's no hover preview on these").
// Pointing at a subagent's name chip, or focusing it from the keyboard, shows the card Session
// Info's Subagents list already shows for a line (session-info/SubagentsSection.tsx): its whole name,
// then its state, time, kind and progress, then its latest output (what it does now, else the last
// line it said), then its task, dim, two lines at most. The card is the shared hover card
// (ui/Tooltip.tsx with `ui-card`: the tooltip layer's glass, the warm group's timing), so it floats
// over the transcript and never moves a row. A click on the chip still opens the subagent, as the
// background tasks panel's lines do. Every chip that names a subagent wraps itself in
// ``SubagentChipPreview``: the start line (SubagentStartedLine.tsx, grouped or one), the end line
// (SubagentDoneLine.tsx, each of its looks). The running tray's lines name their task whole and keep
// their own title tooltip (SubagentTray.tsx `agentTooltip`).
import { cloneElement, type ReactElement, type ReactNode } from "react";
import { useConnectionQuietKeys } from "../../../ui/lasting";
import { Tooltip } from "../../../ui/Tooltip";
import { useT } from "../i18n";
import { subagentStateText, subagentStatus, type SubagentStatus } from "../summary/subagentStatusListModel";
import { useAgentProgress } from "./agentProgressStore";
import { isRepeatedAgentKind } from "./agentIdentityModel";
import { awaitsOwnWork, type Subagent } from "./subagentFold";
import { subagentTime, useNow } from "./subagentGroupModel";
import { subagentDisplayName, subagentTaskLabel } from "./subsessions";
import { latestLine } from "./trayDetail";

const NO_WAITING: ReadonlySet<string> = new Set();

/// The card's content, as Session Info's line and a chip's preview both draw it.
export function SubagentCardBody({
  name,
  status,
  state,
  latest,
  task,
}: {
  name: ReactNode;
  status: SubagentStatus;
  /// Its state, time, kind and progress, one muted line.
  state?: string;
  /// What it does now, or the last line it said.
  latest?: string;
  /// Its whole task, when its name is not that.
  task?: string;
}) {
  return (
    <span className="acpmux-agent-card">
      <span className="acpmux-agent-card__name">{name}</span>
      {state && (
        <span className="acpmux-agent-card__state" data-status={status}>
          {state}
        </span>
      )}
      {latest && <span className="acpmux-agent-card__latest">{latest}</span>}
      {task && <span className="acpmux-agent-card__task">{task}</span>}
    </span>
  );
}

/// What subagent `agent`'s card says. `name`: what its chip names it (its task's first line, else its
/// name: ``subagentTaskLabel``); `waiting`: the subagents waiting on the person, where the host knows.
export function SubagentPreviewCard({
  agent,
  name,
  waiting = NO_WAITING,
}: {
  agent: Subagent;
  name?: string;
  waiting?: ReadonlySet<string>;
}) {
  const t = useT();
  const progress = useAgentProgress(agent);
  // The session's clock as the card opens (it mounts on open): it shows for seconds, so it never ticks.
  const now = useNow(false);
  // A retry waits out the shared bound before the card says so (retryState.ts ``retryWords``).
  const connectionQuiet = useConnectionQuietKeys();
  const title = name ?? subagentTaskLabel(t, agent);
  const status = subagentStatus(agent, waiting, now);
  const own = subagentDisplayName(t, agent);
  const kind = agent.kind && agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined;
  const state = [
    subagentStateText(t, agent, waiting, connectionQuiet, now),
    subagentTime(agent, now),
    // Its own name, when its chip names it by its task.
    own !== title ? own : undefined,
    kind !== own ? kind : undefined,
    progress,
  ]
    .filter(Boolean)
    .join(" · ");
  const latest = agent.state === "failed" ? agent.error?.trim() : latestLine(t, agent, awaitsOwnWork(agent));
  const task = agent.task?.trim();
  return (
    <SubagentCardBody
      name={title}
      status={status}
      state={state}
      latest={latest && latest !== title ? latest : undefined}
      task={task && task !== title && task !== latest ? task : undefined}
    />
  );
}

/// `children` (a subagent's name chip, AgentTag) with `agent`'s preview on hover and keyboard focus.
/// The chip keeps its click; the line's own title tooltip stays off the chip (`data-tooltip=""`, which
/// ui/titleTooltips.ts reads as no text), so one card shows, never two.
export function SubagentChipPreview({
  agent,
  name,
  waiting,
  children,
}: {
  agent: Subagent;
  name?: string;
  waiting?: ReadonlySet<string>;
  children: ReactElement;
}) {
  return (
    // tooltip-allow: the chip cuts the subagent's name; its card names it whole, with its state and task
    <Tooltip
      label={<SubagentPreviewCard agent={agent} name={name} waiting={waiting} />}
      side="top"
      className="ui-card acpmux-agent-card__popup acpmux-subagent-preview"
    >
      {cloneElement(children, { "data-tooltip": "" } as Record<string, string>)}
    </Tooltip>
  );
}
