// The summary card's Subagents section (SummaryCard.tsx): every subagent of the chat, nested ones
// indented under the agent that spawned them, with its live state (running, waiting on the user,
// done, failed) and its time. A row shows that subagent (`onOpen`): its pane when it has one. Its
// title opens the card's Subagents tab (`onShowAll`, SubagentsTab.tsx). The sub-sessions the chat's
// agent started with its `start_session` tool (subagents/subsessions.ts) follow, theirs indented under
// each, with their live state, an unread dot, how many messages wait for them and what a working
// one does now; a click opens its chat beside this one (`onOpenSession`). After them, the other
// chats the agent started (`sessions`, inspector/ChildSessionRows.tsx), each opening its chat.
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { formatDuration } from "../conversation/turns";
import { AgentLine } from "../subagents/AgentLine";
import { useT, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { elapsed, running, STATE_LABEL, useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { retrying, retryLabel, sessionRetry } from "../subagents/retryState";
import { Spinner } from "../conversation/icons";
import {
  SUBSESSION_STATE_LABEL,
  type SubsessionRow,
  type SubsessionState,
  waitingLine,
} from "../subagents/subsessions";
import type { StartedSession } from "../started/startedSessions";
import { ChildSessionRows, sessionStatus } from "../inspector/ChildSessionRows";
import type { SummarySubagent } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";

const ROW_ICON = rowIconSize(12);
const NO_SESSIONS: readonly StartedSession[] = [];
const NO_STACK: readonly SummarySubagent[] = [];

/// What a row says of its subagent: a subagent that asks the user for a permission or an answer
/// is waiting on them, not running; a cancelled (stopped by the person) or disconnected (lost by
/// acpmux) one is stopped: it ended without its result, but did not fail.
export type SubagentStatus = "running" | "waiting" | "done" | "failed" | "stopped";

export const STATUS_LABEL: Record<SubagentStatus, StringKey> = {
  running: "subagents.state.running",
  waiting: "subagents.state.waiting",
  done: "subagents.state.completed",
  failed: "subagents.state.failed",
  stopped: "subagents.state.cancelled",
};

export function subagentStatus(agent: Subagent, waiting: ReadonlySet<string>): SubagentStatus {
  if (running(agent)) return waiting.has(agent.id) ? "waiting" : "running";
  // acpmux waits to retry it (subagents/retryState.ts): it is about to run again.
  if (retrying(agent)) return "running";
  if (agent.state === "completed") return "done";
  return agent.state === "cancelled" || agent.state === "disconnected" ? "stopped" : "failed";
}

/// The label of a subagent's status: a stopped one says how it stopped (Cancelled, Disconnected),
/// as its transcript row does.
export function subagentStatusLabel(agent: Subagent, waiting: ReadonlySet<string>): StringKey {
  const status = subagentStatus(agent, waiting);
  if (status !== "stopped") return STATUS_LABEL[status];
  return agent.state === "disconnected" ? STATE_LABEL.disconnected : STATE_LABEL.cancelled;
}

/// What a subagent's line says of its state: acpmux's retry while one waits ("Retrying (2/4) after a
/// capacity error"), else its status's word.
export function subagentStateText(t: Translate, agent: Subagent, waiting: ReadonlySet<string>): string {
  const retry = retrying(agent);
  return retry ? retryLabel(t, retry) : t(subagentStatusLabel(agent, waiting));
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
      if (item.state === "pending") {
        const request = item.request as {
          toolCall?: { toolCallId?: unknown };
          subject?: { type?: unknown; toolCall?: { toolCallId?: unknown } };
        };
        add(
          request.toolCall?.toolCallId ??
            (request.subject?.type === "tool_call" ? request.subject.toolCall?.toolCallId : undefined),
        );
      }
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
  const rank = (agent: Subagent) =>
    ({ waiting: 0, running: 1, done: 2, failed: 2, stopped: 2 })[subagentStatus(agent, waiting)];
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

/// A sub-session's state as a subagent row's status, for the row's dot and the card's counts.
export const SUBSESSION_STATUS: Record<SubsessionState, SubagentStatus> = {
  working: "running",
  input: "waiting",
  failed: "failed",
  done: "done",
};

export function SubagentStatusList({
  agents,
  waiting,
  current,
  onOpen,
  autoOpen,
  onShowAll,
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
  /// The other chats the agent started, after the sub-sessions.
  sessions?: readonly StartedSession[];
  /// Subagents an older record names only by their Task calls (sessionSummary.ts), as one line,
  /// when acpmux reports none.
  stack?: readonly SummarySubagent[];
}) {
  const t = useT();
  const now = useNow(agents.some(running));
  const title = t("summary.subagents");
  const live =
    agents.filter((agent) => subagentStatus(agent, waiting) === "running").length +
    subsessions.filter((session) => session.state === "working" || sessionRetry(session).kind === "retrying").length +
    sessions.filter((child) => sessionStatus(child) === "running").length;
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
        {agents.length === 0 && stack.length > 0 && <SubagentStack subagents={stack} />}
        {ordered(agents, waiting).map(({ agent, depth }) => {
          const status = subagentStatus(agent, waiting);
          return (
            <li key={agent.id}>
              {/* The tray's own line (subagents/AgentLine.tsx): a subagent reads the same here and above the composer. */}
              <AgentLine
                name={agent.name}
                detail={agent.kind}
                mark={agent.harness}
                status={status}
                state={subagentStateText(t, agent, waiting)}
                working={Boolean(retrying(agent))}
                time={formatDuration(elapsed(agent, now))}
                iconSize={ROW_ICON}
                depth={depth}
                current={agent.id === current}
                title={agent.task}
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
        <Icon name="agent.session" size={ROW_ICON} row />
      </span>
      <span className="acpmux-summary-text">
        <span className="acpmux-summary-agent__name">{session.name}</span>
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
