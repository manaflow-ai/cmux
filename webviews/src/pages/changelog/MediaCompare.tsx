// A highlight's before/after pair (Leo 2026-10-20: "tho i think vids and before/afters for our
// techincal stuff is p important... we want things to be PRETTY!!!!"). Both pictures sit in one box
// that keeps its ratio, so nothing around it moves when the view changes sides. Modes (the route's
// `compare=`, for the gallery): a split the person drags (default), the two side by side, or a
// Before / After toggle that crossfades through the page's motion gate (styles.css .cl-compare).
import { createContext, useContext, useState, type CSSProperties } from "react";
import type { Strings } from "../shared/i18n";
import type { CompareMode } from "./types";

/** The page's compare mode; ChangelogPage provides the route's. */
export const CompareModeContext = createContext<CompareMode>("slider");

export function MediaCompare({
  after,
  alt,
  before,
  strings,
  fit = "cover",
}: {
  after: string;
  alt: string;
  before: { src: string; alt: string };
  strings: Strings;
  /** `contain` in the lightbox: the after picture sets the box, shown whole. */
  fit?: "cover" | "contain";
}) {
  const mode = useContext(CompareModeContext);
  // In the page both load as they near the viewport, as a lone picture does; enlarged, at once.
  const loading = fit === "cover" ? "lazy" : "eager";
  const [split, setSplit] = useState(50);
  const [showBefore, setShowBefore] = useState(false);
  const beforeLabel = strings.t("changelog.compare.before");
  const afterLabel = strings.t("changelog.compare.after");
  return (
    // Pictures read left to right in every language: before on the left, as the split shows it.
    <div
      className="cl-compare"
      data-mode={mode}
      data-fit={fit}
      data-showing={mode === "toggle" ? (showBefore ? "before" : "after") : undefined}
      dir="ltr"
      style={{ "--cl-split": `${split}%` } as CSSProperties}
    >
      <div className="cl-compare-pane" data-side="after">
        <img src={after} alt={alt} loading={loading} decoding="async" />
        {mode !== "toggle" && <span className="cl-compare-tag">{afterLabel}</span>}
      </div>
      <div className="cl-compare-pane" data-side="before">
        <img src={before.src} alt={before.alt} loading={loading} decoding="async" />
        {mode !== "toggle" && <span className="cl-compare-tag">{beforeLabel}</span>}
      </div>
      {mode === "slider" && (
        <>
          <span className="cl-compare-handle" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="14" height="14">
              <path d="M9 7 4 12l5 5M15 7l5 5-5 5" />
            </svg>
          </span>
          <input
            type="range"
            className="cl-compare-range"
            min={0}
            max={100}
            step={1}
            value={split}
            aria-label={strings.t("changelog.compare.drag")}
            aria-valuetext={`${beforeLabel} ${split}%`}
            onChange={(event) => setSplit(Number(event.currentTarget.value))}
          />
        </>
      )}
      {mode === "toggle" && (
        <fieldset className="cl-compare-switch ui-glass" aria-label={strings.t("changelog.compare.show")}>
          <button type="button" aria-pressed={showBefore} onClick={() => setShowBefore(true)}>
            {beforeLabel}
          </button>
          <button type="button" aria-pressed={!showBefore} onClick={() => setShowBefore(false)}>
            {afterLabel}
          </button>
        </fieldset>
      )}
    </div>
  );
}
