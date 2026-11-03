// The running turn's token count is secondary to its words (Leo, 2026-10-21: "the token font
// shouldnt be this same color"). "Thinking 35s" keeps the line's muted color and "Working for 35s"
// the background activity tone (#27074, `--cv-activity-text`); "· 679.9K out" after either takes
// the tool rows' quieter one, the theme's tertiary text
// (`--cv-text-dim`, `--agent-soft`, the host's textTertiary), never a literal color, in tabular
// numerals so the count ticks in place. Both lines that say it, the Codex layout's live line at the
// bottom (Thinking.tsx) and the line over the turn with that layout off (WorkingFor.tsx), draw the
// count in the same span, so one rule covers both. agent-pane-turn-tokens-muted-browser.test.tsx
// resolves the real stylesheets in Chromium.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { SPLIT, thinkingLine, tokenLines, tokenLineMarkup } from "./support/turnTokenLines";

const conversationCss = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);
/// The declarations of the rule whose selector is exactly `selector`.
const rule = (selector: string) => {
  const at = conversationCss.indexOf(`\n${selector} {`);
  if (at < 0) throw new Error(`conversation.css has no rule for ${selector}`);
  return conversationCss.slice(at, conversationCss.indexOf("}", at));
};

for (const [name, line] of Object.entries(tokenLines))
  test(`${name}: the count is its own span, which the quieter rule keys on`, () => {
    const html = tokenLineMarkup(line);
    expect(html).toContain(
      '<span class="cv-worked__count"><span class="cv-worked__sep" aria-hidden="true">·</span><span class="cv-worked__tokens">679.9K out</span></span>',
    );
    // The line's words come before the count's span, outside it.
    expect(html.indexOf("cv-worked__count")).toBeGreaterThan(html.search(/Working for|Thinking/));
  });

test("the count takes the theme's tertiary text token, in tabular numerals, never a literal color", () => {
  const tokens = rule(".cv-worked__count:has(> .cv-worked__tokens)");
  expect(tokens).toContain("color: var(--cv-text-dim);");
  expect(tokens).toContain("font-variant-numeric: tabular-nums;");
  expect(tokens).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(|oklch\(/i);
  // The line's words take the background activity tone (#27074); the count's is the tertiary one.
  expect(rule(".cv-worked")).toContain("color: var(--cv-activity-text);");
  expect(conversationCss).toContain("--cv-text-muted: var(--agent-muted);");
  expect(conversationCss).toContain("--cv-text-dim: var(--agent-soft);");
});

// The coordinator, relaying Leo's capture of "Thinking 7m 34s · ↓ 4.5K out ↑ 1.4M in": the counts on
// the live line are "debug noise in the main transcript". The line keeps them in its hover.
test("the live line at the bottom keeps the counts in its hover, not its text, beside its icon", () => {
  for (const [split, hover] of [
    [undefined, "679.9K out"],
    [SPLIT, "12.4K out"],
  ] as const) {
    const html = tokenLineMarkup(thinkingLine, split);
    expect(html).not.toContain("cv-worked__count");
    expect(html).not.toContain("cv-worked__tokens");
    expect(html).toMatch(
      new RegExp(`<div class="cv-worked cv-worked--live[^"]*" title="[^"]*${hover.replace(".", "\\.")}`),
    );
    // Its icon sits in the rows' one icon column, as every row's does.
    expect(html).toContain('<span class="cv-worked__icon" aria-hidden="true">');
  }
});
