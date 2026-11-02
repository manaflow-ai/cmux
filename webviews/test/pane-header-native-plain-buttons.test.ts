// The pane header's native icon buttons are plain glyphs too (Leo 2026-10-25: "why do the icons have their
// own background border situation instead of just being, you know, good"; Leo 2026-10-31: "AND THE FUCKING
// BACKGROUND ON THIS FUCKING BUILD ON THESE BUTTONS STILL ISN'T FUCKING REMOVESD"). The pane's toolbar at the
// tab row's trailing end (PaneToolbarView: the pinned actions, the content-supplied native row tools of
// chrome.tabs.nativeRowTools, and "…") draws TitlebarBandButton and OverflowButton: borderless, no bezel that
// shows, no resting layer fill, no vibrancy or glass plate and no shadow. A toggled or lit button reads as on
// by its lit ink (Palette.litGlyph), never the selection fill. The pointer's hover and a press light only the
// button under it (ChromeHover); that stays. The webview's buttons are checked by chat-header-plain-icons and
// chat-header-tab-row-surface; these are their native counterparts, which no webview test can see.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const SOURCES = join(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources");
const read = (file: string) =>
  readFileSync(join(SOURCES, file), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "");

const BUTTONS = ["CmuxNextDesign/TitlebarBandButton.swift", "CmuxNextDesign/OverflowButton.swift"];
const TOOLBAR = "CmuxNextTabs/PaneToolbarView.swift";

// What would put a plate, pill, border or shadow behind a header button at rest or while it is on.
const PLATES: [string, RegExp][] = [
  ["a border", /\bisBordered\s*=\s*true\b/],
  ["a bezel that draws", /\bbezelStyle\s*=\s*\.(?!regularSquare\b)\w+/],
  ["a button type that draws its state", /\bsetButtonType\s*\(/],
  ["a border on hover", /\bshowsBorderOnlyWhileMouseInside\b/],
  ["a resting layer fill", /\b(?:layer\??\.)?backgroundColor\s*=/],
  ["a drawn background", /\bdrawsBackground\s*=\s*true\b/],
  ["a vibrancy or glass plate", /\bNSVisualEffectView\b|\bNSGlassEffectView\b|\.glassEffect\b/],
  ["a shadow", /\bshadow\s*=|\bshadowOpacity\s*=/],
  ["the selection fill", /\bselectionFill\b|\.selected\s*=\s*(?!false\b)|\bselected:\s*(?!false\b)\w/],
];

function plates(file: string, source: string): string[] {
  return PLATES.filter(([, pattern]) => pattern.test(source)).map(([what]) => `${file}: ${what}`);
}

test("the pane header's native icon buttons are borderless with no resting plate", () => {
  const found: string[] = [];
  for (const file of BUTTONS) {
    const source = read(file);
    expect(source, `${file} must turn its border off`).toMatch(/\bisBordered\s*=\s*false\b/);
    // The badge label is a text field inside the button: it may not draw a background either.
    found.push(...plates(file, source.replace(/\bbadgeLabel\.isBezeled\s*=\s*false\b/, "")));
  }
  expect(found).toEqual([]);
});

test("the pane toolbar draws its buttons, toggled or lit, with ink and no plate", () => {
  const source = read(TOOLBAR);
  expect(plates(TOOLBAR, source)).toEqual([]);
  // Lit (a zoomed pane's zoom button and "…") and toggled (a native row tool whose panel is open) are ink.
  expect(source).toMatch(/item\.lit\s*\?\s*Palette\.litGlyph/);
  expect(source).toMatch(/item\.toggled\s*\?\s*Palette\.litGlyph/);
  expect(source).toMatch(/moreButton\.tintOverride\s*=\s*lit\s*\?/);
});
