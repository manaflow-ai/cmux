// A mixed run opens directly to its calls, never another set of group disclosures or group lines:
// the opened run shows the rows it holds as they draw on their own (transcript-collapsed-tool-runs.test.tsx).
import { memo, useMemo, useRef } from "react";
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
import { useRevealPins, useStepWindow, windowedSteps } from "./stepWindow";

const RunStep = memo(
  function RunStep({
    item,
    thoughtId,
    lead,
    stepId,
    stepKey,
  }: {
    item: AcpmuxActivity;
    thoughtId: string;
    lead: boolean;
    stepId: string;
    /// The step's key in the list's window (stepWindow.ts `data-step`).
    stepKey: string;
  }) {
    const own = useMemo(() => [item], [item]);
    const images = useMemo(() => (item.tool ? toolImages(item.tool) : []), [item.tool]);
    if (!item.tool && item.kind !== "note" && isQuietThought(item)) return null;
    return (
      <div
        className={item.tool ? "cv-step" : `cv-step is-thought${lead ? " is-lead" : ""}`}
        data-step={stepKey}
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
    a.stepKey === b.stepKey &&
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

type RunEntry = { key: string; thoughtId: string };

/// The run's step keys and thought ids, rebuilt only when its shape changes (a step joins or one
/// takes another's place), never when a listed call streams output: the transcript replaces only that
/// call's activity, so the entries stay as they were and the window keeps its heights.
function useRunEntries(items: readonly AcpmuxActivity[], rowId: string, thoughtsBefore: number): RunEntry[] {
  const last = useRef<{ items: readonly AcpmuxActivity[]; rowId: string; thoughtsBefore: number; entries: RunEntry[] }>(
    undefined,
  );
  const prior = last.current;
  if (
    prior &&
    prior.rowId === rowId &&
    prior.thoughtsBefore === thoughtsBefore &&
    prior.items.length === items.length &&
    items.every((item, at) => {
      const before = prior.items[at]!;
      return (
        item === before || (item.tool ? item.tool.id === before.tool?.id : !before.tool && item.kind === before.kind)
      );
    })
  ) {
    last.current = { ...prior, items };
    return prior.entries;
  }
  let thoughts = thoughtsBefore;
  const seen = new Set<string>();
  const entries = items.map((item, at) => {
    const thoughtId = item.tool || item.kind === "note" ? "" : `${rowId}:thought:${thoughts++}`;
    const id = item.tool?.id || thoughtId;
    const key = seen.has(id) ? `${id}:${at}` : id;
    seen.add(id);
    return { key, thoughtId };
  });
  last.current = { items, rowId, thoughtsBefore, entries };
  return entries;
}

/// A mixed run's steps, windowed as an opened group's are (stepWindow.ts, ToolGroupRow.tsx StepList):
/// the steps in the run's box and a box's height over and under them draw, a box as tall as the rest
/// stands in for them, and Find's match, the focused step and a selection's ends stay drawn.
export const ToolRunSteps = memo(function ToolRunSteps({
  items,
  rowId,
  thoughtsBefore,
}: {
  items: readonly AcpmuxActivity[];
  rowId: string;
  thoughtsBefore: number;
}) {
  const entries = useRunEntries(items, rowId, thoughtsBefore);
  const keys = useMemo(() => entries.map((entry) => entry.key), [entries]);
  const list = useRef<HTMLDivElement>(null);
  const latest = useRef(items);
  latest.current = items;
  const pieces = useStepWindow({
    list,
    keys,
    quiet: (at) => {
      const item = latest.current[at];
      return Boolean(item && !item.tool && item.kind !== "note" && isQuietThought(item));
    },
    pinned: useRevealPins(items),
  });
  return (
    <InStep.Provider value>
      <div ref={list} className="cv-tool-group is-flat cv-steps" data-mixed-tool-steps>
        {windowedSteps(pieces, (from, to) =>
          entries.slice(from, to).map(({ key, thoughtId }, offset) => {
            const at = from + offset;
            const item = items[at]!;
            return (
              <RunStep
                key={key}
                stepKey={key}
                stepId={`${rowId}:step:${at}`}
                item={item}
                thoughtId={thoughtId}
                lead={at === 0 && !item.tool}
              />
            );
          }),
        )}
      </div>
    </InStep.Provider>
  );
});
