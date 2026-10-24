// l10n-allow-file: test fixture pull requests, not shipped UI.
// The Inspector's Changes reads every pull request's title, state, conflicts, line counts and
// checks from the App's one pull request cache (AgentReplyPullRequests), never from GitHub per
// row: it registers the list with the host up to sixty-four links to a `link.inspect` (one batched GraphQL
// read on the host), at most once a minute per link, then asks `pr.inspect` for each answer.
import { afterEach, expect, jest, setSystemTime, test } from "bun:test";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetPullRequestStore, type LinkedPullRequest } from "../src/agent-session/acpmux/chips/pullRequestStore";
import {
  READ_SLACK_MS,
  REGISTER_BATCH,
  REGISTER_EVERY_MS,
  changesStatus,
  keepChangesFresh,
  refreshChanges,
  resetChangesStatuses,
  withHeader,
} from "../src/agent-session/acpmux/inspector/changesStatus";
import { rowState } from "../src/agent-session/acpmux/inspector/ChangesSection";

afterEach(() => {
  jest.useRealTimers();
  setSystemTime();
  setChipHost(undefined);
  resetPullRequestStore();
  resetChangesStatuses();
});

const linked = (fields: Partial<LinkedPullRequest>): LinkedPullRequest => ({
  url: "https://github.com/manaflow-ai/cmux/pull/22033",
  number: 22033,
  title: "cmux-next: backgrounds batch",
  state: "open",
  review: "",
  mergeable: "",
  checks: { state: "failing", passed: 3, total: 14 },
  checkList: [],
  ...fields,
});

test("an answer becomes the row's title, state, conflicts, lines by kind and failing checks", () => {
  const status = changesStatus(
    {
      pullRequest: linked({
        state: "draft",
        mergeable: "conflicting",
        additions: 758,
        deletions: 265,
        files: [
          { path: "webviews/src/agent-session/acpmux/inspector/ChangesSection.tsx", additions: 700, deletions: 260 },
          { path: "webviews/test/chat-inspector-changes.test.tsx", additions: 58, deletions: 5 },
        ],
        comments: 13,
        checks: { state: "failing", passed: 1, total: 3, failingOnBase: 1 },
        checkList: [
          { name: "lint", state: "failed", onBase: true },
          { name: "test", state: "failed" },
          { name: "build", state: "passed" },
        ],
      }),
      fetchedAt: 1_700_000_000,
      reading: false,
    },
    5_000,
  );
  expect(status).toEqual({
    title: "cmux-next: backgrounds batch",
    state: "draft",
    mergeable: "conflicting",
    additions: 758,
    deletions: 265,
    breakdown: { code: { additions: 700, deletions: 260 }, tests: { additions: 58, deletions: 5 } },
    comments: 13,
    checks: "failing",
    failing: 2,
    failingOnBase: 1,
    // When the page first saw it in this state, not when the host's read finished.
    since: 5_000,
  });
  // Green: no failing count; the row draws its dot from `checks`.
  expect(
    changesStatus({ pullRequest: linked({ checks: { state: "passing", passed: 3, total: 3 } }), reading: false }),
  ).toMatchObject({ checks: "passing" });
  expect(changesStatus({ pullRequest: linked({}), reading: false })?.failing).toBeUndefined();
  // No answer yet, or GitHub says there is no such pull request (an issue's #N): nothing.
  expect(changesStatus(undefined)).toBeUndefined();
  expect(changesStatus({ pullRequest: null, reading: false })).toBeUndefined();
});

test("the list registers with the host REGISTER_BATCH links a call, once a minute, then asks for each answer", async () => {
  const calls: { method: string; urls?: string[]; url?: string }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, urls: params.urls as string[] | undefined, url: params.url as string | undefined });
    return method === "pr.inspect" ? { pullRequest: null, reading: false } : {};
  });
  const urls = Array.from({ length: REGISTER_BATCH + 4 }, (_, index) => `https://github.com/acme/a/pull/${index + 1}`);
  refreshChanges(urls, 1_000);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  const registers = calls.filter((call) => call.method === "link.inspect").map((call) => call.urls!.length);
  expect(registers).toEqual([REGISTER_BATCH, 4]);
  expect(new Set(calls.filter((call) => call.method === "pr.inspect").map((call) => call.url)).size).toBe(
    REGISTER_BATCH + 4,
  );
  // Within the minute: no new registration, only the local asks.
  calls.length = 0;
  refreshChanges(urls, 1_000 + REGISTER_EVERY_MS - 1);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls.filter((call) => call.method === "link.inspect")).toHaveLength(0);
  // After it: registered again, still batched.
  refreshChanges(urls, 1_000 + REGISTER_EVERY_MS);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls.filter((call) => call.method === "link.inspect").map((call) => call.urls!.length)).toEqual([
    REGISTER_BATCH,
    4,
  ]);
});

test("the header's live read of the folder's pull request wins field by field; the cache keeps the rest", () => {
  const url = "https://github.com/acme/a/pull/12";
  const merged = withHeader(
    { [url]: { title: "Cached title", state: "open", additions: 10, deletions: 2, checks: "pending" } },
    { [url]: { title: undefined, state: "merged", checks: "passing" } },
  );
  expect(merged[url]).toEqual({
    title: "Cached title",
    state: "merged",
    additions: 10,
    deletions: 2,
    checks: "passing",
  });
  // The header's checks are live: an older cached failing count (before a push) and a cached
  // conflict give way, even though the header leaves out a zero count and an unknown mergeable.
  const live = withHeader(
    {
      [url]: { checks: "failing", failing: 2, failingOnBase: 1, mergeable: "conflicting", additions: 4, deletions: 1 },
    },
    { [url]: { checks: "pending", mergeable: undefined } },
  );
  expect(live[url]).toEqual({ checks: "pending", additions: 4, deletions: 1 });
});

test("a row's state counts from when the page first saw it, so a read that answers after the chat's close cannot reopen it", () => {
  const url = "https://github.com/acme/a/pull/13";
  const open = { pullRequest: linked({ url, number: 13, state: "open" }), fetchedAt: 9_999, reading: false };
  // First seen open at 1000; the chat closes it at 2000; a read that started before the close
  // answers at 3000 (fetchedAt after the close), still open.
  expect(changesStatus(open, 1_000)?.since).toBe(1_000);
  const late = changesStatus(open, 3_000)!;
  expect(late.since).toBe(1_000);
  const closed = { url, repo: "acme/a", number: 13, state: "closed" as const, closedAt: 2_000, opened: true };
  expect(rowState(closed, late)).toBe("closed");
  // A later read that says closed, then a real reopen after the close, show as they are.
  expect(changesStatus({ ...open, pullRequest: linked({ url, number: 13, state: "closed" }) }, 4_000)?.since).toBe(
    4_000,
  );
  const reopened = changesStatus(open, 5_000)!;
  expect(reopened.since).toBe(5_000);
  expect(rowState(closed, reopened)).toBe("open");
});

test("a cached open answer read before the chat's close, first seen after it, cannot reopen the row", () => {
  const url = "https://github.com/acme/a/pull/14";
  const closed = { url, repo: "acme/a", number: 14, state: "closed" as const, closedAt: 2_000_000, opened: true };
  // The App read it open at 1_990 s; the chat closed it at 2_000 s while the list was closed; the
  // list opens at 2_010 s and sees that cached answer for the first time.
  const stale = changesStatus(
    { pullRequest: linked({ url, number: 14, state: "open" }), fetchedAt: 1_990, reading: false },
    2_010_000,
  )!;
  expect(stale.since).toBe(1_990_000 - READ_SLACK_MS);
  expect(rowState(closed, stale)).toBe("closed");
  // A read that finished more than READ_SLACK_MS after the close started after it: a real reopen.
  const fresh = changesStatus(
    {
      pullRequest: linked({ url, number: 14, state: "open" }),
      fetchedAt: 2_000 + READ_SLACK_MS / 1_000 + 5,
      reading: false,
    },
    2_070_000,
  )!;
  expect(fresh.since).toBe(2_005_000);
  expect(rowState(closed, fresh)).toBe("open");
});

test("an open list registers again each minute while the chat is quiet, and stops when it closes", async () => {
  jest.useFakeTimers();
  setSystemTime(new Date(1_000_000));
  const registers: string[][] = [];
  setChipHost(async (method, params) => {
    if (method === "link.inspect") registers.push(params.urls as string[]);
    return method === "pr.inspect" ? { pullRequest: null, reading: false } : {};
  });
  const urls = ["https://github.com/acme/a/pull/1", "https://github.com/acme/a/pull/2"];
  refreshChanges(urls);
  await Promise.resolve();
  expect(registers).toEqual([urls]);
  const stop = keepChangesFresh(urls);
  setSystemTime(new Date(1_000_000 + REGISTER_EVERY_MS));
  jest.advanceTimersByTime(REGISTER_EVERY_MS);
  await Promise.resolve();
  expect(registers).toEqual([urls, urls]);
  // Closed: no timer is left to register them again.
  stop();
  setSystemTime(new Date(1_000_000 + 3 * REGISTER_EVERY_MS));
  jest.advanceTimersByTime(2 * REGISTER_EVERY_MS);
  await Promise.resolve();
  expect(registers).toEqual([urls, urls]);
});
