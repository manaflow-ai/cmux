// The live preview card's full screen view (ComputerUsePreviewCard.tsx, its Full Screen button): the
// app the agent drives over the whole pane, as large as the pane allows, live. Each new frame the
// host pushes shows once it has decoded (useLoadedFrame), so the picture follows the agent with no
// blank between frames, and it opens on the frame the card already shows, so its first paint is
// instant. A static Live badge says it follows the agent (Done once the session ends); the agent's
// cursor shows where the card draws it. Pinch or Command-scroll zooms about the pointer, a drag or
// a scroll pans a zoomed frame, a double click zooms in or back, + - 0 do the same from the keys
// (ui/zoomPan.ts, shared with the chat's image viewer). The zoom stays while new frames arrive.
// Open in Agent Activity shows the session's every screenshot on its timeline; Escape or Close ends it.
import { useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import { Dialog } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { FIT, MIN_SCALE, ZOOM_STEP, useZoomPan, zoomAbout, zoomTransform } from "../../../ui/zoomPan";
import { Close, OpenTab } from "../conversation/icons";
import { useT } from "../i18n";
import { useLoadedFrame } from "./cardMotion";
import { computerUsePreviewTitle, type ComputerUsePreview } from "./computerUsePreview";
import { AgentCursorArt, cursorStyle } from "./cursorArt";

export function ComputerUseLightbox({
  preview,
  onOpenActivity,
  onClose,
}: {
  preview: ComputerUsePreview;
  onOpenActivity(session: string): void;
  onClose(): void;
}) {
  const t = useT();
  const frame = useLoadedFrame(preview.frame);
  const { view, setView, stageRef, stageHandlers } = useZoomPan();
  // The frame's shape, once its image has loaded: the frame box takes it, so the box is the
  // image's own box (the cursor's fractions are fractions of it) at the largest size that fits.
  const [ratio, setRatio] = useState<number>();
  const close = useRef<HTMLButtonElement>(null);
  const title = computerUsePreviewTitle(preview) || t("computerUse.viewer.title");

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key;
    if (key === "+" || key === "=") setView((current) => zoomAbout(current, current.scale * ZOOM_STEP, { x: 0, y: 0 }));
    else if (key === "-") setView((current) => zoomAbout(current, current.scale / ZOOM_STEP, { x: 0, y: 0 }));
    else if (key === "0") setView(FIT);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };

  const frameStyle = {
    transform: zoomTransform(view),
    ...(ratio ? { "--cu-frame-ratio": ratio } : {}),
    ...(preview.pointer && ratio ? cursorStyle(preview.pointer) : {}),
  } as CSSProperties;

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={title}
      className="acpmux-image-viewer acpmux-cu-viewer"
      backdropClassName="acpmux-image-viewer-backdrop"
      initialFocus={close}
      // ui-allow: the viewer's own zoom keys (+ - 0), as the chat's image viewer has.
      onKeyDown={onKeyDown}
    >
      <div className="acpmux-image-viewer-body">
        <div className="acpmux-image-viewer-bar">
          <span className="acpmux-image-viewer-title">{title}</span>
          {preview.done ? (
            <span className="acpmux-cu-viewer__state">{t("computerUse.viewer.done")}</span>
          ) : (
            <span className="acpmux-cu-viewer__state" data-live="">
              {t("computerUse.viewer.live")}
            </span>
          )}
          <button
            type="button"
            className="acpmux-image-viewer-action"
            aria-label={t("computerUse.viewer.openActivity")}
            title={t("computerUse.viewer.openActivity")}
            onClick={() => onOpenActivity(preview.session)}
          >
            <OpenTab />
          </button>
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
        <div
          ref={stageRef}
          className={`acpmux-image-viewer-stage acpmux-cu-viewer__stage${view.scale > MIN_SCALE ? " is-zoomed" : ""}`}
          {...stageHandlers}
        >
          <span className="acpmux-cu-viewer__frame" data-fitted={ratio ? "" : undefined} style={frameStyle}>
            <img
              src={frame}
              alt=""
              draggable={false}
              onLoad={(event) => {
                const image = event.currentTarget;
                if (image.naturalWidth > 0 && image.naturalHeight > 0)
                  setRatio(image.naturalWidth / image.naturalHeight);
              }}
            />
            {preview.pointer && ratio && (
              <>
                <span key={preview.pointer.click} className="acpmux-cu-preview__ripple" aria-hidden="true" />
                <AgentCursorArt />
              </>
            )}
          </span>
        </div>
      </div>
    </Dialog>
  );
}
