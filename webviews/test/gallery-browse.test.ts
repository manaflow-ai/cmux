import { expect, test } from "bun:test";
import { diffPageEntry } from "../src/gallery/format";
import {
  browseFrameHref,
  browseHasMotion,
  browseItems,
  browseVariant,
  filterBrowseItems,
  nextBrowseVariant,
} from "../src/gallery/shell/browseModel";
import { DEFAULT_ENV } from "../src/gallery/env";
import { loadEntries } from "../scripts/gallery/entries";

const entry = (
  id: string,
  variants: Record<string, { files: []; play?: () => Promise<void> }>,
  recommendedId?: string,
) =>
  diffPageEntry({
    id,
    title: id,
    area: "Pages",
    covers: ["page:cmux.diff"],
    pick: recommendedId ? { beadId: `bead-${id}`, recommendedId } : undefined,
    variants,
  });

test("browse cards use the recorded recommendation and fall back to the first real variant", () => {
  const recommended = entry("pages.recommended", { first: { files: [] }, chosen: { files: [] } }, "chosen");
  const fallback = entry("pages.fallback", { first: { files: [] }, second: { files: [] } });
  expect(browseVariant(recommended)).toBe("chosen");
  expect(browseVariant(fallback)).toBe("first");
  expect(browseItems([recommended, fallback]).map(({ entry: value, variant }) => [value.id, variant])).toEqual([
    ["pages.recommended", "chosen"],
    ["pages.fallback", "first"],
  ]);
  expect(browseFrameHref(recommended, "chosen", DEFAULT_ENV)).toBe("frame.html?entry=pages.recommended&variant=chosen");
});

test("empty entries are omitted so the contact sheet never mounts a missing frame", () => {
  const empty = entry("pages.empty", {});
  expect(browseVariant(empty)).toBeUndefined();
  expect(browseItems([empty])).toEqual([]);
});

test("the contact sheet model is backed by the checked-in gallery registry", async () => {
  const entries = await loadEntries();
  const cards = browseItems(entries);
  expect(cards.length).toBeGreaterThan(0);
  expect(cards.every(({ entry: value, variant }) => Object.hasOwn(value.variants, variant))).toBe(true);
  expect(cards.some(({ entry: value }) => value.id === "agent-pane.transcript")).toBe(true);
});

test("browse filters expose motion and static reference cards without changing their identity", () => {
  const staticEntry = entry("pages.static", { idle: { files: [] } });
  const motionEntry = entry("agent-pane.motion", {
    idle: { files: [] },
    open: { files: [], play: async () => {} },
  });
  const cards = browseItems([staticEntry, motionEntry]);
  expect(nextBrowseVariant("idle", ["idle", "open"])).toBe("open");
  expect(nextBrowseVariant("open", ["idle", "open"])).toBe("idle");
  expect(nextBrowseVariant("missing", ["idle", "open"])).toBe("idle");
  expect(nextBrowseVariant("idle", [])).toBeUndefined();
  expect(browseHasMotion(staticEntry)).toBe(false);
  expect(browseHasMotion(motionEntry)).toBe(true);
  expect(filterBrowseItems(cards, "", "static").map(({ entry: value }) => value.id)).toEqual(["pages.static"]);
  expect(filterBrowseItems(cards, "motion", "all").map(({ entry: value }) => value.id)).toEqual(["agent-pane.motion"]);
  expect(filterBrowseItems(cards, "agent", "motion").map(({ entry: value, variant }) => [value.id, variant])).toEqual([
    ["agent-pane.motion", "idle"],
  ]);
});
