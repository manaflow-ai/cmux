// The GitHub page's store: a pull request the host already has draws from its first answer; a read
// still running is asked again shortly, and a shown page keeps asking every minute; an answer for a
// pull request the page has left is dropped; Open on GitHub and View diff go to the host's ops.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { mockPullRequest, MOCK_URL } from "./mockProvider";
import { GitHubStore, REFRESH_MS, WAIT_MS } from "./store";
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
  expect(host.calls).toEqual([{ op: GitHubOps.inspect, params: { url: MOCK_URL } }]);
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
  expect(host.calls.length).toBe(1);
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
  expect(host.calls.slice(1)).toEqual([
    { op: GitHubOps.openIn, params: { url: MOCK_URL, browserId: "cmux" } },
    { op: GitHubOps.openDiff, params: { url: MOCK_URL, file: "docs/sidebar.md" } },
  ]);
  host.call = async () => {
    throw pageError("cmux.github.diff_unavailable", "The diff could not be read.");
  };
  await store.openDiff();
  expect(store.getSnapshot().failure).toBe("The diff could not be read.");
});
