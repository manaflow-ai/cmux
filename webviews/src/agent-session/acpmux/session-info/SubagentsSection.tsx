// Session Info's Subagents, as Claude Code desktop's session panel lists them: what runs is named,
// one row each, and what ended is one fold. The harness's own subagents and the chats its agent
// started (ChildSessionRows.tsx; a Cloud VM's or another machine's included) share the list. Each
// running one is a lean line of its own (subagents/AgentLine.tsx `lean`): its own toned glyph, its
// name and how long it has run, Waiting ones first; no spinner and no tool name (Lucas, 2026-11-05,
// Session Info lab). Past five, "Show more" opens the rest. The ones that ended fold under one row,
// "94 done · 1 failed", failed first. Every line opens what it names: a subagent's pane or view
// (App.tsx `showSubagent`), a chat beside this one (`chat.offer.open`); its hover card names it and
// says its state and its task. The live counts sit in the section's head (the running ones as their mark
// and number, then "40 done",
// `subagentCountParts`).
import { useState, memo, useCallback, useMemo } from "react";
import { useConnectionQuietKeys } from "../../../ui/lasting";
import { useScrollEdges } from "../../../ui/scrollEdges";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";

import type { StartedSession } from "../started/startedSessions";
import { AgentLine } from "../subagents/AgentLine";
import { SubagentCardBody } from "../subagents/SubagentPreview";
import { ResumeControl, type ResumeActions } from "../subagents/ResumeControl";
import { useSenderIconLook } from "../subagents/senderIconLook";
import { useAgentProgress } from "../subagents/agentProgressStore";
import { foreignHarness, isRepeatedAgentKind, SUBAGENT_FALLBACK } from "../subagents/agentIdentityModel";
import { subagentProgress } from "../subagents/subagentProgress";
import { namedAction } from "../subagents/trayDetail";
import { useNow, ticking } from "../subagents/subagentGroupModel";
import { agentTone } from "../subagents/agentTones";
import type { Subagent } from "../subagents/subagentFold";
import { subsessionResumeRow } from "../subagents/resumeState";
import { retrying } from "../subagents/retryState";
import { subagentStateText, type SubagentStatus } from "../summary/subagentStatusListModel";
import { awaitsOwnWork } from "../subagents/subagentFold";
import { sessionStateText } from "./childSessionRowsModel";
import "./SubagentsSection.css";
import { heightAbove, useFoldMotion } from "./foldMotion";
import { SessionInfoFold } from "./SessionInfoSection";
import {
  SUBAGENTS_SHOWN,
  NO_SESSIONS,
  subagentCountParts,
  nextSubagentStatusChange,
  splitSubagentLines,
  type SubagentEntry,
} from "./subagentsSectionModel";
import { useStatusClock } from "./statusClock";
import { CountLine } from "../summary/LiveCount";
import { WindowedRows } from "./WindowedRows";
import { sameSubagentLook } from "../subagents/subagentLook";

/// The clock the section's statuses read: it moves when a running subagent turns idle, not each
/// second (statusClock.ts), so neither the head's counts nor the lines' order are worked out again
/// on a tick.
function useSubagentStatusClock(agents: readonly Subagent[], waiting: ReadonlySet<string>): number {
  const nextChange = useCallback((now: number) => nextSubagentStatusChange(agents, waiting, now), [agents, waiting]);
  return useStatusClock(nextChange);
}

/// The section head's counts on the clock the lines read, so an idle one leaves "running" in both
/// at once; counted again only when the subagents change or one turns idle.
export function SubagentCountsMeta({
  agents,
  waiting,
  sessions,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  sessions: readonly StartedSession[];
}) {
  const t = useT();
  const now = useSubagentStatusClock(agents, waiting);
  const parts = useMemo(
    () => subagentCountParts(t, agents, waiting, sessions, now),
    [t, agents, waiting, sessions, now],
  );
  return parts.length > 0 ? (
    <span className="acpmux-session-info-section__value">
      <CountLine parts={parts} />
    </span>
  ) : null;
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
  /// A stopped sub-session's row, for its Resume (resumeState.ts ``subsessionResumeRow``).
  resumeRow?: Subagent;
  name: string;
  detail?: string;
  /// The kind of agent it is, for the hover card.
  kind?: string;
  progress?: string;
  status: SubagentStatus;
  state: string;
  /// acpmux retries it: its line shows the turning ring (retryState.ts).
  working?: boolean;
  /// Its time, ticked by its own leaf (SubagentTime): from `since` to `until`, or to now while
  /// `ticks`. A chat's line shows none.
  since?: number;
  until?: number;
  ticks?: boolean;
  /// Its whole task, for the hover card.
  task?: string;
  icon: string;
  /// The harness whose mark it draws (the agent's own, else the chat's for its own subagents).
  mark?: string;
  depth: number;
  /// When it ended (or, for a chat, was made): the ended list's order.
  at: number;
};

type Same<T> = (a: T, b: T) => boolean;
const sameAgent: Same<Subagent | undefined> = (a, b) => a === b || (!!a && !!b && sameSubagentLook(a, b));

/// Each field of a line, as its row compares it: the words and values it draws by value, and its
/// subagent (for the hover card's progress, Resume and the open) by the fields a subagent's row reads
/// (subagents/subagentLook.ts), so a snapshot that only moves `progressVersion` or `quietSince` (new
/// objects every time) draws no line; a line's idle status is its `status` and `state`, compared here.
/// A new field fails to compile until it is classed as drawn (compared) or not (null).
const LINE_LOOK: { [K in keyof Line]-?: Same<Line[K]> | null } = {
  key: Object.is,
  identity: Object.is,
  agent: sameAgent,
  resumeRow: sameAgent,
  name: Object.is,
  detail: Object.is,
  kind: Object.is,
  progress: Object.is,
  status: Object.is,
  state: Object.is,
  working: Object.is,
  // Its time's range; SubagentTime ticks the time itself, so a second draws no line.
  since: Object.is,
  until: Object.is,
  ticks: Object.is,
  task: Object.is,
  icon: Object.is,
  mark: Object.is,
  depth: Object.is,
  // The ended list's order, the section's; the line draws no part of it.
  at: null,
};
const LINE_FIELDS = Object.entries(LINE_LOOK).filter(
  (entry): entry is [keyof Line, Same<unknown>] => entry[1] !== null,
);

/// A line's row props: the line by LINE_LOOK, its callbacks (the section's) by identity.
function sameLineProps(a: LineRowProps, b: LineRowProps): boolean {
  return (
    a.onOpen === b.onOpen &&
    a.onOpenSession === b.onOpenSession &&
    a.resume === b.resume &&
    (a.item === b.item || LINE_FIELDS.every(([key, same]) => same(a.item[key], b.item[key])))
  );
}

/// An idle line keeps its place among the live ones but takes no part in the running shimmer.
const working = (status: SubagentStatus) => status === "running" || status === "waiting";

export function SubagentsSection({
  agents,
  waiting,
  onOpen,
  sessions = NO_SESSIONS,
  onOpenSession,
  harness,
  resume,
}: {
  agents: readonly Subagent[];
  /// Resume on a stopped subagent's line (subagents/ResumeControl.tsx), as its end line offers it.
  resume?: ResumeActions;
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
  // A retry waits out the shared bound before its line says so (retryState.ts ``retryWords``).
  const connectionQuiet = useConnectionQuietKeys();
  const language = usePaneLanguage();
  // Not the second's clock: the lines' order and groups move only when a subagent turns idle, and
  // each line's time ticks in its own leaf (SubagentTime), so a tick sorts and draws nothing here.
  const now = useSubagentStatusClock(agents, waiting);
  const [more, setMore] = useState(false);
  const [endedOpen, setEndedOpen] = useState(false);
  const endedEdges = useScrollEdges();
  // The badge look picks which subagents show their family mark (foreignHarness): read here, so a
  // change of the setting draws them again.
  const senderBadge = useSenderIconLook().badge;
  // Show more grows the running lines in place, and the ended row opens its list, each as one motion
  // with the sections under it and the panel's edge (foldMotion.ts).
  const moreFold = useFoldMotion<HTMLUListElement>(more, (list) => heightAbove(list, list.children[SUBAGENTS_SHOWN]));
  const endedFold = useFoldMotion<HTMLDivElement>(endedOpen, () => 0);
  // The two lists, worked out again only when the items, the words or the status clock change.
  const { runningLines, endedLines } = useMemo(() => {
    const agentLine = (agent: Subagent, depth: number, status: SubagentStatus): Line => ({
      key: `agent:${agent.id}`,
      identity: agent.id,
      agent,
      name: agent.name,
      progress: subagentProgress(t, language, agent, { usage: false }).join(" · "),
      // What it does now, while it runs; its kind (Explore, general-purpose) is no subtitle on the
      // line (Leo, 2026-10-31: "a lot of these subtitles are bad"): the hover card keeps it.
      detail: working(status) ? namedAction(t, agent.action, agent.actionShell) : undefined,
      kind: agent.kind && agent.kind !== agent.name && !isRepeatedAgentKind(agent.kind) ? agent.kind : undefined,
      status,
      state: subagentStateText(t, agent, waiting, connectionQuiet, now),
      working: Boolean(retrying(agent)),
      // How long it has run (subagentGroupModel.ts `elapsed`): one waiting on work of its own still counts.
      since: agent.startedAt,
      until: awaitsOwnWork(agent) ? undefined : agent.endedAt,
      ticks: ticking(agent),
      task: agent.task,
      icon: SUBAGENT_FALLBACK,
      // Another family's mark; the chat's own subagents keep their toned sparkle (foreignHarness).
      mark: foreignHarness(agent.harness, harness, senderBadge),
      depth,
      at: agent.endedAt ?? agent.startedAt,
    });
    const sessionLine = (child: StartedSession, status: SubagentStatus): Line => ({
      key: `session:${child.sessionId}`,
      identity: child.sessionId,
      name: child.title,
      status,
      ...(({ text, working }) => ({ state: text, working }))(sessionStateText(t, child, connectionQuiet)),
      icon: "agent.chat",
      mark: child.harness,
      depth: 0,
      at: child.createdAt ?? 0,
      resumeRow: subsessionResumeRow(child),
    });
    const toLine = (entry: SubagentEntry): Line =>
      entry.agent ? agentLine(entry.agent, entry.depth, entry.status) : sessionLine(entry.session, entry.status);
    const split = splitSubagentLines(agents, waiting, sessions, now);
    return { runningLines: split.running.map(toLine), endedLines: split.ended.map(toLine) };
  }, [agents, waiting, sessions, now, t, language, harness, senderBadge, connectionQuiet]);
  const shown = moreFold.drawn ? runningLines : runningLines.slice(0, SUBAGENTS_SHOWN);
  // Each line is its own memo boundary (SubagentLineRow): a tick, a change to another subagent or a
  // scroll draws only the lines whose words changed.
  const line = (item: Line) => (
    <SubagentLineRow key={item.key} item={item} onOpen={onOpen} onOpenSession={onOpenSession} resume={resume} />
  );
  return (
    <div className="acpmux-session-info-subagents">
      {runningLines.length > 0 && (
        <ul ref={moreFold.ref} className="acpmux-summary-list acpmux-session-info-subagents__running">
          <WindowedRows items={shown} render={line} />
        </ul>
      )}
      {runningLines.length > SUBAGENTS_SHOWN && (
        <SessionInfoFold
          className="acpmux-session-info-subagents__more"
          open={more}
          onToggle={() => moreFold.toggle(!more, setMore)}
        >
          {more
            ? t("sessionInfo.subagents.less")
            : t("sessionInfo.subagents.more", { n: runningLines.length - SUBAGENTS_SHOWN })}
        </SessionInfoFold>
      )}
      {endedLines.length > 0 && (
        <>
          <SessionInfoFold
            className="acpmux-session-info-subagents__ended"
            open={endedOpen}
            onToggle={() => endedFold.toggle(!endedOpen, setEndedOpen)}
          >
            <Icon name="disclosure.collapsed" size={12} />
            {endedCounts(t, endedLines)}
          </SessionInfoFold>
          {endedFold.drawn && (
            <div ref={endedFold.ref} className="acpmux-session-info-fold-box">
              <ul
                ref={endedEdges}
                className="acpmux-summary-list acpmux-session-info-scroll acpmux-session-info-subagents__list ui-scroll-edge-fade"
              >
                <WindowedRows items={endedLines} render={line} />
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  );
}

type LineRowProps = {
  item: Line;
  onOpen?: (id: string) => void;
  onOpenSession?: (sessionId: string) => void;
  resume?: ResumeActions;
};

/// One line of the list (a subagent or a started chat), drawn again only when its own words change.
/// Its open is the section's, which takes the line's id.
const SubagentLineRow = memo(
  function SubagentLineRow({ item, onOpen, onOpenSession, resume }: LineRowProps) {
    const handler = item.agent ? onOpen : onOpenSession;
    const { identity } = item;
    const open = useCallback(() => handler?.(identity), [handler, identity]);
    // `resumable`: the row a stopped one's Resume reads, a subagent's or a sub-session's.
    const resumable = item.agent ?? item.resumeRow;
    return (
      <li>
        <AgentLine
          lean
          name={item.name}
          status={item.status}
          state={item.state}
          time={
            item.since !== undefined ? (
              <SubagentTime since={item.since} until={item.until} ticks={item.ticks} />
            ) : undefined
          }
          icon={item.icon}
          mark={item.mark}
          tone={agentTone(item.identity)}
          depth={item.depth}
          onOpen={handler ? open : undefined}
          card={<AgentCard item={item} />}
          after={resume && resumable && <ResumeControl agent={resumable} actions={resume} />}
        />
      </li>
    );
  },
  // A line is built again on each render (and a stopped chat's Resume row with it): compared by the
  // fields it draws (LINE_LOOK).
  sameLineProps,
);

/// How long a line's subagent has run: the one part of the line the second's clock draws, a leaf of
/// its own, so a tick draws this text and not the line around it.
function SubagentTime({ since, until, ticks = false }: { since: number; until?: number; ticks?: boolean }) {
  return lineTime(since, until, useNow(ticks && until === undefined));
}

const lineTime = (since: number, until: number | undefined, now: number) =>
  formatDuration(Math.max(0, (until ?? now) - since));

function AgentCard({ item }: { item: Line }) {
  const progress = useAgentProgress(item.agent) ?? item.progress;
  // The card shows only while hovered: its time keeps its own clock while it does.
  const now = useNow(Boolean(item.ticks) && item.until === undefined);
  const time = item.since !== undefined ? lineTime(item.since, item.until, now) : undefined;
  // The one subagent card (subagents/SubagentPreview.tsx), which a subagent's name chip shows too.
  return (
    <SubagentCardBody
      name={item.name}
      status={item.status}
      state={[
        item.state,
        time,
        item.kind,
        progress,
        item.status === "running" || item.status === "waiting" ? item.detail : undefined,
      ]
        .filter(Boolean)
        .join(" · ")}
      task={item.task && item.task !== item.name ? item.task : undefined}
    />
  );
}
