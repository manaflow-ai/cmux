// An in-memory `cmux.github.*` provider for the browser dev loop (`/github/?mock#/pull?url=…`) and
// the gallery: one pull request shaped like the host's `pr.inspect` answer.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { GitHubOps, type LinkedPullRequest, type PullRequestDetails, type PullRequestReply } from "./types";

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

export const mockDetails: PullRequestDetails = {
  body: [
    "## Summary",
    "",
    "After a drag reorders the sidebar, the selected row can end up off screen. This keeps it in view:",
    "",
    "- `SidebarList` scrolls the selection into view once the reorder settles",
    "- the scroll is skipped while the pointer is still down",
    "- [x] tested with 200 rows",
    "- [ ] tested with a filter on",
    "",
    "Fixes #470. See the [design notes](https://github.com/example/app/blob/main/docs/sidebar.md).",
    "",
    "<!-- template: describe the change -->",
  ].join("\n"),
  headCommit: "3f9c2a1b7e4d5c6a8b9f0e1d2c3b4a5968778695",
  mergeState: "unstable",
  mergeMethod: "squash",
  labels: [
    { name: "sidebar", color: "1d76db" },
    { name: "risk:normal", color: "fbca04" },
  ],
  conversation: [
    {
      kind: "comment",
      author: "hubot",
      body: "Preview build is ready.",
      at: "2026-11-04T18:20:00Z",
      url: "https://github.com/example/app/pull/482#issuecomment-1",
      state: null,
      comments: [],
    },
    {
      kind: "review",
      author: "monalisa",
      body: "One question about the timing.",
      at: "2026-11-04T21:05:00Z",
      url: "https://github.com/example/app/pull/482#pullrequestreview-2",
      state: "changes_requested",
      comments: [
        {
          path: "Sources/Sidebar/SidebarList.swift",
          line: 88,
          body: "Does this run before or after the drop animation ends?",
          url: null,
        },
      ],
    },
    {
      kind: "comment",
      author: "octocat",
      body: "After: the scroll waits for the drop to settle now.",
      at: "2026-11-05T02:35:00Z",
      url: "https://github.com/example/app/pull/482#issuecomment-3",
      state: null,
      comments: [],
    },
  ],
  conversationTotal: 3,
  reviewers: [
    { name: "monalisa", state: "changes_requested" },
    { name: "app-team", state: "requested" },
  ],
  linked: [
    {
      number: 470,
      title: "Selected sidebar row scrolls away after a reorder",
      url: "https://github.com/example/app/issues/470",
      state: "open",
    },
  ],
};

/** One file's patch as `diff.file` answers it. */
export function mockPatch(path: string): string {
  return [
    `diff --git a/${path} b/${path}`,
    `--- a/${path}`,
    `+++ b/${path}`,
    "@@ -84,7 +84,11 @@ final class SidebarList {",
    "     func reorderDidEnd() {",
    "-        tableView.reloadData()",
    "+        tableView.reloadData()",
    "+        guard !isDragging else { return }",
    "+        if let row = selectedRow {",
    "+            tableView.scrollRowToVisible(row)",
    "+        }",
    "     }",
    " ",
    "     func select(_ row: Int) {",
    "",
  ].join("\n");
}

export class MockGitHubProvider implements PageClient {
  constructor(
    private readonly answer: PullRequestReply = {
      pullRequest: mockPullRequest,
      fetchedAt: 1_793_847_600,
      reading: false,
    },
    private readonly details: PullRequestDetails | null = mockDetails,
  ) {}

  async call<R>(op: string, params?: unknown): Promise<R> {
    if (op === GitHubOps.inspect) return this.answer as R;
    if (op === GitHubOps.details) return { details: this.details } as R;
    if (op === GitHubOps.diffFile) {
      const file = (params as { file?: string } | undefined)?.file ?? "";
      return { patch: mockPatch(file) } as R;
    }
    if (op === GitHubOps.merge) return { merged: true, queued: false } as R;
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
