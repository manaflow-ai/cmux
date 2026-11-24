// The GitHub page's issues view: a repository's issues (`#/issues?repo=<owner/name>`) and one issue
// with its comments (`#/issue?url=<address>`). The host reads each through the GitHub host op
// (`cmux.github.issues.list`, `cmux.github.issue.details`, GitHubPageProvider.swift); the page asks
// once per route, again when the person comes back to the tab, and again every REFRESH_MS while shown.
import type { PageClient } from "../shared/pageClient";
import { userMessage } from "../shared/userMessage";
import { REFRESH_MS } from "./store";
import {
  GitHubOps,
  issueRoute,
  issuesRoute,
  routedIssue,
  routedIssues,
  type GitHubIssue,
  type GitHubIssueComment,
} from "./types";

export type IssuesView = { kind: "list"; repo: string } | { kind: "issue"; repo: string; number: number; url: string };

export interface IssuesSnapshot {
  /** What the route names; undefined when it names no issue view (the pull request page draws). */
  view?: IssuesView;
  /** The list, once the host answered. */
  issues?: GitHubIssue[];
  /** The issue and its comments, once the host answered. */
  issue?: GitHubIssue;
  comments?: GitHubIssueComment[];
  /** An ask is in flight and nothing is drawn yet. */
  loading: boolean;
  /** Why the last read failed, in the host's words. */
  failure?: string;
}

export class IssuesStore {
  private snapshot: IssuesSnapshot = { loading: false };
  private listeners = new Set<() => void>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  /** Bumped by every new view, so an answer for the one before is dropped. */
  private generation = 0;

  constructor(
    private readonly client: PageClient | null,
    /** Moves the page to another route (main.tsx sets `location.hash`; the gallery routes in place). */
    private readonly navigate: (hash: string) => void = (hash) => {
      location.hash = hash;
    },
    private readonly visible: () => boolean = () =>
      typeof document === "undefined" || document.visibilityState === "visible",
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Shows the issue view `hash` routes to; the same one again only asks the host again. */
  route(hash: string): Promise<void> {
    const issue = routedIssue(hash);
    const list = routedIssues(hash);
    const view: IssuesView | undefined = issue
      ? { kind: "issue", ...issue }
      : list
        ? { kind: "list", repo: list.repo }
        : undefined;
    if (key(view) !== key(this.snapshot.view)) {
      this.generation += 1;
      clearTimeout(this.timer);
      this.set({ view, loading: view !== undefined });
    }
    return this.ask();
  }

  /** Asks the host for the routed view now (coming back to the tab, a timer). */
  async ask(): Promise<void> {
    clearTimeout(this.timer);
    const view = this.snapshot.view;
    if (!view || !this.client) return;
    const generation = this.generation;
    try {
      if (view.kind === "list") {
        const reply = await this.client.call<{ issues?: GitHubIssue[] | null }>(GitHubOps.issues, { repo: view.repo });
        if (generation !== this.generation) return;
        const issues = Array.isArray(reply?.issues) ? reply.issues : [];
        this.set({ ...this.snapshot, issues, loading: false, failure: undefined });
      } else {
        const reply = await this.client.call<{ issue?: GitHubIssue | null; comments?: GitHubIssueComment[] | null }>(
          GitHubOps.issue,
          { url: view.url },
        );
        if (generation !== this.generation) return;
        const issue = reply?.issue && typeof reply.issue.number === "number" ? reply.issue : undefined;
        const comments = Array.isArray(reply?.comments) ? reply.comments : [];
        this.set({ ...this.snapshot, issue, comments, loading: false, failure: undefined });
      }
    } catch (error) {
      if (generation !== this.generation) return;
      // What the page had stays; the failure says why it did not refresh.
      this.set({ ...this.snapshot, loading: false, failure: userMessage(error) });
    }
    this.timer = setTimeout(() => {
      if (this.visible()) void this.ask();
    }, REFRESH_MS);
  }

  /** Opens `issue` in this page. */
  openIssue(issue: GitHubIssue): void {
    this.navigate(issueRoute(issue.html_url));
  }

  /** Back to the repository's list. */
  openList(repo = this.snapshot.view?.repo): void {
    if (repo) this.navigate(issuesRoute(repo));
  }

  /** Opens the issue's (or the list's) web page in a cmux tab. */
  openOnGitHub(url = webURL(this.snapshot.view)): void {
    if (url && this.client) void this.client.call(GitHubOps.openIn, { url, browserId: "cmux" }).catch(() => undefined);
  }

  stop(): void {
    clearTimeout(this.timer);
    this.generation += 1;
  }

  private set(next: IssuesSnapshot) {
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
}

function key(view: IssuesView | undefined): string {
  return !view ? "" : view.kind === "list" ? `list:${view.repo}` : `issue:${view.url}`;
}

function webURL(view: IssuesView | undefined): string | undefined {
  return !view ? undefined : view.kind === "list" ? `https://github.com/${view.repo}/issues` : view.url;
}
