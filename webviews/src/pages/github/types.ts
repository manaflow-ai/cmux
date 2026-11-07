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
} as const;

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
