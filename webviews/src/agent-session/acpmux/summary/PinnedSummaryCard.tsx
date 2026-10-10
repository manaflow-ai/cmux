import React, { useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { chatGallery } from "./chatGallery";
import { GalleryDialog } from "./GalleryDialog";
import { sessionSummary } from "./sessionSummary";
import { SummaryPanel } from "./SummaryPanel";
import { useSummaryOpen } from "./summaryPin";
import type { SummarySectionInput } from "./summaryRows";

/// What the header button and the docked panel both take (App passes the same props to each).
export type SummaryCardProps = {
  rows: readonly AcpmuxRow[];
  project?: string;
  folder?: string;
  sections?: readonly SummarySectionInput[];
  /// The last turn that edited files, with its counts (App's lastChanges); the Changes row shows them.
  changes?: { additions: number; deletions: number };
  onOpenOutput?: (path: string) => void;
  onOpenChanges?: () => void;
  onAddSource?: () => void;
  onOpenImage?: (src: string, alt: string) => void;
};

/// The panel's element id, for the header button's aria-controls.
export const SUMMARY_PANEL_ID = "acpmux-summary-panel";

/// The chat summary docked next to the transcript (PINNED-SUMMARY P1', Lawrence 2026-10-09: "pinned summary
/// shouldn't really be a popover. like i click, and it should always stay open until i close it").
/// The header button opens it; it stays open until the user closes it with that button, the panel's close
/// button, or Escape inside it. An outside click, typing, scrolling or a new turn never close it, and the
/// open state lasts across reloads. A wide pane gives it its own right column, so the transcript column
/// narrows instead of being covered; a narrow pane docks it as a strip above the transcript with its own
/// scroll. The transcript keeps one keyed slot, so opening or closing the panel never remounts it.
/// The panel reads the transcript only while it shows (P6).
export function SummaryDock({
  children,
  enabled = true,
  ...props
}: SummaryCardProps & { children: ReactNode; enabled?: boolean }) {
  const { open, wide, setOpen } = useSummaryOpen();
  const shown = enabled && open;
  const panel = shown ? <SummaryDockPanel key="panel" {...props} wide={wide} onClose={() => setOpen(false)} /> : null;
  return (
    <div className={`flex min-h-0 min-w-0 flex-1 ${wide ? "flex-row" : "flex-col"}`}>
      {!wide && panel}
      <div key="main" className="flex min-h-0 min-w-0 flex-1 flex-col">
        {children}
      </div>
      {wide && panel}
    </div>
  );
}

function SummaryDockPanel({
  rows,
  project,
  folder,
  sections,
  changes,
  onOpenOutput,
  onOpenChanges,
  onAddSource,
  onOpenImage,
  wide,
  onClose,
}: SummaryCardProps & { wide: boolean; onClose(): void }) {
  const t = useT();
  const [gallery, setGallery] = useState(false);
  const summary = useMemo(() => sessionSummary(rows), [rows]);
  const galleryCount = useMemo(() => chatGallery(rows).length, [rows]);
  // Escape inside the panel closes it and gives the keyboard back to the button that opens it.
  const close = () => {
    onClose();
    document.querySelector<HTMLElement>("[data-summary-toggle]")?.focus();
  };
  return (
    <aside
      id={SUMMARY_PANEL_ID}
      data-summary-panel={wide ? "column" : "strip"}
      aria-label={t("summary.open")}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        event.preventDefault();
        event.stopPropagation();
        close();
      }}
      className={
        wide
          ? "flex w-72 flex-none flex-col overflow-y-auto border-l-[0.5px] border-edge bg-menu px-1.5 pt-1 pb-1.5 text-body text-fg"
          : "max-h-[40%] flex-none overflow-y-auto border-b-[0.5px] border-edge bg-menu px-1.5 pt-1 pb-1.5 text-body text-fg"
      }
    >
      <SummaryPanel
        summary={summary}
        project={project}
        folder={folder}
        sections={sections}
        changes={changes}
        galleryCount={galleryCount}
        onOpenOutput={onOpenOutput}
        onOpenChanges={onOpenChanges}
        onAddSource={onAddSource}
        onOpenGallery={() => setGallery(true)}
        onClose={close}
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
