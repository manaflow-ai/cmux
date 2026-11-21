// A mixed run opens directly to its calls, never another set of group disclosures or group lines:
// the opened run shows the rows it holds as they draw on their own (transcript-collapsed-tool-runs.test.tsx).
import { memo, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { McpCallRow } from "./McpCallRows";
import { mcpCall } from "./mcpCalls";
import { StepThought } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { ToolGroupRow } from "./ToolGroupRow";
import { toolGroupKind } from "./toolGroups";
import { InStep } from "./toolFailureCauseModel";
import { isQuietThought } from "./thoughts";
import { toolImages } from "../toolImages";

const RunStep = memo(
  function RunStep({
    item,
    thoughtId,
    lead,
    stepId,
  }: {
    item: AcpmuxActivity;
    thoughtId: string;
    lead: boolean;
    stepId: string;
  }) {
    const own = useMemo(() => [item], [item]);
    const images = useMemo(() => (item.tool ? toolImages(item.tool) : []), [item.tool]);
    if (!item.tool && item.kind !== "note" && isQuietThought(item)) return null;
    return (
      <div
        className={item.tool ? "cv-step" : `cv-step is-thought${lead ? " is-lead" : ""}`}
        data-step-call={item.tool?.id}
      >
        {item.tool ? (
          mcpCall(item.tool) ? (
            <McpCallRow item={item} />
          ) : toolGroupKind(item.tool) === "edits" && item.tool.diffs?.length ? (
            // As toolGroups draws a lone edit: its own group only with a diff, so one without keeps its title.
            <ToolGroupRow
              kind="edits"
              items={own}
              folded
              disclosureKey={`group:edits:${item.tool.id || stepId}`}
              findTitle={item.tool.title}
            />
          ) : item.tool.kind === "execute" && item.tool.command && !images.length ? (
            // A command that returned or printed an image keeps ToolRow's strip under its row.
            <CommandRow item={item} />
          ) : (
            <ToolRow item={item} />
          )
        ) : item.kind === "note" ? (
          <p className="cv-tool-note">{item.text}</p>
        ) : (
          <StepThought id={thoughtId} item={item} lead={lead} />
        )}
      </div>
    );
  },
  (a, b) =>
    a.stepId === b.stepId &&
    a.thoughtId === b.thoughtId &&
    a.lead === b.lead &&
    (a.item === b.item ||
      (!a.item.tool &&
        !b.item.tool &&
        a.item.kind === b.item.kind &&
        a.item.text === b.item.text &&
        a.item.startedAt === b.item.startedAt &&
        a.item.endedAt === b.item.endedAt)),
);

export const ToolRunSteps = memo(function ToolRunSteps({
  items,
  rowId,
  thoughtsBefore,
}: {
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
          return (
            <RunStep
              key={key}
              stepId={`${rowId}:step:${at}`}
              item={item}
              thoughtId={thoughtId}
              lead={at === 0 && !item.tool}
            />
          );
        })}
      </div>
    </InStep.Provider>
  );
});
