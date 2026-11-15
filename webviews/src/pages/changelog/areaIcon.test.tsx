import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AREAS } from "./areas";
import { AreaIcon } from "./SheetPage";

// Every area glyph is strokes, and its svg carries the stroke paint itself: the Updated card's
// popover (UpdatedNotes) gave its icons no stroke CSS, so the cloud drew as a black fill and Other's
// dots drew as nothing (Leo 2026-11-15: "theese are kinda crappy looking icons and stuff").
describe("AreaIcon", () => {
  const areas = [...AREAS.map(([key]) => key), undefined];
  for (const area of areas) {
    test(`${area ?? "other"} draws in its host's text color with no fill`, () => {
      const svg = renderToStaticMarkup(<AreaIcon area={area} />);
      expect(svg).toMatch(/^<svg [^>]*fill="none"/);
      expect(svg).toMatch(/^<svg [^>]*stroke="currentColor"/);
      expect(svg).toMatch(/^<svg [^>]*stroke-linecap="round"/);
    });
  }
});
