// The live preview card of computer use (B6, as the Codex app draws it): a small glass card at the
// chat's top right with the newest frame of the app the agent drives and the app's name. When the
// session ends, the last frame dims under the app's icon with a green check. A click opens Agent
// Activity on the session; the close button hides the card for that session. The host owns the
// card (computerUsePreview.ts); a close hides it here at once, before the host's next push.
import { useState } from "react";
import { useT } from "../i18n";
import { Check, Close } from "../conversation/icons";
import type { ComputerUsePreview } from "./computerUsePreview";
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
  // The session the person closed here: the host's push that takes the card away comes after.
  const [closed, setClosed] = useState<string | undefined>();
  if (!preview || preview.session === closed) return null;
  const app = preview.app || t("computerUse.preview.unknownApp");
  return (
    <div className="ui-glass ui-glass-floats acpmux-cu-preview" data-done={preview.done ? "" : undefined}>
      <button
        type="button"
        className="acpmux-cu-preview__open"
        aria-label={t(preview.done ? "computerUse.preview.doneLabel" : "computerUse.preview.runningLabel", { app })}
        onClick={() => onOpen(preview.session)}
      >
        <span className="acpmux-cu-preview__title">
          {!preview.done && <span className="acpmux-cu-preview__live" aria-hidden="true" />}
          <span className="acpmux-cu-preview__app">{app}</span>
        </span>
        <span className="acpmux-cu-preview__frame">
          <img src={preview.frame} alt="" draggable={false} />
          {preview.done && (
            <span className="acpmux-cu-preview__badge" aria-hidden="true">
              {preview.icon ? <img src={preview.icon} alt="" draggable={false} /> : null}
              <span className="acpmux-cu-preview__check">
                <Check size={10} strokeWidth={2} />
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
          setClosed(preview.session);
          onClose(preview.session);
        }}
      >
        <Close size={12} />
      </button>
    </div>
  );
}
