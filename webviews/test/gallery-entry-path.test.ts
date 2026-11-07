// Every gallery entry's id resolves to its own file through galleryEntryPath, which browser tests
// use to open one entry alone (test/support/galleryFrame.ts finds a file by its literal
// `id: "<id>"` line). An entry whose id is a constant or template (#32825's `id: SPLIT_ENTRY`)
// matched no file, and only the browser lane's gallery-control-surfaces caught it, after merge.
// This runs in the plain bun lane, no browser.
import { expect, test } from "bun:test";
import { loadEntrySources } from "../scripts/gallery/entries";
import { galleryEntryPath } from "./support/galleryFrame";

test("every gallery entry's id is found in its own file", async () => {
  const sources = await loadEntrySources();
  expect(sources.length).toBeGreaterThan(0);
  const wrong: string[] = [];
  for (const { entry, path } of sources) {
    let found: string;
    try {
      found = galleryEntryPath(entry.id);
    } catch (error) {
      found = String(error);
    }
    if (found !== path) wrong.push(`${entry.id} (${path}): ${found}; write its id as a string literal`);
  }
  expect(wrong).toEqual([]);
});
