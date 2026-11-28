// The chats this chat's agent started with the cmux-subsessions `start_session` tool (acpmux
// `startedBy`, hub/subsessions.rs), as the pane follows them: each one's name among its parent's
// (`shortName`), its live state (working, waiting on the person, failed, done), whether it has news,
// how many messages wait behind its turn, what its turn does now, and while it waits on the
// person, what for (a question or a permission, which only the person answers). The summary card's Subagents
// section lists them under the chat's own subagents (summary/SubagentStatusList.tsx), and the
// transcript's sub-session cards (conversation/SubsessionCallCard.tsx) read one's state live from
// a small store fed from the session list, so a card never redraws its turn when a session changes.
import { createContext, useContext, useMemo, useSyncExternalStore } from "react";
import type { StringKey, Translate } from "../i18n";
import type { RetryState } from "./retryState";
import { cloudHost, listed, type AcpmuxSessionEntry, type SessionWaiting } from "../sessionList";
import { replacedSince, sessionIndex } from "../sessionIndex";
import { resolveSenderIdentity, type SenderIdentity, type SenderReference } from "../senderIdentity";
import type { HarnessIconSpec } from "../../shared/harnessIcons";

/// What a sub-session is doing: its turn runs, it waits on the person (a permission or a question),
/// its turn failed or its agent went away, or it is done until it is sent more.
export type SubsessionState = "working" | "input" | "failed" | "done";

export type SubsessionInfo = {
  sessionId: string;
  /// Its harness identity, used by every session list and card.
  harness?: string;
  /// Its short name, else its title.
  name: string;
  /// Its title (what the chat is about), when it has one apart from `name`: a finished task's line
  /// in its parent's transcript names it by this (conversation/TaskLine.tsx).
  title?: string;
  state: SubsessionState;
  /// Its last turn ended and nobody has looked at it yet.
  unread?: true;
  /// Messages waiting behind its running turn.
  queued?: number;
  /// What its running turn does now, while it works.
  doing?: string;
  /// What it waits on the person for, while it does and acpmux says.
  waiting?: SessionWaiting;
  /// It waits for a run slot (its parent runs `maxRunning` already): it has not started.
  slot?: true;
  /// Its model, as acpmux names it.
  model?: string;
  /// Its thinking effort, as acpmux names it.
  effort?: string;
  /// Its parent session id, from the proven `startedBy` link.
  parent?: string;
  /// The latest bounded message text from the session summary.
  lastMessage?: string;
  /// acpmux's retry of its failed turn, while one waits (retryState.ts).
  retry?: RetryState;
  /// acpmux settles, starts or runs its failed turn's retry: no Retry meanwhile.
  retryDeciding?: true;
  /** Why its turn failed, while it is failed (acpmux's `lane.error`). */
  error?: string;
  /// When its last turn ended stopped, while it is done: it offers Resume (resumeState.ts).
  stoppedAt?: number;
};

/// The user-facing name for a session. Keep the raw id in `session.name` for matching and
/// diagnostics, but never expose an opaque optchat id as the identity in a row.
export function subsessionDisplayName(t: Translate, session: Pick<SubsessionInfo, "name" | "sessionId">): string {
  return session.name === session.sessionId || OPAQUE_ID.test(session.name) ? t("tray.kind.subagent") : session.name;
}

/// An optchat session id, which names nothing.
const OPAQUE_ID = /(?:^|\/)optchat-[0-9a-f]{8,}(?:-[0-9a-f]+)*$/iu;

/// A subagent's name as a line shows it: until a record names it (history paged in after its spawn
/// carries none), its name is its raw `<session>/<tool call>` id, which the fold keeps for routing
/// and the line shows as the localized "Subagent" instead (Leo, 2026-10-22, on "Subagent finished:
/// 01a15779-…/toolu_01H9…": "this needs to be rendered better"). A raw id is Claude's
/// `<session>/<tool call>` or Codex's bare thread UUID; a name equal to any other id is a real
/// name a record gave it, so it stays.
/// `child`: the name a sub-session's own chat gives it (`subsessionName`), before "Subagent": a
/// finished sub-session's fold record often names nothing, while its chat has a title.
export function subagentDisplayName(
  t: Translate,
  agent: { id: string; name: string; task?: string; kind?: string; prompt?: string },
  child?: string,
): string {
  return namedBy(agent, agent.name) ?? fallbackName(agent) ?? child ?? t("tray.kind.subagent");
}

/// A subagent's label on the running tray's line: what it was asked to do (Claude's Agent
/// `description`, a workflow's summary), as Claude Code's and ChatGPT's task rows name a task; else
/// its name; "Subagent" only when nothing names it (Leo, 2026-11-02, on a done line that read just
/// "Subagent": "this running thing now looks mildly awkward"). Its name stays in the tooltip.
export function subagentTaskLabel(
  t: Translate,
  agent: { id: string; name: string; task?: string; kind?: string; prompt?: string },
  child?: string,
): string {
  return namedBy(agent, firstLine(agent.task)) ?? subagentDisplayName(t, agent, child);
}

/// What a sub-session's own chat calls it: its title, else its name unless that is only its id
/// (an opaque optchat id names nothing); undefined when neither names it.
export function subsessionName(
  session: Pick<SubsessionInfo, "name" | "sessionId" | "title"> | undefined,
): string | undefined {
  if (!session) return undefined;
  if (session.title?.trim()) return session.title.trim();
  return session.name === session.sessionId || OPAQUE_ID.test(session.name) ? undefined : session.name;
}

/// Whether anything names the subagent (its task, its name, what it was asked, its kind), so a line
/// can show it by more than the generic "Subagent" or its raw id. A start line names only these, and
/// counts the rest (runningTray.ts `startedLine`).
export function subagentNamed(agent: {
  id: string;
  name: string;
  task?: string;
  kind?: string;
  prompt?: string;
}): boolean {
  return (namedBy(agent, firstLine(agent.task)) ?? namedBy(agent, agent.name) ?? fallbackName(agent)) !== undefined;
}

/// `text` when it names the subagent: not empty and not one of its raw ids.
function namedBy(agent: { id: string; name: string }, text: string | undefined): string | undefined {
  if (!text) return undefined;
  const rawId = agent.id.includes("/") || /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/iu.test(agent.id);
  return (text === agent.id && rawId) || /(?:^|\/)toolu_[0-9A-Za-z]+$/u.test(text) ? undefined : text;
}

/// What still names a subagent its record left unnamed: its task, the first line of what it was
/// asked, then its kind (Explore, general-purpose).
function fallbackName(agent: { id: string; name: string; task?: string; kind?: string; prompt?: string }) {
  return namedBy(agent, firstLine(agent.task)) ?? namedBy(agent, firstLine(agent.prompt)) ?? namedBy(agent, agent.kind);
}

const firstLine = (text: string | undefined) =>
  text
    ?.split("\n")
    .map((line) => line.trim())
    .find(Boolean);

/// What a sub-session waiting on the person waits for, in one line: a question (and its first
/// prompt, which the line cuts when there is no room), a tool's permission, a secret, a command to
/// run as root or an MCP server to connect. Only the person answers it, in its chat (person proof):
/// its parent's agent cannot, so the line says where.
export function waitingLine(t: Translate, waiting: SessionWaiting): string {
  if (waiting.on === "permission") return t("subsession.waitingPermission");
  if (waiting.on === "secret") return t("subsession.waitingSecret");
  if (waiting.on === "elevation") return t("subsession.waitingElevation");
  if (waiting.on === "mcpConnect") return t("subsession.waitingMcpConnect");
  const line = t("subsession.waitingQuestion");
  return waiting.prompt ? `${line} · ${waiting.prompt}` : line;
}

/// Each state's word.
export const SUBSESSION_STATE_LABEL: Record<SubsessionState, StringKey> = {
  working: "subsession.state.working",
  input: "subsession.state.input",
  failed: "subagents.state.failed",
  done: "subagents.state.completed",
};

/// acpmux's lane (`lane.state`) when it gives one, else its status dot, else its status.
export function subsessionState(entry: AcpmuxSessionEntry): SubsessionState {
  switch (entry.lane ?? entry.indicator) {
    case "working":
      return "working";
    case "input":
      return "input";
    case "failed":
    case "lost":
      return "failed";
    case "idle":
    case "done":
      return "done";
  }
  if (entry.status === "running") return "working";
  if (entry.status === "waiting") return "input";
  return "done";
}

export function subsessionInfo(entry: AcpmuxSessionEntry): SubsessionInfo {
  const state = subsessionState(entry);
  const name = entry.shortName || entry.displayTitle || entry.title || entry.sessionId;
  // Its first title that is not only its name or id: sessionEntry's display title is the session's
  // name (`lead/october-review`) whenever acpmux gave it one, which would hide the real title.
  const title = [entry.displayTitle, entry.title].find(
    (candidate) => candidate && candidate !== name && candidate !== entry.name && candidate !== entry.sessionId,
  );
  return {
    sessionId: entry.sessionId,
    ...(entry.harness ? { harness: entry.harness } : {}),
    name,
    ...(title ? { title } : {}),
    state,
    ...(state === "done" && entry.unread ? { unread: true as const } : {}),
    ...(entry.queued ? { queued: entry.queued } : {}),
    ...(state === "working" && entry.doing ? { doing: entry.doing } : {}),
    ...(state === "input" && entry.waitingOn ? { waiting: entry.waitingOn } : {}),
    ...(entry.waitsForSlot ? { slot: true as const } : {}),
    ...(entry.model ? { model: entry.model } : {}),
    ...(entry.effort ? { effort: entry.effort } : {}),
    ...(entry.startedBy ? { parent: entry.startedBy } : {}),
    ...(entry.lastMessage ? { lastMessage: entry.lastMessage } : {}),
    // Read through retryState.ts ``sessionRetry``, which ignores them on a row that isn't failed.
    ...(entry.retry ? { retry: entry.retry } : {}),
    ...(entry.retryDeciding ? { retryDeciding: true as const } : {}),
    ...(state === "failed" && !entry.retry && entry.laneError ? { error: entry.laneError } : {}),
    // Only a sub-session's stop resumes (hub/subsession_resume.rs): one its parent started.
    ...(state === "done" && entry.startedBy && entry.stoppedAt !== undefined ? { stoppedAt: entry.stoppedAt } : {}),
  };
}

/// What SubsessionStore's name index (names, harnesses, runs, places, machines, senders) reads of a
/// listed chat, as one string: an entry whose string did not change leaves the index as it is.
function nameFields(entry: AcpmuxSessionEntry): string {
  return JSON.stringify([
    entry.name,
    entry.displayName,
    entry.formerNames,
    iconKey(entry.icon),
    entry.shortName,
    entry.peer,
    entry.harness,
    entry.host,
    entry.hostKind,
    entry.startedBy,
    entry.spawnedBy,
    entry.archived ?? false,
    entry.model,
    entry.effort,
    entry.cwd,
    // Read only as another machine's chat's name in its machine menu, when it has no name.
    cloudHost(entry) && !entry.name?.trim() ? entry.displayTitle : undefined,
    cloudHost(entry) ?? "",
    listed(entry),
  ]);
}

/// What tells a chat's icon from another (an image's own bytes stand in by length and tail, so a
/// favicon's base64 is not copied into every key).
function iconKey(icon: AcpmuxSessionEntry["icon"]): string | undefined {
  if (!icon) return undefined;
  switch (icon.kind) {
    case "image":
      return `image:${icon.mime}:${icon.data.length}:${icon.data.slice(-24)}`;
    case "brand":
      return `brand:${icon.brand}`;
    case "symbol":
      return `symbol:${icon.name}:${icon.text}:${icon.hue}`;
    case "emoji":
    case "monogram":
      return `${icon.kind}:${icon.text}`;
    case "glyph":
      return `glyph:${icon.name}`;
  }
}

/// A sub-session's row in the summary card: `depth` 0 for one this chat started, 1 for one that
/// one started, and so on.
export type SubsessionRow = SubsessionInfo & { depth: number };

/// Each state's place on one level: what needs the person first, then what runs, then what ended.
const RANK: Record<SubsessionState, number> = { input: 0, working: 1, failed: 2, done: 2 };

/// The sub-sessions chat `chatId` started, each followed by its own, depth first; archived ones
/// left out. On each level, those waiting on the person first, then the working ones, then the
/// ended ones, each newest first.
export function subsessionRows(sessions: readonly AcpmuxSessionEntry[], chatId: string | undefined): SubsessionRow[] {
  if (!chatId) return [];
  const children = new Map<string, AcpmuxSessionEntry[]>();
  // Among the chats another started only (sessionIndex.ts), not every listed chat.
  for (const entry of sessionIndex(sessions).of("started")) {
    if (!entry.startedBy || entry.archived) continue;
    const list = children.get(entry.startedBy);
    if (list) list.push(entry);
    else children.set(entry.startedBy, [entry]);
  }
  const out: SubsessionRow[] = [];
  // A session listed twice (a peer's copy) or a loop in the links draws once.
  const seen = new Set<string>([chatId]);
  const visit = (parent: string, depth: number) => {
    const level = (children.get(parent) ?? [])
      .filter((entry) => !seen.has(entry.sessionId))
      .map((entry) => ({ entry, info: subsessionInfo(entry) }))
      .sort((a, b) => RANK[a.info.state] - RANK[b.info.state] || (b.entry.createdAt ?? 0) - (a.entry.createdAt ?? 0));
    for (const { entry, info } of level) {
      if (seen.has(entry.sessionId)) continue;
      seen.add(entry.sessionId);
      out.push({ ...info, depth });
      visit(entry.sessionId, depth + 1);
    }
  };
  visit(chatId, 0);
  return out;
}

/// Every listed session's sub-session view by id, which cards read with ``useSubsessionInfo``.
/// One listed chat as the name index holds it: what it adds to each of the index's maps, so a change
/// takes out exactly what the entry put in.
type NameRow = {
  entry: AcpmuxSessionEntry;
  /// What the index reads of the entry (``nameFields``): an entry with the same one changes nothing in it.
  sig: string;
  /// The names it answers to (``nameLabels``), and whether it counts as archived for them.
  labels: readonly string[];
  /// Its former names (acpmux `formerNames`, "fka"): each names it only where no chat has it now.
  formers: readonly string[];
  archived: boolean;
  harness?: string;
  host?: string;
  run?: SenderRun;
  place?: SenderPlace;
  /// Its line in its machine's menu, when it has one.
  machine?: MachineChat;
  /// What its readers see of it: an entry whose key is the same tells no name reader.
  key: string;
};

/// The names a listed chat answers to: its name, the name it was given ("Mango", acpmux `displayName`,
/// which signs its messages too), its short name, and a peer chat's bare name (listed as
/// `<peer>/<name>`, it may sign a message with the bare one).
function nameLabels(entry: AcpmuxSessionEntry): string[] {
  const labels: string[] = [];
  const add = (name: string | undefined) => {
    const label = name?.trim();
    if (label && !labels.includes(label)) labels.push(label);
  };
  add(entry.name);
  add(entry.displayName);
  add(entry.shortName);
  const name = entry.name?.trim();
  add(entry.peer && name?.startsWith(`${entry.peer}/`) ? name.slice(entry.peer.length + 1) : undefined);
  return labels;
}

/// A listed chat's former names, trimmed, each once.
function formerLabels(entry: AcpmuxSessionEntry): string[] {
  const labels: string[] = [];
  for (const former of entry.formerNames ?? []) {
    const label = former.trim();
    if (label && !labels.includes(label)) labels.push(label);
  }
  return labels;
}

/// A machine menu's order: by name, then id.
const byMachineName = (a: MachineChat, b: MachineChat) =>
  a.name.localeCompare(b.name) || (a.sessionId < b.sessionId ? -1 : a.sessionId > b.sessionId ? 1 : 0);

function nameRow(entry: AcpmuxSessionEntry, sig: string, before: NameRow | undefined): NameRow {
  const id = entry.sessionId;
  const host = cloudHost(entry);
  const cwd = entry.cwd?.trim();
  const run =
    entry.model || entry.effort
      ? { ...(entry.model && { model: entry.model }), ...(entry.effort && { effort: entry.effort }) }
      : undefined;
  const place = cwd || host ? { ...(cwd && { cwd }), ...(host && { host }) } : undefined;
  let machine: MachineChat | undefined;
  if (host && listed(entry)) {
    // A peer's chat is listed as `<machine>/<name>`: the machine's menu already names the machine.
    const full = entry.name?.trim() || entry.displayTitle?.trim() || id;
    const name = full.startsWith(`${host}/`) && full.length > host.length + 1 ? full.slice(host.length + 1) : full;
    machine = { sessionId: id, name };
  }
  const key = JSON.stringify([
    entry.harness,
    host,
    run,
    place,
    machine?.name,
    entry.name,
    entry.displayName,
    entry.formerNames,
    iconKey(entry.icon),
    entry.shortName,
    entry.peer,
    entry.host,
    entry.hostKind,
    entry.startedBy,
    entry.spawnedBy,
  ]);
  const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
  return {
    entry,
    sig,
    labels: nameLabels(entry),
    formers: formerLabels(entry),
    archived: Boolean(entry.archived),
    ...(entry.harness && { harness: entry.harness }),
    ...(host && { host }),
    // An unchanged value keeps its object, so a reader of it does not draw again.
    ...(run && { run: before?.run && same(before.run, run) ? before.run : run }),
    ...(place && { place: before?.place && same(before.place, place) ? before.place : place }),
    ...(machine && { machine: before?.machine?.name === machine.name ? before.machine : machine }),
    key,
  };
}

export class SubsessionStore {
  private infos = new Map<string, SubsessionInfo>();
  private keys = new Map<string, string>();
  private readonly listeners = new Set<() => void>();

  private entries = new Map<string, AcpmuxSessionEntry>();
  private senders = new Map<string, AcpmuxSessionEntry>();
  /// `senders` as its readers get it: the same map until a name changes (``senderEntries``).
  private sendersView: ReadonlyMap<string, AcpmuxSessionEntry> | undefined;
  /// Every listed chat's id by its names (its name, its short name; not its title, which can be
  /// "New chat"), and by id its harness and the other machine it runs on: another agent's message
  /// names its sender, which a card marks with its harness and opens, its tooltip naming that
  /// machine. Their readers have their own listeners, so a chat's name changing never tells a
  /// sub-session card.
  private named = new Map<string, string>();
  private harnesses = new Map<string, string>();
  /// By id, the model and thinking effort each listed chat runs on, for a sender's hover.
  private runs = new Map<string, SenderRun>();
  private hosts = new Map<string, string>();
  /// Where each listed chat works, by id: its folder and the other machine it runs on, for the
  /// files its messages name (IncomingMessageCard.tsx), read with the same listeners.
  private places = new Map<string, SenderPlace>();
  /// By machine, the listed chats that run on it, by name (a received line's machine menu,
  /// IncomingMessageCard.tsx MachineMenu); this Mac's chats are under none.
  private machines = new Map<string, readonly MachineChat[]>();
  private ids = new Set<string>();
  /// The name index by chat, and by each name the chats that answer to it, live and archived: a
  /// session's change, arrival or departure moves only its own names (Leo, 2026-11-22: "Why should
  /// non visible thing even affect the renderer thread anyways?"; at 3,000 listed chats every new
  /// chat rebuilt the whole index on the renderer's main thread). Undefined while the list names a
  /// session twice, which ``setWhole`` reads.
  private rows: Map<string, NameRow> | undefined;
  private candidates = new Map<string, { live: Set<string>; archived: Set<string> }>();
  /// The chats each former name was once theirs; read for a name only when no chat has it now.
  private formerCandidates = new Map<string, { live: Set<string>; archived: Set<string> }>();
  /// For a list that names a session twice (``setWhole``): what the index read of each entry, and
  /// the index's whole content, which says whether a name reader is told.
  private nameFrom = new Map<string, AcpmuxSessionEntry>();
  private nameSigs = new Map<string, string>();
  private nameCount = -1;
  private namedKey = "";
  /// The list the last `set` was given: a list made from it in place (sessionIndex.ts `noteReplaced`)
  /// is patched at the replaced entries only, with no lookup per listed chat.
  private last: readonly AcpmuxSessionEntry[] | undefined;
  private readonly nameListeners = new Set<() => void>();

  senderEntries = (): ReadonlyMap<string, AcpmuxSessionEntry> => {
    this.rebuild();
    return (this.sendersView ??= new Map(this.senders));
  };

  /// Replaces the views with those of the sub-sessions among `sessions`; one whose content did not
  /// change keeps its object. The pane sends the list with every snapshot, reusing the entry of a
  /// session that did not change, so an entry seen last time is not read again: a call costs the
  /// entries that changed, came or went, not one per listed chat.
  set(sessions: readonly AcpmuxSessionEntry[]): void {
    if (this.released) {
      this.dirty ||= sessions !== this.pending;
      this.pending = sessions;
      return;
    }
    const last = this.last;
    this.last = sessions;
    const change = this.changeSince(last, sessions);
    if (change) this.apply(change.removed, change.upserts);
    else this.setWhole(sessions);
  }

  /// Takes the chats `removed` out of the index and puts `upserts` in, each in place of what it put
  /// in before: O(their names and fields), whatever the list's length. `renamed` tells every name
  /// reader even when no name moved (an index built again).
  private apply(removed: readonly string[], upserts: readonly AcpmuxSessionEntry[], renamed = false): void {
    let changed = false;
    const touched = new Set<string>();
    const rows = this.rows!;
    const drop = (row: NameRow) => {
      const id = row.entry.sessionId;
      for (const label of row.labels) {
        const matches = this.candidates.get(label);
        if (!matches) continue;
        (row.archived ? matches.archived : matches.live).delete(id);
        if (!matches.live.size && !matches.archived.size) this.candidates.delete(label);
        touched.add(label);
      }
      for (const label of row.formers) {
        const matches = this.formerCandidates.get(label);
        if (!matches) continue;
        (row.archived ? matches.archived : matches.live).delete(id);
        if (!matches.live.size && !matches.archived.size) this.formerCandidates.delete(label);
        touched.add(label);
      }
      this.harnesses.delete(id);
      this.hosts.delete(id);
      this.runs.delete(id);
      this.places.delete(id);
      if (row.machine) this.moveMachine(row.host!, row.machine, undefined);
    };
    const add = (row: NameRow) => {
      const id = row.entry.sessionId;
      for (const label of row.labels) {
        let matches = this.candidates.get(label);
        if (!matches) this.candidates.set(label, (matches = { live: new Set(), archived: new Set() }));
        (row.archived ? matches.archived : matches.live).add(id);
        touched.add(label);
      }
      for (const label of row.formers) {
        let matches = this.formerCandidates.get(label);
        if (!matches) this.formerCandidates.set(label, (matches = { live: new Set(), archived: new Set() }));
        (row.archived ? matches.archived : matches.live).add(id);
        touched.add(label);
      }
      if (row.harness) this.harnesses.set(id, row.harness);
      if (row.host) this.hosts.set(id, row.host);
      if (row.run) this.runs.set(id, row.run);
      if (row.place) this.places.set(id, row.place);
      if (row.machine) this.moveMachine(row.host!, undefined, row.machine);
    };
    for (const id of removed) {
      const row = rows.get(id);
      if (row) {
        drop(row);
        rows.delete(id);
        this.ids.delete(id);
        this.senders.delete(id);
        renamed = true;
      }
      if (this.infos.delete(id)) changed = true;
      this.keys.delete(id);
      this.entries.delete(id);
    }
    for (const entry of upserts) {
      const id = entry.sessionId;
      const before = rows.get(id);
      if (before?.entry === entry) continue;
      const sig = nameFields(entry);
      if (before?.sig === sig) before.entry = entry;
      else {
        // The senders map hands out entries only when names change, as before.
        this.senders.set(id, entry);
        const row = nameRow(entry, sig, before);
        if (before) drop(before);
        else this.ids.add(id);
        add(row);
        rows.set(id, row);
        if (row.key !== before?.key) renamed = true;
      }
      if (!entry.startedBy) {
        if (this.infos.delete(id)) changed = true;
        this.keys.delete(id);
        this.entries.delete(id);
        continue;
      }
      if (this.entries.get(id) === entry && this.infos.has(id)) continue;
      const next = subsessionInfo(entry);
      const key = JSON.stringify(next);
      this.entries.set(id, entry);
      if (this.keys.get(id) === key) continue;
      this.infos.set(id, next);
      this.keys.set(id, key);
      changed = true;
    }
    // A name resolves only when it identifies exactly one live session (across peers two live chats
    // can share one, and opening the first would show the wrong chat); archived chats are a fallback
    // when no live session uses it. All aliases of one session count once. A former name counts only
    // where no listed chat has it as a name now.
    for (const label of touched) {
      const matches = this.candidates.get(label) ?? this.formerCandidates.get(label);
      const active = matches && (matches.live.size ? matches.live : matches.archived);
      const id = active?.size === 1 ? active.values().next().value! : undefined;
      if (id === this.named.get(label)) continue;
      if (id) this.named.set(label, id);
      else this.named.delete(label);
      renamed = true;
    }
    if (renamed) {
      this.sendersView = undefined;
      this.notify(this.nameListeners);
    }
    if (changed) this.notify(this.listeners);
  }

  /// What changed from `last` to `sessions`: the ids that left and the entries that are new or not
  /// the object indexed. O(changed) for a list made from the last in place (`noteReplaced`), else a
  /// pass of identity checks with no field read. Undefined (``setWhole`` reads the list) before the
  /// first list, after one that named a session twice, and for one that does.
  private changeSince(
    last: readonly AcpmuxSessionEntry[] | undefined,
    sessions: readonly AcpmuxSessionEntry[],
  ): { removed: readonly string[]; upserts: readonly AcpmuxSessionEntry[] } | undefined {
    const rows = this.rows;
    if (!rows) return undefined;
    const replaced = replacedSince(last, sessions);
    if (replaced) return { removed: [], upserts: replaced.map((at) => sessions[at]!) };
    // The last list with chats listed after it (a new chat): the earlier ones are the same objects.
    if (last && sessions.length > last.length && rows.size === last.length) {
      let at = 0;
      while (at < last.length && sessions[at] === last[at]) at++;
      if (at === last.length) {
        const added = sessions.slice(at);
        const ids = new Set(added.map((entry) => entry.sessionId));
        if (ids.size === added.length && added.every((entry) => !rows.has(entry.sessionId)))
          return { removed: [], upserts: added };
      }
    }
    const upserts: AcpmuxSessionEntry[] = [];
    const seen = new Set<string>();
    let added = 0;
    for (const entry of sessions) {
      const id = entry.sessionId;
      if (seen.has(id)) return undefined;
      seen.add(id);
      const row = rows.get(id);
      if (!row) added += 1;
      if (row?.entry !== entry) upserts.push(entry);
    }
    const removed: string[] = [];
    if (rows.size + added !== seen.size) for (const id of rows.keys()) if (!seen.has(id)) removed.push(id);
    return { removed, upserts };
  }

  /// Chat `from` leaves machine `host`'s menu and `to` takes its place in the menu's order (either
  /// may be absent): the menu is a new array, the others keep theirs.
  private moveMachine(host: string, from: MachineChat | undefined, to: MachineChat | undefined): void {
    const chats = [...(this.machines.get(host) ?? [])];
    if (from) {
      const at = chats.indexOf(from);
      if (at >= 0) chats.splice(at, 1);
    }
    if (to) {
      let low = 0;
      let high = chats.length;
      while (low < high) {
        const mid = (low + high) >>> 1;
        if (byMachineName(chats[mid]!, to) < 0) low = mid + 1;
        else high = mid;
      }
      chats.splice(low, 0, to);
    }
    if (chats.length) this.machines.set(host, chats);
    else this.machines.delete(host);
  }

  /// The whole list read again: the first list, the first after one that named a session twice, and
  /// one that does (``setTwice``). The index is built from nothing by the path a change takes, so the
  /// two never disagree, and every name reader is told.
  private setWhole(sessions: readonly AcpmuxSessionEntry[]): void {
    const ids = new Set<string>();
    for (const entry of sessions) {
      if (ids.has(entry.sessionId)) return this.setTwice(sessions);
      ids.add(entry.sessionId);
    }
    this.rows = new Map();
    this.candidates = new Map();
    this.formerCandidates = new Map();
    this.named = new Map();
    this.harnesses = new Map();
    this.hosts = new Map();
    this.runs = new Map();
    this.places = new Map();
    this.machines = new Map();
    this.ids = new Set();
    this.senders = new Map();
    this.nameFrom = new Map();
    this.nameSigs = new Map();
    this.nameCount = -1;
    this.namedKey = "";
    const gone = [...this.infos.keys()].filter((id) => !ids.has(id));
    this.apply(gone, sessions, true);
  }

  /// A list that names a session twice (a peer's copy): every copy's names count, and the later
  /// copy's fields win, which an index by id cannot say, so the list is read whole. The next list
  /// without a copy builds the index again (``setWhole``).
  private setTwice(sessions: readonly AcpmuxSessionEntry[]): void {
    this.rows = undefined;
    const infos = new Map<string, SubsessionInfo>();
    const keys = new Map<string, string>();
    const entries = new Map<string, AcpmuxSessionEntry>();
    let changed = false;
    // The name index reads every listed chat; it is rebuilt only when one of them changed what it
    // reads (``nameFields``): one chat's status, unread, title or cost changing, which is most of what
    // the pane is told, leaves it as it is and costs one entry's fields, not one per listed chat.
    const nameFrom = new Map<string, AcpmuxSessionEntry>();
    const nameSigs = new Map<string, string>();
    let names = sessions.length !== this.nameCount;
    for (const entry of sessions) {
      const id = entry.sessionId;
      const kept = this.nameFrom.get(id) === entry ? this.nameSigs.get(id) : undefined;
      const sig = kept ?? nameFields(entry);
      if (sig !== this.nameSigs.get(id)) names = true;
      nameFrom.set(id, entry);
      nameSigs.set(id, sig);
    }
    // A session listed twice in place of another keeps the length: the ids' count shows it left.
    if (nameFrom.size !== this.nameFrom.size) names = true;
    // Listed twice, the later entry's names hide the earlier one's: an alias can leave unseen.
    if (nameFrom.size !== sessions.length) names = true;
    this.nameFrom = nameFrom;
    this.nameSigs = nameSigs;
    this.nameCount = sessions.length;
    if (names) {
      const named = new Map<string, string>();
      const harnesses = new Map<string, string>();
      // The sending chat can arrive with only a name (no session ID). Across peers, two
      // live chats can share that name: opening the first one would show the wrong chat.
      // A name resolves only when it identifies exactly one live session; archived chats
      // are a fallback when no live session uses the name. All aliases of the same session
      // count once (its full name, short name and a peer's bare name).
      const candidates = new Map<string, { live: Set<string>; archived: Set<string> }>();
      const addName = (name: string | undefined, entry: AcpmuxSessionEntry) => {
        const label = name?.trim();
        if (!label) return;
        let matches = candidates.get(label);
        if (!matches) candidates.set(label, (matches = { live: new Set(), archived: new Set() }));
        (entry.archived ? matches.archived : matches.live).add(entry.sessionId);
      };
      for (const entry of sessions) {
        addName(entry.name, entry);
        // The name it was given ("Mango", acpmux `displayName`) signs its messages too.
        addName(entry.displayName, entry);
        addName(entry.shortName, entry);
        // A peer chat may be listed as `<peer>/<name>` but sign a message with the
        // bare name. The bare alias is safe only when unique across listed chats.
        const name = entry.name?.trim();
        const bare = entry.peer && name?.startsWith(`${entry.peer}/`) ? name.slice(entry.peer.length + 1) : undefined;
        addName(bare, entry);
      }
      // A former name (acpmux `formerNames`, "fka") still names its chat where no chat has it now.
      const current = new Set(candidates.keys());
      for (const entry of sessions)
        for (const former of entry.formerNames ?? []) if (!current.has(former.trim())) addName(former, entry);
      for (const [name, matches] of candidates) {
        const active = matches.live.size ? matches.live : matches.archived;
        if (active.size === 1) named.set(name, active.values().next().value!);
      }
      const hosts = new Map<string, string>();
      const places = new Map<string, SenderPlace>();
      const runs = new Map<string, SenderRun>();
      const machines = new Map<string, MachineChat[]>();
      for (const entry of sessions) {
        if (entry.harness) harnesses.set(entry.sessionId, entry.harness);
        if (entry.model || entry.effort)
          runs.set(entry.sessionId, {
            ...(entry.model && { model: entry.model }),
            ...(entry.effort && { effort: entry.effort }),
          });
        const host = cloudHost(entry);
        if (host) hosts.set(entry.sessionId, host);
        if (host && listed(entry)) {
          // A peer's chat is listed as `<machine>/<name>`: the machine's menu already names the machine.
          const full = entry.name?.trim() || entry.displayTitle?.trim() || entry.sessionId;
          const name =
            full.startsWith(`${host}/`) && full.length > host.length + 1 ? full.slice(host.length + 1) : full;
          let chats = machines.get(host);
          if (!chats) machines.set(host, (chats = []));
          chats.push({ sessionId: entry.sessionId, name });
        }
        const cwd = entry.cwd?.trim();
        if (cwd || host) places.set(entry.sessionId, { ...(cwd && { cwd }), ...(host && { host }) });
      }
      // Session-list order can change as activity or priority changes. The same identities
      // and metadata should not notify every sender card only because rows were reordered.
      const sorted = <T>(map: Map<string, T>) => [...map].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
      const ids = new Set(sessions.map((entry) => entry.sessionId));
      for (const chats of machines.values())
        chats.sort((a, b) => a.name.localeCompare(b.name) || (a.sessionId < b.sessionId ? -1 : 1));
      const namedKey = JSON.stringify([
        sorted(named),
        sorted(harnesses),
        sorted(places),
        sorted(runs),
        sorted(machines),
        [...ids].sort(),
        [...sessions]
          .sort((a, b) => (a.sessionId < b.sessionId ? -1 : a.sessionId > b.sessionId ? 1 : 0))
          .map(
            ({
              sessionId,
              name,
              displayName,
              formerNames,
              icon,
              shortName,
              peer,
              harness,
              host,
              hostKind,
              startedBy,
              spawnedBy,
            }) => [
              sessionId,
              name,
              displayName,
              formerNames,
              iconKey(icon),
              shortName,
              peer,
              harness,
              host,
              hostKind,
              startedBy,
              spawnedBy,
            ],
          ),
      ]);
      const renamed = namedKey !== this.namedKey;
      this.named = named;
      this.ids = ids;
      this.harnesses = harnesses;
      this.hosts = hosts;
      if (renamed) this.senders = new Map(sessions.map((entry) => [entry.sessionId, entry]));
      if (renamed) this.sendersView = undefined;
      if (renamed) this.places = places;
      if (renamed) this.runs = runs;
      if (renamed) this.machines = machines;
      this.namedKey = namedKey;
      if (renamed) this.notify(this.nameListeners);
    }
    for (const entry of sessions) {
      if (!entry.startedBy) continue;
      const id = entry.sessionId;
      const before = this.infos.get(id);
      let info: SubsessionInfo;
      let key: string;
      if (before && this.entries.get(id) === entry) {
        info = before;
        key = this.keys.get(id)!;
      } else {
        const next = subsessionInfo(entry);
        key = JSON.stringify(next);
        info = before && this.keys.get(id) === key ? before : next;
        if (info !== before) changed = true;
      }
      infos.set(id, info);
      keys.set(id, key);
      entries.set(id, entry);
    }
    if (infos.size !== this.infos.size) changed = true;
    this.infos = infos;
    this.keys = keys;
    this.entries = entries;
    if (changed) this.notify(this.listeners);
  }

  /// The page is hidden: every index made from the list goes, the list stays (the pane's snapshot
  /// holds it). A hidden chat keeps its data and nothing derived from it, so 100 open chats do not
  /// each hold a name index over every listed chat (hq#21290). Lists set while released wait for
  /// ``restore``; a read while released makes the indexes again first, telling no one.
  release(): void {
    if (this.released) return;
    this.pending = this.last;
    this.released = true;
    this.infos = new Map();
    this.keys = new Map();
    this.entries = new Map();
    this.senders = new Map();
    this.sendersView = undefined;
    this.named = new Map();
    this.harnesses = new Map();
    this.runs = new Map();
    this.hosts = new Map();
    this.places = new Map();
    this.machines = new Map();
    this.ids = new Set();
    this.rows = undefined;
    this.candidates = new Map();
    this.formerCandidates = new Map();
    this.namedKey = "";
    this.nameFrom = new Map();
    this.nameSigs = new Map();
    this.nameCount = -1;
    this.last = undefined;
  }

  /// The page shows again: the indexes are made from the latest list, and readers are told when a
  /// list came while it was hidden.
  restore(): void {
    if (!this.released) return;
    const dirty = this.dirty;
    this.rebuild();
    if (dirty) {
      this.notify(this.nameListeners);
      this.notify(this.listeners);
    }
  }

  private released = false;
  /// A list set while released (``dirty``), or the last one before it.
  private pending: readonly AcpmuxSessionEntry[] | undefined;
  private dirty = false;
  private quiet = false;

  private rebuild(): void {
    if (!this.released) return;
    this.released = false;
    this.dirty = false;
    const pending = this.pending;
    this.pending = undefined;
    if (!pending) return;
    this.quiet = true;
    try {
      this.set(pending);
    } finally {
      this.quiet = false;
    }
  }

  private notify(listeners: ReadonlySet<() => void>): void {
    if (this.quiet) return;
    for (const listener of listeners) listener();
  }

  get(sessionId: string): SubsessionInfo | undefined {
    this.rebuild();
    return this.infos.get(sessionId);
  }

  /// The listed chat named `name`, if one is.
  find(name: string): string | undefined {
    this.rebuild();
    return this.named.get(name.trim());
  }

  /// Whether the list has chat `sessionId` (any listed chat, not only a sub-session).
  has(sessionId: string): boolean {
    this.rebuild();
    return this.ids.has(sessionId);
  }

  harness(sessionId: string): string | undefined {
    this.rebuild();
    return this.harnesses.get(sessionId);
  }

  sender(sessionId: string): AcpmuxSessionEntry | undefined {
    this.rebuild();
    return this.senders.get(sessionId);
  }

  /// The model and effort listed chat `sessionId` runs on, when the list names them.
  run(sessionId: string): SenderRun | undefined {
    this.rebuild();
    return this.runs.get(sessionId);
  }

  /// The other machine listed chat `sessionId` runs on; undefined for this Mac's.
  host(sessionId: string): string | undefined {
    this.rebuild();
    return this.hosts.get(sessionId);
  }

  /// The listed chats on machine `host`, by name; none for this Mac's (no host). The same array
  /// until the list changes, so a reader can hand it to `useSyncExternalStore`.
  chatsOn(host: string): readonly MachineChat[] {
    this.rebuild();
    return this.machines.get(host) ?? NO_CHATS;
  }

  /// Where listed chat `sessionId` works: its folder, and the other machine it runs on.
  place(sessionId: string): SenderPlace | undefined {
    this.rebuild();
    return this.places.get(sessionId);
  }

  subscribeNames = (listener: () => void): (() => void) => {
    this.nameListeners.add(listener);
    return () => this.nameListeners.delete(listener);
  };

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
}

/// Where the cards read sessions from, and how a click opens one beside this chat. Absent (a
/// gallery stage, a test), a card draws its name without its state and without a link.
export type Subsessions = {
  store: SubsessionStore;
  open(sessionId: string): void;
  /// Opens the chat that sent this one a message (its received line's chip): any listed chat, not
  /// only this chat's family; `open` when absent.
  openSender?(sessionId: string): void;
  /// Says the sender a received line's chip names is no chat acpmux lists (App.tsx: a notice line),
  /// so the click is never a silent no-op.
  senderMissing?(name: string): void;
};
export const SubsessionContext = createContext<Subsessions | null>(null);

const EMPTY = new SubsessionStore();

/// Session `sessionId`'s view, live while the component shows; undefined while the list does not
/// have it.
export function useSubsessionInfo(sessionId: string | undefined): SubsessionInfo | undefined {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = () => (sessionId ? store.get(sessionId) : undefined);
  return useSyncExternalStore(store.subscribe, read, read);
}

/// A group's children from the same store as useSubsessionInfo. Keep the snapshot stable when
/// unrelated sessions change; subscribe once even when a group gains another start call.
export function useSubsessionInfos(
  sessionIds: readonly (string | undefined)[],
): readonly (SubsessionInfo | undefined)[] {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = useMemo(() => {
    let previous: readonly (SubsessionInfo | undefined)[] = [];
    return () => {
      const next = sessionIds.map((id) => (id ? store.get(id) : undefined));
      if (next.length !== previous.length || next.some((info, index) => info !== previous[index])) previous = next;
      return previous;
    };
  }, [store, sessionIds]);
  return useSyncExternalStore(store.subscribe, read, read);
}

/// Where a message's sender works: its folder (`cwd`), and the other machine it runs on (`host`,
/// undefined for this Mac's).
export type SenderPlace = { cwd?: string; host?: string };

/// The model and thinking effort a listed chat runs on (its sender's hover, IncomingMessageCard.tsx).
export type SenderRun = { model?: string; effort?: string };

/// A listed chat on another machine, as that machine's menu names it.
export type MachineChat = { sessionId: string; name: string };
const NO_CHATS: readonly MachineChat[] = [];

/// Where the chat a message came from works, while the list has it (subsessions.ts `place`).
export function useSenderPlace(sessionId: string | undefined): SenderPlace | undefined {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = () => (sessionId ? store.place(sessionId) : undefined);
  return useSyncExternalStore(store.subscribeNames, read, read);
}

/// The chat a message's sender is: its own id when the message gives one, else the listed chat
/// with its name (a message `acpmux send` sent from a shell names its sender only, a chat on
/// another machine its bare name), that chat's harness and the other machine it runs on. Undefined
/// while the list has neither.
export function useSenderChat(
  name: string,
  sessionId: string | undefined,
): {
  sessionId?: string;
  harness?: string;
  host?: string;
  run?: SenderRun;
  /// The name it was given (acpmux `displayName`) and the icon it set: a sender line shows them first.
  displayName?: string;
  icon?: HarnessIconSpec;
} {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  // `name` may be the chat's id itself (a sender acpmux proved, incomingMessage.ts `lookup`).
  const readId = () => sessionId ?? (store.has(name.trim()) ? name.trim() : store.find(name));
  const id = useSyncExternalStore(store.subscribeNames, readId, readId);
  const readHarness = () => (id ? store.harness(id) : undefined);
  const harness = useSyncExternalStore(store.subscribeNames, readHarness, readHarness);
  const readHost = () => (id ? store.host(id) : undefined);
  const host = useSyncExternalStore(store.subscribeNames, readHost, readHost);
  const readRun = () => (id ? store.run(id) : undefined);
  const run = useSyncExternalStore(store.subscribeNames, readRun, readRun);
  const readEntry = () => (id ? store.sender(id) : undefined);
  const entry = useSyncExternalStore(store.subscribeNames, readEntry, readEntry);
  const displayName = entry?.displayName;
  const icon = entry?.icon;
  return {
    ...(id && { sessionId: id }),
    ...(harness && { harness }),
    ...(host && { host }),
    ...(run && { run }),
    ...(displayName && { displayName }),
    ...(icon && { icon }),
  };
}

/// The listed chats on machine `host`, live while the component shows.
export function useMachineChats(host: string): readonly MachineChat[] {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = () => store.chatsOn(host);
  return useSyncExternalStore(store.subscribeNames, read, read);
}

/** One identity path for preview cards and session lists. No body-text inference. */
export function useSenderIdentity(sender: SenderReference, viewerSessionId?: string): SenderIdentity {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const readId = () => sender.sessionId ?? store.find(sender.name);
  const id = useSyncExternalStore(store.subscribeNames, readId, readId);
  const read = () => (id ? store.sender(id) : undefined);
  const entry = useSyncExternalStore(store.subscribeNames, read, read);
  return useMemo(
    () =>
      resolveSenderIdentity(
        {
          name: sender.name,
          sessionId: sender.sessionId,
          relation: sender.relation,
          ...(sender.displayName && { displayName: sender.displayName }),
        },
        entry,
        viewerSessionId,
      ),
    [sender.name, sender.sessionId, sender.relation, sender.displayName, entry, viewerSessionId],
  );
}
