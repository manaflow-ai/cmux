// Project menus keep the useful badge and trailing check while matching the compact desktop
// menu gutter. The shared menu token stays at 8px for other surfaces; this scoped edge keeps the
// project chooser from growing a second, empty-looking left rail around its badge.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");

test("project menu uses a compact edge without removing project affordances", () => {
  expect(css).toMatch(/\.ui-popup\.acpmux-project-menu\{[^}]*--acpmux-project-menu-edge:4px/);
  expect(css).toContain(".acpmux-project-menu .acpmux-menu-item{padding-inline:var(--acpmux-project-menu-edge)}");
  expect(css).toContain(".acpmux-project-menu .acpmux-project-search{padding-inline:var(--acpmux-project-menu-edge)}");
  expect(css).toContain(".acpmux-project-menu .acpmux-project-browse{padding-inline:var(--acpmux-project-menu-edge)}");
  expect(css).toContain(".acpmux-project-badge");
  expect(css).toContain(".acpmux-project-check");
});
