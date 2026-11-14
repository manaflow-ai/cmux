// The started-agent pills and the agent pane's model, ported from Swift `HomeAgentPills`,
// `HomeAgentChatContent`, `HomeAgentPane` (CmuxNextHome/NativeTranscript/AgentPills) and
// `HomeAgentThread` / `HomeAgentSessionRef` (CmuxHomeCore). Values only, so the views draw a real
// agent and the gallery's alike. Times are epoch milliseconds.
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

/** Who wrote a message after the task (`HomeAgentSender`). */
export type AgentSender = "agent" | "chief" | "you";

/** One subagent's chat with the Chief in one conversation (`HomeAgentThread`). */
export interface AgentThread {
  peer: string;
  title: string;
  state: AgentPeerState;
  /** The Chief's first message to it; absent when the Chief sent it nothing here. */
  task?: string;
  /** Every message after the task, oldest first. */
  entries: readonly { id: string; sender: AgentSender; text: string }[];
  startedAt: number;
  /** Its newest message's time once it reported or stopped; absent while it works. */
  endedAt?: number;
  /** The Chief's link to the agent's session (`cmux://chief/<home>/session/<id>`). */
  workspaceLink?: string;
}

/** Where an agent runs now, followed by its session id (`HomeAgentSessionRef`). */
export interface AgentSessionRef {
  peer: string;
  session: string;
  /** The machine it runs on now; absent: the Chief's own acpmux. */
  place?: string;
  spawnEpoch?: number;
  moveEpoch?: number;
}

/** The agent's acpmux session id, from the Chief's link. */
export function threadSession(thread: AgentThread): string | undefined {
  const link = thread.workspaceLink;
  if (!link) return undefined;
  const token = link.slice(link.lastIndexOf("/") + 1);
  return token || undefined;
}

/** What one agent's chat in the agent pane shows (`HomeAgentChatContent`). */
export interface AgentChatContent {
  peer: string;
  title: string;
  /** Queued, Working, Reported or Stopped without a report. */
  status: string;
  /** The Chief's task (empty: no "Sent via Chief" bubble). */
  task: string;
  /** "Worked for 5m 35s" (empty: no line). */
  workedFor: string;
  /** The lines behind "Worked for ›" (when it started and ended). */
  details: readonly string[];
  messages: readonly { sender: AgentSender; text: string }[];
  /** Where Go to workspace goes; absent hides the button. */
  workspaceLink?: string;
  /** The machine it moved to; absent while it runs where it started. */
  place?: string;
}

/** `seconds` as the short localized duration ("5m 35s", "1h 2m", "48s"): hours and minutes from
 * an hour, else minutes and seconds, leading zero units dropped. */
export function agentDuration(seconds: number, language = "en"): string {
  const total = Math.max(0, Math.floor(seconds));
  const unit = (value: number, name: "hour" | "minute" | "second") =>
    new Intl.NumberFormat(language, { style: "unit", unit: name, unitDisplay: "narrow" }).format(value);
  if (total >= 3600)
    return `${unit(Math.floor(total / 3600), "hour")} ${unit(Math.floor((total % 3600) / 60), "minute")}`;
  const minutes = Math.floor(total / 60);
  return minutes > 0 ? `${unit(minutes, "minute")} ${unit(total % 60, "second")}` : unit(total, "second");
}

/** The status words for `state`. */
export function agentStatus(state: AgentPeerState, strings: Strings): string {
  const key = { queued: "queued", told: "working", reported: "reported", stopped: "stopped" }[state];
  return strings.t(`home.agentPane.status.${key}`);
}

/** The line over the steps: "Queued for …" while it waits for a slot, "Working for …" while it
 * works, else "Worked for …". */
export function agentTimeLine(state: AgentPeerState, duration: string, strings: Strings): string {
  const key = state === "queued" ? "queuedFor" : state === "told" ? "workingFor" : "workedFor";
  return strings.format(`home.agentPane.${key}`, duration);
}

/** The content of a real agent's chat at `now`. Only this chat's session moves it: once it moved,
 * its own link opens it where acpmux has it now, not the Chief's link to where it started. */
export function agentChatContent(
  thread: AgentThread,
  now: number,
  strings: Strings,
  session?: AgentSessionRef,
): AgentChatContent {
  const time = new Intl.DateTimeFormat(strings.language, { timeStyle: "short" });
  const details = [strings.format("home.agentPane.started", time.format(thread.startedAt))];
  if (thread.endedAt !== undefined)
    details.push(strings.format("home.agentPane.finished", time.format(thread.endedAt)));
  const worked = Math.max(0, ((thread.endedAt ?? now) - thread.startedAt) / 1000);
  const content: AgentChatContent = {
    peer: thread.peer,
    title: thread.title,
    status: agentStatus(thread.state, strings),
    task: thread.task ?? "",
    workedFor: agentTimeLine(thread.state, agentDuration(worked, strings.language), strings),
    details,
    messages: thread.entries.map(({ sender, text }) => ({ sender, text })),
    workspaceLink: thread.workspaceLink,
  };
  const moved = session && ((session.spawnEpoch ?? 0) > 0 || (session.moveEpoch ?? 0) > 0);
  if (session && moved && session.session === threadSession(thread)) {
    content.place = session.place;
    content.workspaceLink = `cmux://session/${session.session}`;
  }
  return content;
}

/** What the agent pane reads and marks: a seam over the store, so tests pass a fake. */
export interface AgentThreadSource {
  thread(peer: string): AgentThread | undefined;
  /** The person saw agent `peer`'s newest report: its pill's unread dot clears. */
  markSeen(peer: string): void;
  /** The person wrote `text` to `peer` from the pane's composer (it reaches the agent through the Chief). */
  send(text: string, peer: string): void;
}

/** The agent pane of one Home chat (`HomeAgentPane`): one tab per agent the person opened from its
 * pill, in the order opened, and the selected one. Opening an agent that has a tab selects it;
 * closing the last tab hides the pane. Selecting an agent marks its newest report seen. */
export interface AgentPaneState {
  tabs: readonly string[];
  selected?: string;
}

export const EMPTY_PANE: AgentPaneState = { tabs: [] };

/** Opens `peer` (a click on its pill): a new tab at the end, or its existing tab. */
export function openAgent(pane: AgentPaneState, peer: string, source: AgentThreadSource): AgentPaneState {
  const tabs = pane.tabs.includes(peer) ? pane.tabs : [...pane.tabs, peer];
  return selectAgent({ tabs, selected: pane.selected }, peer, source);
}

/** Opens `peer` beside Home when it can (`outside` gets its link; true when it opened), else in
 * this pane, so the click always shows it. */
export function openAgentOutside(
  pane: AgentPaneState,
  peer: string,
  source: AgentThreadSource,
  outside: (link: string) => boolean,
): [AgentPaneState, boolean] {
  const link = source.thread(peer)?.workspaceLink;
  if (link && outside(link)) {
    source.markSeen(peer);
    return [pane, true];
  }
  return [openAgent(pane, peer, source), false];
}

/** Shows `peer`'s tab and marks its newest report seen. */
export function selectAgent(pane: AgentPaneState, peer: string, source: AgentThreadSource): AgentPaneState {
  if (!pane.tabs.includes(peer)) return pane;
  source.markSeen(peer);
  return pane.selected === peer ? pane : { ...pane, selected: peer };
}

/** Closes `peer`'s tab; the next one (else the previous) shows, none left hides the pane. */
export function closeAgent(pane: AgentPaneState, peer: string, source: AgentThreadSource): AgentPaneState {
  const index = pane.tabs.indexOf(peer);
  if (index < 0) return pane;
  const tabs = pane.tabs.filter((tab) => tab !== peer);
  if (pane.selected !== peer) return { ...pane, tabs };
  if (!tabs.length) return { tabs };
  return selectAgent({ tabs }, tabs[Math.min(index, tabs.length - 1)]!, source);
}

/** The person sent `text` to `peer` from its tab's composer. */
export function sendToAgent(pane: AgentPaneState, peer: string, text: string, source: AgentThreadSource): void {
  const words = text.trim();
  if (pane.tabs.includes(peer) && words) source.send(words, peer);
}
