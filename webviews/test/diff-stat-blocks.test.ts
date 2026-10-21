// The five-block change bar in a diff file header (FileHeader.tsx): proportional, every nonzero
// side gets a block, and an even split stays even.
import { expect, test } from "bun:test";
import { diffStatBlocks } from "../src/diff-viewer/FileHeader";

const bar = (added: number, deleted: number) =>
  diffStatBlocks(added, deleted)
    .map((kind) => ({ added: "+", deleted: "-", neutral: "." })[kind])
    .join("");

test("the bar splits five blocks by the counts", () => {
  expect(bar(9, 0)).toBe("+++++");
  expect(bar(0, 4)).toBe("-----");
  expect(bar(4, 1)).toBe("++++-");
  expect(bar(0, 0)).toBe(".....");
});

test("an even split stays even, and a tiny side still shows", () => {
  expect(bar(6, 6)).toBe("++--.");
  expect(bar(1, 1)).toBe("++--.");
  expect(bar(1, 100)).toBe("+----");
  expect(bar(100, 1)).toBe("++++-");
});
