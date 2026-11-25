// l10n-allow-file: mock fixtures for the browser dev loop and the gallery, not shipped UI.
// The issues view's mock answers: GitHub's REST issue fields as the host passes them through
// (`cmux.github.issues.list`, `cmux.github.issue.details`).
import type { GitHubIssue, GitHubIssueComment } from "./types";

export const MOCK_REPO = "example/app";
export const MOCK_ISSUE_URL = "https://github.com/example/app/issues/517";

/** What the mock answers for the issue ops: arrays, or `"failed"` for a host refusal. */
export interface MockIssueData {
  issues: GitHubIssue[] | "failed";
  issue: { issue: GitHubIssue; comments: GitHubIssueComment[] } | "failed";
}

const issue = (number: number, fields: Partial<GitHubIssue>): GitHubIssue => ({
  number,
  title: `Issue ${number}`,
  state: "open",
  state_reason: null,
  labels: [],
  user: { login: "octocat" },
  comments: 0,
  created_at: "2026-11-01T10:00:00Z",
  updated_at: "2026-11-04T22:00:00Z",
  html_url: `https://github.com/${MOCK_REPO}/issues/${number}`,
  body: "",
  ...fields,
});

export const mockIssue: GitHubIssue = issue(517, {
  title: "Sidebar loses the selected row after dragging a workspace",
  labels: [
    { name: "bug", color: "d73a4a" },
    { name: "sidebar", color: "0e8a16" },
    { name: "good first issue", color: "7057ff" },
  ],
  user: { login: "mona" },
  comments: 3,
  updated_at: "2026-11-05T02:10:00Z",
  body: [
    "After dragging a workspace to a new position the selection jumps to the first row.",
    "",
    "**Steps**",
    "",
    "1. Open three workspaces.",
    "2. Drag the second one to the top.",
    "3. The selected row is now the first one, not the one dragged.",
    "",
    "Expected: the dragged workspace stays selected and in view.",
  ].join("\n"),
});

export const mockIssues: GitHubIssue[] = [
  mockIssue,
  issue(516, {
    title: "Terminal font ligatures render one cell too wide in split panes",
    labels: [
      { name: "bug", color: "d73a4a" },
      { name: "terminal", color: "1d76db" },
      { name: "needs repro", color: "fbca04" },
    ],
    user: { login: "hubot" },
    comments: 12,
    updated_at: "2026-11-05T00:40:00Z",
  }),
  issue(512, {
    title: "Let automations fire on a pull request label, not only on a push",
    labels: [
      { name: "enhancement", color: "a2eeef" },
      { name: "automation", color: "5319e7" },
    ],
    comments: 7,
    updated_at: "2026-11-04T18:30:00Z",
  }),
  issue(509, {
    title: "Settings search misses rows whose title is localized",
    state: "closed",
    state_reason: "completed",
    labels: [{ name: "settings", color: "c5def5" }],
    user: { login: "mona" },
    comments: 2,
    updated_at: "2026-11-03T09:00:00Z",
  }),
  issue(503, {
    title: "Add a dark variant of the onboarding illustration",
    state: "closed",
    state_reason: "not_planned",
    labels: [{ name: "design" }],
    user: { login: "defunkt" },
    updated_at: "2026-11-01T12:00:00Z",
  }),
  issue(498, {
    title:
      "A very long issue title that keeps going to show how a row wraps when the pane is narrow and the labels do not fit on one line",
    labels: [
      { name: "docs", color: "0075ca" },
      { name: "help wanted", color: "008672" },
      { name: "question", color: "d876e3" },
      { name: "wontfix", color: "ffffff" },
    ],
    comments: 1,
    updated_at: "2026-10-28T08:00:00Z",
  }),
];

export const mockIssueComments: GitHubIssueComment[] = [
  {
    user: { login: "octocat" },
    body: "I can reproduce this on the nightly. It only happens when the sidebar is scrolled.",
    created_at: "2026-11-04T20:00:00Z",
    html_url: `${MOCK_ISSUE_URL}#issuecomment-1`,
  },
  {
    user: { login: "hubot" },
    body: "The selection is stored by index, so a reorder moves it. Storing the workspace id instead should fix it:\n\n```swift\nselection = workspace.id\n```",
    created_at: "2026-11-04T23:15:00Z",
    html_url: `${MOCK_ISSUE_URL}#issuecomment-2`,
  },
  {
    user: { login: "mona" },
    body: "Confirmed fixed in example/app#482.",
    created_at: "2026-11-05T02:10:00Z",
    html_url: `${MOCK_ISSUE_URL}#issuecomment-3`,
  },
];

export const mockIssueData: MockIssueData = {
  issues: mockIssues,
  issue: { issue: mockIssue, comments: mockIssueComments },
};
