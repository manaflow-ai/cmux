// The image viewer: one chat image over the pane, zoomed and panned in place, with arrows
// through every image of the chat (chatImages.ts).
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { Dialog } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { frameInput } from "../../../ui/frameInput";
import { useT } from "../i18n";
import { postNative } from "../native";
import type { ChatImage } from "./chatImages";
import { copyImage } from "./clipboard";
import { Check, ChevronLeft, ChevronRight, Close, Copy, Folder, Globe } from "./icons";

export const MIN_SCALE = 1;
export const MAX_SCALE = 8;
/// What a double click or the + key zooms to from the fitted image.
const STEP = 2;

type View = { scale: number; x: number; y: number };
const FIT: View = { scale: 1, x: 0, y: 0 };

/// The wheel events of one frame: a zoom (Control or Command) adds up deltaY about the newest
/// point, a scroll adds up its pan.
export type WheelFrame = { zoom: number; x: number; y: number; point: { x: number; y: number } };

export function mergeWheel(held: WheelFrame, next: WheelFrame): WheelFrame {
  return { zoom: held.zoom + next.zoom, x: held.x + next.x, y: held.y + next.y, point: next.point };
}

/// `view` after one frame's wheel: the zoom first (about the point), then the pan of a zoomed image.
export function applyWheel(view: View, wheel: WheelFrame): View {
  const zoomed = wheel.zoom === 0 ? view : zoomAbout(view, view.scale * Math.exp(-wheel.zoom * 0.01), wheel.point);
  if (zoomed.scale === MIN_SCALE || (wheel.x === 0 && wheel.y === 0)) return zoomed;
  return { ...zoomed, x: zoomed.x - wheel.x, y: zoomed.y - wheel.y };
}

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

/// `view` zoomed to `scale` about `point` (relative to the stage's center), so the pixel under
/// the point stays there. Back at the fitted size the image is centered again.
export function zoomAbout(view: View, scale: number, point: { x: number; y: number }): View {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
  if (next === MIN_SCALE) return FIT;
  const ratio = next / view.scale;
  return { scale: next, x: point.x - (point.x - view.x) * ratio, y: point.y - (point.y - view.y) * ratio };
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
  const [view, setView] = useState<View>(FIT);
  // The view a pinch started from, read by the gesture listener (registered once).
  const viewRef = useRef(view);
  useEffect(() => {
    viewRef.current = view;
  }, [view]);
  const [copied, setCopied] = useState<"copied" | "failed" | undefined>();
  // The image action (Show in Finder, Open in browser tab) that could not open this image.
  const [failed, setFailed] = useState<"image.reveal" | "image.openInPane" | undefined>();
  const stage = useRef<HTMLDivElement | null>(null);
  // The stage as state too: the dialog's portal mounts it after the first commit, and the pinch
  // and wheel listeners attach once it is there.
  const [stageElement, setStageElement] = useState<HTMLDivElement | null>(null);
  const stageRef = useCallback((element: HTMLDivElement | null) => {
    stage.current = element;
    setStageElement(element);
  }, []);
  const close = useRef<HTMLButtonElement>(null);
  const drag = useRef<{ id: number; x: number; y: number } | undefined>(undefined);
  // A drag pans once per frame, by that frame's moves (ui/frameInput.ts).
  const [dragMoves] = useState(() =>
    frameInput(window, (point: { id: number; x: number; y: number }) => {
      const from = drag.current;
      if (!from || from.id !== point.id) return;
      drag.current = point;
      setView((current) => ({ ...current, x: current.x + point.x - from.x, y: current.y + point.y - from.y }));
    }),
  );
  useEffect(() => () => dragMoves.cancel(), [dragMoves]);
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

  const center = () => {
    const box = stage.current?.getBoundingClientRect();
    return box ? { x: box.left + box.width / 2, y: box.top + box.height / 2 } : { x: 0, y: 0 };
  };
  const fromCenter = (clientX: number, clientY: number) => {
    const c = center();
    return { x: clientX - c.x, y: clientY - c.y };
  };

  // A pinch zooms about the pointer: WebKit sends it as gesture events, other engines as a wheel
  // event with Control. Command-scroll zooms too; a scroll pans a zoomed image. The view changes
  // once per frame, from that frame's events (ui/frameInput.ts).
  useEffect(() => {
    const element = stageElement;
    if (!element) return;
    const win = element.ownerDocument.defaultView ?? window;
    let pinchFrom: View | undefined;
    // A gesture's scale is from its start, so the newest one wins.
    const pinch = frameInput(win, (change: { scale: number; point: { x: number; y: number } }) => {
      if (pinchFrom) setView(zoomAbout(pinchFrom, pinchFrom.scale * change.scale, change.point));
    });
    const wheels = frameInput(win, (wheel: WheelFrame) => setView((current) => applyWheel(current, wheel)), mergeWheel);
    // Not passive: preventDefault keeps WebKit from magnifying the whole pane behind the viewer.
    const onGesture = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale?: number; clientX?: number; clientY?: number };
      if (event.type === "gesturestart") pinchFrom = viewRef.current;
      else if (event.type === "gesturechange" && pinchFrom && typeof gesture.scale === "number") {
        const point = fromCenter(gesture.clientX ?? center().x, gesture.clientY ?? center().y);
        pinch.push({ scale: gesture.scale, point });
      } else if (event.type === "gestureend") {
        pinch.flush();
        pinchFrom = undefined;
      }
    };
    for (const type of ["gesturestart", "gesturechange", "gestureend"]) element.addEventListener(type, onGesture);
    // Not passive: the viewer covers the pane, and preventDefault keeps the pane from scrolling (or
    // zooming, with Control) behind it.
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      const point = fromCenter(event.clientX, event.clientY);
      wheels.push(
        event.ctrlKey || event.metaKey
          ? { zoom: event.deltaY, x: 0, y: 0, point }
          : { zoom: 0, x: event.deltaX, y: event.deltaY, point },
      );
    };
    element.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      pinch.cancel();
      wheels.cancel();
      element.removeEventListener("wheel", onWheel);
      for (const type of ["gesturestart", "gesturechange", "gestureend"]) element.removeEventListener(type, onGesture);
    };
  }, [stageElement]);

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key;
    if (key === "ArrowLeft") step(-1);
    else if (key === "ArrowRight") step(1);
    else if (key === "+" || key === "=") setView((current) => zoomAbout(current, current.scale * STEP, { x: 0, y: 0 }));
    else if (key === "-") setView((current) => zoomAbout(current, current.scale / STEP, { x: 0, y: 0 }));
    else if (key === "0") setView(FIT);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };

  const onPointerDown = (event: ReactPointerEvent) => {
    if (view.scale === MIN_SCALE || event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
  };
  const onPointerMove = (event: ReactPointerEvent) => {
    if (drag.current?.id !== event.pointerId) return;
    dragMoves.push({ id: event.pointerId, x: event.clientX, y: event.clientY });
  };
  const endDrag = () => {
    dragMoves.flush();
    drag.current = undefined;
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
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onDoubleClick={(event) => {
            const point = fromCenter(event.clientX, event.clientY);
            setView((current) => (current.scale > MIN_SCALE ? FIT : zoomAbout(current, STEP, point)));
          }}
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
            style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.scale})` }}
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
