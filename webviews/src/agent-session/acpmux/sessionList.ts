// The session sidebar's model: what each session row shows and how rows group
// by project. It follows the acpmux TUI sidebar (crates/acpmux/src/tui/render),
// so a session reads the same in the terminal and in the pane.
import { type Translate, translate } from "./i18n";
import { readRetry, type RetryState } from "./subagents/retryState";
import { senderSessionName } from "./senderIdentity";

/** A session as the sidebar sees it, cut from acpmux's session summary. */
export type AcpmuxSessionEntry = {
  sessionId: string;
  displayTitle?: string;
  title?: string;
  name?: string;
  harness?: string;
  /** The harness's own id for the chat (Claude Code's session id): the device chat index lists it too. */
  agentSessionId?: string;
  status?: string;
  model?: string;
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
  /** A fork: the chat it was forked from and that chat's event it branched after (cx-ncc.61). */
  parentId?: string;
  /** Started by another session's agent (acpmux `spawnedBy`): it folds under that chat, off every list. */
  spawnedBy?: string;
  /** A sub-session: the chat whose agent started it with its `start_session` tool (acpmux
   *  `startedBy`, kept at any depth and after that chat closes). */
  startedBy?: string;
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
  /** Completed turns, the copied ones of a fork included. */
  turnCount?: number;
  /** Nothing was sent in it yet (acpmux names no last prompt, no turn, nothing queued or waiting on
   *  the person, and no turn running or waiting): a New Tab's chip pick starts such a session before
   *  its first prompt. */
  unsent?: boolean;
  /** Its last turn completed: its harness profile runs here (signed in, routed). */
  worked?: boolean;
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
};

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

/** Whether `entry` folds under a parent in `parents`: it has one there and needs no answer. */
export const folded = (entry: AcpmuxSessionEntry, parents: ReadonlySet<string>) =>
  Boolean(entry.spawnedBy && parents.has(entry.spawnedBy) && sessionMark(entry, false) !== "input");

/** Whether acpmux's tags (an object of key to value; a list in older fixtures) hold `tag`. */
function tagged(tags: unknown, tag: string): boolean {
  if (Array.isArray(tags)) return tags.includes(tag);
  return typeof tags === "object" && tags !== null && tag in tags;
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

/** What a session waits on the person for: only the person answers either, in the app. */
export type SessionWaiting = { on: "question"; prompt?: string } | { on: "permission" };

/** `waitingOn` while the session waits on the person, with a question's first prompt
 *  (`waitingPrompt`) when acpmux gives it. */
export function sessionWaiting(session: Record<string, any>): SessionWaiting | undefined {
  if (session.waitingOn === "permission") return { on: "permission" };
  if (session.waitingOn !== "question") return undefined;
  const prompt = text(session.waitingPrompt);
  return prompt ? { on: "question", prompt } : { on: "question" };
}

/** What a row draws at its right edge, most urgent first. */
export type SessionMark = "input" | "running" | "error" | "unread" | undefined;

/** Cuts acpmux's session summary down to the fields the pane uses. */
export function sessionEntry(session: Record<string, any> & { sessionId: string }): AcpmuxSessionEntry {
  const pending = Number(session.pendingPermissions ?? 0);
  return {
    sessionId: session.sessionId,
    displayTitle: sessionTitle(session),
    title: session.title,
    name: session.name,
    harness: session.harness,
    agentSessionId: text(session.agentSessionId),
    status: session.status,
    model: text(session.model),
    cwd: typeof session.cwd === "string" ? session.cwd : undefined,
    updatedAt: typeof session.updatedAt === "number" ? session.updatedAt : undefined,
    activityAt: summaryActivityAt(session),
    createdAt: typeof session.createdAt === "number" ? session.createdAt : undefined,
    pendingPermissions: Number.isFinite(pending) ? pending : 0,
    unread: session.unread === true,
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
    preview: text(session.preview),
    parentId: text(session.parentId),
    spawnedBy: text(session.spawnedBy),
    startedBy: text(session.startedBy),
    shortName: text(session.shortName),
    lane: LANES.includes(session.lane?.state) ? session.lane.state : undefined,
    queued: Number(session.queued) > 0 ? Number(session.queued) : undefined,
    ...(session.waitsForSlot === true && { waitsForSlot: true as const }),
    doing: doingLine(session),
    doingTool: session.lane?.state === "working" ? text(session.turn?.activity) : undefined,
    waitingOn: sessionWaiting(session),
    forkSeq: typeof session.forkSeq === "number" ? session.forkSeq : undefined,
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
    lifecycleReceipt: lifecycleReceipt(session.lifecycleReceipt),
    trustPending: trustPending(session.tags),
    retry: readRetry(session.retry) ?? undefined,
    ...(session.retryDeciding === true && { retryDeciding: true as const }),
    laneError: text(session.lane?.error),
  };
}

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

/**
 * The title (the agent's title, else the first prompt) when the name was generated (`codex`,
 * `codex-3`, `codex-fork`, after the harness profile or its family), else the name the user gave. A generated
 * name is the launch profile's (`claude-sr`), so a chat with no prompt yet is a "New chat".
 */
export function sessionTitle(
  session: {
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
  const name = senderSessionName(session.name ?? "", session.peer);
  const bare = name.split("/").pop() ?? name;
  // acpmux names a session `agent` or `agent-N`, and a fork `<name>-fork`, also made unique with `-N`.
  const generatedFrom = (agent: string | undefined) =>
    !!agent && bare.startsWith(agent) && /^(?:-(?:fork|\d+))*$/.test(bare.slice(agent.length));
  if (name && !generatedFrom(session.harness) && !generatedFrom(session.family)) return name;
  return session.title?.trim() || session.lastPrompt?.trim() || t("sidebar.newChat");
}

/**
 * A folderless workspace's private chat folder, `~/Library/Application Support/cmux/agent-home/<workspace-id>`
 * (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). It is not a project, so it is never shown by its id.
 */
export function isAgentHome(cwd: string | undefined): boolean {
  return /\/Library\/Application Support\/cmux\/agent-home(?:\/|$)/.test(cwd ?? "");
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

/// This Mac's chat folders, newest chat first, each once: not a private agent-home folder, `~` or a
/// chat on another machine. `mostRecentProject` picks from it; a New Tab page keeps it for the next
/// page's first frame (newtab/recentProject.ts).
export function recentLocalFolders(sessions: readonly AcpmuxSessionEntry[], limit = Infinity): string[] {
  const local = sessions.filter((session) => {
    const cwd = session.cwd?.replace(/\/+$/, "");
    if (!cwd || cwd === "~" || isAgentHome(cwd)) return false;
    return !session.peer && (!session.hostKind || session.hostKind === "local") && listed(session);
  });
  const folders: string[] = [];
  for (const session of byRecency(local)) {
    const cwd = session.cwd!.replace(/\/+$/, "");
    if (!folders.includes(cwd)) folders.push(cwd);
    if (folders.length >= limit) break;
  }
  return folders;
}

/// The first of `folders` (newest first) a New Tab may start in: not the home folder, and with
/// `known` (the host's project list; absent or empty is not loaded yet) one in it. `null`: the host
/// answered and lists no project (every one removed or missing), so no folder is one.
export function firstProject(
  folders: readonly string[],
  home?: string,
  known?: readonly string[] | null,
): string | undefined {
  if (known === null) return undefined;
  const projects = known?.length ? new Set(known.map((path) => path.replace(/(.)\/+$/, "$1"))) : undefined;
  const homeFolder = home?.replace(/\/+$/, "");
  return folders.find((cwd) => cwd !== homeFolder && (!projects || projects.has(cwd)));
}

/** A project's name for its header: the folder's last component, `~` for a home folder. */
export function projectLabel(cwd: string | undefined, t: Translate = translate): string {
  const trimmed = (cwd ?? "").replace(/\/+$/, "");
  if (!trimmed) return t("project.noFolder");
  const parts = trimmed.split("/").filter(Boolean);
  if (parts.length === 2 && (parts[0] === "Users" || parts[0] === "home")) return "~";
  return parts[parts.length - 1] ?? trimmed;
}

/** A folder for display, with a home folder's prefix written `~` as a shell prompt does. */
export function homePath(path: string): string {
  return path.replace(/^\/(?:Users|home)\/[^/]+(?=\/|$)/, "~");
}

/** Newest first. */
function byRecency(sessions: AcpmuxSessionEntry[]): AcpmuxSessionEntry[] {
  return [...sessions].sort((left, right) => (activityTime(right) ?? 0) - (activityTime(left) ?? 0));
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

export function sessionPlace(session: AcpmuxSessionEntry, groupHost?: string): SessionPlace {
  const host = cloudHost(session);
  if (host && host !== groupHost) return { kind: "cloud", label: host, branch: session.branch };
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
