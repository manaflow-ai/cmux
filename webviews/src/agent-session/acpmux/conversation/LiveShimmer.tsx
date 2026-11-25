// The live line's words under ONE shimmer, from "Thinking" through each named step (Leo, 2026-11-01:
// "this should be replacing the thinking area and its shimmer across things", "it should just keep
// going", "and shouldn't flicker"). The bare thinking word (`verbs` given: its widest verb reserves
// the width) and a step's words ("Running grep …", `lead`) are two looks of this one component, so a
// change between them keeps the same `ShimmerText` and the same band element: React swaps only the
// words inside. Two component types at the line's one place would mount a new band at every change.
// The band shows only while loops run (ShimmerText.tsx); Reduce Motion and static status indicators
// hide it (conversation.css `.cv-shimmer__*`).
import { ShimmerText } from "./ShimmerText";
import { useVerbSizes } from "../../../slots/thinkingIndicator/slot";

const NO_VERBS: readonly string[] = [];

export function LiveShimmer({
  label,
  verbs,
  lead,
}: {
  label: string;
  /// The bare thinking word: every label the line may rotate through. Absent for a named step.
  verbs?: readonly string[];
  /// A step's leading verb, drawn in its own span before the rest of the words.
  lead?: { lead: string; rest: string };
}) {
  const sizes = useVerbSizes(verbs ?? NO_VERBS);
  const decorative = verbs !== undefined;
  return (
    <ShimmerText
      text={label}
      baseText={
        decorative ? (
          <span className="cv-status-verb">
            {sizes}
            <span className="cv-status-verb__word">{label}</span>
          </span>
        ) : lead ? (
          <>
            <span className="cv-worked__lead">{lead.lead}</span>
            {lead.rest}
          </>
        ) : (
          label
        )
      }
      lit={
        // The words alone: the band stays in their box and never lights the time after them (Leo,
        // 2026-11-25: "and the overlap when the glimmer goes to the end").
        <span className={`cv-shimmer__lit-label${decorative ? " cv-status-verb" : ""}`} data-text={label}>
          {decorative && sizes}
        </span>
      }
    />
  );
}
