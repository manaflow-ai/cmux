import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../src");
const read = (path: string) => readFileSync(join(root, path), "utf8");

test("tab-row chat tools leave the native strip surface visible", () => {
  const app = read("agent-session/acpmux/App.tsx");
  const shell = read("agent-session/acpmux/styles.css");
  const header = read("agent-session/acpmux/header/header.css");
  const page = read("styles.css");

  expect(app).toContain('data-tab-row={inTabRow ? "" : undefined}');
  expect(app).toContain("style={inTabRow ? tabRowStyle(tabRow) : undefined}");
  expect(shell).toContain(
    ".acpmux-shell[data-tab-row]{background:linear-gradient(to bottom,transparent 0,var(--agent-page-bg) var(--acpmux-tab-row-height));}",
  );
  expect(header).toContain(".acpmux-header[data-tab-row]::after{content:none}");
  expect(page).toContain("html:has(.acpmux-shell[data-tab-row])");
  expect(page).toContain("background: transparent !important");
});
