// The Inspector's Subagents, as Claude Code desktop's session panel lists them: what runs is named,
// one row each, and what ended is one row. The harness's own subagents and the chats its agent
// started (ChildSessionRows.tsx; a Cloud VM's or another machine's included) share the list. Each
// running one is a line of its own (subagents/AgentLine.tsx, the tray's): its name, what it does
// now, how long it has run and its state, Waiting ones first; past five, "View all" opens the
// rest. The ones that ended are one row, "94 done · 1 failed", that opens into their lines, failed
// first. Every line opens what it names: a subagent's pane or view (App.tsx `showSubagent`), a chat
// beside this one (`chat.offer.open`); its hover card names it and says its state and its task. The
// running lines' icons share one shimmer that sweeps down them (ui/wave.ts); the ended ones stay
// still. The live counts sit in the section's head ("3 running · 40 done", `subagentCounts`). Leo
// 2026-10-21: the row of identical avatars it replaces opened nothing anyone could tell apart.
import { useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT, type Translate } from "../i18n";
import { waveIndices } from "../../../ui/wave";
import { Icon } from "../icons/Icon";
import type { StartedSession } from "../started/startedSessions";
import { AgentLine } from "../subagents/AgentLine";
import { nestAgents } from "../subagents/AgentsPill";
import { elapsed, running, useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { subagentStatus, subagentStatusLabel, type SubagentStatus } from "../summary/SubagentStatusList";
import { orderedSessions, sessionStatus, sessionStateLabel } from "./ChildSessionRows";
import type { InspectorListMode } from "./OutputsSection";

/// Running lines shown before "View all", as Claude Code desktop's panel caps its list.
export const SUBAGENTS_SHOWN = 5;
const NO_SESSIONS: readonly StartedSession[] = [];
const ENDED_SHOWN = 6;

/// "1 waiting · 3 running · 40 done" for the section's head, the started chats counted with the
/// subagents, or nothing for neither.
export function subagentCounts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
): string {
  const count = (status: SubagentStatus) =>
    agents.filter((agent) => subagentStatus(agent, waiting) === status).length +
    sessions.filter((child) => sessionStatus(child) === status).length;
  return [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ]
    .filter(Boolean)
    .join(" · ");
}

/// "94 done · 1 failed": the ended row's words, the done ones first as Leo asked for them (its
/// list below leads with the failed ones).
function endedCounts(t: Translate, lines: readonly Line[]): string {
  const count = (status: SubagentStatus) => lines.filter((line) => line.status === status).length;
  return [
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
  ]
    .filter(Boolean)
    .join(" · ");
}

/// One line of the list: a subagent or a started chat, as AgentLine draws it.
type Line = {
  key: string;
  name: string;
  detail?: string;
  status: SubagentStatus;
  state: string;
  time?: string;
  /// Its whole task, for the hover card.
  task?: string;
  icon: string;
  depth: number;
  /// When it ended (or, for a chat, was made): the ended list's order.
  at: number;
  open?: () => void;
};

const live = (status: SubagentStatus) => status === "running" || status === "waiting";
/// The ended list's order: a failed one first, then a stopped one, then the done ones.
const ENDED_RANK: Record<SubagentStatus, number> = { failed: 0, stopped: 1, done: 2, running: 3, waiting: 3 };

export function SubagentsSection({
  agents,
  waiting,
  onOpen,
  sessions = NO_SESSIONS,
  onOpenSession,
  listMode = "view-all",
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  /// Shows a subagent (App.tsx `showSubagent`); without it a subagent's line opens nothing.
  onOpen?: (id: string) => void;
  /// The chats the agent started, and how one opens.
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
  /// Gallery-only alternatives for the long-list treatment.
  listMode?: InspectorListMode;
}) {
  const t = useT();
  const now = useNow(agents.some(running));
  const [more, setMore] = useState(false);
  const [endedOpen, setEndedOpen] = useState(false);
  const [endedAll, setEndedAll] = useState(false);
  const agentLine = (agent: Subagent, depth: number): Line => {
    const status = subagentStatus(agent, waiting);
    return {
      key: `agent:${agent.id}`,
      name: agent.name,
      detail: live(status) ? (agent.action ?? agent.kind) : agent.kind,
      status,
      state: t(subagentStatusLabel(agent, waiting)),
      time: formatDuration(elapsed(agent, now)),
      task: agent.task,
      icon: "agent.session",
      depth,
      at: agent.endedAt ?? agent.startedAt,
      open: onOpen && (() => onOpen(agent.id)),
    };
  };
  const sessionLine = (child: StartedSession): Line => ({
    key: `session:${child.sessionId}`,
    name: child.title,
    status: sessionStatus(child),
    state: t(sessionStateLabel(child)),
    icon: "agent.chat",
    depth: 0,
    at: child.createdAt ?? 0,
    open: onOpenSession && (() => onOpenSession(child.sessionId)),
  });
  // The chats waiting on the person lead, then the running subagents in the tray's order (oldest
  // first, a nested one under its parent; among siblings a waiting one first, so it never leaves its
  // parent), then the running chats.
  const waitsFirst = (a: Subagent, b: Subagent) =>
    Number(subagentStatus(b, waiting) === "waiting") - Number(subagentStatus(a, waiting) === "waiting") ||
    a.startedAt - b.startedAt;
  const runningAgents = nestAgents(agents.filter((agent) => live(subagentStatus(agent, waiting))).sort(waitsFirst)).map(
    ({ agent, depth }) => agentLine(agent, depth),
  );
  const children = orderedSessions(sessions);
  const runningLines = [
    ...children.filter((child) => sessionStatus(child) === "waiting").map(sessionLine),
    ...runningAgents,
    ...children.filter((child) => sessionStatus(child) === "running").map(sessionLine),
  ];
  const endedLines = [
    ...agents.filter((agent) => !live(subagentStatus(agent, waiting))).map((agent) => agentLine(agent, 0)),
    ...children.filter((child) => !live(sessionStatus(child))).map(sessionLine),
  ].sort((a, b) => ENDED_RANK[a.status] - ENDED_RANK[b.status] || b.at - a.at);
  const shown = listMode === "view-all" && !more ? runningLines.slice(0, SUBAGENTS_SHOWN) : runningLines;
  // Each running line's place in the wave, top to bottom; the ended lines take none.
  const wave = waveIndices(shown, (item) => live(item.status));
  const line = (item: Line, index: number, inWave: boolean) => (
    <li key={item.key}>
      <AgentLine
        name={item.name}
        detail={item.detail}
        status={item.status}
        state={item.state}
        time={item.time}
        icon={item.icon}
        depth={item.depth}
        onOpen={item.open}
        wave={inWave ? wave[index] : undefined}
        card={
          <span className="acpmux-agent-card">
            <span className="acpmux-agent-card__name">{item.name}</span>
            <span className="acpmux-agent-card__state" data-status={item.status}>
              {[item.state, item.time, item.status === "running" || item.status === "waiting" ? item.detail : undefined]
                .filter(Boolean)
                .join(" · ")}
            </span>
            {item.task && item.task !== item.name && <span className="acpmux-agent-card__task">{item.task}</span>}
          </span>
        }
      />
    </li>
  );
  return (
    <div className="acpmux-chat-inspector-subagents">
      {runningLines.length > 0 && (
        <ul className="acpmux-summary-list acpmux-chat-inspector-subagents__running">
          {shown.map((item, index) => line(item, index, true))}
        </ul>
      )}
      {listMode === "view-all" && runningLines.length > SUBAGENTS_SHOWN && (
        <button
          type="button"
          className="acpmux-chat-inspector-fold acpmux-chat-inspector-subagents__more"
          aria-expanded={more}
          onClick={() => setMore(!more)}
        >
          {more ? t("summary.showFewer") : t("summary.viewAll", { n: runningLines.length })}
        </button>
      )}
      {endedLines.length > 0 && (
        <>
          <button
            type="button"
            className="acpmux-summary-row acpmux-summary-link acpmux-chat-inspector-subagents__ended"
            aria-expanded={endedOpen}
            onClick={() => setEndedOpen(!endedOpen)}
          >
            <span className="acpmux-lineage__icon" data-state={endedLines[0]!.status}>
              <Icon name={endedLines[0]!.icon} size={14} />
            </span>
            <span className="acpmux-summary-text">{endedCounts(t, endedLines)}</span>
            <Icon name={endedOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
          </button>
          {endedOpen && (
            <ul
              className="acpmux-summary-list acpmux-chat-inspector-scroll acpmux-chat-inspector-subagents__list"
              data-list-mode={listMode}
            >
              {(listMode === "view-all" && !endedAll ? endedLines.slice(0, ENDED_SHOWN) : endedLines).map(
                (item, index) => line(item, index, false),
              )}
              {listMode === "view-all" && endedLines.length > ENDED_SHOWN && (
                <li>
                  <button type="button" className="acpmux-chat-inspector-fold" onClick={() => setEndedAll(!endedAll)}>
                    {endedAll ? t("summary.showFewer") : t("summary.viewAll", { n: endedLines.length })}
                  </button>
                </li>
              )}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
