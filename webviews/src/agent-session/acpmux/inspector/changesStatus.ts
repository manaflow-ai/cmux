// What the App has read of each pull request in the Inspector's Changes: its title, state (a
// draft included), whether it conflicts, its lines by kind of file, its comments and its failing checks. It all
// comes from the App's one pull request cache (AgentReplyPullRequests, the one the reply links'
// hover cards read): never a GitHub call per row, and no polling of GitHub.
//
// When the list opens or names new pull requests, the page registers them with the host
// (`link.inspect`, sixty-four to a call, the host's bound per request), which reads every stale one
// in one batched GraphQL query and never the same link twice in a minute; then it asks the host
// for each answer (`pr.inspect`), a local call that never waits on GitHub. While the host says a
// read is running, the page asks it again every WAIT_MS (a call to the App, as the hover card
// does), and a later transcript change registers the list again at most once a minute. The
// header's pull request (the chat folder's, which the App reads live) wins over the cache.
import { useEffect, useSyncExternalStore } from "react";
import { kindTotals } from "../../../fileKinds";
import { callChipHost } from "../chips/host";
import {
  askPullRequest,
  pullRequestAnswer,
  subscribePullRequests,
  type PullRequestAnswer,
} from "../chips/pullRequestStore";
import type { ChangeKind, InspectorPullRequestStatus, LineCounts } from "./ChangesSection";

/// The most links the host prefetches per `link.inspect` (AgentReplyPullRequests.maximumRegistered,
/// AgentPaneReplyRequest.maximumInspect).
export const REGISTER_BATCH = 64;
/// How long a registration stands: the host's freshness, after which it reads the link again.
export const REGISTER_EVERY_MS = 60_000;
/// How long the page waits before asking the host again while it reads.
const WAIT_MS = 1_500;

const registered = new Map<string, number>();
/// The state the page first saw each pull request in, and when (epoch ms). A row compares that with
/// when the chat closed it: a read that started before the close and answered after it still says
/// open, but the page saw it open before the close, so the close stands (the header's own rule,
/// headerState.stateSince). The host's `fetchedAt` is when a read finished, too late for that.
const firstSeen = new Map<string, { state: string; at: number }>();
const MAX_SEEN = 500;

function seenSince(url: string, state: string, now: number): number {
  const seen = firstSeen.get(url);
  if (seen?.state === state) return seen.at;
  if (!seen && firstSeen.size >= MAX_SEEN) firstSeen.delete(firstSeen.keys().next().value!);
  firstSeen.set(url, { state, at: now });
  return now;
}

/// Registers the links not registered in the last minute, REGISTER_BATCH to a call, then asks the host
/// for each one's answer.
export function refreshChanges(urls: readonly string[], now = Date.now()): void {
  // A registration older than a minute is due again anyway, so it need not be kept.
  for (const [url, at] of registered) if (now - at >= REGISTER_EVERY_MS) registered.delete(url);
  const due = urls.filter((url) => !registered.has(url));
  for (let start = 0; start < due.length; start += REGISTER_BATCH) {
    const batch = due.slice(start, start + REGISTER_BATCH);
    for (const url of batch) registered.set(url, now);
    void callChipHost("link.inspect", { paths: [], urls: batch }).then(() => {
      for (const url of batch) askPullRequest(url);
    });
  }
  // A link registered lately that the page has no answer for yet (another chat registered it).
  for (const url of urls) if (!due.includes(url) && !pullRequestAnswer(url)) askPullRequest(url);
}

const BREAKDOWN: Record<string, ChangeKind> = {
  code: "code",
  tests: "tests",
  mocks: "tests",
  evals: "tests",
  docs: "docs",
  generated: "generated",
};

/// One answer as the row reads it; undefined when the host has none.
export function changesStatus(
  answer: PullRequestAnswer | undefined,
  now = Date.now(),
): InspectorPullRequestStatus | undefined {
  const pr = answer?.pullRequest;
  if (!pr) return undefined;
  const failing = pr.checkList.filter((check) => check.state === "failed").length;
  const breakdown: Partial<Record<ChangeKind, LineCounts>> = {};
  for (const total of kindTotals(pr.files ?? [])) {
    const kind = BREAKDOWN[total.kind] ?? "code";
    const was = breakdown[kind] ?? { additions: 0, deletions: 0 };
    breakdown[kind] = { additions: was.additions + total.additions, deletions: was.deletions + total.deletions };
  }
  return {
    ...(pr.title ? { title: pr.title } : {}),
    ...(pr.state ? { state: pr.state } : {}),
    ...(pr.mergeable ? { mergeable: pr.mergeable } : {}),
    ...(typeof pr.additions === "number" && typeof pr.deletions === "number"
      ? { additions: pr.additions, deletions: pr.deletions }
      : {}),
    // One kind is the totals again: the hover only helps with two or more.
    ...(Object.keys(breakdown).length > 1 ? { breakdown } : {}),
    ...(typeof pr.comments === "number" ? { comments: pr.comments } : {}),
    checks: pr.checks.state,
    ...(failing > 0 ? { failing } : {}),
    // The host's count of those that fail at the base branch's tip too (dimmed on the row).
    ...(failing > 0 && (pr.checks.failingOnBase ?? 0) > 0 ? { failingOnBase: pr.checks.failingOnBase } : {}),
    ...(pr.state ? { since: seenSince(pr.url, pr.state, now) } : {}),
  };
}

export type ChangesStatuses = {
  readonly statuses: Readonly<Record<string, InspectorPullRequestStatus>>;
  /// The host is reading one of them now: the page asks again shortly.
  readonly reading: boolean;
};

const EMPTY: ChangesStatuses = { statuses: {}, reading: false };
/// The last statuses built, so an unchanged list keeps the object React has.
let cache: { key: string; answers: readonly (PullRequestAnswer | undefined)[]; value: ChangesStatuses } = {
  key: "",
  answers: [],
  value: EMPTY,
};

function statusesOf(key: string): ChangesStatuses {
  if (!key) return EMPTY;
  const urls = key.split("\n");
  const answers = urls.map(pullRequestAnswer);
  if (key === cache.key && answers.every((answer, index) => answer === cache.answers[index])) return cache.value;
  const statuses: Record<string, InspectorPullRequestStatus> = {};
  urls.forEach((url, index) => {
    const status = changesStatus(answers[index]);
    if (status) statuses[url] = status;
  });
  cache = { key, answers, value: { statuses, reading: answers.some((answer) => answer?.reading === true) } };
  return cache.value;
}

/// What the App's cache has for `urls`, refreshed while `open` when the list or `tick` (the
/// transcript) changes.
export function useChangesStatuses(urls: readonly string[], open: boolean, tick: unknown): ChangesStatuses {
  const key = open ? urls.join("\n") : "";
  const read = () => statusesOf(key);
  const { statuses, reading } = useSyncExternalStore(subscribePullRequests, read, read);
  useEffect(() => {
    if (key) refreshChanges(key.split("\n"));
  }, [key, tick]);
  // While the host reads, ask it again: a call to the App, which answers from its cache.
  useEffect(() => {
    if (!key || !reading) return;
    const timer = setInterval(() => {
      for (const url of key.split("\n")) if (pullRequestAnswer(url)?.reading) askPullRequest(url);
    }, WAIT_MS);
    return () => clearInterval(timer);
  }, [key, reading]);
  return { statuses, reading };
}

/// The cache's statuses with the header's live read over them, field by field: what the header
/// leaves out (line counts, the breakdown) the cache keeps.
export function withHeader(
  cached: Readonly<Record<string, InspectorPullRequestStatus>>,
  header: Readonly<Record<string, InspectorPullRequestStatus>>,
): Record<string, InspectorPullRequestStatus> {
  const out: Record<string, InspectorPullRequestStatus> = { ...cached };
  for (const [url, live] of Object.entries(header)) {
    const base: InspectorPullRequestStatus = { ...cached[url] };
    // The header's checks are the live ones: the cache's failing counts are from an older read
    // (before a push), and the header leaves them out when nothing fails.
    if (live.checks !== undefined) {
      delete base.failing;
      delete base.failingOnBase;
    }
    // Its conflict state is live too, and absent when GitHub has not said: a cached one is older.
    if ("mergeable" in live) delete base.mergeable;
    const known = Object.fromEntries(Object.entries(live).filter(([, value]) => value !== undefined));
    out[url] = { ...base, ...known };
  }
  return out;
}

/// Tests start from nothing.
export function resetChangesStatuses(): void {
  registered.clear();
  firstSeen.clear();
  cache = { key: "", answers: [], value: EMPTY };
}
