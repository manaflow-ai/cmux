// The review brief of an agent's diff: one row under the diff's toolbar, kept from the first frame
// whenever a chat owns the diff, so the brief arriving never moves the diff. The row names the goal
// and counts the unsure spots; it opens a panel over the diff (not in its flow) that lists the
// goal, the unsure spots first, the approaches dropped and the plan. A spot opens its hunk.
// `ReviewBriefBody` is the panel's content alone, for a surface with its own frame (a review queue).
import { useEffect, useId, useRef } from "react";
import { Icon } from "../icons";
import type { BriefSpot, ReviewBrief } from "./model";
import { isEmptyBrief } from "./model";

export type ReviewBriefLabels = {
  title: string;
  loading: string;
  failed: string;
  empty: string;
  goal: string;
  plan: string;
  rejected: string;
  unsure: string;
  show: string;
  hide: string;
  hedge: string;
  reverted: string;
  redone: string;
  reworked: string;
  notInDiff: string;
};

export type ReviewBriefState = { kind: "loading" } | { kind: "failed" } | { kind: "ready"; brief: ReviewBrief };

type BodyProps = {
  brief: ReviewBrief;
  labels: ReviewBriefLabels;
  /** Opens a spot's hunk; a spot it says is not in the diff is drawn without a link. */
  onOpenSpot?: (spot: BriefSpot) => void;
  inDiff?: (spot: BriefSpot) => boolean;
};

const kindLabel = (spot: BriefSpot, labels: ReviewBriefLabels) => labels[spot.kind];

/** Where a spot is, as its row names it: `path:line`, or the path. */
const place = (spot: BriefSpot) => (spot.path === "" ? "" : spot.line ? `${spot.path}:${spot.line}` : spot.path);

function SpotRow({ spot, labels, onOpenSpot, inDiff }: { spot: BriefSpot } & Omit<BodyProps, "brief">) {
  const linked = onOpenSpot != null && spot.path !== "" && (inDiff?.(spot) ?? true);
  const content = (
    <>
      <span className="review-brief-spot-head">
        <span className="review-brief-spot-kind" data-kind={spot.kind}>
          {kindLabel(spot, labels)}
        </span>
        {spot.path !== "" ? <span className="review-brief-spot-place">{place(spot)}</span> : null}
        {spot.path !== "" && !linked && onOpenSpot ? (
          <span className="review-brief-spot-absent">{labels.notInDiff}</span>
        ) : null}
      </span>
      {spot.text !== "" ? <span className="review-brief-spot-text">{spot.text}</span> : null}
      {spot.snippet !== "" ? <code className="review-brief-spot-snippet">{spot.snippet}</code> : null}
    </>
  );
  return linked ? (
    <button type="button" className="review-brief-spot" onClick={() => onOpenSpot?.(spot)}>
      {content}
    </button>
  ) : (
    <div className="review-brief-spot">{content}</div>
  );
}

/** The brief's sections: goal, unsure spots, dropped approaches, plan. Empty sections are left out. */
export function ReviewBriefBody({ brief, labels, onOpenSpot, inDiff }: BodyProps) {
  if (isEmptyBrief(brief)) return <p className="review-brief-empty">{labels.empty}</p>;
  const goal = brief.goal || brief.planText;
  return (
    <div className="review-brief-body">
      {goal !== "" ? (
        <section className="review-brief-section">
          <h3>{labels.goal}</h3>
          <p className="review-brief-goal">{goal}</p>
          {brief.goal !== "" && brief.planText !== "" ? (
            <p className="review-brief-plan-text">{brief.planText}</p>
          ) : null}
        </section>
      ) : null}
      {brief.unsure.length > 0 ? (
        <section className="review-brief-section">
          <h3>{labels.unsure}</h3>
          <div className="review-brief-spots">
            {brief.unsure.map((spot) => (
              <SpotRow
                key={`${spot.kind}:${spot.seq}:${spot.path}:${spot.text}`}
                spot={spot}
                labels={labels}
                onOpenSpot={onOpenSpot}
                inDiff={inDiff}
              />
            ))}
          </div>
        </section>
      ) : null}
      {brief.rejected.length > 0 ? (
        <section className="review-brief-section">
          <h3>{labels.rejected}</h3>
          <ul className="review-brief-notes">
            {brief.rejected.map((note) => (
              <li key={`${note.seq}:${note.text}`}>{note.text}</li>
            ))}
          </ul>
        </section>
      ) : null}
      {brief.plan.length > 0 ? (
        <section className="review-brief-section">
          <h3>{labels.plan}</h3>
          <ul className="review-brief-plan">
            {brief.plan.map((item, index) => (
              <li key={`${index}:${item.content}`} data-status={item.status}>
                {item.content}
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}

type StripProps = {
  state: ReviewBriefState;
  labels: ReviewBriefLabels;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onOpenSpot?: (spot: BriefSpot) => void;
  inDiff?: (spot: BriefSpot) => boolean;
};

/** The row's one line: the goal (or why there is none yet) and the unsure count. */
function summary(state: ReviewBriefState, labels: ReviewBriefLabels): { text: string; unsure: number } {
  if (state.kind === "loading") return { text: labels.loading, unsure: 0 };
  if (state.kind === "failed") return { text: labels.failed, unsure: 0 };
  const { brief } = state;
  if (isEmptyBrief(brief)) return { text: labels.empty, unsure: 0 };
  return { text: brief.goal || brief.planText || labels.title, unsure: brief.unsure.length };
}

/** The diff page's brief row and its panel. */
export function ReviewBriefStrip({ state, labels, open, onOpenChange, onOpenSpot, inDiff }: StripProps) {
  const panelId = useId();
  const rootRef = useRef<HTMLDivElement>(null);
  const ready = state.kind === "ready" && !isEmptyBrief(state.brief);
  const shown = open && ready;
  const { text, unsure } = summary(state, labels);
  // Escape and a press outside close the panel; listeners live only while it is open.
  useEffect(() => {
    if (!shown) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onOpenChange(false);
      }
    };
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) onOpenChange(false);
    };
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("pointerdown", onPointer, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("pointerdown", onPointer, true);
    };
  }, [shown, onOpenChange]);
  return (
    <div className="review-brief" ref={rootRef} data-state={state.kind} data-open={shown ? "true" : "false"}>
      <button
        type="button"
        className="review-brief-row"
        aria-expanded={shown}
        aria-controls={panelId}
        aria-label={shown ? labels.hide : labels.show}
        disabled={!ready}
        onClick={() => onOpenChange(!shown)}
      >
        <span className="review-brief-title">{labels.title}</span>
        <span className="review-brief-summary">{text}</span>
        {unsure > 0 ? (
          <span className="review-brief-count" title={labels.unsure}>
            <span className="review-brief-count-dot" aria-hidden="true" />
            {unsure}
          </span>
        ) : null}
        <span className="review-brief-chevron" aria-hidden="true">
          <Icon name="chevronDown" />
        </span>
      </button>
      {/* Always mounted while there is a brief, so opening is a transition, not a pop-in. */}
      {state.kind === "ready" ? (
        <div className="review-brief-panel" id={panelId} role="region" aria-label={labels.title} inert={!shown}>
          <ReviewBriefBody
            brief={state.brief}
            labels={labels}
            inDiff={inDiff}
            onOpenSpot={
              onOpenSpot &&
              ((spot) => {
                onOpenChange(false);
                onOpenSpot(spot);
              })
            }
          />
        </div>
      ) : null}
    </div>
  );
}
