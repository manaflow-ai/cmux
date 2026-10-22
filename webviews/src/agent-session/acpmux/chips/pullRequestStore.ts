// What the host already has about a pull request a card shows (`pr.inspect`, Leo 2026-10-20).
//
// The host keeps the cache and reads gh in the background (AgentReplyPullRequests): a card asks
// the host, which answers at once from what it has, so hovering a link never waits on GitHub —
// a link the host's minute of freshness has run out on gets a background refresh, which is one
// read a minute for that link however often it is hovered, never one per hover.
// Leo's complaint was the opposite: the old card called GitHub per hover and showed "GitHub rate
// limit · resets 9:11 PM" where the pull request should be. Here the answer carries `fetchedAt`
// and the card prints its age ("updated 3 min ago"); a read that fails leaves the last good
// answer in place on the host's side and here.
//
// While the host says a read is running, the page asks it again every ``WAIT_MS`` — a local call
// to the app, never to GitHub — so a card opened before the first read lands fills in by itself.
import { useEffect, useSyncExternalStore } from "react";
import type { HeaderPullRequest } from "../header/headerState";
import { callChipHost } from "./host";

/** One file of a pull request, for the card's by-kind breakdown of its `+/−`. */
export type PullRequestFile = {
  readonly path: string;
  readonly additions: number;
  readonly deletions: number;
};

/** The header's pull request with everything else the card draws. */
export type LinkedPullRequest = HeaderPullRequest & {
  readonly author?: string;
  /** GitHub's ISO 8601 text; empty when the host did not say. */
  readonly createdAt?: string;
  readonly updatedAt?: string;
  readonly mergedAt?: string;
  readonly additions?: number;
  readonly deletions?: number;
  /** Files changed as GitHub counts them, which can be more than `files` holds. */
  readonly changedFiles?: number;
  readonly files?: readonly PullRequestFile[];
  readonly labels?: readonly string[];
  readonly baseRef?: string;
  readonly headRef?: string;
};

/** What the host has for one link: the pull request, and when gh last answered about it. */
export type PullRequestAnswer = {
  readonly pullRequest: LinkedPullRequest | null;
  /** Seconds since 1970; undefined when the host has never had an answer. */
  readonly fetchedAt?: number;
  /** The host is reading it now, so the page asks again shortly. */
  readonly reading: boolean;
};

/** How long the page waits before asking the host again while it reads. */
const WAIT_MS = 1_500;
const MAX_KEPT = 200;

const answers = new Map<string, PullRequestAnswer>();
const asking = new Set<string>();
const listeners = new Set<() => void>();

function changed() {
  for (const listener of listeners) listener();
}

/**
 * Whether two answers say the same thing. `fetchedAt` is when gh last answered about the link, so
 * an unchanged one means unchanged data: the answer object can stay the one React already has,
 * and a poll that learns nothing re-renders no cards.
 */
function same(previous: PullRequestAnswer | undefined, next: PullRequestAnswer): boolean {
  if (!previous) return false;
  if (previous.reading !== next.reading || previous.fetchedAt !== next.fetchedAt) return false;
  return previous.fetchedAt != null || previous.pullRequest === next.pullRequest;
}

function ask(url: string) {
  if (asking.has(url)) return;
  asking.add(url);
  let settled = false;
  void callChipHost("pr.inspect", { url })
    .then((reply) => {
      const value = (reply ?? {}) as {
        pullRequest?: LinkedPullRequest | null;
        fetchedAt?: unknown;
        reading?: unknown;
      };
      const pullRequest = value.pullRequest ?? null;
      const answer: PullRequestAnswer = {
        // The host never sends a worse answer than it had; keep ours when it sends none at all.
        pullRequest:
          pullRequest && typeof pullRequest.number === "number" ? pullRequest : (answers.get(url)?.pullRequest ?? null),
        fetchedAt: typeof value.fetchedAt === "number" ? value.fetchedAt : answers.get(url)?.fetchedAt,
        reading: value.reading === true,
      };
      if (same(answers.get(url), answer)) return;
      if (!answers.has(url) && answers.size >= MAX_KEPT) answers.delete(answers.keys().next().value!);
      answers.set(url, answer);
      settled = true;
    })
    .finally(() => {
      asking.delete(url);
      if (settled) changed();
    });
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/**
 * What the host has for the pull request at `url`; asks while `open` (a shown card), and again
 * while the host says it is reading. Undefined before the first answer.
 */
export function usePullRequestAnswer(url: string | undefined, open: boolean): PullRequestAnswer | undefined {
  // The snapshot is the answer itself, not a version counter: a counter leaves the map read
  // outside React's view, and the React Compiler then memoizes a stale answer forever (the card
  // stayed empty in the gallery build). An unchanged link keeps the same object, so this
  // re-renders only when its own answer changes.
  const read = () => (url ? answers.get(url) : undefined);
  const answer = useSyncExternalStore(subscribe, read, read);
  // No answer yet, or the host is still reading: ask it again until it settles.
  const waiting = answer === undefined || answer.reading;
  // One ask when the card opens…
  useEffect(() => {
    if (url && open) ask(url);
  }, [open, url]);
  // …then again every WAIT_MS only while the host is still reading. Both are calls to the app,
  // which answers from its cache; neither is a call to GitHub.
  useEffect(() => {
    if (!url || !open || !waiting) return;
    const timer = setInterval(() => ask(url), WAIT_MS);
    return () => clearInterval(timer);
  }, [open, url, waiting]);
  return answer;
}

/** Tests start from nothing. */
export function resetPullRequestStore(): void {
  answers.clear();
  asking.clear();
  changed();
}
