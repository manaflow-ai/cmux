import { type Translate } from "../i18n";
import type { StartedSession } from "../started/startedSessions";
import { nestAgents } from "../subagents/agentsPillModel";
import { IDLE_AFTER_MS } from "../subagents/idle";
import { retrying } from "../subagents/retryState";
import { awaitsOwnWork, type Subagent } from "../subagents/subagentFold";
import { running } from "../subagents/subagentGroupModel";
import { subagentStatus, type SubagentStatus } from "../summary/subagentStatusListModel";
import { orderedSessions, sessionStatus } from "./childSessionRowsModel";
import { countParts, countText, live, type CountPart } from "../summary/LiveCount";

/// Running lines shown before "Show more", as Claude Code desktop's panel caps its list.
export const SUBAGENTS_SHOWN = 5;
export const NO_SESSIONS: readonly StartedSession[] = [];

/// "1 waiting · 1 failed · 3 running · 1 queued · 40 done" (the native text) for the section's head, the started chats counted with the
/// subagents, or nothing for neither.
/// With the clock (`now`), a subagent quiet past IDLE_AFTER_MS counts as idle, as its line reads:
/// the head and the lines read one status each (Leo, 2026-11-02: "but what's going on with these?").
/// The page draws the running ones as their mark and number (`subagentCountParts`, LiveCount.tsx);
/// this text, with their word, is the App's native Session Info's meta, which draws only text.
export function subagentCounts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
  now?: number,
): string {
  return countText(subagentCountParts(t, agents, waiting, sessions, now));
}

/// The head's counts as parts: the running ones as their mark and number, no word (LiveCount.tsx).
export function subagentCountParts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
  now?: number,
): CountPart[] {
  // A chat acpmux holds for a free slot (`waitsForSlot`) is queued, as the running limit's line
  // says, never done or idle by its state.
  const queued = sessions.filter((child) => child.waitsForSlot).length;
  const count = (status: SubagentStatus) =>
    agents.filter((agent) => subagentStatus(agent, waiting, now) === status).length +
    sessions.filter((child) => !child.waitsForSlot && sessionStatus(child) === status).length;
  return orderedCountParts(
    {
      waiting: count("waiting"),
      failed: count("failed"),
      running: count("running"),
      queued,
      idle: count("idle"),
      stopped: count("stopped"),
      done: count("done"),
    },
    t,
    { words: { queued: (n) => t("sessionInfo.subagents.limit.queued", { n }) } },
  );
}

/// One line of the section in its place: a subagent (nested under its parent at `depth`) or a chat
/// the agent started, with the status it is drawn with.
export type SubagentEntry =
  | { agent: Subagent; depth: number; status: SubagentStatus; session?: undefined }
  | { session: StartedSession; status: SubagentStatus; agent?: undefined; depth?: undefined };

const isLive = (status: SubagentStatus) => status === "running" || status === "waiting" || status === "idle";
/// The ended list's order: a failed one first, then a stopped one, then the done ones.
const ENDED_RANK: Record<SubagentStatus, number> = { failed: 0, stopped: 1, done: 2, running: 3, waiting: 3, idle: 3 };

/// The section's two lists at `now`: the live ones (the chats waiting on the person, then the running
/// subagents in the tray's order, oldest first, a nested one under its parent and among siblings a
/// waiting one first, then the running chats) and the ended ones (failed, stopped, then done, the
/// latest first). A pass over every item: SubagentsSection runs it only when the items change or
/// `now` crosses `nextSubagentStatusChange`, never on the second's tick.
export function splitSubagentLines(
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[],
  now: number,
): { running: SubagentEntry[]; ended: SubagentEntry[] } {
  const statuses = new Map(agents.map((agent) => [agent, subagentStatus(agent, waiting, now)]));
  const statusOf = (agent: Subagent) => statuses.get(agent)!;
  const waitsFirst = (a: Subagent, b: Subagent) =>
    Number(subagentStatus(b, waiting) === "waiting") - Number(subagentStatus(a, waiting) === "waiting") ||
    a.startedAt - b.startedAt;
  const runningAgents = nestAgents(agents.filter((agent) => isLive(statusOf(agent))).sort(waitsFirst)).map(
    ({ agent, depth }): SubagentEntry => ({ agent, depth, status: statusOf(agent) }),
  );
  const children = orderedSessions(sessions).map((session): SubagentEntry => ({
    session,
    status: sessionStatus(session),
  }));
  const at = (entry: SubagentEntry) =>
    entry.agent ? (entry.agent.endedAt ?? entry.agent.startedAt) : (entry.session.createdAt ?? 0);
  return {
    running: [
      ...children.filter((child) => child.status === "waiting"),
      ...runningAgents,
      ...children.filter((child) => child.status === "running"),
    ],
    ended: [
      ...agents
        .filter((agent) => !isLive(statusOf(agent)))
        .map((agent): SubagentEntry => ({ agent, depth: 0, status: statusOf(agent) })),
      ...children.filter((child) => !isLive(child.status)),
    ].sort((a, b) => ENDED_RANK[a.status] - ENDED_RANK[b.status] || at(b) - at(a)),
  };
}

/// The next session time after `now` at which a subagent's status changes by the clock alone: a
/// running one with no call open turns idle IDLE_AFTER_MS after it went quiet
/// (subagentStatusListModel.ts `isIdle`). Undefined while none will. Nothing else in the section moves
/// with the clock but the times on its lines, which tick in leaves of their own.
export function nextSubagentStatusChange(
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  now: number,
): number | undefined {
  let next: number | undefined;
  for (const agent of agents) {
    if (awaitsOwnWork(agent) || !running(agent) || waiting.has(agent.id) || agent.quietSince === undefined) continue;
    if (retrying(agent)) continue;
    const idleAt = agent.quietSince + IDLE_AFTER_MS;
    if (idleAt > now && (next === undefined || idleAt < next)) next = idleAt;
  }
  return next;
}

/// The order every subagent count line reads in: what needs the person first (waiting, then
/// failed), then what is still going, then what ended. A narrow head cuts from the end, so the
/// failure is never the part an ellipsis hides ("1 waiting · 4 running · 1 faile…" at 420 px,
/// cmuxterm-hq#19495).
export const SUBAGENT_COUNT_ORDER = ["waiting", "failed", "running", "queued", "idle", "stopped", "done"] as const;
export type SubagentCountKind = (typeof SUBAGENT_COUNT_ORDER)[number];
export type SubagentCountTally = Partial<Record<SubagentCountKind, number>>;

const COUNT_WORD: Record<SubagentCountKind, (t: Translate, n: number) => string> = {
  waiting: (t, n) => t("summary.subagents.waiting", { n }),
  failed: (t, n) => t("summary.subagents.failed", { n }),
  running: (t, n) => t("summary.subagents.running", { n }),
  queued: (t, n) => t("workflow.queued", { n }),
  idle: (t, n) => t("summary.subagents.idle", { n }),
  stopped: (t, n) => t("summary.subagents.stopped", { n }),
  done: (t, n) => t("summary.subagents.done", { n }),
};

type CountOptions = {
  /// A kind in a surface's own wording (a started chat's "queued" for a slot, a card's "Working").
  words?: Partial<Record<SubagentCountKind, (n: number) => string | false | undefined>>;
  /// A surface's own parts right after a kind's ("2 commands" after the running ones), present or not.
  after?: Partial<Record<SubagentCountKind, readonly (string | false | undefined)[]>>;
};

/// Each count that is not zero, in SUBAGENT_COUNT_ORDER. The running ones are their mark and number
/// with no word (LiveCount.tsx), unless the surface words them: "1 waiting", "1 failed", (mark) 4.
export function orderedCountParts(
  counts: SubagentCountTally,
  t: Translate,
  { words = {}, after = {} }: CountOptions = {},
): CountPart[] {
  const parts: (CountPart | false | undefined)[] = [];
  for (const kind of SUBAGENT_COUNT_ORDER) {
    const n = counts[kind] ?? 0;
    if (n > 0) {
      const word = words[kind];
      if (word) parts.push(word(n));
      else if (kind === "running") parts.push(live(n, COUNT_WORD.running(t, n)));
      else parts.push(COUNT_WORD[kind](t, n));
    }
    parts.push(...(after[kind] ?? []));
  }
  return countParts(...parts);
}

/// The same parts as words, for a surface that draws only text (the native Session Info, a row's
/// status line): the running ones keep their word there ("4 running").
export const orderedCountWords = (counts: SubagentCountTally, t: Translate, options?: CountOptions): string[] =>
  orderedCountParts(counts, t, options).map((part) => (typeof part === "string" ? part : part.label));
