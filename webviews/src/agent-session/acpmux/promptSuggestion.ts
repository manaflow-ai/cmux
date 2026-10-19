import type { AcpmuxSessionEntry } from "./sessionList";

/// The prompt an idle new chat's empty composer suggests, Tab to take it (Leo 2026-10-18): the open
/// PR another chat in this checkout made, which a fresh agent can act on with `gh pr view`. Only
/// PRs: a previous chat's title means nothing to an agent that has none of its context.
export type PromptSuggestion = { kind: "failing" | "draft" | "open"; number: number; title: string };

/// A PR older than this is likely settled or forgotten; the suggestion stays quiet.
const RECENT_MS = 3 * 24 * 60 * 60 * 1000;
const TITLE_MAX = 60;

/** The newest open or draft PR of another recent chat in `cwd`, unless a chat is already on it. */
export function promptSuggestion(
  sessions: readonly AcpmuxSessionEntry[] | undefined,
  here: { sessionId?: string; cwd?: string; branch?: string },
  now: number,
): PromptSuggestion | undefined {
  if (!here.cwd || !sessions) return undefined;
  const source = sessions
    .filter(
      (entry) =>
        entry.sessionId !== here.sessionId &&
        !entry.archived &&
        entry.cwd === here.cwd &&
        // The same checkout: a worktree chat's own folder is its cwd, and a known branch must agree.
        (!entry.worktree || entry.worktree === here.cwd) &&
        (!here.branch || !entry.branch || entry.branch === here.branch) &&
        (entry.pullRequest?.state === "open" || entry.pullRequest?.state === "draft") &&
        entry.updatedAt !== undefined &&
        now - entry.updatedAt <= RECENT_MS,
    )
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0];
  const pr = source?.pullRequest;
  if (!pr) return undefined;
  // A chat already working on (or waiting about) this PR has it; a second agent would collide.
  const busy = sessions.some(
    (entry) =>
      entry.pullRequest?.number === pr.number &&
      entry.cwd === here.cwd &&
      (entry.indicator === "working" || entry.indicator === "input"),
  );
  if (busy) return undefined;
  const title = pr.title.length > TITLE_MAX ? `${pr.title.slice(0, TITLE_MAX - 1).trimEnd()}…` : pr.title;
  const kind = pr.checks === "failing" ? "failing" : pr.state === "draft" ? "draft" : "open";
  return { kind, number: pr.number, title };
}
