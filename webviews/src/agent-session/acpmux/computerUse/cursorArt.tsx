// The helper's agent cursor as the preview card draws it (ComputerUsePreviewCard.tsx). The legacy
// helper (cmux-cua, --cursor-shape cmux) draws each agent's cursor on screen as a small dart: the tip
// at the pointer, two wings, a back that curves in toward the tip, a white rim and no shadow, filled
// with the cmux gradient from the tip (#12c7f5, #2d8cff at 53%, #6c5cff). Traced from the helper's
// own cursor window, 2026-10-28: the dart and its rim span 17 points; the wings sit at about (17, 6.7)
// and (6.7, 17) from the tip. The card draws it at the window's scale, so the preview shows the cursor
// as the app does, never smaller than CURSOR_MIN_PX.
// The person's pointer is a second telepointer: a plain small arrow in a neutral tone with a "You"
// label, at a fixed size so it never competes with the agent's cursor. Its arrow is Petal's
// telepointer arrow (kiruna-labs/petal @ 7ac436a, web-harness/src/telepointerDisplay.ts,
// Apache-2.0).
import type { ComputerUsePreviewPointer, ComputerUsePreviewTelepointer } from "./computerUsePreview";

/// The cursor's box in points, rim included (the viewBox below: -1...18 on each axis).
export const CURSOR_POINTS = 19;
/// The smallest the card draws it, so it shows on a large window scaled far down.
export const CURSOR_MIN_PX = 8;
/// The width without a known window width (a pixel click's point, with no live cursor).
export const CURSOR_FALLBACK_PX = 12;

/// The frame's custom properties for `pointer`: its position (fractions of the frame) and the
/// cursor's width (a share of the frame's width, the window's scale).
export function cursorStyle(pointer: ComputerUsePreviewPointer): Record<string, string | number> {
  const width = pointer.windowWidth
    ? `max(${CURSOR_MIN_PX}px, ${((CURSOR_POINTS / pointer.windowWidth) * 100).toFixed(3)}%)`
    : `${CURSOR_FALLBACK_PX}px`;
  return { "--cu-pointer-x": pointer.x, "--cu-pointer-y": pointer.y, "--cu-pointer-width": width };
}

export function AgentCursorArt() {
  return (
    <svg className="acpmux-cu-preview__arrow" viewBox="-1 -1 19 19" aria-hidden="true">
      <defs>
        <linearGradient id="acpmux-cu-cursor-fill" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="17" y2="17">
          <stop offset="0" stopColor="#12c7f5" />
          <stop offset="0.53" stopColor="#2d8cff" />
          <stop offset="1" stopColor="#6c5cff" />
        </linearGradient>
      </defs>
      <path
        d="M0.9 0.9 L15.3 5.8 Q16.6 6.5 15.4 7.4 Q8.4 8.4 7.4 15.4 Q6.5 16.6 5.8 15.3 Z"
        fill="url(#acpmux-cu-cursor-fill)"
      />
    </svg>
  );
}

/// The frame's custom properties for the person's pointer: its position (fractions of the frame).
export function personPointerStyle(pointer: ComputerUsePreviewTelepointer): Record<string, number> {
  return { "--cu-person-x": pointer.x, "--cu-person-y": pointer.y };
}

/// The person's pointer: Petal's arrow (tip at 5,3 of its 24-point box), filled in the card's
/// neutral tone, with `label` beside it on a small-radius rect. Outside the window it hides; idle,
/// it dims (computerUsePreview.css).
export function PersonPointerArt({ pointer, label }: { pointer: ComputerUsePreviewTelepointer; label: string }) {
  return (
    <span
      className="acpmux-cu-preview__person"
      data-outside={pointer.visible ? undefined : ""}
      data-idle={pointer.idle ? "" : undefined}
      aria-hidden="true"
    >
      <svg className="acpmux-cu-preview__person-arrow" viewBox="0 0 24 24">
        <path d="M5 3l5 16 2.5-6.5L19 10z" />
      </svg>
      <span className="acpmux-cu-preview__person-label">{label}</span>
    </span>
  );
}
