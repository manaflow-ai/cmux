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
// With Session Info open, the card sits directly under it (session-info/underSessionInfo.ts) and keeps
// its own room there.
// While it runs, the agent's cursor shows where the helper draws it on screen (the window stream
// has no cursor of its own): the helper's own cursor, drawn the same (cursorArt.tsx) and at the
// window's scale, gliding as it does, with a ripple on each click. The person's pointer over the
// same window shows as a second telepointer (PersonPointerArt): a neutral arrow labelled "You",
// hidden while it is outside the window and dimmed once it stays still. Both are metadata from the
// host, drawn over the frame; neither is in the frame's pixels.
import { useState, type CSSProperties } from "react";
import { useT } from "../i18n";
import { Check, Close } from "../conversation/icons";
import { useUnderSessionInfoRoom } from "../session-info/underSessionInfo";
import { useLeavingCard, useLoadedFrame } from "./cardMotion";
import { AgentCursorArt, cursorStyle, PersonPointerArt, personPointerStyle } from "./cursorArt";
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
  useUnderSessionInfoRoom(card);
  if (!shown) return null;
  // The app's name is in the label only; with no name and no window title, the label names none
  // (never "Unknown app").
  const title = computerUsePreviewTitle(shown);
  // The agent's cursor: the host's pointer (with its click and window width), else its telepointer
  // when that is all a host sends (no click to play then).
  const agentTele = shown.telepointers?.agent;
  const agent = shown.pointer ?? (agentTele?.visible ? { x: agentTele.x, y: agentTele.y, click: 0 } : undefined);
  const person = shown.telepointers?.person;
  const frameStyle = {
    ...(agent ? cursorStyle(agent) : {}),
    ...(person ? personPointerStyle(person) : {}),
  } as CSSProperties;
  const label = title
    ? t(shown.done ? "computerUse.preview.doneLabel" : "computerUse.preview.runningLabel", { app: title })
    : t(shown.done ? "computerUse.preview.doneLabelNoApp" : "computerUse.preview.runningLabelNoApp");
  return (
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
        <span className="acpmux-cu-preview__frame" style={agent || person ? frameStyle : undefined}>
          <img src={frame} alt="" draggable={false} />
          {person && <PersonPointerArt pointer={person} label={t("computerUse.preview.you")} />}
          {agent && (
            <>
              {shown.pointer && (
                <span key={shown.pointer.click} className="acpmux-cu-preview__ripple" aria-hidden="true" />
              )}
              <AgentCursorArt />
            </>
          )}
          {shown.done && (
            <span className="acpmux-cu-preview__badge" aria-hidden="true">
              <span className="acpmux-cu-preview__mark" data-icon={shown.icon ? "" : undefined}>
                {shown.icon && <img src={shown.icon} alt="" draggable={false} />}
                <span className="acpmux-cu-preview__check">
                  <Check size={shown.icon ? 10 : 12} />
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
        <Close size={12} />
      </button>
    </div>
  );
}
