const ISSUE_INBOX_LABELS = {
  title: "Issue Inbox",
  searchPlaceholder: "Search issues",
  refresh: "Refresh",
  refreshing: "Refreshing",
  statusOpen: "Open",
  statusClosed: "Closed",
  statusAll: "All",
  providerAll: "All providers",
  providerGithub: "GitHub",
  providerLinear: "Linear",
  spawn: "Spawn",
  agentClaude: "Claude",
  agentCodex: "Codex",
  agentShell: "Shell only",
  openConfig: "Open config",
  emptyTitle: "Configure Issue Inbox",
  emptyBody: "Add GitHub or Linear sources in ~/.config/cmux/issue-inbox.json.",
  emptyExample: "Minimal example",
  emptyResults: "No issues match the current filters.",
  sourceFailed: "Could not refresh this source.",
  staleRows: "Showing cached rows where available.",
  details: "Details",
  updated: "Updated",
  showing: "Showing {shown} of {total}",
  openInBrowser: "Open in browser",
  loading: "Loading issues",
  requestFailed: "Issue Inbox request failed.",
} as const;

export type IssueInboxLabelKey = keyof typeof ISSUE_INBOX_LABELS;
export type IssueInboxLabelResolver = (key: IssueInboxLabelKey) => string;

export function createIssueInboxLabelResolver(
  labels: Record<string, string> | undefined,
): IssueInboxLabelResolver {
  return (key) => {
    const localized = labels?.[key];
    if (typeof localized === "string" && localized.trim() !== "") {
      return localized;
    }
    return ISSUE_INBOX_LABELS[key];
  };
}
