import { pullRequestStateSince, type HeaderPullRequest } from "../header/headerState";
import type { SummaryPullRequest } from "../summary/sessionSummary";
import type { PullRequestGlyphState } from "./pullRequestGlyphModel";

/// Rows shown before Show more (Claude Code desktop's Changes shows five).
export const CHANGES_SHOWN = 5;

/// Lines a pull request adds and removes in one kind of file.
export type LineCounts = { readonly additions: number; readonly deletions: number };
export type ChangeKind = "code" | "tests" | "generated" | "docs";
export const KINDS: readonly ChangeKind[] = ["code", "tests", "generated", "docs"];
/// What the App knows of a pull request now; any field it has not read is left out.
export type SessionInfoPullRequestStatus = {
  title?: string;
  /// `open`, `draft`, `merged` or `closed`.
  state?: string;
  /// `mergeable`, `conflicting`, or empty while GitHub works it out.
  mergeable?: string;
  additions?: number;
  deletions?: number;
  /// The same lines split by the kind of file they are in.
  breakdown?: Partial<Record<ChangeKind, LineCounts>>;
  /// The checks summed: `failing`, `pending`, `passing` or `none`.
  checks?: string;
  /// How many checks fail, and how many of those fail on the base branch's head too.
  failing?: number;
  failingOnBase?: number;
  /// How many comments and reviews it has.
  comments?: number;
  /// Who owns it: the agent or person the App names (a login, a lane's callsign).
  owner?: string;
  /// When the App first read it in `state` (epoch ms).
  since?: number;
};

/// The header's pull request (the chat folder's, read live by the App) as a status.
export function headerStatus(pr: HeaderPullRequest | undefined): Record<string, SessionInfoPullRequestStatus> {
  if (!pr) return {};
  const failing = pr.checkList.filter((check) => check.state === "failed").length;
  return {
    [pr.url]: {
      title: pr.title || undefined,
      state: pr.state || undefined,
      mergeable: pr.mergeable || undefined,
      checks: pr.checks.state,
      ...(failing > 0 ? { failing } : {}),
      since: pullRequestStateSince(pr.url),
    },
  };
}

export const ABBREVIATE_FROM = 10_000;

/** A row count (lines, comments, failing checks) short enough for a narrow row: 1,284, then 12.3K,
 *  4.6M ... 9Q. Below 10,000 the number is exact; above it, screen readers get the exact one. */
export function formatCount(count: number): string {
  if (count < ABBREVIATE_FROM) return count.toLocaleString();
  const units = ["K", "M", "B", "T", "Q"];
  let value = count;
  let unit = "";
  for (const candidate of units) {
    if (value < 1000) break;
    value /= 1000;
    unit = candidate;
  }
  const rounded = value >= 100 ? Math.round(value) : value.toFixed(1).replace(/\.0$/, "");
  return `${rounded}${unit}`;
}

/// What the row shows of `pr`: the App's read when it is newer than what the chat did.
export function rowState(pr: SummaryPullRequest, live: SessionInfoPullRequestStatus): string {
  // A merge the chat ran is final. A close wins until a later read differs (a reopen). An open
  // one defers to the App.
  if (pr.state === "closed") {
    const after = live.since !== undefined && pr.closedAt !== undefined && live.since > pr.closedAt;
    return after && live.state ? live.state : "closed";
  }
  return pr.state !== "open" ? pr.state : (live.state ?? "open");
}

/// The glyph a row draws: its state, and an open one GitHub can't merge for conflicts is red.
export function glyphState(pr: SummaryPullRequest, live: SessionInfoPullRequestStatus): PullRequestGlyphState {
  const state = rowState(pr, live);
  if (state === "merged" || state === "closed" || state === "draft") return state;
  return live.mergeable === "conflicting" ? "conflicting" : "open";
}

export const ended = (state: PullRequestGlyphState) => state === "merged" || state === "closed";

/// Changes contains only pull requests this session created or mutated. Read-only PR and issue
/// references stay in Sources, even after the App has read them as pull requests.
export const visibleChanges = (
  pullRequests: readonly SummaryPullRequest[],
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>,
): SummaryPullRequest[] => {
  void statuses;
  return pullRequests.filter((pr) => pr.kind !== "issue" && (pr.opened || pr.changed === true));
};

/// The rows in Claude's order: the ones still open (drafts and conflicting ones included) first,
/// then the merged and closed, the most recently touched or named first within each.
export function changesOrder(
  pullRequests: readonly SummaryPullRequest[],
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>,
): SummaryPullRequest[] {
  const newest = pullRequests
    .map((pr, index) => ({ pr, index, at: pr.touched ?? index }))
    .sort((a, b) => b.at - a.at || b.index - a.index)
    .map(({ pr }) => pr);
  const done = (pr: SummaryPullRequest) => ended(glyphState(pr, statuses[pr.url] ?? {}));
  return [...newest.filter((pr) => !done(pr)), ...newest.filter(done)];
}
