import { AgentNamesContext } from "../../agent-session/acpmux/conversation/agentNames";
import { ToolRows } from "../../agent-session/acpmux/conversation/TurnRows";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";
import { homeToolGroup } from "./runBlocks";
import type { HomeRunStep } from "./types";

/** The compact Home representation of a contiguous tool run. The original ACP row stays behind
 * the disclosure so copy, output and protocol details remain available on demand. */
export function HomeToolGroup({
  row,
  steps,
  agentNames,
  collapsed = false,
}: {
  row: AcpmuxRow;
  steps: readonly HomeRunStep[];
  agentNames: ReadonlyMap<string, string>;
  collapsed?: boolean;
}) {
  const group = homeToolGroup(steps);
  return (
    <details className="lg-home-tool-group" open={!collapsed}>
      <summary className="lg-home-tool-summary">
        <span>{group.summary}</span>
        {group.entries.length > 0 && (
          <span className="lg-home-tool-titles" aria-label="Tool steps">
            {group.entries.map((entry) => (
              <span key={entry.step.id} className={`lg-home-tool-title ${entry.kind}`}>
                {entry.title}
              </span>
            ))}
          </span>
        )}
      </summary>
      <div className="lg-home-tool-details">
        <AgentNamesContext.Provider value={agentNames}>
          <ToolRows row={row} />
        </AgentNamesContext.Provider>
      </div>
    </details>
  );
}
