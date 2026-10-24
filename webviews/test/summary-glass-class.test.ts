// The chat's Summary card puts the liquid glass class on its popover, and only its popover (Leo
// 2026-10-21: "i dont like the non glassness here :("): summary.css styles `.ui-glass` on the
// popover placement as glass; the wide pane's inline column is not an overlay and keeps the page
// background. The popover floats over the chat, so it is `.ui-glass-floats` too: a see-through
// Chromium page lays it on the theme surface underlay as it does a menu (ui/glass/glass.css).
// summary-glass.test.ts checks the drawn glass in Chromium.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

test("the Summary card gives the popover, and only the popover, the glass class", () => {
  const source = readFileSync(new URL("../src/agent-session/acpmux/summary/SummaryCard.tsx", import.meta.url), "utf8");
  expect(source).toContain(
    'className={card.column ? "acpmux-summary-card" : "ui-glass ui-glass-floats acpmux-summary-card"}',
  );
});
