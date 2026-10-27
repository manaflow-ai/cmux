// Running subagents, background commands and the chats the agent started live in one tray at the
// foot of the chat, in the bottom stack right above the composer (SubagentTray.tsx), never in the
// middle of history (Leo 2026-10-20: "put the subagent situation at the bottom of the chat and
// anchor"). It is the one place running background work shows: the transcript keeps no running
// card and no "Running in background" row, and the running turn's line counts nothing. Once a
// subagent ends it leaves one quiet line where it ended, "Subagent finished: Explore the daemon ·
// 1m 20s" (SubagentDoneLine.tsx), as a background shell's end does
// (conversation/BackgroundTaskNote.tsx).
//
// Debug Settings `agentPane.debug.subagentTray` (AgentPaneTunables+SubagentTray.swift) turns it off:
// the transcript then draws the old group card where the subagents started (SubagentGroup.tsx),
// the agents pill sits above the composer (AgentsPill.tsx) and the running turn's line counts the
// work (conversation/WorkingFor.tsx). The host sends it with the theme (`subagentTray`); absent
// means on.
import { useSyncExternalStore } from "react";
import type { AcpmuxRow } from "../model";
import type { StartedSession } from "../started/startedSessions";
import type { BackgroundCommand } from "../inspector/processes";
import { nestAgents } from "./AgentsPill";
import { isRunGroup, isSubagentGroup, SUBAGENT_DONE, WORKFLOW_CARD } from "./subagentRows";
import type { Subagent } from "./subagentFold";

let trayOn = true;
const listeners = new Set<() => void>();

/// The host pushed the theme: anything but `false` keeps the tray.
export function configureSubagentTray(value: unknown): void {
  const next = value !== false;
  if (next === trayOn) return;
  trayOn = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => trayOn;

/// Whether running subagents show in the tray (the default) rather than as a transcript card.
export const useSubagentTray = (): boolean => useSyncExternalStore(subscribe, snapshot, snapshot);

/// One running thing in the tray: a subagent (nested ones moved in under their parent), a
/// background command, or a chat the agent started.
export type TrayItem =
  | { kind: "agent"; id: string; agent: Subagent; depth: number }
  | { kind: "command"; id: string; command: BackgroundCommand }
  | { kind: "session"; id: string; session: StartedSession };

/// What the tray lists and its header counts: what runs or waits on the person, never what ended
/// (Leo 2026-10-21 on "2 subagents running · 2 commands · 32 sessions": "THIS IS LYING"). The
/// running subagents, each nested one right under the one that spawned it, then the background
/// commands still running, then the started chats whose turn runs or that wait on the person.
/// What ended is shown as bounded status cards after the live rows (``finishedTrayItems``).
///
/// Between turns only work that outlives its turn shows. A foreground subagent a cancel or a
/// reconnect left "running" pins nothing. A command shows whenever acpmux's process registry says
/// it runs (inspector/processes.ts `backgroundCommands` merged it in, `processId`); one only the
/// transcript knows shows only while a turn runs, since the transcript cannot tell a command that
/// ended unseen (a peer's chat, whose registry this acpmux cannot list) from one that runs.
export function trayItems(
  agents: readonly Subagent[],
  commands: readonly BackgroundCommand[],
  sessions: readonly StartedSession[],
  working: boolean,
): TrayItem[] {
  const live = agents
    .filter((agent) => agent.state === "running" && (working || agent.background === true))
    .sort((a, b) => a.startedAt - b.startedAt || a.id.localeCompare(b.id));
  const items: TrayItem[] = nestAgents(live).map(({ agent, depth }) => ({ kind: "agent", id: agent.id, agent, depth }));
  for (const command of commands)
    if (command.state === "running" && (working || command.processId !== undefined))
      items.push({ kind: "command", id: command.id, command });
  for (const session of sessions)
    if (liveSession(session)) items.push({ kind: "session", id: session.sessionId, session });
  return items;
}

const liveSession = (session: StartedSession) => session.state === "running" || session.state === "waiting";

/// The chat's subagents and started chats that ended, for the tray's bounded status cards: the
/// subagents that ended last first, so the few the tray shows under what runs are the latest. A
/// nested one stays under its parent, and a parent's place is its subtree's latest end, so a child
/// that ended after the others is never hidden behind older ones. Then the chats, newest first
/// (their end is not known here), those with no creation time last.
export function finishedTrayItems(agents: readonly Subagent[], sessions: readonly StartedSession[]): TrayItem[] {
  const ended = agents.filter((agent) => agent.state !== "running");
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
    .filter((session) => !liveSession(session))
    .sort((a, b) =>
      a.createdAt === undefined || b.createdAt === undefined
        ? Number(a.createdAt === undefined) - Number(b.createdAt === undefined)
        : b.createdAt - a.createdAt,
    );
  for (const session of chats) items.push({ kind: "session", id: session.sessionId, session });
  return items;
}

/// When an item started, if known.
export const itemStart = (item: TrayItem): number | undefined =>
  item.kind === "agent" ? item.agent.startedAt : item.kind === "command" ? item.command.startedAt : undefined;

/// Done lines by row id, kept while what they say holds, so the turns built on them stay the same
/// objects (conversation/turns.ts `turnViewFrom` reuses turns whose rows did not change).
export type DoneLineCache = Map<string, { key: string; row: AcpmuxRow }>;

/// A cheap stable number for a done line's content, its row version.
function versionOf(key: string): number {
  let hash = 5381;
  for (let index = 0; index < key.length; index += 1) hash = (Math.imul(hash, 33) + key.charCodeAt(index)) | 0;
  return (hash >>> 0) % 1_000_003;
}

function doneLine(agent: Subagent, endedAt: number, cache: DoneLineCache, made: Set<string>): AcpmuxRow {
  const id = `${SUBAGENT_DONE}:${agent.id}`;
  const key = [agent.state, agent.name, agent.startedAt, endedAt, agent.stopReason ?? ""].join("\u0000");
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key) return kept.row;
  const row: AcpmuxRow = {
    id,
    version: versionOf(key),
    at: endedAt,
    kind: SUBAGENT_DONE,
    subagents: [{ ...agent, endedAt }],
  };
  cache.set(id, { key, row });
  return row;
}

const isWorkflow = (agent: Subagent) => agent.kind === "workflow";

/// What a workflow's card draws, as a key: its name, state, times, size and each agent's state.
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
    agents.map((agent) => `${agent.index}:${agent.state ?? ""}`).join(","),
  ].join("\u0000");
}

/// A workflow's card row, one per workflow so each row is one card's height (model.ts).
function workflowCard(row: AcpmuxRow, node: Subagent, cache: DoneLineCache, made: Set<string>): AcpmuxRow {
  const id = `${WORKFLOW_CARD}:${node.id}`;
  const key = cardKey(node);
  made.add(id);
  const kept = cache.get(id);
  if (kept?.key === key) return kept.row;
  const card: AcpmuxRow = { id, version: versionOf(key), at: row.at, kind: WORKFLOW_CARD, subagents: [node] };
  cache.set(id, { key, row: card });
  return card;
}

/// The transcript as the tray draws it: no subagent group where the subagents started (the tray
/// shows them while they run), and for each subagent that ended a done line where it ended, after
/// the last row that came before its end. With `workflowCards` (Labs), a workflow a group started
/// is a card in the group's place instead, running or ended, and leaves no done line. Rows are
/// otherwise the same objects, so a transcript with no subagents is returned as it is.
export function withSubagentLines(
  rows: readonly AcpmuxRow[],
  cache: DoneLineCache = new Map(),
  workflowCards = false,
): readonly AcpmuxRow[] {
  if (!rows.some(isSubagentGroup)) return rows;
  // Each ended subagent goes before the first row after its group that came after its end.
  const before = new Map<number, AcpmuxRow[]>();
  const cards = new Map<number, AcpmuxRow[]>();
  const made = new Set<string>();
  rows.forEach((row, index) => {
    // An agent a shell call started keeps its card where it started (AgentRunCard.tsx).
    if (!isSubagentGroup(row) || isRunGroup(row)) return;
    const workflows = workflowCards ? (row.subagents ?? []).filter(isWorkflow) : [];
    if (workflows.length > 0)
      cards.set(
        index,
        workflows.map((node) => workflowCard(row, node, cache, made)),
      );
    for (const agent of row.subagents ?? []) {
      if (agent.state === "running" || (workflowCards && isWorkflow(agent))) continue;
      const endedAt = agent.endedAt ?? agent.startedAt;
      let at = index + 1;
      while (at < rows.length && (isSubagentGroup(rows[at]!) || rows[at]!.at <= endedAt)) at += 1;
      const line = doneLine(agent, endedAt, cache, made);
      before.set(at, [...(before.get(at) ?? []), line]);
    }
  });
  const out: AcpmuxRow[] = [];
  const flush = (at: number) => {
    const lines = before.get(at);
    if (lines) out.push(...lines.sort((a, b) => a.at - b.at || a.id.localeCompare(b.id)));
  };
  rows.forEach((row, index) => {
    flush(index);
    if (!isSubagentGroup(row) || isRunGroup(row)) out.push(row);
    else out.push(...(cards.get(index) ?? []));
  });
  flush(rows.length);
  // Only this pass's lines stay cached, so another chat's do not pile up.
  for (const id of cache.keys()) if (!made.has(id)) cache.delete(id);
  return out;
}
