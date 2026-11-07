// The GitHub page's state: the routed pull request and the host's answer for it. The host answers
// from its cache at once (AgentReplyPullRequests), so a pull request a chat already showed draws
// in the first frame; while the host reads, the page asks again every WAIT_MS (a call to the app,
// not to GitHub), and while the page is shown it asks every REFRESH_MS so a push, a review or a
// check shows up without a reload. The host reads GitHub at most once a minute per pull request
// whatever the page asks.
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  GitHubOps,
  routedPullRequest,
  type DashboardChecks,
  type FilePatch,
  type LinkedPullRequest,
  type MergeState,
  type PullRequestDetails,
  type PullRequestReply,
  type RerunState,
} from "./types";
import { failedRuns } from "./checksModel";

export const WAIT_MS = 1_500;
export const REFRESH_MS = 60_000;
/** How often a shown page asks the host for its checks while a job runs or waits. The host reads
 * GitHub at its own pace for the state (GitHubChecksCache: 20 s running, 5 min settled), so this is
 * a call to the app; once every job is done the page asks only with its minute refresh. */
export const CHECKS_MS = 10_000;

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
  /** The body, conversation and reviewers (`pr.details`), once the host has read them. */
  details?: PullRequestDetails;
  /** The `updatedAt` the details were asked for: a newer one asks again. */
  detailsFor?: string;
  /** Files expanded inline, by path, with their patch as far as it has come. */
  patches: Readonly<Record<string, FilePatch>>;
  merge: MergeState;
  /** The CI dashboard's jobs (`checks.read`), once the host has them. */
  checks?: DashboardChecks;
  rerun: RerunState;
}

const EMPTY = {
  patches: {},
  merge: { phase: "idle" },
  rerun: { phase: "idle" },
} as const satisfies Partial<GitHubSnapshot>;

export class GitHubStore {
  private snapshot: GitHubSnapshot = { reading: false, answered: false, ...EMPTY };
  private listeners = new Set<() => void>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  /** The checks' own timer, armed only while a job runs or waits and the page is shown. */
  private checksTimer: ReturnType<typeof setTimeout> | undefined;
  /** The generation whose checks ask is in flight: a new pull request's ask never waits on the old one's. */
  private checksAsking: number | undefined;
  /** The newest patch ask per file. */
  private patchAsks = new Map<string, number>();
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
      clearTimeout(this.checksTimer);
      this.set({ target, reading: false, answered: false, ...EMPTY });
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
    // A new `updatedAt` (a push, a comment, a review): its details again, and its files' diffs from the new head.
    void this.loadChecks();
    const updatedAt = this.snapshot.pullRequest?.updatedAt;
    if (this.snapshot.pullRequest && updatedAt !== this.snapshot.detailsFor) void this.loadDetails(updatedAt ?? "");
  }

  /** Asks the host for the dashboard's checks at the shown head; while a job runs or waits, or the
   * host is still reading, again in CHECKS_MS. */
  async loadChecks(): Promise<void> {
    clearTimeout(this.checksTimer);
    const target = this.snapshot.target;
    const generation = this.generation;
    if (!target || !this.client || this.checksAsking === generation) return;
    const asked = this.snapshot.details?.headCommit;
    this.checksAsking = generation;
    let reply: { checks?: DashboardChecks | null; reading?: boolean } | undefined;
    try {
      reply = await this.client.call(GitHubOps.checks, { url: target.url, ...(asked ? { head: asked } : {}) });
    } catch {
      reply = undefined;
    } finally {
      if (this.checksAsking === generation) this.checksAsking = undefined;
    }
    if (generation !== this.generation) return;
    const answered = reply?.checks && Array.isArray(reply.checks.jobs) ? reply.checks : undefined;
    // Another head's checks (the page has seen a push since) are never drawn; asked again shortly.
    const head = this.snapshot.details?.headCommit;
    const stale = answered !== undefined && !!head && !!answered.head && answered.head !== head;
    const checks = stale ? undefined : answered;
    if (checks) this.set({ ...this.snapshot, checks });
    // Stops by itself: a settled pull request the host is not reading, a failed ask or a hidden page
    // arms nothing more; the minute refresh (ask) and showing the page again start it.
    const live = reply?.reading === true || stale || (checks !== undefined && !checks.settled);
    if (!live) return;
    this.checksTimer = setTimeout(() => {
      if (this.visible()) void this.loadChecks();
    }, CHECKS_MS);
  }

  /** Re-runs the failed jobs of every run the dashboard shows failing, through the host. */
  async rerunFailed(): Promise<void> {
    const { target, checks, rerun } = this.snapshot;
    const runs = checks ? failedRuns(checks.jobs) : [];
    if (!target || !this.client || runs.length === 0 || rerun.phase === "running") return;
    const generation = this.generation;
    this.set({ ...this.snapshot, rerun: { phase: "running" } });
    let next: RerunState;
    try {
      await this.client.call(GitHubOps.rerun, { url: target.url, runs });
      next = { phase: "started" };
    } catch (error) {
      next =
        isPageError(error) && error.code === "cmux.github.gesture_required"
          ? { phase: "idle" }
          : { phase: "failed", message: isPageError(error) ? error.message : "" };
    }
    if (generation !== this.generation) return;
    this.set({ ...this.snapshot, rerun: next });
    if (next.phase === "started") void this.loadChecks();
  }

  /** Reads the details for `updatedAt`; the host keeps one read per pull request and `updatedAt`. */
  private async loadDetails(updatedAt: string): Promise<void> {
    const target = this.snapshot.target;
    if (!target || !this.client) return;
    const generation = this.generation;
    const fresh = this.snapshot.detailsFor !== undefined;
    this.set({ ...this.snapshot, detailsFor: updatedAt, ...(fresh ? { patches: this.reloadPatches() } : {}) });
    let details: PullRequestDetails | undefined;
    try {
      const reply = await this.client.call<{ details?: PullRequestDetails | null }>(GitHubOps.details, {
        url: target.url,
      });
      details = reply?.details && typeof reply.details.body === "string" ? reply.details : undefined;
    } catch {
      details = undefined;
    }
    if (generation !== this.generation) return;
    // A failed read keeps what the page had and asks again with the next answer.
    if (!details) {
      this.set({ ...this.snapshot, detailsFor: undefined });
      return;
    }
    // A new head (a push): the old head's checks go, and the new head's are asked for.
    const { checks: shown, ...rest } = this.snapshot;
    const moved = !!shown?.head && !!details.headCommit && shown.head !== details.headCommit;
    this.set(moved ? { ...rest, details } : { ...this.snapshot, details });
    if (moved) void this.loadChecks();
  }

  /** The open files read again from the new head; closed ones are forgotten. */
  private reloadPatches(): Record<string, FilePatch> {
    const open = Object.keys(this.snapshot.patches);
    queueMicrotask(() => open.forEach((file) => void this.loadPatch(file, true)));
    return Object.fromEntries(open.map((file) => [file, { state: "loading" } as const]));
  }

  /** Expands `file` in place, or folds it when it is open. */
  toggleFile(file: string): void {
    if (this.snapshot.patches[file]) {
      const { [file]: _, ...rest } = this.snapshot.patches;
      this.set({ ...this.snapshot, patches: rest });
      return;
    }
    void this.loadPatch(file);
  }

  private async loadPatch(file: string, again = false): Promise<void> {
    const target = this.snapshot.target;
    if (!target || !this.client) return;
    if (!again && this.snapshot.patches[file]) return;
    const generation = this.generation;
    // Only the newest ask for a file lands: a reload after a push outruns the older head's answer.
    const ask = (this.patchAsks.get(file) ?? 0) + 1;
    this.patchAsks.set(file, ask);
    this.setPatch(file, { state: "loading" });
    let next: FilePatch;
    try {
      const reply = await this.client.call<{ patch?: string | null; tooLarge?: boolean }>(GitHubOps.diffFile, {
        url: target.url,
        file,
      });
      next =
        typeof reply?.patch === "string"
          ? { state: "ready", patch: reply.patch }
          : reply?.tooLarge
            ? { state: "tooLarge" }
            : { state: "missing" };
    } catch (error) {
      next = { state: "failed", message: isPageError(error) ? error.message : "" };
    }
    // Dropped when the page left the pull request, or the person folded the file meanwhile.
    if (generation !== this.generation || !this.snapshot.patches[file] || this.patchAsks.get(file) !== ask) return;
    this.setPatch(file, next);
  }

  private setPatch(file: string, patch: FilePatch) {
    this.set({ ...this.snapshot, patches: { ...this.snapshot.patches, [file]: patch } });
  }

  /**
   * Merge: the first click asks to confirm (it names the method), the second merges through the
   * host, pinned to the head commit the page shows. GitHub's rules still decide.
   */
  async merge(): Promise<void> {
    const { target, details, merge } = this.snapshot;
    if (!target || !this.client || !details?.headCommit) return;
    if (merge.phase === "idle" || merge.phase === "failed") {
      this.set({ ...this.snapshot, merge: { phase: "confirm" } });
      return;
    }
    if (merge.phase !== "confirm") return;
    const generation = this.generation;
    this.set({ ...this.snapshot, merge: { phase: "merging" } });
    let next: MergeState;
    try {
      const reply = await this.client.call<{ merged?: boolean; queued?: boolean }>(GitHubOps.merge, {
        url: target.url,
        head: details.headCommit,
      });
      next = reply?.merged ? { phase: "merged", queued: reply.queued === true } : { phase: "idle" };
    } catch (error) {
      // A click the host did not count asks for another, not a failure.
      next =
        isPageError(error) && error.code === "cmux.github.gesture_required"
          ? { phase: "confirm" }
          : { phase: "failed", message: isPageError(error) ? error.message : "" };
    }
    if (generation !== this.generation) return;
    this.set({ ...this.snapshot, merge: next });
  }

  /** Steps back from the confirm. */
  cancelMerge(): void {
    if (this.snapshot.merge.phase === "confirm") this.set({ ...this.snapshot, merge: { phase: "idle" } });
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
    const generation = this.generation;
    try {
      await this.client.call(GitHubOps.openDiff, file ? { url: target.url, file } : { url: target.url });
    } catch (error) {
      // A click the host did not count (no gesture) says nothing; a failed read says why, on its own pull request only.
      if (generation === this.generation && isPageError(error) && error.code !== "cmux.github.gesture_required")
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
    clearTimeout(this.checksTimer);
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
