// Resume beside the mic is the line ▶, as the mic and Send's ↑ are, never the solid one (cmux#51039;
// test/composer-resume-quiet.test.ts measures it in the composer).
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { GlyphIcon } from "./SendSlotGlyph";

test("Resume's ▶ is the line glyph, not the solid one", () => {
  const play = renderToStaticMarkup(createElement(GlyphIcon, { glyph: "play" }));
  const send = renderToStaticMarkup(createElement(GlyphIcon, { glyph: "arrow" }));
  // The line form draws a stroke, as Send's ↑ and the mic do; the solid form has none.
  expect(send).toContain("stroke-width");
  expect(play).toContain("stroke-width");
});
