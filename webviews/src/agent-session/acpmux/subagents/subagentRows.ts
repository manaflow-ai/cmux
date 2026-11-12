import { keptPrefix, PrefixFilter, PrefixFlatCache } from "../conversation/prefixFlatMap";
import { turnCopyParts } from "../conversation/turnCopy";
import type { Folds } from "../conversation/viewFolds";
import { turnWork } from "../conversation/waterfallSpans";
import type { AcpmuxRow } from "../model";
import { continuesTurn } from "../turnStart";
import { SUBAGENTS, awaitsOwnWork, type Subagent } from "./subagentFold";

/// A subagent's line in an open group (SubagentListRow in SubagentGroup.tsx).
export const SUBAGENT_ROW = "subagent";
/// The child view's "Subagent of" pill (SubagentOfRow in SubagentGroup.tsx).
export const SUBAGENT_OF = "subagentOf";
/// The known child has no recorded messages or tool calls yet.
export const SUBAGENT_EMPTY = "subagentEmpty";
/// A subagent's one line where it ended, while running ones sit in the tray (SubagentDoneLine.tsx,
/// runningTray.ts).
export const SUBAGENT_DONE = "subagentDone";
/// A Claude workflow's card where it started (Labs `workflowLabs`, summary/WorkflowCard.tsx;
/// runningTray.ts `withSubagentLines`): a row per workflow a group started, in the group's place.
export const WORKFLOW_CARD = "workflowCard";

/// Every subagent the rows list, nested views' included.
export function subagentsIn(
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> = {},
): Map<string, Subagent> {
  const found = new Map<string, Subagent>();
  // The chat calls this on every snapshot: its agents come from a pass that reads only the rows the
  // snapshot changed (prefixFlatMap.ts), and a view's from the last read of that same view.
  for (const agent of agentReads.read(rows).items) found.set(agent.id, agent);
  for (const view of Object.values(views)) {
    for (const row of viewGroups(view)) for (const agent of row.subagents ?? []) found.set(agent.id, agent);
  }
  return found;
}

const NO_AGENTS: readonly Subagent[] = [];
const isGroupRow = (row: AcpmuxRow) => row.kind === SUBAGENTS;
const agentReads = new PrefixFlatCache<AcpmuxRow, Subagent>(
  (row) => (row.kind === SUBAGENTS ? (row.subagents ?? NO_AGENTS) : NO_AGENTS),
  6,
);
/// A subagent view's group rows, by the view's array: an unchanged view is not read again.
const viewGroupCache = new WeakMap<readonly AcpmuxRow[], readonly AcpmuxRow[]>();
function viewGroups(view: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  let groups = viewGroupCache.get(view);
  if (!groups) viewGroupCache.set(view, (groups = view.filter(isGroupRow)));
  return groups;
}

/// Subagent `id`'s own view: the "Subagent of" pill naming its parent (a subagent, or the chat,
/// `chat`), then its rows with its open groups listed. Undefined when the subagent is unknown.
export function childView(
  id: string,
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> | undefined,
  expanded: Folds,
  chat: string,
): AcpmuxRow[] | undefined {
  const agents = subagentsIn(rows, views);
  const agent = agents.get(id);
  if (!agent) return undefined;
  const parent = agent.parent === null ? chat : agents.get(agent.parent)?.name || chat;
  const pill: AcpmuxRow = {
    id: `${id}:of`,
    version: 1,
    at: agent.startedAt,
    kind: SUBAGENT_OF,
    subagents: [agent],
    text: parent,
  };
  const own = views?.[id] ?? [];
  const content = withSubagentRows(own, expanded);
  // Views are populated by recorded child events, not a separate fetch. An absent entry does
  // not mean a request is pending; describe the empty transcript without claiming it is loading.
  if (!content.length) return [pill, { id: `${id}:empty`, version: 1, at: agent.startedAt, kind: SUBAGENT_EMPTY }];
  const footer = subagentFooter(agent, own);
  return footer ? [pill, ...content, footer] : [pill, ...content];
}

/// The footer (TurnRows.tsx TurnFooter: Copy, Pin, Timeline, Read aloud, More, its time) under a
/// finished subagent's view, as under a turn of the chat's own: its Copy copies everything the
/// subagent said and the top line of each run of its tool calls (turnCopy.ts). A subagent's records
/// end with no `turn_result`, so its view had no summary row and no way to copy its work (Leo,
/// 2026-11-06: "This is a subagent. I should be able to, like, copy the stuff that it did."). None
/// while it runs or waits on background work of its own (`awaitsOwnWork`: its report is still to
/// come), or when it said nothing, as a turn of tool calls alone draws no Copy. No `seq`:
/// a fork goes through the chat's own turns, never a subagent's.
export function subagentFooter(agent: Subagent, rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  if (agent.state === "running" || awaitsOwnWork(agent)) return undefined;
  let answer: AcpmuxRow | undefined;
  for (let at = rows.length - 1; at >= 0 && !answer; at -= 1)
    if (rows[at]!.kind === "assistant" && (rows[at]!.text ?? "").trim()) answer = rows[at];
  if (!answer || answer.streaming) return undefined;
  const parts = turnCopyParts(rows);
  if (!parts) return undefined;
  const work = turnWork(rows);
  const last = rows.at(-1)!;
  const ended = agent.endedAt ?? last.at;
  return {
    id: `${agent.id}:end`,
    kind: "turnSummary",
    // The memoized footer redraws when the subagent's rows do.
    version: rows.reduce((sum, row) => (sum * 31 + row.version) % 2_147_483_647, rows.length),
    at: ended,
    // A failed subagent says so on its own line (SubagentDoneLine.tsx), not on a failure card here.
    status: "completed",
    durationMs: Math.max(0, ended - agent.startedAt),
    text: answer.text,
    answerId: answer.id,
    turnCopy: parts,
    ...(work && { turnWork: work }),
  };
}

export const isSubagentGroup = (row: AcpmuxRow) => row.kind === SUBAGENTS;

/// A group that is one agent a shell call started (subagentFold.ts `reduceRun`): its card
/// (AgentRunCard.tsx) stays where it started, in the tray's layout too, and never opens to a list.
export const isRunGroup = (row: AcpmuxRow) =>
  row.kind === SUBAGENTS && row.subagents?.length === 1 && row.subagents[0]!.command !== undefined;

/// The latest turn's groups, nested views' included, with an agent still running: in a working
/// turn they start open (App.tsx), after Codex and Claude Code. An earlier turn's group stays as
/// it was, its agent still running in the background.
export function runningGroups(rows: readonly AcpmuxRow[], views: Record<string, AcpmuxRow[]> = {}): string[] {
  // The turn starts after its prompt; a prompt still waiting to send starts none, nor does a steer.
  let start = rows.length;
  while (
    start > 0 &&
    (rows[start - 1]!.kind !== "user" ||
      rows[start - 1]!.pending ||
      rows[start - 1]!.failed ||
      continuesTurn(rows[start - 1]!))
  )
    start -= 1;
  const found: string[] = [];
  for (const list of [rows.slice(start), ...Object.values(views)])
    for (const row of list)
      if (row.kind === SUBAGENTS && row.subagents?.some((agent) => agent.state === "running")) found.push(row.id);
  return found;
}

/// ``withSubagentRows`` with what it was drawn from, for the next snapshot to build on.
export type SubagentRows = { source: readonly AcpmuxRow[]; grouped: boolean; rows: AcpmuxRow[] };

/// ``withSubagentRows``, building on `previous`: in a chat without subagent groups, only the rows
/// after the first that differs from `previous.source` (by object) can bring one.
export function subagentRowsFrom(rows: readonly AcpmuxRow[], expanded: Folds, previous?: SubagentRows): SubagentRows {
  if (previous && !previous.grouped) {
    const shared = previous.source;
    const from = keptPrefix(shared, rows);
    let grouped = false;
    for (let index = from; index < rows.length && !grouped; index += 1) grouped = isSubagentGroup(rows[index]!);
    if (!grouped) return { source: rows, grouped, rows: rows as AcpmuxRow[] };
  }
  const out = withSubagentRows(rows, expanded);
  return { source: rows, grouped: out !== rows, rows: out };
}

/// A group row as drawn, open or closed, by the row's object: a group an update did not change is
/// not read again, and keeps the objects it was drawn as, so the passes after this one keep them too.
const drawnGroups = new WeakMap<AcpmuxRow, { id: string; open: boolean; drawn: readonly AcpmuxRow[] }>();
function drawnGroup(row: AcpmuxRow, expanded: Folds): readonly AcpmuxRow[] {
  const kept = drawnGroups.get(row);
  const open = expanded.has(kept?.id ?? row.id);
  if (kept?.open === open) return kept.drawn;
  const drawn: AcpmuxRow[] = [{ ...row, version: row.version * 2 + (open ? 1 : 0) }];
  if (open) {
    const agents = row.subagents ?? [];
    agents.forEach((agent, index) => {
      const edge =
        agents.length === 1 ? "only" : index === 0 ? "first" : index === agents.length - 1 ? "last" : "middle";
      drawn.push({
        id: `${row.id}:${agent.id}`,
        version: row.version,
        at: row.at,
        kind: SUBAGENT_ROW,
        subagents: [agent],
        status: edge,
      });
    });
  }
  drawnGroups.set(row, { id: row.id, open, drawn });
  return drawn;
}

/// An open group's subagents as rows below it, one line each, so every line keeps a fixed
/// height. Each carries its place in the list (`status`: only, first, middle or last) for the
/// list's border. A group's version records whether it is open.
export function withSubagentRows(rows: readonly AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  // The groups that list their subagents (a run group's card stays as it is), from a pass that
  // reads only the rows a snapshot changed (conversation/prefixFlatMap.ts). None: the rows as they
  // are, so the next snapshot builds on them (subagentRowsFrom) instead of copying every row.
  const listed = listedGroups.read(rows).from;
  if (listed.length === 0) return rows as AcpmuxRow[];
  const out: AcpmuxRow[] = [];
  let next = 0;
  for (const index of listed) {
    for (; next < index; next += 1) out.push(rows[next]!);
    next = index + 1;
    for (const each of drawnGroup(rows[index]!, expanded)) out.push(each);
  }
  for (; next < rows.length; next += 1) out.push(rows[next]!);
  return out;
}
const listedGroups = new PrefixFilter<AcpmuxRow>((row) => isSubagentGroup(row) && !isRunGroup(row), 6);
