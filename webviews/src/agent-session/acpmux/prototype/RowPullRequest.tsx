// A detailed workspace row's pull request (#16688): its number, the glyph coloured by the head
// commit's checks from theme tokens.
import type { SessionPullRequest } from "../sessionList";
import { PullRequestIcon } from "./icons";

export function RowPullRequest({ pullRequest }: { pullRequest: SessionPullRequest }) {
  const tone = pullRequest.state === "open" ? (pullRequest.checks ?? "none") : pullRequest.state;
  const checks = pullRequest.checks ? `, checks ${pullRequest.checks}` : "";
  return (
    <span className="proto-row-pr" data-tone={tone} title={pullRequest.title}>
      <PullRequestIcon />
      <span aria-hidden="true">{pullRequest.number}</span>
      <span className="acpmux-hidden-label">{`Pull request ${pullRequest.number}, ${pullRequest.state}${checks}`}</span>
    </span>
  );
}
