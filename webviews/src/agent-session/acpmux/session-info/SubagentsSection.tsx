// Session Info's Subagents, as Claude Code desktop's session panel lists them: what runs is named,
// one row each, and what ended is one row. The harness's own subagents and the chats its agent
// started (ChildSessionRows.tsx; a Cloud VM's or another machine's included) share the list. Each
// running one is a line of its own (subagents/AgentLine.tsx, the tray's): its name, what it does
// now, how long it has run and its state, Waiting ones first; past five, "Show more" opens the
// rest. The ones that ended are one row, "94 done · 1 failed", that opens into their lines, failed
// first. Every line opens what it names: a subagent's pane or view (App.tsx `showSubagent`), a chat
// beside this one (`chat.offer.open`); its hover card names it and says its state and its task. The
// running lines' icons share one shimmer that sweeps down them (ui/wave.ts); the ended ones stay
// still. The live counts sit in the section's head ("3 running · 40 done", `subagentCounts`). Leo
// 2026-10-21: the row of identical avatars it replaces opened nothing anyone could tell apart.
import { memo, useState } from "react";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { waveIndices } from "../../../ui/wave";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
const ROW_ICON = rowIconSize(12);

import type { StartedSession } from "../started/startedSessions";
import { AgentLine } from "../subagents/AgentLine";
import { isRepeatedAgentKind } from "../subagents/AgentIdentity";
import { subagentProgress } from "../subagents/subagentProgress";
import { nestAgents } from "../subagents/AgentsPill";
import { Avatar, elapsed, running, useNow } from "../subagents/SubagentGroup";
import { agentTone } from "../subagents/agentTones";
import type { Subagent } from "../subagents/subagentFold";
import { retrying } from "../subagents/retryState";
import { subagentStateText, subagentStatus, type SubagentStatus } from "../summary/SubagentStatusList";
import { orderedSessions, sessionStatus, sessionStateText } from "./ChildSessionRows";
import "./SubagentsSection.css";
import { SessionInfoFold } from "./SessionInfoSection";
import { AgentMark } from "../../shared/AgentMark";
import { TonedIcon } from "../subagents/TonedIcon";

/// Running lines shown before "Show more", as Claude Code desktop's panel caps its list.
export const SUBAGENTS_SHOWN = 5;
const NO_SESSIONS: readonly StartedSession[] = [];

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
  identity: string;
  agent?: Subagent;
  name: string;
  detail?: string;
  /// The kind of agent it is, for the hover card.
  kind?: string;
  progress?: string;
  status: SubagentStatus;
  state: string;
  /// acpmux retries it: its line shows the turning ring (retryState.ts).
  working?: boolean;
  time?: string;
  /// Its whole task, for the hover card.
  task?: string;
  icon: string;
  /// The harness whose mark it draws (the agent's own, else the chat's for its own subagents).
  mark?: string;
  depth: number;
  /// When it ended (or, for a chat, was made): the ended list's order.
  at: number;
  open?: () => void;
};

const live = (status: SubagentStatus) => status === "running" || status === "waiting";
/// The ended list's order: a failed one first, then a stopped one, then the done ones.
const ENDED_RANK: Record<SubagentStatus, number> = { failed: 0, stopped: 1, done: 2, running: 3, waiting: 3 };

// Streaming rows/views recreate the folded agents. Compare only the bounded preview's visual
// inputs so those snapshots do not render its Avatars or hash their tones again. Avatar's harness
// context and AgentMark's theme subscription still update independently through this memo boundary.
const EndedAvatars = memo(
  function EndedAvatars({ items }: { items: readonly Line[]; count: number }) {
    return (
      <span className="acpmux-session-info-subagents__avatars" aria-hidden="true">
        {items.map((item) => (
          <span key={item.key} data-agent-tone={agentTone(item.identity)}>
            {item.agent ? (
              <Avatar agent={item.agent} />
            ) : (
              <span className="cv-subagent-avatar" data-state={item.status}>
                {item.mark ? (
                  <AgentMark
                    agent={item.mark}
                    size={14}
                    fallback={<TonedIcon name={item.icon} size={14} tone={agentTone(item.identity)} />}
                  />
                ) : (
                  <TonedIcon name={item.icon} size={14} tone={agentTone(item.identity)} />
                )}
              </span>
            )}
          </span>
        ))}
      </span>
    );
  },
  (before, after) =>
    before.count === after.count &&
    before.items.length === after.items.length &&
    before.items.every((item, index) => {
      const next = after.items[index]!;
      return (
        item.key === next.key &&
        item.identity === next.identity &&
        item.status === next.status &&
        item.working === next.working &&
        item.icon === next.icon &&
        item.mark === next.mark &&
        item.agent?.state === next.agent?.state &&
        item.agent?.harness === next.agent?.harness
      );
    }),
);

export function SubagentsSection({
  agents,
  waiting,
  onOpen,
  sessions = NO_SESSIONS,
  onOpenSession,
  harness,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  /// Shows a subagent (App.tsx `showSubagent`); without it a subagent's line opens nothing.
  onOpen?: (id: string) => void;
  /// The chats the agent started, and how one opens.
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
  /// The chat's harness: its own subagents (Claude's Agent calls) draw its mark (Leo, 2026-10-29:
  /// "surely you can just at least say, you know, one of these is Codex, one of these is Claude").
  harness?: string;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const now = useNow(agents.some(running));
  const [more, setMore] = useState(false);
  const [endedOpen, setEndedOpen] = useState(false);
  const agentLine = (agent: Subagent, depth: number): Line => {
    const status = subagentStatus(agent, waiting);
    return {
      key: `agent:${agent.id}`,
      identity: agent.id,
      agent,
      name: agent.name,
      progress: subagentProgress(t, language, agent, { usage: false }).join(" · "),
      // What it does now, while it runs; its kind (Explore, general-purpose) is no subtitle on the
      // line (Leo, 2026-10-31: "a lot of these subtitles are bad"): the hover card keeps it.
      detail: live(status) ? agent.action : undefined,
      kind: agent.kind && agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined,
      status,
      state: subagentStateText(t, agent, waiting),
      working: Boolean(retrying(agent)),
      time: formatDuration(elapsed(agent, now)),
      task: agent.task,
      icon: "agent.session",
      mark: agent.harness ?? harness,
      depth,
      at: agent.endedAt ?? agent.startedAt,
      open: onOpen && (() => onOpen(agent.id)),
    };
  };
  const sessionLine = (child: StartedSession): Line => ({
    key: `session:${child.sessionId}`,
    identity: child.sessionId,
    name: child.title,
    status: sessionStatus(child),
    ...(({ text, working }) => ({ state: text, working }))(sessionStateText(t, child)),
    icon: "agent.chat",
    mark: child.harness,
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
  const shown = more ? runningLines : runningLines.slice(0, SUBAGENTS_SHOWN);
  // Each running line's place in the wave, top to bottom; the ended lines take none.
  const wave = waveIndices(shown, (item) => live(item.status));
  const line = (item: Line, index: number, inWave: boolean) => (
    <li key={item.key}>
      <AgentLine
        name={item.name}
        detail={item.detail}
        progress={item.progress}
        status={item.status}
        state={item.state}
        working={item.working}
        time={item.time}
        icon={item.icon}
        mark={item.mark}
        tone={agentTone(item.identity)}
        depth={item.depth}
        onOpen={item.open}
        wave={inWave ? wave[index] : undefined}
        card={
          <span className="acpmux-agent-card">
            <span className="acpmux-agent-card__name">{item.name}</span>
            <span className="acpmux-agent-card__state" data-status={item.status}>
              {[
                item.state,
                item.time,
                item.kind,
                item.progress,
                item.status === "running" || item.status === "waiting" ? item.detail : undefined,
              ]
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
    <div className="acpmux-session-info-subagents">
      {runningLines.length > 0 && (
        <ul className="acpmux-summary-list acpmux-session-info-subagents__running">
          {shown.map((item, index) => line(item, index, true))}
        </ul>
      )}
      {runningLines.length > SUBAGENTS_SHOWN && (
        <SessionInfoFold className="acpmux-session-info-subagents__more" open={more} onToggle={() => setMore(!more)}>
          {more
            ? t("sessionInfo.subagents.less")
            : t("sessionInfo.subagents.more", { n: runningLines.length - SUBAGENTS_SHOWN })}
        </SessionInfoFold>
      )}
      {endedLines.length > 0 && (
        <>
          <button
            type="button"
            className="acpmux-summary-row acpmux-summary-link acpmux-session-info-subagents__ended"
            aria-expanded={endedOpen}
            onClick={() => setEndedOpen(!endedOpen)}
          >
            <EndedAvatars items={endedLines.slice(0, 4)} count={endedLines.length} />
            <span className="acpmux-summary-text">{endedCounts(t, endedLines)}</span>
            <Icon name={endedOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </button>
          {endedOpen && (
            <ul className="acpmux-summary-list acpmux-session-info-scroll acpmux-session-info-subagents__list">
              {endedLines.map((item, index) => line(item, index, false))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
