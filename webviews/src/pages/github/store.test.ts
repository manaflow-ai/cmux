// The GitHub page's store: a pull request the host already has draws from its first answer; a read
// still running is asked again shortly, and a shown page keeps asking every minute; an answer for a
// pull request the page has left is dropped; Open on GitHub and View diff go to the host's ops.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { mockChecks, mockChecksPassed, mockDetails, mockPullRequest, MOCK_URL } from "./mockProvider";
import { CHECKS_MS, GitHubStore, REFRESH_MS, WAIT_MS } from "./store";
import { GitHubOps, routedPullRequest, type PullRequestReply } from "./types";

const route = (url: string) => `#/pull?url=${encodeURIComponent(url)}`;

class Host implements PageClient {
  calls: { op: string; params: unknown }[] = [];
  replies: (PullRequestReply | Error | (() => Promise<PullRequestReply>))[] = [];
  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (op !== GitHubOps.inspect) return {} as R;
    const next = this.replies.shift() ?? { pullRequest: mockPullRequest, fetchedAt: 1, reading: false };
    if (next instanceof Error) throw next;
    return (typeof next === "function" ? await next() : next) as R;
  }
  async subscribe(): Promise<() => void> {
    return () => {};
  }
  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

/** The calls a test is about: the page's details read rides along with every first answer. */
const asked = (host: Host) =>
  host.calls.filter((call) => call.op !== GitHubOps.details && call.op !== GitHubOps.checks);

const timers: { ms: number; run: () => void }[] = [];
const realSetTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;
beforeEach(() => {
  timers.length = 0;
  globalThis.setTimeout = ((run: () => void, ms: number) => {
    timers.push({ ms, run });
    return timers.length as unknown as ReturnType<typeof setTimeout>;
  }) as typeof setTimeout;
  globalThis.clearTimeout = (() => {}) as typeof clearTimeout;
});
afterEach(() => {
  globalThis.setTimeout = realSetTimeout;
  globalThis.clearTimeout = realClearTimeout;
});

test("a route names one github.com pull request, nothing else", () => {
  expect(routedPullRequest(route(MOCK_URL))).toEqual({ url: MOCK_URL, repo: "example/app", number: 482 });
  expect(routedPullRequest(route("https://github.com/example/app/issues/3"))).toBeUndefined();
  expect(routedPullRequest(route("https://evil.example/example/app/pull/3"))).toBeUndefined();
  expect(routedPullRequest("#/other")).toBeUndefined();
});

test("the cached pull request draws from the first answer, then the page asks again in a minute", async () => {
  const host = new Host();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  expect(store.getSnapshot().pullRequest?.title).toBe(mockPullRequest.title);
  expect(asked(host)).toEqual([{ op: GitHubOps.inspect, params: { url: MOCK_URL } }]);
  expect(timers.at(-1)?.ms).toBe(REFRESH_MS);
});

test("while the host reads, the page asks again shortly until it answers", async () => {
  const host = new Host();
  host.replies.push({ pullRequest: null, reading: true });
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  expect(store.getSnapshot()).toMatchObject({ reading: true, answered: true, pullRequest: undefined });
  expect(timers.at(-1)?.ms).toBe(WAIT_MS);
  timers.at(-1)!.run();
  await Promise.resolve();
  await Promise.resolve();
  expect(store.getSnapshot().pullRequest?.number).toBe(482);
  expect(store.getSnapshot().reading).toBe(false);
});

test("a hidden page asks nothing when its timer fires", async () => {
  const host = new Host();
  const store = new GitHubStore(host, () => false);
  await store.route(route(MOCK_URL));
  timers.at(-1)!.run();
  expect(asked(host).length).toBe(1);
});

test("an answer for the pull request the page has left is dropped", async () => {
  const host = new Host();
  let release: (reply: PullRequestReply) => void = () => {};
  host.replies.push(() => new Promise((resolve) => (release = resolve)));
  const store = new GitHubStore(host, () => true);
  const first = store.route(route(MOCK_URL));
  const other = "https://github.com/example/app/pull/7";
  host.replies.push({ pullRequest: { ...mockPullRequest, url: other, number: 7, title: "Seven" }, fetchedAt: 2 });
  await store.route(route(other));
  release({ pullRequest: mockPullRequest, fetchedAt: 1 });
  await first;
  expect(store.getSnapshot().pullRequest?.title).toBe("Seven");
});

test("a failed read keeps the last good answer", async () => {
  const host = new Host();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  host.replies.push(new Error("offline"));
  await store.ask();
  expect(store.getSnapshot().pullRequest?.title).toBe(mockPullRequest.title);
});

test("Open on GitHub and View diff go to the host; a diff failure says the host's words", async () => {
  const host = new Host();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  store.openOnGitHub();
  await store.openDiff("docs/sidebar.md");
  expect(asked(host).slice(1)).toEqual([
    { op: GitHubOps.openIn, params: { url: MOCK_URL, browserId: "cmux" } },
    { op: GitHubOps.openDiff, params: { url: MOCK_URL, file: "docs/sidebar.md" } },
  ]);
  host.call = async () => {
    throw pageError("cmux.github.diff_unavailable", "The diff could not be read.");
  };
  await store.openDiff();
  expect(store.getSnapshot().failure).toBe("The diff could not be read.");
});

test("a diff failure for the pull request the page has left is dropped", async () => {
  const host = new Host();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  let reject: (error: unknown) => void = () => {};
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> =>
    op === GitHubOps.openDiff ? new Promise<R>((_, fail) => (reject = fail)) : call<R>(op, params);
  const opening = store.openDiff();
  await store.route(route("https://github.com/example/app/pull/7"));
  reject(pageError("cmux.github.diff_unavailable", "The diff could not be read."));
  await opening;
  expect(store.getSnapshot().failure).toBeUndefined();
});

/** A host that answers the page's other reads too, and logs every call. */
class RichHost extends Host {
  detailsReplies: unknown[] = [];
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === GitHubOps.details) {
      this.calls.push({ op, params });
      return (this.detailsReplies.shift() ?? { details: mockDetails }) as R;
    }
    if (op === GitHubOps.diffFile) {
      this.calls.push({ op, params });
      return { patch: `patch of ${(params as { file: string }).file}` } as R;
    }
    if (op === GitHubOps.merge) {
      this.calls.push({ op, params });
      return { merged: true, queued: true } as R;
    }
    return super.call<R>(op, params);
  }
}

const settle = async () => {
  for (let i = 0; i < 4; i += 1) await Promise.resolve();
};

test("the details are asked once per updatedAt, and again when it moves", async () => {
  const host = new RichHost();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  expect(store.getSnapshot().details?.body).toBe(mockDetails.body);
  await store.ask();
  await settle();
  expect(host.calls.filter((call) => call.op === GitHubOps.details).length).toBe(1);
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 2 });
  await store.ask();
  await settle();
  expect(host.calls.filter((call) => call.op === GitHubOps.details).length).toBe(2);
});

test("a file opens inline with its own patch, folds again, and reloads after a push", async () => {
  const host = new RichHost();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  store.toggleFile("docs/sidebar.md");
  expect(store.getSnapshot().patches["docs/sidebar.md"]).toEqual({ state: "loading" });
  await settle();
  expect(store.getSnapshot().patches["docs/sidebar.md"]).toEqual({ state: "ready", patch: "patch of docs/sidebar.md" });
  expect(host.calls.at(-1)).toEqual({ op: GitHubOps.diffFile, params: { url: MOCK_URL, file: "docs/sidebar.md" } });
  // A new updatedAt reads the open file again, from the new head.
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 2 });
  await store.ask();
  await settle();
  expect(host.calls.filter((call) => call.op === GitHubOps.diffFile).length).toBe(2);
  store.toggleFile("docs/sidebar.md");
  expect(store.getSnapshot().patches["docs/sidebar.md"]).toBeUndefined();
});

test("merge asks to confirm first, then merges pinned to the head the page shows", async () => {
  const host = new RichHost();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  await store.merge();
  expect(store.getSnapshot().merge).toEqual({ phase: "confirm" });
  expect(host.calls.some((call) => call.op === GitHubOps.merge)).toBe(false);
  store.cancelMerge();
  expect(store.getSnapshot().merge).toEqual({ phase: "idle" });
  await store.merge();
  await store.merge();
  expect(host.calls.at(-1)).toEqual({ op: GitHubOps.merge, params: { url: MOCK_URL, head: mockDetails.headCommit } });
  expect(store.getSnapshot().merge).toEqual({ phase: "merged", queued: true });
});

test("a merge GitHub refuses says why; a click the host did not count asks for another", async () => {
  const host = new RichHost();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  const call = host.call.bind(host);
  let error = pageError("cmux.github.gesture_required", "Click to merge");
  host.call = <R>(op: string, params: unknown): Promise<R> =>
    op === GitHubOps.merge ? Promise.reject(error) : call<R>(op, params);
  await store.merge();
  await store.merge();
  expect(store.getSnapshot().merge).toEqual({ phase: "confirm" });
  error = pageError("cmux.github.merge_refused", "Pull request is not mergeable");
  await store.merge();
  expect(store.getSnapshot().merge).toEqual({ phase: "failed", message: "Pull request is not mergeable" });
});

test("no merge without the details' head commit", async () => {
  const host = new RichHost();
  host.detailsReplies.push({ details: null });
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  await store.merge();
  expect(store.getSnapshot().merge).toEqual({ phase: "idle" });
});

test("checks are asked while a job runs, then stop once every job is done", async () => {
  const host = new RichHost();
  let settled = false;
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> => {
    if (op !== GitHubOps.checks) return call<R>(op, params);
    host.calls.push({ op, params });
    return Promise.resolve({ checks: settled ? mockChecksPassed : mockChecks, reading: false } as R);
  };
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  expect(store.getSnapshot().checks?.jobs.length).toBe(mockChecks.jobs.length);
  const checksTimer = [...timers].reverse().find((timer) => timer.ms === CHECKS_MS);
  expect(checksTimer).toBeDefined();
  settled = true;
  const before = timers.length;
  checksTimer!.run();
  await settle();
  expect(store.getSnapshot().checks?.settled).toBe(true);
  // Settled: no checks timer armed after this answer.
  expect(timers.slice(before).some((timer) => timer.ms === CHECKS_MS)).toBe(false);
});

test("Re-run failed names the runs with a failed job", async () => {
  const host = new RichHost();
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> => {
    if (op === GitHubOps.checks) return Promise.resolve({ checks: mockChecks } as R);
    if (op === GitHubOps.rerun) {
      host.calls.push({ op, params });
      return Promise.resolve({ rerun: 1 } as R);
    }
    return call<R>(op, params);
  };
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  await store.rerunFailed();
  expect(host.calls.find((each) => each.op === GitHubOps.rerun)?.params).toEqual({ url: MOCK_URL, runs: [9001] });
  expect(store.getSnapshot().rerun).toEqual({ phase: "started" });
});

test("a failed details refresh asks again with the next answer", async () => {
  const host = new RichHost();
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  host.detailsReplies.push({ details: null });
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 2 });
  await store.ask();
  await settle();
  // The old details stay on screen, and the next answer asks for them again.
  expect(store.getSnapshot().details?.body).toBe(mockDetails.body);
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 3 });
  await store.ask();
  await settle();
  expect(host.calls.filter((call) => call.op === GitHubOps.details).length).toBe(3);
});

test("an older head's patch never replaces the newer one's", async () => {
  const host = new RichHost();
  const releases: ((reply: unknown) => void)[] = [];
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> =>
    op === GitHubOps.diffFile
      ? new Promise<R>((resolve) => releases.push(resolve as (reply: unknown) => void))
      : call<R>(op, params);
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  store.toggleFile("docs/sidebar.md");
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 2 });
  await store.ask();
  await settle();
  expect(releases.length).toBe(2);
  releases[1]!({ patch: "new head" });
  await settle();
  releases[0]!({ patch: "old head" });
  await settle();
  expect(store.getSnapshot().patches["docs/sidebar.md"]).toEqual({ state: "ready", patch: "new head" });
});

test("checks keep being asked while the host reads, even with settled checks kept", async () => {
  const host = new RichHost();
  let reading = true;
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> => {
    if (op !== GitHubOps.checks) return call<R>(op, params);
    host.calls.push({ op, params });
    return Promise.resolve({ checks: mockChecksPassed, reading } as R);
  };
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  // Settled checks kept while the host reads again (a re-run just started): the page asks again.
  const checksTimer = [...timers].reverse().find((timer) => timer.ms === CHECKS_MS);
  expect(checksTimer).toBeDefined();
  reading = false;
  const before = timers.length;
  checksTimer!.run();
  await settle();
  expect(timers.slice(before).some((timer) => timer.ms === CHECKS_MS)).toBe(false);
});

test("a new head never shows the old head's checks", async () => {
  const host = new RichHost();
  let answer = mockChecks;
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> => {
    if (op !== GitHubOps.checks) return call<R>(op, params);
    host.calls.push({ op, params });
    return Promise.resolve({ checks: answer, reading: false } as R);
  };
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  expect(store.getSnapshot().checks?.head).toBe(mockChecks.head);
  // A push: the details carry the new head, so the old head's checks go and the new head's are asked for.
  const pushed = "b".repeat(40);
  host.detailsReplies.push({ details: { ...mockDetails, headCommit: pushed } });
  host.replies.push({ pullRequest: { ...mockPullRequest, updatedAt: "2026-11-06T00:00:00Z" }, fetchedAt: 2 });
  await store.ask();
  await settle();
  await settle();
  expect(store.getSnapshot().details?.headCommit).toBe(pushed);
  expect(store.getSnapshot().checks).toBeUndefined();
  const last = host.calls.filter((each) => each.op === GitHubOps.checks).at(-1);
  expect(last?.params).toEqual({ url: MOCK_URL, head: pushed });
  // The host still answers the old head: not drawn, and asked again shortly.
  const before = timers.length;
  await store.loadChecks();
  expect(store.getSnapshot().checks).toBeUndefined();
  expect(timers.slice(before).some((timer) => timer.ms === CHECKS_MS)).toBe(true);
  answer = { ...mockChecks, head: pushed };
  await store.loadChecks();
  expect(store.getSnapshot().checks?.head).toBe(pushed);
});

test("another pull request's checks are asked while the last one's ask is still out", async () => {
  const host = new RichHost();
  const pending: { url: string; resolve: (reply: unknown) => void }[] = [];
  const call = host.call.bind(host);
  host.call = <R>(op: string, params: unknown): Promise<R> => {
    if (op !== GitHubOps.checks) return call<R>(op, params);
    const url = (params as { url: string }).url;
    return new Promise<R>((resolve) => pending.push({ url, resolve: resolve as (reply: unknown) => void }));
  };
  const other = "https://github.com/example/app/pull/483";
  const store = new GitHubStore(host, () => true);
  await store.route(route(MOCK_URL));
  await settle();
  expect(pending.map((ask) => ask.url)).toEqual([MOCK_URL]);
  host.replies.push({ pullRequest: { ...mockPullRequest, number: 483, url: other }, fetchedAt: 2 });
  await store.route(route(other));
  await settle();
  // The new pull request's ask goes out at once, not after the old one's answer.
  expect(pending.map((ask) => ask.url)).toEqual([MOCK_URL, other]);
  pending[0]!.resolve({ checks: mockChecks, reading: false });
  await settle();
  expect(store.getSnapshot().checks).toBeUndefined();
  pending[1]!.resolve({ checks: { ...mockChecks, head: mockChecks.head }, reading: false });
  await settle();
  expect(store.getSnapshot().checks?.jobs.length).toBe(mockChecks.jobs.length);
});
