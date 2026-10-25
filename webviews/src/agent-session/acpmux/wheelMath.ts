/// Converts a wheel event's line or page delta to pixels for the target scroller.
/// Kept independent so the wheel glide engine and pass-through integration share the same units.
export function wheelPixels(event: Pick<WheelEvent, "deltaY" | "deltaMode">, pageHeight: number): number {
  if (event.deltaMode === 1) return event.deltaY * 16;
  if (event.deltaMode === 2) return event.deltaY * pageHeight;
  return event.deltaY;
}
