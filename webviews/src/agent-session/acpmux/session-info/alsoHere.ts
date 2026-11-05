// "Also working here": the other live chats acpmux lists that work where this chat works, for
// Session Info (AlsoHereSection.tsx). A chat counts when it runs on the same machine in the same
// worktree or folder (one inside the other), or on the same feature branch anywhere (a branch with
// a `/`, `lane/x` or `fix/y`: `main` and `feat-cmux-next` are every clone's, not one task's). This
// chat's own family (its sub-sessions, forks and side chats) is not someone else, nor is a closed,
// archived or day-old chat. Which files two chats share is acpmux's `who_else` (the transcript's
// card); this list needs no request. Leo, 2026-11-05: "CMUX next can maybe do that, like for other
// agents, other harnesses as well."
import type { AcpmuxSessionEntry } from "../sessionList";

/// How recent a chat's last activity must be to count: a day.
export const ALSO_HERE_WINDOW_MS = 24 * 60 * 60 * 1000;

export type AlsoHere = {
  entry: AcpmuxSessionEntry;
  /// Why it is listed: the same worktree or folder, else the same branch.
  why: "folder" | "branch";
};

/// The folders `a` and `b` are one, or one holds the other.
function sameFolder(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  const trim = (p: string) => p.replace(/\/+$/, "");
  const [x, y] = [trim(a), trim(b)];
  return x === y || x.startsWith(`${y}/`) || y.startsWith(`${x}/`);
}

/// The chat `id` and every chat that hangs off it, at any depth.
function family(id: string, all: readonly AcpmuxSessionEntry[]): Set<string> {
  const mine = new Set([id]);
  for (let grew = true; grew;) {
    grew = false;
    for (const e of all) {
      if (mine.has(e.sessionId)) continue;
      const up = [e.startedBy, e.spawnedBy, e.parentId, e.reportsTo];
      if (up.some((p) => p !== undefined && mine.has(p))) {
        mine.add(e.sessionId);
        grew = true;
      }
    }
  }
  // Its own parents too: the chat that started this one is not "also here".
  const own = all.find((e) => e.sessionId === id);
  for (const p of [own?.startedBy, own?.spawnedBy, own?.parentId, own?.reportsTo]) if (p) mine.add(p);
  return mine;
}

/// The chats working where chat `chatId` works, the folder's first, then the most recently active.
export function alsoHere(
  chatId: string | undefined,
  all: readonly AcpmuxSessionEntry[] | undefined,
  now: number,
): AlsoHere[] {
  if (!chatId || !all?.length) return [];
  const own = all.find((e) => e.sessionId === chatId);
  if (!own) return [];
  const folder = own.worktree ?? own.cwd;
  const branch = own.branch?.includes("/") ? own.branch : undefined;
  const mine = family(chatId, all);
  const at = (e: AcpmuxSessionEntry) => e.activityAt ?? e.updatedAt ?? 0;
  const out: AlsoHere[] = [];
  for (const e of all) {
    if (mine.has(e.sessionId) || e.archived || e.side || e.status === "closed") continue;
    if (now - at(e) > ALSO_HERE_WINDOW_MS && e.status !== "running") continue;
    const here = (e.peer ?? "") === (own.peer ?? "") && sameFolder(e.worktree ?? e.cwd, folder);
    if (here) out.push({ entry: e, why: "folder" });
    else if (branch && e.branch === branch) out.push({ entry: e, why: "branch" });
  }
  return out.sort((a, b) => Number(a.why === "branch") - Number(b.why === "branch") || at(b.entry) - at(a.entry));
}
