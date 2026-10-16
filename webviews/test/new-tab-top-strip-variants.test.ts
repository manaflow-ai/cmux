// Two New Tab designs as values of the composer's top strip switch (Debug Settings
// agentPane.debug.topStripStyle, which the app sets on <html> as data-top-strip; Lucas 2026-10-16):
//   - fitted: the New Tab's tab fits its folder and computer and flows into the card through
//     rounded shoulders, the card's rim whole;
//   - cursor: the folder and computer as plain text over the card, as Cursor's home draws them,
//     and the create actions as outlined pills.
// Both are New Tab designs: a started chat's composer keeps its default strip under them, so the
// switch's shared rules for the chat composer leave these two values out.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const NEW_TAB_VALUES = ["fitted", "cursor"] as const;

/** Every rule's selectors in `file`, at-rule preludes (@media) left out, split on top-level commas. */
function selectors(file: string): string[] {
  const css = readFileSync(new URL(file, import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  return [...css.matchAll(/([^{}]+)\{/g)]
    .map((match) => match[1]!.trim())
    .filter((prelude) => !prelude.startsWith("@"))
    .flatMap((prelude) => prelude.split(/,(?![^()]*\))/).map((selector) => selector.trim()));
}

test("the New Tab variants' stylesheet only styles the New Tab page, and only under its own value", () => {
  const rules = selectors("../src/agent-session/acpmux/newtab/topStripVariants.css");
  expect(rules.length).toBeGreaterThan(0);
  for (const selector of rules) {
    expect(selector).toMatch(/^:root\[data-top-strip="(fitted|cursor)"\] \.nt-/);
  }
  for (const value of NEW_TAB_VALUES) expect(rules.some((selector) => selector.includes(`"${value}"`))).toBe(true);
});

test("the switch's shared chat composer rules leave the New Tab values out", () => {
  const chatRules = selectors("../src/agent-session/acpmux/composerLocation.css").filter(
    // The chat composer's own class, not a New Tab rule that names the strip inside it.
    (selector) =>
      selector.startsWith(":root[data-top-strip]") &&
      /\.acpmux-composer(?![\w-])/.test(selector) &&
      !selector.includes(".nt-"),
  );
  expect(chatRules.length).toBeGreaterThan(0);
  for (const selector of chatRules) {
    if (selector.startsWith(':root[data-top-strip="')) continue;
    for (const value of NEW_TAB_VALUES) expect(selector).toContain(`[data-top-strip="${value}"]`);
  }
});

test("the gallery shows each New Tab value on the New Tab page", async () => {
  const { default: entry } = await import("../src/agent-session/acpmux/newtab/NewTabScreen.gallery");
  const variants = (entry as { variants: Record<string, { documentAttributes?: Record<string, string> }> }).variants;
  for (const value of NEW_TAB_VALUES)
    expect(variants[`top-strip-${value}`]?.documentAttributes).toEqual({ "top-strip": value });
});

// The strip is a size container (composerLocation.css: its controls answer to its own width), and a
// size container's width ignores what it holds: a tab sized by its pickers drew 16 px wide.
test("the fitted tab is sized by its pickers, not as a size container", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/newtab/topStripVariants.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  const tab = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].find(
    (match) =>
      match[1]!.trim() === ':root[data-top-strip="fitted"] .nt-screen .nt-composer .acpmux-composer-strip' &&
      /align-self/.test(match[2]!),
  );
  expect(tab?.[2]).toMatch(/container-type:\s*normal/);
});
