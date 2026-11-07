// A Chief chat's started agents on the Messages page (HomePageAgents.swift): the host's `agents`
// stream has each turn's agents row with the message it follows and the agents' chats; a click on a
// pill opens the agent's session right of Home (the host's openLink), or its chat in the agent pane
// here when it has no link. The pane's reads and sends go to the host.
//
//   agents (stream) {conversation, rows: [{after, group, peers, titles, states, unread}],
//                    threads: [{peer, title, state, task?, entries: [{id, sender, text}], startedAt,
//                    endedAt?, workspaceLink?}]} | null
//   agents.seen {conversation, peer}: the person opened its chat (its unread dot clears)
//   agents.note {conversation, peer, text}: the person's words to it, through the Chief (a key or click only)
import { useMemo, useRef, useState } from "react";
import type { PageClient } from "../../shared/pageClient";
import {
  agentChatContent,
  closeAgent,
  EMPTY_PANE,
  openAgent,
  openAgentOutside,
  selectAgent,
  sendToAgent,
  type AgentChatContent,
  type AgentPaneState,
  type AgentPeerState,
  type AgentSender,
  type AgentThread,
  type AgentThreadSource,
} from "../cards/pills/agentModel";
import type { Strings } from "../cards/strings";
import type { TranscriptAgents } from "../transcript/rows";

export const AgentOps = {
  stream: "cmux.home.messages.agents",
  seen: "cmux.home.messages.agents.seen",
  note: "cmux.home.messages.agents.note",
} as const;

/** One Chief chat's agents, as the host last sent them. */
export interface ChiefAgents {
  conversation: string;
  rows: readonly TranscriptAgents[];
  threads: ReadonlyMap<string, AgentThread>;
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const texts = (value: unknown): string[] | undefined =>
  Array.isArray(value) && value.every((item) => typeof item === "string") ? (value as string[]) : undefined;
const time = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;
const STATES = new Set<string>(["queued", "told", "reported", "stopped"]);
const SENDERS = new Set<string>(["agent", "chief", "you"]);

/** The stream's event, or undefined for null or a value that is not one. */
export function parseChiefAgents(event: unknown): ChiefAgents | undefined {
  const raw = record(event);
  const conversation = text(raw?.conversation);
  if (!raw || !conversation) return undefined;
  const rows: TranscriptAgents[] = [];
  for (const entry of Array.isArray(raw.rows) ? raw.rows : []) {
    const row = record(entry);
    const group = text(row?.group);
    const peers = texts(row?.peers);
    if (!row || !group || !peers?.length) continue;
    const unread =
      Array.isArray(row.unread) && row.unread.every((v) => typeof v === "boolean") ? row.unread : undefined;
    const after = text(row.after);
    rows.push({
      group,
      ...(after ? { after } : {}),
      row: {
        peers,
        ...(texts(row.titles) ? { titles: texts(row.titles)! } : {}),
        ...(texts(row.states) ? { states: texts(row.states)! } : {}),
        ...(unread ? { unread: unread as boolean[] } : {}),
      },
    });
  }
  const threads = new Map<string, AgentThread>();
  for (const entry of Array.isArray(raw.threads) ? raw.threads : []) {
    const thread = parseThread(entry);
    if (thread) threads.set(thread.peer, thread);
  }
  return { conversation, rows, threads };
}

function parseThread(value: unknown): AgentThread | undefined {
  const raw = record(value);
  const peer = text(raw?.peer);
  const startedAt = time(raw?.startedAt);
  if (!raw || !peer || startedAt === undefined) return undefined;
  const state = (STATES.has(String(raw.state)) ? raw.state : "told") as AgentPeerState;
  const entries: { id: string; sender: AgentSender; text: string }[] = [];
  for (const item of Array.isArray(raw.entries) ? raw.entries : []) {
    const entry = record(item);
    const id = text(entry?.id);
    if (!entry || !id || typeof entry.text !== "string") continue;
    const sender = (SENDERS.has(String(entry.sender)) ? entry.sender : "agent") as AgentSender;
    entries.push({ id, sender, text: entry.text });
  }
  const task = typeof raw.task === "string" ? raw.task : undefined;
  const endedAt = time(raw.endedAt);
  const workspaceLink = text(raw.workspaceLink);
  return {
    peer,
    title: text(raw.title) ?? peer,
    state,
    entries,
    startedAt,
    ...(task !== undefined ? { task } : {}),
    ...(endedAt !== undefined ? { endedAt } : {}),
    ...(workspaceLink ? { workspaceLink } : {}),
  };
}

/** What a Chief chat's transcript and its agent pane read: the agents rows, the pills' click, and
 * the pane's state and steps. The pane is the shown chat's: another chat starts with none. */
export interface AgentPaneModel {
  rows: readonly TranscriptAgents[] | undefined;
  /** The pills' words and click, the same object while the words are (the rows' actions keep). */
  pills: { strings: Strings; open(peer: string, command: boolean): void };
  pane: AgentPaneState;
  content(peer: string): AgentChatContent | undefined;
  select(peer: string): void;
  close(peer: string): void;
  goToWorkspace(peer: string): void;
  send(peer: string, text: string): void;
}

export function useAgentPane(
  host: PageClient | null,
  conversation: string,
  agents: ChiefAgents | undefined,
  strings: Strings,
  openLink: (url: string) => void,
): AgentPaneModel {
  const [kept, setKept] = useState<{ conversation: string; pane: AgentPaneState }>({ conversation, pane: EMPTY_PANE });
  const pane = kept.conversation === conversation ? kept.pane : EMPTY_PANE;
  const mine = agents?.conversation === conversation ? agents : undefined;
  const source = useMemo<AgentThreadSource>(() => {
    const call = (op: string, params: Record<string, unknown>) =>
      void host?.call(op, { conversation, ...params }).catch(() => undefined);
    return {
      thread: (peer) => mine?.threads.get(peer),
      markSeen: (peer) => call(AgentOps.seen, { peer }),
      send: (words, peer) => call(AgentOps.note, { peer, text: words }),
    };
  }, [host, conversation, mine]);
  // Each step runs once, from the pane on screen (its reads and marks are host calls, so never in an updater).
  const step = (next: (pane: AgentPaneState) => AgentPaneState) => setKept({ conversation, pane: next(pane) });
  const open = useRef<(peer: string) => void>(() => {});
  open.current = (peer) =>
    step((current) =>
      host
        ? openAgentOutside(current, peer, source, (link) => {
            openLink(link);
            return true;
          })[0]
        : openAgent(current, peer, source),
    );
  const pills = useMemo(() => ({ strings, open: (peer: string) => open.current(peer) }), [strings]);
  return {
    rows: mine?.rows,
    pills,
    pane,
    content: (peer) => {
      const thread = mine?.threads.get(peer);
      return thread ? agentChatContent(thread, Date.now(), strings) : undefined;
    },
    select: (peer) => step((current) => selectAgent(current, peer, source)),
    close: (peer) => step((current) => closeAgent(current, peer, source)),
    goToWorkspace: (peer) => {
      const link = mine?.threads.get(peer)?.workspaceLink;
      if (link) openLink(link);
    },
    send: (peer, words) => sendToAgent(pane, peer, words, source),
  };
}
