// The rows beside the bottom stack stay in sight (besideStack.ts; Lucas, 2026-11-17: a reply's action
// icons cut along a straight line beside the composer card's rounded corner, "where as chatgpt allows
// it like this").
import { expect, test } from "bun:test";
import { besideMask } from "./besideStack";

const card = { left: 16, top: 460, right: 684, bottom: 556, radiusLeft: 22, radiusRight: 22 };

test("a lone card keeps its two gutters and the room outside its top corners in sight", () => {
  const mask = besideMask([card], 700)!;
  expect(mask.sizes.split(", ")).toEqual(["16px 96px", "16px 96px", "22px 22px", "22px 22px"]);
  expect(mask.positions.split(", ")).toEqual(["0px 460px", "684px 460px", "16px 460px", "662px 460px"]);
  // Each corner piece is clear inside the card's curve, around its centre, and solid outside it.
  const [, , left, right] = mask.images.split(/, (?=linear|radial)/);
  expect(left).toBe("radial-gradient(circle 22px at 22px 22px, transparent 21.5px, #000 22.5px)");
  expect(right).toBe("radial-gradient(circle 22px at 0px 22px, transparent 21.5px, #000 22.5px)");
});

test("a tray over the card keeps its gutters down to the card, and the card's corners stop at the tray's sides", () => {
  const tray = { left: 28, top: 420, right: 672, bottom: 472, radiusLeft: 12, radiusRight: 12 };
  const mask = besideMask([card, tray], 700)!;
  const sizes = mask.sizes.split(", ");
  const positions = mask.positions.split(", ");
  // The tray first (the topmost surface): its gutters run 420 to 460, where the card begins.
  expect(sizes.slice(0, 2)).toEqual(["28px 40px", "28px 40px"]);
  expect(positions.slice(0, 2)).toEqual(["0px 420px", "672px 420px"]);
  // The card's corner room is only the 12px between its side and the tray's tucked foot.
  expect(sizes.slice(-2)).toEqual(["12px 22px", "12px 22px"]);
  expect(positions.slice(-2)).toEqual(["16px 460px", "672px 460px"]);
});

test("no surface, or one with no box, keeps nothing beside it", () => {
  expect(besideMask([], 700)).toBeUndefined();
  expect(besideMask([{ ...card, bottom: card.top }], 700)).toBeUndefined();
});

test("a tray wider than the card keeps the rows under its foot hidden: the card's gutters start outside it", () => {
  const tray = { left: 8, top: 420, right: 692, bottom: 472, radiusLeft: 12, radiusRight: 12 };
  const mask = besideMask([tray, card], 700)!;
  const pieces = mask.sizes.split(", ").map((size, at) => `${mask.positions.split(", ")[at]} ${size}`);
  // Beside the tray's foot (460 to 472), only the room outside the tray; under it, the card's gutters.
  expect(pieces).toContain("0px 460px 8px 12px");
  expect(pieces).toContain("692px 460px 8px 12px");
  expect(pieces).toContain("0px 472px 16px 84px");
  expect(pieces).toContain("684px 472px 16px 84px");
  // No piece reaches into the tray's foot.
  expect(pieces).not.toContain("0px 460px 16px 96px");
});

test("a pinned ask's card keeps the rows in sight beside it and across the stack's gap under it", () => {
  // The asks stack's card (PendingAsks.tsx) over the composer card: its gutters, and from its bottom
  // (300) down to the stack's bottom (310) the whole width, where the stack paints nothing.
  const ask = { left: 16, top: 220, right: 684, bottom: 300, radiusLeft: 12, radiusRight: 12, clearTo: 310 };
  const mask = besideMask([ask, card], 700)!;
  const pieces = mask.sizes.split(", ").map((size, at) => `${mask.positions.split(", ")[at]} ${size}`);
  expect(pieces).toContain("0px 220px 16px 80px");
  expect(pieces).toContain("684px 220px 16px 80px");
  expect(pieces).toContain("0px 300px 700px 10px");
});

test("the gap under a pinned ask stops at the next card, and a surface with no clearTo keeps none", () => {
  const first = { left: 16, top: 100, right: 684, bottom: 180, radiusLeft: 0, radiusRight: 0, clearTo: 310 };
  const second = { left: 16, top: 220, right: 684, bottom: 300, radiusLeft: 0, radiusRight: 0, clearTo: 310 };
  const mask = besideMask([first, second, card], 700)!;
  const pieces = mask.sizes.split(", ").map((size, at) => `${mask.positions.split(", ")[at]} ${size}`);
  // From the first card to the second (its "Needs your input" line is dockClear.ts's hole).
  expect(pieces).toContain("0px 180px 700px 40px");
  expect(pieces).toContain("0px 300px 700px 10px");
  // The composer card, no clearTo: nothing under it.
  expect(pieces.some((piece) => piece.startsWith("0px 556px"))).toBe(false);
});
