import type { ReactNode } from "react";

// SPINNERS-OFF-MAIN (perf-lead row 23). The words of a transcript row (`cv-tool__text`). While the
// row runs (`working`), the working look "shimmer" (Debug Settings, `data-working-look`) sweeps a
// light band across them the way the Thinking line does (ShimmerText.tsx): the words rest in the
// dim color, and a band (`cv-tool__shine`, masked to a soft stripe) slides across them while its lit
// copy of the words (`cv-tool__lit`) slides back by the same amount, so the lit words hold still
// under the moving stripe. Both loops are `transform` only (conversation.css, `cmux-shimmer-band` /
// `cmux-shimmer-lit` on the shared clock), so the page's main thread paints nothing per frame; the
// old look moved a text-clipped gradient's `background-position`, which repainted the row's words
// every frame. A row's words can hold marks (an edit count, a failed count, a session's name), so
// the lit copy is the same children, not generated text: aria-hidden, inert and skipped by find, so
// the row still reads, copies, finds and takes clicks once. A row that is not running has no copy.

/// A transcript row's words; `working` adds the shimmer's lit layer (shown only in that look).
export function ToolText({
  working = false,
  className,
  findSkip = false,
  children,
}: {
  working?: boolean;
  className?: string;
  findSkip?: boolean;
  children: ReactNode;
}) {
  return (
    <span className={className ? `cv-tool__text ${className}` : "cv-tool__text"} data-find-skip={findSkip || undefined}>
      {children}
      {working && (
        <span className="cv-tool__shine" aria-hidden="true" data-find-skip inert>
          <span className="cv-tool__lit">{children}</span>
        </span>
      )}
    </span>
  );
}
