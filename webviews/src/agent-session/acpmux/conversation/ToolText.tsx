import type { ReactNode } from "react";
import { useWorkingLook } from "../../shared/workingLook";

// SPINNERS-OFF-MAIN (perf-lead row 23). The words of a transcript row (`cv-tool__text`). While the
// row runs (`working`), the working look "shimmer" (Debug Settings, `data-working-look`) sweeps a
// light band across them the way the Thinking line does (ShimmerText.tsx): the words rest in the
// dim color, and a band (`cv-tool__shine`, masked to a soft stripe) slides across them while its lit
// copy of the words (`cv-tool__lit`) slides back by the same amount, so the lit words hold still
// under the moving stripe. Both loops are `transform` only (conversation.css, `cmux-shimmer-band` /
// `cmux-shimmer-lit` on the shared clock), so the page's main thread paints nothing per frame; the
// old look moved a text-clipped gradient's `background-position`, which repainted the row's words
// every frame.
//
// The lit layer exists only in the shimmer look: the look comes from the theme push
// (workingLook.ts, set with `data-working-look` by applyAgentTheme), so the default look and the
// spinner mount the row's words once and React renders them once. Plain-text words get the lit copy
// as generated content (`data-text`, `::before { content: attr(data-text) }`), as ShimmerText does,
// so even the shimmer look holds them once in the DOM. Words with marks (an edit count, a failed
// count, a session's name, a file link) need the same children as the lit copy: aria-hidden, inert
// and skipped by find, so the row still reads, copies, finds and takes clicks once.

/// A transcript row's words; `working` adds the shimmer's lit layer while that look is on.
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
  const shimmer = useWorkingLook() === "shimmer";
  return (
    <span className={className ? `cv-tool__text ${className}` : "cv-tool__text"} data-find-skip={findSkip || undefined}>
      {children}
      {working && shimmer && (
        <span className="cv-tool__shine" aria-hidden="true" data-find-skip inert>
          {typeof children === "string" ? (
            <span className="cv-tool__lit" data-text={children} />
          ) : (
            <span className="cv-tool__lit">{children}</span>
          )}
        </span>
      )}
    </span>
  );
}
