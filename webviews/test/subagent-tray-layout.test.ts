import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const bottomStack = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/bottomStack.css"), "utf8");

test("the bottom-stack tray is flush with the composer and keeps the shared outer inset", () => {
  const rule = bottomStack.match(/\.acpmux-dock > \.acpmux-running-tray\s*\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toMatch(/margin:\s*0\s+var\(--cv-inset\)\s*;/);
  expect(rule).not.toMatch(/margin-bottom\s*:\s*8px/);
});
