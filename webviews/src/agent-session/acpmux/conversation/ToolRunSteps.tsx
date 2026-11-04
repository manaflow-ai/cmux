// A mixed run opens directly to its calls, never another set of group disclosures.
import { memo } from "react";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { McpCallRow } from "./McpCallRows";
import { mcpCall } from "./mcpCalls";
import { StepThought } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { InStep } from "./ToolFailureCause";
import { isQuietThought } from "./thoughts";

const RunStep = memo(function RunStep({ item, thoughtId, lead }: {
  item: AcpmuxActivity;
  thoughtId: string;
  lead: boolean;
}) {
  if (!item.tool && item.kind !== "note" && isQuietThought(item)) return null;
  return (
    <div className={item.tool ? "cv-step" : `cv-step is-thought${lead ? " is-lead" : ""}`}>
      {item.tool ? (
        mcpCall(item.tool) ? <McpCallRow item={item} /> :
        item.tool.kind === "execute" && item.tool.command ? <CommandRow item={item} /> :
        <ToolRow item={item} />
      ) : item.kind === "note" ? <p className="cv-tool-note">{item.text}</p> :
        <StepThought id={thoughtId} item={item} lead={lead} />}
    </div>
  );
}, (a, b) => a.thoughtId === b.thoughtId && a.lead === b.lead &&
  (a.item === b.item || (!a.item.tool && !b.item.tool && a.item.kind === b.item.kind &&
    a.item.text === b.item.text && a.item.startedAt === b.item.startedAt && a.item.endedAt === b.item.endedAt)));

export const ToolRunSteps = memo(function ToolRunSteps({ items, rowId, thoughtsBefore }: {
  items: readonly AcpmuxActivity[];
  rowId: string;
  thoughtsBefore: number;
}) {
  let thoughts = thoughtsBefore;
  const seen = new Set<string>();
  return (
    <InStep.Provider value>
      <div className="cv-tool-group is-flat cv-steps" data-mixed-tool-steps>
        {items.map((item, at) => {
          const thoughtId = item.tool || item.kind === "note" ? "" : `${rowId}:thought:${thoughts++}`;
          const id = item.tool?.id || thoughtId;
          const key = seen.has(id) ? `${id}:${at}` : id;
          seen.add(id);
          return <RunStep key={key} item={item} thoughtId={thoughtId} lead={at === 0 && !item.tool} />;
        })}
      </div>
    </InStep.Provider>
  );
});
