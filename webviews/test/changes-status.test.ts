// l10n-allow-file: test fixture pull requests, not shipped UI.
// Session Info's Changes reads every pull request's title, state, conflicts, line counts and
// checks from the App's one pull request cache (AgentReplyPullRequests), never from GitHub per
// row: it registers the list with the host up to sixty-four links to a `link.inspect` (one batched GraphQL
// read on the host), at most once a minute per link, then asks `pr.inspect` for each answer.
import { afterEach, expect, jest, setSystemTime, test } from "bun:test";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetPullRequestStore, type LinkedPullRequest } from "../src/agent-session/acpmux/chips/pullRequestStore";
import {
  REGISTER_BATCH,
  REGISTER_EVERY_MS,
  changesStatus,
  keepChangesFresh,
  refreshChanges,
  resetChangesStatuses,
  stableUrls,
  withHeader,
} from "../src/agent-session/acpmux/session-info/changesStatus";
import { rowState } from "../src/agent-session/acpmux/session-info/ChangesSection";
import { pageClocks } from "../src/ui/pageClock";

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
  const status = changesStatus({
    pullRequest: linked({
      state: "draft",
      mergeable: "conflicting",
      additions: 758,
      deletions: 265,
      files: [
        { path: "webviews/src/agent-session/acpmux/session-info/ChangesSection.tsx", additions: 700, deletions: 260 },
        { path: "webviews/test/session-info-changes.test.tsx", additions: 58, deletions: 5 },
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
    readFrom: 1_699_999_990,
    reading: false,
  });
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
    // When the host's read began (readFrom), not when it finished.
    since: 1_699_999_990_000,
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

test("a row's state counts from when the host's read began, so only a read that began after the chat's close reopens it", () => {
  const url = "https://github.com/acme/a/pull/13";
  const closed = { url, repo: "acme/a", number: 13, state: "closed" as const, closedAt: 2_000_000, opened: true };
  const open = (readFrom: number | undefined, fetchedAt: number) =>
    changesStatus({
      pullRequest: linked({ url, number: 13, state: "open" }),
      fetchedAt,
      ...(readFrom === undefined ? {} : { readFrom }),
      reading: false,
    })!;
  // The page saw it open long before the chat closed it at 2_000 s.
  expect(rowState(closed, open(1_000, 1_001))).toBe("closed");
  // A batched read that began at 1_990 s, before the close, and finished at 2_100 s (a queued
  // batch can take longer than any fixed allowance) still says open: the close stands.
  expect(rowState(closed, open(1_990, 2_100))).toBe("closed");
  // Someone reopened it after the close; a read that began at 2_005 s says open: it shows open,
  // although the page first saw it open before the close.
  expect(rowState(closed, open(2_005, 2_006))).toBe("open");
  // A host that does not say when its read began: the chat's close stands.
  expect(open(undefined, 2_500).since).toBeUndefined();
  expect(rowState(closed, open(undefined, 2_500))).toBe("closed");
});

test("every pr.inspect the list sends is cache-only: the host never starts a GitHub read for one row", async () => {
  const asks: Record<string, unknown>[] = [];
  setChipHost(async (method, params) => {
    if (method === "pr.inspect") asks.push(params);
    return method === "pr.inspect" ? { pullRequest: null, reading: true } : {};
  });
  const urls = ["https://github.com/acme/a/pull/1", "https://github.com/acme/a/pull/2"];
  refreshChanges(urls, 1_000);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  // Registered lately (within the minute) with no answer here yet: asked from the cache too.
  resetPullRequestStore();
  refreshChanges(urls, 2_000);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(asks).toHaveLength(4);
  expect(asks.every((params) => params.cached === true)).toBe(true);
});

test("a hidden page registers and asks nothing", async () => {
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    return method === "pr.inspect" ? { pullRequest: null, reading: false } : {};
  });
  const had = Object.getOwnPropertyDescriptor(globalThis, "document");
  Object.defineProperty(globalThis, "document", { value: { visibilityState: "hidden" }, configurable: true });
  try {
    refreshChanges(["https://github.com/acme/a/pull/1"], 1_000);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls).toEqual([]);
  } finally {
    if (had) Object.defineProperty(globalThis, "document", had);
    else delete (globalThis as { document?: unknown }).document;
  }
  // Shown again: the same call registers it.
  refreshChanges(["https://github.com/acme/a/pull/1"], 1_000);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls).toEqual(["link.inspect", "pr.inspect"]);
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

test("freshness releases its hidden timer and showing the page does not refresh", async () => {
  jest.useFakeTimers();
  setSystemTime(new Date(1_000_000));
  const original = Object.getOwnPropertyDescriptor(globalThis, "document");
  const doc = new EventTarget() as Document;
  const visibility = (value: DocumentVisibilityState) => {
    Object.defineProperty(doc, "visibilityState", { configurable: true, value });
    doc.dispatchEvent(new Event("visibilitychange"));
  };
  visibility("visible");
  Object.defineProperty(globalThis, "document", { configurable: true, value: doc });
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    return method === "pr.inspect" ? { pullRequest: null, reading: false } : {};
  });
  const stop = keepChangesFresh(["https://github.com/acme/a/pull/1"]);
  try {
    expect(pageClocks(doc).running).toBe(1);
    visibility("hidden");
    expect(pageClocks(doc).running).toBe(0);
    jest.advanceTimersByTime(2 * REGISTER_EVERY_MS);
    expect(calls).toEqual([]);
    visibility("visible");
    expect(pageClocks(doc).running).toBe(1);
    await Promise.resolve();
    expect(calls).toEqual([]);
    jest.advanceTimersByTime(REGISTER_EVERY_MS - 1);
    expect(calls).toEqual([]);
    jest.advanceTimersByTime(1);
    await new Promise((resolve) => setImmediate(resolve));
    expect(calls).toEqual(["link.inspect", "pr.inspect"]);
    stop();
    expect(pageClocks(doc).running).toBe(0);
    jest.advanceTimersByTime(REGISTER_EVERY_MS);
    expect(calls).toEqual(["link.inspect", "pr.inspect"]);
  } finally {
    stop();
    if (original) Object.defineProperty(globalThis, "document", original);
    else delete (globalThis as { document?: unknown }).document;
  }
});

test("a transcript update that names the same pull requests keeps the list the page registered, with no new array", () => {
  const pr = (number: number) => ({ url: `https://github.com/acme/a/pull/${number}` });
  const first = stableUrls(undefined, [pr(1), pr(2)]);
  expect(first).toEqual(["https://github.com/acme/a/pull/1", "https://github.com/acme/a/pull/2"]);
  // A streamed reply rebuilds the summary: new objects, the same pull requests in the same order.
  expect(stableUrls(first, [pr(1), pr(2)])).toBe(first);
  // A new one, or a new order, is a new list.
  const grown = stableUrls(first, [pr(1), pr(2), pr(3)]);
  expect(grown).not.toBe(first);
  expect(grown).toHaveLength(3);
  expect(stableUrls(grown, [pr(2), pr(1), pr(3)])).not.toBe(grown);
  // None: one shared empty list.
  expect(stableUrls(undefined, undefined)).toBe(stableUrls(first, []));
});
