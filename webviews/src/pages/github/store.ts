// The GitHub page's state: the routed pull request and the host's answer for it. The host answers
// from its cache at once (AgentReplyPullRequests), so a pull request a chat already showed draws
// in the first frame; while the host reads, the page asks again every WAIT_MS (a call to the app,
// not to GitHub), and while the page is shown it asks every REFRESH_MS so a push, a review or a
// check shows up without a reload. The host reads GitHub at most once a minute per pull request
// whatever the page asks.
import { isPageError, type PageClient } from "../shared/pageClient";
import { GitHubOps, routedPullRequest, type LinkedPullRequest, type PullRequestReply } from "./types";

export const WAIT_MS = 1_500;
export const REFRESH_MS = 60_000;

export interface GitHubSnapshot {
  /** The routed pull request; undefined for a route that names none. */
  target?: { url: string; repo: string; number: number };
  pullRequest?: LinkedPullRequest;
  /** Seconds since 1970 when gh last answered. */
  fetchedAt?: number;
  /** The host is reading the pull request now. */
  reading: boolean;
  /** The host has answered at least once for this target. */
  answered: boolean;
  /** Why the last open (the diff) failed, in the host's words. */
  failure?: string;
}

export class GitHubStore {
  private snapshot: GitHubSnapshot = { reading: false, answered: false };
  private listeners = new Set<() => void>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  /** Bumped by every new target, so an answer for the one before is dropped. */
  private generation = 0;

  constructor(
    private readonly client: PageClient | null,
    private readonly visible: () => boolean = () =>
      typeof document === "undefined" || document.visibilityState === "visible",
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Shows the pull request `hash` routes to; the same one again only asks the host again. */
  route(hash: string): Promise<void> {
    const target = routedPullRequest(hash);
    if (target?.url !== this.snapshot.target?.url) {
      this.generation += 1;
      this.set({ target, reading: false, answered: false });
    }
    return this.ask();
  }

  /** Asks the host for the routed pull request now (coming back to the tab, a timer). */
  async ask(): Promise<void> {
    clearTimeout(this.timer);
    const target = this.snapshot.target;
    if (!target || !this.client) return;
    const generation = this.generation;
    let reply: PullRequestReply | undefined;
    try {
      reply = await this.client.call<PullRequestReply>(GitHubOps.inspect, { url: target.url });
    } catch {
      reply = undefined;
    }
    if (generation !== this.generation) return;
    const pullRequest =
      reply?.pullRequest && typeof reply.pullRequest.number === "number" ? reply.pullRequest : undefined;
    this.set({
      ...this.snapshot,
      // The host never sends a worse answer than it had; keep ours when it sends none.
      pullRequest: pullRequest ?? this.snapshot.pullRequest,
      fetchedAt: typeof reply?.fetchedAt === "number" ? reply.fetchedAt : this.snapshot.fetchedAt,
      reading: reply?.reading === true,
      answered: this.snapshot.answered || reply !== undefined,
    });
    // Reading: ask again shortly for its answer. Otherwise a minute on, which keeps a shown page live.
    this.schedule(reply?.reading === true ? WAIT_MS : REFRESH_MS);
  }

  /** Opens the web page (Open on GitHub), or another https page of it (a check's run). */
  openOnGitHub(url = this.snapshot.target?.url): void {
    if (url && this.client) void this.client.call(GitHubOps.openIn, { url, browserId: "cmux" }).catch(() => undefined);
  }

  /** Opens the diff in the diff viewer, at `file` when given. */
  async openDiff(file?: string): Promise<void> {
    const target = this.snapshot.target;
    if (!target || !this.client) return;
    if (this.snapshot.failure) this.set({ ...this.snapshot, failure: undefined });
    try {
      await this.client.call(GitHubOps.openDiff, file ? { url: target.url, file } : { url: target.url });
    } catch (error) {
      // A click the host did not count (no gesture) says nothing; a failed read says why.
      if (isPageError(error) && error.code !== "cmux.github.gesture_required")
        this.set({ ...this.snapshot, failure: error.message });
    }
  }

  /** Tells the host what the page drew for the routed pull request (its bench mark of the open). */
  shown(): void {
    const { target, pullRequest } = this.snapshot;
    if (target && this.client)
      void this.client
        .call(GitHubOps.shown, { url: target.url, content: pullRequest !== undefined })
        .catch(() => undefined);
  }

  stop(): void {
    clearTimeout(this.timer);
    this.generation += 1;
  }

  private schedule(ms: number) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      // A hidden page asks nothing; showing it again asks at once (main.tsx).
      if (this.visible()) void this.ask();
    }, ms);
  }

  private set(next: GitHubSnapshot) {
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
}
