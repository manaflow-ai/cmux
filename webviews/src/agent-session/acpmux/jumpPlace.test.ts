// The jump stack's side (jumpPlace.ts): a side arm keeps its side unless the hat's handle stands
// there, and the centered arm has none.
import { expect, test } from "bun:test";
import { jumpSide } from "./jumpPlace";

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
