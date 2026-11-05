import { expect, test } from "bun:test";
import { heldPlace, type SlotBox } from "./heldPlace";

// Leo, 2026-11-05: "when I'm clicking to, like, hold and drag stuff on the session info thing, it becomes
// opaque ... in terms of just the proper, you know, dragging correctness kind of things, I feel like
// there's stuff we can do there." His recording: the lifted Subagents section slid over Background tasks
// and nothing made way. A section makes way once the held one's leading edge passes its middle, as the
// sidebar's rows do (SidebarDragGeometry.edgeY): moving down its bottom edge, moving up its top edge.

// The gallery's panel, measured (agent-pane.chat-inspector compact-more): Context, Subagents (held),
// Background tasks, Sources, 12px apart.
const slots: SlotBox[] = [
  { top: 161, height: 176 },
  { top: 349, height: 220 },
  { top: 581, height: 156 },
  { top: 749, height: 196 },
];
const held = 1;
const top = slots[held]!.top;

test("picked up where it lies, it keeps its place", () => {
  expect(heldPlace(slots, held, top)).toBe(1);
});

test("dragged down, the section below makes way once the held bottom passes its middle", () => {
  // Bottom at 569 + 80 = 649: past Background tasks' middle (659)? Not yet.
  expect(heldPlace(slots, held, top + 80)).toBe(1);
  // Bottom at 569 + 100 = 669: past it, so Background tasks moves up above the held section.
  expect(heldPlace(slots, held, top + 100)).toBe(2);
});

test("dragged up, the section above makes way once the held top passes its middle", () => {
  // Top at 349 - 90 = 259: Context's middle is 249, not passed yet.
  expect(heldPlace(slots, held, top - 90)).toBe(1);
  // Top at 349 - 110 = 239: past it, so Context moves down under the held section.
  expect(heldPlace(slots, held, top - 110)).toBe(0);
});

/// The boxes the drag shows with the held section at `at` among the others: stacked 12px apart.
function shown(at: number): { boxes: SlotBox[]; held: number } {
  const others = slots.filter((_, i) => i !== held);
  const order = [...others.slice(0, at), slots[held]!, ...others.slice(at)];
  let y = slots[0]!.top;
  const boxes = order.map((box) => {
    const placed = { top: y, height: box.height };
    y += box.height + 12;
    return placed;
  });
  return { boxes, held: at };
}

test("the held section never covers more than half of a neighbour before it makes way", () => {
  for (let dy = -250; dy <= 400; dy += 1) {
    const drawn = top + dy;
    const { boxes, held: at } = shown(heldPlace(slots, held, drawn));
    const below = boxes[at + 1];
    const above = boxes[at - 1];
    const bottom = drawn + slots[held]!.height;
    if (below) expect(bottom - below.top).toBeLessThanOrEqual(below.height / 2);
    if (above) expect(above.top + above.height - drawn).toBeLessThanOrEqual(above.height / 2);
  }
});

test("a sweep down and back up moves one way at a time, no flip-flop", () => {
  const down = Array.from({ length: 500 }, (_, dy) => heldPlace(slots, held, top + dy - 250));
  for (let i = 1; i < down.length; i++) expect(down[i]!).toBeGreaterThanOrEqual(down[i - 1]!);
});
