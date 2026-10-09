import React, { useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { chatGallery } from "./chatGallery";
import { GalleryDialog } from "./GalleryDialog";
import { sessionSummary } from "./sessionSummary";
import { SummaryPanel } from "./SummaryPanel";
import { useSummaryPinned } from "./summaryPin";
import type { SummarySectionInput } from "./summaryRows";

/// What the header button and the pinned card both take (App passes the same props to each).
export type SummaryCardProps = {
  rows: readonly AcpmuxRow[];
  project?: string;
  folder?: string;
  sections?: readonly SummarySectionInput[];
  onOpenOutput?: (path: string) => void;
  onOpenChanges?: () => void;
  onAddSource?: () => void;
  onOpenImage?: (src: string, alt: string) => void;
};

/// The pinned summary card (PINNED-SUMMARY P1, the Codex app's card): at the stage's top right,
/// over the transcript's margin, while the user keeps it pinned and the pane is wide. It reads
/// the transcript only while it shows (P6), and it updates with every snapshot. Its pin control
/// unpins it; the header button then opens the same content as a popover.
export function PinnedSummaryCard({
  rows,
  project,
  folder,
  sections,
  onOpenOutput,
  onOpenChanges,
  onAddSource,
  onOpenImage,
}: SummaryCardProps) {
  const t = useT();
  const pin = useSummaryPinned();
  const [gallery, setGallery] = useState(false);
  const summary = useMemo(() => (pin.shown ? sessionSummary(rows) : undefined), [pin.shown, rows]);
  const galleryCount = useMemo(() => (pin.shown ? chatGallery(rows).length : 0), [pin.shown, rows]);
  if (!summary) return null;
  return (
    <aside
      data-summary-card
      aria-label={t("summary.open")}
      className="absolute top-12 right-3 z-[2] max-h-[min(540px,calc(100%-112px))] w-72 overflow-auto rounded-xl bg-menu px-1.5 pt-1 pb-1.5 text-[13px] leading-[18px] text-fg shadow-menu"
    >
      <SummaryPanel
        summary={summary}
        project={project}
        folder={folder}
        sections={sections}
        galleryCount={galleryCount}
        onOpenOutput={onOpenOutput}
        onOpenChanges={onOpenChanges}
        onAddSource={onAddSource}
        onOpenGallery={() => setGallery(true)}
        pin={{ pinned: true, onToggle: () => pin.setPinned(false) }}
      />
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={() => setGallery(false)}
          onOpenImage={
            onOpenImage &&
            ((src, alt) => {
              setGallery(false);
              onOpenImage(src, alt);
            })
          }
        />
      )}
    </aside>
  );
}
