import React from "react";
import { SummaryDock, type SummaryCardProps } from "./PinnedSummaryCard";
import { SummaryButton } from "./SummaryButton";

/// The chat summary laid out as App lays it out: the header button over a stage whose transcript slot the
/// docked panel sits beside (wide) or above (narrow). The gallery's custom-section variants draw it
/// (PinnedSummarySections.gallery.tsx) until the host sends sections in the snapshot.
export function SummaryStage(props: SummaryCardProps) {
  return (
    <div className="flex h-full min-h-[480px] flex-col text-fg">
      <header className="acpmux-header justify-end">
        <SummaryButton />
      </header>
      <SummaryDock {...props}>
        <div className="flex-1 p-4 text-muted">…</div>
      </SummaryDock>
    </div>
  );
}
