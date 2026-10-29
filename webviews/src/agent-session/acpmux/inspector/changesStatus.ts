// What the App has read of each pull request in the Inspector's Changes: its title, state (a
// draft included), whether it conflicts, its lines by kind of file, its comments and its failing checks. It all
// comes from the App's one pull request cache (AgentReplyPullRequests, the one the reply links'
// hover cards read): never a GitHub call per row, and no polling of GitHub.
//
// When the list opens or names new pull requests, the page registers them with the host
// (`link.inspect`, sixty-four to a call, the host's bound per request), which reads every stale one
// in one batched GraphQL query and never the same link twice in a minute; then it asks the host
// for each answer (`pr.inspect` with `cached`), a local call that answers from the cache and never
// starts a GitHub read, so no row ever costs a read of its own. While the host says a read is
// running, the page asks it again every WAIT_MS (a call to the App). Each minute the list stays
// open and shown it registers again, so a row the chat no longer touches still follows a merge, a
// push or a new comment: one batched read per minute for the links gone stale. A transcript
// update that names no new pull request does nothing here. Nothing registers or asks while
// Changes is folded, the Inspector is closed or the page is hidden; the timers stop when it folds,
// closes or unmounts, and a page shown again waits for the next minute. The header's pull request (the chat folder's, which the App reads live) wins over
// the cache.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { kindTotals } from "../../../fileKinds";
import { callChipHost } from "../chips/host";
import {
  askPullRequest,
  pullRequestAnswer,
  pullRequestsVersion,
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

const hidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";

/// Registers the links not registered in the last minute, REGISTER_BATCH to a call, then asks the host
/// for each one's answer from its cache. Nothing while the page is hidden.
export function refreshChanges(urls: readonly string[], now = Date.now()): void {
  if (hidden()) return;
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
export function changesStatus(answer: PullRequestAnswer | undefined): InspectorPullRequestStatus | undefined {
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
    // What the answer says was true when its read began (the host's `readFrom`): a row the chat
    // closed reopens only for a read that began after the close, however long its batch took.
    ...(pr.state && typeof answer.readFrom === "number" ? { since: answer.readFrom * 1_000 } : {}),
  };
}

export type ChangesStatuses = {
  readonly statuses: Readonly<Record<string, InspectorPullRequestStatus>>;
  /// The host is reading one of them now: the page asks again shortly.
  readonly reading: boolean;
  /// One of them has no settled answer yet (none asked for, or the host still reading): a named
  /// pull request may still turn out to be one, so Changes keeps its header.
  readonly unsettled: boolean;
};

const EMPTY: ChangesStatuses = { statuses: {}, reading: false, unsettled: false };
const NO_URLS: readonly string[] = [];

/// The URLs of `pullRequests`, as `held` when they are the same ones in the same order, so a
/// transcript update that names no new pull request keeps the list (and everything keyed on it)
/// and allocates nothing.
export function stableUrls(
  held: readonly string[] | undefined,
  pullRequests: readonly { readonly url: string }[] | undefined,
): readonly string[] {
  const list = pullRequests ?? [];
  if (!list.length) return NO_URLS;
  if (held && held.length === list.length && list.every((pr, index) => pr.url === held[index])) return held;
  return list.map((pr) => pr.url);
}

/// `pullRequests`' URLs, the same array while they name the same pull requests (``stableUrls``).
export function useStableUrls(pullRequests: readonly { readonly url: string }[] | undefined): readonly string[] {
  const [held, setHeld] = useState(NO_URLS);
  const urls = stableUrls(held, pullRequests);
  // Derived state: a new list replaces the held one in this render, before any effect reads it.
  if (urls !== held) setHeld(urls);
  return urls;
}
/// The last statuses built, so an unchanged list keeps the object React has, and a render is no
/// pass over the list until the list or one of the store's answers changes.
let cache: {
  key: string;
  version: number;
  answers: readonly (PullRequestAnswer | undefined)[];
  value: ChangesStatuses;
} = { key: "", version: -1, answers: [], value: EMPTY };

function statusesOf(key: string): ChangesStatuses {
  if (!key) return EMPTY;
  const version = pullRequestsVersion();
  if (key === cache.key && version === cache.version) return cache.value;
  const urls = key.split("\n");
  const answers = urls.map(pullRequestAnswer);
  if (key === cache.key && answers.every((answer, index) => answer === cache.answers[index])) {
    cache = { ...cache, version };
    return cache.value;
  }
  const statuses: Record<string, InspectorPullRequestStatus> = {};
  urls.forEach((url, index) => {
    const status = changesStatus(answers[index]);
    if (status) statuses[url] = status;
  });
  cache = {
    key,
    version,
    answers,
    value: {
      statuses,
      reading: answers.some((answer) => answer?.reading === true),
      unsettled: answers.some((answer) => answer === undefined || answer.reading),
    },
  };
  return cache.value;
}

/// Registers `urls` again every `every` ms while the page is shown, so a row follows its pull
/// request while the chat is quiet. Stops when the returned function runs (the list folded, closed
/// or unmounted); a minute while the page is hidden is skipped, not caught up, and a switch back
/// to the page reads nothing of its own (shared-projections.md): the next minute does.
export function keepChangesFresh(urls: readonly string[], every = REGISTER_EVERY_MS): () => void {
  const timer = setInterval(() => refreshChanges(urls), every);
  return () => clearInterval(timer);
}

/// What the App's cache has for `urls` while `shown` (the Inspector drawn); registered and asked
/// for only while `active` too (Changes unfolded), when the list changes and each minute after.
export function useChangesStatuses(urls: readonly string[], shown: boolean, active: boolean): ChangesStatuses {
  // Joined once per list: `urls` is the same array while the transcript names the same ones.
  const joined = useMemo(() => urls.join("\n"), [urls]);
  const key = shown ? joined : "";
  const live = active ? key : "";
  const read = () => statusesOf(key);
  const value = useSyncExternalStore(subscribePullRequests, read, read);
  const { reading } = value;
  useEffect(() => {
    if (!live) return;
    const list = live.split("\n");
    refreshChanges(list);
    // Each minute while it stays unfolded: the host re-reads the links gone stale, in batches.
    return keepChangesFresh(list);
  }, [live]);
  // While the host reads, ask it again: a call to the App, which answers from its cache.
  useEffect(() => {
    if (!live || !reading) return;
    const timer = setInterval(() => {
      if (hidden()) return;
      for (const url of live.split("\n")) if (pullRequestAnswer(url)?.reading) askPullRequest(url);
    }, WAIT_MS);
    return () => clearInterval(timer);
  }, [live, reading]);
  return value;
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
  cache = { key: "", version: -1, answers: [], value: EMPTY };
}
