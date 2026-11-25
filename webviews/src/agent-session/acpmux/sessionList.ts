// The session sidebar's model: what each session row shows and how rows group
// by project. It follows the acpmux TUI sidebar (crates/acpmux/src/tui/render),
// so a session reads the same in the terminal and in the pane.
import { type AutoSession, autoSessionOf, heldInCloud } from "./autoSession/autoSession";
import { type Translate, translate } from "./i18n";
import { withoutRelayLabel, withoutRelayLabelOfMessage } from "./conversation/relayEnvelope";
import { readRetry, type RetryState } from "./subagents/retryState";
import { parseSessionIcon, type HarnessIconSpec } from "../shared/harnessIcons";
import { senderSessionName } from "./senderIdentity";
import { replacedSince } from "./sessionIndex";
import { type SessionUsageStats, usageStatsOf } from "./usageStats";

/** A session as the sidebar sees it, cut from acpmux's session summary. */
export type AcpmuxSessionEntry = {
  sessionId: string;
  displayTitle?: string;
  /** The name it was given (acpmux `displayName`, "Mango"): every human-visible surface shows it
   *  first. Absent when none was given. */
  displayName?: string;
  /** Its names before its renames, oldest first (acpmux `formerNames`): "fka" lines read the last. */
  formerNames?: string[];
  /** The icon it set (acpmux `icon`), drawn in place of its harness mark (`SessionMark`). */
  icon?: HarnessIconSpec;
  title?: string;
  name?: string;
  harness?: string;
  /** The harness's own id for the chat (Claude Code's session id): the device chat index lists it too. */
  agentSessionId?: string;
  status?: string;
  model?: string;
  /** The harness's thinking effort, when a summary producer supplies it. */
  effort?: string;
  cwd?: string;
  /** acpmux's last write to the session: any logged record, a warm, resume or stop of its agent too. */
  updatedAt?: number;
  /** When the person or the agent last did something in the chat (`activityAt`): what the chat
   *  lists sort and label by, so warming, resuming or stopping an agent moves no row. */
  activityAt?: number;
  /** When acpmux made the session (`SessionSummary.createdAt`). */
  createdAt?: number;
  pendingPermissions?: number;
  unread?: boolean;
  /** Turns that ended while nobody showed the chat, since a person last did (`unreadTurns`). */
  unreadTurns?: number;
  /** The log seq the person had seen when they last left the chat (`seenSeq`): where "New since
   *  you looked" goes. */
  seenSeq?: number;
  /** The status dot acpmux decided (`SessionSummary.indicator`, cx-zlox); absent for none. */
  indicator?: SessionIndicator;
  /** The machine the session runs on ("This Mac", or a cloud machine's name), and which kind it is. */
  host?: string;
  /** The acpmux peer name for a remote daemon. */
  peer?: string;
  hostKind?: "local" | "cloud";
  branch?: string;
  /** Set only when the session runs in a git worktree: the worktree's path. */
  worktree?: string;
  /** Pinned by the fixture's flag, or tagged `pinned` through `_acpmux/tag`; listed under Pinned instead of its project. */
  pinned?: boolean;
  /** Tagged `archived` through `_acpmux/tag` (the chat menu's Archive): off every list, found only by search. */
  archived?: boolean;
  /** A side chat: a fork tagged `side` with its chat's session, shown beside that chat and off every list. */
  side?: boolean;
  pullRequest?: SessionPullRequest;
  /** The pull request URLs the session's `gh pr create` calls printed (acpmux `pullRequests`),
   *  oldest first; absent from an acpmux that does not record them. */
  pullRequestUrls?: string[];
  /** A line of the session's latest reply, for previews. */
  preview?: string;
  /** Its log is in acpmux's cold archive (`coldArchive`, hub/cold_archive.rs): the row draws this
   *  preview only, and opening the chat brings the log back. */
  coldArchive?: ColdArchive;
  /** The latest message text from acpmux's summary, when present. */
  lastMessage?: string;
  /** A fork: the chat it was forked from and that chat's event it branched after (cx-ncc.61). */
  parentId?: string;
  /** Started by another session's agent (acpmux `spawnedBy`): it folds under that chat, off every list. */
  spawnedBy?: string;
  /** A sub-session: the chat whose agent started it with its `start_session` tool (acpmux
   *  `startedBy`, kept at any depth and after that chat closes). */
  startedBy?: string;
  /** The chat it reports to (acpmux's tag `lane.reportsTo`, a bare id on its own machine): the
   *  session that started it as a lane (leads.ts). */
  reportsTo?: string;
  /** Started by a Chief (its `mux.parent` tag, `optchat-chief:<home>`): the Chief manages it. */
  chiefChild?: true;
  /** The Chief home that started it (its `mux.parent` tag's value), when a Chief did. */
  chiefHome?: string;
  /** A Chief's own turn session: the home whose chats it starts (`mux.children`) and that Chief's
   *  participant id (`cmux.chief.participant`, optchat-chief acpmux.rs), as the sidebar reads them. */
  chiefTurn?: { home: string; participant: string };
  /** A sub-session's name among its parent's (acpmux `shortName`, "tests"). */
  shortName?: string;
  /** What it is doing (acpmux `lane.state`): working, waiting on the person, failed, lost or idle. */
  lane?: SessionLane;
  /** Prompts waiting behind its running turn, when any. */
  queued?: number;
  /** Its parent already runs as many sub-sessions as `maxRunning` allows: its first prompt waits
   *  for a run slot (acpmux `waitsForSlot`), so it has not started. */
  waitsForSlot?: true;
  /** One line of what its running turn does now: its plan step and latest tool, as acpmux says it
   *  to the parent's agent (`doing`). */
  doing?: string;
  /** The tool part of `doing` (acpmux `turn.activity`, its latest tool call's title), when it has
   *  one: the tray reads a shell call's title, the command as typed, as "Running <command>". */
  doingTool?: string;
  /** What it waits on the person for, while it does: an agent question (with its first prompt)
   *  or a tool's permission. acpmux names it on a sub-session's family rows (`waitingOn`,
   *  subsession_send.rs `waiting_on`); a summary that does not leaves it unknown. */
  waitingOn?: SessionWaiting;
  forkSeq?: number;
  /** acpmux forks and edits it through any completed turn, not only its latest (`forksAnyTurn`:
   *  its harness cuts a conversation at a turn, by kind, whatever its family is named). Unset
   *  from an older acpmux. */
  forksAnyTurn?: boolean;
  /** Completed turns, the copied ones of a fork included. */
  turnCount?: number;
  /** Nothing was sent in it yet (acpmux names no last prompt, no turn, nothing queued or waiting on
   *  the person, and no turn running or waiting): a New Tab's chip pick starts such a session before
   *  its first prompt. */
  unsent?: boolean;
  /** Its last turn completed: its harness profile runs here (signed in, routed). */
  worked?: boolean;
  /** When its last turn ended stopped (`lastTurn.status` `cancelled`): acpmux can carry it on from
   *  there (subagents/resumeState.ts ``subsessionResumeRow``). */
  stoppedAt?: number;
  /** Explicit lifecycle evidence; absent until the protocol producer supplies a validated receipt. */
  lifecycleReceipt?: LifecycleReceipt;
  /** The folder of a sub-session this chat's agent wants to start but cannot until the person trusts
   *  it (acpmux tag `trust.pending:<name>`, hub/trust_wait.rs): the row says "Needs trust". */
  trustPending?: string;
  /** acpmux's retry of its failed turn while one waits (session/list `retry`, subagents/retryState.ts). */
  retry?: RetryState;
  /** acpmux is settling whether its failed turn is retried, or that retry starts or runs
   *  (session/list `retryDeciding`): no Retry is offered meanwhile. */
  retryDeciding?: true;
  /** Why its failed or lost turn failed, as acpmux's lane says it (`lane.error`, secrets masked):
   *  a retry acpmux refused before its turn started leaves it failed with this. */
  laneError?: string;
  /** What it spends: context, 24h tokens and cost, subagents (acpmux `usageStats`, usageStats.ts). */
  usageStats?: SessionUsageStats;
  /** Where an Auto chat stands (acpmux `autoSession`, autoSession/autoSession.ts); unset from an
   *  acpmux without Auto, and the row then reads as it did before. */
  autoSession?: AutoSession;
};

/** A cold-archived chat's preview, as acpmux keeps it in `session.json` (`ColdPreview`). */
export type ColdArchive = {
  archivedAt: number;
  /** The prompts and replies its log held. */
  messages: number;
  bytesBefore: number;
  bytesAfter: number;
  /** Its last few messages, oldest first, each cut short. */
  last: { role: string; text: string; at: number }[];
};

const coldCount = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);

/** acpmux's `coldArchive`, else undefined. */
export function coldArchive(value: unknown): ColdArchive | undefined {
  if (!value || typeof value !== "object") return undefined;
  const cold = value as Record<string, unknown>;
  const last = (Array.isArray(cold.last) ? cold.last : []).flatMap((item) => {
    const message = item as Record<string, unknown> | null;
    const body = text(message?.text);
    return body ? [{ role: text(message?.role) ?? "assistant", text: body, at: coldCount(message?.at) }] : [];
  });
  return {
    archivedAt: coldCount(cold.archivedAt),
    messages: coldCount(cold.messages),
    bytesBefore: coldCount(cold.bytesBefore),
    bytesAfter: coldCount(cold.bytesAfter),
    last,
  };
}

export type LifecycleReceipt = {
  id: string;
  sequence: number;
  state: string;
  source: string;
};

export type SessionPullRequest = {
  number: number;
  title: string;
  state: "open" | "draft" | "merged" | "closed";
  reviewReady?: boolean;
  /** The head commit's CI rollup, when the daemon reports one. */
  checks?: "passing" | "failing" | "pending";
};
const PR_STATES = new Set(["open", "draft", "merged", "closed"]);
const CHECK_STATES = new Set(["passing", "failing", "pending"]);

/** A non-empty string, else undefined. */
export const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
/** "local" or "cloud", else undefined. */
export const hostKind = (value: unknown) => (value === "local" || value === "cloud" ? value : undefined);

/** The tag that pins a session to the top of the list. */
export const PINNED_TAG = "pinned";
/** The tag the chat menu's Archive sets. */
export const ARCHIVED_TAG = "archived";
/** The tag New side chat sets on its fork (the value is the chat's session). */
export const SIDE_TAG = "side";
/** acpmux's tag on the fork a side question (`/btw`) is asked in, while it lives. */
const ASIDE_TAG = "aside";

/** Whether a session belongs in the sidebar, Home and recents: neither archived nor a side chat. */
export const listed = (session: AcpmuxSessionEntry) => !session.archived && !session.side;

/** `entries` without the chats that fold under another of them (`spawnedBy`). A child whose parent
 *  is not in `entries` (gone, archived, filtered out) or that waits on the user lists on its own,
 *  so no chat is hidden everywhere. */
export function withoutChildren(entries: AcpmuxSessionEntry[]): AcpmuxSessionEntry[] {
  const parents = new Set(entries.filter((entry) => !entry.spawnedBy).map((entry) => entry.sessionId));
  return entries.filter((entry) => !folded(entry, parents));
}

/** A child with a live ask remains independently discoverable even while its dot says "working".
 * The Home inbox and the sidebar share this folding rule; acpmux may report a pending permission
 * or question before its indicator moves to "input". A lost host cannot answer its old asks.
 */
export const folded = (entry: AcpmuxSessionEntry, parents: Pick<ReadonlySet<string>, "has">) => {
  const needsPerson =
    entry.indicator !== "lost" &&
    ((entry.pendingPermissions ?? 0) > 0 || entry.waitingOn !== undefined || entry.status === "waiting");
  return Boolean(
    entry.spawnedBy && parents.has(entry.spawnedBy) && sessionMark(entry, false) !== "input" && !needsPerson,
  );
};

/** Whether acpmux's tags (an object of key to value; a list in older fixtures) hold `tag`. */
function tagged(tags: unknown, tag: string): boolean {
  if (Array.isArray(tags)) return tags.includes(tag);
  return typeof tags === "object" && tags !== null && tag in tags;
}

/** A lane's tag naming the session it reports to (acpmux hub/lane_reports.rs `TAG`). */
const REPORTS_TO_TAG = "lane.reportsTo";

/** The string value of acpmux's tag `tag` (tags an object of key to value), else undefined. */
function tagValue(tags: unknown, tag: string): string | undefined {
  if (typeof tags !== "object" || tags === null || Array.isArray(tags)) return undefined;
  const value = (tags as Record<string, unknown>)[tag];
  return typeof value === "string" && value ? value : undefined;
}

/** The tag a Chief puts on every session it starts (cmux_chief::rules::PARENT_TAG), valued
 *  `optchat-chief` or `optchat-chief:<home id>`. */
const CHIEF_PARENT_TAG = "mux.parent";

/** The tags a Chief puts on its own turn session (cmux_chief::rules::CHILDREN_TAG, optchat-chief
 *  acpmux.rs CHIEF_PARTICIPANT_TAG). */
const CHIEF_CHILDREN_TAG = "mux.children";
const CHIEF_PARTICIPANT_TAG = "cmux.chief.participant";

/** A Chief turn session's home and participant id, from its tags. */
function chiefTurn(tags: unknown): { home: string; participant: string } | undefined {
  const home = tagValue(tags, CHIEF_CHILDREN_TAG);
  const participant = tagValue(tags, CHIEF_PARTICIPANT_TAG);
  return home && participant && /^optchat-chief(?::|$)/.test(home) && /^agent_[A-Za-z0-9_-]{1,58}$/.test(participant)
    ? { home, participant }
    : undefined;
}

/** Whether acpmux's tags say a Chief started the session. */
function chiefParent(tags: unknown): boolean {
  if (typeof tags !== "object" || tags === null || Array.isArray(tags)) return false;
  const value = (tags as Record<string, unknown>)[CHIEF_PARENT_TAG];
  return typeof value === "string" && /^optchat-chief(?::|$)/.test(value);
}

/** The tag acpmux sets on a chat while a sub-session of it waits for a folder's trust (hub/trust_wait.rs). */
const TRUST_PENDING_TAG = "trust.pending:";

/** The folder a chat's waiting sub-session needs trusted, from its tags (an object of key to value). */
function trustPending(tags: unknown): string | undefined {
  if (typeof tags !== "object" || tags === null || Array.isArray(tags)) return undefined;
  for (const [key, value] of Object.entries(tags)) {
    if (key.startsWith(TRUST_PENDING_TAG) && typeof value === "string" && value) return value;
  }
  return undefined;
}

/** acpmux's status dots (`SessionSummary.indicator`). */
export type SessionIndicator = "input" | "working" | "failed" | "lost" | "done";
const INDICATORS: readonly string[] = ["input", "working", "failed", "lost", "done"];

/** acpmux's lane states (`SessionSummary.lane.state`). */
export type SessionLane = "working" | "input" | "failed" | "lost" | "idle";
const LANES: readonly string[] = ["working", "input", "failed", "lost", "idle"];

/** A running turn's line as acpmux's `doing_line` (hub/activity.rs) writes it: its plan step and
 *  latest tool, either alone; else what the turn was asked (`lane.step`). */
function doingLine(session: Record<string, any>): string | undefined {
  if (session.lane?.state !== "working") return undefined;
  const step = text(session.turn?.planStep);
  const tool = text(session.turn?.activity);
  if (step && tool && step !== tool) return `${step} · ${tool}`;
  return step ?? tool ?? text(session.lane?.step);
}

/** What a session waits on the person for: only the person answers any of them, in the app. acpmux
 *  names every wait (`waitingOn`, subsession_send.rs `waiting_on`): a question, a tool's permission,
 *  a secret's value, the password for one command as root, or an MCP server to connect. */
export type SessionWaiting =
  | { on: "question"; prompt?: string }
  | { on: "permission" }
  | { on: "secret" }
  | { on: "elevation" }
  | { on: "mcpConnect" };

/** `waitingOn` while the session waits on the person, with a question's first prompt
 *  (`waitingPrompt`) when acpmux gives it. */
export function sessionWaiting(session: Record<string, any>): SessionWaiting | undefined {
  if (session.waitingOn === "permission") return { on: "permission" };
  if (session.waitingOn === "secret") return { on: "secret" };
  if (session.waitingOn === "elevation") return { on: "elevation" };
  if (session.waitingOn === "mcp_connect") return { on: "mcpConnect" };
  if (session.waitingOn !== "question") return undefined;
  const prompt = text(session.waitingPrompt);
  return prompt ? { on: "question", prompt } : { on: "question" };
}

/** `formerNames` as acpmux sends it (oldest first), its non-blank strings; absent for none. */
export function formerNamesOf(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const names = value.filter((name): name is string => typeof name === "string" && name.trim() !== "");
  return names.length > 0 ? names : undefined;
}

/** The newest of its former names ("fka claude-sr2-coord-old"), unless it is the name shown now. */
export function formerName(entry: { formerNames?: string[]; displayTitle?: string }): string | undefined {
  const last = entry.formerNames?.at(-1);
  return last && last !== entry.displayTitle ? last : undefined;
}

/** What a row draws at its right edge, most urgent first. */
export type SessionMark = "input" | "running" | "error" | "unread" | undefined;

/** Cuts acpmux's session summary down to the fields the pane uses. */
export function sessionEntry(session: Record<string, any> & { sessionId: string }): AcpmuxSessionEntry {
  const pending = Number(session.pendingPermissions ?? 0);
  const turn = chiefTurn(session.tags);
  const cold = coldArchive(session.coldArchive);
  const auto = autoSessionOf(session.autoSession);
  return {
    sessionId: session.sessionId,
    displayTitle: sessionTitle(session),
    displayName: text(session.displayName),
    formerNames: formerNamesOf(session.formerNames),
    icon: parseSessionIcon(session.icon),
    title: session.title,
    name: session.name,
    harness: session.harness,
    agentSessionId: text(session.agentSessionId),
    status: session.status,
    model: text(session.model),
    effort: text(session.effort),
    cwd: typeof session.cwd === "string" ? session.cwd : undefined,
    updatedAt: typeof session.updatedAt === "number" ? session.updatedAt : undefined,
    activityAt: summaryActivityAt(session),
    createdAt: typeof session.createdAt === "number" ? session.createdAt : undefined,
    pendingPermissions: Number.isFinite(pending) ? pending : 0,
    unread: session.unread === true,
    unreadTurns: count(session.unreadTurns),
    seenSeq: count(session.seenSeq),
    indicator: INDICATORS.includes(session.indicator) ? session.indicator : undefined,
    host: text(session.host),
    peer: text(session.peer),
    hostKind: hostKind(session.hostKind),
    branch: text(session.branch),
    worktree: text(session.worktree),
    pinned: session.pinned === true || tagged(session.tags, PINNED_TAG),
    archived: session.archived === true || tagged(session.tags, ARCHIVED_TAG),
    // A side question's throwaway copy (`aside`, acpmux hub/aside.rs) is never listed either.
    side: session.side === true || tagged(session.tags, SIDE_TAG) || tagged(session.tags, ASIDE_TAG),
    pullRequest: pullRequest(session.pullRequest),
    pullRequestUrls: pullRequestUrls(session.pullRequests),
    // A relayed message's text holds the broker's label for the agent (conversation/relayEnvelope.ts):
    // a list's preview reads the message.
    preview: shown(session.preview),
    lastMessage: shown(session.lastMessage?.text) ?? shown(session.preview),
    ...(cold && { coldArchive: cold }),
    parentId: text(session.parentId),
    spawnedBy: text(session.spawnedBy),
    startedBy: text(session.startedBy),
    reportsTo: tagValue(session.tags, REPORTS_TO_TAG),
    ...(chiefParent(session.tags) && {
      chiefChild: true as const,
      chiefHome: tagValue(session.tags, CHIEF_PARENT_TAG),
    }),
    ...(turn && { chiefTurn: turn }),
    shortName: text(session.shortName),
    lane: LANES.includes(session.lane?.state) ? session.lane.state : undefined,
    queued: Number(session.queued) > 0 ? Number(session.queued) : undefined,
    ...(session.waitsForSlot === true && { waitsForSlot: true as const }),
    doing: doingLine(session),
    doingTool: session.lane?.state === "working" ? text(session.turn?.activity) : undefined,
    waitingOn: sessionWaiting(session),
    forkSeq: typeof session.forkSeq === "number" ? session.forkSeq : undefined,
    ...(typeof session.forksAnyTurn === "boolean" && { forksAnyTurn: session.forksAnyTurn }),
    turnCount: typeof session.turnCount === "number" ? session.turnCount : undefined,
    unsent:
      session.lastPrompt === null &&
      !(typeof session.turnCount === "number" && session.turnCount > 0) &&
      // A first prompt waiting in the queue, a turn, or the person (a permission, an answer) is sent.
      !(Number(session.queued) > 0) &&
      !(Number(session.pendingPermissions) > 0) &&
      session.inputSince == null &&
      // Running or waiting is a first turn under way; any other state (an agent gone away) is not.
      session.status !== "running" &&
      session.status !== "waiting",
    worked: session.lastTurn?.status === "completed",
    ...(session.lastTurn?.status === "cancelled" && { stoppedAt: time(session.lastTurn.endedAt) ?? 0 }),
    lifecycleReceipt: lifecycleReceipt(session.lifecycleReceipt),
    trustPending: trustPending(session.tags),
    retry: readRetry(session.retry) ?? undefined,
    ...(session.retryDeciding === true && { retryDeciding: true as const }),
    laneError: text(session.lane?.error),
    usageStats: usageStatsOf(session.usageStats),
    ...(auto && { autoSession: auto }),
  };
}

const count = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
const time = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined);

/** When the person or the agent last did something in a chat, from acpmux's session summary.
 *  `updatedAt` moves on every record acpmux logs, a pane warming or resuming the chat's agent and
 *  the idle pool stopping it included, so it is activity only while a turn runs. A chat waiting on
 *  the person counts from when it began to wait; any other from when its last turn ended, or, with
 *  no turn ended here (adopted, or never answered), from when it was made: it never jumps to now. */
export function summaryActivityAt(session: Record<string, any>): number | undefined {
  const updated = time(session.updatedAt);
  // Waiting on the person (a permission inside a turn too) counts from when the wait began, so a
  // draft or a tag saved meanwhile moves nothing.
  const waiting = time(session.inputSince);
  if (waiting !== undefined) return waiting;
  if (session.status === "running" || session.status === "waiting" || Number(session.pendingPermissions) > 0)
    return updated;
  // A turn that never ended on a chat no longer running (disconnected, unreachable) counts from its
  // start, so retries to reach the agent move nothing.
  if (session.turn && typeof session.turn === "object") return time(session.turn.startedAt) ?? updated;
  return time(session.lastTurn?.endedAt) ?? time(session.createdAt) ?? updated;
}

/** The time a chat list sorts and labels an entry by: its activity, or for an entry cut by an
 *  older producer (gallery fixtures), its `updatedAt`. */
export const activityTime = (entry: Pick<AcpmuxSessionEntry, "activityAt" | "updatedAt">) =>
  entry.activityAt ?? entry.updatedAt;

/** Reuses a direct-client entry while retaining compatibility with raw summary fixtures/callers. */
export function normalizedSessionEntry(session: Record<string, any> & { sessionId: string }): AcpmuxSessionEntry {
  return typeof session.displayTitle === "string" ? (session as AcpmuxSessionEntry) : sessionEntry(session);
}

function lifecycleReceipt(value: unknown): LifecycleReceipt | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const raw = value as Record<string, unknown>;
  const sequence = raw.sequence;
  if (typeof raw.id !== "string" || !raw.id) return undefined;
  if (typeof sequence !== "number" || !Number.isSafeInteger(sequence) || sequence < 1) return undefined;
  if (typeof raw.state !== "string" || !raw.state) return undefined;
  if (typeof raw.source !== "string" || !raw.source) return undefined;
  return { id: raw.id, sequence, state: raw.state, source: raw.source };
}

function pullRequestUrls(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const urls = value.filter((url): url is string => typeof url === "string" && url.startsWith("https://"));
  return urls.length ? urls : undefined;
}

function pullRequest(value: any): SessionPullRequest | undefined {
  // A pull request the pane can't name or place is left out rather than guessed at.
  if (!Number.isInteger(value?.number) || value.number <= 0 || !text(value.title) || !PR_STATES.has(value.state))
    return undefined;
  return {
    number: value.number,
    title: value.title,
    state: value.state,
    reviewReady: value.reviewReady === true || undefined,
    checks: CHECK_STATES.has(value.checks) ? value.checks : undefined,
  };
}

/// A raw id where a name should be: a session or thread UUID ("01a18a35-b1e8-7951-ba2f-…"), Claude's
/// `<session>/<tool call>` or a bare `toolu_…` call id. Never a title the person reads.
export function isRawId(text: string): boolean {
  const value = text.trim();
  return (
    /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?:\/.*)?$/iu.test(value) || /(?:^|\/)toolu_[0-9A-Za-z]+$/u.test(value)
  );
}

/// A session name that reads as an id or a counter, not a task (acpmux `session_name::opaque_reason`,
/// AgentTurnStates.swift `isOpaqueName`): a Chief's machine name (`optchat-sub-6b68ac4a-a26`), a
/// trailing counter (`cloud-item-14`) or a hex run of 6 or more with a digit (`dispatch-019a3f2e`).
/// The chat's title reads instead (Leo 2026-11-02: "that's the agents naming them like that").
export function isOpaqueName(bare: string): boolean {
  if (bare.startsWith("optchat-")) return true;
  const parts = bare.split(/[-_.]/u).filter(Boolean);
  if (parts.length > 1 && /^\d+$/u.test(parts[parts.length - 1]!)) return true;
  return parts.some((part) => part.length >= 6 && /^[0-9a-f]+$/iu.test(part) && /\d/u.test(part));
}

/**
 * Its given name (acpmux `displayName`) when it has one. Else the title (the agent's title, else
 * the first prompt) when the name was generated (`codex`,
 * `codex-3`, `codex-fork`, after the harness profile or its family), else the name the user gave. A generated
 * name is the launch profile's (`claude-sr`), so a chat with no prompt yet is a "New chat".
 */
export function sessionTitle(
  session: {
    displayName?: string;
    title?: string;
    lastPrompt?: string;
    name?: string;
    peer?: string;
    harness?: string;
    family?: string;
    sessionId: string;
  },
  t: Translate = translate,
): string {
  // The name it was given (acpmux decides it: a given handle) reads everywhere first.
  const given = session.displayName?.trim();
  if (given) return given;
  const name = senderSessionName(session.name ?? "", session.peer);
  const bare = name.split("/").pop() ?? name;
  // acpmux names a session `agent` or `agent-N`, and a fork `<name>-fork`, also made unique with `-N`.
  const generatedFrom = (agent: string | undefined) =>
    !!agent && bare.startsWith(agent) && /^(?:-(?:fork|\d+))*$/.test(bare.slice(agent.length));
  // A name that is only a raw id (the session's own UUID) is no name: the title reads instead.
  if (name && !generatedFrom(session.harness) && !generatedFrom(session.family) && !isRawId(bare)) {
    // A name that reads as an id or a counter (`cloud-item-14`) yields to the chat's title, and
    // still beats "New chat" while it has none.
    if (!isOpaqueName(bare)) return name;
    return session.title?.trim() || firstPrompt(session.lastPrompt) || name;
  }
  return session.title?.trim() || firstPrompt(session.lastPrompt) || t("sidebar.newChat");
}

/// How long acpmux keeps `lastPrompt` (hub/turns.rs `short_text(&line, 200)`), an ellipsis after,
/// in characters (Rust `chars`, code points here), not UTF-16 units.
const LAST_PROMPT_CHARS = 200;

/// A chat's first prompt as its title: a lane's message the broker relayed reads as the message,
/// never the label around it (conversation/relayEnvelope.ts). `lastPrompt` is the whole prompt on
/// one line (acpmux hub/turns.rs), so words that only start like a label stay. One cut at acpmux's
/// limit is a preview, which a long sender's head can run past: a head cut inside itself holds none
/// of the message and titles nothing (cmux#38642 review).
const firstPrompt = (prompt: string | undefined) => {
  const line = prompt?.trim() ?? "";
  const cut = line.endsWith("…") && Array.from(line).length > LAST_PROMPT_CHARS;
  return (cut ? withoutRelayLabel(line) : withoutRelayLabelOfMessage(line)).trim();
};

/// A list's preview text without the broker's label; undefined when none is left.
const shown = (value: unknown): string | undefined => {
  const read = text(value);
  return read === undefined ? undefined : withoutRelayLabel(read).trim() || undefined;
};

/**
 * A folderless workspace's private chat folder, `~/Library/Application Support/cmux/agent-home/<workspace-id>`
 * (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE), or a DEV build's own,
 * `~/Library/Application Support/cmux-next/builds/<key>/agent-home/<workspace-id>` (BuildStatePaths `agentHome`).
 * It is not a project, so it is never shown by its id (cmux#53226: a tagged build listed its own by UUID).
 */
export function isAgentHome(cwd: string | undefined): boolean {
  return /\/Library\/Application Support\/(?:cmux|cmux-next\/builds\/[^/]+)\/agent-home(?:\/|$)/.test(cwd ?? "");
}

/**
 * A system temporary folder (`/tmp`, `/private/tmp`, `/var/folders`, anything under `/private/var`):
 * a harness's scratchpad or a script's chat runs there, so it is never a project (cmux#49610: the
 * New Tab composer started on "tmp", the folder of the newest agent chat, instead of the last one used).
 */
export function isTemporaryFolder(cwd: string | undefined): boolean {
  return /^\/(?:tmp|var\/tmp|var\/folders|private\/tmp|private\/var)(?:\/|$)/.test(cwd ?? "");
}

/// The folder of the most recently used chat on this Mac (Leo 2026-10-18): where a New Tab with no
/// folder of its own starts. Not a private agent-home folder, the home folder or `/`, and not a chat
/// on another machine (a peer or a Cloud host). With `known` (the host's project list, which drops
/// folders that no longer exist), only a folder in it: a deleted or removed project never starts one.
/// An empty list is one not loaded yet, so every local chat folder counts until it lands.
export function mostRecentProject(
  sessions: readonly AcpmuxSessionEntry[],
  home?: string,
  known?: readonly string[] | null,
): string | undefined {
  return firstProject(recentLocalFolders(sessions), home, known);
}

/// `sessions` as it was when what `fields` reads of them last changed: the same array while only
/// other fields of a session change (a status dot, unread, a title, a cost), so a projection that
/// reads only `fields` (a memo over it) runs again only when its input moved, and one session's
/// change costs one entry's fields here, not the projection over every listed chat. The pane keeps
/// an unchanged session's entry object (direct.ts `sessionEntryList`), so an entry seen last time is
/// not read again. A session added, removed or moved in the list counts as a change.
export class SessionsBy {
  private kept: readonly AcpmuxSessionEntry[] | undefined;
  /// The list `of` was last given, which a list made from it in place (sessionIndex.ts
  /// `noteReplaced`) is compared with at the replaced entries only.
  private last: readonly AcpmuxSessionEntry[] | undefined;

  constructor(private readonly fields: (entry: AcpmuxSessionEntry) => readonly unknown[]) {}

  of(sessions: readonly AcpmuxSessionEntry[]): readonly AcpmuxSessionEntry[] {
    const previous = this.last;
    if (sessions === previous) return this.kept!;
    this.last = sessions;
    if (previous && previous.length === sessions.length) {
      // Both immutable lists already hold the entries. Compare only the ones that changed,
      // without keeping a serialized key and a bookkeeping object for every session.
      const positions = replacedSince(previous, sessions) ?? sessions.keys();
      for (const at of positions) {
        const entry = sessions[at]!;
        const before = previous[at]!;
        if (before === entry) continue;
        if (
          before.sessionId !== entry.sessionId ||
          JSON.stringify(this.fields(before)) !== JSON.stringify(this.fields(entry))
        )
          return (this.kept = sessions);
      }
      return this.kept!;
    }
    return (this.kept = sessions);
  }
}

/// What a session's folder lists read of it (``recentLocalFolders``, the pane's project pickers): its
/// folder, where it runs, whether it is listed, and when it was last active. The time only of a chat
/// on this Mac: no folder list orders another machine's chats by it, and at Leo's scale those were
/// most of the changes (another machine's lanes working), each building every page's project list
/// again from 10K chats (bench/session-scale-typing.bench.ts).
/// Where a session works, without when: the folders a list names, not their order.
export const placeFields = (session: AcpmuxSessionEntry): readonly unknown[] => [
  session.cwd,
  session.host,
  session.hostKind,
  session.peer,
  listed(session),
];

export const folderFields = (session: AcpmuxSessionEntry): readonly unknown[] => [
  ...placeFields(session),
  !session.peer && (!session.hostKind || session.hostKind === "local") ? activityTime(session) : undefined,
];

/// This Mac's chat folders, newest chat first, each once: not a private agent-home folder, `~` or a
/// chat on another machine. `mostRecentProject` picks from it; a New Tab page keeps it for the next
/// page's first frame (newtab/recentProject.ts).
export function recentLocalFolders(sessions: readonly AcpmuxSessionEntry[], limit = Infinity): string[] {
  return recentFolders(sessions, localFolder, limit);
}

/// The folders `folderOf` names, of the newest chat first, each once (a tie keeps the list's order).
/// One pass keeps each folder's newest chat (the first in the list among equals, as a stable sort
/// leaves it), then only the folders are sorted: every page reads this on each change of a chat of
/// this Mac, and sorting all of a large profile's chats there took the scrolled page's frames
/// (bench/session-scale-scroll.bench.ts).
export function recentFolders(
  sessions: readonly AcpmuxSessionEntry[],
  folderOf: (session: AcpmuxSessionEntry) => string | undefined,
  limit = Infinity,
): string[] {
  const newest = new Map<string, { at: number; index: number }>();
  sessions.forEach((session, index) => {
    const folder = folderOf(session);
    if (folder === undefined) return;
    const at = activityTime(session) ?? 0;
    const kept = newest.get(folder);
    if (!kept || at > kept.at) newest.set(folder, { at, index });
  });
  const folders = [...newest].sort(([, left], [, right]) => right.at - left.at || left.index - right.index);
  return folders.slice(0, limit).map(([folder]) => folder);
}

/// The folder `recentLocalFolders` lists a session under, or undefined when it lists none for it.
export function localFolder(session: AcpmuxSessionEntry): string | undefined {
  const cwd = session.cwd?.replace(/\/+$/, "");
  if (!cwd || cwd === "~" || isAgentHome(cwd)) return undefined;
  return !session.peer && (!session.hostKind || session.hostKind === "local") && listed(session) ? cwd : undefined;
}

/// `recentFolders` of a list that changes one chat at a time, kept as the list changes: a chat on
/// this Mac working moves its folder to the front, without sorting every chat again. The same array
/// while the order holds. Anything else (a chat added or gone, one moved to another folder, a time
/// that went back or ties another folder's) builds it again from the whole list. Leo, 2026-11-18,
/// "typing in the composer still slow 😞 there must be a lot of open stuff?": each page sorted all
/// 10K chats on every event of a chat on this Mac (bench/session-scale-typing.bench.ts).
export class FolderRecency {
  constructor(private readonly folderOf: (session: AcpmuxSessionEntry) => string | undefined = localFolder) {}

  private last: readonly AcpmuxSessionEntry[] | undefined;
  private order: string[] = [];
  private newest = new Map<string, number>();

  of(sessions: readonly AcpmuxSessionEntry[]): readonly string[] {
    if (sessions === this.last) return this.order;
    const previous = this.last;
    const replaced = replacedSince(previous, sessions);
    this.last = sessions;
    if (!previous || !replaced || !replaced.every((at) => this.moved(sessions[at]!, previous[at]!)))
      this.build(sessions);
    return this.order;
  }

  /// When a chat here last worked in `folder` (of the list last read), if any did.
  usedAt(folder: string): number | undefined {
    return this.newest.get(folder);
  }

  private build(sessions: readonly AcpmuxSessionEntry[]) {
    this.order = recentFolders(sessions, this.folderOf);
    this.newest = new Map();
    for (const session of sessions) {
      const folder = this.folderOf(session);
      const at = activityTime(session) ?? 0;
      if (folder !== undefined && at > (this.newest.get(folder) ?? -Infinity)) this.newest.set(folder, at);
    }
  }

  /// Applies one replaced session; false when the whole list must be read again.
  private moved(session: AcpmuxSessionEntry, before: AcpmuxSessionEntry): boolean {
    if (before.sessionId !== session.sessionId) return false;
    const beforeFolder = this.folderOf(before);
    const beforeAt = activityTime(before) ?? 0;
    const folder = this.folderOf(session);
    const at = activityTime(session) ?? 0;
    if (beforeFolder !== folder || at < beforeAt) return false;
    if (folder === undefined || at === beforeAt) return true;
    const newest = this.newest.get(folder)!;
    if (at < newest) return true;
    // Its folder's newest time again, from another chat: a tie with another folder may order otherwise.
    if (at === newest) return false;
    this.newest.set(folder, at);
    const from = this.order.indexOf(folder);
    if (from < 0) return false;
    // Its new place: after every folder newer than it. A tie keeps the list's own order: build again.
    let to = 0;
    while (to < this.order.length) {
      const other = this.order[to]!;
      if (other !== folder) {
        const time = this.newest.get(other)!;
        if (time === at) return false;
        if (time < at) break;
      }
      to += 1;
    }
    if (to >= from) return true;
    const next = this.order.slice();
    next.splice(from, 1);
    next.splice(to, 0, folder);
    this.order = next;
    return true;
  }
}

/// The first of `folders` (newest first) a New Tab may start in: not the home folder or a temporary
/// folder, and with `known` (the host's project list; absent or empty is not loaded yet) one in it.
/// `null`: the host answered and lists no project (every one removed or missing), so no folder is one.
export function firstProject(
  folders: readonly string[],
  home?: string,
  known?: readonly string[] | null,
): string | undefined {
  if (known === null) return undefined;
  const projects = known?.length ? new Set(known.map((path) => path.replace(/(.)\/+$/, "$1"))) : undefined;
  const homeFolder = home?.replace(/\/+$/, "");
  return folders.find((cwd) => cwd !== homeFolder && !isTemporaryFolder(cwd) && (!projects || projects.has(cwd)));
}

/**
 * A project's name for its header: the folder's last component, `~` for a home folder, `/` for the
 * filesystem root. Only no folder at all reads No folder: a folder is never called that.
 */
export function projectLabel(cwd: string | undefined, t: Translate = translate): string {
  const trimmed = (cwd ?? "").replace(/\/+$/, "");
  if (!trimmed) return cwd ? "/" : t("project.noFolder");
  const parts = trimmed.split("/").filter(Boolean);
  if (parts.length === 2 && (parts[0] === "Users" || parts[0] === "home")) return "~";
  return parts[parts.length - 1] ?? trimmed;
}

/** A folder for display, with a home folder's prefix written `~` as a shell prompt does. */
export function homePath(path: string): string {
  return path.replace(/^\/(?:Users|home)\/[^/]+(?=\/|$)/, "~");
}

/** The remote machine a session runs on. A host not marked local counts as remote; this Mac is never named. */
export const cloudHost = (session: AcpmuxSessionEntry) =>
  session.hostKind === "local" ? undefined : (session.peer ?? session.host);

/** Where a row says it runs, beyond its project: a cloud machine, then a worktree, then a branch. */
export type SessionPlace =
  | {
      kind: "cloud" | "worktree" | "branch";
      label: string;
      /** A cloud row's branch, for its label. */ branch?: string;
    }
  | undefined;

export function sessionPlace(session: AcpmuxSessionEntry, groupHost?: string, t: Translate = translate): SessionPlace {
  const host = cloudHost(session);
  if (host && host !== groupHost) return { kind: "cloud", label: host, branch: session.branch };
  // An Auto chat of this Mac that the Cloud runs now reads as a Cloud chat does, by the word the
  // composer's Where menu uses: its row names no machine of its own.
  if (!host && heldInCloud(session.autoSession))
    return { kind: "cloud", label: t("composer.cloud"), branch: session.branch };
  if (session.worktree) return { kind: "worktree", label: session.branch ?? projectLabel(session.worktree) };
  if (session.branch) return { kind: "branch", label: session.branch };
  return undefined;
}

/** The row's mark, from acpmux's `indicator`: a done chat is marked only until the user opens it. */
export function sessionMark(session: AcpmuxSessionEntry, selected: boolean): SessionMark {
  switch (session.indicator) {
    case "input":
      return "input";
    case "working":
      return "running";
    case "failed":
    case "lost":
      return "error";
    case "done":
      return session.unread && !selected ? "unread" : undefined;
    default:
      return undefined;
  }
}

/** A compact age for the history list: `now`, `5m`, `3h`, `2d`, `6w`. */
export function shortAge(updatedAt: number | undefined, now: number, t: Translate = translate): string {
  if (updatedAt === undefined) return "";
  const minutes = Math.max(0, Math.floor((now - updatedAt) / 60_000));
  if (minutes < 1) return t("age.now");
  if (minutes < 60) return t("age.minutes", { n: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t("age.hours", { n: hours });
  const days = Math.floor(hours / 24);
  return days < 14 ? t("age.days", { n: days }) : t("age.weeks", { n: Math.floor(days / 7) });
}

/** First shared wall-clock minute where shortAge's text changes (clock.ts useLabelClock), so its
 *  label wakes then and not every minute. */
export function nextShortAge(at: number, now: number): number {
  if (!Number.isFinite(at)) return Infinity;
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;
  const elapsed = Math.max(0, now - at);
  const size = elapsed < hour ? minute : elapsed < day ? hour : elapsed < 14 * day ? day : 7 * day;
  const change = at + (Math.floor(elapsed / size) + 1) * size;
  return Math.max(now + minute, Math.ceil(change / minute) * minute);
}
