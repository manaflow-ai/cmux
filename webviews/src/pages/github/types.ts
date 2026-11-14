// The GitHub page's ops (`cmux.github.*`, GitHubPageProvider.swift). `pr.inspect` and
// `browser.openIn` are the agent page's link card methods under this page's namespace: the pull
// request comes from the app's one cache (AgentReplyPullRequests), never a GitHub call per ask.
import type { LinkedPullRequest } from "../../agent-session/acpmux/chips/pullRequestStore";

export type { LinkedPullRequest };

export const GitHubOps = {
  /** `{url, cached?}` → `PullRequestReply`. Starts a background read when the host's copy is stale. */
  inspect: "cmux.github.pr.inspect",
  /** `{url, browserId: "cmux"}`: opens the web page in a cmux tab; needs the person's click. */
  openIn: "cmux.github.browser.openIn",
  /** `{url, file?}`: the pull request's diff in the diff viewer; needs the person's click. */
  openDiff: "cmux.github.diff.open",
  /** `{url, content}`: the page drew the pull request (`content`) or its loading or failure state. */
  shown: "cmux.github.shown",
  /** `{url}` → `{details}`: body, conversation, reviewers, closed issues; one GitHub read per `updatedAt`. */
  details: "cmux.github.pr.details",
  /** `{url, file}` → `{patch, tooLarge?}`: one file's part of the diff, for its inline expand. */
  diffFile: "cmux.github.diff.file",
  /** `{url, head}` → `{merged, queued}`: GitHub's normal merge, pinned to `head`; needs the person's click. */
  merge: "cmux.github.pr.merge",
} as const;

/** One review comment, on a line of a file. */
export interface ReviewComment {
  path: string;
  line: number | null;
  body: string;
  url: string | null;
}

/** A comment or a review in the conversation. */
export interface ConversationEntry {
  kind: "comment" | "review";
  author: string;
  body: string;
  /** ISO 8601. */
  at: string;
  url: string | null;
  /** A review's verdict: `approved`, `changes_requested`, `commented`, `dismissed`. */
  state: string | null;
  comments: ReviewComment[];
}

/** The host's `pr.details` answer (GitHubPullRequestDetails.swift). */
export interface PullRequestDetails {
  body: string;
  /** The head commit the page shows: Merge is pinned to it. */
  headCommit: string;
  /** GitHub's merge state, lowercased: `clean`, `unstable`, `blocked`, `behind`, `dirty`, `unknown`. */
  mergeState: string;
  mergeMethod: "merge" | "squash" | "rebase";
  /** Six hex digits, or empty. */
  labels: { name: string; color: string }[];
  conversation: ConversationEntry[];
  /** How many comments and reviews GitHub has; can be more than `conversation` holds. */
  conversationTotal: number;
  /** `approved`, `changes_requested`, `commented`, `dismissed` or `requested`. */
  reviewers: { name: string; state: string }[];
  linked: { number: number; title: string; url: string; state: string }[];
}

/** One file's inline diff, as the page holds it. */
export type FilePatch =
  | { state: "loading" }
  | { state: "ready"; patch: string }
  | { state: "tooLarge" }
  | { state: "missing" }
  | { state: "failed"; message: string };

/** Merge's progress on the page: `confirm` is the first click, which asks for the second. */
export type MergeState =
  | { phase: "idle" }
  | { phase: "confirm" }
  | { phase: "merging" }
  | { phase: "merged"; queued: boolean }
  | { phase: "failed"; message: string };

/** The host's answer to `pr.inspect`. */
export interface PullRequestReply {
  pullRequest?: LinkedPullRequest | null;
  /** Seconds since 1970; absent before gh first answered. */
  fetchedAt?: number;
  /** The host is reading it now: ask again shortly. */
  reading?: boolean;
}

/** The pull request a route names (`#/pull?url=<address>`), else undefined. */
export function routedPullRequest(hash: string): { url: string; repo: string; number: number } | undefined {
  const route = hash.startsWith("#") ? hash.slice(1) : hash;
  if (!route.startsWith("/pull?")) return undefined;
  const address = new URLSearchParams(route.slice("/pull?".length)).get("url");
  const match = address ? /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/([1-9]\d{0,9})$/.exec(address) : null;
  return match ? { url: address!, repo: match[1]!, number: Number(match[2]) } : undefined;
}
