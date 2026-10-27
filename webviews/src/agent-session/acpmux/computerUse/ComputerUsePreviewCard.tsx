// The live preview card of computer use (B6, as the Codex app draws it): a small glass card at the
// chat's top right with the newest frame of the app the agent drives and the app's name. The
// column keeps the card's room, so it covers no message (computerUsePreview.ts). When the session
// ends, the last frame dims under the app's icon with a green check on the icon's corner. A click
// opens Agent Activity on the session; the close button hides the card for that session. The host
// owns the card; a close hides it here at once, before the host's next push. With the Inspector
// open, the card sits directly under it (inspector/underInspector.ts) and keeps its own room there.
import { useState } from "react";
import { useT } from "../i18n";
import { Check, Close } from "../conversation/icons";
import { useUnderInspectorRoom } from "../inspector/underInspector";
import { closeComputerUsePreview, computerUsePreviewTitle, type ComputerUsePreview } from "./computerUsePreview";
// The card's glass is the Inspector's, from the same rules (inspector.css).
import "../inspector/inspector.css";
import "./computerUsePreview.css";

export function ComputerUsePreviewCard({
  preview,
  onOpen,
  onClose,
}: {
  preview: ComputerUsePreview | null;
  onOpen(session: string): void;
  onClose(session: string): void;
}) {
  const t = useT();
  const [card, setCard] = useState<HTMLDivElement | null>(null);
  useUnderInspectorRoom(card);
  if (!preview) return null;
  // No name and no window title: no title row (never "Unknown app").
  const title = computerUsePreviewTitle(preview);
  const label = title
    ? t(preview.done ? "computerUse.preview.doneLabel" : "computerUse.preview.runningLabel", { app: title })
    : t(preview.done ? "computerUse.preview.doneLabelNoApp" : "computerUse.preview.runningLabelNoApp");
  return (
    <div
      ref={setCard}
      className="ui-glass ui-glass-floats acpmux-cu-preview"
      data-done={preview.done ? "" : undefined}
      data-untitled={title ? undefined : ""}
    >
      <button
        type="button"
        className="acpmux-cu-preview__open"
        aria-label={label}
        onClick={() => onOpen(preview.session)}
      >
        {title && (
          <span className="acpmux-cu-preview__title">
            {!preview.done && <span className="acpmux-cu-preview__live" aria-hidden="true" />}
            <span className="acpmux-cu-preview__app">{title}</span>
          </span>
        )}
        <span className="acpmux-cu-preview__frame">
          <img src={preview.frame} alt="" draggable={false} />
          {preview.done && (
            <span className="acpmux-cu-preview__badge" aria-hidden="true">
              <span className="acpmux-cu-preview__mark" data-icon={preview.icon ? "" : undefined}>
                {preview.icon && <img src={preview.icon} alt="" draggable={false} />}
                <span className="acpmux-cu-preview__check">
                  <Check size={10} strokeWidth={2.5} />
                </span>
              </span>
            </span>
          )}
        </span>
      </button>
      <button
        type="button"
        className="acpmux-cu-preview__close"
        aria-label={t("computerUse.preview.close")}
        onClick={() => {
          closeComputerUsePreview(preview.session);
          onClose(preview.session);
        }}
      >
        <Close size={12} />
      </button>
    </div>
  );
}
