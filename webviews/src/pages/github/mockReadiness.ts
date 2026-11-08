// Fixtures for the merge readiness block and the conversation's filters: a pull request into
// feat-cmux-next that a reviewer blocked at its head after an earlier SHIP, with a hold line, a red
// of its own and jobs still running; and the same pull request ready, with the SHIP that counts.
import { mockChecks, mockChecksPassed, mockDetails, mockPullRequest } from "./mockProvider";
import type { DashboardChecks, PullRequestDetails, PullRequestReply } from "./types";

const HEAD = mockDetails.headCommit;
const OLDER = "9a8b7c6d5e4f30211203f4e5d6c7b8a9f0e1d2c3";
const FOOTER = "🤖 Generated with [Claude Code](https://claude.com/claude-code)";

const receipt = (verdict: string, sha: string, findings: string[]) =>
  [
    `Review (gpt-6.1-sol, router-review, started by aid-5140761eb82f4f560c9a): ${verdict} at ${sha}`,
    "",
    "Reviewer: codex gpt-6.1-sol xhigh, fast tier.",
    "",
    ...findings,
  ].join("\n");

export const mockBlockedDetails: PullRequestDetails = {
  ...mockDetails,
  body: [mockDetails.body, "", "HOLD: waiting for the nightly cut", "", FOOTER].join("\n"),
  viewer: "octocat",
  conversation: [
    {
      kind: "comment",
      author: "octocat",
      body: receipt("SHIP", OLDER, ["No findings."]),
      at: "2026-11-04T19:10:00Z",
      url: "https://github.com/example/app/pull/482#issuecomment-11",
      state: null,
      comments: [],
    },
    {
      kind: "review",
      author: "monalisa",
      body: "Two questions about the timing.",
      at: "2026-11-04T21:05:00Z",
      url: "https://github.com/example/app/pull/482#pullrequestreview-2",
      state: "changes_requested",
      comments: [
        {
          path: "Sources/Sidebar/SidebarList.swift",
          line: 88,
          body: "Does this run before or after the drop animation ends?",
          url: "https://github.com/example/app/pull/482#discussion_r1",
          resolved: true,
        },
        {
          path: "Sources/Sidebar/SidebarSelection.swift",
          line: 31,
          body: "What happens when the selected row is filtered out?",
          url: "https://github.com/example/app/pull/482#discussion_r2",
          resolved: false,
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
    {
      kind: "comment",
      author: "octocat",
      body: receipt("BLOCK", HEAD, [
        "- [P1] [blocking] [category:correctness] [finding:F1] [outcome:pending] With a filter on, the scroll targets a row the list no longer shows.",
        "- [P3] [category:test] [finding:F2] [outcome:pending] The reorder test does not cover a filtered list.",
      ]),
      at: "2026-11-05T02:50:00Z",
      url: "https://github.com/example/app/pull/482#issuecomment-12",
      state: null,
      comments: [],
    },
  ],
  conversationTotal: 4,
};

export const mockBlocked: PullRequestReply = {
  pullRequest: { ...mockPullRequest, baseRef: "feat-cmux-next", labels: ["sidebar", "risk:normal"] },
  fetchedAt: 1,
};

export const mockBlockedChecks: DashboardChecks = mockChecks;

export const mockReadyDetails: PullRequestDetails = {
  ...mockDetails,
  body: [mockDetails.body, "", FOOTER].join("\n"),
  viewer: "octocat",
  conversation: [
    ...mockDetails.conversation,
    {
      kind: "comment",
      author: "octocat",
      body: receipt("SHIP", HEAD, ["No findings."]),
      at: "2026-11-05T02:55:00Z",
      url: "https://github.com/example/app/pull/482#issuecomment-13",
      state: null,
      comments: [],
    },
  ],
  conversationTotal: 4,
};

export const mockReady: PullRequestReply = {
  pullRequest: {
    ...mockPullRequest,
    baseRef: "feat-cmux-next",
    review: "approved",
    checks: { state: "passed", passed: 7, total: 7 },
    checkList: mockPullRequest.checkList.map((check) => ({ ...check, state: "passed", onBase: false })),
  },
  fetchedAt: 1,
};

export const mockReadyChecks: DashboardChecks = mockChecksPassed;
