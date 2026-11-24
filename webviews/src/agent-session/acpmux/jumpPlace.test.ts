// The jump stack's side (jumpPlace.ts): a side arm keeps its side unless the hat's handle stands
// there, and the centered arm has none.
import { expect, test } from "bun:test";
import { hatSide, jumpSide } from "./jumpPlace";

test("a side arm takes the side the hat's handle leaves free", () => {
  expect(jumpSide("end", "middle")).toBe("end");
  expect(jumpSide("end", "left")).toBe("end");
  expect(jumpSide("end", "right")).toBe("start");
  expect(jumpSide("corner", "right")).toBe("start");
  expect(jumpSide("start", "middle")).toBe("start");
  expect(jumpSide("start", "right")).toBe("start");
  expect(jumpSide("start", "left")).toBe("end");
});

test("the centered arm stays on the center line", () => {
  for (const handle of ["left", "middle", "right"] as const) expect(jumpSide("center", handle)).toBeUndefined();
});

test("the centered stack moves the middle handle aside, never one the person placed", () => {
  expect(hatSide("center", "middle", "end")).toBe("right");
  expect(hatSide("center", "middle", "quiet")).toBe("right");
  expect(hatSide("center", "middle", "start")).toBe("left");
  expect(hatSide("center", "middle", "middle")).toBe("middle");
  expect(hatSide("center", "left", "end")).toBe("left");
  expect(hatSide("center", "right", "start")).toBe("right");
  for (const place of ["end", "start", "corner"] as const) expect(hatSide(place, "middle", "end")).toBe("middle");
});
