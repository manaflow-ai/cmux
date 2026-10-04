import { expect, test } from "bun:test";
import styles from "../src/styles.css" with { type: "text" };

test("toolbar, files pane, tree and page share one opaque viewer background", () => {
  expect(styles).toContain("--cmux-diff-viewer-bg: var(--cmux-diff-bg)");
  expect(styles).not.toContain("--cmux-diff-toolbar-bg");
  expect(styles).not.toContain("--cmux-diff-sidebar-bg");
  expect(styles).not.toContain("--cmux-diff-surface-fill");
  expect(styles).toMatch(/body\s*\{[^}]*background: var\(--cmux-diff-viewer-bg\)/s);
  expect(styles).toMatch(
    /#toolbar\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-viewer-bg\)/s,
  );
  expect(styles).toMatch(/#toolbar\s*\{[^}]*padding: 3px 4px 3px 8px;/s);
  expect(styles).toMatch(/#files-sidebar\s*\{[^}]*background: var\(--cmux-diff-viewer-bg\)/s);
  expect(styles).toMatch(
    /#files-header\s*\{[^}]*border-bottom: 1px solid var\(--cmux-diff-border\)[^}]*background: var\(--cmux-diff-viewer-bg\)/s,
  );
  expect(styles).toMatch(/#file-list\s*\{[^}]*background: var\(--cmux-diff-viewer-bg\)/s);
  const rendererHostBlock = String(styles).match(/#viewer diffs-container\s*\{(?<body>[^}]*)\}/s)?.groups?.body ?? "";
  expect(rendererHostBlock).toContain("flex: 1 1 auto");
  expect(rendererHostBlock).toContain("min-height: 30px");
  expect(rendererHostBlock).not.toContain("background: var(--cmux-diff-bg)");
  expect(styles).toContain("--trees-bg-override: var(--cmux-diff-viewer-bg)");
  expect(styles).toContain("--trees-font-weight-semibold-override: var(--trees-font-weight-regular)");
  expect(styles).toMatch(/\.toolbar-actions\s*\{[^}]*gap: 4px;/s);
  expect(styles).toMatch(/\.toolbar-icon\s*\{[^}]*width: 20px;[^}]*height: 20px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*width: 14px;[^}]*height: 14px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).toMatch(/#file-search-toggle svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).not.toContain("#source-detail");
  expect(styles).not.toContain("box-shadow: 0 -1px 0 var(--cmux-diff-border), 0 1px 0 var(--cmux-diff-border)");
});
