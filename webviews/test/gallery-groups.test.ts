import { expect, test } from "bun:test";
import type { EntryState } from "../src/gallery/entryStore";
import { diffPageEntry } from "../src/gallery/format";
import { EXPERIMENTAL_AREA, sidebarGroups } from "../src/gallery/shell/groups";
import { experimentalLabel } from "../src/gallery/shell/strings";

function state(id: string, area: string, experimental?: boolean): EntryState {
  const entry = diffPageEntry({
    id,
    title: id,
    area,
    experimental,
    covers: ["page:cmux.diff"],
    variants: { normal: { files: [] } },
  });
  return { path: `${id}.gallery.ts`, status: "ready", version: 1, entry, promise: Promise.resolve(entry) };
}

test("flagged entries from any area form one Experimental section after every other area", () => {
  const minimap = state("thread.minimap", "Agent pane", true);
  const widgets = state("thread.widgets", "Thread", true);
  const code = state("code.widgets", "Pages", true);
  const shipped = state("pages.diff", "Pages");
  const custom = state("custom.other", "Z custom");
  const groups = sidebarGroups([widgets, shipped, code, minimap, custom]);
  expect(groups.at(-1)?.area).toBe(EXPERIMENTAL_AREA);
  expect(groups.at(-1)?.states.map((s) => s.entry?.id)).toEqual(["code.widgets", "thread.minimap", "thread.widgets"]);
  expect(groups.find((g) => g.area === "Pages")?.states).toEqual([shipped]);
  expect(groups.at(-2)?.states).toEqual([custom]);
  expect(groups.flatMap((g) => g.states)).toHaveLength(5);
  expect(minimap.entry?.area).toBe("Agent pane");
});

test("clearing experimental returns an entry to its declared area", () => {
  const shipped = state("thread.minimap", "Agent pane", false);
  const groups = sidebarGroups([shipped]);
  expect(groups.find((g) => g.area === "Agent pane")?.states).toEqual([shipped]);
  expect(groups.at(-1)?.states).toEqual([]);
});

test("reloads retain experimental placement while unknown failures and loads stay at the top", () => {
  const original = state("thread.widgets", "Thread", true);
  const failed: EntryState = { ...original, status: "error", entry: undefined, lastGood: original.entry };
  const loading: EntryState = { ...original, path: "loading.ts", status: "loading", entry: undefined };
  const unknown: EntryState = { ...loading, path: "broken.ts", status: "error" };
  const groups = sidebarGroups([failed, loading, unknown]);
  expect(groups.slice(0, 2).map((g) => g.area)).toEqual(["Failed to load", "Loading"]);
  expect(groups.at(-1)?.states).toEqual([failed]);
});

test("Experimental stays last in an empty sidebar and its label follows the selected locale", () => {
  expect(sidebarGroups([]).at(-1)).toEqual({ area: EXPERIMENTAL_AREA, states: [] });
  expect(experimentalLabel("en")).toBe("Experimental");
  expect(experimentalLabel("ja")).toBe("実験的");
  expect(experimentalLabel("en-XA")).not.toBe("Experimental");
});
