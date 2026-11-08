// Where a held Session Info section belongs while it is dragged (SessionInfoGroup.tsx).
//
// A neighbour makes way once the held section's leading edge passes its middle, as the sidebar's rows
// do (SidebarDragGeometry.edgeY): dragged down, the held bottom past the middle of the section below;
// dragged up, the held top past the middle of the section above. So the held section never covers
// more than about half of a neighbour (Leo, 2026-11-05, of the lifted Subagents section sliding over
// Background tasks: "in terms of just the proper, you know, dragging correctness kind of things").
// Probing at a fixed point near the top left a tall section over the whole of the one below it.
//
// The place is read from the held top against the others alone, stacked in their order with the list's
// gap: moving the held section never reorders the others, so the answer depends on where it is drawn and
// never on where it sits now. A still pointer never flips it. A block's larger gap (data-run-start) is
// left out: it moves with the held section, and read from the live layout it flipped the place back and
// forth at a block edge. Its few px are the price.

/// A section's layout box in the list: its top and height in px, transforms left out.
export type SlotBox = { top: number; height: number };

/// The index among the other sections that the held one takes, drawn with its top at `drawnTop`.
/// `slots` are every section's layout boxes in the list's order now, the held one at `held`; `gap` is the
/// list's own gap between sections (its CSS row-gap), a constant, never read from where they sit.
export function heldPlace(slots: readonly SlotBox[], held: number, drawnTop: number, gap = 0): number {
  if (!slots[held]) return 0;
  // The list's first top: no section ever takes a margin above it.
  let top = slots[0]!.top;
  let at = 0;
  slots.forEach((other, index) => {
    if (index === held) return;
    // Held under it, its top is past the middle (top + height / 2); held over it, its bottom is past the
    // middle of where it sits under the held slot (top + gap + height / 2). Halfway between the two.
    if (drawnTop > top + other.height / 2 + gap / 2) at += 1;
    top += other.height + gap;
  });
  return at;
}
