// The session sidebar's model: what each session row shows and how rows group
// by project. It follows the acpmux TUI sidebar (crates/acpmux/src/tui/render),
// so a session reads the same in the terminal and in the pane.

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
  /// Tagged `pinned` through `_acpmux/tag`; listed under Pinned instead of its project.
  pinned?: boolean;
  /// The machine the session runs on, when the summary names one.
  host?: string;
};

export type SessionGroup = { key: string; label: string; cwd?: string; host?: string; sessions: AcpmuxSessionEntry[] };

/** The tag that pins a session to the top of the list. */
export const PINNED_TAG = "pinned";

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
    pinned: Array.isArray(session.tags) && session.tags.includes(PINNED_TAG),
    host: typeof session.host === "string" && session.host ? session.host : undefined,
  };
}

/** The title (the first prompt) when the name was generated (`codex`, `codex-3`), else the name the user gave. */
export function sessionTitle(session: { title?: string; name?: string; harness?: string; sessionId: string }): string {
  const name = session.name ?? "";
  const harness = session.harness ?? "";
  const bare = name.split("/").pop() ?? name;
  const generated =
    !name ||
    (harness !== "" &&
      (bare === harness || (bare.startsWith(`${harness}-`) && /^\d+$/.test(bare.slice(harness.length + 1)))));
  const title = session.title?.trim();
  if (generated) return title || name || session.sessionId.slice(0, 8);
  return name;
}

/** A project's name for its header: the folder's last component, `~` for a home folder. */
export function projectLabel(cwd: string | undefined): string {
  const trimmed = (cwd ?? "").replace(/\/+$/, "");
  if (!trimmed) return "No folder";
  const parts = trimmed.split("/").filter(Boolean);
  if (parts.length === 2 && (parts[0] === "Users" || parts[0] === "home")) return "~";
  return parts[parts.length - 1] ?? trimmed;
}

/** Newest first. */
function byRecency(sessions: AcpmuxSessionEntry[]): AcpmuxSessionEntry[] {
  return [...sessions].sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0));
}

/** Sessions under one header per folder and machine. Groups follow their most recent session; sessions stay newest first. */
export function groupByProject(sessions: AcpmuxSessionEntry[]): SessionGroup[] {
  const groups = new Map<string, SessionGroup>();
  for (const session of byRecency(sessions)) {
    const cwd = (session.cwd ?? "").replace(/\/+$/, "");
    // The same folder on two machines is two projects.
    const key = session.host ? `${session.host}:${cwd}` : cwd;
    let group = groups.get(key);
    if (!group) {
      group = { key, label: projectLabel(cwd), cwd: cwd || undefined, host: session.host, sessions: [] };
      groups.set(key, group);
    }
    group.sessions.push(session);
  }
  return [...groups.values()];
}

/** The list's two sections: pinned sessions, newest first, then every other session grouped by project. */
export function sidebarSections(sessions: AcpmuxSessionEntry[]): {
  pinned: AcpmuxSessionEntry[];
  groups: SessionGroup[];
} {
  return {
    pinned: byRecency(sessions.filter((session) => session.pinned)),
    groups: groupByProject(sessions.filter((session) => !session.pinned)),
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
