import { describe, expect, test } from "bun:test";
import type { GalleryEntry } from "../format";
import { browseItems, filterBrowseItems } from "./browseModel";

const entries = [
  {
    host: "native",
    id: "composer.picker",
    title: "Composer picker",
    area: "Composer",
    covers: [],
    pick: { beadId: "picker", recommendedId: "keyboard" },
    variants: { pointer: {}, keyboard: {} },
  },
  {
    host: "native",
    id: "transcript.motion",
    title: "Transcript motion",
    area: "Transcript",
    covers: [],
    variants: { reduced: {} },
  },
] as unknown as GalleryEntry[];

describe("gallery browse model", () => {
  test("starts picked entries on their recommended variant", () => {
    expect(browseItems(entries).map(({ entry, variant }) => [entry.id, variant])).toEqual([
      ["composer.picker", "keyboard"],
      ["transcript.motion", "reduced"],
    ]);
  });

  test("filters by entry title, area, id, or variant without changing card order", () => {
    expect(filterBrowseItems(entries, "composer").map(({ entry }) => entry.id)).toEqual(["composer.picker"]);
    expect(filterBrowseItems(entries, "REDUCED").map(({ entry }) => entry.id)).toEqual(["transcript.motion"]);
    expect(filterBrowseItems(entries, "").map(({ entry }) => entry.id)).toEqual([
      "composer.picker",
      "transcript.motion",
    ]);
  });
});
