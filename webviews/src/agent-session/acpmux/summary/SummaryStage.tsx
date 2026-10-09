import React from "react";
import { PinnedSummaryCard, type SummaryCardProps } from "./PinnedSummaryCard";
import { SummaryButton } from "./SummaryButton";

/// The chat summary's two surfaces laid out as App lays them out: the header button over a stage
/// that holds the pinned card at its top right. The gallery's custom-section variants draw it
/// (PinnedSummaryCard.gallery.tsx) until the host sends sections in the snapshot.
export function SummaryStage(props: SummaryCardProps) {
  return (
    <div className="relative h-full min-h-[480px] text-fg">
      <header className="acpmux-header justify-end">
        <SummaryButton {...props} />
      </header>
      <PinnedSummaryCard {...props} />
    </div>
  );
}
