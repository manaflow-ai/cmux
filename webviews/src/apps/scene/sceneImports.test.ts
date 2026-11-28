// The agent pane loads no ui/ui.css (modelPicker.css, popupSurface.css). The kit's entry (kit/index.ts)
// imports kit.css, and kit.css imports ui/ui.css. So one import of the kit entry from the agent pane, or
// from the app scenes it draws (New Tab widgets, Session Info, tool widgets), adds ui.css's `.ui-popup`
// rule (padding, min-width, max-height, overflow) to the pane's CSS. That rule then wins over the pane's
// popup rules by load order: the New Tab suggestions drew 12 px of padding, not 6. Import a kit piece
// from its own module instead (kit/index.ts names each one).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const src = join(import.meta.dir, "..", "..");
const KIT_ENTRY = /(?:from\s+|import\s+)["'](?:\.\.?\/)+(?:[\w-]+\/)*kit(?:\/index(?:\.ts)?|\/kit\.css)?["']/;

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sources(path);
    if (!/\.(ts|tsx)$/.test(entry.name) || /\.(test|gallery|fixture)\.tsx?$/.test(entry.name)) return [];
    return [path];
  });
}

test("the agent pane and the app scenes never import the kit entry or its sheet", () => {
  const offenders = [join(src, "agent-session"), join(src, "apps")]
    .flatMap(sources)
    .filter((path) => KIT_ENTRY.test(readFileSync(path, "utf8")))
    .map((path) => relative(src, path));
  expect(offenders).toEqual([]);
});

test("the check sees a kit entry import", () => {
  expect(KIT_ENTRY.test('import { Icon } from "../../kit";')).toBe(true);
  expect(KIT_ENTRY.test('import "../../kit/kit.css";')).toBe(true);
  expect(KIT_ENTRY.test('import { Icon } from "../../agent-session/acpmux/icons/Icon";')).toBe(false);
  expect(KIT_ENTRY.test('import { Row } from "../../kit/Row";')).toBe(false);
});
