// The live preview card of computer use (B6, as the Codex app draws it): at the chat's top right, the
// app the agent drives as its own window and nothing around it (the frame's rounded corners are
// its own, with a soft shadow that follows them). The app's name is for screen readers only (the
// card's label). The column keeps the card's room, so it covers no message (computerUsePreview.ts).
// When the session ends, the window dims under the app's icon with a green check on the icon's
// corner; the host hides a done card by itself after a while (ComputerUseLivePreview.autoHideDelay).
// A click enlarges the card over the chat's top right (as the Codex app enlarges its preview) and a
// second click shrinks it back; the close button (always shown, on the window's top left corner)
// hides the card for that session. A new session's card starts small. The host owns the card; a close hides it here at
// once, before the host's next push. It eases in, and when it goes it plays a short exit first
// (cardMotion.ts); a new frame shows once it has decoded, so the stream never blanks.
// The person drags it anywhere inside the pane (a press that moves less than
// COMPUTER_USE_PREVIEW_DRAG_SLOP is still the click that enlarges it); it stays inside the pane at any
// size, and the daemon remembers where it was for the session (computerUsePreview.ts). The button on the
// window's top right corner makes it fill the pane and back (Leo, 2026-10-29: "And why can't I full
// screen this picture?"). Hidden, a small "Show Preview" chip stays at the card's place and brings it
// back. Moved, larger or hidden, the column takes back the room it kept for the card. Moving, full size
// and the chip are behind Labs > Show Preview Features (off by default, `useComputerUsePreviewControls`):
// off, the card is the top right card a click enlarges and the close button hides.
// With Session Info open, the card sits directly under it (session-info/underSessionInfo.ts) and keeps
// its own room there.
// While it runs, the agent's cursor shows where the helper draws it on screen (the window stream
// has no cursor of its own): the helper's own cursor, drawn the same (cursorArt.tsx) and at the
// window's scale, gliding as it does, with a ripple on each click. The person's pointer over the
// same window shows as a second telepointer (PersonPointerArt): a neutral arrow labelled "You",
// hidden while it is outside the window and dimmed once it stays still. Both are metadata from the
// host, drawn over the frame; neither is in the frame's pixels.
import { useState, type CSSProperties, useRef, type PointerEvent } from "react";
import { useT } from "../i18n";
import { Check, Close, Expand } from "../conversation/icons";
import { Icon } from "../icons/Icon";
import { useUnderSessionInfoRoom } from "../session-info/underSessionInfo";
import { useLeavingCard, useLoadedFrame } from "./cardMotion";
import { AgentCursorArt, PersonPointerArt } from "./cursorArt";
import { cursorStyle, personPointerStyle } from "./cursorArtModel";
import { usePaneView } from "../paneViewStore";
import {
  closeComputerUsePreview,
  computerUsePreviewTitle,
  type ComputerUsePreview,
  COMPUTER_USE_PREVIEW_DRAG_SLOP,
  computerUsePreviewDocked,
  computerUsePreviewPlace,
  dragFraction,
  moveComputerUsePreview,
  showComputerUsePreview,
  useComputerUsePreviewControls,
  useComputerUsePreviewMoves,
  type ComputerUsePreviewMove,
} from "./computerUsePreview";
import "./computerUsePreview.css";

/// A press on the card: where it started, and the place it started from.
type Press = {
  id: number;
  x: number;
  y: number;
  from: { x: number; y: number };
  room: { w: number; h: number };
  moved: boolean;
};

export function ComputerUsePreviewCard({
  preview,
  onClose,
  onMove,
  onShow,
}: {
  preview: ComputerUsePreview | null;
  onClose(session: string): void;
  /// The person moved or resized the card (the host remembers it).
  onMove?(session: string, move: ComputerUsePreviewMove): void;
  /// The person brought back the card they hid.
  onShow?(session: string): void;
}) {
  const t = useT();
  const view = usePaneView();
  const [card, setCard] = useState<HTMLDivElement | null>(null);
  // The place while a drag runs (fractions): drawn at once, sent to the host when the drag ends.
  const [dragging, setDragging] = useState<{ x: number; y: number } | null>(null);
  // Pointer events can arrive before React commits the state update from the preceding move. Keep
  // the latest place in a ref so a fast release still sends the position the person saw.
  const draggingRef = useRef<{ x: number; y: number } | null>(null);
  const press = useRef<Press | null>(null);
  // A drag just ended: the click it fires is the drag's, not an enlarge.
  const dragged = useRef(false);
  const { card: left, leaving } = useLeavingCard(preview, card);
  const shown = useComputerUsePreviewMoves(left);
  const movable = useComputerUsePreviewControls();
  const frame = useLoadedFrame(shown?.frame);
  useUnderSessionInfoRoom(card);
  if (!shown) return null;
  const session = shown.session;
  const place = computerUsePreviewPlace(shown);
  const expanded = place.size === "large";
  const full = place.size === "full";
  const docked = computerUsePreviewDocked(shown, movable) && !dragging;
  const at = dragging ?? place;
  const move = (change: ComputerUsePreviewMove) => {
    moveComputerUsePreview(session, change, view);
    onMove?.(session, change);
  };
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
  const placeStyle = docked || full ? undefined : ({ "--cu-x": at.x, "--cu-y": at.y } as CSSProperties);
  if (shown.hidden) {
    return (
      <div
        ref={setCard}
        className="acpmux-cu-preview"
        data-hidden=""
        data-placed={docked ? undefined : ""}
        data-leaving={leaving ? "" : undefined}
        inert={leaving || undefined}
        style={placeStyle}
      >
        <button
          type="button"
          className="acpmux-cu-preview__chip"
          onClick={() => {
            showComputerUsePreview(session, view);
            onShow?.(session);
          }}
        >
          <Icon name="computeruse.observe" size={12} />
          <span>{t("computerUse.preview.show")}</span>
        </button>
      </div>
    );
  }
  // A press on the card: a drag once it moves past the slop, else the click that enlarges it.
  const onPointerDown = (event: PointerEvent<HTMLButtonElement>) => {
    if (!movable || event.button !== 0 || full || !card) return;
    const pane = card.offsetParent?.getBoundingClientRect();
    const box = card.getBoundingClientRect();
    if (!pane) return;
    // The room the card moves in: the pane less the card and the margins it keeps (computerUsePreview.css).
    press.current = {
      id: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      from: { x: place.x, y: place.y },
      room: {
        w: pane.width - box.width - 2 * PANE_MARGIN,
        h: pane.height - box.height - headerTop(card) - PANE_MARGIN,
      },
      moved: false,
    };
    draggingRef.current = null;
    event.currentTarget.setPointerCapture?.(event.pointerId);
  };
  const onPointerMove = (event: PointerEvent<HTMLButtonElement>) => {
    const start = press.current;
    if (!start || start.id !== event.pointerId) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (!start.moved && Math.hypot(dx, dy) < COMPUTER_USE_PREVIEW_DRAG_SLOP) return;
    start.moved = true;
    const next = { x: dragFraction(start.from.x, dx, start.room.w), y: dragFraction(start.from.y, dy, start.room.h) };
    draggingRef.current = next;
    setDragging(next);
  };
  const onPointerUp = (event: PointerEvent<HTMLButtonElement>) => {
    const start = press.current;
    if (!start || start.id !== event.pointerId) return;
    press.current = null;
    dragged.current = start.moved;
    const next = draggingRef.current;
    draggingRef.current = null;
    if (!start.moved || !next) return;
    move({ x: next.x, y: next.y });
    setDragging(null);
  };
  return (
    <div
      ref={setCard}
      className="acpmux-cu-preview"
      data-done={shown.done ? "" : undefined}
      data-expanded={expanded ? "" : undefined}
      data-full={full ? "" : undefined}
      data-placed={docked || full ? undefined : ""}
      data-dragging={dragging ? "" : undefined}
      data-leaving={leaving ? "" : undefined}
      inert={leaving || undefined}
      style={placeStyle}
    >
      <button
        type="button"
        className="acpmux-cu-preview__open"
        aria-label={label}
        aria-expanded={expanded || full}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={() => {
          press.current = null;
          draggingRef.current = null;
          setDragging(null);
        }}
        onClick={() => {
          // The click that ends a drag is the drag's, not an enlarge.
          if (dragged.current) {
            dragged.current = false;
            return;
          }
          if (full) return move({ size: "small" });
          move({ size: expanded ? "small" : "large" });
        }}
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
          closeComputerUsePreview(session, view);
          onClose(session);
        }}
      >
        <Close size={12} />
      </button>
      {movable && (
        <button
          type="button"
          className="acpmux-cu-preview__full"
          aria-label={t(full ? "computerUse.preview.exitFullSize" : "computerUse.preview.fullSize")}
          aria-pressed={full}
          onClick={() => move({ size: full ? "small" : "full" })}
        >
          <Expand size={12} />
        </button>
      )}
    </div>
  );
}

/// The margin the card keeps from the pane's sides and bottom (computerUsePreview.css, --ds-space-3).
const PANE_MARGIN = 12;

/// The card's top bound in the pane: under the chat's header (computerUsePreview.css).
function headerTop(card: HTMLElement): number {
  const header = Number.parseFloat(getComputedStyle(card).getPropertyValue("--acpmux-header-height"));
  return (Number.isFinite(header) ? header : 44) + 8;
}
