// The Needs you list is a glass popover (Leo 2026-10-21: it drew solid): the frosted material of a
// link's hover card (styles.css .cv-link-preview), the tooltip tint and blur that desktop.css turns
// opaque under Reduce Transparency, and no solid band inside it (its title used to sit on the solid
// popup surface to cover the asks scrolling under it; now only the list scrolls).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const css = fs.readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/needsYou/needsYou.css"),
  "utf8",
);

/// The declarations of the one rule whose selector list is exactly `selector`.
function rule(selector: string): Record<string, string> {
  const match = new RegExp(`(?:^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`).exec(css);
  if (!match) throw new Error(`no rule ${selector}`);
  return Object.fromEntries(
    match[1]!
      .split(";")
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => [part.slice(0, part.indexOf(":")).trim(), part.slice(part.indexOf(":") + 1).trim()]),
  );
}

test("the Needs you popover is glass: the hover card's tint under its blur, never the solid popup surface", () => {
  const popover = rule(".acpmux-needs-you");
  expect(popover.background).toBe("var(--tooltip-tint, var(--surface-popup))");
  expect(popover["backdrop-filter"]).toBe("var(--tooltip-blur, none)");
  expect(popover["-webkit-backdrop-filter"]).toBe("var(--tooltip-blur, none)");
  // The list scrolls inside; the popover clips to its rounded glass.
  expect(popover.overflow).toBe("hidden");
  expect(rule(".acpmux-needs-you-list").overflow).toBe("auto");
});

test("nothing inside the Needs you popover paints the solid popup surface over the glass", () => {
  const inside = css
    .split("}")
    .filter((block) => /\.acpmux-needs-you-(head|panel|list|empty)\b/.test(block.split("{")[0] ?? ""));
  expect(inside.length).toBeGreaterThan(0);
  for (const block of inside) expect(block).not.toContain("--surface-popup");
});
