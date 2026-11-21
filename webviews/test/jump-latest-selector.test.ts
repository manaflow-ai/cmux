// Jump up (#40326, design/transcript-overlays.md) is Jump to latest's companion and the same control:
// it carries `.acpmux-jump-latest` for the disc's look and adds `.acpmux-jump-up`, and it renders first.
// A test or gallery that finds Jump to latest by the bare class gets Jump up instead, or a Playwright
// strict-mode error for two matches; that turned six agent-pane browser suites red at once. Every DOM
// lookup of Jump to latest says `.acpmux-jump-latest:not(.acpmux-jump-up)`; CSS and source scans of the
// class are not lookups and stay as they are.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const LOOKUP = /(locator|querySelector(All)?|closest|waitForSelector|selector:)[^\n]*\.acpmux-jump-latest(?=["'[])/;

function sources(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : sources(full);
    return /\.(ts|tsx)$/.test(entry.name) ? [full] : [];
  });
}

test("every DOM lookup of Jump to latest leaves Jump up out", () => {
  const files = [...sources(path.join(root, "test")), ...sources(path.join(root, "src"))].filter(
    (file) => /[/\\]test[/\\]/.test(file) || /\.(gallery|test)\.tsx?$/.test(file),
  );
  const bare = files.flatMap((file) =>
    fs
      .readFileSync(file, "utf8")
      .split("\n")
      .flatMap((line, index) =>
        LOOKUP.test(line) && !line.includes("jump-up") ? [`${path.relative(root, file)}:${index + 1}`] : [],
      ),
  );
  expect(bare).toEqual([]);
});
