// The drop overlay (composer/dropOverlayState.ts says when it shows and what it says; dropOverlay.css
// draws it). A file drag rings the composer's box in the accent, as Claude desktop rings its prompt
// box, and the pointer carries the system's copy + (Leo 2026-10-23: "chatgpt has blue screen drag
// claude has blue ring and the apple + ... we have a dotted line and a pill thing... i think we could
// do claude + themed ring?"). The chat stays fully readable (Lawrence 2026-10-21: "needs to keep
// stuff behind more visible"): no tint, no frame, no pill. The ring is faint while the drag is over
// the pane but not the chat, full while over the chat; for what the chat cannot take it turns the
// danger color with one plain line saying why; on a drop it fades as the files land as chips. It
// never takes the pointer, so the drag's events stay the page's.
import { useLayoutEffect, useRef } from "react";
import "./dropOverlay.css";
import { createPortal } from "react-dom";
import { type StringKey, type Translate, useT } from "../i18n";
import type { DragSummary, DropOverlayState } from "./dropOverlayState";

const DROP_LABELS = {
  title: "composer.drop.title",
  refusedTitle: "composer.drop.refusedTitle",
  imagesUnsupported: "composer.imagesUnsupported",
  photos: "composer.drop.photos",
  pdf: "composer.drop.pdf",
  pdfs: "composer.drop.pdfs",
  files: "composer.drop.files",
} as const satisfies Record<string, StringKey>;

/// What the drag holds, in a few words ("3 photos", "PDF", "2 files"); empty when the engine showed
/// no items.
export function dropHint(summary: DragSummary, t: Translate): string {
  const n = summary.count;
  if (n === 0) return "";
  if (summary.kind === "photos") return t(DROP_LABELS.photos, { n });
  if (summary.kind === "pdfs") return n === 1 ? t(DROP_LABELS.pdf) : t(DROP_LABELS.pdfs, { n });
  return t(DROP_LABELS.files, { n });
}

/// The overlay for `state`. `container`: the chat column it draws in (the closest `.acpmux-main`);
/// unset, it draws in place. `landingTarget`: the composer's box, which the ring goes around (with
/// none, the ring goes around the column). `onLanded` runs when the landing fade ends (the overlay
/// then hides).
export function DropOverlay({
  state,
  onLanded,
  container,
  landingTarget,
}: {
  state: DropOverlayState;
  onLanded(): void;
  container?: Element | null;
  landingTarget?: () => Element | null;
}) {
  const t = useT();
  const overlayRef = useRef<HTMLDivElement>(null);
  const sheet = useRef<HTMLDivElement>(null);
  const shown = state.phase !== "hidden";
  const landing = state.phase === "landing";
  // Before paint: the ring sits on the composer's box, measured in the overlay's own coordinates.
  useLayoutEffect(() => {
    const overlay = overlayRef.current;
    if (!shown || !overlay) return;
    const from = overlay.getBoundingClientRect();
    const target = landingTarget?.();
    const to = target?.getBoundingClientRect();
    if (!target || !to || to.width === 0 || to.height === 0) {
      overlay.removeAttribute("data-target");
      return;
    }
    overlay.setAttribute("data-target", "composer");
    overlay.style.setProperty("--acpmux-drop-ring-x", `${to.left - from.left}px`);
    overlay.style.setProperty("--acpmux-drop-ring-y", `${to.top - from.top}px`);
    overlay.style.setProperty("--acpmux-drop-ring-w", `${to.width}px`);
    overlay.style.setProperty("--acpmux-drop-ring-h", `${to.height}px`);
    // The ring follows the box's own corners (the chat's composer and New Tab's card differ).
    const radius = target.ownerDocument.defaultView?.getComputedStyle(target).borderTopLeftRadius;
    if (radius && Number.parseFloat(radius) > 0) overlay.style.setProperty("--acpmux-drop-ring-radius", radius);
    else overlay.style.removeProperty("--acpmux-drop-ring-radius");
  }, [shown, landingTarget]);
  // The landing ends on the ring's fade, never on a timer.
  useLayoutEffect(() => {
    const element = sheet.current;
    if (!landing || !element) return;
    const end = (event: Event) => {
      if (event.target === element) onLanded();
    };
    element.addEventListener("animationend", end);
    // No animation runs (the app's animations off): nothing will end it, so it ends now.
    if (element.ownerDocument.defaultView?.getComputedStyle(element).animationName === "none") onLanded();
    return () => element.removeEventListener("animationend", end);
  }, [landing, onLanded]);
  if (state.phase === "hidden") return null;
  const refused = state.phase === "refused";
  const hint = dropHint(state.summary, t);
  // What the ring means, for the overlay's label: the drop prompt and what the drag holds, or the
  // refusal and its reason. Only a refusal shows its words; an accepted drag is the ring alone.
  const title = t(refused ? DROP_LABELS.refusedTitle : DROP_LABELS.title);
  const detail = refused ? t(DROP_LABELS.imagesUnsupported) : hint;
  const overlay = (
    <div
      ref={overlayRef}
      className="acpmux-drop-overlay"
      data-phase={state.phase}
      data-kind={state.summary.kind}
      aria-hidden="true"
      data-label={detail ? `${title} · ${detail}` : title}
    >
      <div ref={sheet} className="acpmux-drop-sheet">
        <div className="acpmux-drop-ring" />
      </div>
      {refused && (
        <div className="acpmux-drop-refusal">
          <span className="acpmux-drop-mark">
            <RefusedMark />
          </span>
          <span className="acpmux-drop-text">
            <span className="acpmux-drop-title">{title}</span>
            <span className="acpmux-drop-hint">{detail}</span>
          </span>
        </div>
      )}
    </div>
  );
  return container ? createPortal(overlay, container) : overlay;
}

/// The refusal's mark: a circle crossed out.
function RefusedMark() {
  return (
    <svg
      viewBox="0 0 32 32"
      width="32"
      height="32"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
    >
      <circle cx="16" cy="16" r="10.5" />
      <path d="m8.6 23.4 14.8-14.8" />
    </svg>
  );
}
