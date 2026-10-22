// Project menus keep the useful badge and trailing check on the one menu grid (schemas/menu-metrics,
// ui/popupSurface.css --ui-menu-*; Leo 2026-10-21, one left alignment across every menu): the badge,
// the search field's icon and New project's icon at the icon column, every name at the text column.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");

test("project menu rows sit on the menu grid without removing project affordances", () => {
  expect(css).toContain(
    ".acpmux-project-menu :is(.acpmux-menu-item,.acpmux-project-search,.acpmux-project-browse){padding-inline:var(--ui-menu-row-start) var(--ui-menu-row-end);gap:var(--ui-menu-icon-gap)}",
  );
  expect(css).not.toContain("--acpmux-project-menu-edge");
  expect(css).toContain(".acpmux-project-badge");
  expect(css).toContain(".acpmux-project-check");
});
