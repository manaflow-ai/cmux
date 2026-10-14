// The chat's pull requests, one source for the pull request dock (PullRequestDock.tsx) and the
// composer strip (strip/StripPullRequests.tsx): each `gh pr create` the chat ran
// (sessionSummary.ts), newest first, less the ones dismissed in this chat. A dismissal is kept in
// the page's storage, so a reload keeps the pull request hidden.
import { useRef, useState } from "react";
import type { StringKey } from "../i18n";
import type { AcpmuxRow } from "../model";
import type { HeaderPullRequest } from "../header/headerState";
import { sessionPullRequests, type SummaryPullRequest } from "./sessionSummary";

/// Each state's short label.
export const PULL_REQUEST_BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};

const storageKey = (sessionId: string) => `acpmux.prDock.dismissed.${sessionId}`;

/// The pull request URLs dismissed in this chat; none when the page has no storage.
function readDismissed(sessionId: string | undefined): string[] {
  if (!sessionId) return [];
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey(sessionId)) ?? "[]");
    return Array.isArray(value) ? value.filter((url): url is string => typeof url === "string") : [];
  } catch {
    return [];
  }
}

function writeDismissed(sessionId: string | undefined, urls: readonly string[]): void {
  if (!sessionId) return;
  try {
    localStorage.setItem(storageKey(sessionId), JSON.stringify(urls));
  } catch {
    // Without storage the pull request stays hidden until the page reloads.
  }
}

/// A pull request's state and title: the live ones when the header follows this pull request.
/// Without them, "open" is only what the chat last saw, so `labeled` is false: name no state
/// rather than a stale one.
export function shownPullRequest(
  pr: SummaryPullRequest,
  live: HeaderPullRequest | undefined,
): { state: string; title: string; labeled: boolean } {
  if (live?.url === pr.url) return { state: live.state, title: live.title || (pr.title ?? ""), labeled: true };
  return { state: pr.state, title: pr.title ?? "", labeled: pr.state !== "open" };
}

/// The chat's pull requests, newest first, without the dismissed ones, and `dismiss`. Mount the
/// caller keyed by the chat: dismissals belong to one chat.
export function useChatPullRequests(
  rows: readonly AcpmuxRow[],
  sessionId: string | undefined,
): { prs: SummaryPullRequest[]; dismiss(url: string): void } {
  // Every streamed chunk is a new rows array: parse again only when a tool call changed.
  const parsed = useRef<{ key: string; prs: SummaryPullRequest[] }>(undefined);
  const key = rows.flatMap((row) => (row.kind === "activity" ? [`${row.id}:${row.version}`] : [])).join(",");
  if (parsed.current?.key !== key) parsed.current = { key, prs: sessionPullRequests(rows) };
  const all = parsed.current.prs;
  const [dismissed, setDismissed] = useState(() => readDismissed(sessionId));
  return {
    prs: all.filter((pr) => !dismissed.includes(pr.url)).reverse(),
    dismiss: (url) => {
      const next = [...dismissed, url];
      setDismissed(next);
      writeDismissed(sessionId, next);
    },
  };
}
