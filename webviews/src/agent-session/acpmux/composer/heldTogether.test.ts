import { expect, test } from "bun:test";
import { heldReady, heldTogether, type PendingAttachment } from "./attachmentIntakeModel";

const chip = (id: string, extra: Partial<PendingAttachment> = {}): PendingAttachment => ({
  id,
  name: id,
  image: false,
  gesture: "g",
  ...extra,
});

test("a drop's chips are held while one of them has no width yet", () => {
  const drawn = heldTogether([chip("png", { image: true, sizing: true }), chip("zip")]);
  expect(drawn.map((c) => c.held)).toEqual([true, true]);
});

test("an image whose header gave its size has its width: its siblings show, it stays unseen by its own sizing", () => {
  const drawn = heldTogether([chip("png", { image: true, sizing: true, size: { width: 1, height: 1 } }), chip("zip")]);
  expect(drawn.map((c) => c.held)).toEqual([undefined, undefined]);
});

test("a video still reading its header holds its gesture; another gesture's chips show", () => {
  const drawn = heldTogether([
    chip("mov", { image: true, video: true, sizing: true }),
    chip("zip"),
    chip("other", { gesture: "h" }),
  ]);
  expect(drawn.map((c) => c.held)).toEqual([true, true, undefined]);
});

test("a failed chip is never held and never holds", () => {
  const drawn = heldTogether([chip("png", { image: true, sizing: true, failed: "no" }), chip("zip")]);
  expect(drawn.map((c) => c.held)).toEqual([undefined, undefined]);
});

test("a chip ready meanwhile is held with its gesture, and not once the gesture shows", () => {
  const gestureOf = new Map([
    ["png", "g"],
    ["zip", "g"],
  ]);
  const waiting = [chip("png", { image: true, sizing: true })];
  expect([...heldReady(gestureOf, new Set(["g"]), waiting)]).toEqual(["zip"]);
  expect(heldReady(gestureOf, new Set(), waiting).size).toBe(0);
});
