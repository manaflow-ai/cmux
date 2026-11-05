import type { AcpmuxSessionEntry } from "./sessionList";
import { sliceWhole } from "../../ui/wholeChars";

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
  const cwd = folder(here.cwd);
  if (!cwd) return undefined;
  sessions ??= [];
  const other = (entry: AcpmuxSessionEntry) => entry.sessionId !== here.sessionId && !entry.archived;
  // Another chat in this checkout: a worktree chat's own folder is its cwd, and a known branch must agree.
  const sameCheckout = (entry: AcpmuxSessionEntry) =>
    other(entry) &&
    folder(entry.cwd) === cwd &&
    (!entry.worktree || folder(entry.worktree) === cwd) &&
    (!here.branch || !entry.branch || entry.branch === here.branch);
  // Another chat changing these files, whatever branch it last recorded.
  const sameTree = (entry: AcpmuxSessionEntry) =>
    other(entry) && (folder(entry.cwd) === cwd || folder(entry.worktree) === cwd);
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
  // A second agent would collide with a chat working (or waiting) in this working tree, whatever PR
  // it reports (live session summaries name none), and with one working on this PR in any folder.
  const busy = sessions.some(
    (entry) => working(entry) && (sameTree(entry) || (other(entry) && entry.pullRequest?.number === pr.number)),
  );
  if (busy) return undefined;
  const title = pr.title.length > TITLE_MAX ? `${sliceWhole(pr.title, TITLE_MAX - 1).trimEnd()}…` : pr.title;
  const kind = pr.checks === "failing" ? "failing" : pr.state === "draft" ? "draft" : "open";
  return { kind, number: pr.number, title };
}

/** A folder path without its trailing slashes, so `/x/app/` and `/x/app` are one checkout. */
export function folder(path: string | undefined): string | undefined {
  return path?.replace(/\/+$/, "") || undefined;
}
