// The thread minimap's preview card (hovering a mark) is one material, as the chat's other hover cards
// are (design/glass-system.md, "One material per surface"). Leo, 2026-11-21, on this card drawn as an
// opaque dark box: "shietttt this web thing got disconnected from its glass... where is our proper glass
// redesign?". It was a private recipe outside .ui-glass (the popover level's tint and its own backdrop
// blur) and never marked for the App's glass, so in Chromium's see-through pane its blur had nothing to
// frost and it read as a slab beside the menus on the App's glass. Now it is .ui-glass (the transient
// hover-card level) marked data-host-glass="popover": the App's popover glass under it when drawn, the
// page's one glass otherwise. Reduce Transparency makes it the solid popup surface (--glass-opaque).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(
  new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");
const tsx = readFileSync(new URL("../src/agent-session/acpmux/threadMinimap/PreviewCard.tsx", import.meta.url), "utf8");
/// The declarations of the rule whose whole selector is `selector`.
const rule = (selector: string) => {
  const at = css.search(new RegExp(`(^|\\})\\s*${selector.replaceAll(".", "\\.")}\\s*\\{`));
  if (at < 0) return "";
  const open = css.indexOf("{", at + 1);
  return css.slice(open + 1, css.indexOf("}", open));
};

test("the minimap card is the shared hover-card glass, marked for the App's popover glass", () => {
  expect(tsx).toContain('className="acpmux-minimap__card ui-glass ui-glass-transient"');
  expect(tsx).toMatch(/className="acpmux-minimap__card[^"]*"\s*\n\s*data-host-glass="popover"/);
});

test("the card paints no material of its own: no fill, no backdrop filter, no private rim", () => {
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).not.toMatch(/(^|[\s;])background(-color)?\s*:/);
  expect(card).not.toMatch(/backdrop-filter\s*:/);
  expect(card).not.toMatch(/(^|[\s;])box-shadow\s*:/);
  // Still the raised elevation step (subtle-elevation.test.ts), through the glass's own drop.
  expect(card).toMatch(/--glass-elevation:\s*var\(--elevation-2\)/);
  // Reduce Transparency: the solid popup surface, through the glass's opaque fill.
  expect(card).toMatch(/--glass-opaque:\s*var\(--surface-popup\b/);
  // No second Reduce Transparency fill of its own beside the glass's.
  expect(css).not.toMatch(/reduce-transparency[^{]*\.acpmux-minimap__card\s*\{[^}]*background/);
});

test("Reduce Transparency makes it the solid popup surface", () => {
  expect(rule(".acpmux-minimap__card")).toMatch(/--glass-opaque:\s*var\(--surface-popup\b/);
});

test("the card draws no accent: theme text tones only, never orange or a system color", () => {
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).not.toMatch(/accent|Highlight\b|orange|#[0-9a-f]{3,8}\b|rgb\(/i);
});
