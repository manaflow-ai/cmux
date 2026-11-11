// SPINNERS-OFF-MAIN (Lawrence 2026-10-21: "is it running on main thread? should it be or is it wasteful
// in terms of cpu?"). The running line's shimmer as two layers the compositor moves: the words rest in
// the dim color (`__base`); a band (`__band`, masked to a soft stripe) slides across the line while
// its lit copy of the words (`__lit`) slides back by the same amount, so the lit words stay put under
// the moving stripe. Both loops are `transform` only (conversation.css `cmux-shimmer-band` /
// `cmux-shimmer-lit`, on the shared clock), so the page's main thread paints nothing per frame; the
// old shimmer moved a text-clipped gradient's `background-position`, which repainted the words every
// frame. The lit copy is aria-hidden inside the band; plain text uses CSS generated content and
// timed rows provide matching label/time slots with generated text, so readers see each word once.

import { useLayoutEffect, useRef, type ReactNode } from "react";
import { setLoopPhase } from "../../../ui/spinnerClock";

/// The shimmer's loops take the shared phase on the frame they mount (ui/spinnerClock.ts
/// `setLoopPhase`, a delay written without reading style), so a line scrolled back into view never
/// restarts its band.
function useAlignedLoops<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useLayoutEffect(() => {
    if (ref.current) setLoopPhase(ref.current);
  }, []);
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
  const band = useAlignedLoops<HTMLSpanElement>();
  return (
    <>
      <span className="cv-shimmer__base">{baseText}</span>
      <span ref={band} className="cv-shimmer__band" aria-hidden="true">
        <span className="cv-shimmer__lit" data-text={lit ? undefined : text}>
          {lit}
        </span>
      </span>
    </>
  );
}

/// A running tool row's shimmer (Leo, 2026-11-03, on a running row whose spinner sat at the
/// transcript's far edge: "doesn't claude desktop have the thinking shimmer go across stuff"): the
/// row's own words, `children`, drawn again as the lit copy over them, so the light band crosses the
/// words themselves, as Claude desktop's and ChatGPT's running rows do. The same two transform loops
/// as the Thinking line (`cmux-shimmer-band` / `cmux-shimmer-lit`), inside a still clip
/// (`.cv-row-shimmer`) so the moving band never widens the words' box (ToolRow measures it to tell
/// a cut label). Only a running row draws it, so the loop ends when the call does; Reduce Motion,
/// the motion gate and the static status look hide it (conversation.css). The copy is inert: hidden
/// from readers, Find, selection, the pointer and the keyboard (a written file's name in it is no
/// second link).
export function RowShimmer({ children }: { children: ReactNode }) {
  const shimmer = useAlignedLoops<HTMLSpanElement>();
  return (
    <span ref={shimmer} className="cv-row-shimmer" aria-hidden="true" inert data-find-skip="">
      <span className="cv-row-shimmer__band">
        <span className="cv-row-shimmer__lit">{children}</span>
      </span>
    </span>
  );
}
