// The started-agent pills, ported from Swift `HomeAgentPills`. A click on a pill opens the agent's own
// workspace; Home never splits into an agent pane (user 2026-11-07, msg 23836). Values only, so the
// views draw a real agent and the gallery's alike.
import type { Strings } from "../strings";

/** Where an agent stands, from its newest message (`HomeAgentMessageRow.PeerState`). */
export type AgentPeerState = "queued" | "told" | "reported" | "stopped";

/** An agents row as the transcript has it: the agents in the Chief's order, with their task titles
 * and states (`HomeAgentFoldRowProvider.Payload`). */
export interface AgentsRow {
  peers: readonly string[];
  /** The task titles; when their count differs from `peers`, the ids show. */
  titles?: readonly string[];
  states?: readonly string[];
  /** A report newer than the one the person last opened; absent: a reported agent is unread. */
  unread?: readonly boolean[];
}

/** One pill. */
export interface AgentPill {
  peer: string;
  title: string;
  state: AgentPeerState;
  /** The unread dot. */
  unread: boolean;
}

/** The pill shapes: stacked full pills (shipped), stacked two-line pills, or small chips in one row. */
export type AgentPillShape = "pill" | "twoLine" | "chip";

const STATES = new Set<string>(["queued", "told", "reported", "stopped"]);

/** The row's pills, one per agent: a missing title shows the id, a missing state is `told`, a
 * missing unread mark is set for a reported agent. */
export function agentPills(row: AgentsRow): AgentPill[] {
  const titles = row.titles && row.titles.length === row.peers.length ? row.titles : row.peers;
  return row.peers.map((peer, index) => {
    const raw = row.states?.[index] ?? "told";
    const state = (STATES.has(raw) ? raw : "told") as AgentPeerState;
    return { peer, title: titles[index] ?? peer, state, unread: row.unread?.[index] ?? state === "reported" };
  });
}

/** The status words for `state`. */
export function agentStatus(state: AgentPeerState, strings: Strings): string {
  const key = { queued: "queued", told: "working", reported: "reported", stopped: "stopped" }[state];
  return strings.t(`home.agentPane.status.${key}`);
}
