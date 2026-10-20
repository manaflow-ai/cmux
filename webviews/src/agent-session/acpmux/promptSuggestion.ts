import type { AcpmuxSessionEntry } from "./sessionList";

/// The prompt an idle new chat's empty composer suggests, Tab to take it (Leo 2026-10-18): the open
/// PR another chat in this checkout made, or else the checkout branch's own open PR as the App read it
/// with gh for the header's chip (`live`), which a fresh agent can act on with `gh pr view`. Only
/// PRs: a previous chat's title means nothing to an agent that has none of its context.
export type PromptSuggestion = { kind: "failing" | "draft" | "open"; number: number; title: string };

/// A PR older than this is likely settled or forgotten; the suggestion stays quiet.
const RECENT_MS = 3 * 24 * 60 * 60 * 1000;
const TITLE_MAX = 60;

/// The chat folder's PR as the header has it (header/headerState.ts): `state` is `open`, `draft`,
/// `merged` or `closed`, and `checks` its summed checks (`failing`, `pending`, `passing`, `none`).
export type LivePullRequest = { number: number; title: string; state: string; checks: string };

/** The newest open or draft PR of another recent chat in `cwd`, else `live` (the folder's own PR) when
 * it is open or a draft, unless a chat is already on it (for `live`, unless any chat in the checkout works). */
export function promptSuggestion(
  sessions: readonly AcpmuxSessionEntry[] | undefined,
  here: { sessionId?: string; cwd?: string; branch?: string },
  now: number,
  live?: LivePullRequest,
): PromptSuggestion | undefined {
  if (!here.cwd) return undefined;
  sessions ??= [];
  // Another chat in this checkout: a worktree chat's own folder is its cwd, and a known branch must agree.
  const sameCheckout = (entry: AcpmuxSessionEntry) =>
    entry.sessionId !== here.sessionId &&
    !entry.archived &&
    entry.cwd === here.cwd &&
    (!entry.worktree || entry.worktree === here.cwd) &&
    (!here.branch || !entry.branch || entry.branch === here.branch);
  const working = (entry: AcpmuxSessionEntry) => entry.indicator === "working" || entry.indicator === "input";
  const source = sessions
    .filter(
      (entry) =>
        sameCheckout(entry) &&
        (entry.pullRequest?.state === "open" || entry.pullRequest?.state === "draft") &&
        entry.updatedAt !== undefined &&
        now - entry.updatedAt <= RECENT_MS,
    )
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0];
  const pr = source?.pullRequest ?? (live && (live.state === "open" || live.state === "draft") ? live : undefined);
  if (!pr) return undefined;
  // A chat already working on (or waiting about) this PR has it; a second agent would collide. Live
  // session summaries name no PR, so for the folder's own PR any working chat in this checkout may be
  // on it: the suggestion stays quiet then.
  const busy = sessions.some(
    (entry) => sameCheckout(entry) && working(entry) && (pr === live || entry.pullRequest?.number === pr.number),
  );
  if (busy) return undefined;
  const title = pr.title.length > TITLE_MAX ? `${pr.title.slice(0, TITLE_MAX - 1).trimEnd()}…` : pr.title;
  const kind = pr.checks === "failing" ? "failing" : pr.state === "draft" ? "draft" : "open";
  return { kind, number: pr.number, title };
}
