// A queued prompt's images, as a row of small thumbnails under its text (ComposerQueue.tsx), as
// Claude's and ChatGPT's apps draw a queued message's pictures (Leo, 2026-10-21: "do queued
// messages have pics?": acpmux kept and sent the screenshot, the row showed only its text). Each
// opens the image viewer; while the prompt is edited each has a remove control, and the edit then
// keeps only the images left.
import React, { useContext, useEffect, useState } from "react";
import type { QueuedPromptImage } from "./model";
import type { Translate } from "./i18n";
import { imageLabel } from "./imageLabel";
import { ImageViewerContext } from "./conversation/imageViewerContext";

export function QueuedImages({
  images,
  t,
  read,
  onRemove,
  onLeave,
}: {
  images: readonly QueuedPromptImage[];
  t: Translate;
  /// Reads an image acpmux keeps by its id (`_acpmux/attachment`), for one the pane has no bytes for.
  read?(id: string): Promise<string | undefined>;
  /// While the prompt is edited: drops the image from it. Absent otherwise.
  onRemove?(id: string): void;
  /// While the prompt is edited: focus left the remove controls for somewhere outside the row, which
  /// saves the edit as a blur of its field does.
  onLeave?(): void;
}) {
  const editing = onRemove !== undefined;
  if (images.length === 0) return null;
  return (
    <span
      className="acpmux-queued-images"
      onBlur={(event) => {
        // Staying in the row is the field or another image control; the row itself is leaving.
        const to = event.relatedTarget;
        const row = event.currentTarget.parentElement;
        if (!editing || (to instanceof Node && to !== row && row?.contains(to))) return;
        // Focus moving to another element of the page, or a click on none; not the window losing it.
        if (to || document.hasFocus()) onLeave?.();
      }}
    >
      {images.map((image, index) => (
        <QueuedImage
          // The same picture attached twice has one id: its copies count up, so removing one does
          // not remount the images after it.
          key={`${image.id}-${images.slice(0, index).filter((other) => other.id === image.id).length}`}
          image={image}
          t={t}
          read={read}
          editing={editing}
          // An image acpmux has not named yet (sent a moment ago) cannot be kept or dropped by id.
          onRemove={onRemove && !image.local ? () => onRemove(image.id) : undefined}
        />
      ))}
    </span>
  );
}

function QueuedImage({
  image,
  t,
  read,
  editing,
  onRemove,
}: {
  image: QueuedPromptImage;
  t: Translate;
  read?(id: string): Promise<string | undefined>;
  editing: boolean;
  onRemove?(): void;
}) {
  // While the prompt is edited its field keeps focus, so a click on an image does not end the edit
  // (it saves on blur).
  const keepFocus = editing ? (event: React.MouseEvent) => event.preventDefault() : undefined;
  const openImage = useContext(ImageViewerContext);
  const [loaded, setLoaded] = useState<{ id: string; src?: string }>();
  const src = image.src ?? (loaded?.id === image.id ? loaded.src : undefined);
  useEffect(() => {
    if (image.src || !read) return;
    let live = true;
    read(image.id).then(
      (url) => live && setLoaded({ id: image.id, src: url }),
      () => live && setLoaded({ id: image.id }),
    );
    return () => {
      live = false;
    };
  }, [image.id, image.src, read]);
  const label = imageLabel(t, { name: image.name });
  return (
    <span className="acpmux-queued-image-slot">
      <button
        type="button"
        className="acpmux-queued-image"
        /* tooltip-allow: an image thumbnail shows no name */ title={label}
        aria-label={label || t("image.view")}
        disabled={!src}
        onMouseDown={keepFocus}
        onClick={() => src && openImage?.(src, label)}
      >
        {src ? <img src={src} alt="" decoding="async" /> : <span className="acpmux-queued-image-empty" />}
      </button>
      {onRemove && (
        <button
          type="button"
          className="acpmux-queued-image-remove"
          aria-label={t("composer.removeAttachment", { name: label })}
          title={t("composer.removeAttachment", { name: label })}
          onMouseDown={keepFocus}
          onClick={(event) => {
            // Removed from the keyboard: focus goes back to the edit's field, where Return saves.
            if (document.activeElement === event.currentTarget) {
              const field = event.currentTarget.closest(".acpmux-queued-images")?.parentElement;
              field?.querySelector<HTMLElement>(".acpmux-queued-edit")?.focus();
            }
            onRemove();
          }}
        >
          <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
            <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
      )}
    </span>
  );
}
