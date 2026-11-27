// Running subagents, background commands and the chats the agent started live in one tray at the
// foot of the chat, in the bottom stack right above the composer (SubagentTray.tsx), never in the
// middle of history (Leo 2026-10-20: "put the subagent situation at the bottom of the chat and
// anchor"). The transcript keeps a compact start line for each recorded group, and a finished
// line for each subagent where it ended. The tray owns live progress and Stop; lifecycle lines
// stay readable when the turn's work folds.
import type { AcpmuxRow } from "../model";
import type { StartedSession } from "../started/startedSessions";
import type { SubagentStatus } from "../summary/subagentStatusListModel";
import { arrivalKey, type BackgroundCommand } from "../session-info/processes";
import { nestAgents } from "./agentsPillModel";
import { isRunGroup, isSubagentGroup, SUBAGENT_DONE, WORKFLOW_CARD, SUBAGENT_STARTED } from "./subagentRows";
import { awaitsOwnWork, type Subagent } from "./subagentFold";
import { subagentNamed } from "./subsessions";
import { retrying, retryKey, sessionRetry, type RetryState } from "./retryState";
import { resumedRun } from "./resumeState";
import { BACKGROUND_TURN } from "../conversation/backgroundTurns";
import { keptPrefix, noteKeptPrefix, PrefixFlatCache } from "../conversation/prefixFlatMap";
import type { SilentTurn } from "../conversation/silentTurns";

/// One running thing in the tray: a subagent (nested ones moved in under their parent), a
/// background command, or a chat the agent started.
export type TrayItem =
  | { kind: "agent"; id: string; agent: Subagent; depth: number }
  | {
      kind: "command";
      id: string;
      command: BackgroundCommand;
      /// The subagent whose call started it, when one did and the chat knows it: its line names it.
      owner?: Subagent;
      /// Its owner's own line is listed too, and this line sits right under it (``newestFirst``): it
      /// names what runs, with the owner as its muted "via", never the owner's title first, which read
      /// as a second copy of the owner's line (Leo, ask-31a1e4b192: "this isn't great").
      underOwner?: boolean;
    }
  | { kind: "session"; id: string; session: StartedSession }
  /// A turn something other than the person started that said nothing (conversation/silentTurns.ts):
  /// only ever a finished line, never in what runs.
  | { kind: "turn"; id: string; turn: SilentTurn };

/// A silent turn's line mark: the clock the transcript's background-turn line draws.
export const SILENT_TURN_ICON = "history";

/// A tray line's key: a command's is the call that started it, which stays when the registry lists a
/// command only the transcript knew, so its line is the same node running and finished.
export const trayItemKey = (item: TrayItem): string =>
  item.kind === "command" ? `command:${arrivalKey(item.command)}` : `${item.kind}:${item.id}`;

/// What the tray lists and its header counts: what runs or waits on the person, never what ended
/// (Leo 2026-10-21 on "2 subagents running · 2 commands · 32 sessions": "THIS IS LYING"). The
/// running subagents (each nested one right under the one that spawned it), the background commands
/// still running and the started chats whose turn runs or that wait on the person, newest first.
/// What ended is shown as bounded status cards after the live rows (``finishedTrayItems``).
///
/// Only the chat's own work: its subagents, its commands and the sub-sessions its agent started with
/// its `start_session` tool (``StartedSession.subsession``). A lane a coordinator dispatched with
/// `sessions new` or `acpmux new` from its shell is its own chat, in the sidebar, never a running line
/// here (Leo, 2026-11-03, on a dispatched lane's line: "like why is this even in the "running" in the
/// first place?"). Session Info still lists every chat it started.
///
/// Between turns only work that outlives its turn shows. A foreground subagent a cancel or a
/// reconnect left "running" pins nothing. A command shows whenever acpmux's process registry says
/// it runs (session-info/processes.ts `backgroundCommands` merged it in, `processId`); one only the
/// transcript knows shows only while a turn runs, since the transcript cannot tell a command that
/// ended unseen (a peer's chat, whose registry this acpmux cannot list) from one that runs.
export function trayItems(
  agents: readonly Subagent[],
  commands: readonly BackgroundCommand[],
  sessions: readonly StartedSession[],
  working: boolean,
): TrayItem[] {
  const retries = childRetries(sessions);
  // A run a Resume started shows as the row it continues (resumeState.ts), once.
  const known = new Map(agents.map((agent) => [agent.id, agent]));
  const live = agents
    .filter((agent) => !resumedRun(agent, known))
    // One acpmux retries is about to run again: it shows with the running ones, turn or not. A
    // sub-session's retry is on its own session row: its line carries it, to read "Retrying (2/4)".
    .flatMap((agent) => {
      if (agent.state === "running" && (working || agent.background === true)) return [agent];
      // Stopped to wait on background work of its own: still live, its report still to come.
      if (awaitsOwnWork(agent)) return [agent];
      const retry = retries(agent);
      return retry ? [agent.retry ? agent : { ...agent, retry }] : [];
    })
    .sort((a, b) => a.startedAt - b.startedAt || a.id.localeCompare(b.id));
  const items: TrayItem[] = nestAgents(live).map(({ agent, depth }) => ({ kind: "agent", id: agent.id, agent, depth }));
  const byId = new Map(agents.map((agent) => [agent.id, agent]));
  for (const command of commands)
    if (command.state === "running" && (working || command.processId !== undefined)) {
      const owner = command.subagent === undefined ? undefined : byId.get(command.subagent);
      items.push({ kind: "command", id: command.id, command, ...(owner ? { owner } : {}) });
    }
  for (const session of sessions)
    if (session.subsession && liveSession(session)) items.push({ kind: "session", id: session.sessionId, session });
  return newestFirst(items);
}

/// The open tray's lines newest first, as its folded header names them, so the top line is what just
/// started (Leo, 2026-11-03: "this previews one of the latest but it doesn't show in latest it shows
/// in oldest order"). A nested subagent keeps its place under its parent: a parent and its subtree
/// move as one, by the parent's start. Those with no start time go last, in their list order.
function newestFirst(items: readonly TrayItem[]): TrayItem[] {
  const groups: { start: number; index: number; items: TrayItem[] }[] = [];
  /// The group each listed subagent's line is in, so its commands join it.
  const groupOf = new Map<string, { start: number; index: number; items: TrayItem[] }>();
  const owned: TrayItem[] = [];
  for (const item of items) {
    const last = groups.at(-1);
    if (item.kind === "command" && item.owner && items.some((each) => each.kind === "agent" && each.id === item.owner!.id)) {
      owned.push(item);
      continue;
    }
    if (last && item.kind === "agent" && item.depth > 0) {
      last.items.push(item);
      groupOf.set(item.id, last);
    } else {
      const group = { start: itemStart(item) ?? Number.NEGATIVE_INFINITY, index: groups.length, items: [item] };
      groups.push(group);
      if (item.kind === "agent") groupOf.set(item.id, group);
    }
  }
  // A subagent's command goes right under its owner's line (after the owner and what it nested),
  // so the two read as one piece of work, not as two lines with one title.
  for (const item of owned) {
    if (item.kind !== "command") continue;
    const group = groupOf.get(item.owner!.id)!;
    const at = group.items.findIndex((each) => each.kind === "agent" && each.id === item.owner!.id);
    let end = at + 1;
    const depth = (group.items[at] as { depth: number }).depth;
    while (end < group.items.length) {
      const next = group.items[end]!;
      if (next.kind === "agent" && next.depth <= depth) break;
      end += 1;
    }
    group.items.splice(end, 0, { ...item, underOwner: true });
  }
  groups.sort((a, b) => b.start - a.start || a.index - b.index);
  return groups.flatMap((group) => group.items);
}

/// The retry acpmux waits to run for `agent`, if any: a sub-session's is on its own session row
/// (retryState.ts ``subagentRetry``), found among the chats this one started.
function childRetries(sessions: readonly StartedSession[]): (agent: Subagent) => RetryState | undefined {
  const byId = new Map(sessions.map((session) => [session.sessionId, session]));
  return (agent) => retrying(agent, agent.child ? byId.get(agent.child) : undefined);
}

const liveSession = (session: StartedSession) =>
  session.state === "running" || session.state === "waiting" || sessionRetry(session).kind === "retrying";

/// The chat's subagents and started chats that ended, for the tray's bounded status cards: the
/// subagents that ended last first, so the few the tray shows under what runs are the latest. A
/// nested one stays under its parent, and a parent's place is its subtree's latest end, so a child
/// that ended after the others is never hidden behind older ones. Then the chats, newest first
/// (their end is not known here), those with no creation time last.
export function finishedTrayItems(agents: readonly Subagent[], sessions: readonly StartedSession[]): TrayItem[] {
  const retries = childRetries(sessions);
  const known = new Map(agents.map((agent) => [agent.id, agent]));
  const ended = agents.filter(
    (agent) => agent.state !== "running" && !awaitsOwnWork(agent) && !retries(agent) && !resumedRun(agent, known),
  );
  // Each subtree's latest end, in one pass over a parent-to-children map (a loop is cut where it
  // meets an agent already on the path).
  const ids = new Set(ended.map((agent) => agent.id));
  const children = new Map<string, Subagent[]>();
  for (const agent of ended) {
    if (agent.parent === null || !ids.has(agent.parent)) continue;
    const under = children.get(agent.parent);
    if (under) under.push(agent);
    else children.set(agent.parent, [agent]);
  }
  const latest = new Map<string, number>();
  const visiting = new Set<string>();
  const subtreeEnd = (agent: Subagent): number => {
    const known = latest.get(agent.id);
    if (known !== undefined) return known;
    let end = agent.endedAt ?? agent.startedAt;
    if (visiting.has(agent.id)) return end;
    visiting.add(agent.id);
    for (const child of children.get(agent.id) ?? []) end = Math.max(end, subtreeEnd(child));
    visiting.delete(agent.id);
    latest.set(agent.id, end);
    return end;
  };
  for (const agent of ended) subtreeEnd(agent);
  ended.sort((a, b) => latest.get(b.id)! - latest.get(a.id)! || b.startedAt - a.startedAt || a.id.localeCompare(b.id));
  const items: TrayItem[] = nestAgents(ended).map(({ agent, depth }) => ({
    kind: "agent",
    id: agent.id,
    agent,
    depth,
  }));
  const chats = sessions
    .filter((session) => session.subsession && !liveSession(session))
    .sort((a, b) =>
      a.createdAt === undefined || b.createdAt === undefined
        ? Number(a.createdAt === undefined) - Number(b.createdAt === undefined)
        : b.createdAt - a.createdAt,
    );
  for (const session of chats) items.push({ kind: "session", id: session.sessionId, session });
  return items;
}

/// A command's line status: running, done (exit 0), failed, or stopped (killed, or acpmux lost it).
export function commandStatus(command: BackgroundCommand): SubagentStatus {
  if (command.state === "running") return "running";
  if (command.state === "completed") return "done";
  return command.state === "failed" ? "failed" : "stopped";
}

/// An ended line that failed: a subagent that neither completed nor was stopped, a command that
/// exited non-zero, a chat the agent started whose run failed. It leaves the hat at once and never
/// lingers there (Leo, 2026-11-12: "if these failed, I don't know why they still show up"): its
/// failure stays where it ended, the transcript's failed line with its Retry, and in Session Info.
export function endedInFailure(item: TrayItem): boolean {
  if (item.kind === "turn") return false;
  if (item.kind === "command") return commandStatus(item.command) === "failed";
  if (item.kind === "session") return item.session.state === "failed";
  const { state } = item.agent;
  return state !== "running" && state !== "completed" && state !== "cancelled" && state !== "disconnected";
}

/// When an item started, if known.
export const itemStart = (item: TrayItem): number | undefined =>
  item.kind === "agent"
    ? item.agent.startedAt
    : item.kind === "command"
      ? item.command.startedAt
      : item.kind === "turn"
        ? item.turn.startedAt
        : undefined;

/// Done lines by row id, kept while what they say holds, so the turns built on them stay the same
/// objects (conversation/turns.ts `turnViewFrom` reuses turns whose rows did not change).
export type DoneLineCache = Map<string, { key: string; row: AcpmuxRow }>;

const STARTED_STATES = new Set(["running", "completed", "failed", "cancelled", "disconnected"]);
const hasStarted = (agent: Subagent) =>
  agent.id.trim() !== "" && Number.isFinite(agent.startedAt) && STARTED_STATES.has(agent.state);

/// The most subagents a start line names; the rest it counts ("+8 more"), and the count's hover card
/// lists them. Leo, 2026-11-22, on start lines of six to twelve chips, each cut to an empty pill or a
/// letter: "ENTIRE THING FUCKING BLANKED AND FUCKING SHIFTED".
export const STARTED_LINE_NAMES = 3;

/// What a turn's start line says, decided here so the line only draws it: the subagents it names
/// (each named by its task or name, its start read by this pane), and how many more started with them.
export type StartedLineModel = { named: Subagent[]; more: Subagent[] };

/// The start line of `agents` (every group of one turn, in order): a subagent this pane did not see
/// start (`startUnseen`: met first through its progress or its end, after a page, a lag's re-read or
/// a reconnect began past its spawn) is not on it; one that nothing names yet waits off it until a
/// record names it. Undefined when no subagent is left: no line, never a row of empty pills.
export function startedLineModel(agents: readonly Subagent[], workflows: boolean): StartedLineModel | undefined {
  const shown = agents.filter(
    (agent) => hasStarted(agent) && !agent.startUnseen && subagentNamed(agent) && !(workflows && isWorkflow(agent)),
  );
  if (!shown.length) return undefined;
  return { named: shown.slice(0, STARTED_LINE_NAMES), more: shown.slice(STARTED_LINE_NAMES) };
}

function startedLine(
  group: AcpmuxRow,
  agents: readonly Subagent[],
  cache: DoneLineCache,
  made: Set<string>,
  workflows: boolean,
): AcpmuxRow[] {
  const line = startedLineModel(agents, workflows);
  if (!line) return [];
  const all = [...line.named, ...line.more];
  const id = `${SUBAGENT_STARTED}:${group.id}`;
  const at = Math.min(...all.map((agent) => agent.startedAt));
  const key = JSON.stringify([
    at,
    group.inBackground,
    line.named.length,
    all.map(({ id, name, task, kind, prompt, harness }) => [id, name, task, kind, prompt, harness]),
  ]);
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key) return [kept.row];
  const row: AcpmuxRow = {
    id,
    kind: SUBAGENT_STARTED,
    at,
    version: versionOf(key),
    subagents: all,
    startedNamed: line.named.length,
    ...(group.inBackground !== undefined && { inBackground: group.inBackground }),
  };
  cache.set(id, { key, row });
  return [row];
}

/// A cheap stable number for a done line's content, its row version.
function versionOf(key: string): number {
  let hash = 5381;
  for (let index = 0; index < key.length; index += 1) hash = (Math.imul(hash, 33) + key.charCodeAt(index)) | 0;
  return (hash >>> 0) % 1_000_003;
}

/// A done line or card keeps the background turn its group belongs to (conversation/backgroundTurns.ts),
/// so a quiet turn's closed line folds it with the rest of that turn.
function doneLine(
  agent: Subagent,
  endedAt: number,
  cache: DoneLineCache,
  made: Set<string>,
  inBackground?: string,
): AcpmuxRow {
  const id = `${SUBAGENT_DONE}:${agent.id}`;
  const key = [
    agent.state,
    agent.name,
    agent.startedAt,
    endedAt,
    agent.stopReason ?? "",
    retryKey(agent),
    inBackground ?? "",
    // The chat's reaction to its end (ReactionMark.tsx): its new mark comes and goes.
    agent.reaction ? `${agent.reaction.turn}:${agent.reaction.fresh ? 1 : 0}` : "",
  ].join("\u0000");
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key) return kept.row;
  const row: AcpmuxRow = {
    id,
    version: versionOf(key),
    at: endedAt,
    kind: SUBAGENT_DONE,
    subagents: [{ ...agent, endedAt }],
    ...(inBackground !== undefined && { inBackground }),
  };
  cache.set(id, { key, row });
  return row;
}

const isWorkflow = (agent: Subagent) => agent.kind === "workflow";

/// What a workflow's card draws, as a key: its name, state, times, size and each agent's live
/// presentation fields. Keeping the message/action fields here makes the card update in place as
/// workflow events arrive; WorkflowCard itself never scans the transcript.
function cardKey(node: Subagent): string {
  const agents = node.workflowAgents instanceof Map ? [...node.workflowAgents.values()] : [];
  return [
    node.id,
    node.state,
    node.paused ? "paused" : "",
    node.name,
    node.startedAt,
    node.endedAt ?? "",
    node.agents?.started ?? "",
    node.agents?.done ?? "",
    node.agents?.failed ?? "",
    node.agents?.queued ?? "",
    node.tokens ?? "",
    node.action ?? "",
    node.phases?.map((phase) => `${phase.index}:${phase.title}`).join(",") ?? "",
    agents
      .map((agent) =>
        [
          agent.index,
          agent.state ?? "",
          agent.action ?? "",
          agent.result ?? "",
          (agent as typeof agent & { lastMessage?: string }).lastMessage ?? "",
          agent.model ?? "",
          agent.tokens ?? "",
          agent.startedAt ?? "",
          agent.elapsedMs ?? "",
          agent.phaseIndex ?? "",
        ].join(":"),
      )
      .join(","),
  ].join("\u0000");
}

/// A workflow's card row, one per workflow so each row is one card's height (model.ts).
function workflowCard(row: AcpmuxRow, node: Subagent, cache: DoneLineCache, made: Set<string>): AcpmuxRow {
  const id = `${WORKFLOW_CARD}:${node.id}`;
  const key = `${cardKey(node)}\u0000${row.inBackground ?? ""}`;
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key) return kept.row;
  const card: AcpmuxRow = {
    id,
    version: versionOf(key),
    at: row.at,
    kind: WORKFLOW_CARD,
    subagents: [node],
    ...(row.inBackground !== undefined && { inBackground: row.inBackground }),
  };
  cache.set(id, { key, row: card });
  return card;
}

/// The subagent a background turn answered: the line of a turn Claude Code started with a
/// subagent's report (its task notification, acpmux `cause.kind` `subagent`), whose `origin` is the
/// Agent call that started it.
const reportOrigin = (row: AcpmuxRow): string | undefined =>
  row.kind === BACKGROUND_TURN && row.background?.cause?.kind === "subagent" ? row.background.cause.origin : undefined;

/// The report origin an agent answers to: Claude Code's notification names the Agent call
/// (`toolu_…`), while acpmux's record names a Claude subagent `<session>/<tool call>`.
function reportKey(id: string, reports: ReadonlyMap<string, number>): string | undefined {
  if (reports.has(id)) return id;
  const call = id.slice(id.lastIndexOf("/") + 1);
  return call !== id && reports.has(call) ? call : undefined;
}

/// A report's line (conversation/BackgroundTurnLine.tsx) names the subagent that sent it: the same
/// row with `subagentReport`, kept while the row and what the agent says hold, so the turn built on
/// it stays the same object.
function reportLine(
  row: AcpmuxRow,
  agent: Subagent,
  first: boolean,
  cache: DoneLineCache,
  made: Set<string>,
): AcpmuxRow {
  const id = `report:${row.id}`;
  const key = [
    row.version,
    first ? 1 : 0,
    agent.state,
    agent.name,
    agent.task ?? "",
    agent.result ?? "",
    agent.lastMessage ?? "",
    agent.error ?? "",
  ].join("\u0000");
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key && kept.row.background === row.background) return kept.row;
  const line: AcpmuxRow = {
    ...row,
    version: versionOf(key),
    subagentReport: agent,
    ...(first && { subagentReportFirst: true as const }),
  };
  cache.set(id, { key, row: line });
  return line;
}

/// The transcript keeps each recorded group's compact start and each subagent's done line after
/// the last row that came before its end. A subagent's report (the turn its end started, a
/// background turn of kind `subagent`) names its subagent, and that subagent's done line goes right
/// above its first report, so the two read as one (Leo, 2026-11-05, on the report's line under
/// "Subagent finished": "what's up with this \"tool call\"?"). With `workflowCards` (Labs), a workflow a group started
/// is a card in the group's place instead, running or ended, and leaves no done line. Rows are
/// otherwise the same objects, so a transcript with no subagents is returned as it is.
export function withSubagentLines(
  rows: readonly AcpmuxRow[],
  cache: DoneLineCache = new Map(),
  workflowCards = false,
): readonly AcpmuxRow[] {
  // The groups and the reports come from passes that read only the rows a snapshot changed
  // (conversation/prefixFlatMap.ts); every other row is copied as it is. A chat of 35,000 rows
  // read each row three times per event here.
  const groups = groupReads.read(rows).from;
  if (groups.length === 0) return rows;
  const reportPass = reportReads.read(rows);
  // Each ended subagent goes before the first row after its group that came after its end, or
  // right above its first report when one came after its group.
  const before = new Map<number, AcpmuxRow[]>();
  const reports = new Map<string, number>();
  reportPass.items.forEach((origin, at) => {
    if (!reports.has(origin)) reports.set(origin, reportPass.from[at]!);
  });
  const reported = new Map<string, Subagent>();
  const cards = new Map<number, AcpmuxRow[]>();
  const made = new Set<string>();
  // The rows drawn other than as they are: the groups' starts and workflow cards, and the reports
  // of a reported subagent (its line); and where the done lines go.
  const changed = new Map<number, (row: AcpmuxRow) => readonly AcpmuxRow[]>();
  // One start line a turn: every group a turn started (one per batch between the agent's words)
  // joins the line of its first, which keeps its place; the others draw none (Leo, 2026-11-22: fifteen
  // "started working" lines filled the screen). A background turn's groups keep a line of their own.
  // Each group's fields are read once here (test/delta-cost-incremental.test.ts counts them per update).
  const turnOpeners = openerReads.read(rows).from;
  const lineOf = new Map<number, Subagent[]>();
  const firstOf = new Map<string, number>();
  for (const index of groups) {
    const row = rows[index]!;
    // An agent a shell call started keeps its card where it started (AgentRunCard.tsx).
    if (isRunGroup(row)) continue;
    const subagents = row.subagents ?? [];
    const inBackground = row.inBackground;
    const turnKey = `${openerBefore(turnOpeners, index)}\u0000${inBackground ?? ""}`;
    const first = firstOf.get(turnKey);
    if (first === undefined) {
      firstOf.set(turnKey, index);
      lineOf.set(index, [...subagents]);
    } else lineOf.get(first)!.push(...subagents);
    // Read when the rows are drawn, after every group of its turn has joined its line.
    changed.set(index, () => {
      const agents = lineOf.get(index);
      return [
        ...(agents ? startedLine(rows[index]!, agents, cache, made, workflowCards) : NO_ROWS),
        ...(cards.get(index) ?? NO_ROWS),
      ];
    });
    const workflows = workflowCards ? subagents.filter(isWorkflow) : [];
    if (workflows.length > 0)
      cards.set(
        index,
        workflows.map((node) => workflowCard(row, node, cache, made)),
      );
    for (const agent of subagents) {
      // One waiting on background work of its own has not finished: its line waits for its report.
      if (agent.state === "running" || awaitsOwnWork(agent) || (workflowCards && isWorkflow(agent))) continue;
      const endedAt = agent.endedAt ?? agent.startedAt;
      let at = index + 1;
      while (at < rows.length && (isSubagentGroup(rows[at]!) || rows[at]!.at <= endedAt)) at += 1;
      const origin = reportKey(agent.id, reports);
      const report = origin === undefined ? undefined : reports.get(origin);
      if (origin !== undefined && report !== undefined && report > index) {
        at = report;
        reported.set(origin, { ...agent, endedAt });
      }
      const line = doneLine(agent, endedAt, cache, made, inBackground);
      before.set(at, [...(before.get(at) ?? []), line]);
    }
  }
  reportPass.items.forEach((origin, at) => {
    const agent = reported.get(origin);
    if (agent) {
      const index = reportPass.from[at]!;
      changed.set(index, (row) => [reportLine(row, agent, reports.get(origin) === index, cache, made)]);
    }
  });
  const marks = [...new Set([...changed.keys(), ...before.keys()])].sort((a, b) => a - b);
  // What each mark draws: the done lines that go before it, then its row as drawn (or as it is).
  const drawn = marks.map((mark): readonly AcpmuxRow[] => {
    const lines = before.get(mark)?.sort((a, b) => a.at - b.at || a.id.localeCompare(b.id)) ?? NO_ROWS;
    if (mark >= rows.length) return lines;
    const draw = changed.get(mark);
    return [...lines, ...(draw ? draw(rows[mark]!) : [rows[mark]!])];
  });
  // Only this pass's lines stay cached, so another chat's do not pile up.
  for (const id of cache.keys()) if (!made.has(id)) cache.delete(id);
  return placeMarks(rows, { marks, drawn, workflowCards }, cache);
}

/// What a pass drew where: the rows it changed or put lines before (sorted), what each drew, and
/// whether workflows were cards.
type MarkedRows = {
  readonly marks: readonly number[];
  readonly drawn: readonly (readonly AcpmuxRow[])[];
  readonly workflowCards: boolean;
};

/// The last pass that used a cache (one per view: App.tsx keeps one for the chat, one for a
/// subagent's), its rows and output held weakly so a closed chat leaves no rows here.
const lastPasses = new WeakMap<
  DoneLineCache,
  MarkedRows & { rows: WeakRef<readonly AcpmuxRow[]>; out: WeakRef<readonly AcpmuxRow[]> }
>();

const sameRows = (a: readonly AcpmuxRow[], b: readonly AcpmuxRow[]) =>
  a.length === b.length && a.every((row, index) => row === b[index]);

/// `rows` with each mark's rows in its place. Rows change at their tail, so the output starts with
/// the last pass's up to the first row that changed (`keptPrefix`) or the first mark that drew
/// otherwise (a report that moved a done line under it), copied, not read, and says so
/// (`noteKeptPrefix`). A streamed token in a chat with a subagent group then costs the passes after
/// this one (turns.ts `turnViewFrom`, the layout) the rows it changed, not a walk of the chat
/// (Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference").
// perf-hot: 1ms agent-chat-token-rows
function placeMarks(rows: readonly AcpmuxRow[], pass: MarkedRows, cache: DoneLineCache): readonly AcpmuxRow[] {
  const { marks, drawn } = pass;
  const last = lastPasses.get(cache);
  const lastRows = last?.rows.deref();
  const lastOut = last?.out.deref();
  const reuse = last && lastRows && lastOut && last.workflowCards === pass.workflowCards ? last : undefined;
  if (
    reuse &&
    rows === lastRows &&
    marks.length === reuse.marks.length &&
    marks.every((mark, index) => mark === reuse.marks[index] && sameRows(drawn[index]!, reuse.drawn[index]!))
  )
    return lastOut!;
  // `from`: the first row whose output may differ from the last pass's; `marked` marks come before it.
  let from = 0;
  let marked = 0;
  let out: AcpmuxRow[] = [];
  if (reuse) {
    from = keptPrefix(lastRows!, rows);
    let index = 0;
    while (index < marks.length && index < reuse.marks.length) {
      const mark = marks[index]!;
      if (mark >= from) break;
      if (mark !== reuse.marks[index] || !sameRows(drawn[index]!, reuse.drawn[index]!)) {
        from = Math.min(mark, reuse.marks[index]!);
        break;
      }
      index += 1;
    }
    // A mark only one pass has, before `from`, changed what that pass drew there.
    if (index < reuse.marks.length) from = Math.min(from, reuse.marks[index]!);
    if (index < marks.length) from = Math.min(from, marks[index]!);
    // Rows before `from` and the marks among them drew what they drew last time: the last output
    // up to row `from` is this one's.
    let at = 0;
    let previous = -1;
    for (; marked < marks.length && marks[marked]! < from; marked += 1) {
      at += marks[marked]! - previous - 1 + drawn[marked]!.length;
      previous = marks[marked]!;
    }
    at += from - previous - 1;
    out = lastOut!.slice(0, at);
  }
  const kept = out.length;
  let next = from;
  for (let index = marked; index < marks.length; index += 1) {
    const mark = marks[index]!;
    for (; next < mark && next < rows.length; next += 1) out.push(rows[next]!);
    out.push(...drawn[index]!);
    next = Math.max(next, mark + 1);
  }
  for (; next < rows.length; next += 1) out.push(rows[next]!);
  if (reuse) noteKeptPrefix(out, lastOut!, kept);
  lastPasses.set(cache, { ...pass, rows: new WeakRef(rows), out: new WeakRef(out) });
  return out;
}

const NO_ROWS: readonly AcpmuxRow[] = [];
/// The subagent groups of a transcript, by index (withSubagentLines).
const groupReads = new PrefixFlatCache<AcpmuxRow, true>((row) => (isSubagentGroup(row) ? YES : NOTHING));
const YES: readonly true[] = [true];
/// The rows that open a turn (a prompt or a message, not a steer into a running one), by index.
const openerReads = new PrefixFlatCache<AcpmuxRow, true>((row) =>
  row.kind === "user" && row.steer === undefined && !row.continues ? YES : NOTHING,
);
/// The index of the last turn opener before `index` in `openers` (sorted), or -1.
function openerBefore(openers: readonly number[], index: number): number {
  let low = 0;
  let high = openers.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (openers[mid]! < index) low = mid + 1;
    else high = mid;
  }
  return low === 0 ? -1 : openers[low - 1]!;
}
const NOTHING: readonly never[] = [];
/// The subagent each report answers (`reportOrigin`), by index.
const reportReads = new PrefixFlatCache<AcpmuxRow, string>((row) => {
  const origin = reportOrigin(row);
  return origin === undefined ? NOTHING : [origin];
});
