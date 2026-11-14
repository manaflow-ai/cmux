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
  expect(heldPlace(slots, held, top, 12)).toBe(1);
});

test("dragged down, the section below makes way once the held bottom passes its middle", () => {
  // Bottom at 569 + 80 = 649: past Background tasks' middle (659)? Not yet.
  expect(heldPlace(slots, held, top + 80, 12)).toBe(1);
  // Bottom at 569 + 100 = 669: past it, so Background tasks moves up above the held section.
  expect(heldPlace(slots, held, top + 100, 12)).toBe(2);
});

test("dragged up, the section above makes way once the held top passes its middle", () => {
  // Top at 349 - 90 = 259: Context's middle is 249, not passed yet.
  expect(heldPlace(slots, held, top - 90, 12)).toBe(1);
  // Top at 349 - 110 = 239: past it, so Context moves down under the held section.
  expect(heldPlace(slots, held, top - 110, 12)).toBe(0);
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
    const { boxes, held: at } = shown(heldPlace(slots, held, drawn, 12));
    const below = boxes[at + 1];
    const above = boxes[at - 1];
    const bottom = drawn + slots[held]!.height;
    if (below) expect(bottom - below.top).toBeLessThanOrEqual(below.height / 2);
    if (above) expect(above.top + above.height - drawn).toBeLessThanOrEqual(above.height / 2);
  }
});

test("a sweep down moves one way at a time", () => {
  const down = Array.from({ length: 500 }, (_, dy) => heldPlace(slots, held, top + dy - 250, 12));
  for (let i = 1; i < down.length; i++) expect(down[i]!).toBeGreaterThanOrEqual(down[i - 1]!);
});

// The glance layout's gaps are uneven: 4px inside a block, 12px where a block starts (data-run-start).
// Laid out again after every answer, a still drawn top must give the same answer: a place that read the
// gap from where the held section sat flipped it back and forth at a block edge (review of cmux#35962).
const blocks = [
  { id: "a1", block: "a", height: 40 },
  { id: "a2", block: "a", height: 60 },
  { id: "b1", block: "b", height: 50 },
  { id: "b2", block: "b", height: 30 },
];
function layOut(order: typeof blocks): SlotBox[] {
  let y = 0;
  return order.map((section, at) => {
    if (at > 0) y += order[at - 1]!.block === section.block ? 4 : 12;
    const box = { top: y, height: section.height };
    y += section.height;
    return box;
  });
}

test("a still pointer never flips the place, with a block's larger gap", () => {
  for (const held of blocks) {
    for (let drawnTop = -60; drawnTop <= 260; drawnTop += 0.5) {
      let order = [...blocks];
      const seen: string[] = [];
      for (let round = 0; round < 6; round++) {
        const at = heldPlace(layOut(order), order.indexOf(held), drawnTop, 4);
        const others = order.filter((section) => section !== held);
        order = [...others.slice(0, at), held, ...others.slice(at)];
        seen.push(order.map((section) => section.id).join(" "));
      }
      expect(new Set(seen.slice(1)).size).toBe(1);
    }
  }
});

test("a sweep down then back up moves the place one way at a time each way", () => {
  const held = blocks[0]!;
  let order = [...blocks];
  const place = (drawnTop: number) => {
    const at = heldPlace(layOut(order), order.indexOf(held), drawnTop, 4);
    const others = order.filter((section) => section !== held);
    order = [...others.slice(0, at), held, ...others.slice(at)];
    return at;
  };
  const down = Array.from({ length: 300 }, (_, i) => place(i - 20));
  const up = Array.from({ length: 300 }, (_, i) => place(280 - i));
  for (let i = 1; i < down.length; i++) expect(down[i]!).toBeGreaterThanOrEqual(down[i - 1]!);
  for (let i = 1; i < up.length; i++) expect(up[i]!).toBeLessThanOrEqual(up[i - 1]!);
});
