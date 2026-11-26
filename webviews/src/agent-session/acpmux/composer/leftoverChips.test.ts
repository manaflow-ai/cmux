// A held prompt's images that no composer took stay with the tab beside its words, and come back once.
import { expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import type { KeptAttachments } from "./keptAttachments";
import { keepLeftoverChips, takeLeftoverChips } from "./leftoverChips";

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AQID",
});

const fakeStore = (): KeptAttachments & { held: Map<string, ComposerAttachment[]> } => {
  const held = new Map<string, ComposerAttachment[]>();
  return {
    held,
    read: async (key) => held.get(key) ?? [],
    write: async (key, chips) => {
      held.set(key, chips);
      return { held: chips.map((chip) => chip.id) };
    },
  };
};

test("images left for a tab come back once, in the order they were left", async () => {
  const store = fakeStore();
  await keepLeftoverChips(store, "tab-1", [image("a")]);
  await keepLeftoverChips(store, "tab-1", [image("b")]);
  expect((await takeLeftoverChips(store, "tab-1")).map((chip) => chip.id)).toEqual(["a", "b"]);
  expect(await takeLeftoverChips(store, "tab-1")).toEqual([]);
});

test("another tab never gets them", async () => {
  const store = fakeStore();
  await keepLeftoverChips(store, "tab-1", [image("a")]);
  expect(await takeLeftoverChips(store, "tab-2")).toEqual([]);
});
