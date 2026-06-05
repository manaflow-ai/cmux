import { expect, test } from "bun:test";
import styles from "../src/styles.css" with { type: "text" };

test("toolbar and files pane use theme surfaces", () => {
  expect(styles).toContain("--cmux-diff-toolbar-bg: var(--cmux-diff-bg)");
  expect(styles).toContain("--cmux-diff-sidebar-bg: var(--cmux-diff-bg)");
  expect(styles).toMatch(/#toolbar\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-toolbar-bg\)/s);
  expect(styles).toMatch(/#files-sidebar\s*\{[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#files-header\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#file-list\s*\{[^}]*background: var\(--cmux-diff-sidebar-bg\)/s);
  expect(styles).toContain("--trees-bg-override: var(--cmux-diff-sidebar-bg)");
  expect(styles).not.toContain("box-shadow: 0 -1px 0 var(--cmux-diff-border), 0 1px 0 var(--cmux-diff-border)");
});
