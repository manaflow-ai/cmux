import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8");
const trayRule = ':root[data-top-strip="tray"] .acpmux-composer-strip,';
const folderRecoveryRule =
  ':root[data-top-strip="tray"] .acpmux-composer-strip:has(> .acpmux-composer-context > .acpmux-folder-choice)';

function bodyAfter(selector: string): string {
  const start = css.indexOf(selector);
  expect(start, `missing selector ${selector}`).toBeGreaterThanOrEqual(0);
  const open = css.indexOf("{", start);
  const close = css.indexOf("}", open);
  expect(close).toBeGreaterThan(open);
  return css.slice(open + 1, close);
}

test("tray folder recovery expands after the fixed tray strip rule", () => {
  const fixedTray = css.indexOf(trayRule);
  const recovery = css.indexOf(folderRecoveryRule);
  expect(fixedTray).toBeGreaterThanOrEqual(0);
  expect(recovery).toBeGreaterThan(fixedTray);

  const body = bodyAfter(folderRecoveryRule);
  expect(body).toMatch(/height\s*:\s*auto\s*;/);
  expect(body).toMatch(/min-height\s*:\s*calc\(var\(--acpmux-strip-height\)\s*\+\s*var\(--acpmux-tray-tuck\)\)\s*;/);
});
