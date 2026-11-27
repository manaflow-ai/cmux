// The line after the three-state control's name says where the chat runs, from the app's place
// state (HybridMounts.placementLine): the move in flight first, then the reported place.
import { expect, test } from "bun:test";
import { placementLine } from "../src/agent-session/acpmux/hybrid/HybridMounts";
import type { MoveView, PlaceState } from "../src/agent-session/acpmux/place/placeModel";

const t = ((key: string, vars?: Record<string, string>) => (vars ? `${key}:${vars.to}` : key)) as never;
const moving = { state: "moving", to: "atlas-cloud" } as MoveView;

test("Hybrid names the place the app reports", () => {
  expect(placementLine({ mode: "auto", at: "local" }, t)).toBe("place.thisMac");
  expect(placementLine({ mode: "auto", at: "cloud" }, t)).toBe("place.cloud");
  expect(placementLine({ mode: "auto", at: "cloud", cloudName: "atlas-cloud" }, t)).toBe("atlas-cloud");
});

test("a move in flight wins, in every mode", () => {
  for (const mode of ["auto", "cloud", "local"] as const) {
    const place: PlaceState = { mode, at: "local", move: moving };
    expect(placementLine(place, t)).toBe("place.faceMoving:atlas-cloud");
  }
});

test("a pin that already names its place says nothing twice", () => {
  expect(placementLine({ mode: "local", at: "local" }, t)).toBeUndefined();
  expect(placementLine({ mode: "cloud", at: "cloud" }, t)).toBeUndefined();
  expect(placementLine({ mode: "cloud", at: "cloud", cloudName: "atlas-cloud" }, t)).toBe("atlas-cloud");
  // Chosen but not there yet: the line says where it still is.
  expect(placementLine({ mode: "cloud", at: "local" }, t)).toBe("place.thisMac");
});
