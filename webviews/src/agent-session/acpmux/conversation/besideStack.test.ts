// The rows beside the bottom stack stay in sight (besideStack.ts; Lucas, 2026-11-17: a reply's action
// icons cut along a straight line beside the composer card's rounded corner, "where as chatgpt allows
// it like this").
import { expect, test } from "bun:test";
import { bandMask, besideMask, clippedRect, joinMasks } from "./besideStack";

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

// The dock band arms (dockBand.experiment.ts; Leo, 2026-11-22: "FIGURE OUT HOW WE CAN HAVE MORE STUFF
// THERE"): the card, 556 px down a 600 px scroller, over its quiet row's 44 px band.
const composerCard = { ...card, card: true };
test("the shipped band adds nothing under the card", () => {
  expect(besideMask([composerCard], 700)).toEqual(besideMask([card], 700));
});
test("frost keeps the card's own footprint in sight, for its glass to frost", () => {
  const mask = besideMask([composerCard], 700, { arm: "frost", height: 600 })!;
  expect(mask.sizes.split(", ")).toContain("668px 96px");
  expect(mask.positions.split(", ")).toContain("16px 460px");
});
test("frost-ramp fades the rows out over 16 px under the card; frost-through over the whole band", () => {
  const ramp = besideMask([composerCard], 700, { arm: "frost-ramp", height: 600 })!;
  expect(ramp.sizes.split(", ").at(-1)).toBe("700px 16px");
  expect(ramp.positions.split(", ").at(-1)).toBe("0px 556px");
  const through = besideMask([composerCard], 700, { arm: "frost-through", height: 600 })!;
  expect(through.sizes.split(", ").at(-1)).toBe("700px 44px");
});

test("an asks band keeps its label, Dismiss and card as the only painted holes", () => {
  const mask = bandMask(
    {
      top: 400,
      bottom: 620,
      holes: [
        { left: 16, top: 400, right: 150, bottom: 428, radius: 0 },
        { left: 550, top: 400, right: 684, bottom: 428, radius: 6 },
        { left: 16, top: 436, right: 684, bottom: 620, radius: 12 },
      ],
    },
    700,
  )!;
  const pieces = mask.sizes.split(", ").map((size, at) => `${mask.positions.split(", ")[at]} ${size}`);
  // The header's center gap and the gap above the card remain transparent in the mask.
  expect(pieces).toContain("150px 400px 400px 28px");
  expect(pieces).toContain("0px 428px 700px 8px");
  // The card's side gutters remain painted, so the card itself is the only full-width surface.
  expect(pieces).toContain("0px 436px 16px 184px");
  expect(pieces).toContain("684px 436px 16px 184px");
  expect(mask.images).toContain("radial-gradient(circle 6px");
});

test("joining an asks band does not discard the existing surface mask", () => {
  const surface = besideMask([card], 700)!;
  const band = bandMask(
    { top: 400, bottom: 428, holes: [{ left: 16, top: 400, right: 150, bottom: 428, radius: 0 }] },
    700,
  )!;
  const joined = joinMasks(surface, band)!;
  expect(joined).toEqual({
    images: `${surface.images}, ${band.images}`,
    sizes: `${surface.sizes}, ${band.sizes}`,
    positions: `${surface.positions}, ${band.positions}`,
  });
});

test("a transparent overlay band keeps the whole band visible", () => {
  const mask = bandMask({ top: 400, bottom: 428, holes: [] }, 700)!;
  expect(mask.sizes).toBe("700px 28px");
  expect(mask.positions).toBe("0px 400px");
});

test("a folding pending card's hole stops at the visible ask section", () => {
  expect(
    clippedRect({ left: 16, top: 436, right: 684, bottom: 620 }, { left: 16, top: 400, right: 684, bottom: 500 }),
  ).toEqual({ left: 16, top: 436, right: 684, bottom: 500 });
  expect(
    clippedRect({ left: 16, top: 436, right: 684, bottom: 620 }, { left: 16, top: 400, right: 684, bottom: 436 }),
  ).toBeUndefined();
});
