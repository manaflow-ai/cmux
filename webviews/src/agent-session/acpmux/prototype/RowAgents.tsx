// A detailed workspace row's agents (#16688): each agent's mark, with a dot for its status.
import { AgentMark } from "../../shared/AgentMark";
import { STATUS_WORDS, type WorkspaceAgent } from "./rowDetail";

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
