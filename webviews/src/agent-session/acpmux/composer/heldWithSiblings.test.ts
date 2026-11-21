import { expect, test } from "bun:test";
import { heldWithSiblings, type PendingAttachment } from "./attachmentIntakeModel";

const chip = (id: string, extra: Partial<PendingAttachment> = {}): PendingAttachment => ({
  id,
  name: id,
  image: false,
  ...extra,
});

test("a drop's file chip is held while its picture's header is read, and shows with it", () => {
  const file = chip("zip", { sizingWith: "drop" });
  const picture = chip("png", { image: true, sizing: true, sizingWith: "drop" });
  expect(heldWithSiblings([file, picture]).map((each) => Boolean(each.sizing))).toEqual([true, true]);
  const sized = { ...picture, sizing: false };
  expect(heldWithSiblings([file, sized]).map((each) => Boolean(each.sizing))).toEqual([false, false]);
});

test("a sibling that failed or left never holds the rest", () => {
  const file = chip("zip", { sizingWith: "drop" });
  expect(heldWithSiblings([file, chip("png", { sizing: true, failed: "x", sizingWith: "drop" })])[0]!.sizing).toBe(
    undefined,
  );
  expect(heldWithSiblings([file])[0]!.sizing).toBe(undefined);
});

test("another gesture's sizing holds nothing of this one", () => {
  const file = chip("zip", { sizingWith: "a" });
  const other = chip("png", { sizing: true, sizingWith: "b" });
  expect(heldWithSiblings([file, other])[0]!.sizing).toBe(undefined);
});
