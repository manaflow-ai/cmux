// The summary card's Subagents section (SummaryCard.tsx): every subagent of the chat, nested ones
// indented under the agent that spawned them, with its live state (running, waiting on the user,
// done, failed) and its time. A row shows that subagent (`onOpen`): in a pane of its own while
// the section's switch is on, else in the chat. Its title opens the card's Subagents tab (`onShowAll`, SubagentsTab.tsx). The sub-sessions the chat's
// agent started with its `start_session` tool (subagents/subsessions.ts) follow, theirs indented under
// each, with their live state, an unread dot, how many messages wait for them and what a working
// one does now; a click opens its chat beside this one (`onOpenSession`). After them, the other
// chats the agent started (`sessions`, session-info/ChildSessionRows.tsx), each opening its chat.
import { useContext } from "react";

import { formatDuration } from "../conversation/turns";
import { AgentLine } from "../subagents/AgentLine";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { elapsed, SubagentHarnessContext, ticking, useNow } from "../subagents/SubagentGroup";
import { type Subagent } from "../subagents/subagentFold";

import { retrying, retryLabel, sessionRetry } from "../subagents/retryState";
import { Spinner } from "../conversation/icons";
import {
  SUBSESSION_STATE_LABEL,
  subsessionDisplayName,
  type SubsessionRow,
  waitingLine,
} from "../subagents/subsessions";
import type { StartedSession } from "../started/startedSessions";
import { ChildSessionRows, sessionStatus } from "../session-info/ChildSessionRows";
import type { SummarySubagent } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";
import { AgentIdentity, foreignHarness, isRepeatedAgentKind, SUBAGENT_FALLBACK } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import { orderedSubagents } from "./subagentOrder";
import { subagentStatus, subagentStateText, SUBSESSION_STATUS } from "./subagentStatusListModel";

const ROW_ICON = rowIconSize(12);
const NO_SESSIONS: readonly StartedSession[] = [];
const NO_STACK: readonly SummarySubagent[] = [];

/// Depth-first, attention first; the indexed walk also keeps malformed orphan/cycle records visible.
function ordered(agents: readonly Subagent[], waiting: ReadonlySet<string>): { agent: Subagent; depth: number }[] {
  return orderedSubagents(
    agents,
    (agent) => ({ waiting: 0, running: 1, idle: 1, done: 2, failed: 2, stopped: 2 })[subagentStatus(agent, waiting)],
  );
}

export function SubagentStatusList({
  agents,
  waiting,
  current,
  onOpen,
  autoOpen,
  onShowAll,
  counts,
  onOpenInPane,
  subsessions = [],
  onOpenSession,
  sessions = NO_SESSIONS,
  stack = NO_STACK,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  /// The chat's sub-sessions, after its subagents (subagents/subsessions.ts `subsessionRows`).
  subsessions?: readonly SubsessionRow[];
  /// Opens a sub-session's or a started chat's chat beside this one.
  onOpenSession?: (sessionId: string) => void;
  /// The subagent this pane shows, if any.
  current?: string;
  onOpen?: (id: string) => void;
  /// The switch for opening new subagents in panes of their own (subagents/subagentPanes.ts).
  autoOpen?: { on: boolean; set: (on: boolean) => void };
  /// Opens the card's Subagents tab; the title is a button only with it.
  onShowAll?: () => void;
  /// Overall activity counts move here when the popover has no title row.
  counts?: string;
  /// Opens Session Info's complete Subagents section beside the chat.
  onOpenInPane?: () => void;
  /// The other chats the agent started, after the sub-sessions.
  sessions?: readonly StartedSession[];
  /// Subagents an older record names only by their Task calls (sessionSummary.ts), as one line,
  /// when acpmux reports none.
  stack?: readonly SummarySubagent[];
}) {
  const t = useT();
  const chatHarness = useContext(SubagentHarnessContext);
  const now = useNow(agents.some(ticking));
  const title = t("summary.subagents");
  const live =
    agents.filter((agent) => subagentStatus(agent, waiting) === "running").length +
    subsessions.filter((session) => session.state === "working" || sessionRetry(session).kind === "retrying").length +
    sessions.filter((child) => sessionStatus(child) === "running").length;
  const heading = counts
    ? `${title} · ${counts}`
    : live > 0
      ? `${title} · ${t("summary.subagents.running", { n: live })}`
      : title;
  return (
    <section className="acpmux-summary-section acpmux-summary-agents" aria-label={title}>
      <h3 className="acpmux-summary-title">
        {onShowAll ? (
          <button type="button" className="acpmux-summary-title__button" onClick={onShowAll}>
            <span className="acpmux-summary-title__text">{heading}</span>
            <Icon name="disclosure.collapsed" size={12} />
          </button>
        ) : (
          heading
        )}
      </h3>
      <ul className="acpmux-summary-list">
        {agents.length === 0 && stack.length > 0 && <SubagentStack subagents={stack} />}
        {ordered(agents, waiting).map(({ agent, depth }) => {
          const status = subagentStatus(agent, waiting);
          return (
            <li key={agent.id}>
              {/* The tray's own line (subagents/AgentLine.tsx): a subagent reads the same here and above the composer. */}
              <AgentLine
                name={agent.name}
                icon={SUBAGENT_FALLBACK}
                mark={foreignHarness(agent.harness, chatHarness)}
                status={status}
                state={subagentStateText(t, agent, waiting)}
                working={Boolean(retrying(agent))}
                time={formatDuration(elapsed(agent, now))}
                iconSize={ROW_ICON}
                depth={depth}
                current={agent.id === current}
                // Its kind is no subtitle on the line (Leo, 2026-10-31: "a lot of these subtitles
                // are bad"): the tooltip keeps it under its task.
                title={
                  [agent.task, agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined]
                    .filter(Boolean)
                    .join("\n") || undefined
                }
                tone={agentTone(agent.id)}
                onOpen={onOpen ? () => onOpen(agent.id) : undefined}
              />
            </li>
          );
        })}
        {subsessions.map((session) => (
          <li key={`session:${session.sessionId}`}>
            <SubsessionStatusRow session={session} onOpen={onOpenSession} />
          </li>
        ))}
        <ChildSessionRows sessions={sessions} onOpen={onOpenSession} />
      </ul>
      {onOpenInPane && (agents.length > 0 || subsessions.length > 0 || sessions.length > 0) && (
        <button type="button" className="acpmux-summary-more" onClick={onOpenInPane}>
          <Icon name="pane.split.right" size={ROW_ICON} row />
          {t("summary.openInPane")}
        </button>
      )}
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

/// A sub-session's row: its name (and what it does now while it works, or what it waits on the
/// person for), its unread dot, how many messages wait for it, and its state.
function SubsessionStatusRow({ session, onOpen }: { session: SubsessionRow; onOpen?: (sessionId: string) => void }) {
  const t = useT();
  // While acpmux retries its failed turn, it works again (subagents/retryState.ts ``sessionRetry``).
  const phase = sessionRetry(session);
  const retry = phase.kind === "retrying" ? phase.retry : undefined;
  const status = retry ? SUBSESSION_STATUS.working : SUBSESSION_STATUS[session.state];
  // What a working one does now, or what one waiting on the person waits for.
  const line = session.waiting ? waitingLine(t, session.waiting) : session.doing;
  return (
    <button
      type="button"
      className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-summary-subsession"
      style={session.depth > 0 ? { paddingLeft: 8 + session.depth * 14 } : undefined}
      data-status={status}
      /* tooltip-allow: the row shows the name; what a working one does may be cut */
      title={line}
      disabled={!onOpen}
      onClick={() => onOpen?.(session.sessionId)}
    >
      <span className="acpmux-lineage__icon" data-state={status}>
        <AgentIdentity harness={session.harness} tone={agentTone(session.sessionId)} size={ROW_ICON} />
      </span>
      <span className="acpmux-summary-text">
        <span className="acpmux-summary-agent__name">{subsessionDisplayName(t, session)}</span>
        {line && <span className="acpmux-summary-agent__kind">{line}</span>}
      </span>
      {session.unread && (
        <span className="acpmux-summary-subsession__unread">
          <span className="sr-only">{t("sidebar.markUnread")}</span>
        </span>
      )}
      {session.queued ? (
        <span className="acpmux-summary-meta">{t("subsession.queued", { n: session.queued })}</span>
      ) : null}
      <span className="acpmux-summary-meta acpmux-summary-agent__state">
        {retry && <Spinner size={12} loading />}
        {retry ? retryLabel(t, retry) : t(SUBSESSION_STATE_LABEL[session.state])}
      </span>
    </button>
  );
}
