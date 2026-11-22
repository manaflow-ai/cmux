// An attachment chip's remove × reads clearly over what it sits on (Leo, 2026-11-06: "Also this close
// button, this is bad clarity. Like it just is. Why is this like this?"). Before, every chip's ×
// (the strip's tiles, a chip placed in the prompt, a queued prompt's image) was a 16-unit glyph
// scaled to 8 px on a badge of 82% of --acpmux-composer-bg, itself 13% of the text over a
// transparent page: a see-through, half-pixel × over the thumbnail or the text card's lines.
// Now each draws RemoveGlyph (its own 8 px box, no scaling) on a solid, inverted badge: the text
// colour as the fill and the page's opaque base as the ink, the contrast of the text itself.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../src/agent-session/acpmux");
const read = (file: string) => readFileSync(join(root, file), "utf8");
const strip = (css: string) => css.replace(/\/\*[\s\S]*?\*\//g, "");

const SITES = ["composer/attachmentIntake.tsx", "composer/inlineAttachments.tsx", "QueuedImages.tsx"];

/** The declarations of every rule whose selector is exactly `selector`. */
function rules(css: string, selector: string): string[] {
  const found: string[] = [];
  for (const [, sel = "", body = ""] of strip(css).matchAll(/([^{}]+)\{([^{}]*)\}/g))
    if (sel.trim().replace(/\s+/g, " ") === selector) found.push(body);
  return found;
}
const value = (body: string, property: string) =>
  body.match(new RegExp(`(?:^|;|\\s)${property}\\s*:\\s*([^;]+)`))?.[1]?.trim();

const BADGES: Array<[file: string, selector: string, hover: string]> = [
  [
    "composerAttachments.css",
    ":is(.acpmux-composer, .nt-box) .acpmux-attachment-remove",
    ":is(.acpmux-composer, .nt-box) .acpmux-attachment-remove:hover",
  ],
  ["markdownField.css", ".acpmux-md-inline-remove", ".acpmux-md-inline-remove:hover"],
  ["composerStates.css", ".acpmux-queued-image-remove", ".acpmux-queued-image-remove:hover"],
];

test("no chip draws its × as a scaled-down 16-unit glyph", () => {
  for (const file of SITES) {
    const source = read(file);
    expect({ file, scaled: source.includes('viewBox="0 0 16 16" width="8"') }).toEqual({ file, scaled: false });
    expect({ file, glyph: source.includes("<RemoveGlyph />") }).toEqual({ file, glyph: true });
  }
});

test("RemoveGlyph draws at its own size, with no scaling", () => {
  const glyph = read("composer/RemoveGlyph.tsx");
  expect(glyph).toContain("viewBox={`0 0 ${REMOVE_GLYPH_PX} ${REMOVE_GLYPH_PX}`}");
  expect(glyph).toContain("width={REMOVE_GLYPH_PX}");
  expect(glyph).toMatch(/export const REMOVE_GLYPH_PX = 8;/);
});

test("every chip's remove badge is solid and inverted, never see-through", () => {
  for (const [file, selector, hover] of BADGES) {
    const css = read(file);
    const [body] = rules(css, selector);
    expect({ selector, found: body !== undefined }).toEqual({ selector, found: true });
    expect({ selector, background: value(body!, "background") }).toEqual({ selector, background: "var(--agent-text)" });
    expect({ selector, color: value(body!, "color") }).toEqual({ selector, color: "var(--acpmux-base, Canvas)" });
    expect({ selector, blur: /backdrop-filter/.test(body!) }).toEqual({ selector, blur: false });
    // Shown at once on hover: a fade is a half-transparent × over the label while it runs.
    expect({ selector, transition: value(body!, "transition") }).toEqual({ selector, transition: undefined });
    const [lit] = rules(css, hover);
    expect({ hover, background: lit && value(lit, "background") }).toEqual({
      hover,
      background: "color-mix(in srgb, var(--agent-text) 82%, var(--acpmux-base, Canvas))",
    });
  }
});
