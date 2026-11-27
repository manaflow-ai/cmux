import { expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
import { selectGalleryFiles } from "../scripts/gallery/entries";
import { manifestCases } from "../scripts/gallery/manifest";

const entry = {
  id: "agent-pane.fixture",
  title: "Fixture",
  area: "Agent pane",
  host: "component",
  covers: ["agent-session/fixture"],
  variants: { initial: { props: {} } },
} as unknown as GalleryEntry;

test("manifest cases carry the real entry source path", () => {
  const [item] = manifestCases([entry], {
    frame: "component",
    themes: "default",
    widths: "normal",
    sourcePaths: new Map([[entry.id, "src/agent-session/Fixture.gallery.tsx"]]),
    limit: 1,
  });
  expect(item?.params.source).toBe("src/agent-session/Fixture.gallery.tsx");
});

test("filtered gallery loading selects files before importing them", () => {
  const files = ["/tmp/webviews/src/good.gallery.tsx", "/tmp/webviews/src/broken.gallery.tsx"];
  const index = { "pages.diff/jump-file-overflow": "src/good.gallery.tsx" };
  expect(selectGalleryFiles(["pages.diff"], files, index, "/tmp/webviews/src")).toEqual([files[0]]);
  expect(selectGalleryFiles(["computed.entry"], files, index, "/tmp/webviews/src")).toEqual(files);
});
