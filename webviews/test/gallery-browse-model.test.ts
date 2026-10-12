import { describe, expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
import {
  browseItems,
  filterBrowseItems,
  nextBrowseVariant,
  resolveBrowseVariant,
} from "../src/gallery/shell/browseModel";

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
    variants: { idle: {}, streaming: { play: true } },
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

  test("starts mixed entries on a motion variant when showing motion previews", () => {
    expect(filterBrowseItems(entries, "", "motion", "entries").map(({ variant }) => variant)).toEqual(["streaming"]);
    expect(filterBrowseItems(entries, "idle", "motion", "entries").map(({ variant }) => variant)).toEqual([
      "streaming",
    ]);
  });

  test("starts an entry on its shareable pick when that pick matches the active kind", () => {
    expect(
      filterBrowseItems(entries, "", "all", "entries", { "composer.picker": "disabled" }).map(({ variant }) => variant),
    ).toEqual(["disabled", "idle"]);
    expect(
      filterBrowseItems(entries, "", "motion", "entries", { "transcript.motion": "streaming" }).map(
        ({ variant }) => variant,
      ),
    ).toEqual(["streaming"]);
    expect(
      filterBrowseItems(entries, "", "motion", "entries", { "transcript.motion": "idle" }).map(
        ({ variant }) => variant,
      ),
    ).toEqual(["streaming"]);
  });

  test("shows static variants from mixed entries and excludes motion-only entries", () => {
    const motionOnly = {
      ...entries[1]!,
      id: "motion-only",
      variants: { streaming: entries[1]!.variants.streaming! },
    } as GalleryEntry;
    expect(
      filterBrowseItems([...entries, motionOnly], "", "static", "entries").map(({ entry, variant }) => [
        entry.id,
        variant,
      ]),
    ).toEqual([
      ["composer.picker", "keyboard"],
      ["transcript.motion", "idle"],
    ]);
    expect(filterBrowseItems(entries, "streaming", "static", "entries").map(({ variant }) => variant)).toEqual([
      "idle",
    ]);
  });

  test("expands every real variant for the all-variants contact sheet", () => {
    expect(browseItems(entries, "variants").map(({ entry, variant }) => `${entry.id}#${variant}`)).toEqual([
      "composer.picker#keyboard",
      "composer.picker#disabled",
      "transcript.motion#idle",
      "transcript.motion#streaming",
    ]);
    expect(filterBrowseItems(entries, "STREAMING", "all", "variants").map(({ variant }) => variant)).toEqual([
      "streaming",
    ]);
    expect(filterBrowseItems(entries, "transcript", "all", "variants").map(({ variant }) => variant)).toEqual([
      "idle",
      "streaming",
    ]);
    expect(filterBrowseItems(entries, "", "motion", "variants").map(({ variant }) => variant)).toEqual(["streaming"]);
    expect(filterBrowseItems(entries, "", "static", "variants").map(({ variant }) => variant)).toEqual([
      "keyboard",
      "disabled",
      "idle",
    ]);
  });
});
