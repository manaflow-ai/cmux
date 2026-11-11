import { expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
import { variantNotes } from "../scripts/gallery/notes";

// whats-new-gallery.py reads "Selected" and "Before:" off these: a variant's own note, never a prop's.
test("each variant's own note, by entry and variant", () => {
  const entry = {
    id: "agent-pane.fixture",
    title: "Fixture",
    area: "Agent pane",
    host: "component",
    covers: ["agent-session/fixture"],
    variants: {
      cards: { props: { note: "Before: a prop, not the note" }, note: "Selected: opened." },
      flat: { note: "Before: one flat list" },
      bare: { props: { before: true } },
    },
  } as unknown as GalleryEntry;
  expect(variantNotes([entry])).toEqual({
    "agent-pane.fixture": { cards: "Selected: opened.", flat: "Before: one flat list", bare: "" },
  });
});
