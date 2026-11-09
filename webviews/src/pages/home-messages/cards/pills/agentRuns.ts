// A Chief's messages with its agents, from its runs' steps, as the native transcript read them
// (CmuxNextHomeEngine HomeAgentRunMapping, CmuxHomeCore HomeAgentMessages, HomeAgentMessageRow,
// HomeAgentThread, HomeAgentNote): a `spawn` is the Chief's first message to each agent it started
// (its task), a `tell` a later one, a `report:` note the agent's report. They fold into one agents
// row per Chief message (its pills, agentModel.ts); a pill opens the agent's workspace through the
// Chief's link to its session (Home never splits: no agent pane).
// Values only: the page passes the runs it holds and the loaded messages.
import type { RunEntry } from "../../../home-channels/runs";
import type { HomeMessage, HomeRunStep } from "../../../home-channels/types";
import type { AgentPeerState, AgentsRow } from "./agentModel";

/** One message between the Chief and an agent (`HomeAgentRun.Message`). */
export interface AgentRunMessage {
  id: string;
  seq: number;
  peer: string;
  /** The Chief's message to the agent; false: the agent's report. */
  outgoing: boolean;
  text: string;
  at: number;
  /** `_meta.cmux.sender` (`human:<participant>`, `chief:<id>`). */
  sender?: string;
  /** It waits with the agent in the Chief's queue (the agent has not started). */
  queued: boolean;
}

const SPAWN = new Set(["spawn", "optchat.spawn", "mcp__optchat__spawn"]);
const TELL = new Set(["tell", "optchat.tell", "mcp__optchat__tell"]);

type Json = Record<string, unknown>;
const object = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

/** A tool input's fields: direct, or a Codex `mcp_tool_call` envelope's `arguments` (ConversationRunTool.Input). */
function toolInput(raw: unknown) {
  const fields = object(raw) ?? {};
  const args = object(fields.arguments);
  const source = args ?? fields;
  const meta = object(object(source._meta)?.cmux) ?? object(object(fields._meta)?.cmux);
  const tasks = Array.isArray(source.tasks) ? source.tasks.filter((task) => typeof task === "string") : undefined;
  return {
    id: text(source.id),
    message: text(source.message),
    tasks: tasks as string[] | undefined,
    sender: text(meta?.sender),
    tellEnvelope: !!args && fields.server === "optchat" && fields.tool === "tell",
    spawnEnvelope: !!args && fields.server === "optchat" && fields.tool === "spawn",
  };
}

/** A finished spawn's agents, their tasks and whether each waits in the queue: one `- a<N>: …` line
 * per task, in order; none when the counts differ (a wrong name is worse than none). */
function spawned(step: HomeRunStep): { peer: string; task: string; queued: boolean }[] | undefined {
  const tool = step.tool;
  if (step.kind !== "tool" || !tool) return undefined;
  const input = toolInput(tool.input);
  if (!input.tasks?.length || !(SPAWN.has(tool.name) || input.spawnEnvelope) || tool.output === undefined)
    return undefined;
  const ids: { id: string; queued: boolean }[] = [];
  for (const line of tool.output.split("\n")) {
    if (!line.startsWith("- a")) continue;
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const id = line.slice(2, colon);
    if (id.length < 2 || !/^a\d+$/.test(id)) continue;
    const outcome = line.slice(colon + 1).trimStart();
    ids.push({ id, queued: outcome === "queued" || outcome.startsWith("queued ") || outcome.startsWith("queued(") });
  }
  if (ids.length !== input.tasks.length) return undefined;
  return ids.map((entry, index) => ({ peer: entry.id, task: input.tasks![index]!, queued: entry.queued }));
}

const parsed = new WeakMap<readonly HomeRunStep[], AgentRunMessage[]>();

/** A run's agent messages, in step order (HomeAgentRunMapping.run). Read once per steps array (the
 * run book replaces it when a step changes), so a render does not parse a run again. */
export function agentMessages(steps: readonly HomeRunStep[], startedAt: number): AgentRunMessage[] {
  const held = parsed.get(steps);
  if (held) return held;
  const out = mapSteps(steps, startedAt);
  parsed.set(steps, out);
  return out;
}

function mapSteps(steps: readonly HomeRunStep[], startedAt: number): AgentRunMessage[] {
  const out: AgentRunMessage[] = [];
  for (const step of steps) {
    const at = step.at || step.tool?.startedAt || startedAt;
    const tasks = spawned(step);
    if (tasks) {
      const sender = toolInput(step.tool?.input).sender;
      for (const task of tasks)
        out.push({
          id: `${step.id}:${task.peer}`,
          seq: step.seq,
          peer: task.peer,
          outgoing: true,
          text: task.task,
          at,
          ...(sender ? { sender } : {}),
          queued: task.queued,
        });
      continue;
    }
    const tool = step.tool;
    if (step.kind === "tool" && tool) {
      const input = toolInput(tool.input);
      const id = input.id?.trim();
      if (!(TELL.has(tool.name) || input.tellEnvelope) || !id || input.message === undefined) continue;
      const reason = tool.output?.trim() ?? "";
      const refused = reason === "outcome: refused" || reason.startsWith("outcome: refused.");
      let body = input.message;
      // A successful call can still refuse delivery (a cancelled agent, a deleted VM).
      if (step.status === "failed" || refused) body += reason ? `\n[Error: ${reason}]` : "\n[Error]";
      out.push({
        id: step.id,
        seq: step.seq,
        peer: input.id!,
        outgoing: true,
        text: body,
        at,
        ...(input.sender ? { sender: input.sender } : {}),
        queued: reason === "outcome: queued" || reason.startsWith("outcome: queued."),
      });
    } else if (step.kind === "note" && step.id.startsWith("report:") && step.text?.startsWith("[")) {
      const end = step.text.indexOf("] ");
      if (end < 0) continue;
      out.push({
        id: step.id,
        seq: step.seq,
        peer: step.text.slice(1, end),
        outgoing: false,
        text: step.text.slice(end + 2),
        at,
        queued: false,
      });
    }
  }
  return out;
}

/** A report that is only a status note ("(stopped without a report: …)", "(gone: …)",
 * "(its report could not be read …)"): the agent stopped (HomeAgentMessageRow.statusNote). */
export function isStatusNote(value: string): boolean {
  const line = value.trim();
  if (!line.startsWith("(") || !line.endsWith(")") || line.includes("\n")) return false;
  const inner = line.slice(1, -1);
  return (
    inner.startsWith("stopped without a report: its session is ") ||
    inner.startsWith("gone:") ||
    inner.startsWith("its report could not be read")
  );
}

const TITLE_LENGTH = 32;

/** `value`'s `Title:` line's words; none when it has none. */
function titleLine(value: string): string | undefined {
  for (const line of value.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.toLowerCase().startsWith("title:")) continue;
    const title = trimmed.slice("title:".length).trim();
    if (title) return title;
  }
  return undefined;
}

/** A task's title (HomeAgentMessageRow.title): its `Title:` line, else its first clause cut at a word
 * edge to about 32 characters, with no trailing punctuation. */
export function taskTitle(value: string): string | undefined {
  const named = titleLine(value);
  if (named) return named;
  const first = value
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean);
  if (!first) return undefined;
  let clause = first.replaceAll("**", "").replaceAll("`", "");
  const colon = clause.indexOf(":");
  if (colon >= 0) {
    // A quoted message's speaker header ("User (Nov 4): …") names who spoke, not the task.
    const words = clause.slice(0, colon).toLowerCase().split(" ").filter(Boolean);
    if (words.length && words.length <= 4 && (words[0] === "user" || (words[0] === "the" && words[1] === "user")))
      clause = clause.slice(colon + 1).replace(/^[\s"“”']+|[\s"“”']+$/g, "");
  }
  for (const mark of [":", ",", ";", " - ", ". ", "? ", "! "]) {
    const cut = clause.indexOf(mark);
    if (cut >= 0) clause = clause.slice(0, cut);
  }
  let title = "";
  for (const word of clause.split(" ").filter(Boolean)) {
    const next = title ? `${title} ${word}` : word;
    if (title && next.length > TITLE_LENGTH) break;
    title = next;
  }
  return title.replace(/[.,;:!?\-–—\s]+$/u, "") || undefined;
}

interface Placed extends AgentRunMessage {
  /** The message id the agents row goes under. */
  anchor: string;
}

const wordChar = (char: string | undefined) => !!char && /[\p{L}\p{N}_]/u.test(char);

/** `text` names `peer` as a whole word (HomeAgentMessages.mentions). */
export function mentions(text: string, peer: string): boolean {
  if (!peer) return false;
  for (let at = text.indexOf(peer); at >= 0; at = text.indexOf(peer, at + peer.length))
    if (!wordChar(text[at - 1]) && !wordChar(text[at + peer.length])) return true;
  return false;
}

/** The characters a `send` key's hash takes at its end: `-` and 16 hex digits. */
const SEND_HASH = 17;

/** Each run's agent messages with the message their row goes under (HomeAgentMessages.inserting):
 * the turn's `send` (the main line's first), else the newest loaded message it answered, else its
 * reply. A run anchored to none of `messages` has no row. */
function placed(messages: readonly HomeMessage[], entries: readonly RunEntry[]): Placed[] {
  const byKey = new Map<string, HomeMessage>();
  const byId = new Map<string, HomeMessage>();
  const sends = new Map<string, HomeMessage[]>();
  for (const message of messages) {
    byId.set(message.id, message);
    const key = message.clientMessageId;
    if (!key) continue;
    byKey.set(`${key}\0${message.author}`, message);
    if (key.startsWith("send-") && key.length > SEND_HASH) {
      const turn = key.slice(0, -SEND_HASH);
      sends.set(turn, [...(sends.get(turn) ?? []), message]);
    }
  }
  const out: Placed[] = [];
  for (const entry of entries) {
    const run = entry.run;
    const reply = run.turn ? byKey.get(`${run.turn}\0${run.author}`) : undefined;
    const answer = run.answers
      .map((id) => byId.get(id))
      .filter((message): message is HomeMessage => !!message)
      .sort((a, b) => b.seq - a.seq)[0];
    const turnSends = (run.turn ? sends.get(`send-${run.conversation}-${run.turn}`) : undefined)?.filter(
      (message) => message.author === run.author,
    );
    const said = turnSends?.find((message) => !message.threadRoot) ?? turnSends?.[0];
    const anchor = said ?? answer ?? reply;
    if (!anchor) continue;
    for (const message of agentMessages(entry.steps, run.startedAt)) {
      // A turn that answered several asks in their own threads: an agent's pill goes beside the send
      // that names it (the main line's first when several do), else beside the turn's first send.
      const naming = turnSends?.filter((send) => mentions(plain(send), message.peer));
      const named = naming?.find((send) => !send.threadRoot) ?? naming?.[0];
      out.push({ ...message, anchor: (named ?? anchor).id });
    }
  }
  return out;
}

/** Each agent's name over every run: the `Title:` line of the earliest message to it that has one. */
function taskTitles(all: readonly AgentRunMessage[]): Map<string, string> {
  const titles = new Map<string, { at: number; title: string }>();
  for (const message of all) {
    if (!message.outgoing) continue;
    const held = titles.get(message.peer);
    if (held && held.at <= message.at) continue;
    const title = titleLine(message.text);
    if (title) titles.set(message.peer, { at: message.at, title });
  }
  return new Map([...titles].map(([peer, { title }]) => [peer, title]));
}

/** The agents rows of the loaded messages, by the message each goes under (HomeAgentMessages.fold):
 * one pill per agent the Chief told or heard from after that message, in first-seen order, each
 * agent only in the row of its newest message (so the pill says where it stands now). A pill's
 * state is its newest message's (told, queued, reported, stopped); a report newer than `seen` (the
 * newest report the person opened, by agent) shows the unread dot. `started`: agents known to run,
 * so a queued one says Working. */
export function agentRows(
  messages: readonly HomeMessage[],
  entries: readonly RunEntry[],
  seen: ReadonlyMap<string, number> = new Map(),
  started: ReadonlySet<string> = new Set(),
): Map<string, AgentsRow> {
  const all = placed(messages, entries).sort((a, b) => a.at - b.at || a.seq - b.seq);
  if (!all.length) return new Map();
  const newest = new Map<string, string>();
  for (const message of all) newest.set(message.peer, message.anchor);
  const titles = taskTitles(all);
  const groups = new Map<string, Placed[]>();
  for (const message of all) groups.set(message.anchor, [...(groups.get(message.anchor) ?? []), message]);
  const out = new Map<string, AgentsRow>();
  for (const [anchor, members] of groups) {
    const peers: string[] = [];
    const states = new Map<string, AgentPeerState>();
    const firstTitles = new Map<string, string>();
    const reportedAt = new Map<string, number>();
    for (const member of members) {
      if (!peers.includes(member.peer)) peers.push(member.peer);
      if (member.outgoing) {
        states.set(member.peer, member.queued && !started.has(member.peer) ? "queued" : "told");
        if (!firstTitles.has(member.peer)) {
          const title = taskTitle(member.text);
          if (title) firstTitles.set(member.peer, title);
        }
      } else if (isStatusNote(member.text)) {
        states.set(member.peer, "stopped");
      } else {
        states.set(member.peer, "reported");
        reportedAt.set(member.peer, member.at);
      }
    }
    const shown = peers.filter((peer) => newest.get(peer) === anchor);
    if (!shown.length) continue;
    out.set(anchor, {
      peers: shown,
      titles: shown.map((peer) => titles.get(peer) ?? firstTitles.get(peer) ?? peer),
      states: shown.map((peer) => states.get(peer) ?? "told"),
      unread: shown.map((peer) => {
        const at = reportedAt.get(peer);
        if (states.get(peer) !== "reported" || at === undefined) return false;
        const read = seen.get(peer);
        return read === undefined || read < at;
      }),
    });
  }
  return out;
}

/** The Chief's link to `peer`'s session in its words (`[a3](cmux://chief/<8 hex>/session/<id>)`), the last one. */
export function workspaceLink(peer: string, texts: Iterable<string>): string | undefined {
  const label = `[${peer}](cmux://chief/`;
  let found: string | undefined;
  for (const value of texts) {
    let from = 0;
    for (;;) {
      const start = value.indexOf(label, from);
      if (start < 0) break;
      const target = start + peer.length + 3;
      const end = value.indexOf(")", target);
      if (end < 0) break;
      const link = value.slice(target, end);
      if (/^cmux:\/\/chief\/[0-9a-f]{8}\/session\/[A-Za-z0-9._-]{1,200}$/.test(link)) found = link;
      from = end;
    }
  }
  return found;
}

const plain = (message: HomeMessage) =>
  message.parts
    .map((part) => (part.type === "text" || part.type === "other" ? part.text : ""))
    .filter(Boolean)
    .join("\n");

/** The Chief's link to `peer`'s session in the loaded messages not mine (the pill's target); none
 * while it has no workspace yet (a queued agent), and the pill then opens nothing. */
export function agentWorkspaceLink(peer: string, messages: readonly HomeMessage[], me?: string): string | undefined {
  return workspaceLink(peer, messages.filter((message) => message.author !== me).map(plain));
}

/** The agents still waiting for a slot in the rows, in the order the Chief starts them (lowest id first,
 * HomeStore.queuedAgents): a queued agent's card says how many are ahead of it. */
export function queuedPeers(rows: Iterable<AgentsRow>): string[] {
  const out: string[] = [];
  for (const row of rows)
    row.peers.forEach((peer, index) => {
      if (row.states?.[index] === "queued") out.push(peer);
    });
  const number = (peer: string) => Number(/\d+$/.exec(peer)?.[0] ?? Number.NaN);
  return out.sort((a, b) => number(a) - number(b) || (a < b ? -1 : a > b ? 1 : 0));
}

/** `peer`'s newest report time (its pill's unread dot clears once the person opened it). */
export function newestReportAt(peer: string, entries: readonly RunEntry[]): number | undefined {
  let newest: number | undefined;
  for (const entry of entries)
    for (const message of agentMessages(entry.steps, entry.run.startedAt))
      if (message.peer === peer && !message.outgoing && (newest === undefined || message.at > newest))
        newest = message.at;
  return newest;
}
