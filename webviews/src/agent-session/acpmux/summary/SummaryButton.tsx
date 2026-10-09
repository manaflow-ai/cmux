import React, { useEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { sessionSummary } from "./sessionSummary";
import { SummaryPopover } from "./SummaryPopover";
import { Popover } from "../../../ui/Popover";
import { registerPicker } from "../pickerOpeners";

/// The header's summary button and its popover: what this chat has produced so far. The
/// summary is read from the transcript only while the popover is open, so a live turn pays
/// nothing for it while it is closed. Its Outputs section opens the chat's gallery; an image
/// there opens the image viewer (`onOpenImage`) in the gallery's place.
export function SummaryButton({
  rows,
  onOpenOutput,
  onOpenImage,
}: {
  rows: readonly AcpmuxRow[];
  onOpenOutput?: (path: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [gallery, setGallery] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const summary = useMemo(() => (open ? sessionSummary(rows) : undefined), [open, rows]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
  useEffect(() => {
    if (!open) return;
    const dismissOutside = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (button.current?.contains(target) || (target as Element).closest?.(".acpmux-summary-popover")) return;
      setOpen(false);
    };
    document.addEventListener("pointerdown", dismissOutside, true);
    return () => document.removeEventListener("pointerdown", dismissOutside, true);
  }, [open]);
  // Automation and captures open it by its label, as a click does (see pickerOpeners.ts).
  const label = t("summary.open");
  useEffect(() => registerPicker(label, () => setOpen(true)), [label, setOpen]);
  return (
    <span className="acpmux-summary">
      <button
        ref={button}
        type="button"
        className="acpmux-summary-button"
        aria-label={label}
        title={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen((current) => !current)}
      >
        <Icon name="view.list" size={15} />
      </button>
      {summary ? (
        <Popover
          open={open}
          onOpenChange={setOpen}
          anchor={button.current}
          label={label}
          className="acpmux-summary-popover"
          finalFocus={button}
        >
          <SummaryPopover
            summary={summary}
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
    </span>
  );
}
