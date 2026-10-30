// The live preview card of computer use (B6, as the Codex app draws it): at the chat's top right, the
// app the agent drives as its own window and nothing around it (the frame's rounded corners are
// its own, with a soft shadow that follows them). The app's name is for screen readers only (the
// card's label). The column keeps the card's room, so it covers no message (computerUsePreview.ts).
// When the session ends, the window dims under the app's icon with a green check on the icon's
// corner; the host hides a done card by itself after a while (ComputerUseLivePreview.autoHideDelay).
// A click opens Agent Activity on the session; the close button (always shown, on the window's top
// left corner) hides the card for that session. The host owns the card; a close hides it here at
// once, before the host's next push. It eases in, and when it goes it plays a short exit first
// (cardMotion.ts); a new frame shows once it has decoded, so the stream never blanks.
// The Full Screen button (on the window's top right corner) opens the app over the whole pane,
// live, with zoom and pan (ComputerUseLightbox.tsx); it follows this session's newest frame, and
// keeps the last one if the card goes while it is open.
// With the Inspector open, the card sits directly under it (inspector/underInspector.ts) and keeps
// its own room there.
// While it runs, the agent's cursor shows where the helper draws it on screen (the window stream
// has no cursor of its own): the helper's own cursor, drawn the same (cursorArt.tsx) and at the
// window's scale, gliding as it does, with a ripple on each click.
import { useState, type CSSProperties } from "react";
import { useT } from "../i18n";
import { Check, Close, Expand } from "../conversation/icons";
import { useUnderInspectorRoom } from "../inspector/underInspector";
import { useLeavingCard, useLoadedFrame } from "./cardMotion";
import { ComputerUseLightbox } from "./ComputerUseLightbox";
import { AgentCursorArt, cursorStyle } from "./cursorArt";
import { closeComputerUsePreview, computerUsePreviewTitle, type ComputerUsePreview } from "./computerUsePreview";
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
  const { card: shown, leaving } = useLeavingCard(preview, card);
  const frame = useLoadedFrame(shown?.frame);
  useUnderInspectorRoom(card);
  // The session shown full screen: it follows the card while the card shows that session, and keeps
  // its last frame once the card goes (done and hidden by the host, or closed).
  const [viewing, setViewing] = useState<ComputerUsePreview | null>(null);
  if (viewing && preview && preview.session === viewing.session && preview !== viewing) setViewing(preview);
  const lightbox = viewing && (
    <ComputerUseLightbox preview={viewing} onOpenActivity={onOpen} onClose={() => setViewing(null)} />
  );
  if (!shown) return lightbox || null;
  // The app's name is in the label only; with no name and no window title, the label names none
  // (never "Unknown app").
  const title = computerUsePreviewTitle(shown);
  const label = title
    ? t(shown.done ? "computerUse.preview.doneLabel" : "computerUse.preview.runningLabel", { app: title })
    : t(shown.done ? "computerUse.preview.doneLabelNoApp" : "computerUse.preview.runningLabelNoApp");
  return (
    <>
    <div
      ref={setCard}
      className="acpmux-cu-preview"
      data-done={shown.done ? "" : undefined}
      data-leaving={leaving ? "" : undefined}
      inert={leaving || undefined}
    >
      <button
        type="button"
        className="acpmux-cu-preview__open"
        aria-label={label}
        onClick={() => onOpen(shown.session)}
      >
        <span
          className="acpmux-cu-preview__frame"
          style={shown.pointer ? (cursorStyle(shown.pointer) as CSSProperties) : undefined}
        >
          <img src={frame} alt="" draggable={false} />
          {shown.pointer && (
            <>
              <span key={shown.pointer.click} className="acpmux-cu-preview__ripple" aria-hidden="true" />
              <AgentCursorArt />
            </>
          )}
          {shown.done && (
            <span className="acpmux-cu-preview__badge" aria-hidden="true">
              <span className="acpmux-cu-preview__mark" data-icon={shown.icon ? "" : undefined}>
                {shown.icon && <img src={shown.icon} alt="" draggable={false} />}
                <span className="acpmux-cu-preview__check">
                  <Check size={shown.icon ? 10 : 12} strokeWidth={2.5} />
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
          closeComputerUsePreview(shown.session);
          onClose(shown.session);
        }}
      >
        <Close size={10} />
      </button>
      <button
        type="button"
        className="acpmux-cu-preview__close acpmux-cu-preview__expand"
        aria-label={t("computerUse.preview.fullScreen")}
        title={t("computerUse.preview.fullScreen")}
        onClick={() => setViewing(shown)}
      >
        <Expand size={10} />
      </button>
    </div>
    {lightbox}
    </>
  );
}
