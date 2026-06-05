import { expect, test } from "bun:test";
import styles from "../src/styles.css" with { type: "text" };

test("toolbar and files pane use theme surfaces", () => {
  expect(styles).toContain("--cmux-diff-toolbar-bg: var(--cmux-diff-bg)");
  expect(styles).toContain("--cmux-diff-sidebar-bg: var(--cmux-diff-bg)");
  expect(styles).toMatch(/#toolbar\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-toolbar-bg\)/s);
  expect(styles).toMatch(/#toolbar\s*\{[^}]*padding: 3px 4px 3px 8px;/s);
  expect(styles).toMatch(/#files-sidebar\s*\{[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#files-header\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#file-list\s*\{[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toContain("--trees-bg-override: var(--cmux-diff-sidebar-bg)");
  expect(styles).toMatch(/\.toolbar-actions\s*\{[^}]*gap: 4px;/s);
  expect(styles).toMatch(/\.toolbar-icon\s*\{[^}]*width: 20px;[^}]*height: 20px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*width: 14px;[^}]*height: 14px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).toMatch(/#file-search-toggle svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).not.toContain("#source-detail");
  expect(styles).not.toContain("box-shadow: 0 -1px 0 var(--cmux-diff-border), 0 1px 0 var(--cmux-diff-border)");
});
