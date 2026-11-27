// The summary card's Subagents section (SummaryCard.tsx): every subagent of the chat, nested ones
// indented under the agent that spawned them, with its live state (running, waiting on the user,
// done, failed) and its time. A row shows that subagent (`onOpen`): in a pane of its own while
// the section's switch is on, else in the chat. Its title opens the card's Subagents tab (`onShowAll`, SubagentsTab.tsx). The sub-sessions the chat's
// agent started with its `start_session` tool (subagents/subsessions.ts) follow, theirs indented under
// each, with their live state, an unread dot, how many messages wait for them and what a working
// one does now; a click opens its chat beside this one (`onOpenSession`). After them, the other
// chats the agent started (`sessions`, session-info/ChildSessionRows.tsx), each opening its chat.
import { useContext, memo } from "react";
import { useConnectionQuietKeys } from "../../../ui/lasting";

import { formatDuration } from "../conversation/turns";
import { AgentLine } from "../subagents/AgentLine";
import { ResumeControl, type ResumeActions } from "../subagents/ResumeControl";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { elapsed, SubagentHarnessContext, ticking, useNow } from "../subagents/subagentGroupModel";
import { type Subagent } from "../subagents/subagentFold";
import { sameAgentRowProps } from "../subagents/subagentLook";
import { sameValue } from "../session-info/sameValue";

import { retrying, retryLabel, sessionRetry, sessionRetryKey } from "../subagents/retryState";
import { WaitSpinner } from "../conversation/WaitSpinner";
import { Spinner } from "../conversation/Spinner";
import {
  SUBSESSION_STATE_LABEL,
  subsessionDisplayName,
  type SubsessionRow,
  waitingLine,
} from "../subagents/subsessions";
import type { StartedSession } from "../started/startedSessions";
import { ChildSessionRows } from "../session-info/ChildSessionRows";
import { sessionStatus } from "../session-info/childSessionRowsModel";
import type { SummarySubagent } from "./sessionSummary";
import { SubagentStack } from "./SubagentStack";
import { CountLine, live as liveCount, type CountPart } from "./LiveCount";
import { AgentIdentity } from "../subagents/AgentIdentity";
import { foreignHarness, isRepeatedAgentKind, SUBAGENT_FALLBACK } from "../subagents/agentIdentityModel";
import { agentTone } from "../subagents/agentTones";
import { useSenderIconLook } from "../subagents/senderIconLook";
import { orderedSubagents } from "./subagentOrder";
import { subagentStatus, subagentStateText, SUBSESSION_STATUS } from "./subagentStatusListModel";
import { WindowedRows } from "../session-info/WindowedRows";

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
  resume,
}: {
  agents: readonly Subagent[];
  /// Resume on a stopped subagent's line (subagents/ResumeControl.tsx), as its end line offers it.
  resume?: ResumeActions;
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
  /// Overall activity counts move here when the popover has no title row (the running ones as their
  /// mark and number, LiveCount.tsx).
  counts?: readonly CountPart[];
  /// Opens Session Info's complete Subagents section beside the chat.
  onOpenInPane?: () => void;
  /// The other chats the agent started, after the sub-sessions.
  sessions?: readonly StartedSession[];
  /// Subagents an older record names only by their Task calls (sessionSummary.ts), as one line,
  /// when acpmux reports none.
  stack?: readonly SummarySubagent[];
}) {
  // The badge look picks which subagents show their family mark (foreignHarness): read here, so a
  // change of the setting draws them again.
  const senderBadge = useSenderIconLook().badge;
  const t = useT();
  const chatHarness = useContext(SubagentHarnessContext);
  const title = t("summary.subagents");
  const live =
    agents.filter((agent) => subagentStatus(agent, waiting) === "running").length +
    subsessions.filter((session) => session.state === "working" || sessionRetry(session).kind === "retrying").length +
    sessions.filter((child) => sessionStatus(child) === "running").length;
  // Every subagent, drawn only as far as the card's body (a scroller) shows and a few past it, over a box
  // as tall as the rest that its scroll reaches; the rest draw as it scrolls to them (WindowedRows). A
  // coordinator's card drew every subagent its chat ever ran (chat-100k-flat CASES=coordinator: 2,386
  // card body elements at 20k records, 11,772 at 100k).
  const lines = ordered(agents, waiting);
  // Each row a memo boundary with its own clock (SubagentStatusRow): a tick draws only the running rows.
  const agentRow = ({ agent, depth }: { agent: Subagent; depth: number }) => (
    <SubagentStatusRow
      key={agent.id}
      agent={agent}
      depth={depth}
      waits={waiting.has(agent.id)}
      current={agent.id === current}
      mark={foreignHarness(agent.harness, chatHarness, senderBadge)}
      onOpen={onOpen}
      resume={resume}
    />
  );
  // The running ones are their mark and their number, no word (LiveCount.tsx).
  const parts = counts?.length ? counts : [liveCount(live, t("summary.subagents.running", { n: live }))];
  const shown = parts.filter((part): part is CountPart => part !== false);
  const heading =
    shown.length > 0 ? (
      <>
        {title} · <CountLine parts={shown} />
      </>
    ) : (
      title
    );
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
      {/* The subagents' list, then the rest's: two lists with no margin or padding draw as one, and the
          windowed rows' box ends their own list (WindowedRows reads its last row as the list's). */}
      <ul className="acpmux-summary-list">
        {agents.length === 0 && stack.length > 0 && <SubagentStack subagents={stack} />}
        <WindowedRows items={lines} render={agentRow} />
      </ul>
      <ul className="acpmux-summary-list">
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
      {autoOpen && <AutoOpenSwitch on={autoOpen.on} set={autoOpen.set} label={t("summary.subagents.openPanes")} />}
    </section>
  );
}

/// The switch for opening new subagents in panes, drawn again only when its setting or label changes.
/// The list above re-renders on the page clock while a subagent runs, and React 19 writes an input's
/// `name` and `type` on every render of it (ReactDOMInput `updateInput`), so drawn inline it took
/// three attribute writes a second in an idle chat, each an edge mark on the card's scroller
/// (summary-card-idle-attributes.test.tsx). Its setter is the page's one module function
/// (subagents/subagentPanes.ts `setAutoOpen`), so the memo holds.
const AutoOpenSwitch = memo(function AutoOpenSwitch({
  on,
  set,
  label,
}: {
  on: boolean;
  set: (on: boolean) => void;
  label: string;
}) {
  return (
    <label className="acpmux-summary-row acpmux-summary-autoopen">
      <input type="checkbox" aria-label={label} checked={on} onChange={(event) => set(event.currentTarget.checked)} />
      <span className="acpmux-summary-text">{label}</span>
    </label>
  );
});

/// A subagent's row: the tray's own line (subagents/AgentLine.tsx), so a subagent reads the same here
/// and above the composer. Memoized on the fields of its agent it draws and its plain values
/// (subagentLook.ts), so a snapshot that only brings new objects draws no row; it keeps its own
/// clock, ticking only while its time moves, so a tick draws the running rows and no ended one.
const SubagentStatusRow = memo(function SubagentStatusRow({
  agent,
  depth,
  waits,
  current,
  mark,
  onOpen,
  resume,
}: {
  agent: Subagent;
  depth: number;
  /// It waits on the person (the list's `waiting` holds it).
  waits: boolean;
  current: boolean;
  mark?: string;
  onOpen?: (id: string) => void;
  resume?: ResumeActions;
}) {
  const t = useT();
  // A retry waits out the shared bound before its row says so (retryState.ts ``retryWords``).
  const connectionQuiet = useConnectionQuietKeys();
  const now = useNow(ticking(agent));
  const waiting = waits ? new Set([agent.id]) : NO_WAITING;
  return (
    <li>
      <AgentLine
        name={agent.name}
        icon={SUBAGENT_FALLBACK}
        mark={mark}
        status={subagentStatus(agent, waiting)}
        state={subagentStateText(t, agent, waiting, connectionQuiet)}
        working={Boolean(retrying(agent))}
        time={formatDuration(elapsed(agent, now))}
        iconSize={ROW_ICON}
        depth={depth}
        current={current}
        // Its kind is no subtitle on the line (Leo, 2026-10-31: "a lot of these subtitles are bad"):
        // the tooltip keeps it under its task.
        title={
          [agent.task, agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined]
            .filter(Boolean)
            .join("\n") || undefined
        }
        tone={agentTone(agent.id)}
        onOpen={onOpen ? () => onOpen(agent.id) : undefined}
        after={resume && <ResumeControl agent={agent} actions={resume} />}
      />
    </li>
  );
}, sameAgentRowProps);

const NO_WAITING: ReadonlySet<string> = new Set();

type Same<T> = (a: T, b: T) => boolean;

/// Each field of a sub-session's row, as SubsessionStatusRow compares it: the ones it draws or reads
/// (its name, line, unread dot, queue count, state, retry, indent, opener) by value, and null for one
/// it never reads. Every snapshot is new objects (subagents/subsessions.ts `subsessionRows`), so a
/// row compared by reference drew again each time; a new field fails to compile here until it is
/// classed.
const SUBSESSION_LOOK: { [K in keyof SubsessionRow]-?: Same<SubsessionRow[K]> | null } = {
  sessionId: Object.is,
  harness: Object.is,
  name: Object.is,
  state: Object.is,
  unread: Object.is,
  queued: Object.is,
  doing: Object.is,
  waiting: sameValue,
  retry: sameValue,
  // sessionRetry reads it (a settling retry); compared so the row follows it.
  retryDeciding: Object.is,
  depth: Object.is,
  // The task line's, Session Info's and Resume's; this row draws none of them.
  title: null,
  slot: null,
  model: null,
  effort: null,
  parent: null,
  lastMessage: null,
  error: null,
  stoppedAt: null,
};
const SUBSESSION_FIELDS = Object.entries(SUBSESSION_LOOK).filter(
  (entry): entry is [keyof SubsessionRow, Same<unknown>] => entry[1] !== null,
);

/// The row's props: its session by SUBSESSION_LOOK, its opener (the list's) by identity.
function sameSubsessionProps(
  a: { session: SubsessionRow; onOpen?: (sessionId: string) => void },
  b: { session: SubsessionRow; onOpen?: (sessionId: string) => void },
): boolean {
  return (
    a.onOpen === b.onOpen &&
    (a.session === b.session || SUBSESSION_FIELDS.every(([key, same]) => same(a.session[key], b.session[key])))
  );
}

/// A sub-session's row: its name (and what it does now while it works, or what it waits on the
/// person for), its unread dot, how many messages wait for it, and its state. Memoized on the fields
/// it reads (SUBSESSION_LOOK), so a snapshot that only brings new objects draws no row.
const SubsessionStatusRow = memo(function SubsessionStatusRow({
  session,
  onOpen,
}: {
  session: SubsessionRow;
  onOpen?: (sessionId: string) => void;
}) {
  const t = useT();
  // While acpmux retries its failed turn, it works again (subagents/retryState.ts ``sessionRetry``).
  const phase = sessionRetry(session);
  const retry = phase.kind === "retrying" ? phase.retry : undefined;
  // Its words wait out the shared bound (retryState.ts ``retryWords``); the ring turns at once.
  const retryLasting = useConnectionQuietKeys()(sessionRetryKey(session.sessionId), retry !== undefined);
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
      <span
        className="acpmux-summary-meta acpmux-summary-agent__state"
        title={t(SUBSESSION_STATE_LABEL[session.state])}
      >
        {retry ? <WaitSpinner size={12} loading /> : session.state === "working" && <Spinner size={12} loading />}
        {/* Working is the spinner, no word (Leo, 2026-11-23: "\"running\" doesn't need text"). A retry
            inside the shared bound reads as working too. */}
        {retry
          ? retryLasting
            ? retryLabel(t, retry)
            : null
          : session.state === "working"
            ? null
            : t(SUBSESSION_STATE_LABEL[session.state])}
      </span>
    </button>
  );
}, sameSubsessionProps);
