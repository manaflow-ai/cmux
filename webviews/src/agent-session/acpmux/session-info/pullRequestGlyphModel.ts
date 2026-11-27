export type PullRequestGlyphState = "open" | "draft" | "merged" | "closed" | "conflicting";

export const PULL_REQUEST_ICONS: Record<PullRequestGlyphState, string> = {
  open: "git.pullrequest",
  draft: "git.pullrequest.draft",
  merged: "git.pullrequest.merged",
  closed: "git.pullrequest.closed",
  conflicting: "git.pullrequest.closed",
};
