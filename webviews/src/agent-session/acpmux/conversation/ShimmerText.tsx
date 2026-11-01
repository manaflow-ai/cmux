// SPINNERS-OFF-MAIN (Lawrence 2026-10-21: "is it running on main thread? should it be or is it wasteful
// in terms of cpu?"). The running line's shimmer as two layers the compositor moves: the words rest in
// the dim color (`__base`); a band (`__band`, masked to a soft stripe) slides across the line while
// its lit copy of the words (`__lit`) slides back by the same amount, so the lit words stay put under
// the moving stripe. Both loops are `transform` only (conversation.css `cmux-shimmer-band` /
// `cmux-shimmer-lit`, on the shared clock), so the page's main thread paints nothing per frame; the
// old shimmer moved a text-clipped gradient's `background-position`, which repainted the words every
// frame. The lit copy is aria-hidden inside the band; plain text uses CSS generated content and
// timed rows provide matching label/time slots with generated text, so readers see each word once.

import type { ReactNode } from "react";

/// `text` with the shimmer layers (the band shows only while loops run; otherwise the words alone).
export function ShimmerText({ text, baseText = text, lit }: { text: string; baseText?: string; lit?: ReactNode }) {
  return (
    <>
      <span className="cv-shimmer__base">{baseText}</span>
      <span className="cv-shimmer__band" aria-hidden="true">
        <span className="cv-shimmer__lit" data-text={lit ? undefined : text}>
          {lit}
        </span>
      </span>
    </>
  );
}
