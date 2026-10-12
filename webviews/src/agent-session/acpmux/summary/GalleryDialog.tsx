// The chat's gallery over the pane: a grid of every image and render the chat produced
// (chatGallery.ts), filtered by kind. An image opens the image viewer; a render is its card, run
// in place as in the transcript.
import { useMemo, useRef, useState } from "react";
import { Dialog } from "../../../ui/Dialog";
import { canRender, RenderCard } from "../conversation/RenderCard";
import { Close } from "../conversation/icons";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { chatGallery, galleryItems, type GalleryFilter } from "./chatGallery";

const FILTERS: readonly GalleryFilter[] = ["all", "image", "render"];
const FILTER_LABEL = { all: "gallery.all", image: "gallery.images", render: "gallery.renders" } as const;

export function GalleryDialog({
  rows,
  onClose,
  onOpenImage,
}: {
  rows: readonly AcpmuxRow[];
  onClose(): void;
  onOpenImage?: (src: string, alt: string) => void;
}) {
  const t = useT();
  const close = useRef<HTMLButtonElement>(null);
  const items = useMemo(() => chatGallery(rows), [rows]);
  const [filter, setFilter] = useState<GalleryFilter>("all");
  const shown = galleryItems(items, filter);
  const framed = canRender();
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={t("gallery.title")}
      className="acpmux-chat-gallery"
      backdropClassName="acpmux-image-viewer-backdrop"
      initialFocus={close}
    >
      <div className="acpmux-image-viewer-bar">
        <span className="acpmux-image-viewer-title">{t("gallery.title")}</span>
        <span className="acpmux-chat-gallery-filters">
          {FILTERS.map((kind) => (
            <button
              key={kind}
              type="button"
              className="acpmux-chat-gallery-filter"
              aria-pressed={filter === kind}
              onClick={() => setFilter(kind)}
            >
              {t(FILTER_LABEL[kind])}{" "}
              <span className="acpmux-chat-gallery-count">{galleryItems(items, kind).length}</span>
            </button>
          ))}
        </span>
        <button
          type="button"
          className="acpmux-image-viewer-action"
          ref={close}
          aria-label={t("image.close")}
          title={t("image.close")}
          onClick={onClose}
        >
          <Close />
        </button>
      </div>
      <div className="acpmux-chat-gallery-grid">
        {shown.map((item) =>
          item.kind === "image" ? (
            <figure key={item.key} className="acpmux-chat-gallery-tile" data-gallery-kind="image">
              <button
                type="button"
                className="acpmux-chat-gallery-image"
                data-open-image={onOpenImage ? "" : undefined}
                title={item.alt}
                disabled={!onOpenImage}
                onClick={() => onOpenImage?.(item.src, item.alt)}
              >
                <img src={item.src} alt={item.alt} />
              </button>
            </figure>
          ) : (
            <figure key={item.key} className="acpmux-chat-gallery-tile is-render" data-gallery-kind="render">
              {/* The pane on a dev server has no render frame (RenderCard.tsx): the title alone. */}
              {framed ? (
                <RenderCard call={item.call} />
              ) : (
                <span className="acpmux-chat-gallery-title">{item.call.title ?? t("render.untitled")}</span>
              )}
            </figure>
          ),
        )}
      </div>
    </Dialog>
  );
}
