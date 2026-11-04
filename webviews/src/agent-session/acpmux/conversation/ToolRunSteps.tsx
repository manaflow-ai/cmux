// A mixed run opens directly to its calls, never another set of group disclosures.
import { memo, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolFiles } from "../diff";
import { CommandRow } from "./CommandRow";
import { McpCallRow } from "./McpCallRows";
import { mcpCall } from "./mcpCalls";
import { StepThought } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { ToolGroupRow } from "./ToolGroupRow";
import { groupCalls, toolGroupKind, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { InStep } from "./ToolFailureCause";
import { isQuietThought } from "./thoughts";
import { ToolLabel } from "./ToolVerb";
import { ChevronRight } from "./icons";

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
    if (!item.tool && item.kind !== "note" && isQuietThought(item)) return null;
    return (
      <div className={item.tool ? "cv-step" : `cv-step is-thought${lead ? " is-lead" : ""}`}>
        {item.tool ? (
          mcpCall(item.tool) ? (
            <McpCallRow item={item} />
          ) : toolGroupKind(item.tool) === "edits" ? (
            <ToolGroupRow
              kind="edits"
              items={own}
              folded
              disclosureKey={`group:edits:${item.tool.id || stepId}`}
              findTitle={item.tool.title}
            />
          ) : item.tool.kind === "execute" && item.tool.command ? (
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
  const t = useT();
  let thoughts = thoughtsBefore;
  const seen = new Set<string>();
  const summaries = useMemo(() => {
    const groups: { kind: ToolGroupKind; items: AcpmuxActivity[] }[] = [];
    for (const item of items) {
      const kind = item.tool ? toolGroupKind(item.tool) : undefined;
      if (!kind) continue;
      const prior = groups.at(-1);
      if (prior?.kind === kind) prior.items.push(item);
      else groups.push({ kind, items: [item] });
    }
    return groups;
  }, [items]);
  // Mixed command/MCP sheets stay flat. Codex replays that also carry an edit group retain the
  // category labels that make their command and file sections discoverable.
  const shownSummaries = summaries.some(({ kind }) => kind === "edits") ? summaries : [];
  return (
    <InStep.Provider value>
      <div className="cv-tool-group is-flat cv-steps" data-mixed-tool-steps>
        {shownSummaries.map(({ kind, items: groupItems }, index) => {
          const files =
            kind === "edits" ? toolFiles(groupCalls(groupItems).map((item) => item.tool!)) : [];
          return (
            <button
              key={`${kind}:${index}`}
              type="button"
              className="cv-tool is-toggle is-run"
              aria-expanded="true"
            >
              <span className="cv-tool__text" data-find-skip>
                <ToolLabel
                  whole
                  text={toolGroupLabel(
                    t,
                    kind,
                    groupItems,
                    files.map((file) => file.path),
                  )}
                />
              </span>
              <ChevronRight size={14} className="cv-tool__chevron cv-rotor is-open" />
            </button>
          );
        })}
        {items.map((item, at) => {
          const thoughtId =
            item.tool || item.kind === "note" ? "" : `${rowId}:thought:${thoughts++}`;
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
