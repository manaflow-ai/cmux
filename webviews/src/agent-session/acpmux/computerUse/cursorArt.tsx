// The helper's agent cursor as the preview card draws it (ComputerUsePreviewCard.tsx). The legacy
// helper (cmux-cua, --cursor-shape cmux) draws each agent's cursor on screen as a small rounded kite:
// a soft round tip at the pointer, two rounded wings, a back that curves in toward the tip and a white
// rim, filled with the cmux gradient from the tip (#12c7f5, #2d8cff at 53%, #6c5cff). The path is the
// helper's own (cmux-cua cursor-overlay shape.rs CMUX_CURSOR_SVG) scaled by 1.35, so it spans 17
// points, as traced from the helper's cursor window (2026-10-28), with the wings at about (17, 6.3)
// and (6.3, 17). The card draws it at the window's scale, so the preview shows the cursor as the app
// does, never smaller than CURSOR_MIN_PX.
// The person's pointer is a second telepointer: a plain small arrow in a neutral tone with a "You"
// label, at a fixed size so it never competes with the agent's cursor. Its arrow is Petal's
// telepointer arrow (kiruna-labs/petal @ 7ac436a, web-harness/src/telepointerDisplay.ts,
// Apache-2.0).
import type { ComputerUsePreviewTelepointer } from "./computerUsePreview";
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
        d="M0.92 2.47 L4.9 13.2 Q6.3 17 7.16 13.04 L7.34 12.16 Q8.21 8.21 12.16 7.34 L13.04 7.16 Q17 6.3 13.2 4.9 L2.47 0.92 Q0 0 0.92 2.47 Z"
        fill="url(#acpmux-cu-cursor-fill)"
      />
    </svg>
  );
}

/// The person's pointer: Petal's arrow (tip at 5,3 of its 24-point box) with its tip and corners
/// rounded, filled in the card's neutral tone, with `label` beside it on a capsule. Outside the window it hides; idle,
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
        <path d="M5.54 4.72 L9.46 17.28 Q10 19 10.65 17.32 L12.5 12.5 L17.32 10.65 Q19 10 17.39 9.2 L6.61 3.8 Q5 3 5.54 4.72 Z" />
      </svg>
      <span className="acpmux-cu-preview__person-label">{label}</span>
    </span>
  );
}
