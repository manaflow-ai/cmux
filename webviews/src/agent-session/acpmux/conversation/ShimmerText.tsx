import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import { startShimmerCadence } from "./shimmerCadence";

export const ShimmerEnabledContext = createContext(true);

function useShimmerCadence() {
  const ref = useRef<HTMLSpanElement>(null);
  const enabled = useContext(ShimmerEnabledContext);
  useEffect(() => {
    if (enabled && ref.current) return startShimmerCadence(ref.current);
  }, [enabled]);
  return ref;
}

/// `text` with the shimmer layers (the band shows only while loops run; otherwise the words alone).
export function ShimmerText({
  text,
  baseText = text,
  lit,
}: {
  text: string;
  /// The words at rest, when they carry their own spans (the live line's verb in its own span).
  baseText?: ReactNode;
  lit?: ReactNode;
}) {
  const band = useShimmerCadence();
  return (
    <>
      <span className="cv-shimmer__base">{baseText}</span>
      {/* A still clip around the moving band, as RowShimmer's: the lit words never draw past the
          words' own box, onto the line's timer (Leo, 2026-11-20, in a narrow pane: the shimmer "shows
          the text overlaid the timestamp when it gets to that part of the animation"). */}
      <span className="cv-shimmer__clip" aria-hidden="true">
        <span ref={band} className="cv-shimmer__band">
          <span className="cv-shimmer__lit" data-text={lit ? undefined : text}>
            {lit}
          </span>
        </span>
      </span>
    </>
  );
}

/** The duplicate stays out of selection, Find, accessibility, and pointer interaction. */
export function RowShimmer({ children }: { children: ReactNode }) {
  const shimmer = useShimmerCadence();
  return (
    <span ref={shimmer} className="cv-row-shimmer" aria-hidden="true" inert data-find-skip="">
      <span className="cv-row-shimmer__band">
        <span className="cv-row-shimmer__lit">{children}</span>
      </span>
    </span>
  );
}
