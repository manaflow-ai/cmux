// Where a held Session Info section belongs while it is dragged (SessionInfoGroup.tsx).
//
// A neighbour makes way once the held section's leading edge passes its middle, as the sidebar's rows
// do (SidebarDragGeometry.edgeY): dragged down, the held bottom past the middle of the section below;
// dragged up, the held top past the middle of the section above. So the held section never covers
// more than half of a neighbour (Leo, 2026-11-05, of the lifted Subagents section sliding over
// Background tasks: "in terms of just the proper, you know, dragging correctness kind of things").
// Probing at a fixed point near the top left a tall section over the whole of the one below it.
//
// It reads the place from the held top alone, against the others laid out with the held slot closed,
// so the answer depends on where the section is drawn, never on the way it moved: a sweep moves it one
// way at a time, and a still pointer never flips it.

/// A section's layout box in the list: its top and height in px, transforms left out.
export type SlotBox = { top: number; height: number };

/// The index among the other sections that the held one takes, drawn with its top at `drawnTop`.
/// `slots` are every section's layout boxes in the list's order now, the held one at `held`.
export function heldPlace(slots: readonly SlotBox[], held: number, drawnTop: number): number {
  const box = slots[held];
  if (!box) return 0;
  const after = slots[held + 1];
  const before = slots[held - 1];
  // The gap the held slot takes in the list (the one after it, else the one before it).
  const gap = after ? after.top - (box.top + box.height) : before ? box.top - (before.top + before.height) : 0;
  let at = 0;
  slots.forEach((other, index) => {
    if (index === held) return;
    // Where it sits with the held slot closed.
    const top = index > held ? other.top - box.height - gap : other.top;
    // Held below it, its top is past the middle: `top + height / 2`. Held above it, its bottom is
    // past the middle where it sits under the held slot: `top + gap + height / 2`. Halfway between
    // the two, the place depends on the drawn top alone.
    if (drawnTop > top + other.height / 2 + gap / 2) at += 1;
  });
  return at;
}
