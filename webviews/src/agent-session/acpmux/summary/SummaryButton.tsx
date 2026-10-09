import React, { useEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { sessionSummary } from "./sessionSummary";
import { SummaryPanel } from "./SummaryPanel";
import { useSummaryPinned } from "./summaryPin";
import { Popover } from "../../../ui/Popover";
import { registerPicker } from "../pickerOpeners";
import type { SummaryCardProps } from "./PinnedSummaryCard";

/// The header's summary button and its popover: what this chat has produced so far. The
/// summary is read from the transcript only while the popover is open, so a live turn pays
/// nothing for it while it is closed. Its Outputs section opens the chat's gallery; an image
/// there opens the image viewer (`onOpenImage`) in the gallery's place.
/// While the card is pinned (PinnedSummaryCard.tsx), the button shows pressed and unpins it.
export function SummaryButton({
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
  const [open, setOpen] = useState(false);
  const [gallery, setGallery] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  // The gallery opens from the popover, which is gone when it closes: focus returns to the button.
  // Not when it closes for the image viewer, which takes focus itself.
  const refocus = useRef(false);
  useEffect(() => {
    if (gallery || !refocus.current) return;
    refocus.current = false;
    button.current?.focus();
  }, [gallery]);
  const closeGallery = () => {
    refocus.current = true;
    setGallery(false);
  };
  const summary = useMemo(() => (open ? sessionSummary(rows) : undefined), [open, rows]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
  useEffect(() => {
    if (!open) return;
    const dismissOutside = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (button.current?.contains(target) || (target as Element).closest?.(".acpmux-summary-popover, .ui-positioner"))
        return;
      setOpen(false);
    };
    document.addEventListener("pointerdown", dismissOutside, true);
    return () => document.removeEventListener("pointerdown", dismissOutside, true);
  }, [open]);
  // Automation and captures open it by its label, as a click does (see pickerOpeners.ts).
  const label = t("summary.open");
  const pinnedShown = pin.shown;
  useEffect(
    () => registerPicker(label, () => (pinnedShown ? undefined : setOpen(true))),
    [label, setOpen, pinnedShown],
  );
  return (
    <span className="acpmux-summary">
      <button
        ref={button}
        type="button"
        className="acpmux-summary-button"
        aria-label={pin.shown ? t("summary.unpin") : label}
        title={pin.shown ? t("summary.unpin") : label}
        aria-haspopup={pin.shown ? undefined : "dialog"}
        aria-expanded={pin.shown ? undefined : open}
        aria-pressed={pin.shown ? true : undefined}
        onClick={() => (pin.shown ? pin.setPinned(false) : setOpen((current) => !current))}
      >
        <Icon name="view.list" size={15} />
      </button>
      {summary && !pin.shown ? (
        <Popover
          open={open}
          onOpenChange={setOpen}
          anchor={button.current}
          label={label}
          className="acpmux-summary-popover"
          initialFocus={false}
          finalFocus={button}
        >
          <SummaryPanel
            focusFirstRow
            summary={summary}
            project={project}
            folder={folder}
            sections={sections}
            onOpenChanges={
              onOpenChanges &&
              (() => {
                setOpen(false);
                onOpenChanges();
              })
            }
            onAddSource={
              onAddSource &&
              (() => {
                setOpen(false);
                onAddSource();
              })
            }
            pin={
              pin.wide
                ? {
                    pinned: false,
                    onToggle: () => {
                      setOpen(false);
                      pin.setPinned(true);
                    },
                  }
                : undefined
            }
            galleryCount={galleryCount}
            onOpenGallery={() => {
              setOpen(false);
              setGallery(true);
            }}
            onFollow={() => setOpen(false)}
            onOpenOutput={
              onOpenOutput &&
              ((path) => {
                setOpen(false);
                onOpenOutput(path);
              })
            }
          />
        </Popover>
      ) : null}
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={closeGallery}
          onOpenImage={
            onOpenImage &&
            ((src, alt) => {
              setGallery(false);
              onOpenImage(src, alt);
            })
          }
        />
      )}
    </span>
  );
}
