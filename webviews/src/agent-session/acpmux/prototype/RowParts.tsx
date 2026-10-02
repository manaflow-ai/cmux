// The opt-in pieces of a detailed workspace row (#16688), one component each so a setting can turn
// any of them off on its own. Colours come from theme tokens only.
import { AgentMark } from "../../shared/AgentMark";
import type { SessionPullRequest } from "../sessionList";
import { BranchIcon, PullRequestIcon } from "./icons";
import type { AgentStatus, StatusGroup, WorkspaceAgent } from "./rowDetail";

const STATUS_WORDS: Record<AgentStatus, string> = {
  input: "needs input",
  running: "working",
  error: "disconnected",
  idle: "idle",
};

/** The lead session's latest reply, one line. */
export function RowPreview({ text }: { text: string }) {
  return <span className="proto-row-preview">{text}</span>;
}

/** How long ago the lead session changed, at the row's right edge. */
export function RowAge({ age }: { age: string }) {
  return <span className="proto-row-age">{age}</span>;
}

/** The pull request's number, its glyph coloured by the head commit's checks. */
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

export function RowBranch({ branch }: { branch: string }) {
  return (
    <span className="proto-row-branch" title={branch}>
      <BranchIcon />
      <span>{branch}</span>
    </span>
  );
}

/** Each agent on the workspace: its mark, with a dot for its status. */
export function RowAgents({ agents }: { agents: WorkspaceAgent[] }) {
  return (
    <span className="proto-row-agents">
      {agents.map((agent) => (
        <span
          key={agent.sessionId}
          className="proto-row-agent"
          data-status={agent.status}
          title={`${agent.title}: ${STATUS_WORDS[agent.status]}`}
        >
          <AgentMark agent={agent.harness} size={12} />
          <i />
          <span className="acpmux-hidden-label">{`${agent.title}: ${STATUS_WORDS[agent.status]}`}</span>
        </span>
      ))}
    </span>
  );
}

/** A status group's header: its name and how many workspaces it holds. */
export function StatusHeader({ group }: { group: StatusGroup<unknown> }) {
  return (
    <div className="proto-status-header" data-status={group.status}>
      <span>{group.label}</span>
      <span className="proto-status-count">{group.items.length}</span>
    </div>
  );
}
