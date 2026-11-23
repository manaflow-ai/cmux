import { expect, test } from "bun:test";
import fixture from "../../../../cmux-tui/crates/cmux-config/tests/fixtures/backdrop-placement-cases.json";
import {
  isPlacementMap,
  parsePlacement,
  placement,
  placementDragged,
  placementKey,
  placementRect,
  placementsValue,
  placementText,
  placementVisible,
  readPlacements,
} from "./backgroundPlacement";

// The Settings preview's math mirrors Rust's (cmux-config backdrop_placement); the Rust tests write
// the table (CMUX_UPDATE_FIXTURES=1) and this checks the mirror against every case.
type Case = {
  image: [number, number];
  view: [number, number];
  placement: string;
  rect: [number, number, number, number] | null;
  frame: [number, number, number, number] | null;
  contents: [number, number, number, number] | null;
};

const near = (got: number, want: number, within = 1e-6) => expect(Math.abs(got - want)).toBeLessThan(within);
// A dragged placement's text keeps 3 decimals (Rust `placement_text`), so it reads back within half a step.
const nearText = (got: number, want: number) => near(got, want, 5e-4 + 1e-9);

test("the mirror matches every case the Rust tests wrote", () => {
  const cases = (fixture as unknown as { cases: Case[] }).cases;
  expect(cases.length).toBeGreaterThan(10);
  for (const item of cases) {
    const read = parsePlacement(item.placement);
    expect(read).not.toBeNull();
    expect(placementText(read!)).toBe(item.placement);
    const image = { width: item.image[0], height: item.image[1] };
    const view = { width: item.view[0], height: item.view[1] };
    const rect = placementRect(read!, image, view);
    if (item.rect === null) expect(rect).toBeNull();
    else [rect!.x, rect!.y, rect!.width, rect!.height].forEach((got, at) => near(got, item.rect![at]!));
    const shown = placementVisible(read!, image, view);
    if (item.frame === null) expect(shown).toBeNull();
    else {
      const { frame, contents } = shown!;
      [frame.x, frame.y, frame.width, frame.height].forEach((got, at) => near(got, item.frame![at]!));
      [contents.x, contents.y, contents.width, contents.height].forEach((got, at) => near(got, item.contents![at]!));
    }
  }
});

type Drag = {
  image: [number, number];
  view: [number, number];
  placement: string;
  delta: [number, number];
  after: string;
};

test("a drag moves the picture as the Rust tests wrote", () => {
  const drags = (fixture as unknown as { drags: Drag[] }).drags;
  expect(drags.length).toBeGreaterThan(5);
  for (const item of drags) {
    const image = { width: item.image[0], height: item.image[1] };
    const view = { width: item.view[0], height: item.view[1] };
    const got = placementDragged(parsePlacement(item.placement)!, image, view, item.delta[0], item.delta[1]);
    const want = parsePlacement(item.after)!;
    expect(got.mode).toBe(want.mode);
    nearText(got.x, want.x);
    nearText(got.y, want.y);
    nearText(got.zoom, want.zoom);
  }
});

test("a shown picture keys its entry as the Rust tests wrote: a moment its file, a pair nothing", () => {
  const keys = (fixture as unknown as { keys: { id: string; key: string | null }[] }).keys;
  expect(keys.length).toBeGreaterThan(10);
  for (const item of keys) expect([item.id, placementKey(item.id)]).toEqual([item.id, item.key]);
});

test("texts read back, and out-of-range ones are refused", () => {
  expect(parsePlacement("fill")).toEqual(placement());
  expect(placementText(placement("fit", 0.25, 0.5))).toBe("fit 0.25 0.5");
  expect(placementText(placement("fill", 0.3, 0.7, 2))).toBe("fill 0.3 0.7 2");
  for (const bad of ["", "cover", "fill 2 0.5", "fill 0.5", "fill 0.5 0.5 5", "fill 0.5 0.5 1 1", "fill x y", 3]) {
    expect(parsePlacement(bad)).toBeNull();
  }
});

test("a drag follows the pointer until an edge would show", () => {
  const image = { width: 2000, height: 1000 };
  const view = { width: 400, height: 400 };
  // Filled: 800 wide, 400 of room to the left; 100 points right moves the anchor a quarter left.
  const moved = placementDragged(placement(), image, view, 100, 0);
  near(moved.x, 0.25);
  near(moved.y, 0.5);
  expect(placementDragged(placement(), image, view, 10_000, 0).x).toBe(0);
  // No room on an axis: the anchor stays.
  expect(placementDragged(placement(), image, view, 0, 50).y).toBe(0.5);
});

test("the setting's map: a centered fill drops its entry, an empty map is none", () => {
  expect(placementsValue(null, "starryNight", placement("fit"))).toEqual({ starryNight: "fit" });
  expect(placementsValue({ starryNight: "fit", other: "fill 0 0" }, "starryNight", placement())).toEqual({
    other: "fill 0 0",
  });
  expect(placementsValue({ starryNight: "fit" }, "starryNight", placement())).toBeNull();
  expect(readPlacements({ a: "fit", b: "nope", " ": "fit" })).toEqual({ a: placement("fit") });
  expect(isPlacementMap({ a: "fit 0 1" })).toBe(true);
  expect(isPlacementMap({ a: "nope" })).toBe(false);
  expect(isPlacementMap(["fit"])).toBe(false);
});
