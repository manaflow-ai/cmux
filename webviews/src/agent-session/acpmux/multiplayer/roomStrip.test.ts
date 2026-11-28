import { expect, test } from "bun:test";
import { noteChat, roomStrip } from "./roomStrip";

test("a strip reads faces, more and the line, and drops what is not a face", () => {
  const strip = roomStrip({
    faces: [
      { id: "a", kind: "person", name: "Ana", doing: "typing", status: "live" },
      { id: "a", kind: "person", name: "Ana again", doing: "idle", status: "live" },
      { id: "b", kind: "robot", name: "Nope" },
      { id: "c", kind: "agent", name: "Claude", doing: "idle", status: "away" },
      "junk",
    ],
    more: 3,
    line: { actors: [{ id: "a", kind: "person", name: "Ana", doing: "typing" }], more: -1 },
  });
  expect(strip?.faces.map((f) => [f.id, f.status])).toEqual([
    ["a", "live"],
    ["c", "away"],
  ]);
  expect(strip?.more).toBe(3);
  expect(strip?.line).toEqual({ actors: [{ id: "a", kind: "person", name: "Ana", doing: "typing" }], more: 0 });
});

test("no faces list is no strip, and an empty line is none", () => {
  expect(roomStrip(undefined)).toBeUndefined();
  expect(roomStrip({ more: 1 })).toBeUndefined();
  expect(roomStrip({ faces: [], more: 0, line: { actors: [], more: 0 } })).toEqual({ faces: [], more: 0 });
});

test("a note names its chat only as {chat}", () => {
  expect(noteChat({ room: { chat: "s1" } })).toBe("s1");
  expect(noteChat({ room: { workspace: "w" } })).toBeUndefined();
});
