// Live lines retain their elapsed time and text tone without rendering token amounts.
// The retained standalone token styles remain theme-based.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { SPLIT, tokenLines, tokenLineMarkup } from "./support/turnTokenLines";

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
  test(`${name}: usage data adds no token span or dangling separator`, () => {
    const html = tokenLineMarkup(line);
    expect(html).not.toContain("cv-worked__tokens");
    expect(html).not.toContain("cv-worked__sep");
    expect(html).not.toContain("679.9K");
    expect(html).toMatch(/<span class="cv-worked__(label-)?time">35s<\/span>/);
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

for (const [name, line] of Object.entries(tokenLines))
  test(`${name}: complete usage splits do not add visible amounts or a token tooltip`, () => {
    const html = tokenLineMarkup(line, SPLIT);
    expect(html).not.toContain("cv-worked__tokens");
    expect(html).not.toContain("cv-worked__sep");
    expect(html).not.toContain('title="Output');
    expect(html).not.toMatch(/↓|↑|12\.4K|60K/);
    expect(html).toMatch(/<span class="cv-worked__(label-)?time">35s<\/span>/);
  });
