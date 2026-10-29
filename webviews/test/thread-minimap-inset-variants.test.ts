import { expect, test } from "bun:test";
import {
  railInsetVariants,
  threadMinimapGalleryVariants,
} from "../src/agent-session/acpmux/threadMinimap/threadMinimapNarrow.gallery";

test("thread minimap inset gallery keeps existing gaps and adds candidates", () => {
  expect(Object.keys(threadMinimapGalleryVariants)).toEqual([
    "gap-4-chosen",
    "gap-8",
    "gap-12",
    "inset-current",
    "inset-4-lawrence-candidate",
    "inset-8-reference-candidate",
    "inset-12-alternative",
    "inset-16-alternative",
  ]);
  expect(Object.keys(railInsetVariants)).toEqual([
    "inset-current",
    "inset-4-lawrence-candidate",
    "inset-8-reference-candidate",
    "inset-12-alternative",
    "inset-16-alternative",
  ]);
  expect("play" in railInsetVariants["inset-current"]).toBe(false);
  expect(railInsetVariants["inset-4-lawrence-candidate"].note).toContain("Exploratory");
  expect(railInsetVariants["inset-8-reference-candidate"].note).toContain("four rail references");
});
