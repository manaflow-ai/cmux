// The thread minimap's preview card (hovering a mark) is the one hover card glass of the chat's other
// hover cards (the link preview, a session's card): .ui-card.ui-glass, never a fill of its own (Leo,
// 2026-10-21: "a SOLID tooltip card"; 2026-11-20: "WHERE IS THE GLASS EVERYWHERE ALL THESE STUPID
// F***ING HOVER TOOLTIPS AND HOVER PREVIEW SHIT"). Reduce Transparency makes the glass the solid
// popup surface (--glass-opaque, glass.css).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(
  new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");
const markup = readFileSync(
  new URL("../src/agent-session/acpmux/threadMinimap/PreviewCard.tsx", import.meta.url),
  "utf8",
);
/// The declarations of the rule whose whole selector is `selector`.
const rule = (selector: string) => {
  const at = css.search(new RegExp(`(^|\\})\\s*${selector.replaceAll(".", "\\.")}\\s*\\{`));
  if (at < 0) return "";
  const open = css.indexOf("{", at + 1);
  return css.slice(open + 1, css.indexOf("}", open));
};

test("the minimap card is the shared hover card glass, with no fill, blur or shadow of its own", () => {
  expect(markup).toMatch(/className="ui-card ui-glass acpmux-minimap__card"/);
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).not.toMatch(/(^|[;\s])background(-color)?\s*:/);
  expect(card).not.toMatch(/backdrop-filter\s*:/);
  expect(card).not.toMatch(/box-shadow\s*:/);
});

test("Reduce Transparency makes it the solid popup surface", () => {
  expect(rule(".acpmux-minimap__card")).toMatch(/--glass-opaque:\s*var\(--surface-popup\b/);
});

test("the card draws no accent: theme text tones only, never orange or a system color", () => {
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).not.toMatch(/accent|Highlight\b|orange|#[0-9a-f]{3,8}\b|rgb\(/i);
});
