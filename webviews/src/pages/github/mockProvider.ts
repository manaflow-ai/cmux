// An in-memory `cmux.github.*` provider for the browser dev loop (`/github/?mock#/pull?url=…`) and
// the gallery: one pull request shaped like the host's `pr.inspect` answer.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { GitHubOps, type LinkedPullRequest, type PullRequestReply } from "./types";

export const MOCK_URL = "https://github.com/example/app/pull/482";

export const mockPullRequest: LinkedPullRequest = {
  url: MOCK_URL,
  number: 482,
  title: "Sidebar: keep the selected row in view after a reorder",
  state: "open",
  review: "review_required",
  mergeable: "mergeable",
  checks: { state: "failed", passed: 5, total: 7, failingOnBase: 1 },
  checkList: [
    { name: "build (macOS)", state: "passed" },
    { name: "unit tests", state: "failed", url: "https://github.com/example/app/actions/runs/1" },
    { name: "lint", state: "failed", url: "https://github.com/example/app/actions/runs/2", onBase: true },
    { name: "web tests", state: "pending" },
    { name: "docs", state: "passed" },
    { name: "format", state: "passed" },
    { name: "types", state: "passed" },
  ],
  author: "octocat",
  createdAt: "2026-11-04T18:00:00Z",
  updatedAt: "2026-11-05T02:40:00Z",
  additions: 214,
  deletions: 38,
  changedFiles: 4,
  files: [
    { path: "Sources/Sidebar/SidebarList.swift", additions: 120, deletions: 22 },
    { path: "Sources/Sidebar/SidebarSelection.swift", additions: 41, deletions: 9 },
    { path: "Tests/SidebarTests/SidebarReorderTests.swift", additions: 48, deletions: 0 },
    { path: "docs/sidebar.md", additions: 5, deletions: 7 },
  ],
  labels: ["sidebar"],
  baseRef: "main",
  headRef: "sidebar-reorder-scroll",
  comments: 3,
};

export class MockGitHubProvider implements PageClient {
  constructor(
    private readonly answer: PullRequestReply = {
      pullRequest: mockPullRequest,
      fetchedAt: 1_793_847_600,
      reading: false,
    },
  ) {}

  async call<R>(op: string): Promise<R> {
    if (op === GitHubOps.inspect) return this.answer as R;
    if (op === GitHubOps.openIn || op === GitHubOps.openDiff) return {} as R;
    throw pageError("cmux.op.unknown", op);
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}
