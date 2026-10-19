// The URL chip's hover card (#21199) draws from classes in the agent pane's stylesheet. A
// stale-base squash (#21194) once dropped every one of those rules while LinkChips.tsx kept
// rendering them, and the card showed up unstyled. Every class the card renders needs a rule.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../src/agent-session/acpmux");

test("every cv-link-preview class the URL chip renders has a rule in the pane's stylesheet", () => {
  const chips = readFileSync(join(root, "chips/LinkChips.tsx"), "utf8");
  const styles = readFileSync(join(root, "styles.css"), "utf8");
  const used = [...new Set(chips.match(/cv-link-preview[\w-]*/g) ?? [])].sort();
  expect(used.length).toBeGreaterThan(0);
  const unstyled = used.filter((name) => !new RegExp(`\\.${name}(?![\\w-])[^{]*\\{`).test(styles));
  expect(unstyled).toEqual([]);
});
