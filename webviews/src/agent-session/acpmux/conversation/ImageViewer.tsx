// The image viewer: one chat image over the pane, zoomed and panned in place, with arrows
// through every image of the chat (chatImages.ts).
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Dialog } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { FIT, MIN_SCALE, ZOOM_STEP, useZoomPan, zoomAbout, zoomTransform } from "../../../ui/zoomPan";
import { useT } from "../i18n";
import { postNative } from "../native";
import type { ChatImage } from "./chatImages";
import { copyImage } from "./clipboard";
import { Check, ChevronLeft, ChevronRight, Close, Copy, Folder, Globe } from "./icons";

/**
 * Base UI can restore focus to a Dialog.Trigger, but the viewer is opened by a markdown or
 * attachment button through ImageViewerContext and therefore has no Trigger of its own. Capture
 * the active opener before the portaled dialog moves focus so closing the viewer remains a local,
 * keyboard-friendly interaction.
 */
export function activeElementToRestore(): HTMLElement | null {
  if (typeof document === "undefined") return null;
  const active = document.activeElement;
  return active instanceof HTMLElement && active !== document.body ? active : null;
}

/// The image as a `data:` URL, the form the host's image actions take (a composer attachment can be
/// a `blob:` URL).
export async function dataUrl(src: string): Promise<string> {
  if (src.startsWith("data:")) return src;
  const blob = await (await fetch(src)).blob();
  return await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/// Show in Finder (the image's file when a reply named one inside the folders, else a copy) or
/// Open in browser tab (a copy), by the host (AgentPaneImageCopies.swift): one request, so one
/// click covers the host's fallback to the copy.
async function imageAction(method: "image.reveal" | "image.openInPane", image: ChatImage): Promise<void> {
  const src = await dataUrl(image.src);
  await postNative(
    method,
    method === "image.reveal" && image.path ? { src, name: image.alt, path: image.path } : { src, name: image.alt },
  );
}

export function ImageViewer({
  images,
  index,
  onIndex,
  onClose,
}: {
  images: readonly ChatImage[];
  index: number;
  onIndex(index: number): void;
  onClose(): void;
}) {
  const t = useT();
  const image = images[index];
  // Pinch, Command-scroll and double click zoom; a scroll or a drag pans a zoomed image (ui/zoomPan.ts).
  const { view, setView, stageRef, stageHandlers } = useZoomPan();
  const [copied, setCopied] = useState<"copied" | "failed" | undefined>();
  // The image action (Show in Finder, Open in browser tab) that could not open this image.
  const [failed, setFailed] = useState<"image.reveal" | "image.openInPane" | undefined>();
  const close = useRef<HTMLButtonElement>(null);
  const count = images.length;
  const restoreFocus = useRef<HTMLElement | null>(activeElementToRestore());

  useEffect(() => {
    const target = restoreFocus.current;
    return () => {
      if (!target?.isConnected) return;
      // The dialog portal and Base UI's focus guard unmount in the same commit. Queue the restore
      // after that cleanup so focus does not briefly land on the document body.
      queueMicrotask(() => {
        if (target.isConnected) target.focus();
      });
    };
  }, []);

  const shownSrc = useRef(image?.src);
  useEffect(() => {
    shownSrc.current = image?.src;
    setView(FIT);
    setCopied(undefined);
    setFailed(undefined);
  }, [image?.src]);

  const step = useCallback(
    (by: number) => {
      if (count > 1) onIndex((index + by + count) % count);
    },
    [count, index, onIndex],
  );

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key;
    if (key === "ArrowLeft") step(-1);
    else if (key === "ArrowRight") step(1);
    else if (key === "+" || key === "=") setView((current) => zoomAbout(current, current.scale * ZOOM_STEP, { x: 0, y: 0 }));
    else if (key === "-") setView((current) => zoomAbout(current, current.scale / ZOOM_STEP, { x: 0, y: 0 }));
    else if (key === "0") setView(FIT);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };

  if (!image) return null;
  const copyLabel =
    copied === "copied" ? t("image.copied") : copied === "failed" ? t("image.copyFailed") : t("image.copy");
  const actionLabel = (method: "image.reveal" | "image.openInPane") =>
    failed === method ? t("image.actionFailed") : t(method === "image.reveal" ? "image.reveal" : "image.openInTab");
  const act = (method: "image.reveal" | "image.openInPane") => {
    // The result belongs to the image it acted on; the viewer may have moved on by then.
    const acted = image;
    void imageAction(method, acted).then(
      () => shownSrc.current === acted.src && setFailed(undefined),
      () => shownSrc.current === acted.src && setFailed(method),
    );
  };
  // A browser tab never opens an SVG copy (the host refuses: it could run script).
  const opensInTab = !/^data:image\/svg\+xml/i.test(image.src);
  // The shared dialog (ui/Dialog) traps focus, makes the pane behind inert, closes on Escape and
  // gives focus back to the image that opened it.
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={image.alt || t("image.viewer")}
      className="acpmux-image-viewer"
      backdropClassName="acpmux-image-viewer-backdrop"
      initialFocus={close}
      // ui-allow: the viewer's own image keys (the arrows step, + - 0 zoom), as an image canvas has.
      onKeyDown={onKeyDown}
    >
      <div className="acpmux-image-viewer-body">
        <div className="acpmux-image-viewer-bar">
          <span className="acpmux-image-viewer-title">{image.alt}</span>
          {count > 1 && (
            <span className="acpmux-image-viewer-count">{t("image.position", { index: index + 1, count })}</span>
          )}
          <button
            type="button"
            className="acpmux-image-viewer-action"
            aria-label={copyLabel}
            onClick={() => {
              // The result belongs to the image copied; the viewer may have moved on by then.
              const copiedSrc = image.src;
              const show = (result: "copied" | "failed") => {
                if (shownSrc.current === copiedSrc) setCopied(result);
              };
              void copyImage(copiedSrc).then(
                () => show("copied"),
                () => show("failed"),
              );
            }}
          >
            {copied === "copied" ? <Check /> : <Copy />}
          </button>
          <button
            type="button"
            className="acpmux-image-viewer-action"
            aria-label={actionLabel("image.reveal")}
            title={actionLabel("image.reveal")}
            onClick={() => act("image.reveal")}
          >
            <Folder />
          </button>
          {opensInTab && (
            <button
              type="button"
              className="acpmux-image-viewer-action"
              aria-label={actionLabel("image.openInPane")}
              title={actionLabel("image.openInPane")}
              onClick={() => act("image.openInPane")}
            >
              <Globe />
            </button>
          )}
          <button
            type="button"
            className="acpmux-image-viewer-action"
            ref={close}
            {...keyedIconProps(t("image.close"), "escape")}
            onClick={onClose}
          >
            <Close />
          </button>
        </div>
        {/* Pointer zoom and pan; the keyboard does the same from the dialog (+, -, 0). */}
        {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
        <div
          ref={stageRef}
          className={`acpmux-image-viewer-stage${view.scale > MIN_SCALE ? " is-zoomed" : ""}`}
          {...stageHandlers}
          onClick={(event) => {
            // A click beside the fitted image closes the viewer, as on the scrim of a sheet.
            if (event.target === event.currentTarget && view.scale === MIN_SCALE) onClose();
          }}
        >
          <img
            className="acpmux-image-viewer-image"
            src={image.src}
            alt={image.alt}
            draggable={false}
            style={{ transform: zoomTransform(view) }}
          />
        </div>
        {count > 1 && (
          <>
            <button
              type="button"
              className="acpmux-image-viewer-step is-previous"
              {...keyedIconProps(t("image.previous"), "left")}
              onClick={() => step(-1)}
            >
              <ChevronLeft size={20} />
            </button>
            <button
              type="button"
              className="acpmux-image-viewer-step is-next"
              {...keyedIconProps(t("image.next"), "right")}
              onClick={() => step(1)}
            >
              <ChevronRight size={20} />
            </button>
          </>
        )}
      </div>
    </Dialog>
  );
}
