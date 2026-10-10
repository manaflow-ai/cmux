import { describe, expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
import { filterBrowseItems, nextBrowseVariant, resolveBrowseVariant } from "../src/gallery/shell/browseModel";

const entries = [
  {
    host: "native",
    id: "composer.picker",
    title: "Composer picker",
    area: "Composer",
    covers: [],
    variants: { keyboard: {}, disabled: {} },
  },
  {
    host: "native",
    id: "transcript.motion",
    title: "Transcript motion",
    area: "Transcript",
    covers: [],
    variants: { idle: {}, streaming: {} },
  },
] as unknown as GalleryEntry[];

describe("gallery browse variants", () => {
  test("keeps the current variant when the registry still contains it", () => {
    expect(resolveBrowseVariant("streaming", "idle", ["idle", "streaming"])).toBe("streaming");
  });

  test("falls back to the recommended variant when a selected state disappears", () => {
    expect(resolveBrowseVariant("removed", "idle", ["idle", "done"])).toBe("idle");
  });

  test("falls back to the first real state when both selections disappear", () => {
    expect(resolveBrowseVariant("removed", "also-removed", ["done", "error"])).toBe("done");
    expect(resolveBrowseVariant("removed", undefined, [])).toBeUndefined();
  });

  test("cycles only through states that exist in the refreshed registry", () => {
    expect(nextBrowseVariant("removed", ["idle", "done"])).toBe("idle");
    expect(nextBrowseVariant("idle", ["idle", "done"])).toBe("done");
  });

  test("starts a filtered card on the variant named by the query", () => {
    expect(filterBrowseItems(entries, "STREAMING").map(({ entry, variant }) => [entry.id, variant])).toEqual([
      ["transcript.motion", "streaming"],
    ]);
    expect(filterBrowseItems(entries, "composer").map(({ entry, variant }) => [entry.id, variant])).toEqual([
      ["composer.picker", "keyboard"],
    ]);
  });
});
