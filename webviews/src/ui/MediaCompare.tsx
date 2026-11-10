// A before/after pair of pictures (Leo 2026-10-20: "tho i think vids and before/afters for our
// techincal stuff is p important... we want things to be PRETTY!!!!"). Both pictures sit in one box
// that keeps its ratio, so nothing around it moves when the view changes sides. Modes: a split the
// person drags or moves with the arrow keys (default), the two side by side, or a Before / After
// toggle that crossfades through the page's motion gate (mediaCompare.css). What's New draws it
// under a highlight (pages/changelog) and the agent chat under a turn's edited files.
import { useState, type CSSProperties } from "react";
import "./mediaCompare.css";

export type CompareMode = "slider" | "side" | "toggle";

/** The pair's words: the two tags, the split's accessible name and the toggle group's. */
export type CompareLabels = { before: string; after: string; drag: string; show: string };

export function MediaCompare({
  after,
  before,
  labels,
  mode = "slider",
  fit = "cover",
  loading = fit === "cover" ? "lazy" : "eager",
}: {
  after: { src: string; alt: string };
  before: { src: string; alt: string };
  labels: CompareLabels;
  mode?: CompareMode;
  /** `contain` enlarged: the after picture sets the box, shown whole. */
  fit?: "cover" | "contain";
  /** In a page both load as they near the viewport, as a lone picture does; enlarged, at once. */
  loading?: "lazy" | "eager";
}) {
  const [split, setSplit] = useState(50);
  const [showBefore, setShowBefore] = useState(false);
  return (
    // Pictures read left to right in every language: before on the left, as the split shows it.
    <div
      className="ui-compare"
      data-mode={mode}
      data-fit={fit}
      data-showing={mode === "toggle" ? (showBefore ? "before" : "after") : undefined}
      dir="ltr"
      style={{ "--ui-compare-split": `${split}%` } as CSSProperties}
    >
      <div className="ui-compare-pane" data-side="after">
        <img src={after.src} alt={after.alt} loading={loading} decoding="async" />
        {mode !== "toggle" && <span className="ui-compare-tag">{labels.after}</span>}
      </div>
      <div className="ui-compare-pane" data-side="before">
        <img src={before.src} alt={before.alt} loading={loading} decoding="async" />
        {mode !== "toggle" && <span className="ui-compare-tag">{labels.before}</span>}
      </div>
      {mode === "slider" && (
        <>
          <span className="ui-compare-handle" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="14" height="14">
              <path d="M9 7 4 12l5 5M15 7l5 5-5 5" />
            </svg>
          </span>
          <input
            type="range"
            className="ui-compare-range"
            min={0}
            max={100}
            step={1}
            value={split}
            aria-label={labels.drag}
            aria-valuetext={`${labels.before} ${split}%`}
            onChange={(event) => setSplit(Number(event.currentTarget.value))}
          />
        </>
      )}
      {mode === "toggle" && (
        <fieldset className="ui-compare-switch ui-glass" aria-label={labels.show}>
          <button type="button" aria-pressed={showBefore} onClick={() => setShowBefore(true)}>
            {labels.before}
          </button>
          <button type="button" aria-pressed={!showBefore} onClick={() => setShowBefore(false)}>
            {labels.after}
          </button>
        </fieldset>
      )}
    </div>
  );
}
