import type { HeaderPullRequest } from "./headerState";

/// Whether the page offers Merge for `pullRequest`.
export function readyToMerge(pullRequest: HeaderPullRequest) {
  return (
    pullRequest.state === "open" &&
    pullRequest.mergeable === "mergeable" &&
    pullRequest.review !== "changes_requested" &&
    pullRequest.review !== "review_required" &&
    (pullRequest.checks.state === "passing" || pullRequest.checks.state === "none")
  );
}
