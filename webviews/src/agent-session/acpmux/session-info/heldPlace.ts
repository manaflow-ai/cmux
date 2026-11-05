// Where a held Session Info section belongs while it is dragged (SessionInfoGroup.tsx).

/// A section's layout box in the list: its top and height in px, transforms left out.
export type SlotBox = { top: number; height: number };

/// How far below its top the held section looks for its place (at most its middle).
const PROBE = 24;

/// The index among the other sections that the held one takes, drawn with its top at `drawnTop`.
/// `slots` are every section's layout boxes in the list's order now, the held one at `held`.
export function heldPlace(slots: readonly SlotBox[], held: number, drawnTop: number): number {
  const box = slots[held];
  if (!box) return 0;
  const probe = drawnTop + Math.min(box.height / 2, PROBE);
  return slots.filter((other, at) => at !== held && other.top + other.height / 2 < probe).length;
}
