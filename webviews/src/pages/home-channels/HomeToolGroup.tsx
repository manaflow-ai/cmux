import { AgentNamesContext } from "../../agent-session/acpmux/conversation/agentNames";
import { ToolRows } from "../../agent-session/acpmux/conversation/TurnRows";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";
import { FoldDetails } from "../../agent-session/shared/FoldDetails";
import { homeToolGroup } from "./runBlocks";
import type { HomeRunStep } from "./types";

/** The compact Home representation of a contiguous tool run. The original ACP row stays behind
 * the disclosure so copy, output and protocol details remain available on demand. It opens and closes
 * as one motion on the settle (FoldDetails.tsx), the card under it moving on the same frames. */
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
    <FoldDetails
      className="lg-home-tool-group"
      defaultOpen={!collapsed}
      bodyClassName="lg-home-tool-fold"
      summaryProps={{ className: "lg-home-tool-summary" }}
      summary={
        <>
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
        </>
      }
    >
      <div className="lg-home-tool-details">
        <AgentNamesContext.Provider value={agentNames}>
          <ToolRows row={row} />
        </AgentNamesContext.Provider>
      </div>
    </FoldDetails>
  );
}
