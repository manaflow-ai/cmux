// Rows whose controls show only on hover give their text the whole width at rest (Leo, 2026-11-24:
// "you're early ellipsis-ing because of a button that doesnt even always show"): the controls lie
// over the text's end (ui/motion/motion.css `.ui-reveal-text`, ui/revealCover.ts), not in a slot,
// margin or padding of their own.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const read = (path: string) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");
const rule = (css: string, selector: string) => {
  const at = css.indexOf(`\n${selector} {`);
  expect(at).toBeGreaterThanOrEqual(0);
  return css.slice(at, css.indexOf("}", at));
};

test("the diff file bar's buttons lie over its path", () => {
  const source = read("diff-viewer/FileHeader.tsx");
  expect(source).toContain("file-header ui-reveal-host");
  expect(source).toContain("file-header-path ui-reveal-text");
  expect(source).toContain("ref={revealControls}");
  const css = read("styles.css");
  expect(rule(css, ".file-header-actions")).toContain("position: absolute");
  expect(rule(css, ".file-header-menu-button")).not.toContain("margin-left");
});

test("the context menu rows' buttons lie over their titles", () => {
  const css = read("pages/settings/styles.css");
  expect(rule(css, ".menu-row-actions")).toContain("position: absolute");
  const source = read("pages/settings/components/ContextMenusCard.tsx");
  expect(source).toContain('className="menu-row-actions" ref={revealControls}');
  expect(source).toContain("menu-row-title ui-reveal-text");
});

test("a removable attachment chip keeps no room for its hover-only ×", () => {
  const css = read("agent-session/acpmux/composerAttachments.css");
  expect(css).not.toMatch(/acpmux-file-chip--removable\s*\{\s*padding-right/);
  expect(rule(css, ".acpmux-attachment-document-meta")).not.toContain("24px");
  expect(read("agent-session/acpmux/FileAttachment.tsx")).toContain("ui-reveal-text");
});
