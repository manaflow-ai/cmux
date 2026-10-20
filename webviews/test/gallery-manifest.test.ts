import { expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
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
