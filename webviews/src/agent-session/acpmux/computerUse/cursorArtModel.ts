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

/// The frame's custom properties for the person's pointer: its position (fractions of the frame).
export function personPointerStyle(pointer: ComputerUsePreviewTelepointer): Record<string, number> {
  return { "--cu-person-x": pointer.x, "--cu-person-y": pointer.y };
}
