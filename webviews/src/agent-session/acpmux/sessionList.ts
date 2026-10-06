// The session sidebar's model: what each session row shows and how rows group
// by project. It follows the acpmux TUI sidebar (crates/acpmux/src/tui/render),
// so a session reads the same in the terminal and in the pane.
import { type Translate, translate } from "./i18n";

/** A session as the sidebar sees it, cut from acpmux's session summary. */
export type AcpmuxSessionEntry = {
  sessionId: string;
  displayTitle?: string;
  title?: string;
  name?: string;
  harness?: string;
  status?: string;
  model?: string;
  cwd?: string;
  updatedAt?: number;
  pendingPermissions?: number;
  unread?: boolean;
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
  pullRequest?: SessionPullRequest;
  /** A line of the session's latest reply, for previews. */
  preview?: string;
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

export type SessionGroup = {
  key: string;
  label: string;
  cwd?: string;
  host?: string;
  sessions: AcpmuxSessionEntry[];
};

/** The tag that pins a session to the top of the list. */
export const PINNED_TAG = "pinned";
/** The tag the chat menu's Archive sets. */
export const ARCHIVED_TAG = "archived";

/** Whether acpmux's tags (an object of key to value; a list in older fixtures) hold `tag`. */
function tagged(tags: unknown, tag: string): boolean {
  if (Array.isArray(tags)) return tags.includes(tag);
  return typeof tags === "object" && tags !== null && tag in tags;
}

/** What a row draws at its right edge, most urgent first. */
export type SessionMark = "input" | "running" | "error" | "unread" | undefined;

/** A long group shows this many rows and a "Show more" (the TUI's GROUP_ROWS). */
export const GROUP_ROWS = 6;

/** Cuts acpmux's session summary down to the fields the pane uses. */
export function sessionEntry(session: Record<string, any> & { sessionId: string }): AcpmuxSessionEntry {
  const pending = Number(session.pendingPermissions ?? 0);
  return {
    sessionId: session.sessionId,
    displayTitle: sessionTitle(session),
    title: session.title,
    name: session.name,
    harness: session.harness,
    status: session.status,
    model: session.model,
    cwd: typeof session.cwd === "string" ? session.cwd : undefined,
    updatedAt: typeof session.updatedAt === "number" ? session.updatedAt : undefined,
    pendingPermissions: Number.isFinite(pending) ? pending : 0,
    unread: session.unread === true,
    host: text(session.host),
    peer: text(session.peer),
    hostKind: hostKind(session.hostKind),
    branch: text(session.branch),
    worktree: text(session.worktree),
    pinned: session.pinned === true || tagged(session.tags, PINNED_TAG),
    archived: session.archived === true || tagged(session.tags, ARCHIVED_TAG),
    pullRequest: pullRequest(session.pullRequest),
    preview: text(session.preview),
  };
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
  session: { title?: string; lastPrompt?: string; name?: string; harness?: string; family?: string; sessionId: string },
  t: Translate = translate,
): string {
  const name = session.name ?? "";
  const bare = name.split("/").pop() ?? name;
  // acpmux names a session `agent` or `agent-N`, and a fork `<name>-fork`, also made unique with `-N`.
  const generatedFrom = (agent: string | undefined) =>
    !!agent && bare.startsWith(agent) && /^(?:-(?:fork|\d+))*$/.test(bare.slice(agent.length));
  if (name && !generatedFrom(session.harness) && !generatedFrom(session.family)) return name;
  return session.title?.trim() || session.lastPrompt?.trim() || t("sidebar.newChat");
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
  return [...sessions].sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0));
}

/** Sessions under one header per folder (a cloud-only folder per machine). Groups follow their most recent session; sessions stay newest first. */
export function groupByProject(
  sessions: AcpmuxSessionEntry[],
  // Every session, pinned ones too, so pinning a local session doesn't regroup its cloud siblings.
  all: AcpmuxSessionEntry[] = sessions,
): SessionGroup[] {
  const folder = (session: AcpmuxSessionEntry) => (session.cwd ?? "").replace(/\/+$/, "");
  // A cloud session joins the local project at the same path; otherwise its folder is only
  // known on its machine, so `/workspace` on two machines stays two projects.
  const local = new Set(all.filter((session) => !cloudHost(session)).map(folder));
  const groups = new Map<string, SessionGroup>();
  for (const session of byRecency(sessions)) {
    const cwd = folder(session);
    const host = cloudHost(session);
    const key = host && !local.has(cwd) ? `${host}:${cwd}` : cwd;
    let group = groups.get(key);
    if (!group) {
      group = { key, label: projectLabel(cwd), cwd: cwd || undefined, sessions: [] };
      groups.set(key, group);
    }
    group.sessions.push(session);
  }
  for (const group of groups.values()) group.host = sharedCloudHost(group.sessions);
  return [...groups.values()];
}

/** The remote machine a session runs on. A host not marked local counts as remote; this Mac is never named. */
export const cloudHost = (session: AcpmuxSessionEntry) =>
  session.hostKind === "local" ? undefined : (session.peer ?? session.host);

/** The one cloud machine every session in a group runs on, else undefined. */
function sharedCloudHost(sessions: AcpmuxSessionEntry[]) {
  const host = cloudHost(sessions[0]!);
  return host && sessions.every((session) => cloudHost(session) === host) ? host : undefined;
}

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

/** Sessions whose title, name, folder, branch, worktree or cloud machine contains every word of the query, ignoring case. */
export function filterSessions(sessions: AcpmuxSessionEntry[], query: string): AcpmuxSessionEntry[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return sessions;
  return sessions.filter((session) => {
    const text = [
      session.displayTitle,
      session.title,
      session.name,
      // Folder names, not full paths: a path prefix like `/Users/me` would match every session.
      session.cwd && projectLabel(session.cwd),
      session.branch,
      session.worktree && projectLabel(session.worktree),
      cloudHost(session),
    ]
      .filter(Boolean)
      .join("\n")
      .toLowerCase();
    return terms.every((term) => text.includes(term));
  });
}

/** The list's two sections: pinned sessions, newest first, then every other session grouped by project. A query narrows both. Archived sessions are in neither. */
export function sidebarSections(
  all: AcpmuxSessionEntry[],
  query = "",
): {
  pinned: AcpmuxSessionEntry[];
  groups: SessionGroup[];
} {
  const sessions = all.filter((session) => !session.archived);
  const pinned = byRecency(
    filterSessions(
      sessions.filter((session) => session.pinned),
      query,
    ),
  );
  const groups = groupByProject(
    sessions.filter((session) => !session.pinned),
    sessions,
  );
  if (!query.trim()) return { pinned, groups };
  // Projects and their headers come from every session, so a search only hides rows.
  return {
    pinned,
    groups: groups
      .map((group) => ({ ...group, sessions: filterSessions(group.sessions, query) }))
      .filter((group) => group.sessions.length > 0),
  };
}

/** The row's mark: a pending permission or a wait for one needs the user; then work in progress, a lost agent, and work that ended unseen. */
export function sessionMark(session: AcpmuxSessionEntry, selected: boolean): SessionMark {
  if ((session.pendingPermissions ?? 0) > 0 || session.status === "waiting") return "input";
  if (session.status === "running") return "running";
  if (session.status === "disconnected" || session.status === "unreachable") return "error";
  if (session.unread && !selected) return "unread";
  return undefined;
}

/** The rows a group shows: all of a short group, else its first GROUP_ROWS unless expanded or holding the selection. */
export function visibleSessions(
  group: SessionGroup,
  expanded: boolean,
  selectedId?: string,
): { rows: AcpmuxSessionEntry[]; hidden: number } {
  const open =
    expanded ||
    group.sessions.length <= GROUP_ROWS + 1 ||
    group.sessions.slice(GROUP_ROWS).some((session) => session.sessionId === selectedId);
  if (open) return { rows: group.sessions, hidden: 0 };
  return { rows: group.sessions.slice(0, GROUP_ROWS), hidden: group.sessions.length - GROUP_ROWS };
}

/** A project header's mark: the most urgent of its sessions' needs-input and lost marks. */
export function groupMark(group: SessionGroup, selectedId?: string): "input" | "error" | undefined {
  let mark: "input" | "error" | undefined;
  for (const session of group.sessions) {
    const own = sessionMark(session, session.sessionId === selectedId);
    if (own === "input") return "input";
    if (own === "error") mark = "error";
  }
  return mark;
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
