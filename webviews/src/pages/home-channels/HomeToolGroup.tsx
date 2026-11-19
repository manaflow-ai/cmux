import { useEffect, useState, type CSSProperties } from "react";
import { AgentNamesContext } from "../../agent-session/acpmux/conversation/agentNames";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";
import { homeToolGroup } from "./runBlocks";
import { toolRowsLoaded, useToolRows } from "./toolRowsChunk";
import type { HomeRunStep } from "./types";

/** The compact Home representation of a contiguous tool run. The original ACP row stays behind
 * the disclosure so copy, output and protocol details remain available on demand.
 *
 * The rows behind it are the agent pane's (`ToolRows`, about 260 KB of the page's JS), so they are
 * their own chunk (toolRowsChunk.ts), not in the page's startup JS. A folded group (a run card)
 * draws nothing below its summary, so its rows arrive at the page's next idle moment with no
 * visible change; an open group (the run sheet, a full transcript) asks for them at once and holds
 * their place meanwhile, one tool line per step. */
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
  const ToolRows = useToolRows();
  const [open, setOpen] = useState(!collapsed);
  useEffect(() => setOpen(!collapsed), [collapsed]);
  useEffect(() => {
    if (!ToolRows) toolRowsLoaded(open ? "now" : "idle");
  }, [ToolRows, open]);
  return (
    <details className="lg-home-tool-group" open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
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
        {ToolRows ? (
          <AgentNamesContext.Provider value={agentNames}>
            <ToolRows row={row} />
          </AgentNamesContext.Provider>
        ) : (
          open && (
            <div
              className="lg-home-tool-pending"
              aria-busy="true"
              style={{ "--lg-tool-lines": Math.max(1, group.entries.length) } as CSSProperties}
            />
          )
        )}
      </div>
    </details>
  );
}
