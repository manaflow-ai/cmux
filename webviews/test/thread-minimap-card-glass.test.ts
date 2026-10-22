// The thread minimap's preview card (hovering a mark) is glass, as the chat's other hover cards
// are (the link preview, the tooltips): the tooltip tint over the shared blur, never an opaque fill
// (Leo, 2026-10-21: "a SOLID tooltip card"). Reduce Transparency makes the tint the solid popup
// surface and the blur none (pages/shared/desktop.css), so the card needs no fallback of its own.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(
  new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");
/// The declarations of the rule whose whole selector is `selector`.
const rule = (selector: string) => {
  const at = css.search(new RegExp(`(^|\\})\\s*${selector.replaceAll(".", "\\.")}\\s*\\{`));
  if (at < 0) return "";
  const open = css.indexOf("{", at + 1);
  return css.slice(open + 1, css.indexOf("}", open));
};

test("the minimap card is the tooltip glass: the tooltip tint over the shared blur", () => {
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).toMatch(/background:\s*var\(--tooltip-tint\b/);
  expect(card).toMatch(/(^|[^-])backdrop-filter:\s*var\(--surface-blur\)/);
  expect(card).toMatch(/-webkit-backdrop-filter:\s*var\(--surface-blur\)/);
  // Still the raised elevation step (subtle-elevation.test.ts).
  expect(card).toMatch(/--elevation-2/);
});

test("the card draws no accent: theme text tones only, never orange or a system color", () => {
  const card = rule(".acpmux-minimap__card");
  expect(card).not.toBe("");
  expect(card).not.toMatch(/accent|Highlight\b|orange|#[0-9a-f]{3,8}\b|rgb\(/i);
});
